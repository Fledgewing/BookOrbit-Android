#!/usr/bin/env python3
"""BookSync's Xteink scenarios in upstream's SDL simulator (docs/design/emulated-release-tests.md,
stage 1), against the seeded BookOrbit server behind the fault proxy (tools/e2e/).

    tools/e2e/kit.py up                                  # once: server up and seeded
    xteink/test/e2e/run.py --checkout <CrossInk> --profile x4-pro [--scenario NAME] [--out DIR] [-v]

The checkout has the overlay applied and the profile's simulator built
(`pio run -e x4-pro-simulator`; profiles: x4-pro, x4-classic, x3). Each scenario gets its own SD
card and fault rules; it asserts on the firmware's log, the card and the proxy's request log, and
never compares screenshots (some scenarios check that a rectangle the log names has ink: the catalog's
stamp; the Full refresh badge and the Tailscale rows, 0041). Screenshots, logs and the proxy log land in --out (CI uploads them). Exit 1 on any
failure. Scenarios are named after the rows of the design's §1 table they cover (X1-X9).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
import time
import traceback
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path[:0] = [str(ROOT / "tools" / "e2e"), str(HERE)]
import bofault  # noqa: E402
import kit  # noqa: E402
from sim import NetworkBootTarget, PROFILES, UI_THEME_BOOKORBIT, SdCard, Simulator, dark_pixels  # noqa: E402

FAULTS = ROOT / "shared" / "fixtures" / "e2e" / "faults"
X4S = ("x4-pro", "x4-classic")
ALL = ("x4-pro", "x4-classic", "x3")


class Context:
    def __init__(self, profile: str, simulator: Simulator, proxy, manifest: dict, artifacts: Path):
        self.profile = profile
        self.sim = simulator
        self.proxy = proxy
        self.manifest = manifest
        self.artifacts = artifacts
        self.books = {b["title"]: b for b in manifest["books"]}
        self.roles = manifest["roles"]

    def card(self, root: Path) -> SdCard:
        return SdCard(root, kit.PROXY, self.manifest["kosync"])

    def book(self, role_or_title: str) -> dict:
        return self.books[self.roles.get(role_or_title, role_or_title)]

    def source(self, role_or_title: str) -> Path:
        return kit.STATE / "library" / self.book(role_or_title)["file"]

    def faults(self, name_or_rules) -> None:
        rules = name_or_rules
        if isinstance(name_or_rules, str):
            rules = json.loads((FAULTS / f"{name_or_rules}.json").read_text())["rules"]
        self.proxy.state.set_rules(rules)

    def requests(self, path: str = "") -> list[dict]:
        with self.proxy.state.lock:
            return [e for e in self.proxy.state.entries if path in e["path"]]


SCENARIOS: dict[str, tuple[tuple[str, ...], object]] = {}


def scenario(*profiles: str):
    def register(fn):
        SCENARIOS[fn.__name__] = (profiles, fn)
        return fn
    return register


def after(output: str, marker: str) -> str:
    assert marker in output, f"missing from the log: {marker!r}"
    return output[output.index(marker):]


def sleep_sync(ctx: Context, card: SdCard, name: str, **kw):
    """Sync on Sleep with the reader on Home: a short Power press sleeps, the sleep sync runs in
    the restarted process, and the device goes back to sleep (the process ends)."""
    state_path = card.crosspoint / "state.json"
    if not state_path.exists() or not json.loads(state_path.read_text()).get("openEpubPath"):
        # The sleep sync needs the last open book, even when the card already has UI state.
        card.open_book(card.add_book(ctx.source("Standalone 01")))
    card.sync_on_sleep()
    run = ctx.sim.run(card, name, script="2500:POWER:120", input_from_poll=True,
                      timeout_s=kw.pop("timeout_s", 90), **kw)
    after(run.output, "Restarting into the BookOrbit sleep sync")
    return run


# --- Scenarios ------------------------------------------------------------------------------------


@scenario(*ALL)
def update_channels(ctx: Context, tmp: Path) -> None:
    """Stored opt-in migration and the real Settings Confirm cycle/save/reload path."""
    for name, settings, expected in (
        ("default", {}, 0),
        ("old-off", {"otaIncludePrereleases": 0}, 0),
        ("old-on", {"otaIncludePrereleases": 1}, 2),
        ("rc-wins", {"otaChannel": 1, "otaIncludePrereleases": 1}, 1),
    ):
        card = ctx.card(tmp / name)
        card.settings.update(settings)
        card.save()
        run = ctx.sim.run(card, name, timeout_s=15, env={"ORBIFY_SIM_UPDATE_CHANNEL_TEST": "1"})
        assert run.returncode == 0
        after(run.output, f"BookSync channel cycle passed (initial={expected})")
        stored = json.loads((card.crosspoint / "crossink-settings.json").read_text())
        assert stored["otaChannel"] == expected
        assert "otaIncludePrereleases" not in stored


@scenario(*ALL)
def sync_through_proxy(ctx: Context, tmp: Path) -> None:
    """Foundation: a manual BookOrbit sync from Home reaches the real server through the proxy and
    uploads the open book's position under the simulator's device id."""
    book = ctx.book("Standalone 03")
    # The server holds an older position from another device, so the sync has one to replace.
    kit.Device().call("PUT", "/syncs/progress", {"document": book["hash"], "progress": "/body/DocFragment[1]/body",
                                                 "percentage": 0.0, "device": "e2e", "device_id": "orbify-e2e-seed"})
    card = ctx.card(tmp)
    path = card.add_book(ctx.source("Standalone 03"))
    card.open_book(path)
    card.progress(path, 3, 0, 1)
    run = ctx.sim.run(card, "sync", script="6000:POWER:120", timeout_s=60, choice="upload",
                      screenshots={5000: f"{ctx.profile}-home"})
    after(run.output, "sync scenario finished")
    puts = [e for e in ctx.requests("/syncs/progress") if e["method"] == "PUT"]
    assert puts and puts[-1]["status"] == 200, f"no accepted progress upload: {puts}"
    remote = kit.Device().call("GET", f"/syncs/progress/{book['hash']}")
    assert "DocFragment[4]" in str(remote.get("progress")), f"the server holds another position: {remote}"


@scenario(*X4S)
def mirror_urls(ctx: Context, tmp: Path) -> None:
    """W30: a persisted request runs on Home; complete base lists, lazy details/covers."""
    card = ctx.card(tmp)
    folder = card.crosspoint / "orbify"
    folder.mkdir(exist_ok=True)
    (folder / "mirror.request").write_text("1\n")
    run = ctx.sim.run(card, "full-home", script="90000:QUIT", timeout_s=105,
                      env={"ORBIFY_SIM_FLASH_ON_CONNECT": "1"})
    after(run.output, "Flash write on internal task stack: orb_catalog")
    after(run.output, "Full refresh: Done")
    assert not (folder / "mirror.request").exists()
    assert (folder / "walk.result").read_text() == "Done"
    lists = ctx.requests("/plugin/catalog/books")
    bad = [e for e in lists if e["status"] != 200 or any(re.search(r"\s\w+=", str(v)) for v in e["query"].values())]
    assert not bad, f"server refused catalog requests: {bad[:3]}"
    assert ctx.requests("/plugin/catalog/manifest"), "no bulk manifest"
    assert all(e["query"].get("size") == "100" for e in lists if e["path"].endswith("/books"))
    details = [e for e in lists if re.search(r"/books/\d+$", e["path"])]
    assert not details, "Full refresh fetched eager details"
    bulk = card.crosspoint / "orbify-catalog" / "bulk"
    generation = (bulk / "active").read_text()
    assert (bulk / generation / "complete").exists()
    assert len(list((bulk / generation / "books").rglob("*.json"))) == len(ctx.manifest["books"])
    assert "open catalog to resume" not in run.output



@scenario("x4-pro")
def full_refresh_large_catalog(ctx: Context, tmp: Path) -> None:
    """Thousands of books through the real worker, HTTP parser and SD adapter.
    The synthetic catalog is independent of the small live server library.
    """
    import os
    import subprocess
    result = subprocess.run(
        [sys.executable, str(ROOT / "xteink/test/bulk_bench.py"), "--checkout",
         str(ctx.sim.program.parents[3]), "--out", str(tmp), "--books", "3000",
         "--modes", "cold", "--timeout", "580"],
        env={**os.environ, "ORBIFY_SIM_FLASH_ON_CONNECT": "1"},
        capture_output=True, text=True, timeout=600)
    ctx.artifacts.mkdir(parents=True, exist_ok=True)
    (ctx.artifacts / "large-catalog.log").write_text(result.stdout + result.stderr)
    import shutil
    if (tmp / "card/cold.log").exists():
        shutil.copy2(tmp / "card/cold.log", ctx.artifacts / "large-catalog-firmware.log")
    assert result.returncode == 0, result.stderr
    stats = json.loads((tmp / "results.json").read_text())[0]
    assert stats["rows"] == 3000 and stats["psramPeakBytes"] < 1024 * 1024
    after((tmp / "card/cold.log").read_text(), "Flash write on internal task stack: orb_catalog")


@scenario(*X4S)
def full_refresh_crash_breaker(ctx: Context, tmp: Path) -> None:
    """Two unclean worker exits across cold boots must never start a third.
    Keep settings, books and the published catalog; an explicit hold retries.
    """
    card = ctx.card(tmp)
    card.theme(UI_THEME_BOOKORBIT)
    folder = card.crosspoint / "orbify"
    folder.mkdir(exist_ok=True)
    (folder / "mirror.request").write_text("1\n")
    # No usable catalog is required for this safety boundary. Preserve arbitrary
    # published bytes and books without parsing or deleting them in recovery.
    published = card.crosspoint / "orbify-catalog" / "bulk" / "a" / "books" / "1.json"
    published.parent.mkdir(parents=True)
    published.write_text('{"id":1,"title":"kept"}')
    (published.parents[2] / "stage").write_text("b")
    path = card.add_book(ctx.source("Standalone 01"))
    book_bytes = (card.fs / path.lstrip("/")).read_bytes()
    credentials = (card.crosspoint / "bookorbit.json").read_bytes()
    before = len(ctx.requests())
    for attempt in (1, 2):
        run = ctx.sim.run(card, f"crash-{attempt}", timeout_s=15,
                          env={**SDFAT, "ORBIFY_SIM_CRASH_REFRESH": "1"},
                          boot_target=(NetworkBootTarget.HOME_REFRESH if attempt == 1 else NetworkBootTarget.CATALOG))
        after(run.output, f"Minimal network boot ready: target={36 if attempt == 1 else 35}")
        assert run.returncode == 86, f"worker did not reach injected crash: {run.returncode}"
        assert (folder / "refresh.inflight").read_text() == str(attempt)
        assert (folder / "mirror.request").exists()
    # Leave the fault enabled: a third worker would immediately kill the process.
    recovery_logs = []
    for name in ("recovered", "normal-boot-1", "normal-boot-2", "normal-boot-3"):
        run = ctx.sim.run(card, name, script="6000:QUIT", timeout_s=15,
                          env={"ORBIFY_SIM_CRASH_REFRESH": "1"})
        assert run.returncode == 0
        recovery_logs.append(run.output)
        after(run.output, "Entering activity: Home")
        assert not (folder / "mirror.request").exists()
        assert (folder / "mirror.request.crashed").exists()
        assert not (published.parents[2] / "stage").exists()
    assert "\n".join(recovery_logs).count("crash breaker stopped automatic resume") == 1
    assert not (folder / "refresh.inflight").exists()
    assert not (folder / "refresh-boot.inflight").exists()
    assert len(ctx.requests()) == before, "recovery restarted network work"
    assert published.read_text() == '{"id":1,"title":"kept"}'
    assert (card.fs / path.lstrip("/")).read_bytes() == book_bytes
    assert (card.crosspoint / "bookorbit.json").read_bytes() == credentials
    if ctx.profile == "x4-pro":
        x, y = home_tile(run.output, "sync")
        # Interrupt a legitimate new Full refresh. It gets a fresh allowance,
        # and the following cold boot must resume instead of quarantining it.
        interrupted = ctx.sim.run(card, "explicit-interrupted", script=f"3000:TAP:{x},{y},1300", timeout_s=30,
                                  env={"ORBIFY_SIM_CRASH_REFRESH": "1"})
        assert interrupted.returncode == 86
        assert (folder / "refresh.inflight").read_text() == "1"
        assert not (folder / "refresh-boot.inflight").exists()
        assert not (folder / "mirror.request.crashed").exists()
        retry = ctx.sim.run(card, "explicit-resumed", timeout_s=100,
                            env={"ORBIFY_SIM_QUIT_BULK_DONE": "1", "ORBIFY_SIM_FLASH_ON_CONNECT": "1"})
        assert "crash breaker stopped automatic resume" not in retry.output
        assert "early-boot breaker disabled" not in retry.output
        after(retry.output, "Full refresh: Done")
        assert retry.returncode == 0
        assert not (folder / "refresh.inflight").exists()
        assert not (folder / "mirror.request.crashed").exists()


# PR #190's host stub and simulator both accepted mkdir(existing), whereas
# SdFat rejects it. Exercise that device contract AND setup's real RTC targets.
SDFAT = {"ORBIFY_SIM_SDFAT_MKDIR": "1"}


def quarantined_refresh_card(ctx: Context, tmp: Path):
    card = ctx.card(tmp)
    card.theme(UI_THEME_BOOKORBIT)
    folder = card.crosspoint / "orbify"
    folder.mkdir(exist_ok=True)
    (folder / "mirror.request").write_text("1\n")
    (folder / "refresh.inflight").write_text("2")
    (folder / "refresh-boot.inflight").write_text("2")
    path = card.add_book(ctx.source("Standalone 01"))
    before = (card.fs / path.lstrip("/")).read_bytes()
    credentials = (card.crosspoint / "bookorbit.json").read_bytes()
    run = ctx.sim.run(card, "quarantined", script="3000:QUIT", timeout_s=10, env=SDFAT)
    assert run.returncode == 0
    after(run.output, "crash breaker stopped automatic resume")
    assert (folder / "mirror.request.crashed").exists()
    assert not (folder / "mirror.request").exists()
    return card, folder, run, path, before, credentials


def assert_refresh_completed(ctx: Context, card: SdCard, folder: Path, output: str) -> None:
    assert "crash breaker stopped automatic resume" not in output
    assert "early-boot breaker disabled" not in output
    after(output, "Full refresh: Done")
    assert not (folder / "mirror.request").exists()
    assert not (folder / "mirror.request.crashed").exists()
    assert not (folder / "refresh.inflight").exists()
    assert not (folder / "refresh-boot.inflight").exists()
    assert (folder / "walk.result").read_text() == "Done"
    bulk = card.crosspoint / "orbify-catalog/bulk"
    generation = (bulk / "active").read_text()
    assert (bulk / generation / "complete").exists()
    assert len(list((bulk / generation / "books").rglob("*.json"))) == len(ctx.manifest["books"])


def full_refresh_network_entry(ctx: Context, tmp: Path, entry: str) -> None:
    card, folder, home, book, before, credentials = quarantined_refresh_card(ctx, tmp)
    ctx.faults([{"match": {"path": "/plugin/catalog/"}, "action": "delay", "ms": 400}])
    env = {**SDFAT, "ORBIFY_SIM_QUIT_BULK_DONE": "1"}
    if entry == "sync":
        if ctx.profile == "x4-pro":
            x, y = home_tile(home.output, "sync")
            script = f"3000:TAP:{x},{y},1300"
        else:
            script = "3000:DOWN:120;4500:CONFIRM:1300"
        run = ctx.sim.run(card, "sync-hold", script=script, after_reboot="", timeout_s=100, env=env)
        after(run.output, "Home: Full refresh asked for from the sync tile")
        after(run.output, "Minimal network boot ready: target=36")
    elif entry == "catalog":
        # Open the catalog's real network boot, then use its actual header
        # control; button readers focus the same control by pressing Up.
        opened = ctx.sim.run(card, "catalog-network", script="6000:QUIT", timeout_s=15,
                             boot_target=NetworkBootTarget.CATALOG, env=SDFAT)
        after(opened.output, "Minimal network boot ready: target=35")
        if ctx.profile == "x4-pro":
            stamp = STAMP.search(opened.output)
            assert stamp, "catalog did not expose its refresh control"
            script = f"6000:TAP:{stamp.group(7)},{stamp.group(8)},1300"
        else:
            script = "6000:UP:120;7500:CONFIRM:1300"
        run = ctx.sim.run(card, "catalog-hold", script=script, timeout_s=100,
                          boot_target=NetworkBootTarget.CATALOG, env=env)
        after(run.output, "Minimal network boot ready: target=35")
        after(run.output, "Catalog: Full refresh of view")
    else:
        # This real boot opens Settings > BookOrbit > Home with Refresh
        # selected. Down selects the Full refresh row; Confirm activates it.
        run = ctx.sim.run(card, "settings-row", script="10000:DOWN:120;11500:CONFIRM:120",
                          boot_target=NetworkBootTarget.HOME_SHELVES, after_reboot="",
                          timeout_s=110, env=env)
        after(run.output, "Minimal network boot ready: target=37")
        after(run.output, "Entering activity: BookOrbitSettings")
        after(run.output, "Minimal network boot ready: target=36")
    assert run.returncode == 0
    assert_refresh_completed(ctx, card, folder, run.output)
    # A moving on-screen percentage, rather than only a worker success log.
    percentages = [int(p) for p in re.findall(r"Full refresh badge '(\d+)%'", run.output)]
    assert any(0 < p < 100 for p in percentages), f"no visible progress: {percentages}"
    assert (card.fs / book.lstrip("/")).read_bytes() == before
    assert (card.crosspoint / "bookorbit.json").read_bytes() == credentials


@scenario(*X4S)
def full_refresh_quarantine_sync_network(ctx: Context, tmp: Path) -> None:
    full_refresh_network_entry(ctx, tmp, "sync")


@scenario(*X4S)
def full_refresh_quarantine_catalog_network(ctx: Context, tmp: Path) -> None:
    full_refresh_network_entry(ctx, tmp, "catalog")


@scenario(*X4S)
def full_refresh_quarantine_settings_network(ctx: Context, tmp: Path) -> None:
    full_refresh_network_entry(ctx, tmp, "settings")


@scenario(*X4S)
def full_refresh_network_restart_and_sleep(ctx: Context, tmp: Path) -> None:
    card, folder, home, *_ = quarantined_refresh_card(ctx, tmp)
    # Begin real work, then cancel back to Home while its first manifest is
    # delayed. The orderly restart drains that worker. Low heap after Wi-Fi
    # keeps the request pending on Home and through the sleep-sync boot.
    ctx.faults([{"match": {"path": "/plugin/catalog/manifest$"}, "action": "delay", "ms": 4000, "times": 1}])
    tight = {**SDFAT, "ORBIFY_SIM_HEAP": "w1000:10000/6000"}
    if ctx.profile == "x4-pro":
        x, y = home_tile(home.output, "sync")
        script = f"3000:TAP:{x},{y},1300"
    else:
        script = "3000:DOWN:120;4500:CONFIRM:1300"
    paused = ctx.sim.run(card, "requested-network-restart", script=script,
                         after_reboot="1000:BACK:120", timeout_s=18, env=tight)
    after(paused.output, "Minimal network boot ready: target=36")
    after(paused.output, "Home refresh: Full refresh continues in background")
    after(after(paused.output, "Home refresh: Full refresh continues in background"), "Entering activity: Home")
    assert "crash breaker" not in paused.output
    assert not (folder / "refresh.inflight").exists()
    assert (folder / "mirror.request").exists()
    assert not (folder / "mirror.request.crashed").exists()
    assert not (folder / "refresh-boot.inflight").exists()
    # The resumed partial catalog can finish in under a second. Apply the
    # floor from boot here so it stays pending until the sleep-sync target,
    # rather than racing the worker against the scripted Power press.
    slept = sleep_sync(ctx, card, "requested-sleep",
                       env={**SDFAT, "ORBIFY_SIM_HEAP": "0:10000/6000"})
    after(slept.output, "Minimal network boot ready: target=33")
    assert slept.returncode == 0
    assert (folder / "mirror.request").exists()
    assert not (folder / "refresh-boot.inflight").exists()
    ctx.faults([{"match": {"path": "/plugin/catalog/"}, "action": "delay", "ms": 400}])
    resumed = ctx.sim.run(card, "resumed-home-network", boot_target=NetworkBootTarget.HOME_REFRESH,
                          timeout_s=100, env={**SDFAT, "ORBIFY_SIM_QUIT_BULK_DONE": "1"})
    after(resumed.output, "Minimal network boot ready: target=36")
    assert resumed.returncode == 0
    assert_refresh_completed(ctx, card, folder, resumed.output)


@scenario(*X4S)
def full_refresh_marker_io_is_not_crash(ctx: Context, tmp: Path) -> None:
    card = ctx.card(tmp)
    folder = card.crosspoint / "orbify"
    folder.mkdir(exist_ok=True)
    (folder / "mirror.request").write_text("1\n")
    built = ctx.sim.run(card, "io-seed", timeout_s=100,
                        env={**SDFAT, "ORBIFY_SIM_QUIT_BULK_DONE": "1"})
    assert built.returncode == 0
    bulk = card.crosspoint / "orbify-catalog/bulk"
    pointer = (bulk / "active").read_bytes()
    (folder / "mirror.request").write_text("1\n")
    for boot in range(3):
        failed = ctx.sim.run(card, f"io-unavailable-{boot}", script="5000:QUIT", timeout_s=15,
                             boot_target=NetworkBootTarget.HOME_REFRESH,
                             env={**SDFAT, "ORBIFY_SIM_MARKER_IO_ERROR": "1"})
        assert failed.returncode == 0
        after(failed.output, "cannot save boot marker; request and saved catalog kept")
        after(failed.output, "cannot save worker marker; request retained")
        assert "crash breaker" not in failed.output
        assert (bulk / "active").read_bytes() == pointer
        assert (folder / "mirror.request").exists()
        assert not (folder / "mirror.request.crashed").exists()
        assert not (folder / "refresh.inflight").exists()
        assert not (folder / "refresh-boot.inflight").exists()
    resumed = ctx.sim.run(card, "io-restored", timeout_s=100,
                          boot_target=NetworkBootTarget.HOME_REFRESH,
                          env={**SDFAT, "ORBIFY_SIM_QUIT_BULK_DONE": "1"})
    assert resumed.returncode == 0
    assert_refresh_completed(ctx, card, folder, resumed.output)


@scenario("x4-pro")
def normal_refresh_after_quarantine(ctx: Context, tmp: Path) -> None:
    """A tap repairs both retained and disabled bulk catalogs and retires the banner."""
    for disable_pointer in (False, True):
        card = ctx.card(tmp / ("no-active" if disable_pointer else "active"))
        card.theme(UI_THEME_BOOKORBIT)
        folder = card.crosspoint / "orbify"
        folder.mkdir(exist_ok=True)
        (folder / "mirror.request").write_text("1\n")
        built = ctx.sim.run(card, f"seed-{disable_pointer}", timeout_s=100,
                            env={"ORBIFY_SIM_QUIT_BULK_DONE": "1"})
        assert built.returncode == 0
        bulk = card.crosspoint / "orbify-catalog" / "bulk"
        assert (bulk / "active").exists()
        (folder / "mirror.request").write_text("1\n")
        (folder / ("refresh-boot.inflight" if disable_pointer else "refresh.inflight")).write_text("2")
        recovered = ctx.sim.run(card, f"quarantine-{disable_pointer}", script="6000:QUIT", timeout_s=15,
                                screenshots={5000: f"warning-{disable_pointer}"})
        assert recovered.returncode == 0
        assert (folder / "mirror.request.crashed").read_text() == (
            "Refresh stopped after a crash. Run Full refresh to rebuild.")
        after(recovered.output, "BookOrbit Home: refresh stopped: Refresh stopped after a crash.")
        assert (bulk / "active").exists() != disable_pointer
        x, y = home_tile(recovered.output, "sync")
        if not disable_pointer:
            # A repair keeps CRASHED until success, but must still resume and
            # count actual crashes rather than resetting its allowance at boot.
            interrupted = ctx.sim.run(card, "normal-repair-crash-1", script=f"3000:TAP:{x},{y},100",
                                      timeout_s=30, env={"ORBIFY_SIM_CRASH_REFRESH": "1"})
            assert interrupted.returncode == 86
            assert (folder / "refresh.inflight").read_text() == "1"
            interrupted = ctx.sim.run(card, "normal-repair-crash-2", timeout_s=15,
                                      env={"ORBIFY_SIM_CRASH_REFRESH": "1"})
            assert interrupted.returncode == 86
            assert (folder / "refresh.inflight").read_text() == "2"
            stopped = ctx.sim.run(card, "normal-repair-stopped", script="6000:QUIT", timeout_s=15,
                                  env={"ORBIFY_SIM_CRASH_REFRESH": "1"})
            assert stopped.returncode == 0
            assert stopped.output.count("crash breaker stopped automatic resume") == 1
            assert not (folder / "mirror.request").exists()
        refreshed = ctx.sim.run(card, f"normal-refresh-{disable_pointer}",
                                script=f"3000:TAP:{x},{y},100", timeout_s=100,
                                env={"ORBIFY_SIM_QUIT_BULK_DONE": "1"}, quit_after_sync=False)
        assert refreshed.returncode == 0
        after(refreshed.output, "Bulk catalog: ok=1")
        assert "Full refresh asked for" not in refreshed.output
        assert (bulk / "active").exists()
        assert not (folder / "mirror.request.crashed").exists()
        assert not (folder / "refresh.inflight").exists()
        settled = ctx.sim.run(card, f"repaired-boot-{disable_pointer}", script="6000:QUIT", timeout_s=15,
                              env={"ORBIFY_SIM_CRASH_REFRESH": "1"},
                              screenshots={5000: f"repaired-{disable_pointer}"})
        assert settled.returncode == 0
        assert "crash breaker stopped automatic resume" not in settled.output
        assert "BookOrbit Home: refresh stopped:" not in settled.output
        assert not (folder / "mirror.request.crashed").exists()


@scenario(*X4S)
def full_refresh_sd_card_recovery(ctx: Context, tmp: Path) -> None:
    """The recovery instruction cancels the persisted job without wiping settings."""
    card = ctx.card(tmp)
    folder = card.crosspoint / "orbify"
    folder.mkdir(exist_ok=True)
    (folder / "mirror.request").write_text("1\n")
    first = ctx.sim.run(card, "crashed", timeout_s=15,
                        env={"ORBIFY_SIM_CRASH_REFRESH": "1"})
    assert first.returncode == 86
    # The sole card-reader operation prescribed for the installed firmware.
    (folder / "mirror.request").unlink()
    before = len(ctx.requests())
    recovered = ctx.sim.run(card, "sd-recovered", script="6000:QUIT", timeout_s=15,
                            env={"ORBIFY_SIM_CRASH_REFRESH": "1"})
    assert recovered.returncode == 0
    after(recovered.output, "Entering activity: Home")
    assert len(ctx.requests()) == before


@scenario(*X4S)
def full_refresh_early_boot_breaker(ctx: Context, tmp: Path) -> None:
    """A setup crash while refresh state exists must be broken before cache reads."""
    card = ctx.card(tmp)
    folder = card.crosspoint / "orbify"
    folder.mkdir(exist_ok=True)
    (folder / "mirror.request").write_text("1\n")
    bulk = card.crosspoint / "orbify-catalog" / "bulk"
    bulk.mkdir(parents=True)
    (bulk / "active").write_text("a")
    (bulk / "active.bak").write_text("b")
    saved = bulk / "a" / "books" / "1.json"
    saved.parent.mkdir(parents=True)
    saved.write_text("interrupted cache bytes")
    credentials = (card.crosspoint / "bookorbit.json").read_bytes()
    before = len(ctx.requests())
    for attempt in (1, 2):
        run = ctx.sim.run(card, f"early-crash-{attempt}", timeout_s=15,
                          env={**SDFAT, "ORBIFY_SIM_CRASH_REFRESH_BOOT": "1"},
                          boot_target=NetworkBootTarget.HOME_REFRESH)
        assert run.returncode == 88
        assert (folder / "refresh-boot.inflight").read_text() == str(attempt)
    run = ctx.sim.run(card, "early-recovered", script="6000:QUIT", timeout_s=15,
                      env={"ORBIFY_SIM_CRASH_REFRESH_BOOT": "1"})
    assert run.returncode == 0
    after(run.output, "early-boot breaker disabled saved catalog pointer")
    after(run.output, "Entering activity: Home")
    assert not (bulk / "active").exists() and not (bulk / "active.bak").exists()
    pointer = bulk / "active.crashed"
    assert pointer.read_text() == "a"
    pointer_stat = pointer.stat()
    logs = [run.output]
    # Upgrade from the old firmware's settled warning plus exhausted markers.
    (folder / "refresh-boot.inflight").write_text("2")
    (folder / "refresh.inflight").write_text("2")
    for boot in range(3):
        settled = ctx.sim.run(card, f"settled-{boot}", script="6000:QUIT", timeout_s=15,
                              env={"ORBIFY_SIM_CRASH_REFRESH": "1"})
        assert settled.returncode == 0
        logs.append(settled.output)
        assert not (folder / "refresh-boot.inflight").exists()
        assert pointer.stat().st_mtime_ns == pointer_stat.st_mtime_ns
        assert pointer.stat().st_ino == pointer_stat.st_ino
    combined = "\n".join(logs)
    assert combined.count("crash breaker stopped automatic resume") == 1
    assert combined.count("early-boot breaker disabled saved catalog pointer") == 1
    assert saved.read_text() == "interrupted cache bytes"
    assert not (folder / "refresh-boot.inflight").exists()
    assert len(ctx.requests()) == before
    assert (card.crosspoint / "bookorbit.json").read_bytes() == credentials


@scenario("x4-pro")
def full_refresh_offline_last_pages(ctx: Context, tmp: Path) -> None:
    """Full refresh on Home; SD-only facet page 2, book page 3 and lazy file information."""
    import shutil
    card = ctx.card(tmp)
    cx, cy, _, _ = open_catalog(ctx, card)
    live = kit.Device().call("GET", "/plugin/catalog/sections/series")["items"][0]
    entries = [{**live, "id": f"W9 series {n:02}", "title": f"W9 series {n:02}"} for n in range(23)]
    ctx.faults([
        {"match": {"path": "/plugin/catalog/sections/series$", "query": {"page": "^2$"}},
         "action": "status", "status": 200, "body": json.dumps({"items": entries[20:], "page": 2, "total": 23, "size": 20, "hasNext": False})},
        {"match": {"path": "/plugin/catalog/sections/series$"}, "action": "status", "status": 200,
         "body": json.dumps({"items": entries[:20], "page": 1, "total": 23, "size": 20, "hasNext": True})}])
    folder = card.crosspoint / "orbify"
    folder.mkdir(exist_ok=True)
    (folder / "mirror.request").write_text("1\n")
    full = ctx.sim.run(card, "full-home", script="90000:QUIT", timeout_s=105)
    after(full.output, "Full refresh: Done")
    saved = []
    by_id = {b["id"]: b for b in ctx.manifest["books"]}
    bulk = card.crosspoint / "orbify-catalog" / "bulk"
    generation = (bulk / "active").read_text()
    for file in (bulk / generation / "books").rglob("*.json"):
        body = json.loads(file.read_text())
        if not isinstance(body, dict) or body.get("id") not in by_id:
            continue
        for edition in body.get("files", []):
            if edition.get("format") != "epub" or not edition.get("devicePath"):
                continue
            target = str(edition["devicePath"]).lstrip("/")
            dest = card.fs / target
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(kit.STATE / "library" / by_id[body["id"]]["file"], dest)
            saved.append((body["id"], "/" + target))
            break
    assert len(saved) == len(by_id), "a Full refresh left manifest files unsaved"
    card.download_index(saved)
    before = len(ctx.requests())
    ctx.faults("offline")
    downs = lambda at, count: ";".join(f"{at + n * 240}:DOWN:100" for n in range(count))
    script = (f"3000:SWIPE:0.8,0.5,0.2,0.5,250;4500:TAP:{cx},{cy};" + downs(6000, 6) +
              ";7800:CONFIRM:100;" + downs(8500, 22) + ";14500:BACK:100;15000:DOWN:100;15500:CONFIRM:100;" +
              downs(16500, 58) + ";31000:CONFIRM:100;38000:QUIT")
    offline = ctx.sim.run(card, "offline-scroll-and-open", script=script, timeout_s=45)
    after(offline.output, "Listing page 2")
    after(offline.output, "Listing page 3")
    assert "[WIFI] Joined" not in offline.output and "Joining saved network" not in offline.output
    assert not ctx.requests()[before:], "saved navigation made network requests"
    samples = [int(n) for n in re.findall(r"Heap after saved catalog window: internal free=(\d+)", offline.output)]
    assert len(samples) >= 4, f"too few offline heap samples: {samples}"
    assert min(samples) >= 60 * 1024, f"offline browsing crossed the Wi-Fi heap reserve: {samples}"
    assert samples[-1] >= samples[0] - 16 * 1024, f"page browsing retained internal heap: {samples}"
    after(offline.output, "Entering activity: EpubReader")


@scenario("x4-pro")
def partial_refresh_keeps_saved_pages(ctx: Context, tmp: Path) -> None:
    """Budget-stop before the first completed mirror still opens saved pages without Wi-Fi."""
    card = ctx.card(tmp)
    card.theme(UI_THEME_BOOKORBIT)
    sx, sy = home_tile(ctx.sim.run(card, "home", script="2500:QUIT", timeout_s=8).output, "sync")
    ctx.sim.run(card, "seed", script=f"3000:TAP:{sx},{sy}", timeout_s=30)
    library = ctx.sim.run(card, "library", script="3000:SWIPE:0.8,0.5,0.2,0.5,250;5000:QUIT", timeout_s=9)
    cx, cy = home_tile(library.output, "catalog")
    # Save an actual browse page before the new atomic bulk run is interrupted.
    # Home's snapshot alone is not a previously published catalog generation.
    ctx.sim.run(card,"saved-before-partial",script=f"3000:SWIPE:0.8,0.5,0.2,0.5,250;4500:TAP:{cx},{cy};6000:DOWN:100;6500:CONFIRM:100;12000:QUIT",timeout_s=18)
    folder = card.crosspoint / "orbify"
    folder.mkdir(exist_ok=True)
    (folder / "mirror.request").write_text("1\n")
    stopped = ctx.sim.run(card, "partial", script="9000:QUIT", timeout_s=15,
                          env={"ORBIFY_SIM_SD_FULL_AFTER": "6"})
    after(stopped.output, "Stopped at SD card full")
    assert not (folder / "mirror.state").exists(), "a partial run claimed a completed mirror"
    assert not (folder / "mirror.request").exists()
    before = len(ctx.requests())
    ctx.faults("offline")
    opened = ctx.sim.run(card, "saved-partial", script=f"3000:SWIPE:0.8,0.5,0.2,0.5,250;4500:TAP:{cx},{cy};"
                          "6000:DOWN:100;6500:CONFIRM:100;10000:QUIT", timeout_s=16)
    after(opened.output, "Catalog: opening from the cache, no Wi-Fi")
    after(opened.output, "Listing page 1")
    assert "Joining saved network" not in opened.output and not ctx.requests()[before:]


@scenario(*X4S)
def full_refresh_while_reading(ctx: Context, tmp: Path) -> None:
    """The worker completes beside reader page turns without notices or a 100 ms UI stall."""
    card = ctx.card(tmp)
    path = card.add_book(ctx.source("Standalone 03"))
    card.download_index([(ctx.book("Standalone 03")["id"], path)])
    card.open_book(path, asleep=True)
    folder = card.crosspoint / "orbify"
    folder.mkdir(exist_ok=True)
    (folder / "mirror.request").write_text("1\n")
    ctx.faults([{"match": {"path": "/plugin/catalog/"}, "action": "delay", "ms": 150}])
    run = ctx.sim.run(card, "reading", script="3000:RIGHT:100;5000:RIGHT:100;90000:QUIT", timeout_s=105, wake=True)
    reader = after(run.output, "Entering activity: EpubReader")
    after(reader, "Full refresh: Done")
    renders = [int(t) for t in re.findall(r"Page render ms: .* total=(\d+)", reader)]
    assert len(renders) >= 3 and max(renders) < 100, f"reader page renders during refresh: {renders}"
    assert "Full refresh popup" not in reader and "Entering activity: BookOrbitCatalogBrowser" not in reader
    loops = [int(n) for n in re.findall(r"New max loop duration: (\d+) ms", reader)]
    assert not loops or max(loops) < 100, f"main-loop stalls while refreshing: {loops}"


@scenario(*X4S)
def full_refresh_sd_full(ctx: Context, tmp: Path) -> None:
    """A low-card-space report is terminal and never loops on the next main-loop turn."""
    card = ctx.card(tmp)
    folder = card.crosspoint / "orbify"
    folder.mkdir(exist_ok=True)
    (folder / "mirror.request").write_text("1\n")
    run = ctx.sim.run(card, "sd-full", script="7000:QUIT", timeout_s=12,
                      env={"ORBIFY_SIM_SD_FREE_BYTES": str(16 * 1024 * 1024 - 1)})
    after(run.output, "Stopped at SD card full")
    assert not (folder / "mirror.request").exists()
    assert (folder / "walk.result").read_text().startswith("Stopped at SD card full")
    assert not ctx.requests(), "SD-full refresh requested catalog data"
    before = len(ctx.requests())
    second = ctx.sim.run(card, "after-stop", script="4000:QUIT", timeout_s=8)
    assert not ctx.requests()[before:] and "Wi-Fi up reason=refresh" not in second.output


def stale_copy_on_card(ctx: Context, card: SdCard, role: str) -> tuple[str, str]:
    """BookOrbit rewrites the book's file; the card keeps the library's original, downloaded from
    the catalog (in the download index). Returns (card path, the server's new hash)."""
    changed = kit.rewrite(role)
    path = card.add_book(ctx.source(role))
    card.download_index([(changed["id"], path)])
    return path, changed["new_hash"]


@scenario(*ALL)
def copy_refresh_sleep_sync(ctx: Context, tmp: Path) -> None:
    """X6: the sleep sync finds a copy the server rewrote (match check) and replaces it in place
    with the library's file."""
    card = ctx.card(tmp)
    path, new_hash = stale_copy_on_card(ctx, card, "copy_refresh")
    run = sleep_sync(ctx, card, "sleep")
    after(run.output, "is an older copy of book")
    after(run.output, "replaced")
    on_card = kit.partial_md5((card.fs / path.lstrip("/")).read_bytes())
    assert on_card == new_hash, f"the card holds {on_card}, the library {new_hash}"


@scenario(*X4S)
def copy_refresh_tight_heap(ctx: Context, tmp: Path) -> None:
    """X6 on the heap an X4 Pro has beside Tailscale (the shared-session heap floor): 39 KB free with a 20 KB
    largest block. The sync's TLS needed a 24 KB block and refused the match check; the X4s now
    need 8 KB (their large buffers are in PSRAM), and the refresh rides the sync's connection."""
    card = ctx.card(tmp)
    path, new_hash = stale_copy_on_card(ctx, card, "copy_refresh_open")
    run = sleep_sync(ctx, card, "sleep", env={"ORBIFY_SIM_HEAP": "w0:39000/20000"})
    assert "Copy refresh: match check failed" not in run.output, "the match check did not fit the heap"
    after(run.output, "replaced")
    on_card = kit.partial_md5((card.fs / path.lstrip("/")).read_bytes())
    assert on_card == new_hash, f"the card holds {on_card}, the library {new_hash}"


@scenario(*X4S)
def sleep_sync_device_heap(ctx: Context, tmp: Path) -> None:
    """X3/X6 on the heap the X4 Pro's sleep sync had on .167: 21 KB of internal RAM free with a 7 KB
    largest block once Tailscale is up. Before the TLS PSRAM hook the match check's reply was refused (match check failed (8)), the copy stopped as heap
    starved and covers were deferred. With wolfSSL in PSRAM the X4s' floors count only what a
    request still needs of internal RAM (12 KB beside a kept session, 8 KB while a transfer runs)
    and a reply of 4 KB or more is measured against PSRAM: the copy check, the copy's download
    (1 KB chunks to SD) and the covers all complete. The internal RAM wolfSSL no longer takes is
    the device's to confirm (log lines in XTEINK-BUILD-NOTES.md), and so is the 15 KB dip the .167
    transfer starved at: the simulator opens a new session per request where the device keeps one,
    so it applies the 20 KB new-session floor there, not the 8 KB transfer floor."""
    card = ctx.card(tmp)
    card.theme(UI_THEME_BOOKORBIT)  # the sleep sync refreshes the BookOrbit Home and its covers
    path, new_hash = stale_copy_on_card(ctx, card, "copy_refresh_open")
    run = sleep_sync(ctx, card, "sleep", timeout_s=150,
                     env={"ORBIFY_SIM_HEAP": "w0:21376/7156"})
    after(run.output, "ORBIFY_SIM_HEAP t=w0 free=21376 largest=7156")
    covers = re.search(r"covers: (\d+) needed, (\d+) on SD, (\d+) fetched", run.output)
    assert covers, "the sleep sync did not refresh the Home's covers"
    for refused in ("Copy refresh: match check failed", "heap starved", "waiting for heap", "deferred (heap",
                    "Leaving the Home snapshot for the next sync"):
        assert refused not in run.output, f"refused on the device's heap: {refused!r}"
    after(run.output, "replaced")
    after(run.output, "Sleep sync over")
    on_card = kit.partial_md5((card.fs / path.lstrip("/")).read_bytes())
    assert on_card == new_hash, f"the card holds {on_card}, the library {new_hash}"


@scenario(*X4S)
def heap_floor_waits(ctx: Context, tmp: Path) -> None:
    """X3: the sleep sync's extras start no request when the heap is under the floor (OrbifyHeap): the heap falls to 10 KB (under the X4s' 12 KB floor) while the
    bulk worker's first request is held by the proxy; the mirror then waits for the next sync instead of
    opening another request."""
    card = ctx.card(tmp)
    (card.crosspoint / "orbify").mkdir(exist_ok=True)
    (card.crosspoint / "orbify" / "mirror.request").write_text("1\n")  # resume a user-started walk
    ctx.faults([{"match": {"path": "/plugin/catalog/manifest$"}, "action": "delay", "ms": 4000, "times": 1}])
    run = ctx.sim.run(card, "home-low-heap", script="9000:QUIT", timeout_s=15, env={"ORBIFY_SIM_HEAP": "w2000:10000/6000"})
    tail = after(run.output, "ORBIFY_SIM_HEAP t=w2000")
    after(tail, "waiting for heap")
    root = ctx.requests("/plugin/catalog/manifest")
    assert root, "the mirror never started"
    later = [e for e in ctx.requests("/plugin/catalog/") if e["t"] > root[0]["t"]]
    assert not later, f"requests opened under the floor: {[e['path'] for e in later][:5]}"


@scenario(*X4S)
def next_cover_heap_floor(ctx: Context, tmp: Path) -> None:
    """X9: the End-of-Book page's next cover. A sync on its own connection fetches it only with
    42 KB free and a 20 KB block on the X3, 20 KB and 4 KB on the X4s (wolfSSL in PSRAM);
    under that it is left for the next sync. The sleep sync then fetches it on the connection it lends and decodes it with the radio
    off."""
    card = ctx.card(tmp)
    path = card.add_book(ctx.source("eob_series_middle"))
    card.download_index([(ctx.book("eob_series_middle")["id"], path)])
    card.open_book(path)
    card.progress(path, 4, 0, 1)
    tight = ctx.sim.run(card, "sync-tight", script="3000:POWER:120", timeout_s=60, choice="upload",
                        env={"ORBIFY_SIM_HEAP": "w0:20200/30000"})
    after(tight.output, "Series card")
    after(tight.output, "Next cover: left for the next sync")
    roomy = sleep_sync(ctx, card, "sleep")
    fetched = re.search(r"Next cover: book (\d+) fetched, decodes with the radio off", roomy.output)
    assert fetched, "the sleep sync did not fetch the next cover"
    after(roomy.output[fetched.end():], f"Next cover: book {fetched.group(1)} decoded")


def open_at_end(ctx: Context, card: SdCard, title: str) -> str:
    path = card.add_book(ctx.source(title))
    card.download_index([(ctx.book(title)["id"], path)])  # from the catalog: the page knows its book
    card.open_book(path, asleep=True)
    card.progress(path, 4, 999, 1000)  # past the last chapter's last page: the reader opens on its last page
    return path


@scenario(*ALL)
def eob_page_finish(ctx: Context, tmp: Path) -> None:
    """X7 and the finish queue: the turn past the last page shows the End-of-Book page and queues
    the book as finished; the next sync drains the queue and the server has the book read. Two
    paths are right: the drain marks it (read-status), or the sync's 100% progress already did
    and the drain's guard, reading the book first, finds it read (a server with no earlier
    position for the book, as in CI)."""
    card = ctx.card(tmp)
    open_at_end(ctx, card, "eob_standalone")
    run = ctx.sim.run(card, "end", script="3000:RIGHT:120;6000:QUIT", timeout_s=30, wake=True,
                      screenshots={5000: f"{ctx.profile}-end-page"})
    page = after(run.output, "[ORB] End page: ")
    after(page, "Finish: ")
    after(page, "queued (book")
    sync = ctx.sim.run(card, "sync", script="3000:POWER:120", timeout_s=60, choice="upload")
    drained = re.search(r"Finish drain \w+: (\w+)", sync.output)
    assert drained and drained.group(1) == "sent", f"the queue was not drained: {drained and drained.group(0)}"
    book_id = ctx.book("eob_standalone")["id"]
    guard = [e for e in ctx.requests(f"/plugin/catalog/books/{book_id}") if e["method"] == "GET"]
    assert guard, "the drain sent without reading the book first (its guard)"
    detail = kit.Device().call("GET", f"/plugin/catalog/books/{book_id}")
    assert detail.get("readStatus") == "read", f"the server does not have it read: {detail.get('readStatus')}"


@scenario("x4-pro")
def eob_series_home_swipe(ctx: Context, tmp: Path) -> None:
    """X7 (the series card and Home swipe): the page of a series' middle book carries the series line from the card
    a sync stored, and the bottom-edge swipe up leaves it for Home."""
    card = ctx.card(tmp)
    path = open_at_end(ctx, card, "eob_series_middle")
    card.open_book(path)
    sync = ctx.sim.run(card, "sync", script="3000:POWER:120", timeout_s=60, choice="upload")
    after(sync.output, "series 'Harbor Lights' #2 (")
    card.open_book(path, asleep=True)
    run = ctx.sim.run(card, "end", script="3000:RIGHT:120;6000:SWIPE:0.5,0.995,0.5,0.55,300;9000:QUIT",
                      timeout_s=30, wake=True, screenshots={5000: "x4-pro-end-page-series", 8000: "x4-pro-after-swipe"})
    drawn = re.search(r"End page: (not )?finished, card (\w+)", run.output)
    assert drawn, "the End-of-Book page was not drawn"
    assert drawn.group(2) == "yes", f"the page has no series card: {drawn.group(0)}"
    after(run.output[drawn.end():], "End page: Home swipe")


@scenario(*X4S)
def sleep_sync_power_wake(ctx: Context, tmp: Path) -> None:
    """X1: a Power press while one sleep-sync step is blocked (the proxy holds the progress request
    for 50 s) wakes the device within the watcher's grace, not after the step."""
    card = ctx.card(tmp)
    path = card.add_book(ctx.source("Standalone 05"))
    card.open_book(path)
    ctx.faults([{"match": {"path": "/syncs/progress/"}, "action": "delay", "ms": 50000, "times": 1}])
    card.sync_on_sleep()
    run = ctx.sim.run(card, "sleep", script="2500:POWER:120", after_reboot="3000:POWER:600", timeout_s=15)
    sync = after(run.output, "Sleep sync starting")
    woke = re.search(r"\[(\d+)\] \[ERR\] \[SLP\] Wake press not answered|\[(\d+)\] \[INF\] \[BookOrbit\] Sleep sync cancelled",
                     sync)
    assert woke, "the press during the blocked step did not wake the device"
    at = int(woke.group(1) or woke.group(2))
    assert at < 3000 + 600 + 4000, f"woken {at} ms into the sleep-sync boot, the press was at 3000 ms"
    after(sync[woke.end():], "Wake route: PowerButton")


@scenario(*X4S)
def sleep_sync_quick_wake(ctx: Context, tmp: Path) -> None:
    """X1, the press the sync can answer (X4 Pro, .167: every wake restarted from the watcher,
    "not answered within 2000 ms", 0.6 s after the press). The watcher recorded the press and
    checked its deadline in the same tick; on an even millisecond the press read as ~49 days old.
    Now the sync answers between its steps and the next boot logs the press-to-screen time."""
    card = ctx.card(tmp)
    path = card.add_book(ctx.source("Standalone 05"))
    card.open_book(path)
    ctx.faults([{"match": {}, "action": "delay", "ms": 400}])
    card.sync_on_sleep()
    run = ctx.sim.run(card, "sleep", script="2500:POWER:120", after_reboot="2600:POWER:120", timeout_s=20)
    sync = after(run.output, "Sleep sync starting")
    assert "Wake press not answered" not in sync, "the watcher restarted before the sync could answer"
    answered = after(sync, "Wake press answered by the sync")
    woke = re.search(r"Wake: (\d+)ms from press to screen", answered)
    assert woke, "the wake boot did not log its press-to-screen time"
    assert int(woke.group(1)) < 15000, f"press to screen took {woke.group(1)} ms"


@scenario("x4-pro")
def sleep_sync_budget(ctx: Context, tmp: Path) -> None:
    """X2: a sleep sync on a slow server ends at its 240 s budget (+20 s grace) and the device
    sleeps. Every request is held 36 s: the sync's own seven take 250 s."""
    card = ctx.card(tmp)
    path = card.add_book(ctx.source("Standalone 06"))
    card.open_book(path)
    ctx.faults([{"match": {}, "action": "delay", "ms": 36000}])
    started = time.monotonic()
    run = sleep_sync(ctx, card, "sleep", timeout_s=330)
    elapsed = time.monotonic() - started
    stopped = any(m in run.output for m in ("Sleep sync stopped: its time budget is spent",
                                             "past its 240 s budget; restarting to sleep"))
    assert stopped, "the sleep sync did not stop at its budget"
    assert elapsed < 2.5 + 240 + 20 + 15, f"the device slept after {elapsed:.0f} s"


@scenario("x4-classic")
def home_tile_refresh(ctx: Context, tmp: Path) -> None:
    """X8 (the Home sync tile): on the BookOrbit Home, Confirm on the sync tile refreshes Home
    ("Refreshing…"); Confirm held 1 s asks for a Full refresh, which the refresh boot runs."""
    card = ctx.card(tmp)
    card.theme(UI_THEME_BOOKORBIT)
    ctx.sim.run(card, "tap", script="3000:DOWN:120;4500:CONFIRM:120", timeout_s=14,
                screenshots={5200: "x4-classic-home-refreshing"})
    assert (card.crosspoint / "bookorbit_home.bin").exists(), "the tile's refresh wrote no Home snapshot"
    run = ctx.sim.run(card, "hold", script="3000:DOWN:120;4500:CONFIRM:1300", timeout_s=40)
    tail = after(run.output, "Home: Full refresh asked for from the sync tile")
    after(tail, "Mirror: saved for offline")


@scenario("x4-pro")
def home_refresh_completion_stamp(ctx: Context, tmp: Path) -> None:
    """Ordinary Home refresh seeds offline windows and stamps its finish, not its start."""
    import struct
    import time
    card = ctx.card(tmp)
    card.theme(UI_THEME_BOOKORBIT)
    sleep_pick(card, **{"from": "library", "hours": 0})
    sx, sy = home_tile(ctx.sim.run(card, "home", script="3000:QUIT", timeout_s=10).output, "sync")
    ctx.faults([{"match": {"path": "/plugin/catalog/"}, "action": "delay", "ms": 250}])
    started = int(time.time())
    run = ctx.sim.run(card, "refresh-counts", script=f"3000:TAP:{sx},{sy},120", after_reboot="", timeout_s=100,
                      env={"ORBIFY_SIM_QUIT_HOME_DONE": "1"})
    ended = int(time.time())
    after(run.output, "Home refresh over (ok=1")
    assert "Mirror: Full refresh asked for" not in run.output, "ordinary refresh became Full refresh"
    counts = re.findall(r"Refresh progress: lists=(\d+)/(\d+) books=(\d+) covers=(\d+)", run.output)
    assert len(counts) >= 2, f"refresh displayed no live counters: {counts}"
    stamp = struct.unpack_from("<I", (card.crosspoint / "bookorbit_home.bin").read_bytes(), 8)[0]
    assert ended > started + 5, "refresh did not exercise a delayed completion"
    assert 0 <= ended-stamp <= 5, f"Home age {stamp} was not stamped at completion {ended}"
    ctx.faults("offline")
    home = ctx.sim.run(card, "just-synced", script="3000:QUIT", timeout_s=10)
    after(home.output, "Home sync stamp: Synced just now")
    assert not (card.crosspoint / "orbify-catalog" / "bulk" / "active").exists(), "ordinary refresh started a bulk generation"
    library = ctx.sim.run(card, "offline-library", script="3000:SWIPE:0.8,0.5,0.2,0.5,250;5000:QUIT", timeout_s=10)
    cx, cy = home_tile(library.output, "catalog")
    before = len(ctx.requests())
    downs = ";".join(f"{7500+n*240}:DOWN:100" for n in range(58))
    offline = ctx.sim.run(card,"ordinary-refresh-offline-pages",
        script=f"3000:SWIPE:0.8,0.5,0.2,0.5,250;4500:TAP:{cx},{cy};6000:DOWN:100;6500:CONFIRM:100;"+downs+";24000:QUIT", timeout_s=30)
    after(offline.output,"Listing page 3")
    assert "Catalog blocking paint:" not in after(offline.output, "Listing page 1"), "saved sectioned list painted Loading"
    assert "Joining saved network" not in offline.output and not ctx.requests()[before:], "refreshed 100-row data woke the network"
    samples=[int(n) for n in re.findall(r"Heap after saved catalog window: internal free=(\d+)",offline.output)]
    assert len(samples)>=3 and min(samples)>=60*1024, f"ordinary refresh paging heap: {samples}"


@scenario("x4-pro")
def offline_cached_list_no_loading(ctx: Context, tmp: Path) -> None:
    """Ordinary refresh's 100-row SD sources, never-visited pages, both swipe directions.

    Full refresh uses a separate bulk adapter; this must also work without a bulk generation
    or session-list files. Cross 12 browser-page boundaries in a 245-book saved listing.
    """
    card = ctx.card(tmp)
    card.theme(UI_THEME_BOOKORBIT)
    # Compact rows keep screen boundaries fixed while walking the whole list both ways.
    # The ordinary-refresh scenario below also checks the default sectioned layout.
    card.settings["libraryListExpanded"] = 0
    card.save()
    sleep_pick(card, **{"from": "library", "hours": 0})
    sx, sy = home_tile(ctx.sim.run(card, "home", script="3000:QUIT", timeout_s=10).output, "sync")
    template = kit.Device().call("GET", "/plugin/catalog/books?format=epub&size=1")["items"][0]
    rows = [{**template, "id": 700000 + n, "title": f"Offline cached book {n:03}",
             "formats": ["epub"], "addedAt": "2026-11-01T00:00:00Z"} for n in range(245)]
    rules = []
    for page in range(1, 4):
        rules.append({"match": {"path": "/plugin/catalog/books$", "query": {"size": "^100$", "page": f"^{page}$"}},
                      "action": "status", "status": 200, "body": json.dumps({"items": rows[(page-1)*100:page*100],
                      "page": page, "size": 100, "total": len(rows), "hasNext": page < 3})})
    ctx.faults(rules)
    seeded = ctx.sim.run(card, "ordinary-refresh", script=f"3000:TAP:{sx},{sy},120", after_reboot="",
                         timeout_s=100, env={"ORBIFY_SIM_QUIT_HOME_DONE": "1"})
    after(seeded.output, "Home refresh over (ok=1")
    assert not (card.crosspoint / "orbify-catalog" / "bulk" / "active").exists()
    # Each process starts with Wi-Fi off. No saved network permits a genuine miss to hide
    # behind a successful reconnect. The proxy also rejects any accidental HTTP request.
    (card.crosspoint / "wifi.json").unlink()
    ctx.faults("offline")
    library = ctx.sim.run(card, "library", script="3000:SWIPE:0.8,0.5,0.2,0.5,250;5000:QUIT", timeout_s=10)
    cx, cy = home_tile(library.output, "catalog")
    before = len(ctx.requests())
    turns = []
    for n in range(32):
        turns.append(f"{8000+n*650}:SWIPE:0.5,0.8,0.5,0.2,150")
    for n in range(32):
        turns.append(f"{30000+n*650}:SWIPE:0.5,0.2,0.5,0.8,150")
    run = ctx.sim.run(card, "offline-cached-swipes", timeout_s=65, quit_after_sync=False,
        script=f"3000:SWIPE:0.8,0.5,0.2,0.5,250;4500:TAP:{cx},{cy};6000:DOWN:100;6500:CONFIRM:100;" +
               ";".join(turns) + ";53000:QUIT")
    listing = after(run.output, "Listing page 1")
    assert "Catalog blocking paint:" not in listing, "cached paging painted a blocking Loading screen"
    assert not ctx.requests()[before:], "cached paging attempted HTTP"
    assert "Joining saved network" not in listing and "[WIFI] Joined" not in listing
    pages = [int(p) for p in re.findall(r"Listing page (\d+) from cache", listing)]
    assert max(pages, default=0) >= 13, f"did not traverse the saved list: {pages}"
    samples = [(int(a), int(b), int(ms)) for a, b, ms in
               re.findall(r"Catalog page turn: from=(\d+) to=(\d+) elapsedMs=(\d+)", listing)]
    assert len(samples) == 64, f"lost swipe inputs: {samples}"
    assert any(b > a for a, b, _ in samples) and any(b < a for a, b, _ in samples)
    assert samples[-1][1] == 0, f"reverse paging did not return to the beginning: {samples[-1]}"
    assert max(ms for _, _, ms in samples) < 250, f"cached page exceeded 250 ms (including paint): {samples}"


@scenario("x4-pro")
def home_tile_touch(ctx: Context, tmp: Path) -> None:
    """X8 by touch (X4 Pro, .167: a hold did nothing, a tap failed, a slow tap started a Full
    refresh). A tap held 700 ms (past the SDK's 500 ms long press) is still a refresh; a 1.3 s hold
    is a Full refresh. Each restart's popup names it before the restart."""
    card = ctx.card(tmp)
    card.theme(UI_THEME_BOOKORBIT)
    shot = ctx.sim.run(card, "home", script="4000:QUIT", timeout_s=10, screenshots={3000: "x4-pro-home"})
    x, y = home_tile(shot.output, "sync")
    tap = ctx.sim.run(card, "tap", script=f"3000:TAP:{x},{y},700", timeout_s=14)
    after(tap.output, "Home: refresh asked for from the sync tile")
    assert "Full refresh asked for" not in tap.output, "a 700 ms tap started a Full refresh"
    hold = ctx.sim.run(card, "hold", script=f"3000:TAP:{x},{y},1300", timeout_s=40)
    after(hold.output, "Home: Full refresh asked for from the sync tile")
    assert "Home: refresh asked for from the sync tile" not in hold.output, "the hold was also a tap"


def home_tile(output: str, which: str) -> tuple[int, int]:
    """The centre of a BookOrbit Home tile, from the Home's log ("sync" or "catalog")."""
    tile = re.search(rf"BookOrbit Home: {which} tile at (\d+),(\d+) (\d+)x(\d+)", output)
    assert tile, f"the Home did not log its {which} tile"
    return int(tile.group(1)) + int(tile.group(3)) // 2, int(tile.group(2)) + int(tile.group(4)) // 2


STAMP = re.compile(r"\[(\d+)\] \[INF\] \[BookOrbit\] Catalog stamp '([^']*)' at (\d+),(\d+) (\d+)x(\d+); "
                   r"refresh control at (\d+),(\d+)")


@scenario("x4-pro")
def catalog_refresh_stamp(ctx: Context, tmp: Path) -> None:
    """The catalog's ⟳ (X4 Pro, .167: the log had "Refresh of view 1" and "Refresh done", the screen
    neither "Refreshing…" nor "updated just now"). The stamp went to the header band's right edge,
    under the ⟳ and the battery; it is drawn left of the controls now. The screenshots taken while
    the refresh runs and after it must show it there."""
    card = ctx.card(tmp)
    card.theme(UI_THEME_BOOKORBIT)
    sx, sy = home_tile(ctx.sim.run(card, "home", script="3000:QUIT", timeout_s=10).output, "sync")
    ctx.sim.run(card, "seed", script=f"3000:TAP:{sx},{sy}", timeout_s=30)  # the Home's snapshot: its Library page
    first = ctx.sim.run(card, "library", script="3000:SWIPE:0.8,0.5,0.2,0.5,250;5000:QUIT", timeout_s=10)
    cx, cy = home_tile(first.output, "catalog")
    opened = ctx.sim.run(card, "open", script=f"3000:SWIPE:0.8,0.5,0.2,0.5,250;4500:TAP:{cx},{cy};14000:QUIT", timeout_s=20)
    stamp = STAMP.search(opened.output)
    assert stamp, "the catalog logged no stamp"
    rx, ry = int(stamp.group(7)), int(stamp.group(8))
    # Each catalog request waits 2 s at the proxy: the refresh is on screen long enough to see.
    ctx.faults([{"match": {"path": "/plugin/catalog/"}, "action": "delay", "ms": 2000}])
    # The simulator presents (and screenshots) only from its main loop, which the refresh holds:
    # a screenshot cannot catch "Refreshing…" mid-fetch, and shots due during the fetch are all
    # saved at once when it ends. So "Refreshing…" is judged from the log (drawn before the first
    # request, on screen while they run) and the screenshots, taken well after the refresh and
    # well before the QUIT, check the final stamp's ink.
    shots = {ms: f"x4-pro-catalog-{ms}" for ms in range(26000, 30001, 1000)}
    run = ctx.sim.run(card, "refresh", script=f"3000:SWIPE:0.8,0.5,0.2,0.5,250;4500:TAP:{cx},{cy};14000:TAP:{rx},{ry};40000:QUIT",
                      timeout_s=75,
                      screenshots=shots)
    refresh = after(run.output, "Catalog: Refresh of view")
    stamps = [(int(m.group(1)), m.group(2), *map(int, m.groups()[2:6])) for m in STAMP.finditer(refresh)]
    busy = next((s for s in stamps if s[1].lower().startswith("refreshing")), None)
    assert busy, f"the stamp never read 'Refreshing…' after the tap: {[s[1] for s in stamps]}"
    first_get = re.search(r"\[(\d+)\] \[DBG\] \[HTTP\] \S+ GET: \S+/plugin/catalog/", refresh)
    assert first_get and busy[0] <= int(first_get.group(1)), "'Refreshing…' was not drawn before the first request"
    queued = after(refresh, "foreground returned")
    after(queued, "Refresh phase: kind=")
    done = after(refresh, "Catalog: Refresh done")
    final = [s for s in STAMP.finditer(done)]
    assert final and final[-1].group(2).lower().startswith("updated just now"), \
        f"the stamp after the refresh: {[m.group(2) for m in final]}"
    at, _, x, y, w, h = int(final[-1].group(1)), final[-1].group(2), *map(int, final[-1].groups()[2:6])
    later = [ms for ms in sorted(shots) if ms >= at + 300]
    assert later, f"no screenshot after the final stamp was drawn at {at} ms"
    shot = card.root / "shots" / f"x4-pro-catalog-{later[-1]}.bmp"
    assert shot.exists(), f"the simulator saved no screenshot at {later[-1]} ms"
    dark = dark_pixels(shot.read_bytes(), x, y, w, h)
    assert dark > w // 4, f"'updated just now' is not on screen at {x},{y} ({dark} dark pixels)"


BADGE = re.compile(r"\[(\d+)\] \[INF\] \[BookOrbit\] Catalog: Full refresh badge '(\d+)%' at (\d+),(\d+) (\d+)x(\d+)")


def open_catalog(ctx: Context, card: SdCard) -> tuple[int, int, int, int]:
    """Home's snapshot, then the catalog from its Library page. Returns the catalog tile's centre and
    the ⟳'s, from the logs."""
    card.theme(UI_THEME_BOOKORBIT)
    sx, sy = home_tile(ctx.sim.run(card, "home", script="3000:QUIT", timeout_s=10).output, "sync")
    ctx.sim.run(card, "seed", script=f"3000:TAP:{sx},{sy}", timeout_s=30)
    first = ctx.sim.run(card, "library", script="3000:SWIPE:0.8,0.5,0.2,0.5,250;5000:QUIT", timeout_s=10)
    cx, cy = home_tile(first.output, "catalog")
    opened = ctx.sim.run(card, "open", script=f"3000:SWIPE:0.8,0.5,0.2,0.5,250;4500:TAP:{cx},{cy};14000:QUIT", timeout_s=20)
    stamp = STAMP.search(opened.output)
    assert stamp, "the catalog logged no stamp"
    return cx, cy, int(stamp.group(7)), int(stamp.group(8))


@scenario("x4-pro")
def catalog_full_refresh_percent(ctx: Context, tmp: Path) -> None:
    """One progress number (docs/design/sqlite-cache.md "Xteink: the same rule", patch 0041): holding
    ⟳ shows one start popup, then the Full refresh walks while the catalog stays usable, its % in
    the stamp's place, repainted in its own rectangle only, never going down; no per-step popups
    ("saving for offline N/M"); "Done" at the end."""
    card = ctx.card(tmp)
    cx, cy, rx, ry = open_catalog(ctx, card)
    # Each catalog request waits 400 ms at the proxy: the walk lasts long enough for the badge to move.
    ctx.faults([{"match": {"path": "/plugin/catalog/"}, "action": "delay", "ms": 400}])
    shots = {ms: f"x4-pro-full-{ms}" for ms in range(16000, 120001, 3000)}
    run = ctx.sim.run(card, "full", script=f"3000:SWIPE:0.8,0.5,0.2,0.5,250;4500:TAP:{cx},{cy};"
                      f"14000:TAP:{rx},{ry},1300;140000:QUIT", timeout_s=155, screenshots=shots)
    full = after(run.output, "Catalog: Full refresh popup: about")
    assert run.output.count("Catalog: Full refresh popup: about") == 1, "the start popup was shown more than once"
    assert "saving for offline" not in run.output.lower(), "a per-step popup was shown"
    after(full, "Catalog: Full refresh popup closed")
    badges = [(int(m.group(1)), int(m.group(2)), *map(int, m.groups()[2:6])) for m in BADGE.finditer(full)]
    assert len(badges) >= 2, f"the badge was repainted {len(badges)} times"
    stamps = [m.group(2) for m in STAMP.finditer(full)]
    shown = [int(t[:-1]) for t in stamps if re.fullmatch(r"\d+%", t)] + [b[1] for b in badges]
    order = sorted([(int(m.group(1)), int(m.group(2)[:-1])) for m in STAMP.finditer(full) if re.fullmatch(r"\d+%", m.group(2))]
                   + [(b[0], b[1]) for b in badges])
    pcts = [p for _, p in order]
    assert pcts == sorted(pcts), f"the % went down: {pcts}"
    assert all(0 <= p < 100 for p in shown), f"a % out of range: {shown}"
    # Partial repaints: a few seconds apart, and only when the % changed.
    for (t0, p0, *_), (t1, p1, *_) in zip(badges, badges[1:]):
        assert p1 > p0, f"a badge repaint with no change: {p0} then {p1}"
        assert t1 - t0 >= 2900, f"badge repaints {t1 - t0} ms apart"
    done = after(full, "Mirror: saved for offline")
    final = after(done, "Catalog: Full refresh done")
    assert any(m.group(2).startswith("Done") for m in STAMP.finditer(final)), "the stamp never read 'Done'"
    # The badge's rectangle has ink after a partial repaint; the title beside it is still there.
    at, _, x, y, w, h = badges[-1]
    later = [ms for ms in sorted(shots) if at + 300 <= ms]
    assert later, f"no screenshot after the badge was repainted at {at} ms"
    shot = (card.root / "shots" / f"x4-pro-full-{later[0]}.bmp").read_bytes()
    assert dark_pixels(shot, x, y, w, h) > 10, f"the badge is not on screen at {x},{y}"
    assert dark_pixels(shot, 60, y, max(1, x - 80), h) > 10, "the header's title went with the badge repaint"


@scenario("x4-pro")
def home_full_refresh_percent(ctx: Context, tmp: Path) -> None:
    """One progress number from Home (patch 0041): the sync tile's hold runs the Full refresh in the
    refresh boot with one start popup, then its % in the corner; a press goes back to Home, whose
    header keeps the % (the walk carries on in the catalog and at the sleep syncs); no "N/M"."""
    card = ctx.card(tmp)
    card.theme(UI_THEME_BOOKORBIT)
    sx, sy = home_tile(ctx.sim.run(card, "home", script="3000:QUIT", timeout_s=10).output, "sync")
    ctx.faults([{"match": {"path": "/plugin/catalog/"}, "action": "delay", "ms": 400}])
    run = ctx.sim.run(card, "hold", script=f"3000:TAP:{sx},{sy},1300", after_reboot="8000:TAP:240,700",
                      timeout_s=140)
    after(run.output, "Full refresh: reboot notice suppressed")
    walk = after(run.output, "Home refresh: Full refresh popup: about")
    assert "saving for offline" not in run.output.lower(), "a per-step N/M was shown"
    after(walk, "Home refresh: Full refresh popup closed")
    returned = re.search(r"Home refresh: Full refresh continues in background at (\d+)% \(a press\)", walk)
    assert returned, "a press did not return to Home"
    after(walk[returned.end():], "Entering activity: Home")
    after(walk[returned.end():], "Full refresh: Done")
    assert "open catalog to resume" not in walk
    pcts = [int(p) for p in re.findall(r"Full refresh badge '(\d+)%'", walk[:returned.end()])]
    assert pcts and pcts == sorted(pcts), f"the % went down: {pcts}"


@scenario("x4-pro")
def tailscale_layout(ctx: Context, tmp: Path) -> None:
    """The BookSync layout rulings (2026-11-24, from Android) on the Tailscale screen: the title once
    (the header), each status on its own line under its row, nothing over a control. A reader that
    is on and logged in (the simulator's ORBIFY_SIM_TAILSCALE=joined): "On; connects when WiFi is on"
    under Enabled, the key-expiry advice under Log out. Before, the status sat centred above the
    list, the first row repeated the title, and the advice was two lines under the list."""
    card = ctx.card(tmp)
    # Home's Settings, the System tab, Tailscale (the Lyra theme's rows on the X4 Pro).
    run = ctx.sim.run(card, "tailscale", script="3000:TAP:120,593;5000:TAP:410,111;7000:TAP:100,589;10000:QUIT",
                      timeout_s=14, env={"ORBIFY_SIM_TAILSCALE": "joined"}, screenshots={9000: "x4-pro-tailscale"})
    page = re.search(r"Tailscale page 'Tailscale': rows from (\d+), (\d+) high", run.output)
    assert page, "the Tailscale screen did not open"
    top, row = int(page.group(1)), int(page.group(2))
    shot = (card.root / "shots" / "x4-pro-tailscale.bmp").read_bytes()
    width = 480
    # Nothing between the header and the first row: no status line above the list, no second title.
    assert dark_pixels(shot, 0, 92, width, max(1, top - 96)) == 0, "text between the header and the list"
    for n, what in ((0, "Enabled's status"), (1, "Log out's advice")):
        y0 = top + n * row
        title = dark_pixels(shot, 20, y0 + 4, 200, row // 2 - 6)
        status = dark_pixels(shot, 20, y0 + row // 2 + 2, 300, row // 2 - 6)
        assert title > 20 and status > 20, f"{what}: not on its own line under the row ({title}, {status})"
    # The status line stops short of the row's value ("ON"), which sits on the title line: under the
    # value there is only the selected row's shading, as in the empty stretch just left of it.
    band = (top + row // 2 + 2, row // 2 - 6)
    assert dark_pixels(shot, 380, top + 4, 80, row // 2 - 6) > dark_pixels(shot, 380, *band[:1], 80, band[1]) + 10, \
        "Enabled's value is missing"
    under_value = dark_pixels(shot, 380, band[0], 80, band[1])
    shading = dark_pixels(shot, 300, band[0], 80, band[1])
    assert under_value <= shading * 1.2 + 5, f"the status runs into the value ({under_value} vs {shading})"


@scenario("x4-pro")
def catalog_cache_first(ctx: Context, tmp: Path) -> None:
    """Cache-first catalog (the user's rule, .167): with a saved copy that is not stale, opening the
    catalog brings no Wi-Fi up and asks the server nothing; ⟳ is what goes to the network. Before,
    every open joined Wi-Fi first, even offline with Tailscale off."""
    card = ctx.card(tmp)
    card.theme(UI_THEME_BOOKORBIT)
    sx, sy = home_tile(ctx.sim.run(card, "home", script="3000:QUIT", timeout_s=10).output, "sync")
    # Full refresh only walks the catalog; an ordinary sync creates Home's snapshot and
    # its Library page, as on a configured reader. Do not rely on the walk fetching Home.
    ctx.sim.run(card, "seed", script=f"3000:TAP:{sx},{sy}", timeout_s=30)
    full = ctx.sim.run(card, "full", script=f"3000:TAP:{sx},{sy},1300", timeout_s=140)
    after(full.output, "Mirror: saved for offline")
    # Age and a different saved library version must never force a reconnect/full walk.
    (card.crosspoint / "orbify" / "mirror.state").write_text("1700000000\tolder-library\n")
    first = ctx.sim.run(card, "library", script="3000:SWIPE:0.8,0.5,0.2,0.5,250;5000:QUIT", timeout_s=10)
    cx, cy = home_tile(first.output, "catalog")  # on the Library page
    before = len(ctx.requests())
    run = ctx.sim.run(card, "open", script=f"3000:SWIPE:0.8,0.5,0.2,0.5,250;4500:TAP:{cx},{cy};10000:QUIT", timeout_s=16)
    after(run.output, "Catalog: opening from the cache, no Wi-Fi")
    asked = ctx.requests()[before:]
    assert not asked, f"opening a cached catalog asked the server: {[e['path'] for e in asked][:5]}"
    assert "[WIFI] Joined" not in run.output, "opening a cached catalog joined Wi-Fi"
    # Then ⟳ (X4 Pro, .194: the catalog opened from the cache with Wi-Fi never started, and the
    # next request panicked in lwIP, which has no TCP/IP stack before Wi-Fi first starts): no
    # request until Wi-Fi is up, then "Refreshing…" and "updated just now".
    stamp = STAMP.search(run.output)
    assert stamp, "the catalog logged no stamp"
    rx, ry = int(stamp.group(7)), int(stamp.group(8))
    before = len(ctx.requests())
    run = ctx.sim.run(card, "refresh", script=f"3000:SWIPE:0.8,0.5,0.2,0.5,250;4500:TAP:{cx},{cy};10000:TAP:{rx},{ry};30000:QUIT",
                      timeout_s=45)
    opened = after(run.output, "Catalog: opening from the cache, no Wi-Fi")
    refresh = after(opened, "Catalog: Refresh of view")
    connected = refresh.find("[WIFI] Joined")
    assert connected >= 0, "⟳ on a catalog opened from the cache did not join Wi-Fi"
    assert not re.search(r"\[HTTP\] \S+ GET: ", refresh[:connected]), "a request went out before Wi-Fi was up"
    assert ctx.requests()[before:], "⟳ asked the server nothing"
    stamps = [m.group(2) for m in STAMP.finditer(refresh)]
    assert any(t.lower().startswith("refreshing") for t in stamps), f"no 'Refreshing…' stamp: {stamps}"
    queued = after(refresh, "foreground returned")
    after(queued, "Refresh phase: kind=")
    roots = [r for r in ctx.requests()[before:] if r["path"].endswith("/plugin/catalog/root")]
    assert len(roots) == 1, f"reloading the refreshed root repeated its network request: {roots}"
    done = after(refresh, "Catalog: Refresh done")
    final = [m.group(2) for m in STAMP.finditer(done)]
    assert final and final[-1].lower().startswith("updated just now"), f"the stamp after the refresh: {final}"


@scenario("x4-pro")
def menu_home_swipe(ctx: Context, tmp: Path) -> None:
    """On the BookOrbit Home's menu (Settings, BookOrbit, ...), a Home swipe goes to the BookOrbit
    Home and stays there (X4 Pro, .167: it flashed the Home and reopened the menu). Back does the
    same from the buttons."""
    card = ctx.card(tmp)
    card.theme(UI_THEME_BOOKORBIT)
    run = ctx.sim.run(card, "swipe", script="3000:SWIPE:0.5,0.6,0.5,0.3,250;5000:SWIPE:0.5,0.995,0.5,0.55,300;8000:QUIT",
                      timeout_s=14, screenshots={4500: "x4-pro-menu", 7500: "x4-pro-menu-home-swipe"})
    tail = after(run.output, "Home swipe on the menu: back to Home")
    assert "Home: menu opened" not in tail, "the Home swipe reopened the menu"


@scenario(*ALL)
def ota_returns_to_update(ctx: Context, tmp: Path) -> None:
    """The completed-install marker returns to the OTA screen without Wi-Fi, then is consumed."""
    card = ctx.card(tmp)
    marker = card.crosspoint / "orbify_ota_return"
    marker.write_text("older-firmware")
    before = len(ctx.requests())
    first = ctx.sim.run(card, "updated", script="4000:QUIT", timeout_s=8,
                        screenshots={3000: "updated"})
    after(first.output, "Updated to v")
    assert not marker.exists() and len(ctx.requests()) == before
    assert "[WIFI] Joined" not in first.output and "Entering activity: OtaUpdate" in first.output
    second = ctx.sim.run(card, "next-boot", script="3000:QUIT", timeout_s=7)
    assert "Updated to v" not in second.output and "Entering activity: OtaUpdate" not in second.output


@scenario("x4-pro")
def sleep_picker_in_place(ctx: Context, tmp: Path) -> None:
    """Both Display sleep pickers toggle and save on the same SD-only screen. Visible switches
    change before Back, and the Leave Out selection is still checked on reopening the list."""
    card = ctx.card(tmp)
    sleep_pick(card, **{"from": "up_next", "leaveScopes": ""})
    before = len(ctx.requests())
    run = ctx.sim.run(card, "pickers", script="3000:TAP:120,593;5000:TAP:60,111;6500:TAP:100,173;"
                      "8000:TAP:100,455;9500:TAP:100,300;12000:TAP:25,55;14000:TAP:100,572;"
                      "16000:TAP:100,125;18000:TAP:25,55;20000:TAP:100,572;22000:QUIT",
                      timeout_s=26, screenshots={8500: "pick-before", 10500: "pick-after",
                      15000: "leave-before", 17000: "leave-after", 21000: "leave-reopened"})
    settings = json.loads((card.crosspoint / "orbify_sleep" / "settings.json").read_text())
    assert set(settings["from"].splitlines()) == {"up_next", "discover"}
    assert settings["leaveScopes"] == "library"
    def ink(name, y):
        return dark_pixels((card.root / "shots" / f"{name}.bmp").read_bytes(), 399, y, 42, 20)
    assert ink("pick-after", 285) > ink("pick-before", 285) + 80, "Pick From did not change in place"
    assert ink("leave-after", 111) > ink("leave-before", 111) + 80, "Leave Out did not change in place"
    assert ink("leave-reopened", 111) == ink("leave-after", 111), "the saved state did not reopen checked"
    assert len(ctx.requests()) == before and "[WIFI] Joined" not in run.output, "picker opened the network"


@scenario(*X4S)
def catalog_incremental_silent(ctx: Context, tmp: Path) -> None:
    """An old cache never schedules a Full refresh. The existing sleep connection checks one
    recent-items page, silently, even when the library version differs from the saved one."""
    card = ctx.card(tmp)
    folder = card.crosspoint / "orbify"
    folder.mkdir(exist_ok=True)
    (folder / "mirror.state").write_text("1700000000\told-library\n")
    run = sleep_sync(ctx, card, "incremental", timeout_s=120)
    after(run.output, "Catalog incremental:")
    assert "no saved recent-items page" not in run.output and "parse failed" not in run.output
    assert "Full refresh popup" not in run.output and "Full refresh badge" not in run.output
    assert "Mirror: Full refresh started" not in run.output
    assert not (folder / "mirror.tsv").exists() and not (folder / "mirror.request").exists()
    recent = [r for r in ctx.requests("/plugin/catalog/books") if r.get("query", {}).get("sort") == "recently_updated"]
    assert len(recent) == 1, f"expected one recent-items page, got {recent}"
    assert (folder / "mirror.state").read_text() == "1700000000\told-library\n"


@scenario(*X4S)
def offline_sleep_sync(ctx: Context, tmp: Path) -> None:
    """The server is gone (every connection dropped): the sleep sync gives up cleanly, keeps the
    Home snapshot and the mirror plan as they were, and the device sleeps."""
    card = ctx.card(tmp)
    path = card.add_book(ctx.source("Standalone 04"))
    card.open_book(path)
    ctx.faults("offline")
    run = sleep_sync(ctx, card, "sleep", timeout_s=120)
    after(run.output, "Sleep sync over")
    assert "Mirror: saved for offline" not in run.output, "a mirror was saved from a dead server"
    assert all(e["action"] == "drop" for e in ctx.requests()), "a request reached the server"


def sleep_pick(card: SdCard, **settings) -> None:
    """BookOrbit Pick on (patch 0039): its settings file, as Settings > Display writes it."""
    folder = card.crosspoint / "orbify_sleep"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "settings.json").write_text(json.dumps({"pick": True, **settings}))


def sleep_batch(run_output: str) -> tuple[int, int]:
    """(covers in the batch, fetched this sync) from the top-up's summary line."""
    m = re.search(r"Sleep screen: batch (\d+) of 24 \((\d+) fetched", run_output)
    assert m, "the sleep sync did not top the batch up"
    return int(m.group(1)), int(m.group(2))


@scenario(*X4S)
def sleep_pick_batch(ctx: Context, tmp: Path) -> None:
    """ROADMAP 11 (docs/design/lock-screen.md R3, X4s): Every sleep from Discover. The first sleep
    has no ready cover (a clear placeholder shows); its sleep sync fetches a few covers on the
    lent connection and decodes them with the radio off. The next sleeps draw a ready cover at once
    from the card, never the one just shown, and each sync tops the batch up. (The simulator's run
    ends with the sync, before the redraw.)"""
    card = ctx.card(tmp)
    sleep_pick(card, **{"from": "discover", "hours": 0})
    opened = ctx.book("Standalone 01")
    path = card.add_book(ctx.source("Standalone 01"))
    card.open_book(path)
    # Firmware excludes catalog IDs through the same index a catalog download writes.
    card.download_index([(opened["id"], path)])
    # Discover is random on the server. Always put the open book first so exclusion is
    # exercised on every run, then use real library covers for the rest of the batch.
    candidates = [opened] + [b for b in ctx.manifest["books"] if b["id"] != opened["id"] and b["cover"]][:11]
    ctx.faults([{"match": {"path": "/dashboard/sections/random$"}, "action": "status", "status": 200,
                 "body": json.dumps({"section": {"books": [
                     {"id": b["id"], "hasCover": True, "readStatus": "unread"} for b in candidates]}})}])
    first = sleep_sync(ctx, card, "sleep-1", timeout_s=150)
    assert not ctx.requests(f"/books/{opened['id']}/thumbnail"), "Every sleep fetched the open book"
    after(first.output, "Sleep: BookOrbit Pick -> placeholder")
    count, fetched = sleep_batch(first.output)
    assert fetched >= 1 and count == fetched, f"the first top-up fetched {fetched}, batch {count}"
    decoded = re.findall(r"Sleep cover: book (\d+) decoded", first.output)
    assert len(decoded) == fetched, f"{fetched} fetched, {len(decoded)} decoded"
    for book in decoded:
        assert (card.crosspoint / "orbify_sleep" / f"{book}.bmp").exists(), f"cover {book} is not on the card"
    thumbs = [e for e in ctx.requests("/thumbnail") if e["status"] == 200]
    assert len(thumbs) >= fetched, f"{len(thumbs)} thumbnails served for {fetched} covers"

    shown = []
    for n in (2, 3):
        run = sleep_sync(ctx, card, f"sleep-{n}", timeout_s=150)
        drawn = re.search(r"Sleep: BookOrbit Pick -> cover (\d+) \(every sleep", run.output)
        assert drawn, f"sleep {n} drew no ready cover"
        assert int(drawn.group(1)) != ctx.book("Standalone 01")["id"], "Every sleep picked the open book"
        shown.append(drawn.group(1))
        assert (card.crosspoint / "orbify_sleep" / f"{drawn.group(1)}.bmp").exists(), f"sleep {n}: not on the card"
        before = count
        count, fetched = sleep_batch(run.output)
        assert count == min(24, before + fetched), f"batch {before} -> {count} ({fetched} fetched)"
    assert shown[0] != shown[1], "Every sleep showed the same cover twice in a row"


@scenario(*X4S)
def sleep_pick_offline(ctx: Context, tmp: Path) -> None:
    """R3/F7: with the server gone, the sleep still draws from the card and the batch keeps what it
    has; the sleep sync adds nothing and waits on nothing."""
    card = ctx.card(tmp)
    sleep_pick(card, **{"from": "discover", "hours": 0})
    first = sleep_sync(ctx, card, "sleep-1", timeout_s=150)
    count, _ = sleep_batch(first.output)
    ctx.faults("offline")
    second = sleep_sync(ctx, card, "sleep-2", timeout_s=120)
    after(second.output, "Sleep sync over")
    assert re.search(r"Sleep: BookOrbit Pick -> cover \d+", second.output), "no ready cover drawn offline"
    for book in re.findall(r"Sleep: BookOrbit Pick -> cover (\d+)", second.output):
        assert (card.crosspoint / "orbify_sleep" / f"{book}.bmp").exists(), f"cover {book} left the card"
    left = len(list((card.crosspoint / "orbify_sleep").glob("*.bmp")))
    assert left == count, f"the batch had {count} covers, the card keeps {left}"


@scenario(*X4S)
def sleep_pick_library(ctx: Context, tmp: Path) -> None:
    """R1c and X8 (Pick from and Leave out as sets, cases.json "sources"): Library picked with a list
    stands alone and is listed into the bag with no filter; the batch fills from it. Library left out
    leaves out every book: the covers leave the card and the sleep shows a placeholder."""
    card = ctx.card(tmp)
    sleep_pick(card, **{"from": "discover\nlibrary", "hours": 0})
    first = sleep_sync(ctx, card, "sleep-1", timeout_s=150)
    listed = re.search(r"Sleep screen: Pick from library lists (\d+) books", first.output)
    assert listed and int(listed.group(1)) > 0, "the library was not listed into the bag"
    assert not ctx.requests("/dashboard/sections/random"), "Discover was asked for though Library stands alone"
    count, fetched = sleep_batch(first.output)
    assert fetched >= 1, "nothing fetched from the library"
    sleep_pick(card, **{"from": "library", "hours": 0, "leaveScopes": "library"})
    second = sleep_sync(ctx, card, "sleep-2", timeout_s=150)
    after(second.output, "Sleep: BookOrbit Pick -> placeholder")
    count2, fetched2 = sleep_batch(second.output)
    assert count2 == 0 and fetched2 == 0, f"Library left out, yet batch {count2} ({fetched2} fetched)"
    assert not list((card.crosspoint / "orbify_sleep").glob("*.bmp")), "left-out covers stayed on the card"


@scenario("x4-pro")
def sleep_sources_regular_sync(ctx: Context, tmp: Path) -> None:
    """The first ordinary Home sync lists named libraries and prepares covers before any sleep."""
    card = ctx.card(tmp)
    library = ctx.manifest["library_id"]
    sleep_pick(card, **{"from": f"library:{library}", "hours": 0})
    open_catalog(ctx, card)
    names = (card.crosspoint / "orbify_sleep" / "scopes.tsv").read_text()
    assert f"l\t{library}\t" in names, "the user's separate library was missing before the first sleep"
    assert ctx.requests("/sections/smart-scopes") and ctx.requests("/sections/collections")
    filtered = [r for r in ctx.requests("/catalog/books") if str(r.get("query", {}).get("libraryId")) == str(library)]
    assert filtered, "a named library did not apply its libraryId filter"
    assert list((card.crosspoint / "orbify_sleep").glob("*.bmp")), "the ordinary sync prepared no ready covers"


@scenario("x4-pro")
def catalog_wifi_holds(ctx: Context, tmp: Path) -> None:
    """Full refresh, browsing and uncached requests share the radio, including an idle-off request."""
    card = ctx.card(tmp)
    cx, cy, rx, ry = open_catalog(ctx, card)
    ctx.faults([{"match": {"path": "/plugin/catalog/"}, "action": "delay", "ms": 15}])
    run = ctx.sim.run(card, "holds",
        script=f"3000:SWIPE:0.8,0.5,0.2,0.5,250;4500:TAP:{cx},{cy};8000:TAP:{rx},{ry},1300;13000:TAP:240,116;45000:BACK:100;47000:BACK:100;140000:QUIT",
        timeout_s=155, env={"ORBIFY_SIM_IDLE_OFF_ON_MISS": "1"})
    walk = after(run.output, "Catalog: Full refresh of view")
    after(walk, "Wi-Fi hold + refresh")
    after(walk, "Wi-Fi hold + offline miss")
    after(walk, "Wi-Fi off deferred")
    # Every attempted idle-off inside a miss must wait: the GET then succeeds on the same radio.
    until_exit = walk.split("Wi-Fi hold - catalog", 1)[0]
    assert "Wi-Fi off:" not in until_exit, "an owner lost its radio"
    after(walk, "Wi-Fi off: SavedWifiConnect disconnect (0 held)")


# OrbiSmart: exercise the firmware task, on-card journal and reader popup (no alternate policy).
def smart_card(ctx: Context, tmp: Path):
    card = ctx.card(tmp)
    card.bookorbit["sync_mode"] = "orbismart"
    card.save()
    path = card.add_book(ctx.source("Standalone 03"))
    card.open_book(path, asleep=True)
    card.progress(path, 1, 0, 1)
    return card, path


def smart_remote(ctx: Context, chapter: int = 4, timestamp: int | None = None):
    book = ctx.book("Standalone 03")
    remote = {"document": book["hash"], "progress": f"/body/DocFragment[{chapter}]/body",
              "percentage": (chapter - 1) / 5, "device": "another reader", "device_id": "orbify-e2e-seed",
              "timestamp": timestamp or int(time.time())}
    ctx.faults([{"match": {"path": f"/syncs/progress/{book['hash']}$", "method": "GET"},
                 "action": "status", "status": 200, "body": json.dumps(remote)}])
    return remote


@scenario(*X4S)
def orbismart_wake_yes(ctx: Context, tmp: Path) -> None:
    card, path = smart_card(ctx, tmp)
    smart_remote(ctx)
    run = ctx.sim.run(card, "wake-yes", wake=True, quit_after_sync=False, timeout_s=18,
                      script="9000:DOWN:120;10000:CONFIRM:120;15000:QUIT")
    after(run.output, "orbismart: rule3")
    after(run.output, "Continue from another reader, p.")
    after(run.output, "yes after")
    after(run.output, "orbismart: applied spine=3")
    assert not [e for e in ctx.requests("/syncs/progress") if e["method"] == "PUT"], "wake pushed behind server"


@scenario(*X4S)
def orbismart_wake_no(ctx: Context, tmp: Path) -> None:
    card, path = smart_card(ctx, tmp)
    smart_remote(ctx)
    run = ctx.sim.run(card, "wake-no", wake=True, quit_after_sync=False, timeout_s=18,
                      script="9000:BACK:120;15000:QUIT")
    after(run.output, "Continue from another reader, p.")
    after(run.output, "no after")
    assert "orbismart: applied" not in run.output
    # Same remote place after another real boot/check: no repeat and no stale upload.
    card.open_book(path, asleep=True)
    run = ctx.sim.run(card, "wake-no-again", wake=True, quit_after_sync=False, timeout_s=13,
                      script="10000:QUIT")
    after(run.output, "orbismart: declined")
    assert "Continue from" not in run.output
    assert "orbismart: applied" not in run.output
    assert not [e for e in ctx.requests("/syncs/progress") if e["method"] == "PUT"]


@scenario(*ALL)
def orbismart_prerender(ctx: Context, tmp: Path) -> None:
    card, path = smart_card(ctx, tmp)
    remote = smart_remote(ctx)
    journal = card.crosspoint / "orbismart"
    journal.mkdir()
    # Packed OSM1 journal: the exact firmware format (OrbiSmartState.h), including checksum.
    import struct
    def fnv32(raw):
        value = 2166136261
        for byte in raw:
            value = ((value ^ byte) * 16777619) & 0xffffffff
        return value
    def record(xpath="", percent=0, at=0, device=""):
        return struct.pack("<qf256s64s64s", at, percent, xpath.encode(), device.encode(), b"")
    scope = card.bookorbit["serverUrl"] + "\n" + card.bookorbit["username"]
    raw = bytearray(struct.pack("<IIIIBqqqI384s", 0x314d534f, 1, fnv32(scope.encode()), 0, 1, 0, 0, 0, 0, b""))
    raw += record(remote["progress"], remote["percentage"], remote["timestamp"], remote["device"])
    raw += record() + record() + struct.pack("<iii", 0, 0, 1)
    struct.pack_into("<I", raw, 12, fnv32(raw))
    (journal / (ctx.book("Standalone 03")["hash"] + ".0")).write_bytes(raw)
    (journal / (ctx.book("Standalone 03")["hash"] + ".1")).write_bytes(raw[:80])  # torn newer slot
    # No usable network. The cached place is consumed by the actual pre-render path.
    (card.crosspoint / "wifi.json").write_text('{"credentials": []}')
    run = ctx.sim.run(card, "prerender", wake=True, quit_after_sync=False, timeout_s=12, script="9000:QUIT")
    after(run.output, "-> take (prerender, now)")
    after(run.output, "pending place used (offline)")
    assert "Continue from" not in run.output
    assert not ctx.requests("/syncs/progress")


@scenario(*ALL)
def orbismart_override_offline(ctx: Context, tmp: Path) -> None:
    card, path = smart_card(ctx, tmp)
    (card.crosspoint / "wifi.json").write_text('{"credentials": []}')
    run = ctx.sim.run(card, "queue", wake=True, quit_after_sync=False, timeout_s=12, script="9000:QUIT",
                      env={"ORBIFY_SIM_OVERRIDE_AT_OPEN": "1"})
    after(run.output, "orbismart: override queued")
    assert not ctx.requests("/syncs/progress")
    (card.crosspoint / "wifi.json").write_text(json.dumps(
        {"lastConnectedSsid": "SimNet", "credentials": [{"ssid": "SimNet", "password": "simnet"}]}))
    # No later server reading: the queued backward place goes before the ordinary snapshot.
    smart_remote(ctx, timestamp=int(time.time()) - 3600)
    run = sleep_sync(ctx, card, "send")
    after(run.output, "orbismart: override sent")
    puts = [e for e in ctx.requests("/syncs/progress") if e["method"] == "PUT"]
    assert puts and puts[0]["status"] == 200
    sent = json.loads(re.search(r"Request body: (.*)", run.output).group(1))
    assert "DocFragment[2]" in sent["progress"], "override lost its offline chosen place"
    assert run.output.index("orbismart: override sent") < run.output.index("orbismart: rule")


@scenario(*ALL)
def orbismart_sleep_pending(ctx: Context, tmp: Path) -> None:
    card, path = smart_card(ctx, tmp)
    smart_remote(ctx)
    card.open_book(path)
    run = sleep_sync(ctx, card, "sleep")
    after(run.output, "-> take (sleep, wake)")
    assert "Continue from" not in run.output
    # The sleep screen discovery is asked at wake before a new connection is available.
    (card.crosspoint / "wifi.json").write_text('{"credentials": []}')
    card.open_book(path, asleep=True)
    run = ctx.sim.run(card, "wake-pending", wake=True, quit_after_sync=False, timeout_s=14,
                      script="9000:BACK:120;11000:QUIT")
    after(run.output, "Continue from another reader, p.")
    after(run.output, "no after")


@scenario(*X4S)
def orbismart_override_superseded(ctx: Context, tmp: Path) -> None:
    card, path = smart_card(ctx, tmp)
    smart_remote(ctx, timestamp=int(time.time()) - 3600)
    ctx.sim.run(card, "seen", wake=True, quit_after_sync=False, timeout_s=12,
                script="8000:BACK:120;10000:QUIT")
    card.open_book(path, asleep=True)
    (card.crosspoint / "wifi.json").write_text('{"credentials": []}')
    run = ctx.sim.run(card, "queue", wake=True, quit_after_sync=False, timeout_s=12,
                      script="9000:QUIT", env={"ORBIFY_SIM_OVERRIDE_AT_OPEN": "1"})
    after(run.output, "orbismart: override queued")
    (card.crosspoint / "wifi.json").write_text(json.dumps(
        {"lastConnectedSsid": "SimNet", "credentials": [{"ssid": "SimNet", "password": "simnet"}]}))
    smart_remote(ctx, chapter=5, timestamp=int(time.time()) + 10)
    card.open_book(path)
    run = sleep_sync(ctx, card, "later-reading")
    after(run.output, "orbismart: override dropped")
    after(run.output, "-> take (sleep, wake)")
    assert not [e for e in ctx.requests("/syncs/progress") if e["method"] == "PUT"]


@scenario(*X4S)
def orbismart_override_redated(ctx: Context, tmp: Path) -> None:
    card, path = smart_card(ctx, tmp)
    remote = smart_remote(ctx, timestamp=int(time.time()) - 3600)
    remote["progress"] += "/p[4]"
    ctx.faults([{"match": {"path": f"/syncs/progress/{ctx.book('Standalone 03')['hash']}$", "method": "GET"},
                 "action": "status", "status": 200, "body": json.dumps(remote)}])
    ctx.sim.run(card, "seen", wake=True, quit_after_sync=False, timeout_s=12,
                script="8000:BACK:120;10000:QUIT")
    card.open_book(path, asleep=True)
    (card.crosspoint / "wifi.json").write_text('{"credentials": []}')
    run = ctx.sim.run(card, "queue", wake=True, quit_after_sync=False, timeout_s=12,
                      script="9000:QUIT", env={"ORBIFY_SIM_OVERRIDE_AT_OPEN": "1"})
    after(run.output, "orbismart: override queued")
    (card.crosspoint / "wifi.json").write_text(json.dumps(
        {"lastConnectedSsid": "SimNet", "credentials": [{"ssid": "SimNet", "password": "simnet"}]}))
    smart_remote(ctx, timestamp=int(time.time()) + 10)  # same chapter, earlier place, newly dated
    card.open_book(path)
    run = sleep_sync(ctx, card, "web-open")
    after(run.output, "orbismart: override sent")
    assert "orbismart: override dropped" not in run.output


@scenario(*ALL)
def orbismart_sleep_prefetch(ctx: Context, tmp: Path) -> None:
    card, path = smart_card(ctx, tmp)
    card.open_book(path)
    entries = []
    for n, title in enumerate(("Standalone 01", "Standalone 02", "Standalone 04")):
        book = ctx.book(title)
        other = card.add_book(ctx.source(title))
        entries.append((book["id"], other))
        kit.Device().call("PUT", f"/plugin/catalog/books/{book['id']}/read-status", {"status": "reading"})
        kit.Device().call("PUT", "/syncs/progress", {"document": book["hash"],
            "progress": "/body/DocFragment[4]/body", "percentage": .6,
            "device": "another reader", "device_id": "orbify-e2e-seed", "timestamp": int(time.time()) + n})
    card.download_index(entries)
    current = ctx.book("Standalone 03")
    kit.Device().call("PUT", "/syncs/progress", {"document": current["hash"],
        "progress": "/body/DocFragment[2]/body", "percentage": .2,
        "device": "another reader", "device_id": "orbify-e2e-seed", "timestamp": int(time.time()) + 30})
    run = sleep_sync(ctx, card, "prefetch")
    after(run.output, "OrbiSmart: pending places saved 3/3")
    (card.crosspoint / "wifi.json").write_text('{"credentials": []}')
    card.open_book(entries[0][1], asleep=True)
    before = len(ctx.requests("/syncs/progress"))
    run = ctx.sim.run(card, "offline-other-book", wake=True, quit_after_sync=False, timeout_s=12, script="9000:QUIT")
    after(run.output, "pending place used (offline)")
    assert "Continue from" not in run.output
    assert len(ctx.requests("/syncs/progress")) == before


# --- Runner -----------------------------------------------------------------------------------

# What only a reader shows (docs/design/emulated-release-tests.md 6.2): written beside the results.
DEVICE_CHECKLIST = """\
# Xteink: still on a reader before the release

- Real heap with Wi-Fi + Tailscale + TLS (X3, X9): no `esp-aes: Failed to allocate memory`.
- The DNS lock race with real STUN timing (X4).
- The Wi-Fi tier and download throughput (patch 0030).
- OTA: check, flash, boot and rollback (X10).
- E-ink refresh, ghosting and touch feel on the End-of-Book page (X7).
- The power watcher's forced restart on real tasks (X1): `Wake press not answered`.
- Battery over a night of sleep syncs.
"""


def check_simulator_pin(checkout: Path) -> None:
    """The simulator package must be pinned to a commit: an unpinned one is where upstream's own
    harness failed most (design §2)."""
    ini = (checkout / "platformio.ini").read_text()
    pin = re.search(r"simulator=\S+#([0-9a-f]+)", ini)
    if not pin or len(pin.group(1)) != 40:
        raise SystemExit("upstream's simulator package is not pinned to a commit in platformio.ini")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--checkout", type=Path, required=True)
    parser.add_argument("--profile", choices=sorted(PROFILES), default="x4-pro")
    parser.add_argument("--scenario", action="append", help="run only this one (repeatable)")
    parser.add_argument("--out", type=Path, default=None)
    parser.add_argument("--proxy-port", type=int, default=None, help="fault proxy port; 0 chooses a free port for parallel workers")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv[1:])

    names = [n for n, (profiles, _) in SCENARIOS.items() if args.profile in profiles]
    if args.list:
        print("\n".join(names))
        return 0
    if args.scenario:
        unknown = set(args.scenario) - set(names)
        if unknown:
            raise SystemExit(f"not a {args.profile} scenario: {', '.join(sorted(unknown))}")
        names = [n for n in names if n in args.scenario]
    checkout = args.checkout.resolve()
    check_simulator_pin(checkout)
    program = checkout / ".pio" / "build" / PROFILES[args.profile] / "program"
    if not program.exists():
        raise SystemExit(f"{program} missing: pio run -e {PROFILES[args.profile]} in {checkout}")
    out = (args.out or Path(tempfile.mkdtemp(prefix="orbify-e2e-"))).resolve()
    port = int(kit.ENV["BOFAULT_PORT"]) if args.proxy_port is None else args.proxy_port
    proxy = bofault.serve(port, kit.SERVER, log=out / f"bofault-{args.profile}.jsonl")
    kit.PROXY = kit.PROXY.rsplit(":", 1)[0] + ":" + str(proxy.server_address[1])
    manifest = kit.seed()  # idempotent: puts back what an earlier run changed (want-to-read, users)
    results = []
    for name in names:
        artifacts = out / args.profile / name
        ctx = Context(args.profile, Simulator(program, artifacts, args.verbose), proxy, manifest, artifacts)
        proxy.state.set_rules([])
        with proxy.state.lock:
            proxy.state.entries.clear()
        started = time.monotonic()
        verdict, detail = "PASS", ""
        with tempfile.TemporaryDirectory(prefix=f"orbify-{name}-") as tmp:
            try:
                SCENARIOS[name][1](ctx, Path(tmp))
            except AssertionError as e:
                verdict, detail = "FAIL", str(e)
            except Exception:  # noqa: BLE001  infrastructure, still a red run
                verdict, detail = "ERROR", traceback.format_exc(limit=3)
        seconds = time.monotonic() - started
        artifacts.mkdir(parents=True, exist_ok=True)
        (artifacts / "requests.jsonl").write_text("".join(json.dumps(e) + "\n" for e in ctx.requests()))
        results.append({"scenario": name, "profile": args.profile, "verdict": verdict, "seconds": round(seconds, 1),
                        "detail": detail})
        print(f"{verdict} {args.profile} {name} ({seconds:.0f} s){': ' + detail if detail else ''}", flush=True)
    proxy.shutdown()
    (out / f"results-{args.profile}.json").write_text(json.dumps(results, indent=1))
    (out / "device-checklist.md").write_text(DEVICE_CHECKLIST)
    failed = [r for r in results if r["verdict"] != "PASS"]
    print(f"{len(results) - len(failed)}/{len(results)} passed on {args.profile}; artifacts in {out}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

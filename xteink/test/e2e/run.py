#!/usr/bin/env python3
"""Orbify's Xteink scenarios in upstream's SDL simulator (docs/design/emulated-release-tests.md,
stage 1), against the seeded BookOrbit server behind the fault proxy (tools/e2e/).

    tools/e2e/kit.py up                                  # once: server up and seeded
    xteink/test/e2e/run.py --checkout <CrossInk> --profile x4-pro [--scenario NAME] [--out DIR] [-v]

The checkout has the overlay applied and the profile's simulator built
(`pio run -e x4-pro-simulator`; profiles: x4-pro, x4-classic, x3). Each scenario gets its own SD
card and fault rules; it asserts on the firmware's log, the card and the proxy's request log, and
never compares screenshots (one scenario checks that a rectangle the log names has ink: the catalog's
stamp, patch 0038). Screenshots, logs and the proxy log land in --out (CI uploads them). Exit 1 on any
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
from sim import PROFILES, UI_THEME_BOOKORBIT, SdCard, Simulator, dark_pixels  # noqa: E402

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
    if not (card.crosspoint / "state.json").exists():  # the sleep sync runs for the last open book
        card.open_book(card.add_book(ctx.source("Standalone 01")))
    card.sync_on_sleep()
    run = ctx.sim.run(card, name, script="2500:POWER:120", timeout_s=kw.pop("timeout_s", 90), **kw)
    after(run.output, "Restarting into the BookOrbit sleep sync")
    return run


# --- Scenarios ------------------------------------------------------------------------------------


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
    """X5: the offline mirror's list requests reach the server as the server reads them. A query
    whose separator turned into a space ("sort=recently_read readStatus=reading") was answered 400
    and those lists were never saved (patch 0037 S6). Three sleep syncs: 0037 walks the mirror in
    slices of 10 requests per sleep."""
    card = ctx.card(tmp)
    for n in range(1, 4):
        run = sleep_sync(ctx, card, f"sleep-{n}")
        if "Mirror: saved for offline" in run.output:
            break
    saved = re.search(r"Mirror: saved for offline: .* \((\d+) failed\)", run.output)
    assert saved, "the mirror was not saved within three sleep syncs"
    lists = ctx.requests("/plugin/catalog/books")
    assert lists, "the mirror asked for no lists"
    # The X5 defect: one value swallowed the next parameter ("recently_read readStatus=reading").
    bad = [e for e in lists if e["status"] != 200 or any(re.search(r"\s\w+=", str(v)) for v in e["query"].values())]
    assert not bad, f"list requests the server refused or that swallowed a parameter: {bad[:3]}"
    assert saved.group(1) == "0", f"the mirror saved with failures: {saved.group(0)}"


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
    """X6 on the heap an X4 Pro has beside Tailscale (patch 0037 S1, S7): 39 KB free with a 20 KB
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
    largest block once Tailscale is up. Before patch
    0038 the match check's reply was refused (match check failed (8)), the copy stopped as heap
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
    """X3: the sleep sync's extras start no request when the heap is under the floor (patch 0037
    S1-S4, OrbifyHeap): the heap falls to 10 KB (under the X4s' 12 KB floor, patch 0038) while the
    mirror's first request is held by the proxy; the mirror then waits for the next sync instead of
    opening another request."""
    card = ctx.card(tmp)
    ctx.faults([{"match": {"path": "/plugin/catalog/root$"}, "action": "delay", "ms": 4000, "times": 1}])
    run = sleep_sync(ctx, card, "sleep", env={"ORBIFY_SIM_HEAP": "w2000:10000/6000"})
    tail = after(run.output, "ORBIFY_SIM_HEAP t=w2000")
    after(tail, "waiting for heap")
    after(tail, "Sleep sync over")
    root = ctx.requests("/plugin/catalog/root")
    assert root, "the mirror never started"
    later = [e for e in ctx.requests("/plugin/catalog/") if e["t"] > root[0]["t"]]
    assert not later, f"requests opened under the floor: {[e['path'] for e in later][:5]}"


@scenario(*X4S)
def next_cover_heap_floor(ctx: Context, tmp: Path) -> None:
    """X9: the End-of-Book page's next cover. A sync on its own connection fetches it only with
    42 KB free and a 20 KB block on the X3, 20 KB and 4 KB on the X4s (wolfSSL in PSRAM, patch 0038);
    under that it is left for the next sync. The sleep sync then fetches it on the connection it lends and decodes it with the radio
    off (patches 0036, 0037)."""
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
    """X7 (patch 0037 S9): the page of a series' middle book carries the series line from the card
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
    for 50 s) wakes the device within the watcher's grace, not after the step (patch 0037 S5)."""
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
    sleeps (patch 0037 S5). Every request is held 36 s: the sync's own seven take 250 s."""
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
    """X8 (patch 0037 S12): on the BookOrbit Home, Confirm on the sync tile refreshes Home
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


@scenario("x4-pro")
def catalog_cache_first(ctx: Context, tmp: Path) -> None:
    """Cache-first catalog (the user's rule, .167): with a saved copy that is not stale, opening the
    catalog brings no Wi-Fi up and asks the server nothing; ⟳ is what goes to the network. Before,
    every open joined Wi-Fi first, even offline with Tailscale off."""
    card = ctx.card(tmp)
    card.theme(UI_THEME_BOOKORBIT)
    sx, sy = home_tile(ctx.sim.run(card, "home", script="3000:QUIT", timeout_s=10).output, "sync")
    full = ctx.sim.run(card, "full", script=f"3000:TAP:{sx},{sy},1300", timeout_s=60)
    after(full.output, "Mirror: saved for offline")
    first = ctx.sim.run(card, "library", script="3000:SWIPE:0.8,0.5,0.2,0.5,250;5000:QUIT", timeout_s=10)
    cx, cy = home_tile(first.output, "catalog")  # on the Library page
    before = len(ctx.requests())
    run = ctx.sim.run(card, "open", script=f"3000:SWIPE:0.8,0.5,0.2,0.5,250;4500:TAP:{cx},{cy};10000:QUIT", timeout_s=16)
    after(run.output, "Catalog: opening from the cache, no Wi-Fi")
    asked = ctx.requests()[before:]
    assert not asked, f"opening a cached catalog asked the server: {[e['path'] for e in asked][:5]}"
    assert "STA event: connected" not in run.output, "opening a cached catalog joined Wi-Fi"


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
    has no ready cover (the open book's cover shows, F1); its sleep sync fetches a few covers on the
    lent connection and decodes them with the radio off. The next sleeps draw a ready cover at once
    from the card, never the one just shown, and each sync tops the batch up. (The simulator's run
    ends with the sync, before the redraw.)"""
    card = ctx.card(tmp)
    sleep_pick(card, **{"from": "discover", "hours": 0})
    first = sleep_sync(ctx, card, "sleep-1", timeout_s=150)
    after(first.output, "Sleep: BookOrbit Pick -> current book")
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
    leaves out every book: the covers leave the card and the sleep shows the current book (F1)."""
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
    after(second.output, "Sleep: BookOrbit Pick -> current book")
    count2, fetched2 = sleep_batch(second.output)
    assert count2 == 0 and fetched2 == 0, f"Library left out, yet batch {count2} ({fetched2} fetched)"
    assert not list((card.crosspoint / "orbify_sleep").glob("*.bmp")), "left-out covers stayed on the card"


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
    manifest = kit.seed()  # idempotent: puts back what an earlier run changed (want-to-read, users)

    proxy = bofault.serve(int(kit.ENV["BOFAULT_PORT"]), kit.SERVER, log=out / f"bofault-{args.profile}.jsonl")
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

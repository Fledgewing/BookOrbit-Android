"""Driving upstream's SDL simulator with the BookSync overlay built in (xteink/test/e2e/run.py).

One scenario = one SD card (a temp dir the simulator uses as fs_/), one or more simulator
processes, the fault proxy's log, and screenshots. The simulator re-execs itself on every restart
and every wake, so a run is a chain of processes; its log is one file.
"""

from __future__ import annotations

import base64
import json
import os
import shutil
import struct
import subprocess
import zlib
from enum import IntEnum
from dataclasses import dataclass
from pathlib import Path

# The simulator's fixed fake MAC (simulator package esp_mac.h): the credential obfuscation key and
# the device id the firmware reports.
SIM_MAC = bytes([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01])
SIM_DEVICE_ID = "crossink-" + SIM_MAC.hex()

# CrossInk settings values (CrossPointSettings.h at the CrossInk pin).
SHORT_PWRBTN_SLEEP = 1
SHORT_PWRBTN_BOOKORBIT_SYNC = 41
BOOKORBIT_SHORTCUT_IDS = 3
SYNC_BEHAVIOR_SMART = 1
UI_THEME_BOOKORBIT = 8

CRASH_PATTERNS = ("Assertion failed", "Segmentation fault", "AddressSanitizer", "std::bad_alloc", "Abort trap")

PROFILES = {  # profile -> PlatformIO env (xteink/overlay/platformio.local.ini)
    "x4-pro": "x4-pro-simulator",
    "x4-classic": "x4-classic-simulator",
    "x3": "simulator-X3",
}


# SilentRestart.h and main.cpp at tools/upstreams.lock's CrossInk pin. These
# tokens go through setup()'s real restore/validate/route path, never a UI stub.
class NetworkBootTarget(IntEnum):
    SLEEP_SYNC = 33
    CATALOG = 35
    HOME_REFRESH = 36
    HOME_SHELVES = 37


SILENT_REBOOT_MAGIC = 0xC1EAB007


def obfuscate(plaintext: str) -> str:
    """The firmware's stored-password format for the simulator's MAC: "CPV1" + FNV-1a 32 of
    (MAC + text), then the text, XORed with the MAC, base64."""
    h = 2166136261
    for b in SIM_MAC + plaintext.encode():
        h = ((h ^ b) * 16777619) & 0xFFFFFFFF
    payload = b"CPV1" + struct.pack("<I", h) + plaintext.encode()
    return base64.b64encode(bytes(c ^ SIM_MAC[i % len(SIM_MAC)] for i, c in enumerate(payload))).decode()


def fnv1a64(text: str) -> int:
    h = 14695981039346656037
    for b in text.encode():
        h = ((h ^ b) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return h


class SdCard:
    """One scenario's SD card: settings, BookOrbit account (pointed at the fault proxy), Wi-Fi."""

    def __init__(self, root: Path, proxy: str, kosync: dict):
        self.root = root
        self.fs = root / "fs_"
        self.crosspoint = self.fs / ".crosspoint"
        self.crosspoint.mkdir(parents=True)
        (self.fs / "books").mkdir()
        self.bookorbit = {"sync_mode": "custom", "username": kosync["username"], "password_obf": obfuscate(kosync["password"]),
                          "serverUrl": proxy, "syncBehavior": SYNC_BEHAVIOR_SMART, "downloadFolder": ""}
        self.settings = {"shortPwrBtn": SHORT_PWRBTN_BOOKORBIT_SYNC, "bookOrbitShortcutIds": BOOKORBIT_SHORTCUT_IDS}
        self.save()
        # These scenarios start on a configured reader; first-install release notes obscure input.
        (self.crosspoint / "state.json").write_text(json.dumps({"releaseNotesSeen": 65535}))
        # The simulator's Wi-Fi accepts any saved network: without one a network boot waits on the
        # network picker.
        (self.crosspoint / "wifi.json").write_text(json.dumps(
            {"lastConnectedSsid": "SimNet", "credentials": [{"ssid": "SimNet", "password": "simnet"}]}))

    def save(self) -> None:
        (self.crosspoint / "bookorbit.json").write_text(json.dumps(self.bookorbit))
        (self.crosspoint / "crossink-settings.json").write_text(json.dumps(self.settings))

    def sync_on_sleep(self) -> None:
        """Sync on Sleep on; a short Power press puts the device to sleep."""
        self.bookorbit["syncOnSleep"] = True
        self.settings["shortPwrBtn"] = SHORT_PWRBTN_SLEEP
        self.save()

    def theme(self, value: int) -> None:
        self.settings["uiTheme"] = value
        self.save()

    def add_book(self, source: Path, folder: str = "books") -> str:
        (self.fs / folder).mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, self.fs / folder / source.name)
        return f"/{folder}/{source.name}"

    def open_book(self, sim_path: str, asleep: bool = False) -> None:
        state = {"openEpubPath": sim_path, "releaseNotesSeen": 65535}
        if asleep:  # a run with wake=True resumes straight into the book
            state.update(lastSleepFromReader=True, showBootScreen=False)
        (self.crosspoint / "state.json").write_text(json.dumps(state))

    def epub_cache(self, sim_path: str) -> Path:
        return self.crosspoint / f"epub_{fnv1a64(sim_path)}"

    def download_index(self, entries: list[tuple[int, str]]) -> None:
        """The catalog's download index (BOD2, BookOrbitDownloadIndex): (book id, card path) of
        books on the card that came from BookOrbit. The header keys it to the server URL."""
        fnv = lambda raw: __import__("functools").reduce(lambda h, b: ((h ^ b) * 16777619) & 0xFFFFFFFF, raw, 2166136261)
        raws = [p.encode() for _, p in entries]
        out = bytearray(b"BOD2") + struct.pack("<II", zlib.crc32(self.bookorbit["serverUrl"].encode()), len(entries))
        offset = 12 + 22 * len(entries)
        for (book_id, path), raw in zip(entries, raws):
            size = (self.fs / path.lstrip("/")).stat().st_size
            out += struct.pack("<qIIIH", book_id, size, fnv(raw), offset, len(raw))
            offset += len(raw)
        (self.crosspoint / "bookorbit_downloads.bin").write_bytes(bytes(out) + b"".join(raws))

    def progress(self, sim_path: str, spine: int, page: int, page_count: int) -> None:
        """The reader's legacy 6-byte position record (still read); the other save slot goes."""
        path = self.epub_cache(sim_path) / "progress.bin"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(struct.pack("<HHH", spine, page, page_count))
        path.with_name("progress.bin.bak").unlink(missing_ok=True)


@dataclass
class Run:
    output: str
    returncode: int


class Simulator:
    def __init__(self, program: Path, artifacts: Path, verbose: bool = False):
        self.program = program
        self.artifacts = artifacts
        self.verbose = verbose

    def run(self, card: SdCard, name: str, script: str = "", timeout_s: float = 30, after_reboot: str | None = None,
            wake: bool = False, screenshots: dict[int, str] | None = None, env: dict[str, str] | None = None,
            choice: str = "none", quit_after_sync: bool = True, input_from_poll: bool = False,
            boot_target: NetworkBootTarget | None = None) -> Run:
        """One simulator chain on `card`. Screenshots {ms: name} land in artifacts as PNG.
        Scenario hooks of upstream's sync activity: CROSSINK_SIM_BOOKORBIT_CHOICE answers its
        choice screens, ..._QUIT_AFTER_SYNC ends the process once the sync settles."""
        e = os.environ.copy()
        for key in ("MAGIC", "TARGET", "PAYLOAD"):
            e.pop("CROSSPOINT_SIM_SILENT_REBOOT_" + key, None)
        if boot_target is not None:
            e.update(CROSSPOINT_SIM_SILENT_REBOOT_MAGIC=str(SILENT_REBOOT_MAGIC),
                     CROSSPOINT_SIM_SILENT_REBOOT_TARGET=str(int(boot_target)),
                     CROSSPOINT_SIM_SILENT_REBOOT_PAYLOAD="0")
        # The software renderer: SDL's dummy video driver has no accelerated one on Linux (CI), where the
        # simulator then had no renderer and silently saved no screenshots.
        e.update(SDL_VIDEODRIVER="dummy", SDL_RENDER_DRIVER="software", CROSSPOINT_SIM_INPUT_SCRIPT=script, CROSSINK_SIM_BOOKORBIT_CHOICE=choice)
        # A cold/contended settings write can outlast an entire short button press.
        # Sleep helpers start their script at the first input poll, not process start.
        e.pop("ORBIFY_SIM_INPUT_FROM_POLL", None)
        if input_from_poll:
            e["ORBIFY_SIM_INPUT_FROM_POLL"] = "1"
        if self.program.parent.name in ("x4-pro-simulator", "x4-classic-simulator"):
            # X4 cache JSON allocates in PSRAM. A zero-sized simulator pool silently defeats it.
            e["CROSSINK_SIMULATOR_PSRAM_TOTAL"] = "8388608"
        if quit_after_sync:
            e["CROSSINK_SIM_BOOKORBIT_QUIT_AFTER_SYNC"] = "1"
        if after_reboot is not None:
            e["CROSSPOINT_SIM_INPUT_SCRIPT_AFTER_REBOOT"] = after_reboot
        if wake:
            e["CROSSPOINT_SIM_WAKE_REASON"] = "power"
        shots_dir = card.root / "shots"
        if screenshots:
            shots_dir.mkdir(exist_ok=True)
            e["CROSSPOINT_SIM_SCREENSHOTS"] = ";".join(f"{ms}:{shots_dir / (n + '.bmp')}" for ms, n in screenshots.items())
        e.update(env or {})
        log_path = card.root / f"{name}.log"
        returncode = 0
        with log_path.open("w") as log:
            proc = subprocess.Popen([str(self.program)], cwd=card.root, env=e, stdout=log, stderr=subprocess.STDOUT,
                                    stdin=subprocess.DEVNULL, start_new_session=True)
            try:
                returncode = proc.wait(timeout=timeout_s)
            except subprocess.TimeoutExpired:
                # Its whole process group: re-exec'd successors and curl children included.
                os.killpg(proc.pid, 9)
                proc.wait()
                returncode = 0  # a run that ends on its time box; the assertions decide
        output = log_path.read_text(errors="replace")
        self.artifacts.mkdir(parents=True, exist_ok=True)
        shutil.copy2(log_path, self.artifacts / log_path.name)
        if screenshots:
            for bmp in sorted(shots_dir.glob("*.bmp")):
                (self.artifacts / (bmp.stem + ".png")).write_bytes(bmp_to_png(bmp.read_bytes()))
        if self.verbose:
            print(output)
        if returncode < 0:
            tail = (output.rstrip().splitlines() or ["(no output)"])[-1]
            raise AssertionError(f"the simulator died on signal {-returncode} after: {tail[:160]}")
        for pattern in CRASH_PATTERNS:
            if pattern in output:
                raise AssertionError(f"crash in the simulator output: {pattern}")
        return Run(output, returncode)


def dark_pixels(data: bytes, x: int, y: int, w: int, h: int) -> int:
    """Pixels darker than mid-grey in a rectangle of a simulator BMP screenshot (logical pixels)."""
    offset, = struct.unpack_from("<I", data, 10)
    width, height, _, bpp = struct.unpack_from("<iiHH", data, 18)
    stride = (width * bpp // 8 + 3) & ~3
    step = bpp // 8
    count = 0
    for row in range(max(0, y), min(abs(height), y + h)):
        src = height - 1 - row if height > 0 else row
        for col in range(max(0, x), min(width, x + w)):
            i = offset + src * stride + col * step
            if data[i] + data[i + 1] + data[i + 2] < 3 * 128:
                count += 1
    return count


def bmp_to_png(data: bytes) -> bytes:
    """The simulator's 24/32-bit BMP screenshots as PNG (review artifacts; never compared)."""
    offset, = struct.unpack_from("<I", data, 10)
    width, height, _, bpp = struct.unpack_from("<iiHH", data, 18)
    stride = (width * bpp // 8 + 3) & ~3
    rows = []
    for y in range(abs(height)):
        src = height - 1 - y if height > 0 else y
        line = data[offset + src * stride: offset + src * stride + width * bpp // 8]
        step = bpp // 8
        rows.append(b"\x00" + b"".join(bytes((line[i + 2], line[i + 1], line[i])) for i in range(0, len(line), step)))

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, abs(height), 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 6)) + chunk(b"IEND", b""))

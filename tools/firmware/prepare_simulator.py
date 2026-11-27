#!/usr/bin/env python3
"""Apply host build configuration without changing the firmware source commit."""
import json
from pathlib import Path
import re
import sys

config = json.loads(Path(__file__).with_name("simulator.json").read_text())
if not re.fullmatch(r"[0-9a-f]{40}", config["commit"]):
    raise SystemExit("simulator dependency requires an immutable commit")
ini = Path(sys.argv[1]) / "platformio.ini"
text = ini.read_text()
# F02 owns the immutable simulator pin and Linux hook in the firmware source.
# Keep supporting the PR #200 seed, but never rewrite the owned configuration.
pinned = f'  simulator={config["repository"]}#{config["commit"]}\n'
if pinned in text and '  pre:tools/ci/simulator_build.py\n' in text:
    shared = ini.parent / "tools/ci/simulator.json"
    if json.loads(shared.read_text()) != config:
        raise SystemExit("BookSync simulator pins differ")
    print("Using firmware-owned pinned simulator configuration")
    raise SystemExit(0)
# CrossInk's native config assumes Clang's spelling. GCC needs this equivalent
# for generated gzip byte arrays declared as char; the device build is untouched.
replacements = {
    "  -Wno-c++11-narrowing\n": "  -Wno-narrowing\n",
    "  pre:scripts/simulator_tls.py\n":
        "  pre:../../tools/firmware/simulator_build.py\n  pre:scripts/simulator_tls.py\n",
    f'  simulator={config["repository"]}\n':
        f'  simulator={config["repository"]}#{config["commit"]}\n',
}
for old, new in replacements.items():
    if text.count(old) != 1:
        raise SystemExit("simulator configuration changed; review the build adjustment")
    text = text.replace(old, new)
ini.write_text(text)

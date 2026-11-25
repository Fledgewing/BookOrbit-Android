#!/usr/bin/env python3
"""Shared BookSync identity. 0.11 firmware retains legacy tags for the OTA bridge."""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PATTERN = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(preview|rc)\.([1-9]\d*))?")

def version():
    value = json.loads((ROOT / "shared/version.json").read_text())["version"]
    if not PATTERN.fullmatch(value):
        raise ValueError("BookSync version must be MAJOR.MINOR.PATCH[-preview.N|-rc.N]")
    return value

def unified(value):
    match = PATTERN.fullmatch(value)
    if not match:
        raise ValueError("Invalid BookSync version")
    return tuple(map(int, match.group(1, 2, 3))) >= (0, 12, 0)

def firmware(value, upstream, run):
    if unified(value):
        # '+' is reserved for the single SemVer metadata delimiter.
        return value + "+crossink." + upstream.removeprefix("v").replace("+", ".")
    base = upstream.removeprefix("v")
    match = re.match(r"\d+\.\d+\.\d+", base)
    if not match:
        raise ValueError("Invalid CrossInk base")
    return match[0] + "." + str(100 + int(run)) + base[match.end():]

def check_release(value):
    # Legacy Android releases keep accepting tag-driven versions through 0.11.
    base = re.match(r"(\d+)\.(\d+)\.(\d+)", value)
    if not base:
        raise ValueError("Invalid release version")
    if tuple(map(int, base.groups())) >= (0, 12, 0) and value != version():
        raise ValueError("Release version differs from shared/version.json")

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("command", choices=["version", "unified", "channel", "firmware", "check"])
    p.add_argument("args", nargs="*")
    args = p.parse_args()
    value = version()
    if args.command == "version":
        print(value)
    elif args.command == "unified":
        print(str(unified(value)).lower())
    elif args.command == "channel":
        print("prerelease" if "-" in value else "stable")
    elif args.command == "firmware":
        print(firmware(value, *args.args))
    elif args.command == "check":
        check_release(*args.args)

if __name__ == "__main__":
    main()

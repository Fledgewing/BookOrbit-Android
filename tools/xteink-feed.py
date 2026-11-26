#!/usr/bin/env python3
"""Reduce GitHub releases to current BookSync channels plus legacy OTA bridges."""
import json
import os
from urllib.parse import quote
import re
import sys

def identity(release):
    tag = release["tag_name"].removeprefix("xteink-v")
    # A bridge retains the legacy tag; its product identity is recorded in the notes.
    marker = re.search(r"(?:^|\s)booksync_version=(\d+\.\d+\.\d+(?:-(?:preview|rc)\.[1-9]\d*)?)(?=\s|$)",
                       release.get("body") or "")
    if re.fullmatch(r"\d+\.\d+\.\d+(?:-(?:preview|rc)\.[1-9]\d*)?(?:\+crossink\.[\w.-]+)?", tag):
        return tag.split("+")[0]
    return marker[1] if marker else None

def product_key(release):
    book = identity(release) or "0.0.0"
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-(preview|rc)\.(\d+))?", book)
    return (*map(int, match.group(1, 2, 3)),
            {None: 2, "rc": 1, "preview": 0}[match[4]], int(match[5] or 0))

def build_feed(releases):
    repo = os.environ.get("GITHUB_REPOSITORY")
    releases = sorted((r for r in releases if not r.get("draft") and
                       r["tag_name"].startswith("xteink-v")), key=lambda r: r["created_at"], reverse=True)
    selected = []
    for pre in (False, True):
        channel = [r for r in releases if r["prerelease"] == pre]
        # Keep legacy channel heads indefinitely. Old firmware compares numeric tags and
        # cannot cross from 2.0.0.N to 0.12 without first installing this bridge.
        legacy = [r for r in channel if re.match(r"xteink-v\d+\.\d+\.\d+\.\d+", r["tag_name"])]
        product = sorted((r for r in channel if r not in legacy and identity(r)),
                         key=product_key, reverse=True)
        for group in (product, legacy):
            if group and group[0] not in selected:
                selected.append(group[0])
    result = []
    for release in selected:
        entry = {key: release[key] for key in ("tag_name", "name", "draft", "prerelease", "created_at")}
        entry["assets"] = [{k: a[k] for k in ("name", "size", "digest", "browser_download_url") if k in a}
                           for a in release["assets"]]
        if repo:
            for asset in entry["assets"]:
                asset["browser_download_url"] = (f"https://github.com/{repo}/releases/download/"
                    f"{quote(release['tag_name'], safe='')}/{quote(asset['name'], safe='')}")
        book = identity(release)
        if book:
            entry["booksync_version"] = book
        result.append(entry)
    return result

if __name__ == "__main__":
    json.dump(build_feed(json.load(sys.stdin)), sys.stdout, indent=2)
    print()

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

def build_feed(releases, repo=None):
    releases = sorted((r for r in releases if not r.get("draft") and
                       r["tag_name"].startswith("xteink-v")), key=lambda r: r["created_at"], reverse=True)
    selected = []
    stems = ("firmware-x4-pro", "firmware-x4-classic", "firmware-x3-x4")

    def keep_heads(group):
        # Select a head per device: previews may contain only changed readers.
        # Preserve original assets so tags, versions and signatures stay bound.
        for stem in stems:
            head = next((r for r in group if any(
                a["name"].startswith(stem + "-v") and a["name"].endswith(".bin")
                for a in r["assets"])), None)
            if head is not None and head not in selected:
                selected.append(head)

    # Old readers still need both numeric bridge heads, regardless of product channel.
    legacy = [r for r in releases if re.match(r"xteink-v\d+\.\d+\.\d+\.\d+", r["tag_name"])]
    for pre in (False, True):
        keep_heads([r for r in legacy if r["prerelease"] == pre])
    # Product labels alone classify new readers' channels. A newer preview must
    # never evict an RC, including an older RC retained for an unchanged device.
    product = sorted((r for r in releases if identity(r)), key=product_key, reverse=True)
    for minimum in (2, 1, 0):  # Stable; RC allows stable; Preview allows every product label
        keep_heads([r for r in product if product_key(r)[3] >= minimum])

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
    json.dump(build_feed(json.load(sys.stdin), os.environ["GITHUB_REPOSITORY"]), sys.stdout, indent=2)
    print()

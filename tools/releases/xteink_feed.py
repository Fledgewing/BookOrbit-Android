#!/usr/bin/env python3
"""Refresh firmware previews; retain stable feed entries until explicit promotion."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('feed', Path(__file__).resolve().parents[1] / 'xteink-feed.py')
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)


def refresh(releases, previous, promote_stable=False, repo=None):
    if promote_stable:
        return feed.build_feed(releases, repo)
    # GitHub's mutable prerelease flag is not promotion authorization. Retain the
    # complete stable entries (including asset signatures) from the current feed.
    stable = [r for r in previous if not r['prerelease']]
    tags = {r['tag_name'] for r in stable}
    previews = feed.build_feed([r for r in releases if r['prerelease'] and r['tag_name'] not in tags], repo)
    return stable + previews


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--previous', type=Path, required=True)
    parser.add_argument('--promote-stable', choices=['true', 'false'], default='false')
    args = parser.parse_args()
    json.dump(refresh(json.load(sys.stdin), json.loads(args.previous.read_text()),
                      args.promote_stable == 'true', os.environ['GITHUB_REPOSITORY']), sys.stdout, indent=2)
    print()

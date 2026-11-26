#!/usr/bin/env python3
"""Coordinator helpers: snapshot, seed, or verify exact raw feed bytes. No releases/tags."""
import argparse
import importlib.util
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('mirror', ROOT / 'stub/mirror.py')
mirror = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mirror)


def direct(repo, branch, path, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    status = subprocess.check_output([
        'curl', '--disable', '--silent', '--show-error', '--max-time', '60',
        '--output', str(output), '--write-out', '%{http_code}',
        f'https://raw.githubusercontent.com/{repo}/{branch}/{path}',
    ], text=True)
    if status != '200':
        raise RuntimeError(f'{repo}/{branch}/{path}: expected direct HTTP 200, got {status}')
    return output.read_bytes()


def run(mode, old, new, directory):
    if mode == 'seed':
        mirror.fetch = lambda branch, path: (directory / branch / path).read_bytes()
        mirror.mirror(old)
        return
    for branch, paths in mirror.FEEDS.items():
        for path in paths:
            target = directory / branch / path
            legacy = direct(old, branch, path, target)
            if mode == 'verify':
                canonical = direct(new, branch, path, directory / 'canonical' / branch / path)
                if legacy != canonical:
                    raise RuntimeError(f'{branch}/{path}: old and canonical feed bytes differ')
                print(f'{branch}/{path}: direct HTTP 200; identical bytes')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['snapshot', 'seed', 'verify'])
    parser.add_argument('old')
    parser.add_argument('new')
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    run(args.mode, args.old, args.new, args.directory)

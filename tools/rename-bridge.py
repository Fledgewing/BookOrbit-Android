#!/usr/bin/env python3
"""Gate the repository rename on published stable bridge releases. Dry-run by default."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
OLD = 'Fledgewing/Orbify'
NEW = 'Fledgewing/BookSync'
FEEDS = ('android-feed/android/releases.json', 'xteink-feed/xteink/releases.json',
         'xteink-feed/xteink/releases.json.sig')
STEMS = ('firmware-x4-pro', 'firmware-x4-classic', 'firmware-x3-x4')
REDIRECTS = {301, 302, 307}


def gh(path, method='GET', **fields):
    args = ['gh', 'api', '--method', method, path]
    for key, value in fields.items():
        args += ['-f', f'{key}={value}']
    return json.loads(subprocess.check_output(args))


def releases():
    pages = json.loads(subprocess.check_output(['gh', 'api', '--paginate', '--slurp',
                                               f'repos/{OLD}/releases?per_page=100']))
    return [release for page in pages for release in page]


def curl(url, follow=False):
    with tempfile.TemporaryDirectory() as directory:
        output = Path(directory) / 'body'
        args = ['curl', '--disable', '--silent', '--show-error', '--max-time', '180',
                '--proto', '=https', '--proto-redir', '=https', '--max-redirs', '10',
                '--output', str(output), '--write-out', '%{http_code}']
        if follow:
            args += ['--location']
        status = int(subprocess.check_output([*args, url], text=True))
        return status, output.read_bytes()


def read_feed(repo, path):
    status, body = curl(f'https://raw.githubusercontent.com/{repo}/{path}')
    if status != 200:
        raise ValueError(f'{repo}/{path}: expected direct HTTP 200, got {status}')
    return body


def signed_feeds(repo):
    copies = {path: read_feed(repo, path) for path in FEEDS}
    envelope = json.loads(copies[FEEDS[0]])
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        for tag, name, body, signature in (
            ('android-feed', 'android-releases.json', envelope['payload'].encode(), envelope['signatures'].encode()),
            ('xteink-feed', 'releases.json', copies[FEEDS[1]], copies[FEEDS[2]]),
        ):
            artifact = directory / name
            artifact.write_bytes(body)
            signatures = directory / 'SIGNATURES'
            signatures.write_bytes(signature)
            subprocess.run([str(ROOT / 'tools/feed-keys/feed-keys'), 'verify', '--tag', tag,
                            str(signatures), str(artifact)], check=True, stdout=subprocess.DEVNULL)
    return json.loads(envelope['payload']), json.loads(copies[FEEDS[1]])


def version_key(tag):
    # Compared only against a Stable bridge: every prerelease at that core is lower.
    match = re.fullmatch(r'(?:android-)?v(\d+)\.(\d+)\.(\d+)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?', tag)
    if not match:
        raise ValueError(f'Unrecognized Android release tag: {tag}')
    return tuple(map(int, match.group(1, 2, 3)))


def firmware_key(tag):
    match = re.fullmatch(r'xteink-v(\d+)\.(\d+)\.(\d+)\.(\d+)(?:\+[^\s]+)?', tag)
    if not match:
        raise ValueError('Rename bridge must retain the four-part firmware version scheme')
    return tuple(map(int, match.group(1, 2, 3, 4)))


def image_assets(release):
    return [next((a for a in release['assets'] if a['name'].startswith(stem + '-v') and
                  a['name'].endswith('.bin')), None) for stem in STEMS]


def gate(version, firmware_tag, published, latest, android, firmware):
    if not re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', version):
        raise ValueError('Bridge version must be Stable MAJOR.MINOR.PATCH')
    tag = 'v' + version
    stable = [r for r in published if not r.get('draft') and not r.get('prerelease')]
    app = next((r for r in stable if r['tag_name'] == tag), None)
    fw = next((r for r in stable if r['tag_name'] == firmware_tag), None)
    if app is None or latest.get('tag_name') != tag or latest.get('draft') or latest.get('prerelease'):
        raise ValueError('Bridge must be the published Android Stable/latest release')
    firmware_version = firmware_key(firmware_tag)
    if re.search(r'(?:[-.]rc|beta|alpha)[.-]?\d', firmware_tag, re.IGNORECASE):
        raise ValueError('An upstream RC/beta base cannot be the stable firmware bridge')
    if fw is None:
        raise ValueError('Bridge firmware must be published Stable')
    all_fw = [r for r in published if not r.get('draft') and r['tag_name'].startswith('xteink-v')]
    if any(firmware_key(r['tag_name']) > firmware_version for r in all_fw):
        raise ValueError('A higher firmware version would bypass the bridge')
    newest = max(all_fw, key=lambda r: r.get('published_at') or r['created_at'])
    if newest['tag_name'] != firmware_tag:
        raise ValueError('Bridge must be the latest firmware release, including preview channels')
    if not re.search(r'(?:^|\s)booksync_version=' + re.escape(version) + r'(?=\s|$)', fw.get('body') or ''):
        raise ValueError('Firmware bridge product version marker is missing or different')
    if not all(image_assets(fw)):
        raise ValueError('Bridge firmware must include X4 Pro, X4 Classic and X3 images')
    if tag in android['withdrawn']:
        raise ValueError('Android bridge is withdrawn')
    offered = [r for r in android['releases'] if not r.get('draft') and r['tag_name'] not in android['withdrawn']]
    if not any(r['tag_name'] == tag and not r.get('prerelease') for r in offered):
        raise ValueError('Signed Android feed does not list the stable bridge')
    if any(version_key(r['tag_name']) > version_key(tag) for r in offered):
        raise ValueError('A newer Android preview would bypass the bridge')
    entry = next((r for r in firmware if r['tag_name'] == firmware_tag and not r.get('draft') and
                  not r.get('prerelease') and r.get('booksync_version') == version), None)
    if entry is None or not all(image_assets(entry)):
        raise ValueError('Signed firmware feed does not list the bridge for every reader')
    if any(firmware_key(r['tag_name']) > firmware_version for r in firmware if not r.get('draft')):
        raise ValueError('A higher offered firmware preview would bypass the bridge')
    # Match offered assets to published artifacts, not just a display version string.
    for feed, release in ((next(r for r in offered if r['tag_name'] == tag), app), (entry, fw)):
        assets = {(a['name'], a['browser_download_url']) for a in release['assets']}
        if not {(a['name'], a['browser_download_url']) for a in feed['assets']} <= assets:
            raise ValueError('Feed assets differ from the published bridge')
    apk = next((a for a in app['assets'] if a['name'].endswith('.apk')), None)
    plugin = next((a for a in app['assets'] if a['name'] == 'orbit.koplugin.zip'), None)
    if not apk or not plugin:
        raise ValueError('Android bridge must include both companion and plugin')
    if not {apk['name'], plugin['name']} <= {a['name'] for a in next(r for r in offered if r['tag_name'] == tag)['assets']}:
        raise ValueError('Signed Android feed omits companion or plugin')
    return [apk, plugin, *image_assets(fw)]


def download_pair(url):
    for repo in (OLD, NEW):
        prefix = f'https://github.com/{repo}/releases/download/'
        if url.startswith(prefix):
            suffix = url[len(prefix):]
            return tuple(f'https://github.com/{name}/releases/download/{suffix}' for name in (OLD, NEW))
    raise ValueError('Bridge download must belong to this repository')


def verify(assets):
    for path in ('releases/latest', 'releases?per_page=5', 'releases?per_page=25', 'releases?per_page=30'):
        old = f'https://api.github.com/repos/{OLD}/{path}'
        new = f'https://api.github.com/repos/{NEW}/{path}'
        if curl(new)[0] != 200 or curl(old)[0] not in REDIRECTS or curl(old, follow=True)[0] != 200:
            raise ValueError(f'API rename verification failed: {path}')
    for path in FEEDS:
        new = read_feed(NEW, path)
        status, old = curl(f'https://raw.githubusercontent.com/{OLD}/{path}')
        if status in REDIRECTS:
            status, old = curl(f'https://raw.githubusercontent.com/{OLD}/{path}', follow=True)
        if status != 200 or old != new:
            raise ValueError(f'Raw feed alias/redirect verification failed: {path}')
    for asset in assets:
        old, new = download_pair(asset['browser_download_url'])
        if curl(old)[0] not in REDIRECTS:
            raise ValueError('Old download does not redirect')
        old_status, old_bytes = curl(old, follow=True)
        new_status, new_bytes = curl(new, follow=True)
        if old_status != 200 or new_status != 200 or hashlib.sha256(old_bytes).digest() != hashlib.sha256(new_bytes).digest():
            raise ValueError('Release download redirect/content verification failed')
    signed_feeds(NEW)


def prepare(version, firmware_tag):
    # Every read and gate completes before the sole mutation. Never create the old name.
    original = gh(f'repos/{OLD}')
    if original.get('full_name') != OLD or curl(f'https://api.github.com/repos/{NEW}')[0] != 404:
        raise ValueError('Expected the current name and an unused canonical repository name')
    published = releases()
    latest = gh(f'repos/{OLD}/releases/latest')
    android, firmware = signed_feeds(OLD)
    assets = gate(version, firmware_tag, published, latest, android, firmware)
    for limit, tag in ((5, 'v' + version), (25, firmware_tag)):
        listing = gh(f'repos/{OLD}/releases?per_page={limit}')
        if tag not in {r['tag_name'] for r in listing if not r.get('draft')} :
            raise ValueError(f'Legacy release-list page of {limit} omits the bridge')
    for asset in assets:
        download_pair(asset['browser_download_url'])
    return assets, original


def execute(version, firmware_tag):
    assets, original = prepare(version, firmware_tag)
    renamed = gh(f'repos/{OLD}', method='PATCH', name='BookSync')
    if renamed.get('full_name') != NEW or renamed.get('id') != original['id']:
        raise ValueError('Unexpected rename response; coordinator must inspect repository state')
    for attempt in range(12):
        try:
            verify(assets)
            return
        except (ValueError, subprocess.CalledProcessError):
            if attempt == 11:
                raise
            time.sleep(5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bridge-version', help='Published Stable Android/product version, e.g. 0.11.4')
    parser.add_argument('--firmware-tag', help='Exact stable bridge xteink-v tag (legacy numbering is retained)')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if (args.apply or args.bridge_version or args.firmware_tag) and not (args.bridge_version and args.firmware_tag):
        parser.error('Supply both --bridge-version and --firmware-tag')
    print('Plan: verify stable bridge releases and both signed feeds; PATCH the repository name; verify redirects.')
    print('Never recreate the previous repository name. Bring readers online for the bridge before renaming.')
    if args.apply:
        execute(args.bridge_version, args.firmware_tag)
    elif args.bridge_version:
        prepare(args.bridge_version, args.firmware_tag)
        print('Bridge gate passed; dry-run only, no mutations.')
    else:
        print('Dry-run: no network requests or mutations. Add --apply only after the documented bridge rollout.')
    print(f'git remote set-url origin https://github.com/{NEW}.git')
    print(f'git remote set-url origin git@github.com:{NEW}.git')


if __name__ == '__main__':
    main()

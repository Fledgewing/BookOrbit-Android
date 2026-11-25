#!/usr/bin/env python3
"""Republish the signed Android feed; never create or edit a release or tag."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BRANCH = 'android-feed'
PATH = 'android/releases.json'


def gh(*args):
    return subprocess.check_output(['gh', *args], text=True)


def run(withdraw):
    if withdraw and not re.fullmatch(r'(?:android-)?v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', withdraw):
        raise ValueError('withdraw_tag must be an Android release tag')
    repo = os.environ['GITHUB_REPOSITORY']
    tool = str(ROOT / 'tools/feed-keys/feed-keys')
    # Branches are listed to distinguish initial bootstrap from a failed feed fetch.
    branches = json.loads(gh('api', '--paginate', '--slurp', f'repos/{repo}/branches?per_page=100'))
    exists = any(b['name'] == BRANCH for page in branches for b in page)
    old_sha = None
    withdrawn = set(json.loads((ROOT / 'shared/withdrawn-android.json').read_text()))
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        payload = tmp / 'android-releases.json'
        signatures = tmp / 'SIGNATURES'
        if exists:
            old = json.loads(gh('api', f'repos/{repo}/contents/{PATH}?ref={BRANCH}'))
            old_sha = old['sha']
            envelope = json.loads(base64.b64decode(old['content']))
            payload.write_text(envelope['payload'])
            signatures.write_text(envelope['signatures'])
            subprocess.run([tool, 'verify', '--tag', BRANCH, str(signatures), str(payload)], check=True)
            withdrawn.update(json.loads(envelope['payload'])['withdrawn'])
        if withdraw:
            # A typo must not silently create an ineffective withdrawal.
            gh('release', 'view', withdraw, '-R', repo, '--json', 'tagName')
            withdrawn.add(withdraw)
        pages = json.loads(gh('api', '--paginate', '--slurp', f'repos/{repo}/releases?per_page=100'))
        releases = [{
            'tag_name': r['tag_name'], 'draft': r['draft'], 'prerelease': r.get('prerelease', False),
            'assets': [{'name': a['name'], 'browser_download_url': a['browser_download_url']}
                       for a in r.get('assets', [])],
        } for page in pages for r in page
            if re.match(r'^(?:android-)?v\d', r['tag_name']) and not r['draft']]
        if not releases:
            raise ValueError('refusing an empty Android release feed')
        payload.write_text(json.dumps({'withdrawn': sorted(withdrawn), 'releases': releases}, separators=(',', ':')))
        signatures.write_text(subprocess.check_output([tool, 'sign', '--tag', BRANCH, str(payload)], text=True))
        subprocess.run([tool, 'verify', '--tag', BRANCH, str(signatures), str(payload)], check=True)
        envelope = json.dumps({'payload': payload.read_text(), 'signatures': signatures.read_text()}).encode()
        if not exists:
            gh('api', f'repos/{repo}/git/refs', '-f', f'ref=refs/heads/{BRANCH}', '-f', f'sha={os.environ["GITHUB_SHA"]}')
        request = {'message': 'Refresh signed Android release safety feed', 'branch': BRANCH,
                   'content': base64.b64encode(envelope).decode()}
        if old_sha:
            request['sha'] = old_sha
        request_file = tmp / 'request.json'
        request_file.write_text(json.dumps(request))
        gh('api', '-X', 'PUT', f'repos/{repo}/contents/{PATH}', '--input', str(request_file))
        print('Signed Android feed published; withdrawn: ' + ', '.join(sorted(withdrawn)))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--withdraw', default='')
    run(parser.parse_args().withdraw)

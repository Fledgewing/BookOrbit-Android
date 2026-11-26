#!/usr/bin/env python3
"""Mirror public feeds atomically per branch, using only the destination's token."""
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.request

SOURCE = 'Fledgewing/BookSync'
FEEDS = json.loads(Path(__file__).with_name('feeds.json').read_text())


def fetch(branch, path):
    # Intentionally anonymous: never send GH_TOKEN to the source repository.
    url = f'https://raw.githubusercontent.com/{SOURCE}/{branch}/{path}'
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read()


def api(repo, method, path, body=None):
    with tempfile.TemporaryDirectory() as directory:
        args = ['gh', 'api', '--method', method, f'repos/{repo}/{path}']
        if body is not None:
            request = Path(directory) / 'request.json'
            request.write_text(json.dumps(body))
            args += ['--input', str(request)]
        return json.loads(subprocess.check_output(args))


def blob_sha(content):
    return hashlib.sha1(f'blob {len(content)}\0'.encode() + content).hexdigest()


def mirror(repo):
    if repo.casefold() == SOURCE.casefold():
        raise ValueError('refusing to mirror into the source repository')
    # Fetch everything first. An unavailable signature/feed leaves all branches alone.
    copies = {branch: {path: fetch(branch, path) for path in paths}
              for branch, paths in FEEDS.items()}
    branches = {b['name'] for b in api(repo, 'GET', 'branches?per_page=100')}
    for branch, files in copies.items():
        parent = None
        existing = {}
        if branch in branches:
            parent = api(repo, 'GET', f'git/ref/heads/{branch}')['object']['sha']
            commit = api(repo, 'GET', f'git/commits/{parent}')
            existing = {e['path']: e['sha'] for e in
                        api(repo, 'GET', f"git/trees/{commit['tree']['sha']}?recursive=1")['tree']
                        if e['type'] == 'blob'}
        desired = {path: blob_sha(data) for path, data in files.items()}
        if existing == desired:
            print(f'{branch}: unchanged')
            continue
        entries = []
        for path, data in files.items():
            blob = api(repo, 'POST', 'git/blobs', {
                'encoding': 'base64', 'content': base64.b64encode(data).decode()})
            entries.append({'path': path, 'mode': '100644', 'type': 'blob', 'sha': blob['sha']})
        # A fresh tree copies only feeds, never the source project's code or history.
        tree = api(repo, 'POST', 'git/trees', {'tree': entries})
        body = {'message': 'Mirror BookSync update feeds', 'tree': tree['sha']}
        if parent:
            body['parents'] = [parent]
        commit = api(repo, 'POST', 'git/commits', body)
        if parent:
            api(repo, 'PATCH', f'git/refs/heads/{branch}', {'sha': commit['sha'], 'force': False})
        else:
            api(repo, 'POST', 'git/refs', {'ref': f'refs/heads/{branch}', 'sha': commit['sha']})
        print(f'{branch}: updated')


if __name__ == '__main__':
    mirror(os.environ['GITHUB_REPOSITORY'])

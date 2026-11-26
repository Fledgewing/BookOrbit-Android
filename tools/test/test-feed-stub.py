#!/usr/bin/env python3
"""Offline tests of mirror bytes, branch atomicity, no-op runs and migration gates."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('mirror', ROOT / 'stub/mirror.py')
mirror = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mirror)
spec_ops = importlib.util.spec_from_file_location('ops', ROOT / 'tools/rename-feeds.py')
ops = importlib.util.module_from_spec(spec_ops)
spec_ops.loader.exec_module(ops)


class MirrorTest(unittest.TestCase):
    def run_mirror(self, existing, changed=False):
        calls = []
        content = b'{"payload":"signed bytes\\n"}\r\n'
        def api(repo, method, path, body=None):
            calls.append((method, path, body))
            self.assertEqual('fixture/stub', repo)
            if path.startswith('branches?'):
                return [{'name': b} for b in mirror.FEEDS] if existing else []
            if path.startswith('git/ref/'):
                return {'object': {'sha': path.split('/')[-1]}}
            if path.startswith('git/commits/'):
                return {'tree': {'sha': path.split('/')[-1]}}
            if path.startswith('git/trees/'):
                branch = path.split('/')[-1].split('?')[0]
                return {'tree': [{'path': p, 'type': 'blob', 'sha': mirror.blob_sha(b'previous' if changed else content)}
                                 for p in mirror.FEEDS[branch]]}
            if path == 'git/blobs':
                self.assertEqual(content, base64.b64decode(body['content']))
                return {'sha': mirror.blob_sha(content)}
            return {'sha': 'new-object'}
        with patch.object(mirror, 'fetch', return_value=content), patch.object(mirror, 'api', side_effect=api):
            mirror.mirror('fixture/stub')
        return calls

    def test_changed_feeds_commit_atomically_with_exact_bytes(self):
        calls = self.run_mirror(False)
        commits = [c for c in calls if c[1] == 'git/commits']
        self.assertEqual(2, len(commits))
        trees = [c[2]['tree'] for c in calls if c[1] == 'git/trees']
        self.assertEqual([set(v) for v in mirror.FEEDS.values()],
                         [{e['path'] for e in tree} for tree in trees])

    def test_updates_preserve_parent_and_refuse_forced_publication(self):
        calls = self.run_mirror(True, changed=True)
        commits = [c[2] for c in calls if c[1] == 'git/commits']
        self.assertEqual([[b] for b in mirror.FEEDS], [c['parents'] for c in commits])
        updates = [c for c in calls if c[0] == 'PATCH']
        self.assertEqual(2, len(updates))
        self.assertTrue(all(c[2]['force'] is False for c in updates))

    def test_identical_feeds_create_no_objects_or_commits(self):
        self.assertTrue(all(c[0] == 'GET' for c in self.run_mirror(True)))

    def test_source_failure_changes_nothing(self):
        with patch.object(mirror, 'fetch', side_effect=OSError('unavailable')), patch.object(mirror, 'api') as api:
            with self.assertRaises(OSError):
                mirror.mirror('fixture/stub')
            api.assert_not_called()

    def test_anonymous_source_read(self):
        with patch.object(mirror.urllib.request, 'urlopen') as urlopen, \
             patch.dict(os.environ, {'GH_TOKEN': 'must-not-leave-destination'}):
            mirror.fetch('android-feed', 'android/releases.json')
            self.assertEqual(('https://raw.githubusercontent.com/Fledgewing/BookSync/android-feed/android/releases.json',),
                             urlopen.call_args.args)

    def test_source_cannot_be_destination(self):
        with self.assertRaises(ValueError):
            mirror.mirror(mirror.SOURCE)

    def test_verification_rejects_redirects_and_changed_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            def curl(args, **kwargs):
                self.assertEqual(['curl', '--disable'], args[:2])
                self.assertNotIn('-L', args)
                self.assertNotIn('--location', args)
                Path(args[args.index('--output') + 1]).write_bytes(b'signed bytes\r\n')
                return '200'
            with patch.object(ops.subprocess, 'check_output', side_effect=curl):
                ops.run('snapshot', 'fixture/old', 'fixture/new', target)
                ops.run('verify', 'fixture/old', 'fixture/new', target)
            with patch.object(ops.subprocess, 'check_output', return_value='301'):
                with self.assertRaisesRegex(RuntimeError, 'direct HTTP 200'):
                    ops.run('verify', 'fixture/old', 'fixture/new', target)
            with patch.object(ops, 'direct', side_effect=[b'one', b'two']):
                with self.assertRaisesRegex(RuntimeError, 'bytes differ'):
                    ops.run('verify', 'fixture/old', 'fixture/new', target)

    def test_ops_default_is_offline_and_apply_is_blocked_before_mutation(self):
        script = ROOT / 'tools/rename-to-booksync.sh'
        for args, code in (([], 0), (['--invalid'], 2)):
            result = subprocess.run(['bash', str(script), *args], capture_output=True, text=True,
                                    env={**os.environ, 'GH_TOKEN': ''})
            self.assertEqual(code, result.returncode, result.stderr)
        self.assertIn('BLOCKED', subprocess.check_output(['bash', str(script)], text=True))
        self.assertIn("if $apply; then\n  echo 'Refusing --apply:", script.read_text())


if __name__ == '__main__':
    unittest.main()

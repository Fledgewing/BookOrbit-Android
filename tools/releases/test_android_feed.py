#!/usr/bin/env python3
"""Publication tests with the GitHub and signing process boundaries replaced."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('feed', Path(__file__).with_name('android-feed.py'))
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)


class FeedTest(unittest.TestCase):
    def publish(self, existing, withdraw="v0.11.3-rc.12"):
        previous = {'withdrawn': ['v0.11.3-rc.8'], 'releases': []}
        calls = []
        published = []

        def gh(*args):
            calls.append(args)
            if '--slurp' in args and 'branches' in args[-1]:
                return json.dumps([[{'name': 'android-feed'}]] if existing else [[]])
            if '--slurp' in args:
                return json.dumps([[{'tag_name': 'v0.11.3-rc.9', 'draft': False,
                                     'assets': [{'name': 'companion.apk', 'browser_download_url': 'https://old.invalid/download'}]},
                                    {'tag_name': 'xteink-v2.0.0', 'draft': False}]])
            if args[0] == 'release':
                return '{}'
            if '-X' in args:
                request = json.loads(Path(args[-1]).read_text())
                if 'content' in request:
                    published.append(json.loads(base64.b64decode(request['content'])))
                if args[2] == 'PUT':
                    self.assertEqual('previous-sha', request.get('sha'))
                return '{"sha":"created-object"}'
            if 'contents/' in args[-1]:
                envelope = json.dumps({'payload': json.dumps(previous), 'signatures': 'previous signature'})
                return json.dumps({'sha': 'previous-sha', 'content': base64.b64encode(envelope.encode()).decode()})
            return '{}'

        with patch.object(feed, 'gh', side_effect=gh), patch.object(feed.subprocess, 'run') as verify, \
             patch.object(feed.subprocess, 'check_output', return_value='new signature'), \
             patch.dict(os.environ, {'GITHUB_REPOSITORY': 'fixture/repo', 'GITHUB_SHA': 'commit'}):
            feed.run(withdraw)
            self.assertEqual(2 if existing else 1, verify.call_count)
            self.assertTrue(all(c.kwargs['check'] for c in verify.call_args_list))
        payload = json.loads(published[0]['payload'])
        self.assertEqual(['v0.11.3-rc.9'], [r['tag_name'] for r in payload['releases']])
        self.assertEqual('https://github.com/fixture/repo/releases/download/v0.11.3-rc.9/companion.apk',
                         payload['releases'][0]['assets'][0]['browser_download_url'])
        expected = {'v0.11.3-rc.10', 'v0.11.3-rc.11', 'v0.11.3-rc.17'}
        if withdraw:
            expected.add(withdraw)
        self.assertTrue(expected <= set(payload['withdrawn']))
        self.assertEqual(existing, 'v0.11.3-rc.8' in payload['withdrawn'])

    def test_bootstrap(self):
        self.publish(False)

    def test_preserves_previous_withdrawals(self):
        self.publish(True)

    def test_refresh_includes_seed_without_dispatch_withdrawal(self):
        self.publish(True, withdraw="")

    def test_rejects_non_android_tag(self):
        with self.assertRaises(ValueError):
            feed.run('xteink-v2.0.0')

    def test_failed_signer_never_exposes_feed_branch(self):
        with patch.object(feed, 'gh', side_effect=[json.dumps([[]]), json.dumps([[{
                'tag_name': 'v0.11.3-rc.9', 'draft': False}]])]) as gh, \
             patch.object(feed.subprocess, 'check_output', side_effect=RuntimeError('signing failed')), \
             patch.dict(os.environ, {'GITHUB_REPOSITORY': 'fixture/repo'}):
            with self.assertRaises(RuntimeError):
                feed.run('')
            self.assertEqual(2, gh.call_count)

    def test_bad_previous_signature_stops_publication(self):
        with patch.object(feed, 'gh', side_effect=[json.dumps([[{'name': 'android-feed'}]]),
                json.dumps({'sha': 'old', 'content': base64.b64encode(json.dumps({
                    'payload': '{}', 'signatures': 'bad'}).encode()).decode()})]) as gh, \
             patch.object(feed.subprocess, 'run', side_effect=RuntimeError('invalid signature')), \
             patch.dict(os.environ, {'GITHUB_REPOSITORY': 'fixture/repo'}):
            with self.assertRaises(RuntimeError):
                feed.run('')
            self.assertEqual(2, gh.call_count)


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Offline bridge gate, mutation ordering, redirect verification and client wiring tests."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('rename_bridge', ROOT / 'tools/rename-bridge.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


def fixtures():
    def asset(name, tag):
        return dict(name=name, browser_download_url=f'https://github.com/{bridge.OLD}/releases/download/{tag}/{name}')
    app = dict(tag_name='v0.11.4', draft=False, prerelease=False, published_at='2026-12-01T00:00:00Z',
               assets=[asset('orbit-companion-0.11.4.apk', 'v0.11.4'), asset('orbit.koplugin.zip', 'v0.11.4')])
    fw = dict(tag_name='xteink-v2.0.0.500', draft=False, prerelease=False,
              published_at='2026-12-01T00:00:00Z', body='booksync_version=0.11.4\n',
              assets=[asset(stem + '-v2.0.0.500.bin', 'xteink-v2.0.0.500') for stem in bridge.STEMS])
    return [app, fw], copy.deepcopy(app), dict(releases=[copy.deepcopy(app)], withdrawn=[]), [dict(copy.deepcopy(fw), booksync_version='0.11.4')]


class Bridge(unittest.TestCase):
    def check(self, values):
        return bridge.gate('0.11.4', 'xteink-v2.0.0.500', *values)

    def test_stable_bridge_on_all_devices_and_channels(self):
        self.assertEqual(5, len(self.check(fixtures())))

    def test_rejects_incomplete_or_bypassed_rollouts(self):
        mutations = [
            lambda p, latest, a, f: p[0].update(prerelease=True),
            lambda p, latest, a, f: p[1].update(prerelease=True),
            lambda p, latest, a, f: p[1].update(draft=True),
            lambda p, latest, a, f: latest.update(tag_name='v0.11.3'),
            lambda p, latest, a, f: p[1].update(body='booksync_version=0.11.3'),
            lambda p, latest, a, f: p[1]['assets'].pop(),
            lambda p, latest, a, f: a['withdrawn'].append('v0.11.4'),
            lambda p, latest, a, f: a['releases'].clear(),
            lambda p, latest, a, f: a['releases'].append(dict(tag_name='v0.12.0-preview.1', assets=[])),
            lambda p, latest, a, f: p.append(dict(p[1], tag_name='xteink-v2.0.0.999', prerelease=True, published_at='2026-11-30T00:00:00Z')),
            lambda p, latest, a, f: f.append(dict(f[0], tag_name='xteink-v2.0.0.999', prerelease=True)),
            lambda p, latest, a, f: f.clear(),
            lambda p, latest, a, f: f[0].update(booksync_version='0.11.3'),
            lambda p, latest, a, f: f[0]['assets'].pop(),
            lambda p, latest, a, f: a['releases'][0]['assets'].pop(),
            lambda p, latest, a, f: f[0]['assets'][0].update(browser_download_url='https://fixture.invalid/wrong.bin'),
            lambda p, latest, a, f: p.append(dict(p[1], tag_name='xteink-v2.0.0.501', published_at='2026-12-02T00:00:00Z')),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                values = fixtures()
                mutate(*values)
                with self.assertRaises(ValueError):
                    self.check(values)
        for version in ('0.11.4-preview.1', '0.11.4-rc.1', 'v0.11.4'):
            with self.assertRaises(ValueError):
                bridge.gate(version, 'xteink-v2.0.0.500', *fixtures())

    def test_failed_gate_never_mutates_and_success_patches_once(self):
        p, latest, app, fw = fixtures()
        for valid in (False, True):
            with patch.object(bridge, 'releases', return_value=p), patch.object(bridge, 'signed_feeds', return_value=(app, fw)), \
                 patch.object(bridge, 'gh', side_effect=lambda path, method='GET', **fields:
                              (dict(full_name=bridge.OLD, id=123) if path == f'repos/{bridge.OLD}' else
                               p if '?per_page=' in path else latest)
                              if method == 'GET' else dict(full_name=bridge.NEW, id=123)) as gh, \
                 patch.object(bridge, 'curl', return_value=(404, b'')), \
                 patch.object(bridge, 'verify') as verify:
                if valid:
                    bridge.execute('0.11.4', p[1]['tag_name'])
                    self.assertEqual(1, verify.call_count)
                    self.assertEqual([unittest.mock.call(f'repos/{bridge.OLD}'),
                        unittest.mock.call(f'repos/{bridge.OLD}/releases/latest'),
                        unittest.mock.call(f'repos/{bridge.OLD}/releases?per_page=5'),
                        unittest.mock.call(f'repos/{bridge.OLD}/releases?per_page=25'),
                        unittest.mock.call(f'repos/{bridge.OLD}', method='PATCH', name='BookSync')], gh.call_args_list)
                else:
                    with self.assertRaises(ValueError):
                        bridge.execute('0.11.4-rc.1', p[1]['tag_name'])
                    self.assertTrue(all(c.kwargs.get('method', 'GET') == 'GET' for c in gh.call_args_list))
                    verify.assert_not_called()

    def test_signatures_must_pass_before_the_gate(self):
        envelope = json.dumps(dict(payload='{}', signatures='invalid')).encode()
        with patch.object(bridge, 'read_feed', return_value=envelope), \
             patch.object(bridge.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, ['verify'])):
            with self.assertRaises(subprocess.CalledProcessError):
                bridge.signed_feeds(bridge.OLD)

    def test_postrename_checks_accept_raw_alias_or_redirect_but_reject_errors(self):
        assets = self.check(fixtures())
        def request(url, follow=False):
            if f'/{bridge.OLD}/' in url and not follow:
                return (200, b'feed') if 'raw.githubusercontent.com' in url else (301, b'redirect')
            return 200, b'feed'
        with patch.object(bridge, 'curl', side_effect=request), patch.object(bridge, 'signed_feeds'):
            bridge.verify(assets)
        def redirect_raw(url, follow=False):
            return (307, b'redirect') if f'/{bridge.OLD}/' in url and not follow else (200, b'feed')
        with patch.object(bridge, 'curl', side_effect=redirect_raw), patch.object(bridge, 'signed_feeds'):
            bridge.verify(assets)
        for response in ((404, b'missing'), (200, b'not a redirect')):
            with patch.object(bridge, 'curl', return_value=response):
                with self.assertRaises(ValueError):
                    bridge.verify(assets)

    def test_curl_disables_config_and_only_follows_explicitly(self):
        def curl(args, **kwargs):
            self.assertEqual(['curl', '--disable'], args[:2])
            Path(args[args.index('--output') + 1]).write_bytes(b'exact\r\nbytes')
            return '200'
        with patch.object(bridge.subprocess, 'check_output', side_effect=curl) as run:
            self.assertEqual((200, b'exact\r\nbytes'), bridge.curl('https://fixture.invalid'))
            self.assertNotIn('--location', run.call_args.args[0])
            bridge.curl('https://fixture.invalid', follow=True)
            self.assertIn('--location', run.call_args.args[0])

    def test_dry_run_is_offline(self):
        with tempfile.TemporaryDirectory() as directory:
            for tool in ('gh', 'curl'):
                mock = Path(directory) / tool
                mock.write_text('#!/bin/sh\nexit 99\n')
                mock.chmod(0o755)
            output = subprocess.check_output(['bash', str(ROOT / 'tools/rename-to-booksync.sh')], text=True,
                env={**os.environ, 'PATH': directory + os.pathsep + os.environ['PATH']})
            self.assertIn('Dry-run:', output)

    def test_explicit_dry_run_checks_gate_without_renaming(self):
        with patch.object(sys, 'argv', ['rename-bridge.py', '--bridge-version', '0.11.4',
                                        '--firmware-tag', 'xteink-v2.0.0.500']), \
             patch.object(bridge, 'prepare') as prepare, patch.object(bridge, 'execute') as execute:
            bridge.main()
            prepare.assert_called_once_with('0.11.4', 'xteink-v2.0.0.500')
            execute.assert_not_called()

    def test_existing_client_wiring_prefers_canonical_and_preserves_trust(self):
        build = (ROOT / 'xteink/tailnet/tailnet_build.py').read_text()
        self.assertIn('"CROSSINK_OTA_RELEASE_LIST_URL": OTA_FEED', build)
        self.assertIn('"CROSSINK_OTA_FALLBACK_URL": (', build)
        patch_text = (ROOT / 'xteink/overlay/patches/v2.0/0055-booksync-ota-redirect.patch').read_text()
        self.assertIn('client_config.url = fallbackReleaseUrl;', patch_text)
        self.assertLess(patch_text.index('esp_err = checkOnce(client_config);'), patch_text.index('client_config.url = fallbackReleaseUrl;'))
        self.assertLess(patch_text.index('releaseParser.reset();'), patch_text.index('client_config.url = fallbackReleaseUrl;'))
        signed = (ROOT / 'xteink/overlay/patches/v2.0/0050-orbify-signed-ota.patch').read_text()
        self.assertIn('if (!signatureAccepted(', signed)
        updater = (ROOT / 'android/companion/app/src/main/java/net/fledgewing/orbitcompanion/Updater.kt').read_text()
        self.assertIn('AndroidReleaseFeed.load(', updater)
        self.assertFalse((ROOT / 'stub').exists())


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Exercise real Git input hashing, promotion evidence and partial firmware feeds."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import io
import base64
import zipfile
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]

def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

I = module('inputs', 'tools/releases/inputs.py')
F = module('feed', 'tools/xteink-feed.py')
XF = module('xteink_feed', 'tools/releases/xteink_feed.py')

class Fingerprints(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-q')
        for path in ('shared/version.json', 'shared/withdrawn-android.json', 'shared/settings.json', 'android/companion/app/code.kt',
                     'android/koreader/main.lua', 'xteink/tailnet/code.cpp', 'tools/upstreams.lock',
                     'tools/releases/inputs.py', '.github/workflows/release-tests.yml', 'README.md'):
            self.write(path, 'initial')
        self.write('tools/upstreams.lock', 'koreader reader v1 ' + '1'*40 + '\ncrossink-v2.0 firmware v2 ' + '2'*40 + '\n')
        self.git('add', '.')
        self.before = I.fingerprints(self.root)

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True)

    def write(self, path, value):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(value)

    def changed(self):
        after = I.fingerprints(self.root)
        return {p for p in I.PLATFORMS if after[p] != self.before[p]}

    def test_version_and_docs_only(self):
        self.write('shared/version.json', '{"version":"0.12.0-rc.1"}')
        self.write('README.md', 'docs')
        self.write('shared/withdrawn-android.json', '["v0.11.3-rc.17"]')
        self.assertEqual(self.changed(), set())

    def test_app_only(self):
        self.write('android/companion/app/code.kt', 'new code')
        self.assertEqual(self.changed(), {'app'})

    def test_plugin_only(self):
        self.write('android/koreader/main.lua', 'new code')
        self.assertEqual(self.changed(), {'plugin'})

    def test_overlay_and_upstream(self):
        self.write('xteink/tailnet/code.cpp', 'new')
        self.assertEqual(self.changed(), set(I.FIRMWARE))
        self.write('xteink/tailnet/code.cpp', 'initial')
        lock = (self.root / 'tools/upstreams.lock').read_text()
        self.write('tools/upstreams.lock', lock.replace('2'*40, '3'*40))
        self.assertEqual(self.changed(), set(I.FIRMWARE))
        self.write('tools/upstreams.lock', lock.replace('1'*40, '4'*40))
        self.assertEqual(self.changed(), {'plugin'})

    def test_shared_and_test_gate(self):
        for path in ('shared/settings.json', '.github/workflows/release-tests.yml', 'tools/releases/inputs.py'):
            self.write(path, 'new')
            self.assertEqual(self.changed(), set(I.PLATFORMS))
            self.write(path, 'initial')

    def test_added_removed_renamed_and_mode(self):
        self.write('android/koreader/extra.lua', 'new')
        self.git('add', 'android/koreader/extra.lua')
        self.assertEqual(self.changed(), {'plugin'})
        self.git('rm', '-f', 'android/koreader/extra.lua')
        self.assertEqual(self.changed(), set())
        self.git('mv', 'android/koreader/main.lua', 'android/koreader/other.lua')
        self.assertEqual(self.changed(), {'plugin'})
        self.git('mv', 'android/koreader/other.lua', 'android/koreader/main.lua')
        self.git('update-index', '--chmod=+x', 'android/koreader/main.lua')
        self.assertEqual(self.changed(), {'plugin'})

    def test_gitlink_pin(self):
        self.git('update-index', '--add', '--cacheinfo', '160000,' + '1' * 40 + ',xteink/tailnet/MicroLink')
        first = I.fingerprints(self.root)
        self.git('update-index', '--cacheinfo', '160000,' + '2' * 40 + ',xteink/tailnet/MicroLink')
        after = I.fingerprints(self.root)
        self.assertEqual({p for p in first if first[p] != after[p]}, set(I.FIRMWARE))

class Selection(unittest.TestCase):
    def setUp(self):
        self.fps = {p: p + '-hash' for p in I.PLATFORMS}
        self.history = dict(builds={p: dict(fingerprint=fp, version='0.12.0-preview.2', tag='old-'+p)
                                   for p, fp in self.fps.items()}, evidence=[])
        for p, fp in self.fps.items():
            for scope in ('component', 'release'):
                self.history['evidence'].append(dict(platform=p, fingerprint=fp, scope=scope,
                                                     result='passed', tag='passed-'+p))

    def plan(self, version='0.12.0-preview.3', force=False):
        return I.make_plan(version, self.fps, self.history, force)

    def selected(self, plan):
        return {p for p, row in plan['platforms'].items() if row['build']}

    def test_preview_unchanged(self):
        plan = self.plan()
        self.assertEqual(self.selected(plan), set())
        result = I.published(plan, I.PLATFORMS, 'new')
        self.assertEqual(result['builds'], self.history['builds'])
        self.assertEqual(result['evidence'], [])
        self.assertIn('preview.2 (unchanged)', I.notes(plan))

    def test_changed_firmware_and_android_cohort(self):
        self.fps['x4-pro'] = 'changed'
        plan = self.plan()
        self.assertEqual(self.selected(plan), {'x4-pro'})
        self.assertIsNone(plan['platforms']['x4-pro']['reuse']['release'])
        self.fps['plugin'] = 'changed'
        self.assertEqual(self.selected(self.plan()), {'app', 'plugin', 'x4-pro'})

    def test_rc_and_stable_always_stamp_all_and_reuse(self):
        for version in ('0.12.0-rc.1', '0.12.0'):
            plan = self.plan(version)
            self.assertEqual(self.selected(plan), set(I.PLATFORMS))
            self.assertTrue(all(r['reuse']['release'] for r in plan['platforms'].values()))
            self.assertIn('reused from passed-app', I.notes(plan))
            receipt = I.published(plan, I.PLATFORMS, 'new')
            self.assertTrue(all(b['version'] == version and b['tag'] == 'new' for b in receipt['builds'].values()))

    def test_no_failed_missing_or_component_only_release_bypass(self):
        self.history['evidence'] = [r for r in self.history['evidence'] if r['scope'] == 'component']
        plan = self.plan('0.12.0')
        self.assertTrue(plan['platforms']['app']['reuse']['component'])
        self.assertIsNone(plan['platforms']['app']['reuse']['release'])
        for r in self.history['evidence']:
            r['result'] = 'failed'
        self.assertIsNone(self.plan()['platforms']['app']['reuse']['component'])
        self.assertEqual(self.selected(I.make_plan('0.12.0-preview.1', self.fps, {})), set(I.PLATFORMS))
        self.assertTrue(all(not any(r['reuse'].values()) for r in self.plan(force=True)['platforms'].values()))

    def test_repeated_preview_carries_actual_tag_and_fingerprint(self):
        self.fps['x4-pro'] = 'new-source'
        plan = self.plan()
        receipt = I.published(plan, I.FIRMWARE, 'xteink-v0.12.0-preview.3')
        self.history['builds'].update(receipt['builds'])
        self.assertEqual(self.selected(self.plan('0.12.0-preview.4')), set())
        self.assertEqual(receipt['builds']['default']['tag'], 'old-default')

    def test_publication_order_and_table_refresh(self):
        plan = self.plan()
        I.require_android(plan)
        self.fps['app'] = 'changed'
        plan = self.plan()
        with self.assertRaises(ValueError):
            I.require_android(plan)
        self.fps['app'] = 'app-hash'
        plan = self.plan('0.12.0-rc.1')
        with self.assertRaises(ValueError):
            I.require_android(plan)
        for p in ('app', 'plugin'):
            self.history['builds'][p]['version'] = '0.12.0-rc.1'
        plan = self.plan('0.12.0-rc.1')
        I.require_android(plan)
        before = 'Install text\n' + I.notes(plan, ('app', 'plugin')) + 'Verify text\n'
        self.assertIn('preview.2 (pending)', before)
        after = I.refresh_notes(before, plan)
        self.assertNotIn('(pending)', after)
        self.assertTrue(after.startswith('Install text\n'))
        self.assertTrue(after.endswith('Verify text\n'))
        self.assertEqual(I.refresh_notes(after, plan), after)

class Collection(unittest.TestCase):
    def test_only_successful_trusted_runs_and_exact_merged_pr_heads_authorize_reuse(self):
        evidence = [dict(platform='app', fingerprint='hash', scope='release', result='passed', tag='v0.12.0-preview.1')]
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w') as archive:
            archive.writestr('passed-inputs.json', json.dumps(evidence))
        artifacts = [dict(id=i, expired=False, name='passed-inputs-test', workflow_run=dict(id=i)) for i in range(1, 10)]
        runs = {i: dict(conclusion='success', event='push', path='.github/workflows/android.yml',
                       head_repository=dict(full_name='org/repo')) for i in range(1, 10)}
        runs[2]['conclusion'] = 'failure'
        runs[3]['event'] = 'pull_request'
        runs[4]['head_repository']['full_name'] = 'fork/repo'
        runs[5]['path'] = '.github/workflows/unrelated.yml'
        artifacts[5]['expired'] = True
        for i in (7, 8, 9):
            runs[i].update(event='pull_request', head_sha='tested', pull_requests=[dict(number=i)])
        prs = {i: dict(merged=True, head=dict(sha='tested', repo=dict(full_name='org/repo'))) for i in (7, 8, 9)}
        prs[8]['merged'] = False
        prs[9]['head']['sha'] = 'later-untested-head'
        downloads = []
        def gh(*args, binary=False):
            endpoint = args[1]
            if '/branches?' in args[-1]:
                return '[[]]'
            if '/releases?' in endpoint:
                return '[]'
            if '/artifacts?' in endpoint:
                return json.dumps(dict(artifacts=artifacts))
            if '/pulls/' in endpoint:
                return json.dumps(prs[int(endpoint.rsplit('/', 1)[1])])
            if '/runs/' in endpoint:
                return json.dumps(runs[int(endpoint.rsplit('/', 1)[1])])
            downloads.append(endpoint)
            return buffer.getvalue()
        with patch.object(I, 'gh', gh):
            history = I.collect('org/repo')
        self.assertEqual(history['evidence'], evidence + evidence)
        self.assertEqual(downloads, ['repos/org/repo/actions/artifacts/1/zip', 'repos/org/repo/actions/artifacts/7/zip'])


    def test_signed_withdrawals_verify_the_original_asset_name_and_fail_closed(self):
        payload = json.dumps(dict(withdrawn=['v0.12.0-preview.2'], releases=[]))
        envelope = json.dumps(dict(payload=payload, signatures='signed-record'))
        def gh(*args, binary=False):
            if '/branches?' in args[-1]:
                return '[[{"name":"android-feed"}]]'
            return json.dumps(dict(content=base64.b64encode(envelope.encode()).decode()))
        def verify(args, **kwargs):
            self.assertIn('verify', args)
            self.assertEqual(args[-3], 'android-feed')
            self.assertEqual(Path(args[-1]).name, 'android-releases.json')
            self.assertEqual(Path(args[-1]).read_text(), payload)
            self.assertEqual(Path(args[-2]).read_text(), 'signed-record')
            self.assertTrue(kwargs['check'])
        with patch.object(I, 'gh', gh), patch.object(I.subprocess, 'run', verify):
            self.assertIn('v0.12.0-preview.2', I.withdrawn('org/repo'))
        with patch.object(I, 'gh', gh), patch.object(I.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'verify')):
            with self.assertRaises(subprocess.CalledProcessError):
                I.withdrawn('org/repo')

    def test_withdrawn_build_cannot_select_an_unchanged_preview(self):
        bad = dict(tag_name='v0.12.0-preview.2', created_at='2', draft=False,
                   assets=[dict(name='RELEASE-INPUTS.json', id=2)])
        good = dict(tag_name='v0.12.0-preview.1', created_at='1', draft=False,
                    assets=[dict(name='RELEASE-INPUTS.json', id=1)])
        def gh(*args, binary=False):
            if '/releases?' in args[1]:
                return json.dumps([bad, good])
            if '/assets/1' in args[1]:
                return json.dumps(dict(builds={'app': dict(fingerprint='old', version='0.12.0-preview.1', tag=good['tag_name'])}, evidence=[]))
            if '/artifacts?' in args[1]:
                return '{"artifacts":[]}'
            raise AssertionError('withdrawn release receipt must not be downloaded')
        with patch.object(I, 'gh', gh), patch.object(I, 'withdrawn', return_value={bad['tag_name']}):
            history = I.collect('org/repo')
        self.assertEqual(history['builds']['app']['tag'], good['tag_name'])


class Feed(unittest.TestCase):
    def release(self, version, devices, pre=True):
        return dict(tag_name='xteink-v'+version, name=version, draft=False, prerelease=pre,
                    created_at=version, assets=[dict(name=I.FIRMWARE[d]+'-v'+version+'.bin',
                    browser_download_url='https://example.invalid/'+d+'/'+version, size=10,
                    digest='sha256:abc') for d in devices])

    def test_stable_feed_changes_only_on_promotion(self):
        stable = self.release('1.6.1.114+bookorbit.9', I.FIRMWARE, False)
        stable['assets'][0]['orbify_signature'] = 'retained-signature'
        final = self.release('2.0.0.765+bookorbit.1', I.FIRMWARE, False)
        preview = self.release('2.0.0.766+bookorbit.1', I.FIRMWARE)
        previous = [stable]
        # Default publication and feed_only must ignore even a manually marked
        # stable GitHub release. Missing/deleted releases cannot erase stable.
        for releases in ([stable, final, preview], [final, preview], [preview], []):
            result = XF.refresh(releases, previous)
            self.assertEqual([r for r in result if not r['prerelease']], previous)
        result = XF.refresh([stable, final, preview], previous, promote_stable=True)
        self.assertEqual([r['tag_name'] for r in result if not r['prerelease']], [final['tag_name']])
        self.assertIn(preview['tag_name'], [r['tag_name'] for r in result])
        # Ordinary refreshes keep the explicitly promoted stable on later runs.
        self.assertEqual([r for r in XF.refresh([preview], result) if not r['prerelease']],
                         [r for r in result if not r['prerelease']])

    def test_partial_release_preserves_other_devices_and_bridges(self):
        old = self.release('0.12.0-preview.2', I.FIRMWARE)
        new = self.release('0.12.0-preview.3', ['x4-pro'])
        bridge = self.release('2.0.0.400+bookorbit.1-rc3', I.FIRMWARE)
        bridge['body'] = 'booksync_version=0.11.3-rc.17'
        stable = self.release('0.11.4', I.FIRMWARE, False)
        feed = F.build_feed([new, old, bridge, stable])
        self.assertEqual({r['tag_name'] for r in feed}, {r['tag_name'] for r in [new, old, bridge, stable]})
        for device in I.FIRMWARE:
            entries = [r for r in feed if r['prerelease'] and r.get('booksync_version','').startswith('0.12.')
                       and any(a['name'].startswith(I.FIRMWARE[device]+'-v') for a in r['assets'])]
            head = max(entries, key=F.product_key)
            self.assertEqual(head['tag_name'], (new if device == 'x4-pro' else old)['tag_name'])
            # Repeated checks compare the same installed product/tag; no synthetic update.
            self.assertEqual(head['assets'], (new if device == 'x4-pro' else old)['assets'])
        rc = self.release('0.12.0-rc.1', I.FIRMWARE)
        self.assertNotIn(old['tag_name'], {r['tag_name'] for r in F.build_feed([new, old, rc])})
        self.assertNotIn(new['tag_name'], {r['tag_name'] for r in F.build_feed([new, old, rc])})

if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Reject obsolete project copy; preserve durable identifiers and published history."""
from pathlib import Path
import ast
import os
from unittest.mock import patch
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
OLD_NAME = re.compile(r'\bOrbify\b')
# Exact historic text, never broad source-directory exclusions.
HISTORY_FILES = {'xteink/test/fixtures/release-body-rc3.txt'}
ALLOWED_LINES = {
    'tools/repo-urls.sh': {'BOOKSYNC_LEGACY_REPO="Fledgewing/Orbify"'},
    'xteink/tailnet/tailnet_build.py': {'LEGACY_OVERLAY_REPO = "Fledgewing/Orbify"'},
    'android/companion/app/src/main/java/net/fledgewing/orbitcompanion/Updater.kt': {
        'internal const val LEGACY_REPO = "Fledgewing/Orbify"',
    },
    'tools/test/test-product-names.py': {'if \'"Orbify"\' in line:'},
    'tools/e2e/e2e.env': {'E2E_PASSWORD=Orbify-e2e-1', 'E2E_KOSYNC_PASSWORD=Orbify-kosync-1'},
    'android/companion/app/src/main/java/net/fledgewing/orbitcompanion/Logic.kt': {
        '"Orbify: the app and the KOReader patch now update from github.com/Fledgewing/Orbify, one home for Android and Xteink readers. Nothing changes on the reader.",',
    },
    # Regression explicitly exercises a download URL already stored by a device.
    'xteink/test/ota_signature_test.cpp': {
        'replaceAll(oldRepo, "Fledgewing/BookSync", "Fledgewing/Orbify");',
    },
}


def obsolete_lines(path, text):
    if 'CHANGELOG' in Path(path).name.upper() or path in HISTORY_FILES:
        return
    for number, line in enumerate(text.splitlines(), 1):
        # Patch removal/context lines describe the existing upstream source. Only
        # added lines and the patch's prose are product text we ship.
        if path.endswith('.patch') and line.startswith((' ', '-', '@@', '+++', 'diff ', 'index ')):
            continue
        if line.strip() in ALLOWED_LINES.get(path, set()):
            continue
        if OLD_NAME.search(line):
            yield f'{path}:{number}: {line.strip()}'


class RepoName(unittest.TestCase):
    def test_tracked_copy(self):
        paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
        failures = []
        for name in paths:
            if not name or name == 'tools/test/test-repo-name.py':
                continue
            path = ROOT / name
            if not path.is_file():
                continue
            try:
                text = path.read_text()
            except UnicodeError:
                continue
            failures.extend(obsolete_lines(name, text))
        self.assertEqual([], failures, '\n'.join(failures))

    def test_firmware_feed_urls_and_custom_feed_isolation(self):
        source = ast.parse((ROOT / 'xteink/tailnet/tailnet_build.py').read_text())
        names = {'OVERLAY_REPO', 'LEGACY_OVERLAY_REPO', 'OTA_TAG_PREFIX', 'OTA_FEED', 'ota_defines'}
        nodes = [n for n in source.body if isinstance(n, ast.Assign)
                 and isinstance(n.targets[0], ast.Name) and n.targets[0].id in names]
        def definitions(environment):
            scope = {'os': os, 're': re, 'booksync_version': '0.11.0', 'crossink_base': '2.0.0'}
            with patch.dict(os.environ, environment, clear=True):
                exec(compile(ast.Module(body=nodes, type_ignores=[]), '<ota defaults>', 'exec'), scope)
            return scope['ota_defines']
        defaults = definitions({})
        self.assertEqual('https://api.github.com/repos/Fledgewing/BookSync/releases/latest',
                         defaults['CROSSINK_OTA_RELEASE_URL'])
        self.assertEqual('https://raw.githubusercontent.com/Fledgewing/BookSync/xteink-feed/xteink/releases.json',
                         defaults['CROSSINK_OTA_RELEASE_LIST_URL'])
        self.assertIn('/' + 'Or' + 'bify' + '/', defaults['CROSSINK_OTA_FALLBACK_URL'])
        self.assertEqual('xteink-v', defaults['CROSSINK_OTA_TAG_PREFIX'])
        custom = definitions({'TAILNET_OTA_FEED': 'http://fixture.test/feed'})
        self.assertEqual('http://fixture.test/feed', custom['CROSSINK_OTA_RELEASE_LIST_URL'])
        self.assertEqual('', custom['CROSSINK_OTA_FALLBACK_URL'])
        self.assertEqual('', definitions({'TAILNET_OVERLAY_REPO': 'test/repository'})['CROSSINK_OTA_FALLBACK_URL'])

    def test_allowlist_does_not_hide_new_copy(self):
        for path in ('README.md', 'docs/new.md', '.github/workflows/release.yml',
                     'android/companion/app/src/main/java/net/fledgewing/orbitcompanion/Logic.kt'):
            self.assertTrue(list(obsolete_lines(path, 'Welcome to Orbify')))
        self.assertTrue(list(obsolete_lines('xteink/overlay/patches/v2.0/new.patch', '+"Orbify settings"')))
        for text in ('namespace OrbifySettings {', 'xteink/orbify/CrashRecord.cpp',
                     'net.fledgewing.orbitcompanion', 'orbit.koplugin', '"orbify_signature"'):
            self.assertFalse(list(obsolete_lines('source.cpp', text)))


if __name__ == '__main__':
    unittest.main()

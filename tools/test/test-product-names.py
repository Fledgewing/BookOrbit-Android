#!/usr/bin/env python3
"""Guard product copy on both platforms without renaming durable identifiers.

OrbiSmart is deliberately unchanged. Orbit identifiers (packages, settings, paths,
logs and upstream BookOrbit names) are not product copy.
"""
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
OLD = re.compile(r'\bOrbit\b|Android sync')
LITERAL = re.compile(r'"(?:\\.|[^"\\])*"|\[\[.*?\]\]', re.S)


def obsolete(text):
    # The picture is an existing file, including when a setup instruction shows it.
    text = text.replace('Pictures/Orbit/sleep.png', '')
    return OLD.search(text)


def strings(path):
    """Read non-comment source literals; log calls and internal paths are exempt."""
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if line.lstrip().startswith(('--', '//', '/*', '*', '#include')):
            continue
        if re.search(r'\b(?:log|logger\.\w+|OLog\.\w+|LOG_\w+|TLOG\w*)\s*\(', line):
            continue
        for match in LITERAL.finditer(line):
            yield number, match.group()


class ProductNames(unittest.TestCase):
    def test_android_resources(self):
        for path in (ROOT / 'android/companion/app/src/main/res').rglob('strings.xml'):
            for element in ET.parse(path).getroot():
                self.assertIsNone(obsolete(''.join(element.itertext())), str(path))

    def test_plugin_and_companion_copy(self):
        paths = list((ROOT / 'android/koreader/orbit.koplugin').rglob('*.lua'))
        paths += list((ROOT / 'android/companion/app/src/main/java').rglob('*.kt'))
        for path in paths:
            for number, text in strings(path):
                # Battery skip/snooze IDs are persisted across the rename.
                if path.name == 'ChecklistLogic.kt' and text == '"Orbit"' and 'val id get()' in path.read_text().splitlines()[number - 1]:
                    continue
                self.assertIsNone(obsolete(text), f'{path.relative_to(ROOT)}:{number}: {text}')

    def test_multiline_plugin_translations(self):
        translation = re.compile(r'_\(\s*("(?:\\.|[^"\\])*"|\[\[.*?\]\])', re.S)
        for path in (ROOT / 'android/koreader/orbit.koplugin').rglob('*.lua'):
            for match in translation.finditer(path.read_text()):
                self.assertIsNone(obsolete(match.group(1)), str(path.relative_to(ROOT)))

    def test_xteink_copy(self):
        paths = [p for folder in ('xteink/orbify', 'xteink/tailnet/ui')
                 for p in (ROOT / folder).rglob('*') if p.suffix in ('.cpp', '.h')]
        for path in paths:
            for number, text in strings(path):
                self.assertIsNone(obsolete(text), f'{path.relative_to(ROOT)}:{number}: {text}')
                self.assertIsNone(re.search(r'\bOrbify\b', text), f'{path.relative_to(ROOT)}:{number}: {text}')
        for path in (ROOT / 'xteink/overlay/patches').rglob('*.patch'):
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if not line.startswith('+') or line.startswith('+++'):
                    continue
                line = line[1:].strip()
                if line.startswith(('//', '#include')) or 'LOG_' in line:
                    continue
                for match in LITERAL.finditer(line):
                    self.assertIsNone(obsolete(match.group()), f'{path.relative_to(ROOT)}:{number}')
                # Firmware labels also reject the repo name as a product label.
                if '"Orbify"' in line:
                    self.fail(f'{path.relative_to(ROOT)}:{number}: old firmware label')

    def test_guard_examples(self):
        for text in ('Orbit', 'Orbit Companion', "Orbit's settings", 'Android sync'):
            self.assertIsNotNone(obsolete(text))
        for text in ('BookSync', 'BookSync Companion', 'BookOrbit', 'OrbiSmart',
                     'orbit.koplugin', 'net.fledgewing.orbitcompanion', 'Pictures/Orbit/sleep.png'):
            self.assertIsNone(obsolete(text))


if __name__ == '__main__':
    unittest.main()

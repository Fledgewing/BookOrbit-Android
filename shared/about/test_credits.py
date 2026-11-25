"""Shared credit, firmware row provider and distribution regressions. No device required."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from generate import generate, rows

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'shared/about/credits.json'


class CreditsTest(unittest.TestCase):
    def test_readme_and_all_surfaces_use_the_shared_notice(self):
        credits = json.loads(SOURCE.read_text())
        readme = (ROOT / 'README.md').read_text().split('## Credits\n', 1)[1]
        for text in [*credits['paragraphs'], credits['url']]:
            self.assertIn(text, readme)
        for path, needle in [
            ('android/companion/app/src/main/java/net/fledgewing/orbitcompanion/AboutActivity.kt', 'credits.getJSONArray("paragraphs")'),
            ('android/koreader/orbit.koplugin/ko/menu.lua', 'ipairs(credits.paragraphs)'),
            ('xteink/overlay/patches/v2.0/0052-orbify-about-credit.patch', 'OrbifyCredits::provideRow(index, item)'),
        ]:
            text = (ROOT / path).read_text()
            self.assertIn(needle, text)
            self.assertNotIn('powered by', text.lower())
        self.assertNotIn('powered by', SOURCE.read_text().lower())
        self.assertNotIn('powered by', readme.lower())
        switches = (ROOT / 'xteink/tailnet/tailnet_build.py').read_text()
        self.assertRegex(switches, r'"CROSSINK_TAILNET_ABOUT_CREDIT":\s*\(0,\s*1,\s*1\)')

    def test_firmware_provider_preserves_all_text_and_resumes_system_rows(self):
        credits = json.loads(SOURCE.read_text())
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            generate(SOURCE, tmp / 'OrbifyCredits.h')
            (tmp / 'test.cpp').write_text('''
#include "OrbifyCredits.h"
#include <cstdio>
struct Item { const char* label; const char* subtitle; };
int main() {
#if CROSSINK_TAILNET_ABOUT_CREDIT
  for (unsigned row = 0; row < OrbifyCredits::count; ++row) {
    auto index = row;
    Item item{};
    if (!OrbifyCredits::provideRow(index, item)) return 1;
    puts(item.label);
    if (*item.subtitle) puts(item.subtitle);
  }
  unsigned index = OrbifyCredits::count + 3;
  Item item{};
  if (OrbifyCredits::provideRow(index, item) || index != 3) return 2;
#else
  static_assert(OrbifyCredits::count == 0);
#endif
}
''')
            for enabled in (0, 1):
                binary = tmp / f'test{enabled}'
                subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
                                f'-DCROSSINK_TAILNET_ABOUT_CREDIT={enabled}',
                                str(tmp / 'test.cpp'), '-o', str(binary)], check=True)
                output = subprocess.check_output([str(binary)], text=True)
                self.assertEqual(rows(credits) if enabled else [], output.splitlines())
                self.assertNotIn('powered by', output.lower())
                if not enabled:
                    self.assertNotIn(b'BookOrbit', binary.read_bytes())

    def test_plugin_zip_contains_the_exact_shared_notice(self):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / 'orbit.zip'
            subprocess.run([str(ROOT / 'android/koreader/package.sh'), '0.0.0-ci', str(archive)], check=True,
                           stdout=subprocess.DEVNULL)
            import zipfile
            with zipfile.ZipFile(archive) as zipped:
                self.assertEqual(SOURCE.read_bytes(), zipped.read('orbit.koplugin/about_credits.json'))


if __name__ == '__main__':
    unittest.main()

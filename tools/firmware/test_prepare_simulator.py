#!/usr/bin/env python3
"""Exercise seed compatibility and the owned immutable simulator configuration."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parent
CONFIG = json.loads((TOOLS / 'simulator.json').read_text())

class SimulatorPreparationTest(unittest.TestCase):
    def prepare(self, ini, config=CONFIG):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'platformio.ini').write_text(ini)
            (root / 'tools/ci').mkdir(parents=True)
            (root / 'tools/ci/simulator.json').write_text(json.dumps(config))
            result = subprocess.run([sys.executable, str(TOOLS / 'prepare_simulator.py'), str(root)],
                                    capture_output=True, text=True)
            return result, (root / 'platformio.ini').read_text()

    def test_legacy_seed(self):
        result, text = self.prepare('  -Wno-c++11-narrowing\n  pre:scripts/simulator_tls.py\n'
                                    f'  simulator={CONFIG["repository"]}\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('#' + CONFIG['commit'], text)
        self.assertIn('pre:../../tools/firmware/simulator_build.py', text)

    def test_owned_configuration_is_unchanged(self):
        ini = ('  pre:tools/ci/simulator_build.py\n'
               f'  simulator={CONFIG["repository"]}#{CONFIG["commit"]}\n')
        result, text = self.prepare(ini)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(text, ini)
        result, _ = self.prepare(ini, {**CONFIG, 'commit': 'f' * 40})
        self.assertNotEqual(result.returncode, 0)

    def test_unknown_configuration_fails_closed(self):
        result, text = self.prepare('unreviewed configuration\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(text, 'unreviewed configuration\n')

if __name__ == '__main__':
    unittest.main()

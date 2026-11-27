#!/usr/bin/env python3
"""Factory config and actual binary budget regressions (no PlatformIO/device)."""
import configparser
import csv
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('budget', ROOT / 'xteink/scripts/check-flash-budget.py')
budget = importlib.util.module_from_spec(spec)
spec.loader.exec_module(budget)


class FlashBudgetTest(unittest.TestCase):
    def test_factory_configs_and_binary_budget(self):
        config = configparser.ConfigParser(interpolation=None)
        config.read(ROOT / 'xteink/overlay/platformio.local.ini')
        for env, expected in [('x4-pro', 0x7e0000), ('x4-classic', 0x7e0000), ('default', 0x640000)]:
            with self.subTest(env=env), tempfile.TemporaryDirectory() as tmp:
                section = config[f'env:{env}']
                self.assertEqual(int(section['board_upload.maximum_size']), expected)
                csv_path = ROOT / 'xteink' / section['board_build.partitions']
                rows = [list(map(str.strip, row)) for row in csv.reader(csv_path.read_text().splitlines())
                        if row and not row[0].startswith('#')]
                apps = [row for row in rows if row[1] == 'app']
                self.assertEqual([int(row[4], 0) for row in apps], [expected, expected])
                self.assertEqual(int(apps[0][3], 0), 0x10000)
                self.assertEqual(int(apps[1][3], 0), 0x10000 + expected)
                binary = b''.join(struct.pack('<HBBII16sI', 0x50aa, 0, 0x10+i,
                                  int(row[3], 0), int(row[4], 0), row[0].encode(), 0)
                                  for i, row in enumerate(apps))
                table, image = Path(tmp)/'partitions.bin', Path(tmp)/'firmware.bin'
                table.write_bytes(binary)
                gate = expected * 995 // 1000
                for size, fits in [(6474672, True), (gate, True), (gate+1, False), (expected+1, False)]:
                    with image.open('wb') as stream:
                        stream.truncate(size)
                    self.assertEqual(budget.check(image, table), fits)
                table.write_bytes(b'bad table')
                with self.assertRaises(ValueError):
                    budget.check(image, table)


if __name__ == '__main__':
    unittest.main()

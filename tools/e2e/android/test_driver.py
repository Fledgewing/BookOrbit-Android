#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Safety checks for the emulator driver; no Android SDK or connected device required."""
import subprocess
import unittest
import tempfile
from pathlib import Path
from unittest.mock import patch
from run import Emulator
from build import build, ROOT

class EmulatorSafetyTest(unittest.TestCase):
    def test_fixture_builder_never_overwrites_the_repo_or_an_unrelated_directory(self):
        with patch("shutil.copytree") as copy:
            with self.assertRaises(ValueError): build(ROOT/"fixture")
            with tempfile.TemporaryDirectory() as directory:
                out=Path(directory);sentinel=out/"unrelated.txt";sentinel.write_text("keep")
                with self.assertRaises(ValueError): build(out)
                self.assertEqual("keep",sentinel.read_text())
                self.assertFalse((out/".booksync-e2e-build").exists())
            copy.assert_not_called()
    def test_physical_serial_is_rejected_before_adb(self):
        for serial in ("usb-fixture", "", "emulator-5580;anything", "127.0.0.1:5555"):
            with self.subTest(serial=serial), patch("subprocess.check_output") as adb:
                with self.assertRaises(ValueError): Emulator(serial)
                adb.assert_not_called()

    def test_emulator_name_alone_does_not_authorize_mutations(self):
        with patch("subprocess.check_output",return_value=b"0\n") as adb:
            with self.assertRaises(ValueError): Emulator("emulator-5580")
            adb.assert_called_once_with(["adb","-s","emulator-5580","shell","getprop","ro.kernel.qemu"],stderr=subprocess.PIPE)

    def test_every_call_keeps_the_explicit_emulator_serial(self):
        with patch("subprocess.check_output",return_value=b"1\n") as adb:
            emulator=Emulator("emulator-5580")
            emulator.shell("getprop","sys.boot_completed")
            emulator.adb("exec-out","screencap","-p")
            for call in adb.call_args_list:
                self.assertEqual(["adb","-s","emulator-5580"],call.args[0][:3])

if __name__=="__main__": unittest.main()

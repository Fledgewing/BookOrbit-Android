#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Safety checks for the emulator driver; no Android SDK or connected device required."""
import subprocess
import unittest
import tempfile
from pathlib import Path
from unittest.mock import patch, Mock
import sys
sys.dont_write_bytecode = True
from run import Emulator
from build import build, ROOT
from upgrade import reset_profile

class EmulatorSafetyTest(unittest.TestCase):
    def test_startup_wait_polls_readiness_without_repeating_a_ui_action(self):
        device=object.__new__(Emulator)
        device.command=Mock(side_effect=["pending","pending","ready"])
        with patch("time.sleep"): device.wait_companion()
        self.assertEqual(3,device.command.call_count)
        for call in device.command.call_args_list:
            self.assertIn("Companion.workerProblem()",call.args[0])
            self.assertNotIn("HomeHost.show",call.args[0])

    def test_startup_wait_fails_when_the_matching_status_never_arrives(self):
        device=object.__new__(Emulator);device.command=Mock(return_value="pending")
        with patch("time.monotonic",side_effect=[0,21]):
            with self.assertRaises(TimeoutError): device.wait_companion()

    def test_upgrade_reset_accepts_a_fresh_emulator_and_clears_only_installed_test_apps(self):
        for installed in ("", "package:net.fledgewing.orbitcompanion\npackage:android"):
            device=Mock()
            device.shell.side_effect=lambda *args: installed if args==("pm","list","packages") else ""
            reset_profile(device)
            clears=[call.args for call in device.shell.call_args_list if call.args[:2]==("pm","clear")]
            self.assertEqual([("pm","clear","net.fledgewing.orbitcompanion")] if installed else [],clears)
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
            adb.assert_called_once_with(["adb","-s","emulator-5580","shell","getprop","ro.kernel.qemu"],stderr=subprocess.PIPE,timeout=60)

    def test_unresponsive_emulator_fails_without_retrying_or_changing_target(self):
        with patch("subprocess.check_output",side_effect=[b"1\n",subprocess.TimeoutExpired("adb",60)]) as adb:
            emulator=Emulator("emulator-5580")
            with self.assertRaises(subprocess.TimeoutExpired): emulator.shell("getprop","sys.boot_completed")
            self.assertEqual(2,adb.call_count)
            self.assertEqual(60,adb.call_args.kwargs["timeout"])
            self.assertEqual(["adb","-s","emulator-5580"],adb.call_args.args[0][:3])

    def test_every_call_keeps_the_explicit_emulator_serial(self):
        with patch("subprocess.check_output",return_value=b"1\n") as adb:
            emulator=Emulator("emulator-5580")
            emulator.shell("getprop","sys.boot_completed")
            emulator.adb("exec-out","screencap","-p")
            for call in adb.call_args_list:
                self.assertEqual(["adb","-s","emulator-5580"],call.args[0][:3])

if __name__=="__main__": unittest.main()

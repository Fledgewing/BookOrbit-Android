#!/usr/bin/env python3
"""Exercise shared identity, package stamping, channel ordering and retained OTA bridges."""
import importlib.util
import json
import os
from unittest.mock import patch
import sys
sys.dont_write_bytecode = True
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]

def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

V = module("version", "tools/booksync-version.py")
F = module("feed", "tools/xteink-feed.py")

class Versions(unittest.TestCase):
    def test_products(self):
        version = V.version()
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "plugin.zip"
            subprocess.run(["bash", str(ROOT / "android/koreader/package.sh"), "shared", str(archive)], check=True,
                           stdout=subprocess.DEVNULL)
            with zipfile.ZipFile(archive) as z:
                self.assertIn(f'local PATCH_VERSION = "{version}"',
                              z.read("orbit.koplugin/main.lua").decode())
        gradle = (ROOT / "android/companion/app/build.gradle.kts").read_text()
        self.assertIn('shared/version.json', gradle)
        self.assertIn('?: sharedVersion', gradle)
        build = (ROOT / "xteink/tailnet/tailnet_build.py").read_text()
        self.assertIn('version_api["build_identity"](version_api["version"]()', build)
        self.assertIn('"BOOKSYNC_VERSION": booksync_version', build)

    def test_release_identity(self):
        for value in ("0.12.0-preview.1", "0.12.0-rc.1", "0.12.0", "1.0.0"):
            self.assertTrue(V.unified(value))
            self.assertEqual(V.firmware(value, "v2.0.0+bookorbit.1-rc3", 500),
                             value + "+crossink.2.0.0.bookorbit.1-rc3")
        self.assertEqual(V.firmware("0.11.4-preview.1", "v2.0.0+bookorbit.1-rc3", 300),
                         "2.0.0.400+bookorbit.1-rc3")
        self.assertEqual(V.firmware("0.12.0", "v2.0.0+bookorbit.1-rc3", 300, True),
                         "0.12.0-0.test.300+crossink.2.0.0.bookorbit.1-rc3")
        self.assertFalse(V.unified("0.11.4-preview.1"))
        if not V.unified(V.version()):
            with self.assertRaises(ValueError):
                V.check_release("0.12.0")

    def test_bridge_feed(self):
        def release(tag, pre, date, book=None):
            return dict(tag_name="xteink-v" + tag, name=tag, draft=False, prerelease=pre,
                        created_at=date, body=f"booksync_version={book}\n" if book else "",
                        assets=[dict(name="firmware-x4-pro-v-test.bin", size=10, digest="sha256:abc",
                                     browser_download_url="https://example.invalid/fw.bin")])
        old = release("2.0.0.373+bookorbit.1-rc3", True, "1")
        bridge = release("2.0.0.400+bookorbit.1-rc3", True, "2", "0.11.3-rc.17")
        preview = release("0.12.0-preview.1+crossink.2.0.0.bookorbit.1-rc3", True, "3")
        rc = release("0.12.0-rc.1+crossink.2.0.0.bookorbit.1-rc3", True, "4")
        stable = release("0.12.0+crossink.2.0.0.bookorbit.1-rc3", False, "5")
        classic = release("1.6.1.114", False, "0")
        for latest in (preview, rc, stable):
            feed = F.build_feed([old, bridge, classic, latest])
            self.assertIn(bridge["tag_name"], [r["tag_name"] for r in feed])
            self.assertIn(classic["tag_name"], [r["tag_name"] for r in feed])
            self.assertIn(latest["tag_name"], [r["tag_name"] for r in feed])
            self.assertNotIn(old["tag_name"], [r["tag_name"] for r in feed])
            self.assertEqual(next(r["booksync_version"] for r in feed if r["tag_name"] == bridge["tag_name"]),
                             "0.11.3-rc.17")
        with patch.dict(os.environ, {'GITHUB_REPOSITORY': 'fixture/canonical'}):
            canonical = json.loads(subprocess.check_output(
                ['python3', str(ROOT / 'tools/xteink-feed.py')],
                input=json.dumps([classic]), text=True))[0]
        self.assertEqual('https://github.com/fixture/canonical/releases/download/xteink-v1.6.1.114/firmware-x4-pro-v-test.bin',
                         canonical['assets'][0]['browser_download_url'])
        self.assertIsNone(F.identity(classic))
        # Rebuilding an old bridge later must retain the current unified release.
        bridge["created_at"] = "9"
        feed = F.build_feed([old, bridge, rc, stable, classic])
        self.assertIn(stable["tag_name"], [r["tag_name"] for r in feed])
        # Stable supersedes its older RC in both the RC and Preview channels.
        self.assertNotIn(rc["tag_name"], [r["tag_name"] for r in feed])
        earlier = release("0.12.0-preview.1", True, "8")
        self.assertIn(rc["tag_name"], [r["tag_name"] for r in F.build_feed([earlier, rc])])

    def test_three_channel_feed_ignores_github_and_upstream_labels(self):
        devices = ("firmware-x4-pro", "firmware-x4-classic", "firmware-x3-x4")
        def release(book, flag, builds=devices):
            return dict(tag_name=f"xteink-v{book}+crossink.2.0.0.bookorbit.1-rc3",
                        name=book, draft=False, prerelease=flag, created_at=book,
                        assets=[dict(name=stem + "-v-test.bin") for stem in builds])
        stable = release("0.12.0", True)
        rc = release("0.13.0-rc.2", False, devices[:1])
        previous_rc = release("0.13.0-rc.1", True)
        preview = release("0.14.0-preview.1", False, devices[:1])
        feed = F.build_feed([stable, rc, preview, previous_rc])
        self.assertEqual({"0.12.0", "0.13.0-rc.1", "0.13.0-rc.2", "0.14.0-preview.1"},
                         {r["booksync_version"] for r in feed})
        self.assertTrue(all("-rc3" in r["tag_name"] for r in feed))
        for i, device in enumerate(devices):
            for minimum, expected in ((2, "0.12.0"), (1, "0.13.0-rc.2" if i == 0 else "0.13.0-rc.1"),
                                      (0, "0.14.0-preview.1" if i == 0 else "0.13.0-rc.1")):
                allowed = [r for r in feed if F.product_key(r)[3] >= minimum and
                           any(a["name"].startswith(device + "-v") for a in r["assets"])]
                self.assertEqual(expected, F.identity(max(allowed, key=F.product_key)))

if __name__ == "__main__":
    unittest.main()

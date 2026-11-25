#!/usr/bin/env python3
"""Contract checks: every shared setting is audited, with evidence and reasons."""
import importlib.util
import json
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("features", ROOT / "tools/features.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


class FeatureMatrixTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = json.loads((ROOT / "shared/features.json").read_text())

    def test_every_setting_once(self):
        schema = json.loads((ROOT / "shared/settings/schema.json").read_text())
        expected = {s["key"] for s in schema["settings"]}
        actual = [key for row in self.data["features"] for key in row.get("settings_keys", [])]
        self.assertEqual(len(actual), len(set(actual)), "duplicate settings coverage")
        self.assertEqual(expected, set(actual), "new or removed schema keys need an explicit audit")

    def test_cells_have_evidence_and_explanations(self):
        ids = [f["id"] for f in self.data["features"]]
        self.assertEqual(len(ids), len(set(ids)))
        for f in self.data["features"]:
            self.assertEqual(set(f["platforms"]), set(self.data["platforms"]))
            for platform, c in f["platforms"].items():
                with self.subTest(feature=f["id"], platform=platform):
                    self.assertIn(c["status"], renderer.SYMBOLS)
                    self.assertTrue(c["note"])
                    self.assertTrue(c["evidence"])
                    if c["status"] == "supported":
                        self.assertTrue(c["version"])
                    else:
                        self.assertTrue(c["reason"])
                        self.assertTrue(c["reason"].startswith(("hardware:", "deliberately deferred:", "gap — no reason", "not applicable:")))
        for e in [e for f in self.data["features"] for c in f["platforms"].values() for e in c["evidence"]] + self.data["constraints"]["evidence"] + [e for c in self.data["constraints"]["costs"] for e in c["evidence"]]:
            with self.subTest(evidence=e):
                path = ROOT / e["path"]
                self.assertFalse(Path(e["path"]).is_absolute())
                self.assertNotIn("..", Path(e["path"]).parts)
                self.assertTrue(path.is_file())
                self.assertGreater(e["line"], 0)
                self.assertLessEqual(e["line"], len(path.read_text().splitlines()))

    def test_constraints_and_priorities(self):
        c = self.data["constraints"]
        for d in c["devices"].values():
            self.assertEqual(d["under_gate_bytes"], c["flash_slot_bytes"] * 995 // 1000 - d["flash_used_bytes"])
            self.assertLess(d["static_ram_used_bytes"], d["static_ram_total_bytes"])
        ids = {f["id"] for f in self.data["features"]}
        for g in self.data["gaps"]:
            self.assertLessEqual(set(g["features"]), ids)
            self.assertLessEqual(set(g["platforms"]), set(self.data["platforms"]))
            self.assertTrue(g["x3_fit"])

    def test_markdown_is_same_data(self):
        self.assertEqual((ROOT / "docs/FEATURES.md").read_text(), renderer.render(self.data))


if __name__ == "__main__":
    unittest.main()

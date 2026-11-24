#!/usr/bin/env python3
"""Tests for the e2e server kit: the fault proxy against a stub server, the library generator,
the pins, and with ORBIFY_E2E_LIVE=1 the seeded BookOrbit server itself (kit.py up first).

    python3 tools/e2e/test_kit.py                      # seconds, no docker
    ORBIFY_E2E_LIVE=1 python3 tools/e2e/test_kit.py    # + the live server through the proxy
"""

from __future__ import annotations

import json
import os
import re
import socket
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bofault  # noqa: E402
import kit  # noqa: E402

FAULTS = kit.ROOT / "shared" / "fixtures" / "e2e" / "faults"


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Stub(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        body = json.dumps({"path": self.path}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_POST = do_PUT = do_GET


def get(url: str, timeout: float = 5, method: str = "GET", data: bytes | None = None) -> tuple[int, bytes]:
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data, method=method), timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


class ProxyTest(unittest.TestCase):
    def setUp(self):
        self.upstream = ThreadingHTTPServer(("127.0.0.1", free_port()), Stub)
        threading.Thread(target=self.upstream.serve_forever, daemon=True).start()
        self.log = Path(tempfile.mkdtemp()) / "not-yet" / "bofault.jsonl"  # the proxy makes the folder
        self.proxy = bofault.serve(free_port(), f"http://127.0.0.1:{self.upstream.server_port}", log=self.log)
        self.base = f"http://127.0.0.1:{self.proxy.server_port}"

    def tearDown(self):
        self.proxy.shutdown()
        self.upstream.shutdown()

    def rules(self, rules):
        self.assertEqual(get(f"{self.base}/__bofault/rules", method="POST", data=json.dumps(rules).encode())[0], 200)

    def entries(self):
        return [json.loads(line) for line in get(f"{self.base}/__bofault/log")[1].decode().splitlines()]

    def test_forwards_and_logs(self):
        status, body = get(f"{self.base}/api/v1/x?limit=50")
        self.assertEqual((status, json.loads(body)["path"]), (200, "/api/v1/x?limit=50"))
        entry = self.entries()[-1]
        self.assertEqual((entry["action"], entry["query"], entry["status"]), ("forward", {"limit": "50"}, 200))
        self.assertEqual(json.loads(self.log.read_text().splitlines()[-1])["path"], "/api/v1/x")

    def test_status_after_and_times(self):
        self.rules([{"match": {"path": "^/a$"}, "action": "status", "status": 400, "after": 1, "times": 1}])
        self.assertEqual([get(f"{self.base}/a")[0] for _ in range(3)], [200, 400, 200])

    def test_query_match(self):
        self.rules([{"match": {"query": {"limit": "^100$"}}, "action": "status", "status": 500}])
        self.assertEqual(get(f"{self.base}/p?limit=100")[0], 500)
        self.assertEqual(get(f"{self.base}/p?limit=50")[0], 200)
        self.assertEqual(get(f"{self.base}/p")[0], 200)

    def test_delay(self):
        self.rules([{"match": {"method": "GET"}, "action": "delay", "ms": 300}])
        started = time.monotonic()
        self.assertEqual(get(f"{self.base}/slow")[0], 200)
        self.assertGreaterEqual(time.monotonic() - started, 0.3)

    def test_timeout_never_answers(self):
        self.rules([{"match": {}, "action": "timeout", "ms": 1500}])
        with self.assertRaises((TimeoutError, socket.timeout, urllib.error.URLError)):
            get(f"{self.base}/held", timeout=0.5)

    def test_drop_closes_without_reply(self):
        self.rules([{"match": {}, "action": "drop"}])
        with self.assertRaises((ConnectionError, urllib.error.URLError, http_client_errors())):
            get(f"{self.base}/gone")

    def test_reset_clears_rules_and_log(self):
        self.rules([{"match": {}, "action": "status", "status": 503}])
        self.assertEqual(get(f"{self.base}/x")[0], 503)
        get(f"{self.base}/__bofault/reset", method="POST", data=b"")
        self.assertEqual(get(f"{self.base}/x")[0], 200)
        self.assertEqual(len(self.entries()), 1)

    def test_fault_fixtures_load(self):
        for path in sorted(FAULTS.glob("*.json")):
            with self.subTest(path.name):
                rules = json.loads(path.read_text())["rules"]
                self.assertTrue(rules)
                for i, spec in enumerate(rules):
                    bofault.Rule(spec, i)


def http_client_errors():
    import http.client
    return http.client.HTTPException


class LibraryTest(unittest.TestCase):
    def test_generated_library_is_stable_and_unique(self):
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            first, second = kit.generate(Path(a)), kit.generate(Path(b))
            self.assertEqual([x["hash"] for x in first], [x["hash"] for x in second])
            self.assertEqual(len({x["hash"] for x in first}), len(first))
            spec = json.loads(kit.SPEC.read_text())
            titles = {x["title"] for x in first}
            for role, title in spec["roles"].items():
                if not role.startswith("_"):
                    self.assertIn(title, titles, role)
            self.assertTrue(all(t in titles for t in spec["want_to_read"]))
            self.assertEqual(sum(1 for x in first if not x["cover"]), len(first) // spec["cover_every_but"])

    def test_bookorbit_image_matches_the_pin(self):
        lock = (kit.ROOT / "tools" / "upstreams.lock").read_text()
        pin = re.search(r"^bookorbit\s+\S+\s+v(\S+)", lock, re.M).group(1)
        compose = (kit.HERE / "compose.yml").read_text()
        self.assertIn(f"ghcr.io/bookorbit/bookorbit:{pin}@sha256:", compose)
        self.assertEqual(len(re.findall(r"image: \S+@sha256:[0-9a-f]{64}", compose)), 2, "every image by digest")


@unittest.skipUnless(os.environ.get("ORBIFY_E2E_LIVE") == "1", "ORBIFY_E2E_LIVE=1 runs against the seeded server")
class LiveTest(unittest.TestCase):
    """The seeded server through the proxy: what every scenario relies on."""

    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads((kit.STATE / "manifest.json").read_text())
        cls.proxy = bofault.serve(free_port(), kit.SERVER)
        cls.device = kit.Device(base=f"http://127.0.0.1:{cls.proxy.server_port}")

    @classmethod
    def tearDownClass(cls):
        cls.proxy.shutdown()

    def test_series_and_shelf(self):
        book = next(b for b in self.manifest["books"] if b["title"] == "Frost Graft")
        detail = self.device.call("GET", f"/plugin/catalog/books/{book['id']}")
        self.assertEqual((detail["seriesName"], detail["seriesIndex"]), ("The Glass Orchard", "4"))
        self.assertEqual([m["title"] for m in detail["seriesMembers"]][:2], ["Seedfall", "The Pruning"])
        self.assertEqual(detail["seriesMembers"][1]["readStatus"], "want_to_read")

    def test_catalog_pages_through_the_proxy(self):
        page = self.device.call("GET", "/plugin/catalog/books?page=1&size=25&sort=title")
        self.assertEqual(len(page["items"]), 25)
        self.proxy.state.set_rules([{"match": {"query": {"size": "^25$"}}, "action": "status", "status": 400}])
        with self.assertRaises(kit.HttpError) as caught:
            self.device.call("GET", "/plugin/catalog/books?page=1&size=25&sort=title")
        self.assertEqual(caught.exception.status, 400)
        self.proxy.state.set_rules([])

    def test_sleep_pool_calls(self):
        """The calls the sleep screen's pool makes (docs/design/lock-screen.md R1-R3, X5)."""
        section = self.device.call("GET", "/plugin/catalog/dashboard/sections/want-to-read")["section"]
        self.assertEqual(section["type"], "want-to-read")
        self.assertTrue(all("id" in b and "title" in b for b in section["books"]))
        # Leave-out membership pages at 100, the server's largest page.
        first = self.device.call("GET", "/plugin/catalog/books?page=1&size=100&sort=recently_added&order=desc")
        self.assertEqual(len(first["items"]), min(100, len(self.manifest["books"])))
        self.assertIn("hasNext", first)
        with self.assertRaises(kit.HttpError):
            self.device.call("GET", "/plugin/catalog/books?page=1&size=200")
        for kind in ("smart-scopes", "collections"):
            self.assertIsInstance(self.device.call("GET", f"/plugin/catalog/sections/{kind}"), (list, dict))
        book = first["items"][0]
        self.assertIn("tags", self.device.call("GET", f"/plugin/catalog/books/{book['id']}"))
        url = f"{self.device.base}/api/v1/koreader/plugin/catalog/books/{book['id']}/thumbnail"
        status, body = kit.request("GET", url, self.device.headers)
        self.assertIn(status, (200, 404))
        if status == 200:
            self.assertGreater(len(body), 0)

    def test_rewrite_changes_the_hash(self):
        changed = kit.rewrite("copy_refresh")
        self.assertNotEqual(changed["new_hash"], changed["old_hash"])
        detail = self.device.call("GET", f"/plugin/catalog/books/{changed['id']}")
        self.assertEqual(detail["files"][0]["fileHash"], changed["new_hash"])


if __name__ == "__main__":
    unittest.main(verbosity=2)

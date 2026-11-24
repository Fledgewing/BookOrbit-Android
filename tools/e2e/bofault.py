#!/usr/bin/env python3
"""bofault: the fault proxy between the e2e devices and BookOrbit (emulated-release-tests.md §5).

    tools/e2e/bofault.py [--port P] [--upstream URL] [--rules FILE] [--log FILE]

Forwards every request to the server unchanged unless a rule matches it. Rules are a JSON list,
the first active match wins:

    {"match": {"method": "GET", "path": "^/api/v1/koreader/plugin/catalog/books$",
               "query": {"limit": "100"}},
     "action": "delay" | "status" | "timeout" | "drop",
     "ms": 90000,            # delay: wait this long, then forward; timeout: hold this long (default 600 s)
     "status": 400, "body": "...",    # status: answer this, never forward
     "after": 0,             # let this many matching requests through first
     "times": 1}             # then apply to this many (absent = every one after)

`path` and each `query` value are regular expressions (re.search; a query key must be present).
`timeout` reads the request and never answers; `drop` closes the connection without a reply.
Offline as a whole is a `drop` rule matching everything (shared/fixtures/e2e/faults/offline.json).

Every request is logged as one JSON line (time, method, path, query, rule, status, ms, bytes) to
--log and kept in memory. A scenario drives the proxy over HTTP on the same port, under
/__bofault/ (never subject to rules): POST rules (replaces them, counters restart), GET log,
POST reset (clears rules and the log). Standard library only.
"""

from __future__ import annotations

import argparse
import http.client
import json
import re
import socket
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

CONTROL = "/__bofault/"
HOP_HEADERS = {"connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "te", "trailer"}


class Rule:
    def __init__(self, spec: dict, index: int):
        self.spec = spec
        self.index = index
        match = spec.get("match", {})
        self.method = match.get("method")
        self.path = re.compile(match["path"]) if "path" in match else None
        self.query = {k: re.compile(v) for k, v in match.get("query", {}).items()}
        self.action = spec["action"]
        if self.action not in ("delay", "status", "timeout", "drop"):
            raise ValueError(f"rule {index}: unknown action {self.action!r}")
        self.after = int(spec.get("after", 0))
        self.times = spec.get("times")
        self.seen = 0
        self.applied = 0

    def matches(self, method: str, path: str, query: dict[str, list[str]]) -> bool:
        if self.method and self.method != method:
            return False
        if self.path and not self.path.search(path):
            return False
        return all(k in query and any(p.search(v) for v in query[k]) for k, p in self.query.items())

    def take(self) -> bool:
        """Counts a matching request; True when the rule applies to it."""
        self.seen += 1
        if self.seen <= self.after:
            return False
        if self.times is not None and self.applied >= int(self.times):
            return False
        self.applied += 1
        return True


class State:
    def __init__(self, log_path: Path | None):
        self.lock = threading.Lock()
        self.rules: list[Rule] = []
        self.entries: list[dict] = []
        self.log_path = log_path
        if log_path:
            log_path.parent.mkdir(parents=True, exist_ok=True)

    def set_rules(self, specs: list[dict]) -> None:
        rules = [Rule(s, i) for i, s in enumerate(specs)]
        with self.lock:
            self.rules = rules

    def pick(self, method: str, path: str, query: dict[str, list[str]]) -> Rule | None:
        with self.lock:
            for rule in self.rules:
                if rule.matches(method, path, query) and rule.take():
                    return rule
        return None

    def record(self, entry: dict) -> None:
        line = json.dumps(entry, sort_keys=True)
        with self.lock:
            self.entries.append(entry)
            if self.log_path:
                with self.log_path.open("a") as f:
                    f.write(line + "\n")


def make_handler(state: State, upstream: urllib.parse.SplitResult):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):  # the JSONL log is the record
            pass

        def _body(self) -> bytes:
            length = int(self.headers.get("Content-Length") or 0)
            return self.rfile.read(length) if length else b""

        def _reply(self, status: int, body: bytes, content_type: str = "application/json") -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _control(self, body: bytes) -> None:
            what = self.path[len(CONTROL):].split("?")[0]
            if what == "rules" and self.command == "POST":
                state.set_rules(json.loads(body or b"[]"))
                return self._reply(200, b'{"ok":true}')
            if what == "log" and self.command == "GET":
                with state.lock:
                    text = "".join(json.dumps(e, sort_keys=True) + "\n" for e in state.entries)
                return self._reply(200, text.encode(), "application/x-ndjson")
            if what == "reset" and self.command == "POST":
                state.set_rules([])
                with state.lock:
                    state.entries.clear()
                return self._reply(200, b'{"ok":true}')
            return self._reply(404, b'{"error":"unknown control request"}')

        def _handle(self) -> None:
            started = time.monotonic()
            body = self._body()
            if self.path.startswith(CONTROL):
                return self._control(body)
            parts = urllib.parse.urlsplit(self.path)
            query = urllib.parse.parse_qs(parts.query, keep_blank_values=True)
            rule = state.pick(self.command, parts.path, query)
            entry = {"t": round(time.time(), 3), "method": self.command, "path": parts.path,
                     "query": {k: v[0] if len(v) == 1 else v for k, v in query.items()},
                     "rule": rule.index if rule else None, "action": rule.action if rule else "forward"}
            status, size = 0, 0
            try:
                if rule and rule.action == "drop":
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                    return
                if rule and rule.action == "timeout":
                    self.close_connection = True
                    self.connection.settimeout(rule.spec.get("ms", 600_000) / 1000)
                    try:  # hold the connection open, answering nothing, until the client gives up
                        while self.connection.recv(1024):
                            pass
                    except OSError:
                        pass
                    return
                if rule and rule.action == "status":
                    status = int(rule.spec.get("status", 500))
                    payload = rule.spec.get("body", json.dumps({"statusCode": status, "message": "bofault"})).encode()
                    size = len(payload)
                    return self._reply(status, payload)
                if rule and rule.action == "delay":
                    time.sleep(rule.spec.get("ms", 0) / 1000)
                status, size = self._forward(body)
            finally:
                entry.update(status=status, bytes=size, ms=round((time.monotonic() - started) * 1000))
                state.record(entry)

        def _forward(self, body: bytes) -> tuple[int, int]:
            conn = http.client.HTTPConnection(upstream.hostname, upstream.port or 80, timeout=600)
            headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_HEADERS}
            headers["Host"] = upstream.netloc
            try:
                conn.request(self.command, self.path, body=body or None, headers=headers)
                resp = conn.getresponse()
                payload = resp.read()
            except OSError:
                self._reply(502, b'{"statusCode":502,"message":"bofault: upstream unreachable"}')
                return 502, 0
            finally:
                conn.close()
            self.send_response(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() not in HOP_HEADERS and k.lower() != "content-length":
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(payload)
            return resp.status, len(payload)

        do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = _handle

    return Handler


class QuietServer(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        # A device that restarts mid-request (a forced wake, the end of a run) closes its socket:
        # the request is in the log already; no traceback for it.
        if isinstance(sys.exc_info()[1], (ConnectionError, TimeoutError)):
            return
        super().handle_error(request, client_address)


def serve(port: int, upstream: str, rules: list[dict] | None = None, log: Path | None = None) -> ThreadingHTTPServer:
    """Starts the proxy on 127.0.0.1:port in a daemon thread and returns the server."""
    state = State(log)
    state.set_rules(rules or [])
    server = QuietServer(("127.0.0.1", port), make_handler(state, urllib.parse.urlsplit(upstream)))
    server.daemon_threads = True
    server.state = state  # type: ignore[attr-defined]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main(argv: list[str]) -> int:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from kit import ENV  # noqa: E402

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=int(ENV["BOFAULT_PORT"]))
    parser.add_argument("--upstream", default=f"http://127.0.0.1:{ENV['APP_PORT']}")
    parser.add_argument("--rules", type=Path)
    parser.add_argument("--log", type=Path)
    args = parser.parse_args(argv[1:])
    rules = json.loads(args.rules.read_text())["rules"] if args.rules else []
    server = serve(args.port, args.upstream, rules, args.log)
    print(f"bofault: 127.0.0.1:{args.port} -> {args.upstream} ({len(rules)} rules)", flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        server.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

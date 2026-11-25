#!/usr/bin/env python3
"""W30 synthetic HTTP catalog through the actual SDL firmware, HTTP client and SD adapter.
No device or live account. Requests/latency exclude real TLS/Tailscale and reader SD timing.
"""
import argparse
import json
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path[:0] = [str(HERE / "e2e"), str(ROOT / "tools/e2e")]
from sim import SdCard, Simulator
import kit


class Catalog:
    def __init__(self, count, latency):
        self.shape = json.loads((ROOT / "shared/fixtures/catalog/bulk-refresh/catalog.json").read_text())["benchmark"]
        self.count, self.latency = count, latency
        self.changed = False
        self.requests = []

    def series(self, book):
        return book % self.shape["primary_series"] + 1

    def members(self, series):
        values = [n for n in range(1, self.count + 1) if self.series(n) == series]
        if series <= self.shape["secondary_series"]:
            values += [n * 100 + 50 + series - 1 for n in range(1, self.shape["secondary_members_per_series"] + 1)]
        return [n for n in values if n <= self.count]

    def row(self, book, manifest=False, context=None):
        series = self.series(book)
        result = {"id": book, "title": f"Book {book:05}" + (" changed" if self.changed and book == 1 else ""),
                  "authors": [f"Author {book % self.shape['authors']:03}"], "formats": ["epub" if book % 2 == 0 else "pdf"],
                  "seriesName": f"Series {series:03}", "seriesIndex": str(book // self.shape["primary_series"]),
                  "files": [{"id": book * 10, "format": "epub", "sizeBytes": 1000,
                             "devicePath": f"Book-{book}.epub", "contentVersion": "v1",
                             "fileHash": f"{book:032x}", "downloadUrl": f"/files/{book * 10}/download"}]}
        if not manifest:
            result.pop("files")
            result.update(seriesId=series, readStatus=["unread", "reading", "read"][book % 3],
                          progressPercentage=(book % 3) * 25, hasCover=False,
                          addedAt="2026-01-01T00:00:00Z", lastReadAt=None,
                          updatedAt="2026-02-01T00:00:00Z" if self.changed and book == 1 else "2026-01-01T00:00:00Z")
        if context is not None:
            result.update(seriesId=context, seriesName=f"Series {context:03}",
                          seriesIndex=str(book // self.shape["primary_series"]) if series == context else str(200 + book))
        return result

    def response(self, request):
        path, q = urlsplit(request).path, parse_qs(urlsplit(request).query)
        def value(key, default=""):
            return q.get(key, [default])[0]
        size, page = int(value("size", "100")), int(value("page", "1"))
        if path.endswith("/manifest"):
            start = int(value("cursor", "0"))
            last = min(start + size, self.count)
            return {"items": [self.row(n, True) for n in range(start + 1, last + 1)],
                    "hasNext": last < self.count, "nextCursor": str(last) if last < self.count else None,
                    "manifestVersion": "changed" if self.changed else "initial"}
        if "/sections/" in path and "/dashboard/" not in path:
            section = path.rsplit("/", 1)[1]
            count = {"authors": 50, "series": self.shape["primary_series"], "libraries": 2, "collections": 3, "smart-scopes": 2}[section]
            values = []
            for n in range(1, count + 1):
                row = {"id": f"Author {n - 1:02}" if section == "authors" else f"series:{n}" if section == "series" else n,
                       "title": f"Author {n - 1:02}" if section == "authors" else f"Series {n:03}" if section == "series" else f"{section} {n}",
                       "count": len(self.members(n)) if section == "series" else self.count // count,
                       "readingCount": self.count // count // 3, "finishedCount": self.count // count // 3}
                if section == "series": row["seriesId"] = n
                values.append(row)
            if value("sort") == "name_desc": values.reverse()
            return {"items": values[(page-1)*size:page*size], "total": count, "page": page, "size": size}
        if path.endswith("/books"):
            values = list(range(1, self.count + 1))
            context = int(value("seriesId")) if value("seriesId") else None
            if context: values = self.members(context)
            for selector, divisor in (("libraryId", 2), ("collectionId", 7), ("smartScopeId", 11)):
                if value(selector): values = [n for n in values if n % divisor == int(value(selector)) - (1 if selector == "libraryId" else 0)]
            if value("readStatus"):
                group = {"unread": 0, "reading": 1, "finished": 2}[value("readStatus")]
                values = [n for n in values if n % 3 == group]
            if "ids[]" in q or "ids" in q:
                ids = {int(n) for value in q.get("ids", q.get("ids[]", [])) for n in value.split(",")}
                values = [n for n in values if n in ids]
            sort = value("sort", "recently_added")
            if sort == "author": values.sort(key=lambda n: (n % self.shape["authors"], n))
            elif sort == "series": values.sort(key=lambda n: (n // self.shape["primary_series"] if self.series(n) == context else 200+n, n) if context else (self.series(n), n // self.shape["primary_series"], n))
            if value("order", "desc" if sort.startswith("recently_") else "asc") == "desc": values.reverse()
            return {"items": [self.row(n, context=context) for n in values[(page-1)*size:page*size]],
                    "total": len(values), "page": page, "size": size, "buckets": [{"key": "B", "index": 0}]}
        if path.endswith("/root"):
            return {"sections": [{"section": n, "title": n} for n in ("recent", "all-books", "authors", "series", "libraries", "collections", "smart-scopes")]}
        if "/books/" in path or "/files/" in path or "/thumbnail" in path:
            raise AssertionError("eager detail/cover request: " + path)
        return {"counts": {"totalBooks": self.count}, "section": {"books": []}, "sections": [], "items": []}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--books", type=int, default=10300)
    parser.add_argument("--latency-ms", type=int, default=0)
    parser.add_argument("--timeout", type=int, default=580)
    parser.add_argument("--modes", nargs="+", default=["cold", "unchanged", "changed"])
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    catalog = Catalog(args.books, args.latency_ms)
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def do_GET(self):
            catalog.requests.append(self.path)
            if catalog.latency: time.sleep(catalog.latency / 1000)
            try: body = json.dumps(catalog.response(self.path), separators=(",", ":")).encode(); code = 200
            except Exception as error: body = json.dumps({"error": str(error)}).encode(); code = 500
            self.send_response(code); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        def log_message(self, *_): pass
    server = ThreadingHTTPServer((urlsplit(kit.PROXY).hostname, 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    proxy = urlsplit(kit.PROXY)._replace(netloc=f"{server.server_address[0]}:{server.server_address[1]}", path="").geturl()
    card = SdCard(args.out / "card", proxy, {"username": "fixture", "password": "fixture"})
    # Avoid an unrelated Home network request: the persisted global worker owns the run.
    folder = card.crosspoint / "orbify"; folder.mkdir(exist_ok=True)
    sim = Simulator(args.checkout.resolve() / ".pio/build/x4-pro-simulator/program", args.out)
    results = []
    for mode in args.modes:
        catalog.changed = mode == "changed"
        (folder / "mirror.request").write_text("1\n")
        catalog.requests.clear()
        run = sim.run(card, mode, script=f"{args.timeout * 1000}:QUIT", timeout_s=args.timeout + 5,
                      quit_after_sync=False, env={"ORBIFY_SIM_QUIT_BULK_DONE": "1"})
        matches = re.findall(r"Bulk catalog: ok=(\d+) requests=(\d+) secondaryRequests=(\d+) bytes=(\d+) elapsedMs=(\d+) rows=(\d+) psramPeakBytes=(\d+) bytesOnSD=(\d+)", run.output)
        if not matches or matches[-1][0] != "1": raise AssertionError(f"{mode}: bulk run failed; inspect {args.out / (mode + '.log')}")
        values = list(map(int, matches[-1]))
        result = dict(zip(("ok", "requests", "secondaryRequests", "bytes", "elapsedMs", "rows", "psramPeakBytes", "bytesOnSD"), values), mode=mode, httpRequests=len(catalog.requests))
        results.append(result); print(json.dumps(result), flush=True)
        (args.out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    server.shutdown()


if __name__ == "__main__": main()

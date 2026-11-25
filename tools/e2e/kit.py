#!/usr/bin/env python3
"""The emulated release tests' server kit (docs/design/emulated-release-tests.md, stage 0).

    tools/e2e/kit.py up         server up (compose.yml), library generated, seeded; prints the URLs
    tools/e2e/kit.py seed       (re)seed a running server; idempotent
    tools/e2e/kit.py rewrite R  BookOrbit writes its metadata into the file of role R
                                (shared/fixtures/e2e/library.json "roles"): the file's hash changes
    tools/e2e/kit.py down       server down, volumes removed

The library is synthetic (shared/fixtures/e2e/library.json): generated EPUBs with invented
titles, authors and series, the same bytes on every run. Devices reach the server through the
fault proxy (bofault.py) on BOFAULT_PORT, never directly. Standard library only; needs docker.
"""

from __future__ import annotations

import hashlib
import json
import os
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
import zlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
# @fixture e2e/library.json
SPEC = ROOT / "shared" / "fixtures" / "e2e" / "library.json"
STATE = Path(os.environ.get("ORBIFY_E2E_STATE", ROOT / "upstream" / "e2e"))  # gitignored
FIXED_DATE = (2024, 1, 1, 0, 0, 0)


def load_env(path: Path = HERE / "e2e.env") -> dict[str, str]:
    env = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            env[key] = value
    return env


ENV = load_env()
SERVER = f"http://127.0.0.1:{ENV['APP_PORT']}"
PROXY = f"http://127.0.0.1:{ENV['BOFAULT_PORT']}"


def partial_md5(data: bytes) -> str:
    """KOReader's partial MD5, the identity BookOrbit keys a book file on: 1 KB at offset 0, then
    at 1024 << 2i for i = 0..10, as far as the file goes."""
    md5 = hashlib.md5()
    for offset in [0] + [1024 << (2 * i) for i in range(11)]:
        if offset >= len(data):
            break
        md5.update(data[offset:offset + 1024])
    return md5.hexdigest()


# --- The synthetic library ----------------------------------------------------------------------


def _png(width: int, height: int, shade: int) -> bytes:
    def chunk(kind: bytes, payload: bytes) -> bytes:
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))

    rows = b"".join(b"\x00" + bytes([shade if (y // 40) % 2 else 255 - shade]) * width for y in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


def books_from_spec(spec: dict) -> list[dict]:
    books = []
    for series in spec["series"]:
        for i, title in enumerate(series["books"], start=1):
            books.append({"title": title, "author": series["author"], "series": series["name"], "index": i})
    for n in range(1, spec["standalones"] + 1):
        books.append({"title": f"Standalone {n:02d}", "author": spec["authors"][(n - 1) % len(spec["authors"])],
                      "series": None, "index": None})
    for number, book in enumerate(books, start=1):
        book["number"] = number
        book["cover"] = number % spec["cover_every_but"] != 0
        book["file"] = f"{number:03d} {book['title']}.epub"
        book["uuid"] = f"urn:uuid:{hashlib.sha1(book['title'].encode()).hexdigest()[:8]}-0000-4000-8000-{number:012d}"
    return books


def epub_bytes(book: dict, spec: dict) -> bytes:
    """An EPUB 3 with Calibre's and EPUB 3's series metadata, `chapters` chapters of plain text."""
    from io import BytesIO

    def esc(s: str) -> str:
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    chapters = spec["chapters"]
    series_meta = ""
    if book["series"]:
        series_meta = (f'<meta name="calibre:series" content="{esc(book["series"])}"/>'
                       f'<meta name="calibre:series_index" content="{book["index"]}"/>'
                       f'<meta property="belongs-to-collection" id="s">{esc(book["series"])}</meta>'
                       f'<meta refines="#s" property="collection-type">series</meta>'
                       f'<meta refines="#s" property="group-position">{book["index"]}</meta>')
    cover_meta = '<meta name="cover" content="cover"/>' if book["cover"] else ""
    cover_item = '<item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>' if book["cover"] else ""
    items = "".join(f'<item id="c{i}" href="c{i}.xhtml" media-type="application/xhtml+xml"/>' for i in range(1, chapters + 1))
    spine = "".join(f'<itemref idref="c{i}"/>' for i in range(1, chapters + 1))
    opf = (f'<?xml version="1.0" encoding="UTF-8"?>\n<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
           f'unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
           f'<dc:identifier id="uid">{book["uuid"]}</dc:identifier><dc:title>{esc(book["title"])}</dc:title>'
           f'<dc:creator>{esc(book["author"])}</dc:creator><dc:language>en</dc:language>'
           f'<meta property="dcterms:modified">2024-01-01T00:00:00Z</meta>{series_meta}{cover_meta}</metadata>'
           f'<manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
           f'{cover_item}{items}</manifest><spine>{spine}</spine></package>')
    nav = ('<?xml version="1.0" encoding="UTF-8"?>\n<html xmlns="http://www.w3.org/1999/xhtml" '
           'xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body>'
           '<nav epub:type="toc"><ol>' + "".join(f'<li><a href="c{i}.xhtml">Chapter {i}</a></li>'
                                                for i in range(1, chapters + 1)) + "</ol></nav></body></html>")
    out = BytesIO()
    with zipfile.ZipFile(out, "w") as z:
        def add(name: str, data: bytes | str, compress: int = zipfile.ZIP_DEFLATED) -> None:
            info = zipfile.ZipInfo(name, FIXED_DATE)
            info.compress_type = compress
            z.writestr(info, data)

        add("mimetype", "application/epub+zip", zipfile.ZIP_STORED)
        add("META-INF/container.xml", '<?xml version="1.0"?>\n<container version="1.0" '
            'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile '
            'full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        add("OEBPS/content.opf", opf)
        add("OEBPS/nav.xhtml", nav)
        if book["cover"]:
            add("OEBPS/cover.png", _png(120, 180, 40 + (book["number"] * 37) % 170), zipfile.ZIP_STORED)
        for i in range(1, chapters + 1):
            paragraphs = "".join(
                f"<p>{esc(book['title'])}, chapter {i}, paragraph {p}. The rows of the orchard ran on past the "
                f"hill, and the reader turned the page to see where they went.</p>"
                for p in range(1, spec["paragraphs_per_chapter"] + 1))
            add(f"OEBPS/c{i}.xhtml", '<?xml version="1.0" encoding="UTF-8"?>\n<html '
                f'xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter {i}</title></head><body>'
                f"<h1>Chapter {i}</h1>{paragraphs}</body></html>")
    return out.getvalue()


def generate(out_dir: Path, spec: dict | None = None) -> list[dict]:
    """Writes every book into out_dir and returns the books with their hashes. The hashes are
    checked to be unique: BookOrbit identifies a book by its file's hash."""
    spec = spec or json.loads(SPEC.read_text())
    out_dir.mkdir(parents=True, exist_ok=True)
    books = books_from_spec(spec)
    for book in books:
        data = epub_bytes(book, spec)
        book["hash"] = partial_md5(data)
        path = out_dir / book["file"]
        if not path.exists() or path.read_bytes() != data:
            path.write_bytes(data)
    hashes = [b["hash"] for b in books]
    if len(set(hashes)) != len(hashes):
        raise SystemExit("two generated books share a partial MD5; change the generator")
    return books


# --- BookOrbit's API ----------------------------------------------------------------------------


class HttpError(RuntimeError):
    def __init__(self, method: str, url: str, status: int, body: str):
        super().__init__(f"{method} {url} -> HTTP {status}: {body[:300]}")
        self.status = status


def request(method: str, url: str, headers: dict[str, str] | None = None, payload: Any = None,
            data: bytes | None = None, timeout: float = 30) -> tuple[int, bytes]:
    headers = dict(headers or {})
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


@dataclass
class Admin:
    """The account's web API (/api/v1, bearer token)."""
    base: str = SERVER
    token: str = ""

    def call(self, method: str, path: str, payload: Any = None, ok: tuple[int, ...] = (200, 201),
             data: bytes | None = None, headers: dict[str, str] | None = None) -> Any:
        h = {"Accept": "application/json", **(headers or {})}
        if self.token:
            h["Authorization"] = f"Bearer {self.token}"
        status, body = request(method, f"{self.base}/api/v1{path}", h, payload, data)
        if status not in ok:
            raise HttpError(method, path, status, body.decode(errors="replace"))
        return json.loads(body) if body.strip() else {}

    def wait_healthy(self, timeout_s: float = 180) -> None:
        deadline = time.monotonic() + timeout_s
        while True:
            try:
                if request("GET", f"{self.base}/api/v1/health")[0] == 200:
                    return
            except OSError:
                pass
            if time.monotonic() > deadline:
                raise SystemExit("the BookOrbit server never became healthy")
            time.sleep(1)

    def sign_in(self) -> None:
        """Reuses the token kept in STATE while the server accepts it: BookOrbit allows 5 logins a
        minute (auth.controller.ts @Throttle), and JWT_EXPIRES_IN (e2e.env) keeps a token a day."""
        kept = STATE / "admin-token"
        if kept.exists():
            self.token = kept.read_text().strip()
            if request("GET", f"{self.base}/api/v1/libraries",
                       {"Accept": "application/json", "Authorization": f"Bearer {self.token}"})[0] == 200:
                return
        creds = {"username": ENV["E2E_USER"], "password": ENV["E2E_PASSWORD"]}
        status, body = request("POST", f"{self.base}/api/v1/auth/login", {"Accept": "application/json"}, creds)
        if status != 200:
            self.call("POST", "/auth/setup", {**creds, "name": "Reader", "email": "reader@example.invalid"},
                      headers={"x-setup-token": ENV["SETUP_BOOTSTRAP_TOKEN"]})
            status, body = request("POST", f"{self.base}/api/v1/auth/login", {"Accept": "application/json"}, creds)
        if status != 200:
            raise HttpError("POST", "/auth/login", status, body.decode(errors="replace"))
        self.token = json.loads(body)["accessToken"]
        kept.parent.mkdir(parents=True, exist_ok=True)
        kept.write_text(self.token)

    def upload(self, library_id: int, path: Path) -> None:
        boundary = f"orbify-e2e-{time.time_ns()}"
        data = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{path.name}"\r\n'
                f"Content-Type: application/epub+zip\r\n\r\n").encode() + path.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
        self.call("POST", f"/libraries/{library_id}/upload", data=data, ok=(200, 201, 409),
                  headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})

    def books(self) -> list[dict]:
        items, page = [], 0
        while True:
            result = self.call("POST", "/books/query", {"pagination": {"page": page, "size": 200}})
            items += result.get("items", [])
            page += 1
            if not result.get("items") or len(items) >= int(result.get("total", 0)):
                return items


@dataclass
class Device:
    """A KOReader-sync device (/api/v1/koreader, x-auth headers): what the readers speak."""
    base: str = SERVER
    device_id: str = "orbify-e2e-seed"
    headers: dict[str, str] = field(default_factory=lambda: {
        "Accept": "application/json", "x-auth-user": ENV["E2E_KOSYNC_USER"],
        "x-auth-key": hashlib.md5(ENV["E2E_KOSYNC_PASSWORD"].encode()).hexdigest()})

    def call(self, method: str, path: str, payload: Any = None, ok: tuple[int, ...] = (200,)) -> Any:
        status, body = request(method, f"{self.base}/api/v1/koreader{path}", self.headers, payload)
        if status not in ok:
            raise HttpError(method, path, status, body.decode(errors="replace"))
        return json.loads(body) if body.strip() else {}


# --- Commands -----------------------------------------------------------------------------------


def compose(*args: str) -> None:
    subprocess.check_call(["docker", "compose", "--env-file", str(HERE / "e2e.env"), "-f", str(HERE / "compose.yml"), *args],
                          stdin=subprocess.DEVNULL)


def seed() -> dict:
    """Seeds the running server; returns the manifest scenarios read (also written to STATE)."""
    spec = json.loads(SPEC.read_text())
    books = generate(STATE / "library", spec)
    admin = Admin()
    admin.wait_healthy()
    admin.sign_in()
    creds = {"username": ENV["E2E_KOSYNC_USER"], "password": ENV["E2E_KOSYNC_PASSWORD"]}
    status, _ = request("POST", f"{SERVER}/api/v1/koreader/credentials",
                        {"Accept": "application/json", "Authorization": f"Bearer {admin.token}"}, creds)
    if status not in (200, 201):
        admin.call("PATCH", "/koreader/credentials", creds)
    libraries = admin.call("GET", "/libraries")
    if not libraries:
        admin.call("POST", "/libraries", {"name": "Orchard", "icon": "book", "folders": ["/data/library"]})
        libraries = admin.call("GET", "/libraries")
    library_id = int(libraries[0]["id"])

    known = {b.get("title") for b in admin.books()}
    for book in books:
        if book["title"] not in known:
            admin.upload(library_id, STATE / "library" / book["file"])
    deadline = time.monotonic() + 300
    while True:
        on_server = {b.get("title"): b for b in admin.books()}
        missing = [b["title"] for b in books if b["title"] not in on_server]
        unseries = [b["title"] for b in books if b["series"] and not on_server.get(b["title"], {}).get("seriesName")
                    and not on_server.get(b["title"], {}).get("series")]
        if not missing and not unseries:
            break
        if time.monotonic() > deadline:
            raise SystemExit(f"ingestion stalled: missing {missing[:5]}, no series yet {unseries[:5]}")
        time.sleep(2)
    for book in books:
        book["id"] = int(on_server[book["title"]]["id"])
    # The server's hash is the readers' (KOReader's partial MD5) for a book no scenario rewrites.
    probe = next(b for b in books if b["title"] not in spec["roles"].values())
    if epub_hash(admin, probe["id"]) != probe["hash"]:
        raise SystemExit(f"BookOrbit hashes {probe['file']} as {epub_hash(admin, probe['id'])}, the kit as {probe['hash']}")

    device = Device()
    device.call("GET", "/users/auth")
    # What scenarios change goes back: the books they finish are unread again, the shelf as listed.
    roles = {v for k, v in spec["roles"].items() if not k.startswith("_")}
    for book in books:
        if book["title"] in spec["want_to_read"]:
            device.call("PUT", f"/plugin/catalog/books/{book['id']}/read-status", {"status": "want_to_read"})
        elif book["title"] in roles:
            device.call("PUT", f"/plugin/catalog/books/{book['id']}/read-status", {"status": "unread"})

    manifest = {"server": SERVER, "proxy": PROXY, "library_id": library_id,
                "user": ENV["E2E_USER"], "kosync": {"username": creds["username"], "password": creds["password"]},
                "books": books, "roles": {k: v for k, v in spec["roles"].items() if not k.startswith("_")}}
    (STATE / "manifest.json").write_text(json.dumps(manifest, indent=1))
    return manifest


def rewrite(role_or_title: str) -> dict:
    """BookOrbit writes its metadata into the book's file (write-and-rename, as editing a book with
    write-back on does): the file's hash changes, the old one stays in the book's history.
    Returns the book with the library's hash (old_hash, what readers hold) and the new one."""
    manifest = json.loads((STATE / "manifest.json").read_text())
    title = manifest["roles"].get(role_or_title, role_or_title)
    book = next(b for b in manifest["books"] if b["title"] == title)
    admin = Admin()
    admin.sign_in()
    result = admin.call("POST", f"/books/{book['id']}/write-and-rename", {})
    if result.get("write", {}).get("status") != "success":
        raise SystemExit(f"metadata write-back failed: {result}")
    new_hash = epub_hash(admin, book["id"])
    if new_hash == book["hash"]:  # a second write-back may leave the file as the first one did
        raise SystemExit(f"{title}: the write-back left the file's hash at the library's {new_hash}")
    return {**book, "old_hash": book["hash"], "new_hash": new_hash}


def epub_hash(admin: Admin, book_id: int) -> str:
    detail = admin.call("GET", f"/books/{book_id}")
    return next(f["fileHash"] for f in detail["files"] if f["format"].lower() == "epub")


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "up"
    if cmd == "up":
        compose("up", "-d", "--wait")
        started = time.monotonic()
        manifest = seed()
        print(f"seeded {len(manifest['books'])} books in {time.monotonic() - started:.0f} s; "
              f"server {SERVER}, devices use the proxy {PROXY} (tools/e2e/bofault.py)")
    elif cmd == "seed":
        print(f"seeded {len(seed()['books'])} books")
    elif cmd == "rewrite":
        print(json.dumps(rewrite(argv[2])))
    elif cmd == "down":
        compose("down", "-v")
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

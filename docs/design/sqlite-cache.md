# One SQLite database for the offline cache (Android)

Status: building (decided with the user 11-24: SQLite, one file, rollback journal, the companion the
only writer, no backwards compatibility).
Platforms: KOReader-Android. The progress display's rule maps to the Xteink too (last section).

## Why

The offline cache is spread over thousands of small files and one big one:

- One Lua file per saved list page and per book detail (`orbit-cache/mirror/<hash>.lua`,
  `CacheWorker.kt:567-581` `store`), plus one per browsed reply (`orbit-cache/<hash>.lua`,
  `ko/cache.lua:167-179` `OC.put`). A book appears once per list that names it, so a library of
  10,300 books holds the same book many times over.
- The index (`orbit-cache/index.lua`, `ko/cache.lua:76-105`): every entry's metadata in one Lua
  table that KOReader loads whole at start and saves whole, in a forked child, after changes.
  It reached 3.4 MB on the M8C (companion-worker.md "Why").
- The worker's queue (`mirror/worker-state.lua`, `CacheWorker.kt:441-445`): queues, the "seen" set,
  sizes and digests of every saved file, re-encoded whole every 30 s.

The rc.6 log showed the cost: "2,805 of 197,709" and "covers 0/57,409" for about 10,300 books.
Covers are counted once per list a book appears in (`CacheWorker.kt:491-508` `coversFor` runs for
every saved list page and never asks whether the book's cover is already queued), and the job total
grows while list pages land (`State.push`, `:371-377`), so the shown total is neither fixed nor
the number of books. Each saved item is a temp file and a rename on Android's FUSE shared storage,
and the run fetches 16 replies, waits for all of them, then writes 16 files one after another
(`fetchAhead`, `:708-713`): network and disk never overlap. rc.6 managed about 10 items/s.

## Decisions (user, 11-24)

- **SQLite, one file.** The companion is the only writer; KOReader opens it read-only.
- **Rollback journal, not WAL.** WAL needs a shared-memory file mapped by every process
  (`-shm`); KOReader itself only uses WAL where mmap'ed I/O works on the file system
  (`frontend/device/generic/device.lua:131` `canUseWAL`, "requires mmap'ed I/O on the target FS"),
  and Android's FUSE shared storage is where that is least reliable. Journal mode `TRUNCATE`
  (KOReader's own non-WAL choice, `plugins/statistics.koplugin/main.lua:459`, and Android's
  default). Writes are short transactions, one page of results each; KOReader reads with a busy
  timeout.
- **Bindings:** KOReader's bundled `lua-ljsqlite3` (`require("lua-ljsqlite3/init")`, as
  `plugins/statistics.koplugin/main.lua:13`) and Android's own `android.database.sqlite`.
- **Fallback** if the stress test shows shared storage is flaky: the companion builds a complete
  file aside and swaps it in by rename; KOReader always opens the current file. Only the write and
  publish step changes (see "Publishing").
- **No backwards compatibility.** The plugin and the companion ship together. The old mirror,
  index and entry files are deleted and the first Full refresh rebuilds everything.
- **The companion is required**, with no plugin fallback (as now).

## The file

`koreader/settings/orbit-cache/orbit.db` on shared storage
(`/storage/emulated/0/koreader/settings/...`; KOReader's settings dir is
`android.getExternalStoragePath() .. "/koreader"`, `datastorage.lua:22`). Beside it: `orbit.db-journal`
(kept at zero bytes between transactions, `TRUNCATE`) and a `.nomedia` so MediaProvider never
indexes the folder.

**Shared storage behaviour (MediaProvider FUSE, Android 11 and later).** Both apps reach the file
through the same FUSE mount. What SQLite needs from it, and what the stress test checks:

| SQLite needs | On FUSE | Risk |
|---|---|---|
| POSIX advisory locks (`fcntl F_SETLK`) between two processes | MediaProvider's FUSE daemon doesn't take lock requests, so the kernel keeps the locks itself, per inode, across every process using the mount | the stress test's main question |
| `fsync` of the journal and the file | passed through | slow, not unsafe: one per transaction |
| a shared `mmap` (WAL's `-shm`) | unreliable through FUSE | why WAL is out |
| `rename` within a folder is atomic | yes | the fallback relies on it |

The companion targets SDK 28 with `WRITE_EXTERNAL_STORAGE` (legacy access, as for today's files);
KOReader has all-files access for books.

## Schema (version 1)

`PRAGMA user_version = 1`. The companion creates the file. A file with another `user_version` (an
older or newer build) is deleted and created again empty; the next Full refresh fills it. The
plugin opens nothing whose version isn't its own (it answers from the server, as with an empty
cache). Values are the cache's existing Lua literal format (`Cache.encode` / `LuaValue.encode`),
which both sides already read and write and which LuaJIT decodes fastest (`loadstring`).

```sql
CREATE TABLE meta (k TEXT PRIMARY KEY, v) WITHOUT ROWID;
  -- owner ("user|server"), detail_template, full_at, lib_version, storage (Lua literal totals)
CREATE TABLE books (
  id INTEGER PRIMARY KEY,
  item BLOB,              -- the book as list pages show it (newest seen)
  detail BLOB,            -- the book's detail reply (detail_template filled with id)
  item_at INTEGER, detail_at INTEGER,
  search TEXT             -- lower-cased title, subtitle, authors, series: offline search
);
CREATE TABLE lists (
  identity TEXT PRIMARY KEY, -- the list's path without page, size, offset (Cache.listWindow)
  kind TEXT,                 -- "books" | "section"
  section TEXT,
  total INTEGER,
  head BLOB,                 -- the first page's other fields (no items, no paging fields)
  fetched_at INTEGER, validated_at INTEGER
) WITHOUT ROWID;
CREATE TABLE list_items (
  identity TEXT, pos INTEGER, -- 0-based position in the list
  book_id INTEGER,            -- a books list: the book (its item lives in books)
  item BLOB,                  -- a section list: the entry itself (an author, a series...)
  PRIMARY KEY (identity, pos)
) WITHOUT ROWID;
CREATE INDEX list_items_book ON list_items (book_id);
CREATE TABLE entries (        -- any other cached reply: Home, the dashboard, other reads
  key TEXT PRIMARY KEY, path TEXT, body BLOB, fetched_at INTEGER, validated_at INTEGER,
  home INTEGER, stale INTEGER, bytes INTEGER
) WITHOUT ROWID;
CREATE TABLE cover_keep (name TEXT PRIMARY KEY) WITHOUT ROWID; -- "Save every cover": outside the pruner's cap
CREATE TABLE tags (name BLOB PRIMARY KEY, n INTEGER) WITHOUT ROWID;   -- the Leave out picker
CREATE TABLE scopes (kind TEXT, id TEXT, label BLOB, n INTEGER, PRIMARY KEY (kind, id)) WITHOUT ROWID;
CREATE TABLE leave_out (rule TEXT, book_id INTEGER, PRIMARY KEY (rule, book_id)) WITHOUT ROWID;
CREATE TABLE jobs (           -- the companion's run: its queue, de-duplicated by key
  kind TEXT, ref TEXT, state INTEGER, tries INTEGER, PRIMARY KEY (kind, ref)
) WITHOUT ROWID;
```

**Keyed by book id.** A list stores positions and book ids, never a copy of the book: a book in 6
lists is one row in `books` and 6 rows of two integers. Dedupe is by construction, so the work of a
Full refresh is the number of books, not the number of list memberships. `jobs` has one row per
(kind, ref): a book's detail is `("detail", id)` whichever list named it, a cover is
`("cover", id)`, a page is `("page", identity#offset)`. `INSERT OR IGNORE` is the dedupe.

**Any page size from the same rows.** Positions are 0-based and independent of page size, so a
read of page 3 in 20s and a saved page of 100 use the same rows; the page-size probing
(`Mirror.pageSize`, three `io.open`s per list miss) and the per-size page files go away.

## How KOReader reads

All reads are in `ko/db.lua`: one connection, opened `SQ3.open(path, "ro")`, busy timeout 2 s
(`conn:set_busy_timeout`), prepared statements kept. Each read below runs inside `BEGIN` ...
`COMMIT` (a deferred read transaction), so its two queries see one snapshot.

- **A list page** (`Cache.listWindow(path)` gives identity, offset and size):
  `SELECT kind, total, head FROM lists WHERE identity = ?`, then
  `SELECT li.pos, COALESCE(b.item, li.item) FROM list_items li LEFT JOIN books b ON b.id = li.book_id
  WHERE li.identity = ? AND li.pos >= ? AND li.pos < ? ORDER BY li.pos`. The reply is built like
  `Cache.slice` (head, items, total, page, size, hasNext). A missing position is a miss (served
  from the server, or offline "This page isn't saved"). Cost: one primary-key range, at most the
  page's size of rows decoded.
- **A detail page**: when the path is the detail template filled with an id,
  `SELECT detail, detail_at FROM books WHERE id = ?`; otherwise `entries` by key.
- **A search**: online, the server, as now (not cached). Offline, `SELECT item FROM books WHERE
  search LIKE ? ESCAPE '\' ORDER BY search LIMIT ? OFFSET ?` with the query lower-cased, words
  ANDed; the reply has the server's list shape. A scan of about 10,000 short rows: a few ms.
- **Anything else** (Home, the dashboard): `SELECT body, validated_at, stale FROM entries WHERE key = ?`.

No read decodes more than the rows it returns. Nothing in KOReader reads a whole file that grows
with the library (guard in `test_flows.lua`, below).

**Forked children.** The BookOrbit plugin reads its catalog in a forked child
(`runInSubprocess`). SQLite connections must not cross a `fork()`: `ko/db.lua` remembers the pid it
opened in and a child opens its own connection (the inherited one is left alone, never closed).

## Mid-write reads

Rollback journal locking: a reader holds SHARED for its read transaction; the writer collects its
changes in its cache and the journal, and needs EXCLUSIVE only to write them into the file at
COMMIT. So:

- a read that starts during a write transaction reads the last committed state;
- a read that starts while a commit is being written waits (busy timeout) and then reads the new
  state; a commit is one page of results (at most 100 rows), a few ms to tens of ms;
- a reader never sees a half-written transaction: either the journal is still hot and SQLite
  refuses (`SQLITE_BUSY`), or the commit finished.
- If the companion dies mid-commit, the journal is hot. A read-only connection cannot roll it back
  (`SQLITE_READONLY_ROLLBACK`): KOReader treats that like a busy database (a miss, served from the
  server or answered "not saved") and the companion rolls it back the next time it opens the file
  (at every start and every job).
- Writer starvation: KOReader's reads are single statements of milliseconds, never held open.

## Publishing (and the fallback)

The writer is one class, `CacheStore` (companion), with one seam, `publish`: in direct mode a
`BEGIN IMMEDIATE ... COMMIT` per batch on `orbit.db`. If the stress test fails, the swap mode
copies `orbit.db` to `orbit.db.next` at the start of a run, writes there, and at the end (and every
2 minutes during a run) closes it and `rename`s it over `orbit.db`. KOReader's side is the same in
both modes: before each read, `ko/db.lua` compares the file's inode and size
(`lfs.attributes`) with what it opened and reopens when they changed. Nothing else changes.

## Everything Orbit caches or persists, and where it goes

"Into SQLite" names the table. P = plugin, C = companion. Paths under `koreader/settings/`.

| What | Today | Decision |
|---|---|---|
| Browsing entries `orbit-cache/<hash>.lua` | P writes (`ko/cache.lua:167-179`), C writes checked ones (`CacheWorker.kt:82-113`) | **SQLite**: list replies into `lists`/`list_items`/`books`, details into `books`, the rest into `entries`. P no longer writes: on a miss served by the server, P asks C to `STORE` the path (C fetches and saves it) |
| The index `orbit-cache/index.lua` (3.4 MB at worst), saved in a forked child | P (`ko/cache.lua:76-105`) | **deleted**: its fields are columns (`validated_at`, `stale`, `home`, `bytes`); `used_at` goes (eviction is by `fetched_at`, in C); `owner`, `detail_variant` move to `meta`; the forked index save is deleted |
| The mirror `orbit-cache/mirror/<hash>.lua` | C (`CacheWorker.kt:567-581`) | **deleted**: `lists`, `list_items`, `books` |
| `mirror/worker-state.lua` (queue, seen, sizes, digests) | C private | **SQLite** `jobs`; sizes and digests go (a page "changed" is compared row by row) |
| `mirror/plan.lua` (P→C), `status.lua`, `summary.lua` (C→P), `stop` (P→C) | small handshake files | **stay files**: tiny, one writer each, read on a timer; `status.lua` carries the progress (below) |
| `orbit-cache/events/` | child→parent and C→P answers | **stay files**: small handshakes; the `stored` event goes (P stores nothing) and a `store` event (key, path) takes its place |
| `orbit-cache/storage.lua` (totals) | C | **SQLite** `meta.storage` |
| Write-through patches (a finish or a rating patches saved replies) | P rewrites entry files (`ko/cache.lua:523-551`) | **SQLite**, by C: P sends `PATCH` (book id, fields, stale-home); C patches `books.item`, `books.detail` and marks Home `entries` stale |
| Cover files `cache/bookorbit/<id>_<ver>.jpg` and `.etag` | both write (P's thumbnail child, C's mirror) | **stay files**: images; the ETag belongs with its file and P's thumbnail child writes both |
| `mirror/cover_keep.lua` (grows with the library) | C writes, P's pruner decodes it whole | **SQLite** `cover_keep`; the pruner asks per file name |
| Copies lookup: details from the index and the mirror | C (`CacheWorker.kt:249-292`) | **SQLite**: `books.detail` by id |
| `orbit-cache/copies/ask.lua` (P→C) | P | **stays a file**: P is the writer (the on-device copies) |
| `orbit-sleep/tags.json` (grows with distinct tags) | C writes, P's picker reads it whole | **SQLite** `tags` |
| `orbit-sleep/scopes.json` | both write (`SleepPoolBuilder.kt:230`, `sleepscreen.lua:279-284`), unordered | **SQLite** `scopes`, C only |
| `orbit-sleep/choices.json` (P→C, the companion's picker) | P builds it from scopes and tags; broken since bc48fae (`Sleep.cachedTags` is gone, so it is never written) | **deleted**: C builds its picker from `scopes` and `tags` itself |
| `orbit-sleep/leave_out.lua` (every Leave out member id) | C writes, P decodes it whole per rule row on the UI thread | **SQLite** `leave_out`; P asks `count(*)` per rule |
| `orbit-sleep/pool.json`, `state.json` (show counts), `bag.lua`, `covers/` | C private | **stay files**: private to C, small and capped (24 covers); images stay files |
| `orbit-sleep/current.png`, `current.json` | P→C | **stay files**: an image and its caption |
| `orbit-companion.json` (status), `/status` and `/clicks` | C→P | **stay**: the handshake, not a cache |
| Settings sync (`settings.reader.lua`, C's SharedPreferences, `SETTINGS` broadcasts) | both | **stays**: per-key timestamps written by both sides; the cache has one writer. The "Waiting for KOReader" flow (`SettingsSync.pending`, `SettingsSync.kt:174-176`) is unchanged: it compares C's `at` with the plugin's acknowledged `at` in C's own preferences |
| Home cards | Home's sections are cache entries | **SQLite** `entries` (`home = 1`) |
| `orbit-recommended.json` (P→C) | P | **stays a file** (a dozen rows, P writes) |
| `orbit-detail-cache.lua` (end-of-book, at most 32 books), `orbit-finish-queue.lua`, `orbit_local_state.lua` (at most 200) | P private | **stay files**: P's own small state; P can't write the database |
| `stats.db` | C private SQLite | **stays separate**: a cache wipe must never lose battery stats |

## The Full refresh

**Work fixed at the start, counted once.** The run starts with the requests that say how big
everything is: the all-books list (`/books` with the plugin's decoration and no filter, which is
every book the account sees) and each section's index. Then:

- every book's detail is one job (`("detail", id)`), from the all-books list's ids;
- every list is one job per 100 positions, from the section indexes and the lists the plugin has
  read (`entries` paths);
- covers: one per book, only for books on the reader and their neighbours, or all of them with
  "Save every cover".

The total is the sum, fixed once the index pages are in: a list longer than its first page adds its
other pages when its first lands (a few, against thousands of books). The shown % is computed from
it and never goes down (`max` with the last one shown; 100 only when the run finishes).

**Fetch each book once.** List pages bring each book's `item`; details come from the all-books ids,
so a book named by 6 lists is fetched once. A Refresh's recheck rechecks list pages and fetches
details only for books that are new to `books`.

**A pipeline, not batches.** A fixed number of requests in flight (`PARALLEL`, tuned with the kit,
below), refilled as each finishes; covers on their own small pool alongside details. One writer
thread takes landed replies and writes them in transactions of up to 100 rows or 1 s, whichever
comes first. Network, parse and disk overlap.

**Timing lines.** Every 10 s: `mirror: 2,140/10,512 (20%) · 41 items/s · write 18 ms/batch
(max 64) · ETA 3 min`. At the end: `mirror: Full refresh done: 10,300 books, 4,210 lists, 14,903
requests in 4 min 12 s (59 items/s), 0 errors`.

## Progress display (the user's design)

- **On start**, one bottom popup: "Full refresh in progress · about 3% done · you can keep reading
  and browsing while it loads". It closes by itself after 6 s or on a tap. Only for a Full refresh
  the reader started; an automatic one starts with the badge alone.
- **Then a small % badge** in the bottom-left corner: "37%". A tap expands it to the full message
  (done and total, estimated time left, errors so far); another tap collapses it. At the end it
  shows "Done" for 5 s, then goes.
- **One number that never goes down**, from the companion's `status.lua` (`pct`, written monotonic
  by the companion; the plugin also keeps the max).
- **No other notes** during a refresh: the old "Full refresh: reloading everything…", "This page
  is refreshed · N covers checked", the 8-second progress toasts and the "Saved for offline" note go.
  A storage-limit stop shows in the expanded badge.
- **E-ink**: only the badge's own rectangle is redrawn (`UIManager:setDirty(badge, "fast",
  region)`), at most every 3 s (the status poll) and only when the % changed.
- **Where**: BookOrbit Home, the catalog and the reader. In the reader it sits in the bottom-left
  margin, below the text area, and is passive (no tap): a tap there stays KOReader's own corner
  gesture. Nothing else is shown in a book: the badge is the one exception the user asked for, and
  it never takes focus (`reading-gate.md`).
- **The companion** shows the same % in its status area ("Saving BookOrbit for offline · 37%").

## Xteink: the same rule

The Xteink's Full refresh (sync tile, or Settings › BookOrbit › Home) plans its requests up front
(`xteink/orbify/Mirror.cpp:241`, `plan.total()`), so its total is already fixed at the start; it
shows "Full refresh · saving for offline 12/140" as a popup per step
(`xteink/orbify/Mirror.cpp:270-273`). The same rule would map as:

- one popup at the start ("Full refresh · about 0% · you can keep reading"), closed by the next
  button press or after a few seconds;
- then a corner % on the catalog and Home header (beside the ⟳ and its "updated" text), drawn
  with a partial refresh of that rectangle only, when the % changes and at most every few seconds;
  Confirm on the ⟳ row (X4) or a tap on it (X4 Pro) shows counts and errors;
- one number, `done * 100 / total`, never decreasing; no per-step popups; "Done" once at the end;
- not in the reader on the X3 (flash) and only where the reader's status bar has room on the X4s.

Routed separately: this change doesn't touch `xteink/`.

## Tests

- **Schema and queries, both sides, one fixture**: `shared/fixtures/cache/db.json` (books, lists,
  entries, and expected answers for list windows, a detail, offline searches). `CacheStoreTest`
  writes it through the companion's writer and checks the companion's reads; `test_logic.lua`
  builds the same rows with the same schema (`shared/fixtures/cache/schema.sql`, which both test
  suites compare with the code) and checks the plugin's reads.
- **Dedupe**: a library where every book is in 6 lists: one detail and one cover job per book,
  and the total equals books + list pages.
- **Monotonic %, no other notes**: a flow test runs a Full refresh whose total grows mid-run and
  asserts the badge never shows a smaller %, and that no other note is shown during the run.
- **No whole-file parsing on the UI thread**: a flow test opens a list, a detail and an offline
  search on a 10,000-book database and asserts no `Cache.decode` over 8 KB and no read of a file
  larger than 8 KB on the UI thread.
- **Stress test on the device** (below).

## Stress test (before the migration)

The companion's `SQLITE_STRESS` broadcast writes nonstop for 2 minutes into
`orbit-cache/stress.db` (pages of 100 rows, each page one transaction that also bumps a
`gen` row, so a reader can check it saw a whole page). The plugin's "SQLite stress test" (Orbit
menu › About › Debug) sends it and reads the same file nonstop from a forked child: a random page,
then checks that all 100 rows carry the generation `gen` says and that the checksum row matches.
It counts reads, `SQLITE_BUSY` waits (and the longest), and every other error (`SQLITE_CORRUPT`,
a torn page, `READONLY_ROLLBACK`). Each side logs one line; the plugin shows and logs the verdict:
`sqlite-stress: N writes, M reads, 0 errors, max busy wait X ms`.

## Self-grill

1. Lua literals or JSON in the columns? Lua literals: both sides already write and read them
   (`LuaValue.encode`, `Cache.decode`), and `loadstring` is LuaJIT's fastest decoder. Two-way door.
2. Read-only connection and a hot journal? Kept read-only as decided; a hot journal reads as busy
   until the companion opens the file. Two-way door (`query_only` on a read-write connection
   would let KOReader roll it back).
3. P's browsed replies: P writes a spool file C ingests, or C fetches the path again? C fetches:
   nothing to encode on KOReader's side and one writer for every row. A browse miss costs one more
   request; after a Full refresh browse misses are rare. Two-way door.
4. One `item` per book although lists decorate their items? Every list the plugin asks for uses
   the same decoration (`listDecorateBookQuery`); the newest item wins. Two-way door.
5. Offline search: new, and cheap with `books.search`; offline today a search only says it needs a
   connection. Two-way door.
6. The badge in the reader: the user asked for it there; passive, so the corner tap stays KOReader's.
   Two-way door.
7. The queue in the shared file or in the companion's private storage? The shared file: one file to
   delete, and a resumed run finds its jobs beside the rows they fill. KOReader never reads `jobs`.
8. Covers' ETags into SQLite? No: P's thumbnail child writes covers and the database has one
   writer.

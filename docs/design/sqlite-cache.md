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

## Cache lifetime and incremental refresh (rc.8 feedback, W6)

The cache is kept indefinitely. There is no scheduled Full refresh and no library-version-triggered
Full refresh; the old interval settings are removed from both settings surfaces. Only a manual
Full refresh starts a new full run. A paused legacy run may resume silently; a run the reader
started in this KOReader session may keep its badge when resumed.

On network-up, wake or Home, at most once per 15 minutes and only when already connected and not
reading, the companion checks `/koreader/plugin/catalog/books?sort=recently_updated&order=desc`
in pages of 100. It never turns Wi-Fi on. The pinned server supports this sort
(`c1dd6b4f`, `server/src/modules/koreader/dto/koreader-catalog-query.dto.ts:17-26`,
`server/src/modules/koreader/koreader-catalog.service.ts:1568-1569`); it orders by book `updatedAt`
then id (`server/src/modules/opds/opds-book.service.ts:91-92`). The DTO has no `since` or
`updatedAt` filter (`koreader-catalog-query.dto.ts:64-157`), and catalog responses have no ETag
([contract](../server-contract.md#catalog-replies-carry-no-version)).

The worker stops below the last successful timestamp watermark, including the entire boundary
timestamp tie, even across pages. It compares items before overwriting them and fetches details
and optional covers only for changed or missing books. Failed details keep a dirty marker and
failed scans do not advance the watermark. A complete Full refresh establishes the watermark;
ordinary browsing cannot advance it. The timestamp probe normally costs one request; dynamic
shelves and their pages are also rechecked on every run (W15 below). Unchanged books need no details or covers; a large
timestamp tie can require more probe pages.

Membership has no change cursor. When books change, or the progress sweep reports a different
library version, saved list pages are rechecked, discovering new section lists and membership.
These are necessary list requests, not a Full refresh: unchanged books do not fetch details or
covers again. A static membership-only edit that changes neither a book timestamp nor
libraryVersion cannot be discovered by the timestamp probe; dynamic identities are always
rechecked (W15). Normal browse checks / explicit Refresh still recheck those replies; manual Full refresh remains the complete snapshot operation. No unsupported
`since` or conditional-list request is sent. Xteink's separate cache is unchanged by this Android
SQLite correction; it has no scheduled SQLite Full refresh to remove.

## How KOReader reads

All reads are in `ko/db.lua`: one connection, opened `SQ3.open(path, "ro")`, busy timeout 20 ms
(`conn:set_busy_timeout`). Each read below runs inside `BEGIN` ...
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

A busy/locked read returns its last successful result from a bounded 64-result, per-owner and
per-path memo, or a cache miss if there is none. Other failures never use that fallback. Each
SQLite wait is capped at 20 ms, including schema and owner checks; the exclusive-lock flow test
asserts a UI read returns in under 100 ms. The stress test child may use a longer timeout; its
1,950 ms measured maximum must never become a UI-path timeout.

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
  state, or uses the bounded cached fallback after 20 ms. Landed replies are committed in
  batches of at most eight jobs; a list job still contains up to 100 positions;
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

## Everything BookSync caches or persists, and where it goes

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

**A pipeline, not batches.** A fixed number of requests in flight (`PARALLEL` = 8), refilled as
each finishes, with 4 jobs queued per pool thread (`AHEAD`) so the pool never waits on a write;
covers on their own pool (`COVER_PARALLEL` = 6), picked from their own end of the queue so they run
alongside the details, not after them. One writer thread takes landed replies and writes them in
transactions of up to 8 replies or 20 ms (`BATCH`, `BATCH_MS`). Network, parse and disk overlap.

**Speed (measured).** `CacheWorkerBench` (`ORBIFY_BENCH=1`, JVM, a server answering in 60 ms, 2,000
books, covers on: 4,040 requests), the same test on both versions:

| | Requests at once | Time | Items/s | 10,000 books |
|---|---|---|---|---|
| 0.12 rc.6 (files, batches of 16, covers in batches after the details) | 4 | 165 s | 24 | about 14 min |
| SQLite pipeline | 6 + 4 covers | 35 s | 113 | about 3 min |

126 transactions for the run (3 ms each on the JVM, 68 ms at most). On the stage 0 kit (real
BookOrbit, no added latency, 59 books) `CacheWorkerLiveTest` runs 75 requests at 82 items/s one at
a time and 132 items/s six at a time. The device adds Wi-Fi latency and slower commits on shared
storage; at rc.6's measured 10 items/s, the same projection gives about 20 min for 10,000 books
then, and the pipeline's 4.7 times about 4-5 min. Covers are the bound with "Save every cover" on;
without it a run is details and lists only.

**W6 before/after (same host and running stage 0 kit).** Baseline: six requests / four covers,
100 replies per write; after: eight requests / six covers, eight replies per write. With 59 kit
books and 75 requests, baseline was 0.4 s / 195 items/s, after 0.7 s / 100 items/s. The small,
low-latency kit regresses because it pays for more commits (4 batches versus 22); its maximum
batch write falls from 6 ms to 4 ms. Do not treat this small library as a device speed claim.

The identical 2,000-book, 60-ms-latency benchmark with all covers enabled sends 4,040 requests
on both versions: 33.4 s before, 21.7 s after (35% less elapsed time). A linear 10,000-book
projection is 2.8 versus 1.8 minutes **in that synthetic latency model**. Maximum batch write
was 59 versus 25 ms. The M8C baseline remains 35–43 items/s and about 11 minutes for 10,300
books / roughly 24,410 requests; after timing needs a user-run device test. Laptop and device
commit costs differ, so neither projection promises a handheld completion time.

Request audit: full details cannot be replaced by list bodies or the manifest (different
fields; no batch detail endpoint), and list pages are capped at 100. A complete snapshot still
needs every section/list page and one detail per book. Jobs already deduplicate shared books
and covers. The avoidable requests fixed here are unchanged details and all the unchanged covers
on a changed recheck page, and existing series-neighbour details during an incremental run.
Covers remain opt-in for the whole library; there is no new blanket cover download.

**Timing lines.** Every 10 s: `mirror: 2,140/10,512 (20%) · 41 items/s · write 18 ms/batch
(max 64) · ETA 3 min`. At the end: `mirror: Full refresh done: 10,300 books, 4,210 lists, 14,903
requests in 4 min 12 s (59 items/s), 0 errors`.

## Progress display (the user's design)

- **On start**, one bottom popup: "Full refresh in progress · about 3% done · you can keep reading
  and browsing while it loads". It closes by itself after 6 s or on a tap. Only for a Full refresh
  the reader started. Background work and restored legacy runs have neither popup nor badge.
- **Then a small % badge** in the bottom-left corner: "37%". A tap expands it to the full message
  (done and total, estimated time left, errors so far); another tap collapses it. At the end it
  shows "Done" for 5 s, then goes.
- **One number that never goes down**, from the companion's `status.lua` (`pct`, written monotonic
  by the companion; the plugin also keeps the max).
- **No other notes** during a refresh: the old "Full refresh: reloading everything…", "This page
  is refreshed · N covers checked", the 8-second progress toasts and the "Saved for offline" note go.
  A storage-limit stop shows in the badge in place of "Done", for 10 s.
- **E-ink**: only the badge's own rectangle is redrawn (`UIManager:setDirty(badge, "fast",
  region)`), at most every 3 s (the status poll) and only when the % changed.
- **Where**: BookOrbit Home, the catalog and the reader. In the reader it sits in the bottom-left
  margin, below the text area, and is passive (no tap): a tap there stays KOReader's own corner
  gesture. Nothing else is shown in a book: the badge is the one exception the user asked for, and
  it never takes focus (`reading-gate.md`).
- **The companion** shows the same % in its status area ("Full refresh · 37%").

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

Built in patch 0041 ([XTEINK-BUILD-NOTES](XTEINK-BUILD-NOTES.md) "One progress number"). The
plan's total turned out not to be fixed (the root and the sections add their lists as they land),
so the % keeps its highest value, as here. The walk now runs one request per idle loop, so the
catalog stays usable; Home's hold runs it in the refresh boot, where any press goes back to Home.
No details view: errors are in the log and the final "Done with N errors".

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

## Storage admission (W14)

The byte limit admits **net growth**, rather than rejecting work when the cache is
already full. A same-size or smaller row/image replacement is always admitted.
The writer measures touched book payload/search rows, list heads and membership rows
before and after a savepoint (including fixed row/index overhead for new rows). It
charges the positive delta against committed database bytes plus live cover/ETag
bytes. A batch also includes its earlier accepted deltas. The rollback journal is
still included in storage reporting, but its temporary copy of existing pages is
not new cached data and cannot block replacement. SQLite page allocation can round
committed usage above the payload estimate; subsequent growth uses that committed
size. This is a cache budget, not a promise of sufficient filesystem free space.

Lists and book data win over covers. The initial storage sweep likewise removes
eligible covers before expendable browsing entries. To admit growing data, evict eligible browsing
and saved-for-offline covers together, least recently **shown** first (filename breaks
ties). The plugin sends the bounded visible paths through STORAGE; the companion
alone touches their timestamps and lazily checks image sizes. Fetching/revalidating
a cover preserves its display timestamp. Covers for Continue reading, on-device
books (the plan and copies snapshot), and the current sleep batch are protected.
A rejected data save rolls back its savepoint, leaves its job pending, retains the
previous rows, and reports the storage limit only after eligible covers are exhausted.
A new/growing cover never displaces list/book data; existing cover replacements
continue even when no new cover fits. A limit stop never marks Full refresh complete. The plugin requests live storage
totals after the run, rather than adding downloaded replacement bytes to usage.

Browsing covers are JPEG quality 85, fitted without upscaling to the current grid
cell bounds (`cover_width`, `cover_height` in the plan, from the screen and effective
grid dimensions). Rechecks outside a run use the device screen's three-column bounds.
The companion resizes downloaded covers before admission and existing oversized
covers only when shown or individually rechecked, including a 304 or a missing ETag.
No sweep decodes thousands of images at once. Each shrink logs before/after bytes,
actual saving and a percentage estimate for similarly sized covers; the expected
68 KB to 15–25 KB is a device/content-dependent estimate, not a test assertion.
`orbit-sleep` retains separate full-screen covers. Orphan image ETags are removed
on storage enumeration. Inactive `stress.db`, its journal and `stress-writer.lua`
are removed on cache open or a storage check; the stress menu is available only with debug key logging.

`shared/fixtures/storage/cases.json` is the shared Android/Xteink W9 admission
contract: same-size/shrinking replacement, last-shown eviction across both cover
tiers, protection, exhaustion, new covers and unlimited storage. The JVM suite
consumes it now; W9 must wire it into the firmware tests when the firmware limit
lands. The plugin sends bounds and shown paths but owns no budget calculation.

## Stress test (before the migration)

The companion's `SQLITE_STRESS` broadcast writes nonstop for 2 minutes into
`orbit-cache/stress.db` (pages of 100 rows, each page one transaction that also bumps a
`gen` row, so a reader can check it saw a whole page). The plugin's "SQLite stress test" (BookSync
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

## Complete browse coverage (W15)

A Full refresh seeds lists before the reader opens them. The canonical inventory is
`shared/fixtures/catalog/sections.json`, packaged as `catalog_sections.json` with the Android
plugin. Xteink's pending W9 Full refresh must consume the same inventory; W15 changes no
Xteink code. `tools/test/test-catalog-coverage.py` compares the inventory with the pinned
server section index and plugin routing and controls. It fails closed when those source
files change, including a route the extractor does not yet recognize. Regenerate with
`--write` only after reviewing the newly browsable paths and updating the planner tests.

The pinned BookOrbit commit is `c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7`. Its browser exposes:

- Root rows: Continue reading, Recently added, All books and the five section indexes
  (`server/src/modules/koreader/koreader-catalog.service.ts:163-214`,
  `koreader-plugin/bookorbit.koplugin/bookorbit_catalog.lua:796-823`).
- Shelves: each library, collection and SmartScope; each author and series, including
  series selected by name (`bookorbit_catalog.lua:1111-1130`). The combined Shelves page
  reads the three underlying indexes (`bookorbit_catalog_lists.lua:267-298`).
- Home: Recently added, In progress, Pick back up, Finished, Discover, custom selector
  shelves, Want to read and Up next in series. Home's composed replies are saved separately
  from their linked book lists (`bookorbit_catalog_board.lua:994-1007`,
  `bookorbit_catalog_dashboard.lua:155-192`). **Finished in YEAR** is a label: opening it sends
  `readStatus=finished&sort=recently_read`, with no year predicate. W15 saves that actual list;
  it does not invent a year parameter (`bookorbit_catalog_board.lua:997`).
- On device (200 ids) and Not on device (up to 200 absent ids from the newest 500 books),
  including the scan's Recently added pages (`bookorbit_catalog.lua:1187-1249`).
- Sort/direction, reading-status, library, format and On device combinations in the book
  sheet; series sort/direction/status combinations, and author/series index sort and status
  facets (`bookorbit_catalog_lists.lua:518-538,584-639,658-727`). Legacy sort controls include
  Recently updated (`bookorbit_catalog_util.lua:35-42`). Layout, letter jumps, screen sizes,
  offsets and page numbers are windows of these identities, not extra lists. Typed searches
  remain online; there is no finite inventory of search strings.

The plugin passes the small inventory and its own entry-path templates to the companion.
After fresh indexes land, the companion expands the finite sort/filter combinations using
all library ids, device ids and section entries. Every list gets all pages, even when a
recheck's membership changes without its total changing. This exhaustive expansion can add
many identities and requests on a large library; book details and covers remain deduplicated.
It runs entirely in the companion. Both decorated (`buckets=1`) and legacy identities are
covered. The shared inventory also records the offered formats, sort keys and status facets
for W9, rather than leaving Xteink to reconstruct them independently.

Every regular/incremental refresh saves Home and composed shelves, seeds the indexes to find
new lists, and refreshes every page of dynamic identities (including Recently added, reading,
finished, Pick back up and their sort/filter variants), regardless of the book timestamp
probe. Existing static variants are rechecked when the normal membership probe detects a
change; missing identities are added. Rechecking page one always schedules the remaining
pages, because an unchanged total says nothing about membership or ordering. Explicit Refresh
also seeds newly browsable lists. A completed Full refresh logs `lists saved by kind: …`,
counting distinct successfully fetched identities in that run, grouped independently of ids.


### X4 refresh repair (0.11, maintainer request 2026-11-25)

Normal Home refresh keeps its bounded flow. Its saved source pages (100 rows) and
browser windows (20 rows, or the facet default) share an absolute-offset model;
Full refresh continues to use the ranked SD catalog. All-format source rows are
filtered locally before paging, including when the browser selects EPUB. Omitted
default sort/order and page-one spellings do not change the sequence. Every refreshed finite list
and later window opens offline. Search remains an explicit uncached request.

For the dedicated refresh screen, the maintainer now requests live counts in addition
to the existing percentage: lists completed / total discovered, books saved, covers
available. This supersedes the earlier Xteink “no N/M” rule on that screen. Counts
update at most once a second with a partial e-ink refresh. A book on screen still
receives no refresh popup or progress repaint. The Home tile says BookSync and
“Synced just now” for the first minute after a successful completion, using the
finish time after cover/SD work. A failed refresh does not advance the stamp.

The redacted .407 report records internal free heap falling from 160,732 bytes
before a cache miss to 33,952 bytes after networking and several pages, then 6,676
bytes before a PHY allocation abort; PSRAM still had 7,565,528 bytes free. The
page vectors were bounded (60 rows reserved, 8,640 bytes plus 1,363 bytes of text),
and the 33,952-to-6,676 drop occurred after leaving the catalog. This supports
network pressure plus a later allocation/fragmentation spike, not proof of a
per-page leak. The first missed page took about 14 seconds including connection;
the supplied .224-era fragment has no comparable browse-page timing.

The repair explicitly places JSON, numeric indexes, image scratch buffers and
small tailnet TLS nodes in PSRAM on X4. SD font caches are released before joining.
Wi-Fi init needs 61,440 internal bytes and a 24,576-byte block; PHY start and new
catalog work need 24,576 bytes and a 4,096-byte block. Radio ownership preserves its originally-off state across the miss-to-request
handoff, so it is restored off after the three-second grace rather than being
kept for the 120-second idle timeout. An idle radio under the catalog floor is
also released, including its catalog TLS session.
Existing lent sleep-sync sessions keep their separate tested budget. The final
device scan runs before that lent session closes. Normal Home top-ups own one
sync session and lend it to catalog/cover requests, then close it before releasing
the radio, instead of handshaking for each metadata request.

Host regressions: saved 100-row pages are projected into 20-, 31- and 60-row
windows, including mixed-format and smart-scope cases, with no network reader.
The ranked catalog also tests 245 synthetic books, 294 offline windows across all seven sort
families, both 100-row boundaries and the short final page; 56,998-byte tracked
JSON/index peak, zero live arena bytes after each window. The emulator also asserts
that offline paging stays above the Wi-Fi reserve and does not retain internal
heap. These are host/emulator measurements, not a post-fix physical-device reading.
X3 retains its online catalog and has no bulk catalog/PSRAM worker; its Home stamp
and cover allocation fallback still follow the same completion and ownership rules.

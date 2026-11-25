# Background work off KOReader's UI thread (Android)

Status: building (step 1 merged; step 2, the companion as the worker, in this change).
Platforms: KOReader-Android.

The W6/rc.8 correction in [sqlite-cache](sqlite-cache.md#cache-lifetime-and-incremental-refresh-rc8-feedback-w6)
supersedes the older scheduling, indicator wording and batch sizes below: Full refresh is manual
only, its badge belongs only to a user-started run, the cache lives indefinitely, and opportunistic
incremental probes are silent. Full-refresh notices (including BookOrbit loading pills and direct
InfoMessages) go to the log. Companion refresh work emits status files and logs, not Android
notifications or toasts. Its visible status is “Full refresh · 37%” only for a manual run.

## Why

KOReader runs on a single Lua thread: input, drawing and every plugin callback share it. Android
shows "KOReader isn't responding" when that thread doesn't take an input event within 5 s.

Test build 0.11.3-0.test.39 on the M8C (11-23, 22:07 PT) did exactly that, and the menus became
unusable. Logcat:

- 22:07:38.9: `mirror: resuming (network up), 5262 left`. The offline mirror's queue was 419 at
  22:01 and grew as list pages landed: 2765 at 22:06:37, 5635 at 22:07:17, and still growing
  (9520 at 22:11:56).
- 22:07:41.6 to 22:07:46.5: no UI-thread line for 4.9 s. Only the cover child (pid 11693) logged.
- 22:07:45.6: `Input dispatching timed out ... Waited 5001ms for FocusEvent` (the ANR).
- 22:07:46.46: the UI thread comes back with a cache save and `mirror: 475/5736 saved`.
- Throughout the run, saving one item took between about 1 and 12 s (`475/5736` at 22:07:46,
  `491/5736` at 22:10:23). Each request took well under a second: the covers in the same window
  took about 400 ms each.

The cause (v0.11.1 to 0.11.3 `ko/mirror.lua`, `ko/cache.lua`): the mirror kept its queue, its
"seen" set and one index entry per saved page and detail **in the cache's index**. The UI thread
re-encoded the whole index (`Cache.encode`: recursive, with sorted keys) and wrote it after every
saved item (`OC.saveIndex`, coalesced to one save per 3 s). It also decoded each reply, compared it
with the saved copy (two more encodes), wrote it, and ran the cache's LRU over every entry. All of
that work grew with the library. With about 5000 books in the queue (3.4 MB of index), each save
took seconds on the M8C. A synthetic index of that size takes 0.13 s to encode on a laptop.

The growth from 419 to 5262 and beyond is what the mirror is designed to do. Every list it saves
names books whose details it then saves, and every author and series entry is its own list. The
total therefore grows while list pages are still arriving. There is no re-seed and no duplicate:
jobs are de-duplicated by path. The order made it look like a leak, though: details were queued
between list pages, so the total kept growing until the very end. Since step 1, lists come first,
and the total stops growing once they are all saved (test: "lists are saved before details").

## The rule

KOReader's UI thread only does what needs KOReader's state at that moment: the open document,
applying a result to a view, drawing. Everything else runs in a worker: network, JSON or Lua
parsing of replies, comparing, file writes and directory scans. Even where the result has to land
in KOReader, only the apply step stays on the UI thread, and it handles a few fields, never a
whole reply.

The worker is the BookSync Companion (a separate process with real threads). A forked child of
KOReader (`Background.run`, koreader-base `ffi/util` `runInSubProcess`) is only for work the
companion can't do, because it needs KOReader's own code (the BookOrbit plugin's reads).

## Required companion (maintainer, 11-23)

The companion is required, and the plugin and the companion always ship together (one release,
one version).

- **No fallback in the plugin.** Once the companion owns a job, the plugin's network, parse and
  disk path for that job is deleted, including step 1's child-process mirror and check. There is
  no "no companion" or "old companion" path.
- **No version-skew handling.** One check (`Companion.workerProblem`, `ko/companion.lua`): the
  companion must be installed and report the plugin's own version in its status file. Otherwise
  the plugin shows "BookSync Companion needed to save BookOrbit for offline" or "Update BookSync
  Companion to <version> …" (the offline line in the menu, and a note when Full refresh is pressed)
  and does nothing heavy: no mirror run, no background check. Reads keep coming from what is saved.
- Test: "companion: the cache worker needs the companion of the plugin's own version".

## Step 1 (#32, merged): the mirror and the cache's own work in children

Step 2 replaced its mirror worker and its checks with the companion's, and deleted them from the
plugin. Its index saves and child stores stay.

- **Mirror worker.** A Full refresh, Refresh's recheck, the cover pass and a resumed run all run in
  a child. One run handles at most `RUN_JOBS` (400) jobs or `RUN_S` (120 s), then the next run
  resumes. The child owns `<settings>/orbit-cache/mirror/`:
  - `<hash>.lua`: the saved pages and details, in the cache's entry format. `OC.get` falls back to
    these files, so offline reads are unchanged.
  - `state.lua`: the queue (seed, lists, details, covers), the lists, sizes and the "seen" set.
    Only the worker reads or writes it.
  - `status.lua`: a few numbers (done, total, left, covers, saved at, the storage-limit note,
    bytes). This is all the UI thread reads, for the menu line and the progress note.
  - `cover_keep.lua`: the covers "Save every cover for offline" keeps, for the plugin's pruner.
  - `stop`: the UI thread's request to stop (network gone, a new Full refresh).

  The UI thread starts a run, holds Wi-Fi, polls `status.lua` every 5 s, and applies the run's
  summary: thumbnails to redraw, lists changed on screen, storage bytes. Nothing of the mirror is
  in the index any more.
- **Migration.** v0.11.2's mirror in the index (`idx.mirror`, entries marked `mirror`) moves on the
  first run. Its files are renamed into `mirror/` and its queue continues where it was. The
  index entries are dropped once the child confirms the move.
- **Index saves** are encoded and written by a child, one at a time and in order.
- **Background checks** (`cache: ... checking (open)`): the child asks the server, compares the
  reply with the saved copy and saves a changed reply itself. It returns only
  `{ changed, bytes, ids }`. The UI thread updates the index entry and redraws if the view is on
  screen.
- **Child stores**: a child's `stored` event carries the entry's size and ids, so the UI thread no
  longer reads and decodes the body back.

Guards (`test_flows.lua`, "v0.11.3: the mirror off the UI thread"):
- During a Full refresh of a 450-book library, no mirror request runs on the UI thread, nothing
  over 8 KB is encoded or decoded there, and the index stays under 8 KB.
- Lists are saved before details, and the total holds still after the lists.
- A background check of a 400-book page never puts the body on the UI thread.
- Index saves encode nothing on the UI thread.
- The v0.11.2 migration keeps its place.

## Step 2 (this change): the companion runs the mirror and the checks

- **The run.** `CacheWorker.kt` (plain JVM, unit-tested) on one worker thread (`Worker.kt`). The
  plugin prepares request templates in short scheduled steps and sends `MIRROR` with the plan
  and login in the caller-checked extras. The worker writes `mirror/plan.lua` (no login). The companion saves the pages, details and covers into `mirror/` (same
  entry format and file names, temp file then rename), its queue in `mirror/worker-state.lua`,
  and writes `status.lua` every 5 s and `summary.lua` at the end. The plugin polls `status.lua`
  every 3 s and applies the summary. Nothing of the run (request, reply, compare, write, queue)
  is in KOReader. Runs have no job budget: one run goes until it is done, stopped or offline.
- **Checks.** `cache: … checking (open)` sends `CHECK` (key, path, mode, login). The companion asks,
  compares with what the plugin would serve (its entry, else the mirror's pages, as `OC.lookup`),
  saves a changed reply under the key and writes a `checked` event. The plugin drains events every
  second while checks are out and applies `{ changed, bytes, ids }` or `{ unchanged }`.
- **The same rules on both sides.** Keys, file names (LuaJIT's FNV-1a, double multiply and all),
  list identities and pages, cover names and the entry format are checked against
  `shared/fixtures/cache/worker.json` by both `test_logic.lua` and `CacheWorkerTest`. The plan
  carries the plugin's own request templates (`paramsForEntry`, `effectiveOrder`,
  `listDecorateBookQuery` with a sentinel id), so BookOrbit's query rules stay in the plugin.
- **Credentials.** Server URL, username and key go only in the caller-checked call to the
  companion (`Companion.send`, `Jni.call`), and only when the companion is signed by BookSync's
  release certificate. They are held in memory, used only as `x-auth-user`/`x-auth-key` on
  requests to that server (a redirect is followed only to the same scheme, host and port), and
  never written to a file, the status or a log (`Companion.send` logs only the reason; tests: the
  key is in no file under `orbit-cache/` and not in the plugin's log). Only the pinned KOReader
  can call (docs/design/security.md).
- **The indicator (rc.1 report).** The Full refresh indicator now follows the run, not a step:
  it is shown at every poll with an 8 s timeout (longer than the 3 s poll), reads "Full refresh ·
  saving 512 of 8,551 for offline", and goes when the run finishes, pauses or fails. Before, it
  was a 2 s note every 10 s, and each 400-job child run ended it. Test: "the Full refresh
  indicator stays up for the whole companion run".
- **Speed (rc.1: about 5 jobs a second, 10,325 queued, 35 min or more).** The companion sends 4
  requests at a time over kept-alive connections (`PARALLEL`, fetched 16 ahead and landed in
  queue order) and has no per-run budget. Each run logs `mirror: run <id> (<why>): N jobs, D books'
  details, R requests in T s (X requests/s, 4 at a time)`. Unit test: 500 books at 20 ms a
  request take about 3 s, against 10 s one at a time. Options weighed:
  - Batched details: the server has no batch for details. `/books?ids=` (at most 200,
    `koreader-catalog-query.dto.ts:114`) returns list items, not the detail body a book's page
    shows offline. `/manifest` (at most 200 a page, `:175`) returns the file data copies need, not
    the detail body either.
  - Covers: still only the books on the reader and their neighbours, unless "Save every cover"
    is on.
  - Writes: one file per entry, because the plugin reads entries by key. The queue state is
    written every 30 s, not per item.

## Audit: background work in KOReader's process

"UI" means KOReader's UI thread. "Child" means a forked child of KOReader. "Companion" means the
BookSync Companion's worker thread. Rule: an item stays in KOReader only if it needs KOReader's state
at that moment, and even then its fetch side moves.

| Work | Now | Decision | Why |
|---|---|---|---|
| Offline mirror: lists, details, covers, Refresh recheck, the every-cover pass | companion (step 2) | **moved** | the ANR |
| Background cache checks, `cache: ... checking (open)` | companion asks, compares and saves (step 2); the UI thread applies a few fields and redraws | **moved**; apply stays | the redraw needs the view |
| Cache index save | child (step 1) | **stays** (step 3 looked): the index is the plugin's own state in memory, so handing it to the companion means encoding it first, on the UI thread or in this same child. A journal of changes would touch every place the index changes to save one fork per 3 s at most. The UI thread encodes nothing (guard in `test_flows.lua`) | small since step 1 (under 8 KB) |
| Child stores (`stored` events) | metadata only on the UI thread (step 1) | stays | the store is the plugin's own read, inside its child |
| Storage limit: count and LRU (`OC.storageEnforce`) | companion (step 3): `STORAGE`; it walks the index and the cover folder, deletes covers and names the entries to drop; a mirror run counts its own base | **moved**; the UI thread drops the named index entries | about 600 files today, thousands with "Save every cover" |
| Copies' detail lookup and replacement (`Copies.details`, `Copies.tick`) | companion (step 3): `COPIES`; it reads the saved details, compares hashes and checks the files | **moved**; the replacement stays the plugin's own Download path (BookOrbit's delivery, forked) and its sidecar, statistics and state carry | per on-device book, at Home and network up |
| Sleep screen pool: Up next, Leave out member lists and tag details, cover prefetch | companion (step 3): `SLEEP_REFRESH`, `SleepPoolBuilder` on the worker thread; the pickers' lists too (`scopes_only`) | **moved**; the companion redraws its picture itself | already off the UI thread (log 22:07:38.98 to :39.82, 0.8 s, UI free) |
| Sleep screen current cover (`Sleep.writeCurrent`) | UI, once per book open | **stays** | needs the open document (`getCoverImage`) |
| Sleep screen pickers: scopes, collections and Leave out's tags | companion: `SLEEP_REFRESH` with `scopes_only` writes `scopes.json` and `tags.json` (it counts the tags in the saved details, up to 2000); the picker opens from those files | **moved** | the tag picker read up to 400 saved details on the UI thread |
| Reading fonts install | companion (`FontInstaller.kt`); the plugin has no trigger | stays | already outside KOReader |
| Rotation patch (`1-orbit-start-rotation.lua`) | UI, at start | stays | needs the display; a few calls, no I/O |
| Plugin self-update check and download (`Updater.check`) | companion (step 3): the menu's check sends `UPDATE`; the companion installs itself, then the plugin of its release | **moved**; the plugin's download, unpack and swap are deleted | the restart for a newer file on disk stays in KOReader (`maybeRestart`) |
| Companion status (`Companion.status`, loopback GET, 1 s timeout) | UI at start, resume and menu | stays | loopback answers in ms; the result drives the UI |
| Outbox drain, progress, annotations, stats sync | BookOrbit plugin; forked when Trapper-wrapped (`bookorbit_api.lua:325-372`), otherwise blocking | not redirected now (see below) | upstream code; no measured stall |
| Home dashboard, discover, search, series reads | BookOrbit plugin, forked (`runInSubprocess`); BookSync's cache answers inside the child | stays | upstream code; its result feeds the plugin's own view |
| Cover and thumbnail downloads | BookOrbit plugin, forked (`bookorbit_catalog_thumbnails.lua:388, :571`) with BookSync's ETag download inside | stays | already off the UI thread; resizing is the plugin's, on draw |
| Full refresh cover recheck (`OC.recheckCovers`) | companion: `RECHECK` with the covers on screen; it asks If-None-Match and answers `covers_rechecked`; the view redraws | **moved**; its forked child is gone | a child per Full refresh |
| Index load at start (`OC.index`) | UI, once per start | stays | small since step 1 |

**BookOrbit's own sync** runs inside KOReader and BookSync doesn't patch upstream. BookSync already
wraps `BookOrbitApi.request` (`ko/cache.lua` `OC.install`). That wrapper could send a non-catalog
write through a child even when the plugin calls it outside a Trapper coroutine. It is not worth
doing until a stall is measured there: the 11-23 log shows none, and a write's result feeds the
plugin's own state (the sync coordinator's queue), which would then have to be applied
asynchronously.

## Self-grill

1. Child or companion first? Child first. It needed no new protocol, and it removes the UI-thread
   work at once. It is also the fallback the companion design needs anyway. Two-way door.
2. Mirror entries in the index or beside it? Beside it. Anything in the index is re-encoded on
   every save. Two-way door: the files stay in the cache's format.
3. Page sizes without the lists map? The UI thread probes page 1 in 100, 50 and 25: at most three
   `io.open` calls on a list miss.
4. Memo for mirror entries? None. The worker rewrites them behind the UI thread's back, and a stale
   memo hid a Refresh's change in testing.
5. (Step 1, superseded by step 2: the companion runs one run to the end.) One long child or many short ones? Short runs, at most 400 jobs or 120 s each. A killed or timed-out
   run loses at most 30 s of progress (`STATE_EVERY_S`), and a new Full refresh or a lost network
   stops it within one job.
6. Plan in a file or in the broadcast? A file: the templates and sections are a few KB, and a
   broadcast extra has a size limit. The login goes in the broadcast only.
7. The lists the plugin has read (up to `Cache.MAX_ENTRIES`): in the plan or from the index? The
   companion reads `index.lua` itself, so nothing on the UI thread grows with them. A pending index
   save is waited for (at most 15 s) before a run.
8. v0.11.2's mirror in the index? A Full refresh that also re-saves its lists; its files move into
   `mirror/`. Its old queue isn't carried over (two-way door: the Full refresh saves the same).
9. How many requests at once? Four: enough for roughly four times the rate on a home server over
   Tailscale, few enough to stay polite. A constant (`PARALLEL`), one line to change.

## W27: bounded startup maintenance

The rc.12 startup callback duplicated the worker's orphan ETag cleanup and walked thousands
of cover files on KOReader's main loop. Startup now only asks `STORAGE`; totals come from its
answer. Upstream cover maintenance is redirected to the same storage worker. The only Lua
cover-directory iterator is in `ko/cover_child.lua`, guarded by child state/PID before entry.
Hash sidecar copies also run on the companion worker.

The companion's durable event spool is private: `EventMailbox` publishes a bounded batch at a
fixed filename, with acknowledgement and replay after restart. The plugin reads at most 64 KiB,
never lists the spool, and ignores duplicate ids. Subprocess metadata travels in its result.
Home's 364-day calendar and daily statistics query run on the worker; changed tiles repaint one
per scheduled callback. Mirror template preparation yields between sections; the companion parses
and writes the plan. Stall diagnostics remain enabled at 50 ms and exclude deliberate coroutine
waits. Host guards exercise startup and reading with 7,000 cover files and an eight-file read budget;
real-device startup and Home rendering still need measurement before release.

Upstream basis for these worker moves: BookOrbit `c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7`,
`koreader-plugin/bookorbit.koplugin/bookorbit_board_data.lua:165` (calendar merge) and
`:628` (board assembly), and `bookorbit_catalog_thumbnails.lua:147` (legacy cleanup),
`:480` (cover pruning). KOReader `9192014d8bd82a91dc1012473be0f238dedfdb54`,
`datastorage.lua:75` and `frontend/docsettings.lua:120` define the hash sidecar location.

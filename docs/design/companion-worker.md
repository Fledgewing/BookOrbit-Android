# Background work off KOReader's UI thread (Android)

Status: building (step 1 merged with this doc). Platforms: KOReader-Android.

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

The worker is a forked child of KOReader (`Background.run`, koreader-base `ffi/util`
`runInSubProcess`) or the Orbit Companion (a separate process with real threads). Both write the
same files.

## Step 1 (this change): the mirror and the cache's own work in children

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

## Audit: background work in KOReader's process

"UI" means it runs on KOReader's UI thread today. "Child" means a forked child already does the
network part. "Move" means the fetch, parse and write side goes to the worker; the apply step stays.

| Work | Today (after step 1) | Decision | Why |
|---|---|---|---|
| Offline mirror: lists, details, covers, Refresh recheck | child (step 1) | **moved**; to the companion in step 2 | the ANR |
| Cache index save | child (step 1) | **moved** | grew with the library |
| Background cache checks, `cache: ... checking (open)` | child requests, compares and saves (step 1); the UI thread updates the index entry and redraws | **moved**; apply stays | the redraw needs the view |
| Child stores (`stored` events) | metadata only on the UI thread (step 1) | **moved** | |
| Storage limit: count and LRU (`OC.storageEnforce`) | UI: index walk and cover-folder `lfs` scan, at start and when over the limit | **move** (step 3): a child counts and deletes; the UI thread drops index entries | about 600 files today, thousands with "Save every cover" |
| Copies' detail lookup (`Copies.details`) | UI: walks the index and decodes the wanted books' details | **move** (step 3) with the copy replacement itself | per on-device book, at Home and network up |
| Sleep screen pool: Up next, Leave out member lists and tag details, cover prefetch | child (`Sleep.build`) | stays in a child; to the companion in step 2 | already off the UI thread (log 22:07:38.98 to :39.82, 0.8 s, UI free) |
| Sleep screen current cover (`Sleep.writeCurrent`) | UI, once per book open | **stays** | needs the open document (`getCoverImage`) |
| Sleep screen scope and collection picker | child; falls back to a cached read | stays | user action, small |
| Reading fonts install | companion (`FontInstaller.kt`); the plugin has no trigger | stays | already outside KOReader |
| Rotation patch (`1-orbit-start-rotation.lua`) | UI, at start | stays | needs the display; a few calls, no I/O |
| Plugin self-update check and download (`Updater.check`) | child | stays in a child | apply (install, restart) needs KOReader |
| Companion status (`Companion.status`, loopback GET, 1 s timeout) | UI at start, resume and menu | stays | loopback answers in ms; the result drives the UI |
| Outbox drain, progress, annotations, stats sync | BookOrbit plugin; forked when Trapper-wrapped (`bookorbit_api.lua:325-372`), otherwise blocking | **not redirected now** (see below) | upstream code; no measured stall |
| Home dashboard, discover, search, series reads | BookOrbit plugin, forked (`runInSubprocess`); Orbit's cache answers inside the child | stays; the decode of the plugin's result is the plugin's | upstream code |
| Cover and thumbnail downloads | BookOrbit plugin, forked (`bookorbit_catalog_thumbnails.lua:388, :571`) with Orbit's ETag download inside | stays | already off the UI thread; resizing is the plugin's, on draw |
| Index load at start (`OC.index`) | UI, once per start | stays | small since step 1; the one start after the upgrade still reads the old index once |

**BookOrbit's own sync** runs inside KOReader and Orbify doesn't patch upstream. Orbify already
wraps `BookOrbitApi.request` (`ko/cache.lua` `OC.install`). That wrapper could send a non-catalog
write through a child even when the plugin calls it outside a Trapper coroutine. It is not worth
doing until a stall is measured there: the 11-23 log shows none, and a write's result feeds the
plugin's own state (the sync coordinator's queue), which would then have to be applied
asynchronously.

## Step 2: the companion as the worker (next)

The companion runs the mirror (and the sleep pool) on a worker thread, writing the same
`mirror/` files atomically (temp file, then rename). The plugin keeps step 1's child only as the
fallback when the companion is missing or too old (`caps` without `mirror`).

- **Requests.** The plugin hands the companion a plan, not code. The plan has the seed paths, the
  section index paths, and each section's entry template (built from the plugin's own
  `paramsForEntry`, `effectiveOrder`, `listDecorateBookQuery` with a sentinel id). It also has the
  detail path template and the page size. So BookOrbit's query rules stay where they are.
- **Credentials.** The server URL, username and key go in an explicit broadcast to the companion's
  package (`setPackage`, as every other action, docs `android/docs/INTERFACE.md`). Other apps
  can't read an explicit broadcast. The key is held in memory and in the companion's private
  storage, never in `koreader/settings`, never in a log or `/status`.
- **Notices.** The companion writes `status.lua` and a `changed` list. The plugin polls them while
  a run is on, as in step 1. A launcher intent would bring KOReader to the front, so it isn't
  used.
- **Rules kept.** Same triggers: network up, wake, Home, Refresh, Full refresh, TTL. Same storage
  limit, same Wi-Fi hold: the companion refuses an automatic Wi-Fi off while it runs. Same
  reading gate: nothing shows.

## Self-grill

1. Child or companion first? Child first. It needed no new protocol, and it removes the UI-thread
   work at once. It is also the fallback the companion design needs anyway. Two-way door.
2. Mirror entries in the index or beside it? Beside it. Anything in the index is re-encoded on
   every save. Two-way door: the files stay in the cache's format.
3. Page sizes without the lists map? The UI thread probes page 1 in 100, 50 and 25: at most three
   `io.open` calls on a list miss.
4. Memo for mirror entries? None. The worker rewrites them behind the UI thread's back, and a stale
   memo hid a Refresh's change in testing.
5. One long child or many short ones? Short runs, at most 400 jobs or 120 s each. A killed or timed-out
   run loses at most 30 s of progress (`STATE_EVERY_S`), and a new Full refresh or a lost network
   stops it within one job.

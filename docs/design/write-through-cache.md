# Write-through cache in front of BookOrbit

Status: approved to design and build (2026-11-22); Android ships it in v0.10.0. Xteink: ROADMAP
item 4 ("Local-first Xteink catalog") is this cache, built by the Xteink builder from this page.

One pattern on both platforms, so offline behaviour, freshness and "why is this stale" live in
one place: every catalog read is answered from a local copy at once and checked against the
server in the background; every write goes straight to the server and, once it succeeds,
corrects the copies it makes stale. This reader's own unsent state stays on top (local-first's
overlay, unchanged).

Citations are to the pins in `tools/upstreams.lock` (plugin = BookOrbit
`koreader-plugin/bookorbit.koplugin` at v3.9.0, plugin 2.3.0; X = CrossInk-Bookorbit 1.6).

## Shared concept

Semantics are fixed by `shared/fixtures/cache/cases.json` (keys, reads, writes, covers, both refresh
modes), which both platforms' tests read.

| Part | Rule |
|---|---|
| Cached reads | `GET` of the catalog: root, dashboard, sections, books lists, book detail, manifest (paths under `/koreader/plugin/catalog/`, firmware `/plugin/catalog/`). Nothing else (auth, version, progress, sync, downloads). |
| Key | account + server + method + path + query, normalised: server URL lower-case without trailing `/`, query parameters sorted, empty values dropped. Account = the user name the request authenticates as. Entries of another account or server are never served; signing out or changing server/account drops them. |
| Read | Entry present: return it at once (no network), then revalidate in the background unless it was validated in the last 60 s. Entry missing: go to the server (as today) and store a `2xx` reply. Errors are never stored. |
| Revalidate | One background request per key at a time. Same reply (by canonical form, after normalising: `generatedAt` is dropped, it is a fresh clock value per request; Home's `discover` row is random per request and keeps the saved one except on a Full refresh; see [server contract](../server-contract.md#catalog-replies-carry-no-version)): stamp `validated_at`, nothing else. Different: replace it and tell the view showing that key to redraw (see the platform hooks). Failure: keep the entry; the view's stamp says "Not updated". |
| Writes | Every non-`GET` passes through untouched. On `2xx`, the write's effects are applied to the cache: `read-status` and `rating` on book *id* patch `readStatus`/`rating` of that book wherever a cached body lists it (detail, Home lists, series members, list pages) and mark Home stale; progress and book-states mark Home stale. Stale = revalidate on the next read (immediately if it is on screen). A failed write changes nothing. |
| Size | Total cap (Android 64 MB since v0.11.1, logged at each Full refresh; X4 2 MB on SD) and entry cap (20000 / 200). Least recently used goes first; the Home body and the open book's detail are never evicted by a list page. |
| Overlay | Unchanged: local-first's rules (device wins while newer or unsent; a local finish leaves Continue reading and counts toward the goal at once; design D4) are applied to what the cache returns, never written into it. |
| Offline | Reads come from the cache, with the "Offline, saved …" stamp. Writes made offline use the existing queues (the plugin's outbox, Orbit's finish queue, the firmware's sync queue); the cache only learns of them when they succeed. |
| Covers | Part of the cache: a disk file per book id + cover version, the version being the book's `updatedAt` as the server lists it (the plugin already names its files this way: `bookorbit_catalog_thumbnails.lua:58-85` coverToken/memoKey, files in `cache/bookorbit`, pruned at 600). A cover is downloaded only when it is missing, failed earlier, or listed with a version other than the one on disk; a cover whose version is unchanged is never downloaded again. A cover changed on the server without a new version is what Full refresh is for. Reading never changes the version (see "Cover version" below). |

## Cover version

`updatedAt` in a catalog book is the `books.updated_at` column (server
`koreader-catalog.service.ts:964`, :1204, :1297), bumped on every update of that row
(`db/schema/books.ts:44-47`, `$onUpdateFn`). Reading never writes that row:

- progress goes to the KOReader progress tables (`db/schema/koreader.ts`);
- read status goes to `user-book-status` (`setManual`, called from `koreader-catalog.service.ts:520`);
- a rating goes to `user_book_ratings` and `reading_attempts` (`book.repository.ts:2494-2510`);
- none of these is an `update(books)`.

What does bump it: metadata edits (`book.repository.ts:2606`, :2658), community-rating refreshes from
metadata fetches (:2642), a new primary file (:1839), cover changes (`book-cover-store.repository.ts:303`),
series membership, scans, moves, renames and uploads. Each of these costs one cover download for that
book. That is rare, and is the price of a version the listing carries.

The thumbnail itself has a cover-only version: `ETag` = the cover file's mtime, with
`If-None-Match` answered by `304` (`koreader-catalog.service.ts:752-769`). Both platforms use it:

- Every cover download stores the reply's ETag next to the file (Android `<cover>.jpg.etag`, which
  the plugin's pruner ignores, `bookorbit_catalog_thumbnails.lua:526`; Xteink in its index).
- When `updatedAt` moved and an older file of that book has an ETag, the request carries
  `If-None-Match`. A `304` keeps the file and renames it (and its ETag) to the new version's name,
  so the versioned path finds it. A `200` replaces it through the same temp-file-then-rename and
  size cap (4 MB) as before, and the old file goes.
- A metadata-only edit therefore costs one 304, not a cover.
- Android: Orbit wraps the plugin's `downloadCatalogThumbnail` (`bookorbit_api.lua:747`) with its own
  conditional GET that reuses the client's server, auth headers and the worker's temp path and size
  cap. The plugin's downloader neither sends nor keeps ETags (`bookorbit_api.lua:455-527`). Behind a
  proxy or on a redirect, it falls back to the plugin's download (no ETag).

## Offline mirror (v0.11.1)

A Full refresh ends by saving everything reachable from Home without typing, so the reader can
browse offline:
- every page of Home's sections and of every list they link to;
- the section indexes (collections, smart scopes, libraries, series, authors) and each entry's
  book list;
- On device;
- details of the books on the reader, Continue reading, Up next, and the next book in each
  series;
- their covers, conditional by ETag.

Search stays online; offline it says "Search needs a connection".

- **Pages.** Lists are saved as 100-item pages (the server's page maximum). Any page or offset the
  plugin asks for offline is cut from them (`Cache.slice`), so paging never asks to connect.
- **Pacing.** One request at a time, a "Full refresh · saving for offline N/M" note every 10 s,
  and a queue kept on disk that resumes after a restart. Wi-Fi is held only while it runs, and it
  stops when the network goes.
- **Refresh.** A normal Refresh rechecks **every saved page** of a list, never only the first one.
  When a list's total changes, the list is paged again (`Cache.repage`): a series that gains a
  21st book shows it after Refresh.
- **When.** A Full refresh can be started by hand (hold ⟳, or the menu). It also starts by itself
  when the mirror is older than its TTL (default 7 days; Orbit menu › Automatic Full refresh, or
  off) or when the library version changes (the sweep reply's `libraryVersion`).
- **Shown as** "Saved for offline · <day time>" in the Orbit menu. The log reports lists, pages,
  requests and MB at the end of each run.

The first paint of Home comes from the cache with the local overlay already applied: Resume
shows at once, never Download then Resume.

## Refresh and Full refresh

The same two modes and words on both platforms.

| | Refresh | Full refresh |
|---|---|---|
| What starts it | Tap ⟳; every automatic background check. Xteink: Confirm on ⟳ (X4 Pro: tap). | Hold ⟳ (a short "Full refresh…" note); "Full refresh" in the Orbit menu / Xteink settings. Xteink: long-press Confirm on ⟳ (X4 Pro: hold). |
| Data | Revalidate this view's entries (and Home's when on Home), skipping the 60 s window, and merge what changed. | Fetch this view and Home's sections from the server, ignoring the cache, and replace those entries. |
| Covers | Fetch only missing, failed or re-versioned covers (a re-versioned one with an ETag asks `If-None-Match`). | Also check every visible cover file: a missing, empty or unreadable file is removed and fetched again. A good file with an ETag is asked `If-None-Match`: a 304 keeps it, a 200 replaces it (this catches a cover changed without a new version). Never a blind re-download. |
| Evicts | Nothing. | Only the entries and cover files it replaces. |
| Overlay | Stays on top. | Stays on top: unsent local state is never lost to a Full refresh. |

BookOrbit's own refresh (plugin `refreshCurrent`, `bookorbit_catalog.lua:475-490`) deletes every
cover on screen (`evictCachedCovers`, `bookorbit_catalog_thumbnails.lua:237`) and cancels the
cover jobs. Neither of our modes goes through that deletion.

## Android (Orbit plugin)

- **Choke point:** `BookOrbitApi:request(method, path, body, headers)` (plugin `bookorbit_api.lua:372-383`)
  is every JSON call; it runs `requestBlocking` (:261) inline or in a forked child
  (`runInSubprocess`, :336). Orbit wraps it on the API class (`wrap`, feature key `cache`).
- **Child processes:** the catalog runs most requests inside a forked child (`fetch`,
  `bookorbit_catalog.lua:881`), so the wrapper runs there. A child never calls JNI or the UI:
  `NetworkMgr:isConnected` is JNI on Android (`device/android/device.lua:333`), and a child that
  calls it dies, which the plugin reports as `subprocess_no_result` (v0.10.0 on the M8C). The parent
  records its connectivity just before forking; the child reads that, and reports what it read,
  stored, wants checked or missed as event files the parent applies when the child returns.
- **Offline:** the catalog's `runConnected` (`bookorbit_catalog.lua:924`) would ask for Wi-Fi first.
  Offline, Orbit runs the view's load from the cache instead. A page that isn't saved answers
  "cancelled" (the plugin's quiet path) and then asks "Connect and load more", which runs the load
  connected; a write or download in that load just connects, as before.
- **Synchronous answer:** the wrapper returns the cached body directly, so the catalog code that
  called it (`fetch`, `loadBooks`, `dashboardRootFetch`, `loadBookDetail`, …) carries on as if
  the server answered, with no spinner and no network.
- **Revalidation:** a KOReader subprocess (`ffi/util` `runInSubProcess`, as Orbit's update check
  does, `ko/background.lua`) runs `requestBlocking` and pipes the reply back; the UI polls it.
  A different reply updates the entry, then calls the redraw hook for the view showing that key:
  - Home: local-first's quiet path (`ko/localfirst.lua` `LF.quietSwitch`): header stamp and the
    tiles whose content changed, nothing else.
  - Lists and book detail: the catalog's own reload (`refreshCurrent`, `bookorbit_catalog.lua:475`)
    with its cover eviction turned off (Orbit wraps `evictCachedCovers`); it reads the
    now-current entry from the cache, so it is one repaint with no request.
- **Covers:** the plugin's queue already skips a cover whose versioned file exists
  (`queueThumbnails`, `bookorbit_catalog_thumbnails.lua:257`). Orbit keeps the jobs alive across
  its quiet Home repaint (the stock `switchTo` cancels them, `bookorbit_catalog.lua:848`), queues
  the covers of books a refresh brings in, lets a cover that lands redraw its tile, and clears
  the session's failed-cover memo on Refresh. Full refresh checks the visible files (size, JPEG
  or PNG header) and removes the bad ones before queueing.
- **⟳:** tap = Refresh, hold = Full refresh, on Home and on lists; the Orbit menu has "Full refresh".
- **What it replaces:** local-first's Home-only body handling (the `dashboardRootFetch` tag and
  `fetchedAt` stamps) moves onto the cache: freshness stamps read `validated_at` per key, lists
  included. The overlay, tile diff, ⟳ and stamp UI stay.
- **Storage:** `<settings>/orbit-cache/` (one JSON file per entry, named by a hash of its key)
  plus `index.lua` (key → file, bytes, fetched_at, validated_at, used_at). Disposable: deleted
  on a version mismatch or if unreadable.
- **Off-switch:** Orbit menu "Use the offline cache" (on). Off, or a plugin without the hooks
  (compat probe): requests go straight through, as before.

## Xteink (CrossInk-Tailnet overlay)

X4 Pro and X4 only (`CROSSINK_TAILNET_ORBIFY_CACHE`, overlay patch 0029 and on). The X3 keeps
today's catalog and none of the cache code. Citations are to CrossInk 2.0.0+bookorbit.1-rc3 with
the overlay's patches up to 0028 applied.

- **Read seam:** `fetchJson(url, filter, doc)` (`src/network/BookOrbitCatalogClient.cpp:120`)
  is every catalog read. It downloads to `/.crosspoint/bookorbit_catalog.json` and parses from the
  file. The hook asks the cache first (`OrbifyCache::lookup`). If the entry is checked in the last
  60 s, or there is no network, it parses the saved reply. Otherwise it downloads as before, and
  keeps a `2xx` reply by renaming the temp file into the cache. A failed request falls back to the
  saved reply, marked "Not updated". Full refresh skips the saved reply. Parsing stays streamed with
  each caller's filter.
- **Write seam:** `sendBookOrbitRequest` (`lib/BookOrbitSync/BookOrbitSyncClient.cpp:426`, which
  the string form at :496 goes through) calls a weak hook with the method, URL, body and status
  of every non-`GET`. On `2xx`, `read-status` and `rating` patch the book in every saved reply
  that lists it, and progress or book states mark Home due.
- **Disk:** `/.crosspoint/bookorbit-cache/<hash>.json` plus `index.bin`, 2 MB and 200 entries,
  least recently used first. The Home body is never evicted by a list page. An index from another
  server or account drops the folder. Whole replies are parsed only to hash or patch them, with
  their nodes in PSRAM.
- **Covers:** the X4 Home covers (`BookOrbitHomeStore`, files `<id>_<ver>_<w>x<h>.bmp`, `<ver>` =
  FNV-1a of `updatedAt`) keep each book's version and ETag in the index.
  - A cover missing at the listed version, whose older file has an ETag, is asked
    `If-None-Match` (`downloadThumbnail`, `HttpDownloader` `DownloadOptions::etag`).
  - A `304` renames the older files to the new version.
  - A `200` replaces them and keeps the new ETag.
- **Revalidation in the background (the catalog browser; not built yet):**
  - The browser opens a view from the cache and queues its keys that are due.
  - A task like 0022's background sync (`BookOrbitBackgroundSync`) joins a saved network only
    then. It fetches only those keys, and turns Wi-Fi off again if it brought it up.
  - It runs only while the catalog is open and a visible key is due: never on a timer, and never
    after the catalog closes (closing stops it and waits, as `readerClosed()` does).
- **Paint once:** the browser's `loop()` polls the keys that changed. It reloads and repaints only
  a view whose key changed, once per change. Nothing changed means no repaint; the stamp updates
  with the next paint.
- **Refresh and Full refresh:** Confirm on ⟳ (X4 Pro: tap) is Refresh. A long press of Confirm on
  ⟳ (X4 Pro: hold) is Full refresh. Both use `OrbifyCache::ScopedMode` around the view's reload.
- **Offline mirror (X4, X4 Pro):** a smaller scope. Home's sections and the lists they link to,
  first pages only beyond Continue reading and Up next, the books on the reader and their next in
  series; files on SD under the same 2 MB cap, oldest lists dropped first. Same "Saved for offline"
  line in settings and the same TTL rule. X3 is excluded (no room). Built in overlay patch 0035
  ([XTEINK-BUILD-NOTES](XTEINK-BUILD-NOTES.md#offline-mirror-full-refresh-and-the-catalogs--patch-0035-2026-11-22)):
  the catalog root, each section's first page, the first 20 lists of each facet section, and up to
  30 book details, 150 requests at most; automatic in the sleep sync (2 min per sleep, resumed),
  by hand from the catalog's ⟳ (hold) or Settings › BookOrbit › Home › Full refresh. Without Wi-Fi
  the catalog opens from it.

## Self-grill (all two-way doors; settled here)

1. Cache every GET? No: catalog reads only. Auth, version and sync calls must see the server.
2. Patch or invalidate on writes? Both: patch the fields a write sets (exact, offline-friendly),
   and mark Home stale for the rest (goal counts, streaks are server-computed).
3. Where does the overlay live? Above the cache, never in it: an entry is always a server reply.
4. 60 s revalidation window: stops a revalidate-redraw-revalidate loop and repeated requests on
   quick back-and-forth; ⟳ always bypasses it.
5. One file per entry vs one big file: per entry, so a write or eviction touches one small file.
6. Account change: entries are keyed by account, and sign-out drops the cache directory.
7. Sizes (8 MB / 2 MB): the Home body is about 30-60 KB and a list page 5-20 KB; this holds
   every view a reader visits in weeks.
8. Covers: keep the plugin's files (already versioned) and decide what to fetch in the cache
   rules, not a second store.
9. Full refresh and covers: verify and replace. A blind re-download of every visible cover costs
   minutes of e-ink repaints and data for a case (a cover changed without a new version) that
   doesn't occur in normal use; a broken file is the real failure, and checking finds it.
10. Hold vs a second button: hold, so the header keeps one control; the menu entry makes it
   findable.

No one-way doors: everything is local, disposable and behind a setting.

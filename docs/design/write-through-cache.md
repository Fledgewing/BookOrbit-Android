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
| Revalidate | One background request per key at a time. Same reply (by canonical form): stamp `validated_at`, nothing else. Different: replace it and tell the view showing that key to redraw (see the platform hooks). Failure: keep the entry; the view's stamp says "Not updated". |
| Writes | Every non-`GET` passes through untouched. On `2xx`, the write's effects are applied to the cache: `read-status` and `rating` on book *id* patch `readStatus`/`rating` of that book wherever a cached body lists it (detail, Home lists, series members, list pages) and mark Home stale; progress and book-states mark Home stale. Stale = revalidate on the next read (immediately if it is on screen). A failed write changes nothing. |
| Size | Total cap (Android 8 MB, X4 2 MB on SD) and entry cap (400 / 200). Least recently used goes first; the Home body and the open book's detail are never evicted by a list page. |
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

- **Choke point:** `fetchJson(url, filter, doc)` (X `src/network/BookOrbitCatalogClient.cpp:82`):
  every catalog read already downloads to `/.crosspoint/bookorbit_catalog.json` and parses from
  the file. The cache keeps that file per key instead of overwriting it. Writes go through
  `sendBookOrbitRequest` (X `lib/BookOrbitSync/BookOrbitSyncClient.cpp:382`, :436); the
  write-effect rules hook there on `2xx`. The Xteink builder confirms these seams on 2.x.
- **Disk:** `/.crosspoint/bookorbit-cache/<hash>.json` + `index.bin`, 2 MB / 200 entries on X4
  and X4 Pro. Parsing stays streamed with the existing filters, so memory use doesn't grow.
- **Covers:** `downloadThumbnail` (X `BookOrbitCatalogClient.cpp:469`) writes the file under a
  name with the book id and its `updatedAt`, so a cover is fetched under the same rules.
- **Revalidate:** only while Wi-Fi is already up (the firmware joins on demand); a catalog screen
  opened offline shows the cached copy with the saved stamp. No background task on the C3.
- **X3:** not designed for now beyond "doesn't break": the cache stays off where the build lacks
  the room (compile-time flag), and the code path is the one it has today.

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

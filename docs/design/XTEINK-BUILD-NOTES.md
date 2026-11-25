# Xteink build notes: end of book, local-first catalog, grouping

How the Xteink firmware builds the approved designs [end of book](end-of-book/DESIGN.md) (ROADMAP items 1 and 2) and
[local first](local-first/DESIGN.md) (item 4, and 6a grouping). It records the two-way doors settled while building and
the upstream lines re-checked at the pins. The designs themselves are not changed here.

Pins: CrossInk-Bookorbit `v2.0.0+bookorbit.1-rc3` `87e2e19` (`crossink-v2.0` in
`tools/upstreams.lock`), BookOrbit `v3.9.0` `c1dd6b4`. The designs cite `v1.6.1+bookorbit.8` and
rc2 lines; the rc3 lines are below. Code: `xteink/orbify/` (symlinked into CrossInk as
`src/orbify`), pure logic in `xteink/orbify/core/`, hooks in `xteink/overlay/patches/v2.0/0027-…`
onwards, switches in `xteink/tailnet/tailnet_build.py`.

## Item 1: mark done at the end of a book (patch 0027)

### Upstream lines at rc3

| What | rc3 |
|---|---|
| End-of-Book page reached (`atEndOfBook`) | `src/activities/reader/EpubReaderActivity.cpp:3768` |
| `setBookCompleted` | `EpubReaderActivity.cpp:6490`; callers: 99% prompt `:3722`, menus `:4823`, `:5840` |
| Every finish on the device ends in `BookSyncFile::onFinishedChanged` | `src/sync/BookSyncFile.cpp:140`; callers `EpubReaderActivity.cpp` (in `setBookCompleted`), `BookStatsActivity.cpp:110`, `home/BookActions.cpp:331` |
| Book id of a downloaded file | `src/BookOrbitDownloadIndex.h:48` (`bookIdForPath`) |
| Sync endings | `bookorbit/BookOrbitSyncActivity.cpp:100` (`completeAlreadySynced`), `:631` (`performUpload`), `:296` (`runSleepSync`) |
| The sleep sync needs an open EPUB | `src/main.cpp:1540` (`shouldSyncBookOrbitBeforeSleep`) |
| Finish day and page count | `src/activities/reader/BookReadingStats.h:13` (`totalPagesTurned`), `:22` (`finishedDate`) |
| Request helper | `lib/BookOrbitSync/BookOrbitSyncClient.cpp:391` (`sendBookOrbitRequest`) |
| Server: `POST /koreader/plugin/book-states` (201), `PUT …/catalog/books/:id/read-status`, `…/rating` | BookOrbit `koreader-plugin.controller.ts:82`, `koreader-catalog.controller.ts:82,87` |

### Decisions (two-way doors)

| # | Question | Decision | Why |
|---|---|---|---|
| B1 | Which CrossInk line gets the Orbify features? | **2.x only** (the `v2.0` series) | The other recent features (settings PIN, battery stats, sync while reading) are 2.x only and LOCAL-FIRST already says v1.6 retires after 1.6.1. The overlay's own files compile to stubs on 1.6. |
| B2 | Where to hook "every manual mark" (G1)? | **`BookSyncFile::onFinishedChanged`**, one line | All three finish paths (reader, stats page, Library) already call it, so one hook covers them and their un-marks. |
| B3 | Queue file crash safety: temp + rename (§5) or two slots? | **Two slots with a CRC** (`orbify_finish.bin` / `.bak`, newer one wins) | The policy CrossInk uses for `progress.bin` and reading stats (`TwoSlotFile.h`); FAT has no atomic rename-over. Host-tested by tearing a write at every byte. |
| B4 | Step 1 (final position) for a job of another book | **Not resent**: the drain runs steps 2-6; the open book's own push is step 1 | The Xteink firmware syncs one book (the open one); its push precedes the drain. For other books, book-states and read-status set the status anyway; resending an xpointer needs the EPUB loaded. |
| B5 | `final_pos` in the record | **1000‰ for every finish** | Reaching the end page is the end; a manual mark keeps the hold rule meaningful (a push ≥10 points below the end). |
| B6 | "≥10 pages forward" release of the hold | **The book's `totalPagesTurned` ≥ the value at the finish + 10** | Already counted by the reader for stats; no new hook. |
| B7 | Statuses that are not fought (G4) | rereading, on_hold, abandoned **and skimmed** | `skimmed` is another deliberate finished state the server has (`db/schema/reader.ts:35`). |
| B8 | `status_seen` before the series card exists | **Unknown** | A server status set elsewhere is then never fought; book-states still applies the finish day when the server's change is older (S6). Item 2's series card fills it. |
| B9 | When does the queue drain? | **Every BookOrbit sync** (manual, on sleep, while reading): after the progress push, on an already-synced book, and once more at the end of the sleep sync | The sleep sync can end without a push (already synced, server newer); the extra drain is a no-op when nothing is due. Catalog and download sessions join with item 2 (G33). |
| B10 | Undo window | **Until the next sync**, which on sleep is "leaving" | The sleep sync runs after the reader leaves or sleeps; the menus un-mark until then (Undo itself is item 2's status row). |
| B11 | Visible change in item 1 | **None besides the setting**; the status row is item 2 | Item 1 is the bug fix: the book leaves Also Reading. |
| B12 | The D1 setting | **Settings > BookOrbit Sync > Mark Finished at End**, on by default, stored with the BookOrbit settings | It is a BookOrbit behaviour; the row sits before Home. |
| B13 | Flash | Item 1 costs **13.3 KB** on the X3 `default` (6,454,127 → 6,467,459 bytes, 98.48% → 98.69%), 11.8 KB on `x4-pro` (94.86%) and `x4-classic` (92.51%) | Mostly ArduinoJson's filtered parse of the detail reply, which item 2 reuses. CI now reports every env's use and fails `default` above 99.5% (6,520,932 bytes). |

## Item 2: the End-of-Book page (patch 0028)

### Upstream lines at rc3

| What | rc3 |
|---|---|
| The end page and its folder suggestions | `src/activities/reader/EndOfBookOptions.cpp:34` (`loadOnce`), `:81` (`handleMenuInput`), `:140` (`buildListScreen`) |
| Book detail at download, with a JSON filter (X5) | `src/network/BookOrbitCatalogClient.cpp:560` (`fetchBookDetail`) |
| Catalog link (X9) and its network-boot payload | `src/activities/browser/BookOrbitCatalogLink.h:11`; `BookOrbitCatalogListCache.cpp:386,397`; `ActivityManager.cpp:1159` |
| Entry link downloads, and a set `reopenPath` opens the new copy after | `BookOrbitCatalogBrowserActivity.cpp:393`, `:1465` |
| Book listing filter by author (S16) | `src/network/BookOrbitCatalogClient.h:74` (`BookOrbitBookQuery::author`) |
| Server: `seriesMembers` and `relatedSections` (author, similar) on the detail | BookOrbit `koreader-catalog.service.ts:747`, `:1368`; `seriesIndex` is a decimal string (`db/schema/metadata.ts:179`); related books carry no read status (`:1435`) |

### Decisions (two-way doors)

| # | Question | Decision | Why |
|---|---|---|---|
| E1 | Card contents | next book (id, index, title, read), gap number or series-done, the server status, 2 suggestions (id, title, source), the first author; **no file id or size** | "Download & open" goes through the catalog link, which reads the detail and its files again; storing them would only go stale. |
| E2 | Card file | `/.crosspoint/orbify_series/<bookId>.bin`, fixed record with a version and a CRC (`core/SeriesCard.cpp`) | Same policy as the queue; a bad file is ignored and rewritten. |
| E3 | When the card is refreshed | At download (the detail fetch already happens) and in a sync (manual or on sleep) **when the book is at 90% or more, or has no card** | The card only matters at the end; this bounds the extra request to the last tenth of a book. Background syncs (while reading) skip it. |
| E4 | "Read" for suggestions | Known only from `seriesMembers` | Related books carry no read status on the server (`:1435`). |
| E5 | Ratings shown as | Five drawn stars (polygons, `core/EndPageLayout::starPoints`); superseded the `‹ 4 / 5 ›` text in patch 0032 | The fonts have no star glyphs, so they are drawn. |
| E6 | X4 Pro touch on the rating | Each star is its own 52 px target and rates at once; superseded the row tap in patch 0032 | Mockup 7. |
| E7 | Undo | The status row's Confirm (or tap) toggles the finish through the reader's own `setBookCompleted` | Every path stays one: the queue job is removed or rewritten by `onFinishedChanged`. |
| E8 | Download & open | The catalog link gains `returnPath`; the catalog sets `reopenPath` from it, so a finished download opens the new book and Back or a failure returns to this book; the queue drains first (G33) | Reuses upstream's replace-and-reopen path; on the C3 it rides the one network boot. |
| E9 | Author row | The catalog link gains `author`; the catalog opens a listing with `author=<name>`, sort `series` | The server resolves the name (S16). |
| E10 | Rows that do not fit | Measured on the device each draw; dropped in the order suggestions, folder rows, author row, rating (`core/EndPagePlan.cpp`) | Landscape on a 480 px-tall panel cannot show every row; status, next and Home always stay. |
| E11 | X3 flash drop order | Switches `CROSSINK_TAILNET_ORBIFY_SUGGESTIONS` (2 → 0) then `..._AUTHOR_ROW` (1 → 0) | The CI gate names the order; flipping a switch is one line in `tailnet_build.py`. |
| E12 | XTC books | Keep upstream's page | The finish queue and the card are keyed by the EPUB's document hash and download index. |
| E14 | Flash | Item 2 adds **10.7 KB** on the X3 `default` (6,478,163 bytes, 98.85%, 42.8 KB under the gate), 7.5 KB on `x4-pro` (94.97%) and 6.8 KB on `x4-classic` (92.62%) | Under the gate: the X3 keeps its suggestions and author row. |
| E13 | "Get it at the next sync" (X4) | **Not in this release** | It needs a download queue in the sync; the page offers Download & open, Back to book, and the catalog's own retry. |

### The page rebuilt to the mockup (patch 0032, 2026-11-22)

The first device test showed a plain list in small type, and a tap that dropped the reader back to
Home. Patch 0032 draws the page itself, on the whole safe area, from `orbify/core/EndPageLayout`
(pure; draw ops plus tap targets). The firmware draws those ops with GfxRenderer; the host test
`eob_render` draws the same ops with FreeType, from the TTFs CrossInk's built-in fonts are made from,
to PNGs. CI uploads the PNGs as the `eob-page-*` artifact.

| # | Change | Why |
|---|---|---|
| P1 | Title "The End" in Bitter 16 bold, "<book> · <author>" in Bitter 12 italic, rows in Lexend Deca 12, second lines Lexend Deca 10, headings Lexend Deca 10 bold | Mockup 7's 34/19/20/15 px; the old page used UI 10/12. |
| P2 | Touch rows at least 64 px (the floor is 44), stars 52 px; the host test checks every target is at least 44 px and that no two rows' targets overlap | The ask's 44 px floor. |
| P3 | The rating row is always there (dimmed until finished), and the status and rating rows always keep their second line | Undo used to remove the rating row, so Home moved under the next tap: the "dropped back to Home" report. The host test checks Home's target stays put across Undo. |
| P4 | Every tap and button on the page is consumed (`Action::Consumed`), and a tap whose finger went down before the page was drawn is ignored and logged | An unhandled input used to fall through to the reader's page turns, short-Back-to-Home and gestures. |
| P5 | No card (offline, nothing fetched yet): the EPUB's own series (`Epub::loadSyncMetadata`) under "Next in series" with "Connect to see what's next", the folder rows under "Continue with", and "All books by <author>" from the EPUB's author | The ask's offline fallback; the rows no longer disappear. |
| P6 | Logs: `ORB End page: <state>, card <yes/no>, series <none/offline>, <n> rows`; `tap row <i> (kind <k>, star <s>)`; `row <i> acts (<act>)`; `tap … ignored`; `Back, to the last page`; `ERS End of book: Home` | Names the exit next time. |
| P7 | Not in this patch: the next book's cover | Added by patch 0036 (below), X4 Pro and X4 only. |

### The next book's cover (patch 0036, 2026-11-22)

`CROSSINK_TAILNET_ORBIFY_EOB_COVER` (0,1,1): X4 Pro and X4; the X3 has no flash for it. The rules are
`orbify/core/NextCover` (host test `end_of_book`); the files and requests are `orbify/FinishSync.cpp`.

| # | Question | Decision | Why |
|---|---|---|---|
| N1 | Cover version | `CardBook::coverVer`, the Home store's FNV-1a of `updatedAt` (`cache::coverVersion`), 0 = none known. Taken from the detail's `relatedSections` books (`hasCover`, `updatedAt`, added to the card filter); when no section lists the next book (the series section holds only the first 8 others, BookOrbit `koreader-catalog.service.ts:148,1395`), the sync asks that book's own detail. | `seriesMembers` carry no `updatedAt` or `hasCover` (`:1388`). |
| N2 | Card file | Version 2. `coverVer` sits in what version 1 left as padding, so the record keeps its size; a version 1 file reads as a card with no cover versions, never as a bad one. | No re-fetch storm after the update. |
| N3 | Files | `/.crosspoint/orbify_series/<bookId>_<ver>_60x90.bmp`, and `<bookId>_<ver>.jpg` until the decode | The cards' own directory: Home's prune lists only `/.crosspoint/bookorbit_home`. |
| N4 | When it is fetched | A sync (manual or sleep), after the card refresh and after the sync session closed, Wi-Fi still up. Never the page, never a background sync. | Nothing interrupts reading. |
| N5 | How | A Home BMP of that book at that version is copied (the largest); otherwise the thumbnail is downloaded, If-None-Match with the cache's kept ETag when an older version's BMP is here (`cache::planCover`); a 304 renames that file. The ETag record is the cache's (`OrbifyCache::coverRecord`), shared with Home: it describes the server's thumbnail. | Reuse; a metadata-only edit costs a 304. |
| N6 | Decode | 1-bit at 60x90 (`JpegToBmpConverter`, as Home), with the radio off: the sleep sync after `SavedWifiConnect::disconnect()`, and a manual sync after its disconnect. Needs a 54 KB block, else it waits. | About 53 KB of contiguous heap. |
| N7 | Old files | The book's other versions and sizes go after each fetch; the previous next book's files go when a card names another next book. | |
| N8 | Page | The cover at the left of the Next row, centred in a row grown to 106 px; label and second line beside it (`EndPageLayout` `COVER_*`). `fitRows` counts the taller row (`FitMetrics::nextRowHeight`). No file: no image and no space, the row as before. | Mockup 7, cover at the left. |
| N9 | Flash | `x4-pro` +8,192 B (6,283,597, 95.88%), `x4-classic` +8,380 B (6,129,086, 93.52%); X3 `default` +466 B with the switch off (6,505,613, 99.27%, 15.2 KB under the 99.5% gate): the shared card, plan and layout code | |

## Item 4: the write-through cache, seams (patch 0029)

Design: [`write-through-cache.md`](write-through-cache.md) ("Xteink"). Rules in `orbify/core/CatalogCache` (host test
`cache_test.cpp` runs `shared/fixtures/cache/cases.json`); disk and hooks in `orbify/CacheStore`.

| # | Question | Decision | Why |
|---|---|---|---|
| C1 | Which readers | X4 Pro and X4 (`CROSSINK_TAILNET_ORBIFY_CACHE` 0,1,1); every hook sits behind the switch | The coordinator's call; the X3 has no PSRAM for whole-reply parses and 42 KB of flash left. |
| C2 | Read hook | Inside `fetchJson`: the saved reply replaces the download, or the download's temp file is renamed into the cache | Every catalog read already goes through one file on the card; a rename costs no copy. |
| C3 | "Same reply" | `canonicalHash` of the whole reply, parsed again into PSRAM | Matches the shared case (key order doesn't matter); the view's filtered fields would differ per caller. |
| C4 | Write hook | A weak `orbifyCacheAfterWrite` called by `sendBookOrbitRequest` for every non-`GET` | `lib/BookOrbitSync` can't include `src/`; the same pattern as upstream's `tailnet_task_stack_*` hooks. |
| C5 | Patching on a write | Only replies whose text contains `"id":<n>` are parsed, patched and rewritten | Writes are rare (a finish, a rating); progress writes only mark Home due and read nothing. |
| C6 | Clock not set | Online, every read asks the server | The 60 s window can't be measured; offline still serves. |
| C7 | Concurrency | One recursive mutex around the store | The sleep sync, the background sync and the catalog's revalidation run on their own tasks. |
| C8 | Covers | Home covers only, by `planCover`: a missing file at the listed version with an older file that has an ETag is asked `If-None-Match`; 304 renames every size | The catalog browser draws no covers; Home's `<ver>` is already `updatedAt`'s hash. |
| C9 | Flash | `x4-pro` +27.3 KB (95.39%), `x4-classic` +27.0 KB (93.03%); X3 +414 B (shared signature changes only) | |

## X3 update check and download (patch 0030, 2026-11-22)

Field report from an X3 on the CrossInk-Tailnet bridge `v2.0.0.51+bookorbit.1-rc2` (serial log):

- The check read `api.github.com/.../releases` (a ~30 KB chunked list) and failed mid-body:
  `esp_tls_conn_read error, errno=No more processes` (EAGAIN, a read timeout),
  `ESP_ERR_HTTP_INCOMPLETE_DATA`, heap min 52 KB, largest block 47 KB.
- The download ran at 1-4 KB/s ("last 18 s: SD write 41 ms, waiting 18164 ms"), on the small WiFi
  tier (`WiFi tier small (boot target 2)`: static RX 2, dynamic RX 4, RX BA window 4) with ~115 KB
  free. At TCP_WND 5760 a 4 KB/s rate means seconds per window: frames dropped for want of an RX
  buffer and recovered by TCP timeouts, not a slow server.

| # | Change | Where |
|---|--------|-------|
| O1 | The check already reads the raw feed (`OTA_FEED`, two releases, a few KB) on every Orbify build; nothing to change. It streams through `ReleaseJsonParser` in whatever chunks arrive. Host test: 1-, 7-, 97- and 4096-byte chunks and the live feed (`shared/fixtures/github/xteink-feed.json`) pick the same release, with a 64-hex digest (so the download uses wolfSSL). | `tailnet_build.py` (OTA defines), `test/ota_release_pick_test.cpp` |
| O2 | The check gets `timeout_ms` 15 s and one retry on a fresh connection, with the parser and the pick reset; a non-2xx answer is retried too. Host test: a list cut off at two thirds, then reset and read again, picks the same release. | patch 0030 (`OtaUpdater.cpp`), switch `CROSSINK_TAILNET_OTA_CHECK_RETRY` |
| O3 | The OTA boot (target 2) takes the parked WiFi tier (X3: static RX 3, dynamic RX 8, dynamic TX 8, RX mgmt 5; RX BA window 6). It has the parked boots' heap (115 KB free before the download). Costs ~8 KB of WiFi buffers at worst. | `ui/TailnetNetPhase.cpp` `tailnet_wifi_parked_boot` |

Two-way doors: one retry (not a loop: a second failure shows the error and the user can retry);
the parked tier rather than a new larger OTA tier (the X4s keep the framework's counts and
were never slow; a larger X3 tier is one more switch row if O3 is not enough).

Device check (X3, serial log): `WiFi tier parked (boot target 2)` at the update; download lines
`Download progress: … KB/s` well above 4 KB/s with "waiting" no longer the whole interval; heap
min during the download.

## Nothing interrupts reading (patch 0031, 2026-11-22)

The user's standing rule: while a book is open, nothing the reader did not ask for appears. The
rule is `orbify/core/ReadingQuiet` (table `shared/fixtures/reading-quiet/cases.json`, shared with
Android); the firmware asks `OrbifyQuiet::allow()`, whose `reading()` is
`activityManager.isReaderActivity()`. Audit of what the overlay can show on its own:

| Path | While reading? | Now |
|------|----------------|-----|
| Sync while reading (0022) | Its BookOrbitSyncActivity asks for repaints at every step | Held as `background-render` (already dropped by 0022; now through the one check) |
| Update check / download (0026, 0030) | Only from Settings > Check for updates; no check on a timer or at boot | User-opened |
| "Connecting to Tailscale..." (live catalog) | Catalog boot only | Held as `network-status` if it ever ran over a book |
| Parked-boot popups and restarts (0002, 0007, 0011, 0020) | Syncs and uploads the reader started from a menu, or the sleep sync | User-opened / during sleep |
| Finish at end, End-of-Book page (0027, 0028) | The page the reader reached | Exception |
| Cache writes (0029) | No UI | - |

Upstream CrossInk's own reader toasts (page load errors, menu actions) answer what the reader did
and are left alone. Flash: X3 +410 B (6,478,797, 98.86%).

## "This copy differs from the library file" (patch 0033, 2026-11-22)

An X4 Pro sync of book 1207 (file 3563) ended with `Server has another copy of this document`,
`positionIncompatible` and `This copy differs from the library file`, then offered the update.
What decides it, read against BookOrbit `c1dd6b4f`:

- The firmware compares no hashes. It sends the card file's KOReader partial MD5
  (`KOReaderDocumentId::calculate`, BookOrbitSyncActivity.cpp:408) and reacts to the server's
  `positionIncompatible` list (BookOrbitSyncActivity.h:238, .cpp:537).
- The server lists a hash there when it resolves to the book's file but
  `compatibleProgressHash` is false (`server/src/modules/koreader/koreader.repository.ts:32-42`,
  `koreader-annotation-exchange.service.ts:146`): the hash is neither the file's current
  `fileHash` nor a `kobo_download` (delivered variant) row with no later source change.
- So the server knows `3dcf3eb3c005357c54c1f8a27320bf98` as an older hash of file 3563. The same
  copy, same hash, synced with `unmatched=0` on 11-21 (X4 Pro log), and the X3 and X4 Classic
  downloads of file 3563 give that hash too. The card bytes did not change; the library file's did,
  between 11-21 01:25 and 11-22 22:00 PT.
- What moves a file's hash on the server without a new upload: a metadata or cover write into the
  EPUB (`file_write`, `file-write.service.ts:465,618,745`; scheduled by any metadata save, bulk
  edit or cover change, `book.service.ts:2241,4246`, `cover.service.ts:104-151`) or a rescan that
  finds new bytes (`rescan`, `scanner.repository.ts:540`). BookOrbit treats both as new content
  for KOReader positions.
- Not the delivery-variant case: no media overlay, so `/plugin/catalog/files/3563/download`
  serves the library file itself (`koreader-catalog.service.ts:812-846`), and the device's name
  has no " - Text Only". Not a hash mismatch between implementations: the server matched the hash.

Patch 0033 (`CROSSINK_TAILNET_ORBIFY_COPY_CHECK`, all three devices) makes the next one
explainable and stops a pointless re-download:

| # | Change | Where |
|---|---|---|
| C1 | The sync's line names the card copy's hash and path. | BookOrbitSyncActivity::resolveUpdateBook |
| C2 | The catalog detail keeps each file's `fileHash` and `contentVersion`. | BookOrbitCatalogClient::fetchBookDetail |
| C3 | An update logs `card copy <hash> (<path>), library file <id> <hash> (changed <contentVersion>): same/differs/unknown`; `same` opens the copy instead of downloading. | BookOrbitCatalogBrowserActivity::downloadBook |
| C4 | The compare rule, host-tested. | orbify/core/CopyCheck, test/copy_check_test.cpp |

## Keep book copies current (patch 0034, 2026-11-22)

After the tag rewrite above happened to almost every book, every card copy went `positionIncompatible`.
`CROSSINK_TAILNET_ORBIFY_COPY_REFRESH` (all three devices) finds and replaces them; the rules and
the queue are `orbify/core/CopyQueue` (host test `copy_queue`, 37 checks, mutation-checked).

| # | Step | Where, and what it reuses |
|---|---|---|
| R1 | Detection: every download in the index is hashed (`BookContentId::contentHash`) and sent through the match check, 20 per request. A copy is queued only when the server matched it to the same book and returned `positionCompatible:false`. When the library token equals the last full pass's, it stops after one batch. | `OrbifyCopyRefresh::detect`; `BookOrbitSyncClient::matchCheck` gains an optional older-copy visitor (default null, other callers unchanged) |
| R2 | Queue: `/.crosspoint/orbify/copy-refresh.tsv` (written to a temp file, then renamed), one book at a time, oldest first, 3 attempts, saved after every book. | `core/CopyQueue` |
| R3 | Before a download: the book detail's `fileHash` must be present (otherwise nothing downloads), and a copy already equal to it is only re-recorded. | `beforeDownload`, patch 0033's detail fields |
| R4 | Download: the catalog's own options (stage as `.part`, resume, free-space check, EPUB check, `keepReplaced`). | `BookOrbitCatalogClient::downloadFile` |
| R5 | After: the new copy's hash must equal `fileHash`; if not, `<book>.old` goes back. If it does, `BookUpdateMigration::begin` moves progress, highlights, bookmarks and sync state to the new hash and rewinds the upload watermarks. | `afterDownload`; the fork's `util/BookUpdateMigration` (the same code the catalog's update path runs) |
| R6 | When: the sleep sync (detect and replace, 180 s per sleep, stopped by a wake press) and the Home refresh (detect only). Never while a book is open. Each download needs a 24 KB heap block; X3 sleep syncs log 65-102 KB. | `BookOrbitSyncActivity::runSleepSync`, `BookOrbitHomeRefreshActivity` |
| R7 | Decision (a): the sync offer's Update queues the open copy and shows "Updates when you leave the book". No restart. | `BookOrbitSyncActivity::startBookUpdate` |
| R8 | The setting: Keep Book Copies Current, on by default (`orbifyKeepCopies`). | `BookOrbitCredentialStore`, `BookOrbitSettingsActivity` |

Two-way doors taken:
- (i) The Home refresh only detects, so a user-started refresh never holds the screen for minutes.
- (ii) 180 s per sleep sync.
- (iii) Charging is not a trigger yet: the sleep sync already covers every sleep.

Not host-tested: the carry-over itself. It is the fork's `BookUpdateMigration`, which needs the card's
storage layer; the test covers the queue entry that records the old hash and the hash check that gates the
swap.

## Offline mirror, Full refresh and the catalog's ⟳ (patch 0035, 2026-11-22)

Design: [write-through-cache](write-through-cache.md) ("Offline mirror", "Refresh and Full
refresh", the Xteink section) and [local-first](local-first/DESIGN.md) decisions 36-37 (the
header ⟳ on every view; on button-only readers Up on the first row selects it). X4 Pro and X4
(`CROSSINK_TAILNET_ORBIFY_MIRROR` 0,1,1, which needs the cache); the X3 has neither.
Rules in `orbify/core/Mirror` (host test `mirror_test.cpp`, with the shared `mirror.due` cases);
the walker in `orbify/Mirror`.

| # | Question | Decision | Why |
|---|---|---|---|
| M1 | What a Full refresh saves | The catalog root; the first page of each section the root lists (Want to read too); for authors, series, collections, libraries and SmartScopes, the first page of the lists of their first 20 rows; the details of the books on the reader and of their next in series (30 at most). 150 requests at most. | The design's X4 scope ("first pages only"), inside the cache's 200 entries so the views read by hand keep room. |
| M2 | Same requests as the browser | The walker calls the catalog client's own fetches with the browser's page size; a facet row's book list comes from `core/Mirror::facetQuery`, the browser's `activateSelected` mapping, checked by the host test | A request the browser makes differently would miss the cache offline. |
| M3 | Cache mode | Every mirror request runs under `OrbifyCache::ScopedMode(Full)`: it asks the server whatever the cache holds and replaces the entry | The design's Full refresh. |
| M4 | When, automatically | The sleep sync, after the copy refresh, when the mirror was never saved, is 7 days old, or the library version (the match check's token) moved: up to 2 min per sleep, resumed by the next (plan on the card, `/.crosspoint/orbify/mirror.tsv`) | Never while reading; the radio is already up. Not in the Home tile's sync, which would then take minutes unasked. |
| M5 | When, by hand | Hold ⟳ (X4 Pro) or long-press Confirm on ⟳ (X4) in the catalog: runs in place with "Full refresh · saving for offline N/M". Settings › BookOrbit › Home › Full refresh: runs in the Home sync boot with a progress bar; its value is "Saved for offline · 3 h ago" | The approved controls, plus the settings row as a second trigger. |
| M6 | The ⟳ | At the header's right on every catalog view, the stamp ("updated just now", "Offline, saved 3 h ago", "Not updated · …", `orbify::formatStamp`) as the header's second line on the X4 Pro and beside the ⟳ on the X4. Tap / Confirm: Refresh (the view, asked now, the session's page copies dropped). Hold / long press: Full refresh | Decisions 36-37. Up from the ⟳ wraps to the last row; Down goes back to the first. |
| M7 | Offline | The catalog boot that cannot join Wi-Fi opens from the cache when a mirror is saved, instead of leaving; Search says "Search needs a connection"; ⟳ connects first ("Couldn't connect" when it can't) | The design's "opens offline"; downloads still need Wi-Fi and fail as before. |
| M8 | Not in this patch | Covers in the mirror (the Home sync keeps the Home covers); the automatic-Full-refresh setting (fixed at 7 days); opening the catalog offline without the network boot (decision 29's restart stays) | Smallest change that gives offline browsing; each is a follow-up if the device test asks for it. |
| M9 | Flash | `x4-pro` +14.0 KB (96.0%); X3 unchanged | |

## The rc3 device fixes: the sleep sync on a shared heap, copies, covers, refresh (patch 0037, 2026-11-23)

Shipped as one patch, now split by concern (same result): `0037a-orbify-sleep-sync-budget` (S5),
`0037b-orbify-eob-card-while-reading` (S9), `0037c-orbify-sleep-sync-lends-session` (S2, S4, S7),
`0037d-orbify-home-cover-heap-floor` (S3, S11), `0037e-orbify-copy-refresh-replace` (S8),
`0037f-orbify-catalog-refresh-and-mirror-urls` (S10, S12 catalog), `0037g-orbify-home-sync-tile`
(S12 Home), `0037h-orbify-sync-retry-after-tailscale` (S15), `0037i-orbify-settings-swipe` (S13).

The rc3 test on an X4 Pro: a wake press was ignored for minutes, the mirror sent a 400, the copy
refresh failed its match check, and the End-of-Book page showed no card, drew no rows on the
reader's Bitter font, and kept the Home swipe.

| # | Question | Decision | Why |
|---|---|---|---|
| S1 | What ate the heap | With Tailscale up an X4 Pro has ~30 KB of internal RAM free beside the sync's one TLS session (largest block 14-16 KB). rc3 then opened a second catalog TLS session for the copy refresh, cover and mirror, with no floor: the relay's own mbedTLS session could not get its hardware-AES buffers (`esp-aes: Failed to allocate memory`), the relay dropped, handshakes took 14 s and a 47 KB reply waited 82 s. | The serial log of the .156 boot; rc2 logs show the same ~31 KB baseline, so the new rc3 extras were the trigger. |
| S2 | One connection | The sleep sync keeps its BookOrbit session after the book's sync and lends it to the catalog client (`BookOrbitCatalogClient::LentConnection`): on the X4s the Home refresh and its covers, the next cover, the match check, copy downloads and the mirror slice all ride it, in that order, then it closes. The X3 (no PSRAM) keeps its order: the Home refreshes on its own connection after the session closes. | Same server; a request on a kept connection needs no new TLS session. |
| S3 | Heap floor | `orbify/HeapFloor.h`: 24 KB free before each extra request; a transfer under way stops below 16 KB free (its `.part` resumes next sleep). | Leaves the relay's TLS its few KB. Both numbers are estimates from one log: the next test's `waiting for heap` / `heap starved` lines confirm or move them. |
| S4 | Mirror in the sleep sync | A paced slice only: at most 10 requests and 30 s per sleep, each behind the floor; the rest resumes in the next sleeps. The whole Full refresh stays in Settings' and the catalog's own boots. | A Full refresh is up to 150 requests: minutes of radio with the device looking asleep. Taking it out entirely would leave the automatic 7-day refresh with no runner. |
| S5 | Wake press and time budget | The power-button watcher (stack 2 KB -> 4 KB) now bounds the sync (`orbify/core/SleepSyncDeadline.h`, host test): a press the sync has not answered within 2 s restarts into the wake from the watcher's task; at 240 s every step stops at its next check and the device sleeps; still running 20 s later, the watcher restarts into a boot that only sleeps (`BOOKORBIT_SLEEP_SYNC_PAYLOAD_SLEEP_NOW`). Copy downloads now check the press between chunks. | The sync checked the press only between steps, and one step blocked 82 s. The forced restart skips the SD flush (the stuck task may hold the card); queues and plans are replaced by rename and downloads staged as `.part`, so at most the step is lost. |
| S6 | Mirror 400 | `core/Mirror` `Plan::add` cleaned the field separator `\x1f` into a space, so a sort+readStatus query became `sort=recently_read readStatus=reading`. Separators are kept; the plan file is `orbify-mirror 2` (a version 1 plan is dropped and rebuilt). The host test sends every request kind through add/serialize/parse/decode. | |
| S7 | `match check failed (8)` | Error 8 is `LOW_MEMORY`: the match check ran after the session closed and a new TLS session needed a 24 KB block (largest 16 KB). It now runs on the kept session (S2), and the X4s' new-session block is 8 KB (`CROSSINK_TAILNET_SYNC_TLS_BLOCK`; their TLS buffers go to PSRAM). | |
| S8 | When a changed copy is replaced (the user's ruling, 2026-11-23) | Never while reading and never at close (no Wi-Fi then). A sync while reading only queues the copy, silently (no offer, "Updates when you leave the book" removed). The sleep sync replaces every queued copy, the book that was open included; the Home's refresh and a Full refresh replace them too. Position, highlights and bookmarks move with the book (BookUpdateMigration). What does not fit (time, heap) carries over. Log: `Copy refresh: replaced N (sleep sync|Home|Full refresh), N carried over`, per book `Copy refresh: book X replaced, position kept at P%`. | The details/long-press line ("Newer copy in the library") is not added: the X3 is at 99.3% of its slot. |
| S9 | End-of-Book page | Card: a sync while reading fetches a missing card near the end, and the page draws itself again when a card arrives (`OrbifyFinish::cardGeneration`). Series line "Book 2 of Harbour Lights" under the book line (mockups 1-5; card v3 carries the series name, index and count, v1/v2 cards still load). Fonts: the X4 builds register only the reader's scalable family; the page now registers Lexend Deca and Bitter before drawing. Home: the bottom-edge swipe leaves the page, as everywhere outside a book and in the reader's drawer. | |
| S10 | Mirror 400s on every list (rc3 Full refresh: 39 of 69 failed) | The same `Plan::add` bug: every kind-2 request (sort+readStatus, `libraryId`, `collectionId`, `smartScopeId`, `seriesId`) was one `sort`. The book-list URL is now built by `core/Mirror::booksPath` (the catalog client's `booksUrl()` uses it on the X4s); the host test checks the URL of every request kind the plan holds. The catalog's `Failed to open … bookorbit_list_<hash>.json` lines were its session page cache missing a page not yet seen: no longer logged. | |
| S11 | Home covers | The covers were deferred by a 42 KB free / 20 KB block floor (an X4 Pro had 28 KB / 8 KB) and only 8 fetched per sync. On a kept connection the floor is OrbifyHeap's 24 KB; on the X4s the block is 8 KB and a sync fetches up to 30. In the sleep sync the Home refreshes first, on the lent connection (X4s; the X3 keeps its order). Log: `covers: N needed, N on SD, N fetched, N deferred (why)`. | |
| S12 | Refresh feedback | The catalog's ⟳ tap shows "Refreshing…" in place of the stamp until the view is read again, then "updated just now". Home: the sync tile is the refresh: tap / Confirm refreshes Home and its lists ("Refreshing…" on the refresh screen); a long press, or Confirm held 1 s, asks for a Full refresh, which the refresh boot runs with "Full refresh N / M" (X4s; the X3 has no mirror). Up and Down reach the tile on button readers, as Up reaches the ⟳ in the catalog. | |
| S13 | Settings › BookOrbit sync swipe | Swipe up/down pages the list (as KOReader sync's settings do). | |
| S14 | "Tailscale off" as offline | Not built (as asked). Reading the code: the cache's "offline" is Wi-Fi down only. With Tailscale off and Wi-Fi up, a request fails fast (no route to the tailnet address) and the catalog shows the saved reply with its "Not updated" stamp; a view never saved shows the catalog's error, and the Home keeps its snapshot. | Confirm on the device. |
| S15 | A sync failed while Tailscale's map was late | Register took 3.6 s (normally ~0.2 s), then the control plane sent no MapResponse at all for 22 s; the sync's 20 s wait ran out ("Host is unreachable"). MicroLink (submodule, `ml_coord.c`): a Stream=false MapRequest with no reply in 10 s is sent again on a new connection, and a second silence takes the streaming fetch; `[TIMING] MapResponse first reply` and `MapRequest retry N` are logged (register time was already: `[TIMING] Register total`). The book sync retries its first request once after Tailscale is up (30 s wait), then fails. The "6 s gap" before MicroLink's tasks is the two log clocks: the app's `[ms]` lines show no gap (IP at 4754, tasks by 4791). Cached peers before the map: not done; MicroLink's cached start exists only in the X3's lite build (`ML_LITE_CACHED_START`), the full build's WireGuard manager waits for registration and the DERP map. | Porting the cached start to the full build is a follow-up. |
| S16 | Not in this patch | DERP over wolfSSL on the X4s (the relay's mbedTLS session is what needs the internal AES buffers) | A transport change for its own test. |
| S16b | End page blank on an X4 Pro (photo, `.156`) | Every row's text was missing and the selected row was a plain black band: the rows use Lexend Deca, and an X4 builds a built-in family from outlines only when it is asked for: only the reader's own family (Bitter here) was loaded, so `GFX Font … not found` drew nothing and measured 0. The fonts now come from one table (`core/EndPageLayout` `fontSpec`); `EndPage.cpp` registers every family in it before drawing, and a font still missing is drawn with the UI font (`End page: font N not loaded; drawing with the UI font`). The host render loads its TTFs from the same table and checks, each row selected in turn on touch and buttons, that every row's text is non-empty and inks pixels against what is under it, and that no enabled row (Home included) falls off the page. | The language-partition line (`Unexpected language partition size: 81920`) does not touch these strings: English is built in. |
| S17 | Flash | `default` (X3/X4) 6,510,769 of 6,553,600 bytes (99.35%, under the 99.5% gate by 10 KB; 99.27% before); `x4-pro` 96.20%; `x4-classic` 93.83% | |

## The .167 X4 Pro test: wake, heap, Home tile, catalog stamp, cache-first, menu swipe (patch 0038, 2026-11-23)

Split by concern like 0037: `0038a-orbify-wake-press-timing` (W1), `0038b-orbify-tls-heap-in-psram`
(H1, H2, T2), `0038c-orbify-boot-trail` (D1, D2; it also calls the heap and wake hooks from
`setup()`), `0038d-orbify-catalog-cache-first` (C1, C2), `0038e-orbify-home-tile-touch` (T1, M1).

| # | Question | Cause (file) | Change |
|---|---|---|---|
| W1 | Every wake restarted from the watcher ("not answered within 2000 ms", 0.6 s after the press) | The watcher stores a press as `now \| 1` and checks the deadline in the same tick (`util/PowerButtonWakeWatcher.cpp`). On an even millisecond the press read as `now + 1`, so `now - pressedAt` wrapped to ~49 days and the forced restart fired at once (`orbify/core/SleepSyncDeadline.h` `check`). The sync's own "Sleep sync cancelled" came 12 ms later. | Measured from `pressTime()` (`pressedAt & ~1`); host test `pressInTheSameTick`. The press time crosses the restart (RTC memory; an env var on the simulator) and the wake boot logs `SLP Wake: N ms from press to screen` once its first frame is on the panel (`GfxRenderer::displaysSinceBoot`). Before the restart: `Wake press answered by the sync N ms after it was made` or `... handled by the watcher ...`. |
| H1 | What fragments the internal heap | The largest internal block was 31.7 KB just before the sync's wolfSSL handshake and 10.2 KB after it (7 KB by the series card). wolfSSL (the BookOrbit and catalog requests) used the default malloc; every allocation under 4 KB (`CONFIG_SPIRAM_MALLOC_ALWAYSINTERNAL`, and with `WOLFSSL_SMALL_STACK` the handshake makes many) went to internal RAM. mbedTLS (the relay) was already in PSRAM (`TailnetTlsMem.c`). | `OrbifyHeap::installTlsPsram()` (`orbify/HeapFloor.cpp`, called first thing in `setup()`): on the X4s `wolfSSL_SetAllocators` puts all of wolfSSL's memory in PSRAM, internal RAM only when PSRAM is full. Switch `CROSSINK_TAILNET_TLS_PSRAM` (0, 1, 1); the X3 is unchanged. |
| H2 | Gates that measured the wrong pool | The reply-body check compared a reply's size with the internal largest block, although malloc puts 4 KB and more in PSRAM: `match check failed (8)` at 7 KB largest. The floors (`OrbifyHeap` 24/16 KB, kept session 20 KB, Home fetch and next cover 42 KB) counted wolfSSL's needs in internal RAM. | `largestBlockFor()` (BookOrbitSyncClient) measures replies of 4 KB and more against PSRAM. X4 floors: kept request 12 KB, transfer 8 KB, kept TLS session 12 KB (`CROSSINK_TAILNET_SYNC_KEPT_FLOOR`), new session 20 KB free and a 4 KB block, Home fetch and next cover 20 KB free and a 4 KB block on a new connection. The series card's JSON goes to PSRAM (`OrbifyHeap::jsonAllocator`). Copy downloads already stream to SD in 1 KB chunks (SecureHttpClient's buffer); they stopped on the floor, not on a buffer. |
| T1 | Sync tile: a hold did nothing, a tap failed, a slow tap started a Full refresh | The tile took the SDK's screen long press, which fires at 500 ms (an ordinary e-ink tap) and suppresses the contact before the tile was checked (`HomeActivity::loopBookOrbitHome`). | The tile times the contact itself: released before 1 s is a refresh, held 1 s is a Full refresh. The restart's popup says which ("Refreshing…", "Full refresh"; `setSilentRestartMessage`) instead of "Loading". |
| T2 | The double reboot after the Full refresh request | The first refresh boot refused the Home fetch on the 42 KB floor (`Leaving the Home snapshot for the next sync (free=38924 maxAlloc=22516)`), showed its failure and went Home; a second refresh boot followed and ran the Full refresh. The log has no input lines, so what started the second boot is not visible; each tile action now logs `Home: refresh asked for from the sync tile` / `Home: Full refresh asked for ...`. | The X4 floor is 20 KB (H2), so the first boot fetches. |
| C1 | Catalog ⟳: no "Refreshing…" / "updated just now" on the X4 Pro | On touch readers the stamp was passed as the header's subtitle, which the header band draws at its right edge, under the ⟳ and the battery (`BookOrbitCatalogBrowserActivity::render`). | Drawn left of the controls; `Catalog stamp '<text>' at x,y wxh` is logged when it changes. |
| C2 | Cache-first catalog (the user's rule) | A catalog opened in place (the X4s) always joined Wi-Fi first (`onEnter` → `checkAndConnectWifi`), even offline with Tailscale off. | With a saved copy that is not stale (`core/Mirror` `catalogFromCache`: saved and `dueNow()` none, so neither the 7-day Full refresh nor a new library version is due) it opens from the cache with no Wi-Fi (`Catalog: opening from the cache, no Wi-Fi`) and the stamp shows the copy's age. ⟳, the Home tile, a stale copy, or a view the cache does not hold (`connectForMiss`, once) connect. The Android plugin differs: it serves the cached entry at once and revalidates it in the background on every read older than 60 s (write-through-cache.md, Read row). The Xteink revalidates only on ⟳ or when stale, because each connection costs a Wi-Fi join and Tailscale's start. |
| M1 | Home swipe on the menu (Settings, BookOrbit, ...) flashed the Home and came back | The menu closed on the swipe's touch-down below its panel; the same swipe then ended on the BookOrbit Home as an upward swipe, which opens the menu (`HomeActivity::loop`). | A tap outside the panel or a Home swipe closes it, and the swipe is spent there. Buttons: Back closes the menu to the BookOrbit Home. |
| D1 | The X4 Pro's core dump after the 19:46 hang: `assert failed: udp_remove ... (Required to lock TCPIP core functionality!)` in loopTask | Not from .167. Every return address in the dump's loopTask backtrace sits right after a CALL8/CALLX8 in the .141 x4-pro image (25 of 25) and only 8 of 25 do in .167's; the chain is `hostByName` → `dns_clear_cache` → `udp_remove` with no wrapper frame, and the dump's strings (`ml_stun` DNS failure at 3.6 s, `bookorbit_catalog.json`) are .141's catalog-boot panic. Fixed in .150 by `__wrap_dns_clear_cache` (`tailnet/shim/TailnetLwipLock.c`, host test `lwip_lock_test.c`); .167 calls the wrapper from `hostByName`. Nothing reads or erases the core dump partition, so it outlives its build. | `orbify::logCrashRecord()` (`orbify/CrashRecord.cpp`, S3 boards): each boot logs `Crash record: none`, `... the one reported before (crc ..), from this build / an earlier build (app <sha>)`, or for a new one its task, PC, panic reason and backtrace (`Crash record backtrace: 0x...`), then remembers its CRC in NVS. The record stays in flash. Host test `boot_trail_test.cpp` (`sameBuild`). |
| D2 | The hang itself: no wake, USB coming and going with no output, Power held 10 s and a replug did nothing, a USB reset booted it | The log ends at the sleep screen's redraw (`8279x4_POF`), without the usual `Deep sleep: power latch released` 28 ms later; USB went away at the same moment as on a good sleep. At the USB reset the ROM's `Saved PC:0x4037acb6` is `esp_cpu_wait_for_intr` (core 0's idle task): the app was running and idle, not in the ROM. The USB reset itself went through the USB-serial-JTAG, which `HWCDC::end()` on the way into deep sleep turns into GPIOs, so the chip had started again after that sleep; the boot that followed never logged, though a wake boot's lines from ~0.65 s on reach the host (19:30:51). The log cannot say more: which boot step it stopped at is not recorded. Ruled out: a hang before the serial port closes (USB dropped on time, so the fuel-gauge wait and the display and SD steps finished), and a panic (it reboots and logs; the core dump is .141's, D1). | A boot trail (`orbify/core/BootTrail.h`): one RTC word per step (setup start, serial up, wake checked, setup done; on the way to sleep: sleep screen, SD stopped, display asleep, serial closed, Power release wait, deep sleep entered). The next boot logs `BOOT Last run ended at: <step>`, or `BOOT Last run stopped at: <step>` (error) when a reset the firmware did not make itself follows a run that never reached deep sleep or `loop()`. A USB reset of a silent device now names the step. Host test `boot_trail_test.cpp`. |
| F1 | Flash | `default` (X3/X4) 6,512,975 of 6,553,600 bytes (99.38%, under the 99.5% gate); `x4-pro` 96.3%; `x4-classic` 93.9% | |
| E1 | Series card log `#5 of 2`, and `#- of 0` for a book with no series | `seriesCount` is `seriesMembers`: how many of the series' books the library holds, not the series' length. The page line ("Book 5 of Starbreaker") uses the series name and was right; the log was misleading. With a card that named no series the page fell back to the EPUB's own series. | Log: `series 'X' #N (K of its books in the library)` or `no series`. The page takes the card's series when there is a card, so no series = no line (`orbify::pageSeries`, host test). |

Simulator numbers (scripted internal heap `w0:21376/7156`, the .167 X4 Pro sleep sync), scenario
`sleep_sync_device_heap`: before (0037 floors, the same scenario), the sync's first request is
refused (`TLS floor: new session needs 35000 free and a 8192 block (largest now 7156)`, progress
result 8) and nothing after it runs; after, the sync, the Home and its covers, the match check and the
copy's download complete (`Copy refresh: replaced 1`). The 15 KB dip the .167 transfer starved at
is device-only: the simulator opens a new session per request, so it applies the 20 KB new-session
floor there rather than the 8 KB transfer floor. The simulator caps
only the reported internal heap; it cannot show the internal RAM wolfSSL no longer takes. On the
device, watch: `MEM` and `BookOrbit Listing ... maxAlloc=` after the handshake (the largest block
should stay near its pre-handshake 30 KB), `ORB wolfSSL allocates from PSRAM` at boot,
`Series card parse: heap free ..., largest ...`, `Copy refresh: replaced N`, `covers: N needed, N on SD,
N fetched` with no `deferred (heap`, `SLP Wake: N ms from press to screen`, and at every boot
`BOOT Last run ended at: ...` / `Last run stopped at: ...` and `BOOT Crash record: ...`.

## The sleep screen (patch 0039, 2026-11-24)

ROADMAP 11 on the X4 Pro and X4 ([lock-screen](lock-screen.md), Xteink rows R3, R4b, R6, R8, R10,
S3, S4, X1-X7). Switch `CROSSINK_TAILNET_ORBIFY_SLEEP` (0, 1, 1): the X3 builds none of it.

| # | What | Where | How |
|---|---|---|---|
| P1 | BookOrbit Pick in the Sleep Screen list | `orbify/SleepSettings.cpp` `sleepScreenRow`, `SettingsList.h` | A dynamic enum over CrossInk's choices plus BookOrbit Pick, stored in `/.crosspoint/orbify_sleep/settings.json` (`pick`; `from` and `leaveScopes` one item per line); `sleepScreen` keeps its value (S4). The rows that apply only to Pick, or to Overlay, show only then. The web settings page has the same keys (`orbifySleep*`). |
| P2 | The batch | `orbify/SleepScreen.cpp` `topUp`, `core/SleepPick` | Up to 24 covers on the card whatever Pick From is; each sleep sync tops it up by at most 4 covers within a 40 s share of its budget, on the lent session, after the next cover. Each picked list is re-read once a day (all picked sources empty: Up Next, Want to Read, Discover not picked); every picked library, smart scope and collection share one shuffle bag of up to 500 (10 pages per sleep). Every sleep: a cover goes after 3 shows, never the one on screen. Hours mode from a list follows the list; from a bag, a shown cover makes room. |
| P3 | Leave out | `topUp`, `memberCheck`, `probe` | Tags from each candidate's detail (8 per sleep); smart scopes and collections as sorted ID files searched in place. A cover whose list is not complete yet is held back (X7). New rules check every kept cover again before it shows. |
| P4 | Sharp covers | `topUp`, `decodeCovers` | The 400 x 600 catalog thumbnail (`downloadThumbnail`): the full-size OPDS cover needs an OPDS login the X4 does not have. Decoded with the radio off by `JpegToBmpConverter` to a 480 x 800 2-bit BMP for the panel's tone profile and Fit/Crop; the JPEG stays for a re-decode when those change. |
| P5 | At sleep | `SleepActivity::renderOrbifyPick`, `pickCover` | Reads `state.bin`, decides by `core::decide` (the shared table), draws the BMP; no ready cover: the open book's cover, then the default screen (F1). A cover that does not draw leaves the batch (F6). Never the network. |
| P6 | Text and battery | `drawExtras`, `prepareSleepBitmap`, `renderDefaultSleepScreen` | Bar: a band under the cover (the cover fits above it); Overlay: plates. Drawn on every grey plane; the redraw draws the battery level the first pass recorded. |
| P7 | X3 i18n | `tailnet_build.py`, `gen_i18n.py` (0039) | `ORBIFY_I18N_SKIP=SleepSettings.cpp` when the switch is 0, so its strings stay out of the X3's table. |
| F1 | Flash | | `x4-pro` 6,352,693 of 6,553,600 bytes (96.9%, +42,052 over 6,310,641); `x4-classic` 6,196,246 (94.5%, +41,680 over 6,154,566); `default` (X3) 6,512,919 (99.38%), unchanged byte for byte |

Settings UI rules shared with Android (the user's ruling, 2026-11-24): Pick From and Leave Out Scopes
each open straight onto one list of toggles (`orbify/SleepListActivity`, no screen in between, the
title in the header only), with **Library** as an item (R1c, X8: it stands alone either way). Pick
From is a set (`core::normalizeSources`, `candidates`: the picked lists in turn, one bag over every
picked library, scope and collection, each listed into `src_<l|s|c><id>.bin`); Leave out with
Library shows the current book. The rules are `shared/fixtures/sleep/cases.json` `sources`, which the
host test reads as Android's tests do. A row's status goes on its own line under the row (the list's
`subtitle`): Change Every's "Changes when the time is known" without Keep Clock in Sleep (R6), and
Leave Out Scopes' "Every book is left out: the current book shows". The web settings page types the
sets comma-separated. "Using the newest 500" is a log line only. The smart scopes and collections
appear in the lists after the first sleep sync saves `scopes.tsv`.

On a device (X4 Pro or X4, serial log): set Sleep Screen to BookOrbit Pick, Pick From, Change Every
(try Every sleep), then sleep with Wi-Fi in reach a few times. Expect per sleep:
`ORB Sleep: BookOrbit Pick -> cover <id> (every sleep, <n> ready, shown <k> times)` (or `-> current
book (0 of 0 covers ready)` on the first), then in the sync `ORB Sleep screen: batch <n> of 24 (<k>
fetched, <r> retired, ...)`, `ORB Sleep cover: book <id> decoded (crop|fit, 480x800)` and `ORB Heap:
after the sleep covers' decode ...`. Watch for `Sleep cover: decode waits for PSRAM`, `Sleep screen:
... failed (http ...)` and `Sleep: cover <id> did not draw`. With Wi-Fi off the sleeps keep drawing
covers from the card.

## The .194 X4 Pro catalog crash (patch 0040, 2026-11-24)

| # | Question | Cause (file) | Change |
|---|---|---|---|
| K1 | Crash while testing the cache-first catalog (C2): open a list offline, then ⟳ | The core dump (app `496c27226`, `assert failed: xQueueSemaphoreTake queue.c:1709 (( pxQueue ))`), decoded against a rebuild of the .194 tag: loopTask, `appendNextPageForCurrentList` → `loadFacetEntries(page 2)` → `fetchSectionEntries` → `fetchJson` → `HttpDownloader` → `SecureClient::connect` → `hostByName` → `lwip_getaddrinfo` → `tcpip_send_msg_wait_sem` → `sys_mutex_lock(&lock_tcpip_core)` with the lock NULL. The catalog opened from the cache with Wi-Fi never started this boot, so `tcpip_init()` (esp_netif_init) had never run; scrolling to a page the cache did not hold made a request. `fetchJson` ignored the write-through cache's plan: offline with nothing saved, `planRead` says neither serve nor fetch, and the request went out anyway. | `fetchJson` follows the plan (`orbify::cache::readStep`: Saved, Request, Miss; host test `cache_test`): a miss offline returns at once (`Catalog: not saved, and the network is off: <url>`), and the activity's `connectForMiss` joins Wi-Fi and asks again. Underneath, for every caller: before the TCP/IP stack exists the name lookup (`__wrap_lwip_getaddrinfo`, `tailnet: lookup of … refused: the network is not started`) and a new socket (`__wrap_lwip_socket`, ENETDOWN) fail as with Wi-Fi down, and `dns_clear_cache` takes no lock (`tailnet/shim/TailnetLwipLock.c` `tailnet_lwip_started()`, host test `lwip_lock_test.c`). The e2e scenario `catalog_cache_first` now taps ⟳ after the offline open: no request before Wi-Fi is up, then "Refreshing…" and "updated just now". |
| K2 | `Last run stopped at: wake checked` at the USB reset (device idle on USB, after the crash) | Not decided: the run that stopped was the one after the panic (its boot had already reported the crash record), and the trail had no step between "wake checked" and "setup done", which spans the I2C sensors and clock, the SD card and the panic report, settings and state, and the first screen's paint. | Four more steps (`orbify/core/BootTrail.h`, after the sleep steps so older words keep their meaning): clock read, SD card ready, settings loaded, first screen started (its paint not done). The stopped run's own reset is kept beside them and logged: `Last run stopped at: <step> (it started after reset=4(PANIC))`. Host test `boot_trail_test`. |
| K3 | Decoding a dump | Releases did not ship the ELF; a rebuild from the tag matches the release's code segments in layout (same IROM/IRAM sizes and addresses) but not its ELF SHA, so `esp-coredump` refuses it until the check is bypassed. | Every build uploads `<firmware>-v<version>.elf.gz` per reader with the image (artifact and release asset, in SHA256SUMS and the attestation): `gunzip`, then `esp-coredump --chip esp32s3 info_corefile -t raw -c <dump.bin> <elf>`. |

## One progress number and the layout rulings (patch 0041, 2026-11-24)

The user's rulings from Android (PR #58, [sqlite-cache](sqlite-cache.md) "Progress display" and
"Xteink: the same rule"; the settings layout rules of 11-24) brought to the X4 Pro and X4. The X3
builds none of the Full refresh part (`CROSSINK_TAILNET_ORBIFY_MIRROR` 0,1,1).

| # | What | Where | How |
|---|---|---|---|
| G1 | One number | `core/Mirror` `Plan::percent`, `badgeDue`, `badgeText` (host test `mirror_test.cpp` `progress`, `badge`) | `done * 100 / total`, kept at its highest: the plan's total grows while the root and the facet sections land (they add their lists), so the raw value can fall; 99 at most until the last step, 100 then. The % shown and the failures ride in the plan (`orbify-mirror 3`; a version 2 plan still resumes), so a wake or a reset never shows a lower one. |
| G2 | The walk no longer blocks | `orbify/Mirror` `Walk`; the catalog's `tickMirror`, the Home refresh boot's `tickMirror` | One request per `loop()`, in the catalog only with a list on screen and a second after the last press; the catalog answers between requests on its boot session. Before, the whole walk ran inside the ⟳ hold with "Full refresh · saving for offline N/M" repainted every 3 s. |
| G3 | The start popup | `orbify/RefreshBadge` `drawStartPopup` | "Full refresh in progress · about N% · you can keep reading and browsing", wrapped (the theme's popup is one line): shown once when a Full refresh starts by hand, closed by the next press (not the hold that started it) or after 5 s. A Full refresh resumed on opening the catalog shows the badge alone. |
| G4 | The badge | The catalog header's stamp slot; the refresh boot's content corner; Home's top bar | While it runs the stamp reads "37%" in a slot as wide as "100%", so the title never moves; each change is drawn into that rectangle only and pushed with a fast refresh (the panel changes only there; CrossInk has no windowed update), at most every 3 s. "Done" or "Done with N errors" for 5 s, then the stamp again. Home makes no requests: its header shows "Full refresh N%" from the plan while one is unfinished. |
| G5 | Home's hold | `BookOrbitHomeRefreshActivity` | The refresh boot runs the Home refresh, then the walk with the popup and the corner %; any press goes back to Home (the walk carries on in the catalog and at the sleep syncs), "Done" goes back by itself. Short press = Refresh, 1 s hold = Full refresh, as before. |
| G6 | Errors | the log, "Done with N errors" | No details view: the counts and each failed request are in the serial log. |
| L1 | Tailscale screen: the title once | `tailnet/ui/TailnetSettingsActivity` | The header names each page (Tailscale, Log in, Relay region, Setup help, Diagnostics); the first row is "Enabled", the Log in page and Setup help lose their bold second title. |
| L2 | Status under its setting | same | The connection status is Enabled's second line (the list's subtitle); the key-expiry advice, the logged-out note and "Peer list full" go under their rows, shortened to one line. Before, the status sat centred above the list and the notes in two lines under it. Taps use the theme's own row math (`wasListItemTapped`). |
| L3 | Checked, no change | Settings PIN (0023), Relay region | The PIN screen has one title, its message on its own line under the boxes and its hint above the number pad with room between them on every reader; Relay region has two rows, its note on its own line. Lists already keep the header still while they scroll (`drawList` under a fixed header). |
| F1 | Flash | | `x4-pro` 6,357,937 of 6,553,600 bytes (97.0%, +4,752 over 6,353,185); `x4-classic` 6,201,342 (94.6%, +4,552 over 6,196,790); `default` (X3) 6,513,263 (99.38%, -160 over 6,513,423: the Tailscale screen's shorter notes and the dropped "saving for offline" string) |

Tests: `mirror_test.cpp` (the % never goes down with a growing total, read back from the card;
version 2 plans; badge timing and words); simulator scenarios `catalog_full_refresh_percent` (one
popup, no per-step text, badge repaints only on change and 3 s apart, ink in the badge rectangle
and the title kept), `home_full_refresh_percent` (the hold's popup, a press back to Home, Home's
header %), `tailscale_layout` (ink: nothing between header and list, each status on its own line
under its row, clear of the row's value). The simulator's Tailscale shim answers "on and logged
in" with `ORBIFY_SIM_TAILSCALE=joined`.

## Measurements needed on a device

Item 1 adds only small requests on the sync's existing TLS session, so no new memory measurement
is needed beyond the sync's own log lines (`ORB Finish …`, `BookOrbit PUT … -> 200`).

Item 2, on an **X3** (`default`), serial log at 115200: read a downloaded book of a series past 90%,
then sleep (the sleep sync refreshes the card). The lines `ORB Series card parse: heap free …,
largest …` and `ORB Series card parsed (ok): <n>-byte reply, heap free …, largest …` give the heap
while the detail reply (the design's "24 KB saved page" case) is parsed. A `failed` there, or a
largest block under 16 KB, is the signal to stream the reply in smaller pieces.

Keep book copies current (patch 0034), on any of the three, serial log: sleep the reader with Wi-Fi in
reach. Expect `ORB Copy refresh: <n> queued (...)`, then per book `ORB Copy refresh: <path> (book <id>)
replaced: <old> -> <new> in <s> s`, then `<k> replaced, <m> waiting`. On the X3, the line to watch is
`heap too fragmented for a download`: that is when a copy waits for the next sleep instead.

Offline mirror (patch 0035), X4 Pro or X4, serial log: Settings › BookOrbit › Home › Full refresh.
Expect `ORB Mirror: Full refresh started, 0/<n> requests, 0% (free=…, maxAlloc=…)`, then (patch 0041)
`Home refresh: Full refresh popup: about 0%` and `Full refresh badge '<p>%'` lines, then `ORB Mirror: saved for offline: <l> lists, <s>
sections, <d> details, <n> requests (<f> failed) in <t> s`. The cache's own `Couldn't keep the reply`
or evictions in that run mean the 150-request plan is too big for 2 MB.

The sleep sync (patch 0037), X4 Pro, serial log: sleep with Wi-Fi in reach. Expect `Catalog requests
ride the sync's connection`, then the copy refresh and `ORB Mirror: due (...); a slice of 10 requests
in this sleep`, and no `esp-aes: Failed to allocate memory`. `waiting for heap (free=…)` and
`Transfer stopped: heap starved` say the floors in `orbify/HeapFloor.h` are met or not. A wake press
during the sync wakes the device within ~2 s (`Wake press not answered … restarting now` when the
watcher had to do it); `Sleep sync stopped: its time budget is spent` and `… past its 240 s budget;
restarting to sleep` mark the budget.

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
Expect `ORB Mirror: Full refresh started, 0/<n> requests (free=…, maxAlloc=…)`, a `Full refresh ·
saving for offline <i>/<n>` line every 10 s, then `ORB Mirror: saved for offline: <l> lists, <s>
sections, <d> details, <n> requests (<f> failed) in <t> s`. The cache's own `Couldn't keep the reply`
or evictions in that run mean the 150-request plan is too big for 2 MB.

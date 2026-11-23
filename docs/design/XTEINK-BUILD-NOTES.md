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
| E5 | Ratings shown as | `‹ 4 / 5 ›` text | CrossInk's UI fonts have no star glyphs (`fontconvert.py` intervals stop before U+2605). |
| E6 | X4 Pro touch on the rating | A tap on the rating row steps the rating and saves it | Five star targets need a custom-drawn row; the list routes row taps already (G32). |
| E7 | Undo | The status row's Confirm (or tap) toggles the finish through the reader's own `setBookCompleted` | Every path stays one: the queue job is removed or rewritten by `onFinishedChanged`. |
| E8 | Download & open | The catalog link gains `returnPath`; the catalog sets `reopenPath` from it, so a finished download opens the new book and Back or a failure returns to this book; the queue drains first (G33) | Reuses upstream's replace-and-reopen path; on the C3 it rides the one network boot. |
| E9 | Author row | The catalog link gains `author`; the catalog opens a listing with `author=<name>`, sort `series` | The server resolves the name (S16). |
| E10 | Rows that do not fit | Measured on the device each draw; dropped in the order suggestions, folder rows, author row, rating (`core/EndPagePlan.cpp`) | Landscape on a 480 px-tall panel cannot show every row; status, next and Home always stay. |
| E11 | X3 flash drop order | Switches `CROSSINK_TAILNET_ORBIFY_SUGGESTIONS` (2 → 0) then `..._AUTHOR_ROW` (1 → 0) | The CI gate names the order; flipping a switch is one line in `tailnet_build.py`. |
| E12 | XTC books | Keep upstream's page | The finish queue and the card are keyed by the EPUB's document hash and download index. |
| E14 | Flash | Item 2 adds **10.7 KB** on the X3 `default` (6,478,163 bytes, 98.85%, 42.8 KB under the gate), 7.5 KB on `x4-pro` (94.97%) and 6.8 KB on `x4-classic` (92.62%) | Under the gate: the X3 keeps its suggestions and author row. |
| E13 | "Get it at the next sync" (X4) | **Not in this release** | It needs a download queue in the sync; the page offers Download & open, Back to book, and the catalog's own retry. |

## Measurements needed on a device

Item 1 adds only small requests on the sync's existing TLS session, so no new memory measurement
is needed beyond the sync's own log lines (`ORB Finish …`, `BookOrbit PUT … -> 200`).

Item 2, on an **X3** (`default`), serial log at 115200: read a downloaded book of a series past 90%,
then sleep (the sleep sync refreshes the card). The lines `ORB Series card parse: heap free …,
largest …` and `ORB Series card parsed (ok): <n>-byte reply, heap free …, largest …` give the heap
while the detail reply (the design's "24 KB saved page" case) is parsed. A `failed` there, or a
largest block under 16 KB, is the signal to stream the reply in smaller pieces.

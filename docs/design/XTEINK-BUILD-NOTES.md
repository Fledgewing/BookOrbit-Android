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

## Measurements needed on a device

Item 1 adds only small requests on the sync's existing TLS session, so no new memory measurement
is needed beyond the sync's own log lines (`ORB Finish …`, `BookOrbit PUT … -> 200`).

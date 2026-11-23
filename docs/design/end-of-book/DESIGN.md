# End of book: mark done, rate, next in series

> **Approved 2026-11-22 PT** (every one-way door; mockups:
> [`mockups.html`](mockups.html), also published at https://claude.ai/artifact/QzDMmBphtiPiG41z44CBjk).
> Android code citations into `android/koreader-patch/2-orbit-android.lua` are to the patch as it
> was before roadmap 8a; that code now lives in `android/koreader/orbit.koplugin`
> ([`../orbit-plugin.md`](../orbit-plugin.md)).

Design for ROADMAP items 1 (**Mark done at end of book**) and 2 (**End-of-book screen**), both
platforms. Status: designing, revision 2; one-way doors approved 2026-11-22 PT (after the user's comments; changes listed in §12).
Mockups: `mockups.html` beside this file. Nothing here is built. This needs the user's approval
(AGENTS.md "Features and roadmap") before either item moves to building. Intended home once
approved: `docs/design/END-OF-BOOK.md`, linked from both ROADMAP rows.

Upstream citations are `file:line` at the pins in `tools/upstreams.lock`:
- BookOrbit v3.9.0 `c1dd6b4`: server paths are below `server/src/modules/` unless noted; the plugin
  is at `koreader-plugin/bookorbit.koplugin/`, same commit.
- CrossInk-Bookorbit v1.6.1+bookorbit.8 `d7b4aa8` (`upstream/crossink-v1.6`).
- KOReader v2026.07.1 `9192014`.

## 1. Outcome

- When a reader reaches the end of a book, on any Orbify device, the book leaves "Also reading"
  and BookOrbit records it as finished on the day it was finished. Offline, this is queued and sent
  later, in order, with no help from the reader.
- The end of a book offers:
  - a 1–5 star rating;
  - the next book in the series, opened directly or downloaded and opened (the device brings
    Wi-Fi up by itself);
  - the author's other books;
  - server-picked suggestions.
- A deliberate reread is never undone. A stale position from a second device can no longer turn a
  finished book back into "rereading", at least from our own devices.

## 2. What the server and firmware really do

| # | Finding | Source |
|---|---|---|
| S1 | A progress push derives status from the percentage. It sets `read` only at the library's `markAsFinishedPercentComplete` (default 98). The entry point is `autoUpdateReadStatusForProgress` at **`book/book.service.ts:2491`** (the brief said ~2576), called from `koreader/koreader.service.ts:535`. | `user-book-status/user-book-status.service.ts:263-301`, `user-book-status/reading-attempt.service.ts:270-380` |
| S2 | "Also reading" is the dashboard's `continueReading`: `readStatus: 'reading'`, sorted by recently read. A book pushed to 100% but still `reading` therefore stays there for good. | `koreader/koreader-catalog.service.ts:241-246`; plugin `bookorbit_board_widgets.lua:894` |
| S3 | Reread evidence is a push ≥10 points below the **latest progress from any device** for that file (`getLatestDeviceProgress` has no device filter). With no active attempt and progress below the finish threshold, the server opens an active attempt, and the status becomes `rereading`. | `koreader/koreader.service.ts:534`, `koreader/koreader.repository.ts:770-783`, `user-book-status/reading-attempt.service.ts:335-355` |
| S4 | The server's stale-push guard compares timestamps (`late = timestamp < newestKnown`). KOReader stamps a push with the time it is *sent*, so a stale position from a second device is not "late" and gets through. | `koreader/koreader.service.ts:263-268`, `:321-322` |
| S5 | A progress push to a book that is already finished, with no active attempt and no reread evidence, changes nothing. A late push dated no later than the finish day is folded into that read. | `user-book-status/reading-attempt.service.ts:289-312` |
| S6 | `POST /koreader/plugin/book-states`: the newest change wins at day granularity, and a same-day tie keeps the server's value. The same rule applies to `rating` and `reviewNote`. A device `complete` that wins becomes a manual `read` with `endedOn = statusModified`. | `koreader/koreader-plugin.service.ts:420-433`, `:461-490`; DTO `koreader/dto/koreader-plugin.dto.ts:215-252` |
| S7 | The plugin pushes state **before** progress. It then writes the server's state back into KOReader's summary. So a same-day "Mark as finished" in KOReader is dropped by S6, then reverted on the device by this write-back. **This is the Android half of the bug.** | plugin `bookorbit_book_sync.lua:286,734-826`, `bookorbit_sidecar.lua:401-420` |
| S8 | KOReader's own `markBook` sets `summary.status = "complete"` and `summary.modified = today`. `EndOfBook` is raised when the reader turns past the last page. `ReaderStatus:onEndOfBook` then shows the "end_document" dialog (or acts on `end_document_action`). The BookOrbit plugin has no `EndOfBook` handler, and its `auto_sync` defaults to off. | KOReader `frontend/apps/reader/modules/readerstatus.lua:38-166`, `:212-217`; `readerrolling.lua:914,943`; `readerpaging.lua:926,1043`; plugin `main.lua:107` |
| S9 | `PUT …/catalog/books/:id/read-status {status}` is unconditional and carries no date. It closes an active attempt as `completed` with `endedOn = today`. It is safe to retry. | `koreader/koreader-catalog.controller.ts:82-85`, `koreader/koreader-catalog.service.ts:518-522`, `user-book-status/reading-attempt.service.ts:150-205` |
| S10 | The plugin wraps it as `api:catalogSetReadStatus` at **`bookorbit_api.lua:705`** (the brief said :715), and `catalogSetRating` at `:709`. | plugin `bookorbit_api.lua:705-712` |
| S11 | **Ratings** are per user (`user_book_ratings`, key user+book), **whole stars 1–5**. The catalog DTO accepts any number 0–5, but storage is integer, and a completed read's rating is checked to be 1–5, so 0 or 4.5 fails; `null` clears. A rating attaches to the latest *completed* read, so send it **after** the status. If the book's metadata `rating` field is locked, the rating is silently skipped. | `db/schema/reader.ts:78-79,109,116-130`, `book/book.repository.ts:2494-2517`, `book/book.service.ts:2864-2878`, `dto/koreader-catalog-query.dto.ts:313-319` |
| S12 | **Reviews exist** (`user_book_notes.note`, up to 10 000 characters). A device reaches them only through book-states `reviewNote`. | `db/schema/reader.ts:144-163` |
| S13 | `catalogBook(id)` returns `seriesId/Name/Index`, `authors` (names), the user's `rating`, `readStatus`, `files`, `relatedSections` (`series`, `author` = "Also by this author", `similar` = "Similar books") and `seriesMembers`. | `koreader/koreader-catalog.service.ts:729-749`, `:1282-1316`, `:1366-1424` |
| S14 | `seriesMembers` holds only books the user can see (accessible libraries plus content filters, i.e. the kids' age limits). A restricted next book is absent, visible only as a gap. | `recommendation/recommendation.service.ts:127-164` |
| S15 | `match-check` returns `bookId` per known hash, and records unknown hashes as "unmatched" books on the server. | `koreader/koreader-plugin.service.ts:135-154` |
| S16 | The author list accepts an author **name**: `GET catalog/books?author=<name>` resolves it to a visible author and returns `authorSummary` (bio, photo). The plugin's author page is `Catalog:loadBooks({author = id or name, sort = "series"}, name, true)`, which renders the "authorpage" view. | `koreader/koreader-catalog.service.ts:466-476,490-491`, `dto/koreader-catalog-query.dto.ts:137-139`; plugin `bookorbit_catalog_lists.lua:866-868,1327-1348` |
| S17 | Suggestions honour the same limits: "Also by this author" and "Similar books" are filtered by accessible libraries and content filters, so they are safe on kids' devices. | `recommendation/recommendation.service.ts:78` (ANN candidates with `contentFilters`), `:183-184` |

Xteink (CrossInk 1.6.1):

| # | Finding | Source |
|---|---|---|
| X1 | The firmware pushes only `PUT /koreader/syncs/progress` plus plugin stats and exchanges, never status. **Network cost differs by chip** (this corrects the brief):<br>• BookOrbit sync always restarts into a network boot.<br>• The catalog and downloads restart only on the ESP32-C3 (X3 and the C3 X4).<br>• On the S3 readers (X4 Pro, X4 Classic), the catalog connects Wi-Fi and downloads in place. | `src/activities/reader/BookOrbitSyncActivity.cpp:1932-1948`; `src/activities/ActivityManager.cpp:979-1001`; `src/activities/browser/BookOrbitCatalogBrowserActivity.cpp:1235-1250` |
| X2 | `setBookCompleted(true)` is local only. It is called from the 99% prompt (`:3162-3176`, queued at `:6293`) and from two menus (`:4392-4396`, `:5362-5366`). **Reaching the End-of-Book screen (`:3217`) does not mark the book completed.** | `src/activities/reader/EpubReaderActivity.cpp:5959-5996`, `:3212-3292` |
| X3 | `EndOfBookOptions` is a full page after the last page. It lists up to 3 books from the same folder plus Home, and short Back returns to the last page. It already routes touch taps on its rows. | `src/activities/reader/EndOfBookOptions.h:14-78` |
| X4 | `BookOrbitDownloadIndex` maps a server book id to a path, and follows moves. | `src/BookOrbitDownloadIndex.h:23-58` |
| X5 | `fetchBookDetail` runs with a JSON filter when a book is downloaded. `BookOrbitBookQuery` already has `author` and `seriesId` filters. | `src/network/BookOrbitCatalogClient.cpp:593-606`, `.h:62-76` |
| X6 | The X4 has no battery-backed clock, so times are flagged as approximate until NTP. | `lib/BookOrbitSync/BookOrbitStatsQueue.h:7-30` |
| X7 | Screens: X4 Pro and X4 Classic are **480×800**, the X3 is **528×792** (portrait). | `lib/Xtc/Xtc/XtcTypes.h:31-32`, `platformio.ini:417,493`, `docs/user-guide.md:743` |
| X8 | **Touch: X4 Pro only** (GT911, plus a capacitive Home key). `x4-pro` builds with `CROSSINK_APP_CAP_TOUCH=1`; `x4-classic` and `default` (X3, C3 X4) build with `0`. At run time the code checks `gpio.hasTouch()`, and `wasTouchTap(nx, ny)` gives a tap point. | `platformio.ini:423-443,497-514,181-190`; `lib/hal/HalGPIO.h:100-127`; `include/DeviceCapabilities.h:25-41` |
| X9 | `BookOrbitCatalogLink{bookId, sectionId, title}` enters the catalog straight onto one book to download (BookOrbit Home uses it). On the C3 that is one network boot that downloads without a second restart. | `src/activities/browser/BookOrbitCatalogLink.h:6-11`, `ActivityManager.cpp:1004-1012`, `BookOrbitCatalogBrowserActivity.cpp:1241-1250` |

Android: the companion brings the network up on request and releases it after
(`Companion.netUp` / `Companion.netDone`, `android/koreader-patch/2-orbit-android.lua:1714-1741`).

## 3. Design overview

One shared model, two thin platform shells.

```
 reach end ──► mark finished locally ──► end screen (rating, next, author, suggestions)
                    │                            │
                    ▼  leave the book            ▼  "Download & open": Wi-Fi up → download → open
              FinishJob in the device's durable queue
                    │  next time the network is up (including the download's own connection)
                    ▼
   1 final progress   2 book-states complete   3 GET detail     4 PUT read-status read
     (as today)         + finish day             (guard)          (only if still needed)
                                                                  5 PUT rating (after 4)
                                                                  6 write server state back
```

**FinishJob** has the same fields on both platforms:
`{ book_id?, hash, finished_on (YYYY-MM-DD or null), final_pos {percentage, xpointer},
rating (nil | 1..5 | "clear"), status_seen, created_at, attempts, next_try_at, parked }`.
There is one job per book, and the newest local intent wins: **Undo** or a reread deletes an
unsent job.

### Drain algorithm (shared, table-tested from one fixture)

1. **Final position**, through the platform's normal progress route. At or above the threshold, the
   server finishes the book by itself (S1).
2. **book-states** `{hash, status:"complete", statusModified: finished_on}`. Android's plugin sends
   this itself from the summary (S7); the Xteink firmware sends it with its own call. It gives the
   exact finish day whenever the server last changed the book before that day (S6). It is skipped
   when `finished_on` is null.
3. **Guard read**, `GET catalog/books/:id`:
   - `read` → go to 5.
   - `rereading`, `on_hold` or `abandoned`, and different from `status_seen` → somebody chose
     that elsewhere after we finished. **Don't fight it**: skip to 5.
4. **`PUT read-status read`** covers the same-day tie and the threshold miss.
5. **`PUT rating`** if one was set. It goes after the status so it attaches to this read (S11).
6. **Write back.**
   - Android: apply `{complete, rating}` through `BookOrbitSidecar` so the plugin's next pull does
     not revert it, and mark the dashboard cache stale.
   - Xteink: set the "sent" flag.

**No `book_id`.** This happens with a sideloaded Xteink book. Use `match-check`, but only for a hash
the server already answered progress for, so no unmatched row is created (S15). If there is
still no id, step 2 alone carries the status and the rating.

**Errors.**
- Network, timeout or 5xx: retry with backoff (60 s doubling to 1 h), and again at every
  network-up. Park the job after 5 attempts; a manual sync retries parked jobs.
- 401: keep the job and show "Sign in to BookOrbit to send".
- 403, 404 or 400: drop the job and log it.

Every step is idempotent, so a crash between steps just replays.

## 4. Android: a bottom sheet over the last page

Hooks, all behind the patch's `Compat` probes, so a changed plugin or KOReader falls back to stock
behaviour:

| Hook | Use |
|---|---|
| `ReaderStatus:onEndOfBook` (wrap) | For a BookOrbit-linked book, show the Orbit sheet. Otherwise call the original. |
| `ReaderStatus:markBook` (wrap) | Every KOReader "Mark as finished" also creates a FinishJob, and "Mark as reading" deletes an unsent one. |
| Plugin lifecycle outbox drain and state | Ordering of steps 1–2 (`2-orbit-android.lua:2084-2140`). |
| `api:catalogBook`, `catalogSetReadStatus`, `catalogSetRating` | Steps 3–5, and the series and suggestion cache. |
| `StateManager.getBook(digest)`, `StateManager.onDeviceMaps().byBookId` | The book id, and whether a book is on the device. |
| `Catalog:downloadDefaultFile(detail, file)` | Download and open, through the plugin's own download (`bookorbit_catalog_download.lua:166`). |
| `Catalog:loadBooks({author = name, sort = "series"}, name, true)` | The author link opens the plugin's author page (S16). |
| `Companion.netUp/netDone` | Wi-Fi for "Download & open" and for the drain. |
| `BookOrbitSidecar.applyServerStateLive/Sidecar`, `rememberServerState` | Step 6. |

**Layout.** The sheet is anchored to the bottom, about 60% of the screen height (M8C: ~1120 of
1872 px), with a heavy top rule. The last page stays visible above it. Tapping that visible page,
or **Back to book**, closes the sheet and keeps the mark. It is drawn as one e-ink paint, with no
dimming (dimming looks muddy on e-ink).

Contents, top to bottom:

1. A status line, "✓ Marked as finished", with **Undo** on the right. Undo is a small outlined
   secondary button.
2. The title and author. **The author name is a link** to the author page.
3. Stars: whole stars 1–5; tapping the same star again clears it. Below them, a "Write a review"
   link that opens KOReader's Book status.
4. One "next" card, from the rule in §6.
5. One suggestion row ("Also by \<author\>" or "You might like").
6. The footer: **Back to book**, **Home**.

**Flow.**
1. Turning past the last page raises `EndOfBook`. This calls `markBook(true)` and opens the sheet.
   The series and suggestion data come from the Orbit detail cache, written when the book was
   opened and on every sync while online, so the sheet never waits on the network.
2. Leaving the book (Home, opening the next book, sleep or close) creates a FinishJob and drains it
   on the same network-up. Paging back to read the afterword is not undo; only **Undo** is.
3. A toast confirms: "Finished · sent", or "Finished · will send when online".

### Download & open (Android)

Tapping **Download and open** always does the whole job:

1. `Companion.netUp("eob_download")` turns Wi-Fi on and joins the tailnet.
2. The download runs, with progress in the card ("Connecting…", then "Downloading 45% · 0.8 of
   1.8 MB").
3. The pending FinishJob drains on the same connection, then the downloaded book opens.
4. `netDone` returns Wi-Fi to the user's mode.

If connecting fails (no known network in range within the companion's join cap), the card shows
**"Couldn't connect"** with **Try again** (primary) and **Get it at the next sync** (secondary).
The secondary choice downloads at the next network-up and announces the book with a toast. The
download itself never fails silently: a server error says so on the card, with Try again.

## 5. Xteink: the End-of-Book page, extended

Xteink keeps the **full page**. CrossInk's end screen is a page after the last page, not an
overlay: the last page is no longer in the frame buffer, and short Back already returns to it. A
480 px-wide sheet would leave rows too short for a 20 px UI font. See G26.

**Marking.** Reaching the End-of-Book page marks the book finished (`setBookCompleted(true)`), the
same as Android. The 99% prompt and the menu toggles stay as they are. All of them write the
FinishJob to `/.crosspoint/orbify_finish.bin`: fixed records, at most 16, written to a temp file and
renamed. Each record stores `final_pos`.

**Cache.** The series and suggestion card is `/.crosspoint/orbify_series/<bookId>.bin`, about 400
bytes. It holds:
- the next book (id, index, title, file id, size), the series-done or gap state, and the server
  status;
- up to 2 suggestions (id, title, source "author" or "similar", on-device);
- the first author name.

It is written when the book is downloaded (`fetchBookDetail`'s filter gains `series*`, `authors`,
`seriesMembers` and `relatedSections[].books[].{id,title}`). It is refreshed in any network session
while that book is the open book (sleep sync, manual sync, catalog). With no card, the page falls
back to upstream's folder suggestions.

**Rows, top to bottom (X4 Pro, X4 Classic):**
1. A status row: "✓ Finished · sends at next sync". It is selectable, and Confirm means **Undo**,
   labelled "Undo" at the row's right.
2. Rating (◀ ▶ changes it, Confirm saves).
3. **Next in series** (§6).
4. "Also by \<author\>" or "You might like": 1–2 rows from the cache, or folder rows if there is
   no cache.
5. **All books by \<author\> ›**, which opens the catalog filtered to the author through an extended
   `BookOrbitCatalogLink` carrying `author` (X5, S16).
6. Home.

Button hints sit at the bottom. On the X4 Pro (X8), every row is a tap target, the five stars are
five tap targets, and tapping the author name in the header opens the author list too. The
buttons keep working exactly as on the X4 Classic.

**Download & open (Xteink).** This uses the catalog link with `bookId` (X9) plus a new "open when
done" flag:
- **X4 Pro and X4 Classic:** the catalog connects Wi-Fi in place, with no restart. The FinishJob
  queue drains first, then the existing download-progress screen runs, and the book opens.
- **X3 and C3 X4:** one silent network boot straight onto the book (no second restart). The queue
  drains, then the download runs with progress, and the book opens.
- **Failure:** if joining fails, the page shows "Couldn't connect" with **Try again** and **Back to
  book**. The X4 readers also offer **Get it at the next sync**; the X3 doesn't (flash).

**X3 (reduced, 98.8% flash):**
- It gets the FinishJob queue and drain, the status row with Undo, Next in series (Open, or
  Download & open through the network boot), up to 2 server suggestions with the folder fallback,
  and "All books by \<author\>".
- The suggestion and author rows reuse the next-in-series row code and the existing catalog
  link, so they add little flash. This is the cheap win.
- Left out on the X3: the rating row, "Get it at the next sync", and touch (it has none).
- A CI gate fails the `default` env build above 99.5% of the app slot. If it fails, the
  suggestion rows go first, then the author row.

## 6. Next, suggestions and author (shared rules, one fixture set)

Given the current `seriesIndex = c` and the visible `seriesMembers`:

- **No series** (`seriesId` or `c` is null): no next card. Show the "author" suggestion first, then
  "similar".
- **Next** is the member with the smallest `seriesIndex > c` (ties go to the lowest id). Fractional
  indexes count. Mark it "Read" if `readStatus` is `read`.
- **Gap**: no member has an index in `(c, floor(c)+1]` while a later one exists. Show "Book
  ⌊c⌋+1 isn't in your library" and offer no later book (D3, accepted).
- **Series done**: no member after `c`. If every member is `read`, show "You've finished the
  series". Otherwise show "Last book · not read yet: Book N", with that book's action.
- **Suggestions**: the first books of `relatedSections` "author", then "similar", skipping the
  current book, the next book, and anything `read`. At most 1 on Android and at most 2 on Xteink.
  They are already age-filtered by the server (S17).
- **Author link**: `authors[0]`, opened by name (S16). A book with no author has no link.
- **Book actions**: on the device → **Open**; otherwise → **Download & open** (§4/§5). There is no
  "offline" state up front: the device tries to connect, and only a failed connection changes the
  card.

## 7. Multi-device stale pushes

- **Finished-book hold (our devices).** While a book is finished locally, a progress push ≥10
  points below its final position is held, unless the reader has turned ≥10 pages forward in this
  session or pressed Undo / Read again.
  - Android wraps the plugin's progress push (`hookPluginPagePush`, `2-orbit-android.lua:2903`).
  - Xteink applies the hold to automatic syncs only.
- Clients we don't control (the web reader, Kobo) can still open a reread. That is upstream
  behaviour, recorded in `docs/server-contract.md`, and we never "repair" a server `rereading`.

## 8. Self-grill log

Two-way doors are settled here; one-way doors are flagged and listed in §11. Entries G25–G33 are
new in revision 2. Superseded entries are kept and marked.

| # | Question | Options | Decision | Why | Door |
|---|---|---|---|---|---|
| G1 | What triggers "finished"? | end event; threshold; end event + manual marks | **End event + every existing manual mark** | The strongest signal, no threshold to tune. Manual marks hit the same bug (S7, X2). | two-way |
| G2 | Mark silently at the end, or ask? | ask; mark + visible undo | **Mark, with Undo** | One fewer tap per book. | one-way (D1, approved 2026-11-22) |
| G3 | When is it sent? | at the end event; on leaving | **On leaving** | Gives an undo window. A sent `read` can't be cleanly undone (S9). | two-way |
| G4 | The server says rereading/on_hold/abandoned at drain | overwrite; skip | **Skip if it changed after we finished** | Don't fight a deliberate choice made elsewhere. | two-way |
| G5 | Request order | read-status first; position first | **Position → book-states → guard → read-status → rating** | S5, S6, S11. | two-way |
| G6 | book-states, read-status, or both? | one; both | **Both** | Correct date when possible, correct status always. | two-way |
| G7 | Android queue location | the plugin's outbox; our own file | **Own file**, drained after the plugin's outbox | The plugin's phases are fixed upstream code. | two-way |
| G8 | Beating the plugin write-back | patch the sync; write back ourselves | **Write back through `BookOrbitSidecar`** | Uses the plugin's own state functions. | two-way |
| G9 | Stale second-device push | ignore; server fix; device hold | **Device-side hold** | The server ignores contributions. | two-way |
| G10 | Hold threshold | any lower push; ≥10 points; time window | **≥10 points, released by ≥10 forward page turns** | Mirrors S3; no time gate. | two-way |
| G11 | Reuse KOReader's BookStatusWidget? | reuse; replace; hybrid | **Replace at the end, reuse for reviews** | It is a stats page with no next action. Its stars write `summary.rating`, so both stay consistent. | two-way |
| G12 | Rating scale | half; whole 1–5 | **Whole 1–5; tap the same star to clear** | S11. | two-way |
| G13 | Rating route | book-states; PUT | **PUT after status**, book-states fallback | PUT is unconditional. | two-way |
| G14 | Ratings and reviews from kids' accounts reach the server | yes; local only | **Yes, rating on the end screen** | It is the reader's own per-user data. | one-way (D2, approved 2026-11-22) |
| G15 | Restricted or missing next book | skip; say so; nothing | **"Book N isn't in your library", no skip** | Accepted by the user, who confirmed one message is right because the device can't tell the cases apart. | settled (was D3) |
| G16 | Series data without network | live only; cache | **Cache** (Android detail cache, Xteink SD card) | The screen must draw instantly. | two-way |
| G17 | Xteink: network at the end of a book just to send? | yes; next session | **Next session**, or the "Download & open" connection | No surprise restart while reading the end screen. | two-way |
| G18 | Xteink book id lookup | index; match-check; hash-only | **Index → match-check (known hashes only) → hash-only book-states** | Covers sideloads without unmatched rows. | two-way |
| G19 | Xteink clock unset | send the date; drop it | **Drop it** | Better a drain-day date than 1970. | two-way |
| G20 | X3 scope | full; mark-done only; reduced | *Superseded by G31* | | |
| G21 | Offline "next" on the server | queue by default; cached list | *Superseded by G27*: the user rejected the default queue ("Wait randomly?") | | |
| G22 | KOReader's `end_document_action` | respect it; override for linked books | **Override for linked books**, with an Orbit setting | Our sheet is the feature. | two-way |
| G23 | "Also reading" right after the finish | edit the cache; refetch | **Mark stale and refetch**; local overlay is ROADMAP #3 | | two-way |
| G24 | Xteink patch shape | one big patch; hooks + new file | **Small hooks + `OrbifyEndOfBook.{h,cpp}`** | Keeps the per-line patch series reapplicable. | two-way |
| G25 | Undo label | "Not finished"; "Undo"; "Mark as reading" | **"Undo"**, a secondary outlined button (Android) or the status row's right label (Xteink) | "Not finished" beside "Marked as finished" reads like a second status (user's comment). "Mark as reading" would imply a reread. | two-way |
| G26 | Shape of the end screen | full screen; bottom sheet | **Android: bottom sheet (~60%), last page visible above. Xteink: full page** | Android: KOReader draws the end dialog over the page, and the user expects the book to stay in view. Xteink's end screen is a page after the last page (X3 finding), and a sheet at 480 px leaves rows too short. | two-way |
| G27 | Offline "next" | default queue; connect on demand | **"Download & open" always connects** (companion `netUp`; Xteink catalog link, a network boot on the C3) and shows progress, then opens | Answers the user's question: the reader never waits for an unknown sync. | two-way |
| G28 | Keep "Get it at the next sync" after a failed connect? | drop; keep as secondary | **Keep as secondary on Android and X4; drop on X3** | Useful out of range (car, holiday): it arrives without remembering to retry, announced by a toast. The X3 lacks flash for a download queue. | two-way |
| G29 | Author link target | Android: plugin author page vs. a list; Xteink: catalog list | **Android: `Catalog:loadBooks({author=name, sort="series"})`, the plugin's own author page with bio (S16). Xteink: catalog filtered by author name** | Reuses existing views; the server resolves names, so no author id is needed. | two-way |
| G30 | Xteink suggestions | folder; server; both | **Server ("Also by" / "You might like"), cached with the series card; folder only without a cache** | Same as Android (user's comment), and age-filtered by the server (S17). | two-way |
| G31 | X3 scope (revised) | as G20; add suggestions and author | **Mark-done, Undo, next (Open / Download & open), up to 2 server suggestions with folder fallback, author row. No rating, no "next sync" download, no touch** | Suggestions, author and next share one row type and the existing catalog link, so they cost little. The rating needs a new input mode. A CI size gate decides, with a fixed drop order. | two-way |
| G32 | Touch on Xteink | ignore; add tap targets | **X4 Pro: rows, stars and author name tappable; buttons unchanged** | X8: only `x4-pro` builds touch. `EndOfBookOptions` already routes row taps. | two-way |
| G33 | Where the queue drains on Xteink | sync sessions only; also "Download & open" | **Every network session, the download's included, before the download** | The connection is already paid for, and the order stays final position → status. | two-way |

## 9. Data and endpoints used

| Step | Android (via plugin API) | Xteink (firmware) |
|---|---|---|
| Final position | plugin lifecycle sync → `POST /koreader/plugin/progress` | `PUT /koreader/syncs/progress` |
| Status with day | plugin `POST /koreader/plugin/book-states` | new `POST /koreader/plugin/book-states` |
| Guard, series, suggestions | `api:catalogBook(id)` | `GET /plugin/catalog/books/:id` with a JSON filter |
| Status fallback | `api:catalogSetReadStatus(id, "read")` | new `PUT /plugin/catalog/books/:id/read-status` |
| Rating | `api:catalogSetRating(id, n\|null)` | new `PUT …/rating` (X4 only) |
| Author list | `Catalog:loadBooks({author = name})` → `GET catalog/books?author=` | catalog link with `author` → `GET catalog/books?author=` |
| Download | `Catalog:downloadDefaultFile` | catalog link `bookId` + open-when-done |
| Id lookup | `StateManager.getBook(digest)` | `BookOrbitDownloadIndex` → `POST /plugin/match-check` |

Local state:
- Android: `orbit-finish-queue.lua`, `orbit-detail-cache/<bookId>.lua`.
- Xteink: `/.crosspoint/orbify_finish.bin`, `/.crosspoint/orbify_series/<bookId>.bin`.

`docs/server-contract.md` gains S3–S7 and S11–S17 before building starts.

## 10. Tests (planned, not written)

Shared fixtures in `shared/fixtures/bookorbit/`, recorded and then scrubbed:

| File | Covers |
|---|---|
| `catalog-book.series-middle.json`, `…series-fractional.json`, `…series-gap.json`, `…series-last-all-read.json`, `…series-last-unread-earlier.json`, `…no-series.json`, `…no-author.json` | the next, gap, done, suggestion and author rules |
| `catalog-books.author-by-name.json` | the author list with `authorSummary` |
| `book-states.tie-kept-server.json`, `book-states.applied.json` | S6 |
| `read-status.ok.json`, `rating.ok.json`, `errors/{401,403,404,500}.json` | step outcomes |
| `finish-cases.json` | table: local job + server state + network → expected requests and job state |

- **Android, `test_logic.lua`:**
  - the next, suggestion and author picker;
  - the FinishJob machine;
  - the stale-push hold;
  - crash safety of the queue file.
- **Android, `test_flows.lua`:**
  - EndOfBook → sheet → leave → drain order;
  - Undo before leaving sends nothing;
  - Download & open: `netUp` → progress → drain → open → `netDone`;
  - a failed connect shows Try again and the next-sync option;
  - a non-linked book falls through to KOReader's dialog;
  - the author link calls `loadBooks` with the name;
  - tapping above the sheet closes it with the mark kept.
- **Android, `plugin_compat.lua`:** probes for every hook in §4, including `Catalog:loadBooks` and
  `Companion.netUp`.
- **Xteink host tests:**
  - the same picker and `finish-cases.json` in C++;
  - the record files under power loss;
  - layouts fit 480×800 and 528×792 with the longest strings;
  - X4 Pro tap targets map to rows and stars;
  - the catalog link with `author` and with open-when-done round-trips through the C3 network
    boot payload.
- **Builds:** the X3 `default` env stays under 99.5%.
- **Acceptance, on devices:**
  - Finish at 97% on an M8C and on an X4: the book leaves "Also reading" elsewhere, with the
    right finish day.
  - A stale second reader leaves the server at `read`.
  - "Download & open" with Wi-Fi off opens the next book with no other step, on the M8C, an X4
    Pro and an X3.

## 11. One-way doors for the user

None open. All three were approved by the user on 2026-11-22 PT:

- **D1, approved.** Reaching the end marks the book finished on the server without asking. On
  every Orbify reader, turning past the last page marks the book finished, and BookOrbit gets
  "read" with the finish day when the reader leaves the book. Until then, **Undo** cancels it.
  A per-device Orbit setting turns auto-marking off; it is on by default.
- **D2, approved.** Ratings given at the end of a book are written to the reader's BookOrbit
  account, kids' accounts included: whole stars 1–5, attached to this read, replacing any earlier
  rating by that account.
- **D3, approved.** When the next book isn't available, show "Book N isn't in your library" and
  don't skip ahead.

## Delivery (Android)

Items 1–3 (mark done at the end of the book, the end-of-book screen, and the local-first home)
ship together in the same Android release. They are built in the new **Orbit KOReader plugin**
(ROADMAP 8a, being built now), not in the user patch `2-orbit-android.lua`. The hooks in §4 are
written as patch `Compat` probes; carry them into the plugin's own hook layer, and point the
patch-file references in §4 and §10 at the plugin.

## 12. Changes in revision 2

- **Undo:** "Not finished" is renamed **Undo** and styled as a secondary action (G25).
- **Layout:** Android is now a bottom sheet with the last page visible above it; Xteink keeps the
  full page (G26).
- **Offline:** the default offline queue is gone. **Download & open** brings Wi-Fi up itself and
  shows progress. "Couldn't connect" offers Try again, plus "Get it at the next sync" as a
  secondary choice (not on the X3) (G27, G28, G33).
- **Author link** on all platforms (G29, S16).
- **Xteink suggestions:** the same server suggestions as Android, with the folder as fallback
  (G30, S17).
- **X3 scope** revised (G31).
- **Touch:** X4 Pro only, confirmed (X8); tappable rows and stars, buttons unchanged (G32).
- **Correction:** only the ESP32-C3 readers need a network boot for the catalog and downloads.
  BookOrbit sync restarts on every reader (X1).

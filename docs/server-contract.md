# BookOrbit server contract

The BookOrbit endpoints Orbify relies on and how the server really behaves, read from the source
at the pinned version (`tools/upstreams.lock`: bookorbit/bookorbit v3.9.0, `c1dd6b4`). Links go
to that commit. Add a finding here, with its citation, before a design depends on it.

## Who calls what

- **Android**: the BookOrbit KOReader plugin makes every server call; the Orbify patch hooks the
  plugin's API class (`bookorbit_api.lua`) and never calls the server itself. The plugin's routes
  are in [`koreader-plugin/bookorbit.koplugin/bookorbit_api.lua:629-781`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/koreader-plugin/bookorbit.koplugin/bookorbit_api.lua#L629-L781).
- **Xteink**: CrossInk-Bookorbit's own client calls the catalog and exchange routes below, but
  pushes positions with KOSync's `PUT /koreader/syncs/progress` (`lib/BookOrbitSync/BookOrbitSyncClient.cpp`
  in `upstream/crossink-v1.6`). The overlay only makes the server reachable over Tailscale.
- Every route is under `/api/v1` ([`main.ts:74`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/main.ts#L74)).

## Endpoints

Plugin routes are under `/koreader/plugin`
([`koreader-plugin.controller.ts:30`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader-plugin.controller.ts#L30)),
catalog routes under `/koreader/plugin/catalog`
([`koreader-catalog.controller.ts:25`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader-catalog.controller.ts#L25)).

| Route | Used for |
|---|---|
| `POST /koreader/plugin/progress` | Reading position pushes, Android (bulk) |
| `PUT /koreader/syncs/progress` | Reading position pushes, Xteink ([`koreader.controller.ts:69`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader.controller.ts#L69)) |
| `POST /koreader/plugin/book-states` | Read status from KOReader (Android) |
| `GET /koreader/plugin/catalog/dashboard`, `/dashboard/sections/:type`, `/sections/:section` | Home and its sections |
| `GET /koreader/plugin/catalog/books`, `/manifest` | Lists (Orbify's series and author views read them) |
| `GET /koreader/plugin/catalog/books/:id` | Book detail, including `seriesMembers` |
| `PUT /koreader/plugin/catalog/books/:id/read-status`, `/rating` | Status and rating set on the device |
| `GET /koreader/plugin/catalog/files/:fileId/download` | Book downloads |

## Progress finishes a book only at the library's threshold

A progress push sets the status from the percentage: `read` once it reaches the library's
`markAsFinishedPercentComplete`, `reading` from the reading threshold, else `unread`.

- The threshold is per library, default **98**:
  [`db/schema/libraries.ts:50`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/db/schema/libraries.ts#L50),
  [`library.service.ts:194`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/library/library.service.ts#L194).
- Both progress routes share one path ([`koreader.service.ts:291`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader.service.ts#L291),
  [`:484`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader.service.ts#L484)), then
  [`koreader.service.ts:535`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader.service.ts#L535)
  → [`book.service.ts:2491-2506`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/book/book.service.ts#L2491-L2506)
  → [`user-book-status.service.ts:274-279`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/user-book-status/user-book-status.service.ts#L274-L279)
  ([`progress-threshold.utils.ts:3`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/common/utils/progress-threshold.utils.ts#L3)).
- So a book read to its last page but pushed below the threshold stays "reading" (ROADMAP "Mark
  done at end of book").

## Reread evidence: a push 10 or more points lower

A progress push at least **10 percentage points below** the previous one counts as strong
evidence of a reread
([`koreader.service.ts:534`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader.service.ts#L534);
the same rule for web and audio progress,
[`book.service.ts:2464`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/book/book.service.ts#L2464)). Jumping back in a
finished book, or a stale position from another device, can start a reread.

- "Previous" is the **latest progress from any device** for that file: `getLatestDeviceProgress`
  has no device filter ([`koreader.repository.ts:770-783`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader.repository.ts#L770-L783)).
- With no active attempt and progress below the finish threshold, that evidence opens a new
  attempt and the status becomes `rereading`
  ([`reading-attempt.service.ts:335-355`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/user-book-status/reading-attempt.service.ts#L335-L355)).

## book-states: newest date wins, same-day ties go to the server

`POST /koreader/plugin/book-states` applies a device's status only when its modification date
is newer than the server's at **day granularity**; on the same day the server's value stays
([`koreader-plugin.service.ts:469-471`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader-plugin.service.ts#L469-L471)).
A device change made the same day as a server change is dropped.

## read-status is unconditional

`PUT /koreader/plugin/catalog/books/:id/read-status` sets the status as a manual status with no
date or conflict check
([`koreader-catalog.controller.ts:82-85`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader-catalog.controller.ts#L82-L85),
[`koreader-catalog.service.ts:518-522`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader-catalog.service.ts#L518-L522)).
Settable values: `unread`, `want_to_read`, `reading`, `on_hold`, `read`, `abandoned`
([`dto/koreader-catalog-query.dto.ts:36-42`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/dto/koreader-catalog-query.dto.ts#L36-L42)).
It is the one way to mark a book done regardless of the threshold.

## Series members in book detail

`GET /koreader/plugin/catalog/books/:id` carries `seriesMembers`, the other books of its series
([`koreader-catalog.service.ts:747`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader-catalog.service.ts#L747),
[`:1372-1424`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader-catalog.service.ts#L1372-L1424)).

## The stale-push guard compares send times

A push is "late" only when its timestamp is older than the newest one the server knows
([`koreader.service.ts:263-268`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader.service.ts#L263-L268)). KOReader stamps a push with the time it is
**sent**, not when the position was reached ([`koreader.service.ts:321-322`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader.service.ts#L321-L322)), so
a stale position from a second device is not late and gets through (and, with the rule above, can
start a reread). End-of-book design: a device-side hold.

## A push to a finished book changes nothing

With no active attempt, no reread evidence and the book's latest read completed, a push dated no
later than that read's end joins it as backlog; any other such push without meaningful activity
is ignored ([`reading-attempt.service.ts:289-312`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/user-book-status/reading-attempt.service.ts#L289-L312)).

## book-states details

- A device `complete` that wins (see the tie rule above) becomes a manual `read` with
  `endedOn = statusModified`, the day the device gave
  ([`koreader-plugin.service.ts:462-489`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader-plugin.service.ts#L462-L489)).
- `rating` and `reviewNote` follow the same newest-day rule
  ([`koreader-plugin.service.ts:420-433`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader-plugin.service.ts#L420-L433); DTO
  [`koreader-plugin.dto.ts:215-252`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/dto/koreader-plugin.dto.ts#L215-L252)).
- The Android plugin pushes state **before** progress
  ([`bookorbit_book_sync.lua:286`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/koreader-plugin/bookorbit.koplugin/bookorbit_book_sync.lua#L286)) and then writes the server's state back into KOReader's
  summary ([`bookorbit_sidecar.lua:401-420`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/koreader-plugin/bookorbit.koplugin/bookorbit_sidecar.lua#L401-L420)). So a same-day "Mark as finished" in KOReader
  is dropped by the tie rule and then reverted on the device.

## read-status closes the read

Setting `read` through `PUT …/read-status` closes an active attempt as completed with
`endedOn` = today ([`reading-attempt.service.ts:150-205`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/user-book-status/reading-attempt.service.ts#L150-L205)); it is safe to
retry. The plugin wraps it as `catalogSetReadStatus`, and the rating route as `catalogSetRating`
([`bookorbit_api.lua:705-712`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/koreader-plugin/bookorbit.koplugin/bookorbit_api.lua#L705-L712)).

## Ratings are whole stars, per user, attached to the latest finished read

- One rating per user and book (`user_book_ratings`, [`reader.ts:116-130`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/db/schema/reader.ts#L116-L130)),
  and each read keeps its own 1-5 stars ([`reader.ts:78-79`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/db/schema/reader.ts#L78-L79)).
- The catalog DTO accepts any number 0-5 ([`koreader-catalog-query.dto.ts:313-319`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/dto/koreader-catalog-query.dto.ts#L313-L319)),
  but only **whole stars 1-5** are stored; `null` clears. Send the rating **after** the status so
  it attaches to this read.
- A book whose metadata `rating` field is locked skips the rating silently
  ([`book.service.ts:2864-2878`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/book/book.service.ts#L2864-L2878)).

## Reviews

A user's review is `user_book_notes.note`, up to 10,000 characters
([`reader.ts:144-163`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/db/schema/reader.ts#L144-L163)). A device reaches it only through book-states
`reviewNote`.

## Continue reading is readStatus "reading"

The dashboard's `continueReading` is the books with `readStatus: 'reading'`, most recently read
first ([`koreader-catalog.service.ts:241-246`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader-catalog.service.ts#L241-L246)). A book pushed to 100% but still
`reading` stays there.

## Book detail, series, author and suggestions

- `GET …/catalog/books/:id` ([`koreader-catalog.service.ts:729-749`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader-catalog.service.ts#L729-L749)) returns
  `seriesId/Name/Index`, `authors`, the user's `rating`, `readStatus`, `files`,
  `relatedSections` (`series`, `author`, `similar`) and `seriesMembers`.
- `seriesMembers` holds only books the user can see: accessible libraries plus content filters
  (kids' age limits), so a restricted book is just absent
  ([`recommendation.service.ts:127-164`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/recommendation/recommendation.service.ts#L127-L164)).
- "Also by this author" and "Similar books" use the same limits
  ([`recommendation.service.ts:78`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/recommendation/recommendation.service.ts#L78),
  [`recommendation.service.ts:183-184`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/recommendation/recommendation.service.ts#L183-L184)).
- `GET catalog/books?author=<name>` takes an author **name**, resolves it to a visible author and
  returns `authorSummary` ([`koreader-catalog.service.ts:466-491`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader-catalog.service.ts#L466-L491),
  [`koreader-catalog-query.dto.ts:137-139`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/dto/koreader-catalog-query.dto.ts#L137-L139)).

## match-check records unknown hashes

`POST /koreader/plugin/match-check` returns `bookId` for each known hash and records every
unknown one as an "unmatched" book on the server
([`koreader-plugin.service.ts:135-154`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader-plugin.service.ts#L135-L154)). Ask only for hashes the server already
knows.

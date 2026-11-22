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

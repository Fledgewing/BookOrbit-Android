# F12-A: Android library boundary

Android implementation authorised by the maintainer on 2026-11-25, on `feature/0.12`.
The approved design is on `origin/design/booksync-home`: DESIGN.md §3.5, §6,
“Companion-published Home read model”, §8.5; DESIGN-NOTES.md §11–12 (revision 8+),
layout.schema.json and prototype.html. This implements the interface foundation;
no new Home or widget is exposed yet. X4 Pro, X4 and X3 follow later. No releases,
tags, device access or published workflow runs are part of this slice.

## Performance ruling, 2026-11-25

“For each screen and widget” there must be strict performance limits, with work
handed to the companion wherever possible. Filtering, local fallback, sorting,
grouping, counts, search and joins run in Kotlin/SQLite. Lua only reads ready
windows. `logic/budgets.lua` is shared with the layout engine and widget registry (PR #139). Library calls
use its canonical widget IDs (`continue-reading`, `booklist`, `library`) and
`Budgets.check`/`Budgets.span`; there is no separate set of caller limits. A new screen/widget must register before obtaining a library context.

Per call: at most 24 display rows (or the smaller caller/requested limit), at most 16 KiB
decoded, zero subprocess spawns and zero network calls. Per widget snapshot:
16 KiB across all its calls, with aggregate rows also checked against its registry budget. Per Home paint: at most 128 KiB decoded in total and at most one batch, up to 16 deduplicated requests (128 KiB
command ceiling). Render tests check the actual ready-row decode byte count and
batch sends; oversized database blobs are excluded by SQL before decoding. Worker
materialization rejects oversized results with `error=budget`, never silently
truncates an allegedly complete result. Info-level read/paint/materialization
spans report milliseconds, rows/bytes where applicable. Device targets, pending
maintainer confirmation: cached Home <500 ms, widget <50 ms, cached library
window <30 ms, editor move <100 ms. Host tests establish counters, not these timings.

## Reuse and coexistence

The implementation extends the existing modules rather than building another cache.
References below identify the reused code at baseline `bfb2930`:

- `ko/db.lua:64`: existing read-only connection and 20 ms busy timeout.
- `ko/store.lua:38`: owner, reading and busy/memo gates; `:92` prepared reads.
- `ko/cache.lua:105`, `:379`: current owner/client bridge, private to the adapter binding.
- `ko/copies.lua:57`, `:75`: account-scoped tracked-file ledger, checked by the worker.
- Companion `CacheStore.kt:20`, `:209`, `:216`: same database, canonical books and lazy details.
- `BulkCatalog.kt:6`, `FastCatalogRefresh.kt:291`: existing generation tables and atomic publication.
- `Worker.kt:36`, `:145`: existing ordered PATCH worker queue, no new service or daemon.
- `Core.kt:43`: existing plugin/companion contract, unchanged sender verification.

`logic/caps.lua:27` resolves companion-service capabilities, which are distinct
from library-adapter capabilities; it remains the service trust gate.
`logic/home_plan.lua:20` decides app/Home routing and `logic/sheet_layout.lua:58`
lays out sheets. Neither queries books, so neither is duplicated here.
`ko/home.lua` delegates its entire legacy screen to the upstream plugin. There
is no mechanical book-query swap on that route. It remains the explicit legacy
coexistence path while the owned Home is built separately.

The guard scans every Lua file under `ko/`, including nested files. Only the
named adapter/transport files can add backend references. The exact pre-existing
legacy reference lines are frozen in `test/library-legacy-boundary.txt`; adding
another occurrence fails. Removing legacy lines is allowed. Future owned screens
must not be added to this exception list. This is a migration seam, not a claim
that the old Home has already been ported.

## Calling the interface

```lua
local paint = Library.paint("home")
local shelf = paint:widget("booklist")
local rows = shelf:window("reading", {sort="last", dir="desc"}, 0, 4)
local summary = paint:widget("library"):counts("library/all")
paint:flush() -- one batched PATCH; no waiting and no subprocess
```

Operations: `capabilities`, `window`, `book`, `counts`, `progress`, `status`, `job`.
All calls inherit the caller's declared budget. Reads after flush and repeated
flush fail. The caller paints cached results immediately and may schedule a later
bounded read; it must obey the reading gate. No automatic UI show/repaint is added.
Repeated ready requests are coalesced for 30 seconds; missing results retry after
two seconds. A first, unmaterialized request returns `pending=true` with no empty-state claim.
The worker's answer distinguishes `Not saved yet` (missing coverage) from
`No books` (a complete, empty source). The result carries its own generation and
snapshot timestamp; publication time is never substituted for refresh time.

String sources: `library/all` (alias `all`), `reading`, `want-to-read`,
`recently-added`, `finished`, `on-device`, `search`. Contextual sources:
`{kind="list"|"series", key=<opaque key>}` and `{kind="author", key=<display name>}`.
Book/list/series/file/job keys are account-namespaced and never contain credentials,
server addresses or delivery locators. `job` currently reports the existing
refresh queue, using the key for `job:refresh`; it does not invent download jobs.

Filter values are semantic strings, not prototype control indices:
`show=all|unread|reading|finished|rereading|on-hold|abandoned|unknown`, boolean `wtr`,
`where=anywhere|on-device|server-only`, arrays `author`, `series`, `tags` (OR within
a field, AND between fields), `length` (alias `len`), `rating`, `added` ranges
`{min=…,max=…}` (inclusive; added uses ISO date/time strings), `group=none|author|series`,
`sort=order|match|title|author|last|added|rating|series`, `dir=asc|desc`, and text `q`.
Unknown fields/values fail explicitly. Unknown values do not satisfy a refinement.
Reading includes rereading; unknown statuses retain their raw value for safe display.
Grouping is disjoint by first author/series, with explicit unknown labels. Groups
sort by label; rows use the requested sort, nulls last, and a stable identity tie.
Search best-match ranks exact title, title prefix, title substring, then other
matching fields. All filtering, grouping and counts precede pagination.

The adapter translation plan targets the existing cached `BulkCatalog.selection`
vocabulary; unsupported fields remain residuals. All predicates are evaluated
locally by the worker today, so offline and future pushdown results share the
same semantics. No new server API behavior is claimed and no network is performed.
Lists advertise `save=false`; download and state writes stay disabled here so this
slice cannot create a second sync writer.

## Coverage and next slice

The projection table is additive and holds at most 64 small results in the owned
DB. Account changes wipe it alongside the catalog. Reads never change ownership.
A worker batch checks owner again inside each transaction. Incomplete secondary
membership stays unavailable until the generation's existing completion marker.
Freshness is conservatively the base generation's successful timestamp.

On-device data comes from the existing account-scoped Copies ledger: coverage is
`tracked-files`, not a claim that unlinked local books have been scanned. Missing
ledger coverage stays `Not saved yet`; existing paths are checked in Kotlin.
List rank is persisted in existing membership context on the next Full refresh;
older cached lists fall back to stable identity order. Detail and cover availability
are separate: lazy saved details can supply plain text and opaque file descriptors;
no URL leaves the adapter, and missing covers remain unavailable.

Next slices can build the host and starter widgets against this API, register their
budgets, and batch their windows. They should prime the initial windows when a layout
is installed, reuse the same paint context, and add a quiet completion/re-read hook
without repainting while reading. Later increments can add the owned local-file
ledger, cover references, source-specific watermarks, list discovery, refresh/job
controls and richer detail without exposing backend payloads to widgets. The current
adapter uses the active published bulk generation; partial legacy-only catalogs
remain `Not saved yet` until Full refresh publishes a generation.

## Inherited CI prerequisite

Initial PR validation exposed a pre-existing patch-application failure in Xteink
patch 0056. The prerequisite was subsequently repaired in main PR #138 and merged
into `feature/0.12`. This slice rebases onto that prerequisite; it contains no
firmware changes. Existing cross-platform CI coverage remains in force.

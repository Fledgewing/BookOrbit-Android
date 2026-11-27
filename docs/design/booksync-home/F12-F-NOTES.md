# Android reading statistics foundation (F12-F)

Android implementation authorised by the maintainer on 2026-11-25. X4 Pro, X4 and
X3 remain deferred to the firmware implementation. The approved design and
prototype on `origin/design/booksync-home` remain the destination; no new screen
or device acceptance is claimed by this standalone increment.

## Reuse and boundary

- `ko/library.lua:23` retains bounded reads, per-instance accounting and one host batch.
  `Library:readingStats()` adds the neutral `reading.stats` operation, no endpoint.
- `LibraryReadModel.kt:14` retains owner checks, the existing `library_views` table,
  encoded byte ceiling and per-call info timing. Worker injects the local reader adapter.
- `Worker.kt:130` already reads KOReader statistics for the legacy board; this slice
  reads the same file, read-only, without adding a plugin scan or subprocess.
- `logic/stats.lua:44` sends STATS batches for battery/gating. Those batches lack
  book identities and finish dates; they are not mixed into the statistics DB,
  which would count the same reading twice.
- `logic/widget_registry.lua:17` already declares the stats contracts and budgets.
  Renderers are registered for `android-tablet`, independent of the unmerged host.
  `ko/badge.lua:71` supplies the existing Font/TextWidget/blitbuffer rendering pattern.

## Source and exact definitions

Pinned KOReader `9192014d8bd82a91dc1012473be0f238dedfdb54`,
`plugins/statistics.koplugin/main.lua:406-419` defines `page_stat_data`
(id_book, page, start_time, duration, total_pages). Its book schema at lines
464-478 has no finish date. No server behaviour is relied upon.

The companion consumes chronological chunks of at most 256 timed page visits in
a read transaction. Invalid/future visits are ignored; positive durations are
clamped to one day and to now. Each visit is split at local hour/day boundaries,
including DST. Calendar and hour history cover the trailing 365 local dates;
the week runs Monday–Sunday with unobserved days zero. Calendar levels are zero
for no reading, then four positive levels at 25%, 50% and 80% of the maximum.
The companion supplies bar heights and hourly levels; Lua never finds maxima.

Records count **recorded timed page visits**, not unique pages or physical turns.
The best day uses visit counts; ties choose the earliest date. Sessions join visits
separated by at most five minutes, sum only recorded time, and exclude overlapping
time. Streaks require positive timed reading; the current streak may end yesterday.
Best streak and page/session records use the entire available DB history.

Books finished this year and the goal target are explicitly unavailable: neither
finish dates nor a configured target exists in this source. Reading all pages is
not a finish event. Goal inputs include today's and this week's seconds; a later
local completion ledger/goal settings slice can supply the missing fields.
Missing DB, schema/read error, empty DB and ready data remain distinct states.

## Host contract and performance

Every screen and widget declares a strict budget; library calls inherit it.
Filtering, grouping, counts and statistics stay in the companion. Lua reads one
small materialized row, at most 16 KiB, with zero subprocesses or render network
calls. The host shares one Library paint context and flushes at most one batched
companion request; identical statistics needs deduplicate. Each call/render/paint
logs one info timing span. Existing `logic/budgets.lua` rows cover these widgets;
Home pages inherit `screens.home`. Targets remain unconfirmed on-device: Home
500 ms, widget 50 ms, cached window 30 ms, editor 100 ms. Host timing is no device proof.

`WidgetRegistry[id].renderers['android-tablet'](snapshot, placement)` returns a
KOReader widget with `getSize`, `paintTo`, and `free`. Placement carries pixel
`w`, `h` and grid `rows`; rows=1 selects the hour strip, rows>=2 selects touching
hour bars with the peak black. The host supplies the immutable snapshot from
`paint:widget(id, instance):readingStats()` and owns invalidation/retry/gating.
All four stats renderer IDs are installed, but no navigation is enabled here.

Next slice: wire the registry renderer into the Home host, refresh after reader
statistics flush, retain cached data offline, and add the owned finish ledger and
goal settings without guessing values from catalog status. Device visual and
performance validation remains with the maintainer; no device or adb was used.

## F12-F2: server-first field precedence

This section supersedes the local-only source/availability statements above.
Android remains authorised; X4 Pro, X4 and X3 remain deferred. No new screen or
widget is introduced. Existing `logic/budgets.lua:17` widget limits still apply:
one shared materialized row, at most 16 KiB decoded per widget, zero subprocesses
and render network calls, at most one companion batch per paint. The companion
per-call span and widget render/paint spans remain in place; device targets still
require device validation.

Reuse: `BookOrbitLibrary.kt:6` owns backend normalization; `CacheStore.kt:108`
provides existing cached entries, published by `FastCatalogRefresh.kt:321-326`.
Its cache paths omit the network client's `/api/v1` prefix. `ReadingStats.kt:35`
retains the local read-only worker aggregation. `LibraryReadModel.kt:22` retains
owner isolation, byte limits, timing and the owned `library_views` table, and now
shares one stats aggregate even if widget requests carry different byte limits.
`ko/library.lua:23` and `ko/reading_stats.lua:4` retain bounded read/draw ownership.
No new library operation, transport, database, sync writer or UI endpoint call.

Pinned BookOrbit commit `c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7`:

- `server/src/modules/koreader/koreader-catalog.service.ts:239-295` returns
  generatedAt, readingYear, readingStreak, readingGoal and finishedThisYear.
- `server/src/modules/dashboard/dashboard-widget.service.ts:130-144` returns
  goalBooks (nullable), completedBooks and year. This is the full finish count;
  `koreader-catalog.service.ts:332-340` builds a limited finished shelf, whose
  length must never substitute for that total.
- `dashboard-widget.service.ts:178-201` uses the account's local date and rounds
  daily seconds to minutes. The adapter preserves those date labels, then projects
  the existing trailing 365-date and Monday-week widget windows. Device/account
  timezone differences do not reassign server dates to device hours.
- `koreader-catalog.service.ts:279` supplies generation time, **not an inclusion
  watermark**. `server/src/modules/koreader/koreader-stats.service.ts:116-117`
  acknowledges each uploaded book's maximum event start time; the dashboard has
  no matching per-device inclusion cursor, and the widget services cache aggregates
  independently. A fetch time or maximum of local/server minutes cannot prove overlap.

`stats.days`, `stats.streak`, `stats.goal`, `stats.finished` capabilities are
independent and reflect valid cached fields. Each available server field wins;
missing/disabled fields retain local equivalents. Without either source,
completion and target remain unavailable, never inferred from page coverage.
The neutral result supplies `sources` per field, using `all your devices` or
`this reader`. Hour buckets, peak and session/page records remain local. Widgets
show small source text for local fields, including the local portion of a mixed
Records card; server-derived values need no source line.

Without a provable inclusion watermark, server Today/Week/Year totals and this
reader's Today total remain separate, explicitly labeled; local Today may overlap
and is never added. The neutral companion combiner also accepts an inclusive
local-event-start watermark paired with the exact local aggregate, for a future
adapter that can prove inclusion. It adds only post-watermark visits in today,
coalesces overlapping intervals and rejects mismatched/future watermarks. The
current BookOrbit adapter deliberately does not manufacture one from generatedAt
or upload acknowledgements. This follows DESIGN.md's read-model rule to show
separate summaries when overlap cannot be reconciled.

The synthetic dashboard fixture and companion tests cover mapping, independent
precedence/fallback, capability-off, missing local DB, separate Today, proven and
mismatched watermark merges, owner isolation and single-row/byte budgets. Lua
harness tests cover source labels and server-only availability. The next Home
slice can consume the same `reading.stats` operation; Goal/Streak widgets can use
the newly available targets/counts without inspecting a backend payload.

## Local completion and goal settings proposal

Status: **NEEDS APPROVAL**. This section and
[the settings mockup](stats-settings-mockups.html) propose the missing Android
0.12 follow-up. They do not authorise new visible controls. X4 Pro/X4/X3 retain
the Android-first deferral; no firmware changes accompany this proposal.

Add “Reading statistics” under the existing Reading settings group, in both the
reader and companion settings. Reuse their existing row/choice/input primitives:

```text
Reading statistics                             Back
Local reading goal
Off · This reader only                            ›

Finished this year
3 books · This reader only
Only books explicitly marked finished count.
Account totals remain separate when overlap is unknown.
```

“Local reading goal” opens the existing numeric-entry style with Off and a year
plus target from 1 to 999. A saved goal is year-specific and device-local; it does
not change an account/server goal. In the off state the local target is unavailable,
not zero. Display “2026 · 12 books · This reader only” after saving. On year rollover,
keep the old record and show Off for the new year until explicitly set. Show the
current year using companion-formatted text; Lua does not calculate dates.

The local completion ledger records explicit native mark-finished events and
Undo, not page coverage or a server catalog's status. Use a stable document identity
and event token; retries/restarts count once. Undo/re-finish replaces that document's
active completion date. Preserve existing 0.11 native summary dates only when their
provenance is explicit and valid; never infer a finish date from file modification
or 100% progress. A missing historical date stays unknown. Imported events retain
an additive migration checkpoint; never rewrite borrowed statistics or sidecars
merely to produce a count. Store the ledger in the companion behind Library and
checkpoint reader intent even while reading.

When valid account finish/goal fields exist they still win for account widgets.
Local goal and count are a separate, explicitly “This reader only” pair: never
combine an account target with a local completed count and never add local finishes
to an account count without an inclusion proof. The settings summary always shows
local values. Keep overlap-safe Today/Week behavior unchanged. No account-goal
write control is proposed.

Budgets: one materialized local row, at most 16 KiB, one existing settings batch,
zero render network/subprocess/scan. Input validation/aggregation/persistence runs
in the companion service; UI calls only Library. The approved Stats renderers and
reading gate remain unchanged until any newly visible presentation is approved.

After approval, unit tests cover duplicate and reordered events, Undo/re-finish,
restart, additive 0.11 import, invalid dates, local midnight/year/DST, target range,
off/new-year state, source pairing and unknown overlap. Emulator flows set/reopen/
disable a goal, finish/Undo/reopen, check labels offline and preserve existing
0.11 state on upgrade. No real reader or publication is part of this follow-up.

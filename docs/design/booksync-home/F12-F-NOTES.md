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

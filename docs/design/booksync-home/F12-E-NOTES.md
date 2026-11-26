# Android battery model (F12-E)

Android implementation authorised by the maintainer on 2026-11-25; X4 Pro, X4 and
X3 follow later. This delivers the data for W.battery, the Battery page and modeBat,
not their new renderers. The feature remains building in ROADMAP.md; no new widget
is registered as shipped. The approved design was read from
`origin/design/booksync-home` (DESIGN.md §3.5, §6, §8.5, DESIGN-NOTES.md Battery page,
layout.schema.json and prototype.html's W.battery/modeBat). The M8C uses the
`android-tablet` four-column projection; estimates do not depend on tile size.

## Reuse and boundary

Starting at library-interface commit `4f1836b`, the existing modules reused are:

- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/StatsLogic.kt:20`
  (`Snap`), `:83` (`Sums`), `:203` (segmentation), `:264` (pooled rate and standard error).
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/StatsStore.kt:23`
  (SQLite), `:101` (rollup), `:147` (view), `:175` (existing event recorder).
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/LibraryReadModel.kt:5`
  (projection, byte ceilings and timing),
  `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/CacheStore.kt:64`
  (ownership isolation) and `Worker.kt:108` (the existing batched worker command).
- `android/koreader/orbit.koplugin/ko/library.lua:7` (paint context), `:20` (bounded
  read), `:61` (batched flush), and `logic/budgets.lua:8` (screen budgets).

`Library:battery()` adds only `op="battery", limit=1` to that interface. The worker
supplies `StatsStore.batterySnapshot`, and the existing `library_views` projection
persists the small normalized reply. No server JSON, network, new sync writer,
subprocess, catalog scan or battery calculation reaches Lua. Battery is a local
capability, independent of the server adapter. The current interface still uses
its existing owner/batch envelope; account changes invalidate the projection but
never erase device measurements in app-private stats.db.

## Meaning of the data

Rates reuse the pooled least-squares fit and its one-standard-error uncertainty.
Screen-on pools reading and other interactive time; it includes no charging.
`hours_reading_nonstop` uses this measured screen-on rate as the reading proxy;
it does not promise a content-specific prediction. Old rows remain usable. Low
evidence stays absent with a reason (one hour and more than 2% change for drain).
Unknown standard error remains absent, rather than becoming zero.

Usual use is the screen-on fraction of observed non-charging intervals clipped to
exactly the trailing 168 hours. It needs 24 hours of evidence. Unknown service gaps
are excluded, not counted as standby. Time left is level divided by the weighted
screen-on/standby rates. Daily values are measured percentage drops, not net drops
after charging. Fourteen local dates and the latest five raw-window charges are
included; charges are retained in the existing 90-day raw history and contiguous
charging segments are joined across radio/settings changes.

Saver and Balanced both use the existing `jit` Wi-Fi pattern. Until richer mode
policy measurements exist they have identical predictions: no invented savings
factor. Always up to date uses `always_on`. Missing per-pattern rates fall back to
pooled rates and set `estimated=true` with a reason. If pooled evidence is also
missing, hours stay absent. A measured pattern is evidence for the Wi-Fi pattern,
not a claim that sync schedule/frontlight/content are controlled experiments.

SQLite schema 2 adds nullable monotonic elapsed time without deleting old rows.
Rows are read in insertion order. A restart, backwards wall clock, elapsed clock
reset or wall/elapsed disagreement over one minute breaks the interval. A time
change broadcast also records a restart boundary. This conservatively drops the
uncertain interval rather than treating a clock correction as drain or charge.

## Performance and next slice

Every screen/widget has strict deterministic budgets; library calls inherit the
caller budget. Heavy work stays in the companion. `logic/budgets.lua` adds the
Battery screen; the battery widget budget already existed. The snapshot is one
row, at most 14 days, five charges and three modes, under 16 KiB. Existing library
read/paint timing spans produce one info line per call/paint. One Home paint uses
at most one batched round-trip, zero subprocesses and zero render-path network.
Tests enforce row/byte limits and missing budgets. Host timing is not device
performance evidence; the <500 ms Home, <50 ms widget, <30 ms cached window and
<100 ms editor targets await maintainer device confirmation.

The renderer slice can call `paint:widget("battery"):battery()` or
`Library.paint("battery"):battery()`, then flush the host context once. Settings
can consume the same `modes` rows. Preserve the explicit usual-use label, missing
evidence and `estimated` marker; do not recompute rates or blend them in Lua.

## Validation

Companion `verifySharedVersion testDebugUnitTest assembleDebug lintDebug`, including
synthetic drain, low evidence, charging/service gaps, forward/backwards clock
corrections, elapsed-time reset, exact 168-hour clipping, mode evidence, persisted
measurements, additive schema migration and library snapshot bounds. The plugin's
existing logic/flow harness covers the one-row battery read, timing, shared batch,
missing budget and oversized snapshot. Feature-matrix checks and existing USB
installer/sideload script tests run without touching devices.

The latest feature branch's F12-F reading-statistics integration is retained: both
worker providers share the existing `LibraryReadModel` and one Home batch. Merge
coverage exercises battery and reading-statistics operations together; neither
operation replaces the other's capability, registration or projection provider.

The updated library prerequisite also keeps ownership reads on the plugin's
already-loaded account settings: no legacy client construction or lazy reading
ledger initialization on the render path. Its regression is retained alongside
the battery snapshot budget tests (see F12-A-NOTES.md's pinned source evidence).

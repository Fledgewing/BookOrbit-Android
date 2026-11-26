# F12-H: Android reader progress

Android implementation was authorised on 2026-11-25, on `feature/0.12`;
X4 Pro, X4 and X3 follow later. This overrides DESIGN.md §8.8's earlier
cross-platform/no-code gate for Android. The approved source remains
`origin/design/booksync-home`: DESIGN.md §3.5, §6, §8.5; DESIGN-NOTES.md §6
and revision 8+ progress/battery rulings; layout.schema.json; prototype.html
(`android-tablet`, four Home columns). This slice is building, unreleased and
not device validated. It adds the progress/stat surfaces, not the complete
prototype reader controls or catalog Details presentation.

The native top-menu action opens a BookSync top panel: title/author, one solid
bar with percentage, the usual-use battery line, manual Sync, Book info, Home,
Back to book and an explicit KOReader menu escape. Book info opens Details.
Both use that same bar and saved reading stats. The stock menu remains the
escape for other document controls; menu search still constructs its stock menu.
Opening and closing these panels preserves the reading document. Catalog hosts
can call `ReaderPanel.details(key, ui)` with an opaque library key.

## Reuse, with source references

- `ko/endsheet.lua:40`, `:135`, `:241`: existing sheet input, measured row renderer
  and layout. The new reader surface extends EndSheet; only a progress row and
  optional minimum button height are added to the shared renderer.
- `logic/sheet_layout.lua:20`, `:58`, `:96`: existing flat-row grouping, placement
  and metrics. No parallel geometry engine.
- `ko/menu.lua:104`, `:383`: existing menu construction and Tools registration;
  the reader adds one Book info entry through that construction.
- `ko/endofbook.lua:311`, `:476`: existing Home departure/finish handling and
  end sheet. Home still uses `onOrbitGoHome`; this slice adds no finish writer.
- `ko/home.lua:651`: existing plugin event dispatch, reused privately by the
  library adapter's explicit Sync action, with the existing Net/Wifi lifecycle.
- `ko/library.lua:7`, `:21`, `:74`, `ko/store.lua:107`: existing paint contexts,
  budget enforcement and bounded SQLite projection reads. No new Lua cache,
  database connection or transport. `ko/cache.lua:105` remains adapter-only.
- Companion `LibraryReadModel.kt:5`, `CacheStore.kt:210`,
  `BookOrbitLibrary.kt:8`: existing worker projection, cached book lookup and
  account-scoped Copies ledger. Extend these rather than copying their catalog.
- `Worker.kt:108`: existing ordered PATCH batch materializer. `Core.kt:43`
  remains the companion contract; no new service, worker loop or permissions.
- `logic/caps.lua:27` remains the companion trust/service capability gate;
  library capabilities, not server identity, decide the Sync control here.

## Interface additions and unavailable data

`Library:reader(path)` resolves the active owner's existing tracked-file ledger
on the companion and returns one normalized book row with stats. `:book(key)`
also includes the same stats. `Library:battery()` is an explicit unavailable
placeholder until the battery slice publishes `hours_usual_use` (the measured estimate,
formatted as days/hours by the display logic). The renderer adds
“≈ N left at your usual use”. Missing data never becomes an invented estimate.
`Library.syncCurrent(done)` is an explicit user action through the adapter to
the existing quiet SyncBook writer; it is never invoked by render or read.
`progress.syncCurrent` advertises the capability. Failure stays inline, and a
late callback never opens or paints a dismissed panel. Missing projections get
at most five short re-read attempts, only while the same user-opened panel is
topmost and the same document is open. No automatic panel appears while reading.

Reading time and pages come from KOReader's saved statistics database, read-only
on the companion worker. No forced reader flush. Distinct pages and duration
sums use KOReader's page_stat view; days start to finish use the first saved
session date and the actual completed summary.modified date, inclusive. Missing
statistics, unfinished summaries, absent per-file sidecars and hashed-sidecar-only
metadata leave the relevant values unavailable. Only ledger-tracked copies are
covered; server-only books can lack local stats. For in-book surfaces, the library adapter includes KOReader's already-computed
footer percentage as one bounded scalar input to `reader`. The companion validates
and projects it with `progress_origin=local-reader`; saved catalog progress is
unchanged. No sidecar read, progress calculation or second sync writer runs in Lua.
Catalog Details without a reader context keep their saved library percentage.

Upstream behavior was checked at pinned KOReader commit
`9192014d8bd82a91dc1012473be0f238dedfdb54`:
`frontend/apps/reader/modules/readermenu.lua:390` (visible vs hidden menu),
`frontend/ui/widget/progresswidget.lua:43` (plain bar options),
`plugins/statistics.koplugin/main.lua:51` (distinct page/duration totals),
`:406` (statistics rows), `:464` (book identity),
`frontend/apps/reader/modules/readerstatus.lua:212` (completion date),
`frontend/util.lua:1141` (one comment plus return in saved settings), and
`frontend/dump.lua:32` (bracketed keys). The companion uses the existing LuaValue
literal parser after removing that fixed settings header; it executes no Lua.

## Performance ruling and tests

Maintainer 2026-11-25: every **screen and widget** has strict limits; their library
calls inherit those limits. Aggregation and joins run in the companion. Top panel,
Book info and Details each have three materialized rows, 32 KiB total decoded,
zero subprocess spawns, zero network calls and at most one companion batch per
paint. The shared reader-progress widget is one row, at most 16 KiB per snapshot.
There are info-level call/paint/draw spans. Host timing is not device performance;
Home <500 ms, widgets <50 ms, cached windows <30 ms and editor <100 ms remain
unconfirmed device targets. AGENTS.md carries this rule for subsequent slices.

The existing plugin logic harness tests display normalization and budget guards.
`reader_panel_flows.lua`, loaded by test_flows.lua, drives the real sheet, reader
menu hook, library batching, progress widget options, capability gate, navigation,
manual Sync, cold completion and dismissal. Companion ReaderBookStatsTest covers
real SQLite aggregates, actual completion dates, owner isolation, missing records
and the battery placeholder. Existing end-of-book flows remain unchanged.

Next slices can supply the battery projection, enrich the existing normalized
book/stat row, use `ReaderPanel.details` from catalog cards, and add the remaining
reader controls to the shared row renderer. Preserve the single existing sync
writer and guard completion/repaint against the still-visible user-opened panel.

Integration with F12-F preserves its `reading.stats` operation, worker provider,
Stats widgets and fixture tests. That operation aggregates the whole history;
reader book stats remain a single hash-scoped SQL aggregate over the same native
database, including distinct-page and completion-date semantics needed here.

Native progress source at the same pinned KOReader commit:
`frontend/apps/reader/modules/readerfooter.lua:2368` and `:2390` update the cached
`percent_finished` scalar on page/position changes. All three in-book surfaces
request this reader context through Library, including after opening Details.

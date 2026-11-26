# F12-J: Android Home wiring

Android implementation authorised 2026-11-25; X4 Pro, X4 and X3 follow later by
explicit maintainer ruling. The approved design sources were read with `git show
origin/design/booksync-home:docs/design/booksync-home/<file>`: DESIGN.md §3.5,
§6 and §8.5, DESIGN-NOTES.md revision 10, layout.schema.json and prototype.html.
Rev 10 still has two M8C pages. This task explicitly requests three: Home,
Library (Library 2×2, On device, Finished), then Stats. The four-column M8C
Stats layout retains the approved Year 4×3, Battery, weekly/hourly and Records
placements. Defaults change only for readers without a saved valid layout.

Reuse evidence at the starting commit `543d67d` (paths relative to
`android/koreader/orbit.koplugin/`): `ko/home.lua:562` and `:770` already route
the opt-in Home; `ko/menu.lua:218` already exposes the choice, with old Home
the default. `ko/home_widgets.lua:4` registers renderers; `ko/home_host.lua:27`
owns paints, subscriptions and immutable snapshots; `logic/home_host.lua:18`
plans neutral Shelf sources. These modules are extended, with no parallel host.
`ko/reading_stats.lua:5` and `logic/reading_stats.lua:6` supply the existing
renderers/geometry. Lua 5.1 immutable array proxies need indexed fixed-length
checks rather than `#`; the renderer receives the measured snapshot byte size.
`ko/filter_sheet.lua:4` supplies the shared sheet and onSave callback;
`logic/layout.lua:285`/`:322` already implement bounded tile/page additions.
`ko/library.lua:7` and `:26`, `ko/store.lua:107`, `ko/db.lua:64` and
`ko/cache.lua:124` retain the read/batch/database/event ownership.
Companion `LibraryReadModel.kt:20`/`:49` publishes/projects the existing views,
`CacheStore.kt:15`/`:37` owns their database, and `Core.kt:600` retains the
existing Home command path. No extra catalog, network client or worker is added.

The new library operation is deliberately small: `library.summary` reuses the
worker's canonical catalog/filter projection and owner-checked local paths,
returning total and an optional on-device count. Unknown local coverage stays
unknown. After integrating F12-H (`609cc8e`), the widget reuses its existing
`Library:battery()` operation and enriches its explicit not-saved stub until
battery history lands; it invents no charge level, rate or estimate. Summary
and battery have companion projection tests. Home book actions now inherit
F12-H’s owned Details flow. All UI queries use Library, opaque list keys and
neutral filters. Capabilities hide unsupported sources/statistics.

Every Shelf title opens the shared bounded list screen; Lists rows, Library,
On device and author/series grouping use that same path. Search uses its own
neutral source and Best match default. Search and Filter are adjacent in list
headers; changed filters have removable chips. FilterView handles the actual
sheet and picker UI. Save preserves base source and query in a local Book list,
uses Layout.add's first available slot across pages, or creates an auto-named
page. It offers Go to Home and never writes a server list. After integrating F12-I (`57c1d0b9`), `ko/home_editor.lua:24` owns the atomic
save and previous-valid backup for the same S.home_layout; filter saving reuses
HomeEditor.save, including its failure handling and restart persistence. Temporary list navigation does not modify it.
Legacy server-plugin screens remain available through the existing Home choice.
The single reading gate reuses `ko/home.lua:382`'s visibleStack helper to recognize
Home beneath its filter/picker/editor dialogs. A reader above Home restores the
gate, and a stale active-host pointer alone never permits cached reads or notices.
Open-book flow tests cover sheet, picker and foreground-reader transitions.
Nonlocal Details retain Home beneath them, so cached detail refreshes work and
Back returns to Home; local Resume closes Home and restores foreground reading.

F12-F's later server/local projection (`0077684c`) is also integrated: the same
reading.stats operation supplies per-field provenance and separate local-today
values when the server has no inclusion watermark. Home retains these labels and
uses indexed checks on immutable arrays; all four Stats renderers still share
one host read per paint.

## Inherited performance rule

AGENTS.md already contains the maintainer's screen/widget performance section.
Every Home page inherits `Budgets.screens.home`; owned lists use `library` and
Search inherits that family in the same budget table. Each installed widget
already has a strict registry/budget entry. All stats widgets share **one**
materialized reading.stats read per paint. Each renderer checks its own snapshot,
and the complete normalized widget snapshot is capped at 16 KiB. Library checks
rows/decoded bytes before/after each read, and the host flushes at most one batch.
Filtering, sorting, grouping, counts, joins, search, stats and future battery
estimates stay in the companion. No render-path network or subprocess spawn.
Info spans cover library calls, host paints and each widget's drawing. Targets
remain unconfirmed: Home <500 ms, widget <50 ms, cached window <30 ms, editor
<100 ms; host tests establish deterministic limits, not device performance.

Flow tests draw all three pages with real stats renderers, verify one stats read
and one batch per paint, drive list Filter → Show picker → Unread → Save → Go to
Home → reopen, and drive Search with its filter button. Pure placement tests
exercise new-page naming without changing the prior document. Device acceptance,
actual battery history, cached covers and full details/actions remain later work.
No devices, adb, test-build dispatch, tags or releases are used here.

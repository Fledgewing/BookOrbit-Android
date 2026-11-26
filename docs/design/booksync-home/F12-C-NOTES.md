# F12-C: Android Home host

Android build authorised 2026-11-25; design source is the approved
`origin/design/booksync-home` DESIGN.md §3.5, §6 and §8.5, DESIGN-NOTES.md
revision 8+ and prototype.html (`android-tablet`, four columns). Firmware follows
later by the maintainer's Android-first ruling. This adds an opt-in host to the
Reading and Home settings; Server plugin’s Home remains the default.

Reuse evidence (source on this branch, before this slice): `ko/home.lua:561` and
`:763` route Home commands; `ko/cache.lua:124` and `:148` poll/dispatch acknowledged
worker events; `ko/store.lua:107` bounds SQLite blobs before decode;
`ko/db.lua:17` shares read-only connections. `ko/library.lua:5` and `:59` own
paint contexts and the single flush. `logic/caps.lua:11`, `logic/home_plan.lua:20`
and `logic/sheet_layout.lua:58` retain their existing capability/routing/sheet
roles; this host does not copy them. `logic/layout.lua:148` resolves projections
and `:194` supplies the approved M8C defaults. Companion `CacheStore.kt:20`/`:37` owns the
same catalog/read-model database; `Core.kt:600`'s existing Home command path remains
unchanged. No second catalog, worker, credential store or sync loop is added.

The installed renderer map is `HomeWidgets.renderers`; register an additional
renderer with `HomeWidgets.register(id, render, planNeed)` after adding its registry contract
and budget; optional pure `planNeed(placement)` declares the bounded library operation. The host passes read-only proxies: use `snapshot.count` and indexed
`snapshot.items[i]` (Lua 5.1 proxies deliberately do not implement `#`/`pairs`).
It passes a dispatch function separately. Widgets own no timers or library contexts.
Unknown/uninstalled placements remain in the document but do not read or render.
Future-only pages are skipped in navigation, and a single page has no pager.
Read-model invalidation refreshes only changed card rectangles on the display.
`HomeHost.document()` consumes `S.home_layout` if valid and otherwise Layout.default;
the editor can publish that same document and invalidate the active host.

Continue reading uses a black hero and plain white progress bar. Shelf supports
ready cover placeholders or rows, with neutral sources in placement settings;
Lists opens a small Shelf in this host. Cached cover images, full details,
downloads, shelf paging, stats and richer book actions belong to later slices.
No estimates or cover availability are fabricated. Local Resume uses the companion's
owner-scoped checked file ledger; unavailable books get an explicit local-data message.
Temporary list navigation never modifies the saved layout.

## Inherited performance rule

Every screen and widget declares a budget in `logic/budgets.lua`; library calls
inherit it. Filtering, sorting, grouping, counts, search, joins and file checks
stay in the companion. The host reads only visible small windows, at most one
batched companion request per paint, zero subprocesses and zero render-path network.
Per-widget decoded snapshots stay at or below 16 KiB; Home is bounded to 128 rows,
128 KiB and 16 requests. A preflight stops reads before exhausting the page budget.
Per-card errors (including deferred KOReader painting) become Error/Retry cards;
no invalid widget can poison the sibling budget counters. Read-model events coalesce
on the next UI tick and redraw only a visible Home. Closing unsubscribes and cancels
pending redraws; events never show/focus a Home over reading.

Info-level spans cover library calls, Home construction and widget painting. Device
targets remain unconfirmed: cached Home <500 ms, widget <50 ms, cached window <30 ms,
editor <100 ms. Host counters do not establish those device timings. No device,
adb, release or tag is used in this slice.

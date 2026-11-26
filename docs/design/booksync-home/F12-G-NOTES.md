# F12-G: reusable Android filter sheet

The maintainer authorised Android implementation on `feature/0.12` on 2026-11-25.
This follows approved DESIGN-NOTES rev 10/11 §11 and prototype `filterView`, read
from `origin/design/booksync-home`; the draft's older no-code/platform-order text
is superseded for Android. Firmware remains planned for X4 Pro, X4 and X3.

## Reuse and boundary

- `ko/home.lua:215` supplies the existing reading gate for every show and repaint.
- `ko/library.lua:6` supplies the caller-budget paint context; `:26` reads only
  bounded projections and `:59` now exposes `facets`. The existing adapter delegates
  to `ko/store.lua:107`, using the FFI connection in `ko/db.lua:64`, with no fork.
- `logic/cache.lua:29` supplies canonical small selection comparison; the existing
  `logic/layout.lua:10` copy helper protects caller-owned data.
- `LibraryReadModel.kt:20` publishes through the existing `CacheStore.kt:15`
  SQLite store. Facets extend its existing source/membership scan and the existing
  `LibraryFilter.matches` predicate. No second catalog, sync writer or API client.
- Existing `logic/sheet_layout.lua:21` is specifically the end-of-book block
  language. This sheet uses KOReader's existing ButtonDialog/ButtonTable rather
  than duplicating that sheet or inventing another widget toolkit. New symbol uses
  are checked in `test/koreader_compat.lua` against pinned KOReader.

## Host API

`FilterView.new{source, query, defaults, title, sorts, onChange, onApply, onSave}`
is the single component for owned list and search filter buttons. `:show()` opens
it; `:header(total)` returns the shared active icon ID, subtitle, removable chips
and callbacks. The host gives the same query to its library window and takes the
subtitle total from that window. `onChange(query)` invalidates/reloads the host;
`onApply(query)` closes/applies. All callbacks receive copies. Search defaults
preserve its search text and Best match order on reset. List searches also retain
their query; Reading now and Recently added inherit the library's default ordering. On device hides Where;
Reading now hides Show. Context defaults can supply source-specific grouping/order.

Home's layout owner supplies `onSave{source="custom-filter",base_source=...,query=...}` and owns
first-fit placement/new-page naming, persistence and the navigation toast. The
footer action is present and disabled until this callback is supplied. The saved
base source preserves constraints such as Finished, On device or a named list,
so reopening the Home Book list queries the same source and filter. This slice
never creates a parallel layout store. The owned list/search/Home slices must
wire these callbacks; the legacy upstream UI is not retrofitted.

The sheet has nine rows and a divider before Group & sort. Each row opens a picker.
Author/Series/Tags toggle and keep the picker; radios return immediately. Back
returns to the sheet, then applies. Group, sort and direction share one page.
Picker pages contain at most eight values; the page bar is absent for one page.
Counts of zero are gray with no numeral and remain selectable, including selected
values absent from the catalog. A cache miss says Counting, never a fabricated 0.

## Read operation and counting

`paint:facets(source, query, field, offset, limit)` returns `total`, `items`,
`option_total`, `offset`, `next`, `multi` and `freshness`. Without `field`, it returns
just the result count and an empty bounded items array. With a picker field, each
item has `id`, `label`, neutral `value`, `selected` and `count`. Multi-values
also carry `selected_values` so removal uses the worker's Unicode case folding. An omitted value
means Any. The total applies every filter; option counts apply all other filters
with this picker's own selection removed. Source constraints remain in force.
The companion returns positive counts first, zero values last; multi-values sort
by label within those partitions and preserve selected missing values. Duplicate
tags on a book count once. No filtering, sorting, catalog joins or dates run in Lua.

Show adds the neutral `want-to-read` choice; the adapter retains it as a local
predicate. Length uses the approved <250 / 250–450 / >450 boundaries. Added uses
the prototype's rolling 7/31/365 days, computed in UTC on the worker. Existing
range predicates remain unchanged. Unknown device coverage leaves Where
unavailable rather than claiming no downloaded books. Labels use the read model's
UTF-8 byte-string contract.

## Performance and validation

Every screen and widget declares a strict budget; library calls inherit it.
All counts, fallback filtering, sorting, grouping, search, stats, battery estimates
and catalog joins belong in the companion. Lua reads small ready-to-draw windows:
zero subprocesses, zero render-path network, at most one batch per paint, at most
16 KiB per widget snapshot. Filter picker pages have an explicit budget row;
reads are bounded to eight options / 16 KiB. The sheet budgets its complete card
height before constructing widgets. Pending reads retry only while visible and
not reading, up to 20 times at 500 ms; close cancels them. Each read, library paint
and drawing pass logs one info-level timing line.

Device targets remain unconfirmed: Home <500 ms, widget <50 ms, cached library
window <30 ms, editor move <100 ms. Host checks do not establish those timings.
Tests cover counts with the own-picker choice excluded, source constraints, ranges,
zero ordering, selected missing values, pagination/bytes, chips/reset, actual view
callbacks and budgets. No devices, USB tools, releases or tags are involved.

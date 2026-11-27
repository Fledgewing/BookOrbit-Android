# Personal reading source aggregation (Android, unreleased 0.12)

The approved Android-first build installs Highlight of the day and A year ago in
2×1 and 2×2 picker sizes. UI requests `personal.reading` with a neutral `kind`;
it never chooses a provider. `PersonalReading` queries capable providers in order,
keeps the first record per neutral identity, and publishes one bounded display row.
A failed provider cannot erase another provider's saved data. All failed is an error;
a successful empty device history is an explicit empty card. Cached data supports
offline display. Acquisition is outside this read-only provider contract.

Reuse evidence on this implementation's base e93cbcc8:

- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/ReadingStats.kt:24`
  opens the existing statistics database read-only; `:52` reads timestamped
  `page_stat_data` rows. Stats already delegates this aggregation to the companion.
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/LibraryReadModel.kt:29`
  retains the existing account/device ownership check; `:73` bounds published bytes
  and rows; `:86` logs timing. Both personal widgets extend that same materializer.
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/DeviceLibrary.kt:11`
  already discovers device books, excludes escaping symlinks and sidecar directories;
  `:24` parses bounded native metadata as literals without executing Lua. The shared
  discovery function now serves both device catalog and highlight provider.
- `android/koreader/orbit.koplugin/ko/local_widgets.lua:31` and
  `android/koreader/orbit.koplugin/logic/local_widgets.lua:4` supply the existing
  immutable renderer/projection contracts, budgets and timing span.

A year ago uses the same calendar day last year in the device timezone, clamping
February 29 to February 28. SQL groups timed page visits by book, selects the book
with most recorded time (book ID breaks ties), and returns minutes, days read and
the latest stop page. No history is fabricated for a missing database or day.
This window is one calendar day, so days read is one for a populated row.

Highlight reads local books' native annotation sidecars (read-only, ≤1 MiB each),
excludes bookmarks without a passage locator, and deduplicates by path/locator/text.
Sorted book paths and annotation order define a deterministic pool. Calendar-day
round robin survives process restarts and does not repeat until the stable pool
is exhausted. Editing the annotation pool changes the cycle. Only bounded passage,
source and book-action fields enter the published row. No sidecar IO occurs in Lua.

ServerAdapter exposes optional `personalReadingSources(owner)` registration; its
default is empty. A future adapter can capability-gate highlights/history providers
inside its own package. This slice implements no remote provider. Toy providers
prove precedence, dedupe, capability skipping and failure fallback in tests.

Both widgets inherit `logic/budgets.lua`: one display row, ≤16 KiB, zero render
network calls/subprocesses and one shared Home batch. Companion discovery/parsing
is worker work; these limits apply to materialized/read/display records rather
than pretending an aggregate SQL query visits only one underlying statistics row.
Device appearance/latency acceptance and firmware integration remain pending.

# F12-recdisc: Recommended and Discover

Android implementation on feature/0.12, under the maintainer's 2026-11-25 build
and 2026-11-26 slice authorization. Unreleased; real-device acceptance remains.
X4 Pro, X4 and X3 are deferred to firmware under the Android-first ruling.

## Reuse and boundary evidence

- `android/koreader/orbit.koplugin/ko/recommendations.lua:19` and companion
  `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/RecommendationPlan.kt:7`
  implement **recommended settings**, not book recommendations. Their existing
  companion projection and review behavior remain intact.
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/PersonalReading.kt:6`
  is the #181 provider seam; `:14` selects one bounded result, registration-order
  identity dedupe and failure isolation. New kinds are recommended and discover.
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/DevicePersonalReading.kt:11`
  supplies device catalog data using the existing DeviceLibrary sidecar parser,
  extended with neutral series identity/position. The registry tries it first.
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/CatalogPersonalReading.kt:6`
  ranks saved neutral rows. Device books lead; a saved catalog provider adds mirror
  books. File paths dedupe device/mirror copies; opaque keys identify mirror-only books.
  Read and abandoned books never enter either unread pool.
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/LibraryReadModel.kt:27`
  owns materialization in the existing library_views table. Personal catalog input
  stays on the worker, behind ServerAdapter; its internal full-generation read does
  not widen UI windows. No recommendation endpoint or remote acquisition is added.
- `android/koreader/orbit.koplugin/ko/library.lua:189` bounds reads and logs spans;
  `ko/library_local_widgets.lua:3` owns neutral requests and the persisted Another
  offset; `ko/home_host.lua:209` dispatches the user action through that interface.
  `ko/home_widgets.lua:27` supplies the existing native button primitive.

No UI knows a provider, catalog format or server name. A later recommendation
provider implements PersonalReadingSource and registers behind the interface;
CatalogPersonalReadingTest exercises an independent toy source. This slice does
not install a BookOrbit recommendations provider. The cached catalog adapter only
normalizes saved book data through its existing projection pipeline.

## Selection and presentation

Recommended offers 4×2 and 2×2, matching the prototype's recommendation entry.
It shows one unread book: the first known unread series volume after a finished
volume ranks first, then unread books by authors in reading/finished history,
then other unread books in deterministic identity order. Device-source picks
precede mirror picks. Unknown series positions do not invent a next volume.

Discover offers 2×1 and 2×2. A SHA-256 ordering of local-calendar-day plus neutral
identity gives a deterministic daily shuffle, stable across companion restarts.
Another advances a device-local persisted offset through that day's pool, without
repeating until the pool cycles. An empty pool has no Another action; a single
book cycles to itself. Library owns the offset; widgets only dispatch an action.
Pool changes (refresh, finish or deletion) can change the pick before the next day.

Both show explicit loading, empty, offline-with-data, offline-without-data and
error presentation. Ready and offline data can open the selected book through the
existing host action. Missing data uses Retry; no account setup is needed for
local-only widgets. All buttons have at least 50 px width and height.

## Budgets and verification

Each widget inherits one display-book row and at most 16 KiB from logic/budgets.lua.
Catalog joins, sidecar parsing, sorting and shuffling run in the companion. Lua
only renders the immutable snapshot. One Home paint uses at most one batch, zero
subprocesses and zero network; existing Library, widget and worker timing spans
remain active. No second cache or per-widget worker round-trip is introduced.

Plugin logic and flow sweeps cover both sizes and every state, immutable snapshots,
picker availability, action bounds, row/byte rejection, a shared Home batch and
Another dispatch. Companion tests cover series and author ranking, read/abandoned
exclusion, native sidecars, restart stability, daily change, a complete Another
cycle, dedupe, provider failure, toy registration and whole-generation mirror
input with a one-book output. UI/server boundary guards remain unchanged.

Device font fitting and the <50 ms widget / <500 ms Home targets need the
maintainer's device run; host timings and tree geometry do not prove them.

# F12-L: Android server boundary

Authorised Android-only implementation on `feature/0.12`, 25 November 2026. Firmware follows
later under the maintainer's Android-first direction. This is protocol ownership/enforcement,
not a new screen or transport writer. Approved source: `origin/design/booksync-home`,
`DESIGN.md` §§3.5, 6 and 8.5, its revision-8+ notes, schema and clickable prototype.

## Reuse and ownership

At starting feature commit `543d67d`, the implementation extends these existing seams:

- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/CacheStore.kt:15`:
  same cache/schema/transaction owner, moved into `server/bookorbit`, implementing the small
  `ProjectionStore` persistence seam. No parallel catalog or database.
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/CacheWorker.kt:25`:
  same worker, bulk refresh and event mailbox, moved into the adapter package.
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/BookOrbitLibrary.kt:36`:
  same translation/normalization; the existing read-model projection joins moved alongside it.
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/LibraryReadModel.kt:20`:
  retained bounded publishing, cache invalidation, owner isolation and timing. Server projection
  is injected through `ServerAdapter`; local KOReader reading statistics remain neutral.
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/SettingsUiLogic.kt:200`:
  retained the sleep picker's cached-list translation inside `SleepChoicesProjection`, with
  the same neutral `SleepChoices` output and existing background worker.
- `android/koreader/orbit.koplugin/ko/library.lua:23` and `ko/store.lua:107`:
  retained bounded UI reads. The protocol-specific bulk query interpreter moved into the
  Lua compatibility adapter; serialization stays in the existing `logic/cache.lua`.
- `android/koreader/orbit.koplugin/ko/home.lua:194`, `logic/caps.lua:1`,
  `logic/home_plan.lua:19` and `logic/sheet_layout.lua:1`: retained reading gate,
  capability resolution, Home planning and sheet sizing. No new screen/paint path.

The companion adapter also owns the upstream connector installer and connector cover auth.
Core's Android connectivity/package/preferences utilities contain no server calls and stay
shared. Updater's release feed and APK installation are BookSync product services, not library
server APIs, and stay shared. Local ReadingStats and LibraryFacets have no server protocol.

The full rule, registration instructions and the enumerated Lua transport follow-up are in
[backend independence](../backend-independence.md#android-adapter-enforcement-f12-l).
Legacy sync/reading/snapshot primitives are adapter-contained too; their API names are
guarded in addition to paths and JSON fields. The reading-gate source check now recurses
into all adapter submodules. The old Lua frozen baseline is deleted. Guards run over all production source files and
self-test rejection of fields, routes, imports and attempted suppression comments.

## Budgets and checks

No new screen or widget is introduced. Every existing caller retains its declared
`logic/budgets.lua` / registry budget, at most one Home batch, zero render-path subprocesses
and network, and a 16 KiB snapshot cap. Shared publishing additionally rejects an adapter
that returns more rows than the caller requested. Existing timing lines remain one per
published call/paint; host tests do not establish the device timing targets.

`ServerAdapterTest` runs fake and acquisition-only backends through the same publisher,
with distinct opaque key shapes/capabilities, unsupported operations, account isolation,
secret clearing and an oversized response. The internal adapter method `cachedReadingStats` supplies F12-F's normalized cache input;
`reading.stats` remains the existing UI operation with one aggregate per batch.
Existing backend fixtures/tests moved into the
adapter test package; reading and contract source guards now recurse into subpackages.

F12-K integration keeps the native account, independent sync and OPDS transports, credential
provisioning, OPDS parser and account-stat normalization in `server/bookorbit`. Shared
`LibraryAccount` receives its session from registry wiring and catches only neutral
`ServerFailure`; encrypted storage and normalized account-stat aggregation remain shared.
The existing publisher accepts neutral account snapshots and passes them to projection
composition. Native account launch/return is explicit lifecycle work, never a widget read.
The account screen keeps F12-K's budget and timing spans. Shared Settings schema wording
is neutral while stored wire values remain compatible.

F12-E and F12-J integration keeps battery estimation local to the neutral publisher (one
lazy snapshot per batch), and contains the added `library.summary` catalog join in the
server projection. No renderer receives raw catalog fields or performs that aggregation.

F12-N adds only neutral account/login commands to the shared provider port. Account display
metadata and provisioning outcomes normalize in `server/bookorbit`; the private Lua binding
caches the bounded lifecycle snapshot, so signed-out forms work without a catalog owner and
Home still performs at most one batched worker read. The Home setup action shares its row with Search and stays out of list filters; Custom editor and sign-in panel actions coexist.

F12-O replaces the temporary Battery renderer with the snapshot widget/page. Its existing
`battery` operation remains local; all display labels, rates, dates and totals are companion
projections. The Home integration wraps that one row for the immutable widget contract and
keeps the shared reading gate, including dialogs opened above Home.

The landed F12-J Home integration's interim scalar Battery renderer is superseded by
F12-O's companion-formatted widget/page. Its capability gate and absent-history checks
remain, without a parallel renderer or display model. Account subtitle changes invalidate its header region without moving widgets.

The final F12-O integration extends Home's canonical `logic/battery_widget.lua`
contract, removes the earlier `logic/battery.lua` name, and consumes `snapshot.data`
directly. Loading/error labels survive the shared snapshot conversion; Home owns the
sole registration and all reads.

F12-P adds `sources` in the existing Lua Library and companion projection. The adapter
contains section translation, counted/paged source names and current-book exclusion before
filter/sort/page; display labels are bounded without splitting UTF-8 code points. The neutral
`ServerAdapter.sources` delegates through the same tested contract. Source pickers retain
the six-row/16 KiB budget; configuration screens read no catalog.

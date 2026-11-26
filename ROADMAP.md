# Roadmap

Outcomes BookSync plans, in order. A design doc and mockups need the user's approval before an item
moves to building; when it ships it moves into [`docs/FEATURES.md`](docs/FEATURES.md)
(AGENTS.md "Features and roadmap"). Items are outcomes only: designs live in
[`docs/design/`](docs/design/).

Status: idea, planned, designing, approved, building, shipped. Platforms: Android, X4 Pro, X4, X3 (Xteink:
CrossInk 2.x only; 1.6 is retired).

| Outcome | Platforms | Status | Design |
|---|---|---|---|
| Withdraw broken releases through a signed Android feed and require reader opening flows before publication. | Android | building (W35 implementation requested) | [release safety](docs/design/release-safety.md) |
| Caller-verified companion commands and one tested plugin–companion contract, with file operations confined to BookSync data. | Android | building (approved design; caller checks merged) | [security](docs/design/security.md), [contract](android/docs/INTERFACE.md) |

## Next release (0.12): BookSync Home

| Outcome | Platforms | Status |
|---|---|---|
| Three-page Android Home with Library and Stats widgets, shared filtered lists/search and saving custom filters as Home tiles. | Android building; X4 Pro, X4, X3 deferred by Android-first ruling | building (authorised 2026-11-25; device acceptance pending) |
| Opt-in owned Home host with paged placements, isolated Continue reading, Shelf and Lists widgets, and one budgeted batch per paint. | Android; X4 Pro, X4, X3 later | building (authorised 2026-11-25; device acceptance pending) |

The release after 0.11.4 graduates from previews and release candidates. Built in parallel on the
`feature/0.12` branch while 0.11.4 stabilises on `main`; design and mockups need approval first
([BookSync Home design](docs/design/booksync-home/DESIGN.md), in progress). This is the first step
of [backend independence](#planned-backend-independence): BookSync owns the screens and BookOrbit
becomes a data source.

**Widget layout engine and budgeted host contracts:** versioned layouts, immutable class
projections, M8C defaults, pure editing and previous-valid recovery — Android building
(maintainer-approved 2026-11-25); X4 Pro, X4 and X3 deferred to the firmware implementation.
The layout editor and further widgets build on this engine.

All four remaining parity gaps below ship in 0.12 (maintainer ruling 2026-11-25);
design and mockup approval still apply.

| Outcome | Platforms | Status |
|---|---|---|
| **Stable / RC / Preview update channels** selected from the BookSync version, with stored opt-in migration and no channel-switch downgrade. | Android, X4 Pro, X4, X3 | building (0.12, maintainer-approved W42) |
| **BookSync Home** replaces the BookOrbit plugin's Home: every section rebuilt by BookSync from the offline database, instant and offline, with BookSync's own book detail page. | Android; X4 Pro, X4 after | designing |
| **In-book progress**: one plain bar in the top panel, Book info and Details, cached reading stats and manual Sync through the library interface; battery estimate waits for its operation. | Android building; X4 Pro, X4, X3 later (maintainer ruling 2026-11-25) | building (F12-H; unreleased, device validation pending) |
| **Reusable filter sheet**: nine picker rows, companion-counted facets, removable chips and a local Home Book list action. | Android building; X4 Pro, X4, X3 after | building (maintainer-authorised Android F12-G) |
| **Reading statistics and Stats widgets**: companion aggregates local reading history into bounded Year, This week, hourly and Records snapshots; host integration and completion/goal settings follow. | Android building (approved 2026-11-25); X4 Pro, X4, X3 deferred to firmware implementation | building |
| **BookSync library interface**: all platform UIs use one interface with BookOrbit/Grimmory adapters, capability-gated features and neutral filters with cached-catalog fallback ([BookSync Home owned-client design](docs/design/backend-independence.md#1-owned-android-client-and-ledger)); maintainer rule 2026-11-26. | Android (KOReader plugin + companion), X4 Pro, X4, X3 | building (Android F12-A foundation; X4 Pro, X4, X3 planned) |
| **Equivalent settings controls**: expose the [parity gap 1](docs/FEATURES.md#prioritised-parity-bugs) controls, including a sleep sync budget aligned with Android's 10/15/20 s choices. | X4 Pro, X4 | planned (0.12) |
| **BookSync status-bar preset**: add one preset over the existing native controls ([parity gap 2](docs/FEATURES.md#prioritised-parity-bugs)). | X4 Pro, X4 | planned (0.12) |
| **Discoverable settings**: make equivalent settings easy to find while retaining button navigation ([parity gap 3](docs/FEATURES.md#prioritised-parity-bugs)). | X4 Pro, X4 | planned (0.12) |
| **Persistent crash summary**: retain a deduplicated crash summary across restarts, never uploaded automatically ([parity gap 4](docs/FEATURES.md#prioritised-parity-bugs)). | Android | planned (0.12) |
| **Tap to download** (Next 5) on Home, lists, series and detail. | Android; Xteink after | designing |
| **Series view** (Next 6): every book in order, on device or server only, read state, download next. | Android; Xteink after | designing |
| **Add-on mode and setup checklist** (Next 10, 10a). | Android | approved items carried over |
| **Cleaner menus** (Later 8b) and **no visible app switches** (Later 9) where the new Home makes them small. | Android | stretch |

## Planned: backend independence

BookSync's journey to backend independence: your reading works with the library server you
choose (BookOrbit today, Grimmory next, others later) and your positions, history and
highlights come with you when you change. Deferred work, in the order below; existing work in
progress continues. The proposed design
and any UI mockups still need approval before implementation.

| # | Outcome | Platforms | Status | Design |
|---|---|---|---|---|
| 1 | **Owned KOReader plugin and portable read state**: the plugin + required companion retain BookSync's own positions, status, sessions, highlights, ratings and shelves, with open export and BookOrbit + Grimmory direct adapters. | Android | designing | [owned client and ledger](docs/design/backend-independence.md#1-owned-android-client-and-ledger) |
| 2 | **Per-device catalog packages from BookSync**: an optional self-hosted container (Kubernetes or Docker) serves profile-sized catalogs and covers as its first API. | Server, Android; packages designed for X4 Pro, X4, X3 | planned | [first server API](docs/design/backend-independence.md#2-server-first-api-catalog-packages) |
| 3 | **Shared portable history across backends**: BookSync adds durable ledger/event sync and BookOrbit + Grimmory adapters, with backup/restore and explicit direct/server mode transitions. | Server, Android | planned | [shared ledger](docs/design/backend-independence.md#3-shared-ledger-and-backend-adapters) |
| 4 | **BookSync on Xteink**: X4 Pro, X4 and X3 consume catalog packages and sync hardware-supported read state; retain direct mode, with a separate X3 server profile if fit requires it. | X4 Pro, X4, X3 (subject to flash/RAM validation) | planned | [Xteink clients](docs/design/backend-independence.md#4-xteink-clients) |

## Next

| # | Outcome | Platforms | Status | Design |
|---|---|---|---|---|
| 1 | **Mark done at end of book**: send the final position, then `read-status=read`, so a finished book no longer stays at 100% in Also Reading. Upstream: [progress finishes a book only at the library's threshold](docs/server-contract.md#progress-finishes-a-book-only-at-the-librarys-threshold). | Android, X4 Pro, X4, X3 | Android shipped (0.9.0); Xteink shipped (2.x rc, xteink-v2.0.0.123) | [end-of-book](docs/design/end-of-book/DESIGN.md), [mockups](https://claude.ai/artifact/QzDMmBphtiPiG41z44CBjk) |
| 2 | **End-of-book screen**: rating, then "Next in series" (from the book detail's [`seriesMembers`](docs/server-contract.md#series-members-in-book-detail)). | Android, X4 Pro, X4; X3 if strings and flash allow | Android shipped (0.9.0); Xteink shipped (2.x rc, xteink-v2.0.0.131) | [end-of-book](docs/design/end-of-book/DESIGN.md), [mockups](https://claude.ai/artifact/QzDMmBphtiPiG41z44CBjk) |
| 2a | **Next book's cover on the End-of-Book page**: the cover at the left of "Next in series", fetched by a sync (or copied from Home) and drawn offline. | X4 Pro, X4; not X3 (flash) | building (patch 0036; ships with the next Xteink release) | [build notes](docs/design/XTEINK-BUILD-NOTES.md#the-next-books-cover-patch-0036-2026-11-22), [mockups](https://claude.ai/artifact/QzDMmBphtiPiG41z44CBjk) |
| 4 | **Local-first Xteink catalog**: the write-through cache on Xteink: catalog screens open from the cache without Wi-Fi and refresh in the background. | X4 Pro, X4, X3 | building: X4s have the cache, the ⟳ on every catalog view and the offline mirror (2.x rc); background revalidation and the X3 to come | [write-through-cache](docs/design/write-through-cache.md), [local-first](docs/design/local-first/DESIGN.md) |
| 5 | **Tap to download**: a book tile downloads the book, or opens it when it is already on the device. | Android, X4 Pro, X4, X3 | idea | |
| 6 | **Series view**: shows which books are on the device and which are only on the server. | Android, X4 Pro, X4, X3 | idea | |
| 10 | **Add-on mode**: BookSync installs, updates and configures KOReader and both plugins without becoming the Home app or managing Wi-Fi and sleep; recommended settings are applied during setup in both modes (only values still at their default; the user's own are listed for review, with Undo). | Android | shipped (0.11.0); §16 lists what waits | [addon-mode](docs/design/addon-mode.md), [mockups](docs/design/addon-mode-mockups.html) |
| 10a | **Setup checklist that reads at a glance**: a summary first ("All set" or "2 things need you"), finished rows folded into one line per group, plain words with one verb per row, and "what you lose without it" on every optional, skipped or unfinished row in both modes. | Android | building (companion built; not released yet) | [companion-checklist](docs/design/companion-checklist.md), [mockups](docs/design/companion-checklist-mockups.html) |
| 6a | **Group catalog lists by series or author on Xteink**, matching Android 0.6.0. | X4 Pro, X4; not X3 | approved | [local-first](docs/design/local-first/DESIGN.md), [mockups](https://claude.ai/artifact/QzDMmBphtiPiG41z44CBjk) |
| 11 | **Sleep screen**: a recommended BookOrbit cover that changes every X hours, or the current book's cover, with optional text and the battery level at sleep; choose separate BookOrbit libraries, scopes and collections for Pick from and Leave out. | Android, X4 Pro, X4; not X3 | building: Android; X4 Pro and X4 (patch 0039) | [lock-screen](docs/design/lock-screen.md), [build notes](docs/design/XTEINK-BUILD-NOTES.md#the-sleep-screen-patch-0039-2026-11-24) |
| 12 | **Reading fonts**: an optional Setup item, off by default, that installs Bitter and Literata into KOReader. On Xteink both are already there (Bitter built in, Literata in CrossInk's Download Fonts). | Android | building | [reading-fonts](docs/design/reading-fonts.md) |
| 13 | **KOReader never freezes on background work**: the offline mirror, cache checks and other network, parse and file work run outside KOReader's UI thread (the BookSync Companion, which is required and ships with the plugin), so menus stay responsive during a Full refresh. | Android | building: step 1 (child process) merged; step 2 (the companion runs the mirror and the cache checks, 4 requests at a time; the Full refresh indicator follows the run) in review; step 3 (storage scan, copies, sleep pool, self-update) next | [companion-worker](docs/design/companion-worker.md) |
| 13a | **One offline database, a fast Full refresh with one progress number**: the whole offline cache in one SQLite file the companion writes and KOReader reads (lists reference books by id, so each book is fetched and counted once); the Full refresh's work is fixed at the start, fetched in a pipeline, and shown as one corner % that never goes down. | Android (the progress rule maps to X4 Pro, X4) | building | [sqlite-cache](docs/design/sqlite-cache.md) |
| 13b | **Manual Full refresh, silent incremental updates**: keep Android’s SQLite cache indefinitely; show progress only for a user-started run, suppress other refresh notices, bound UI database waits and probe changed books on an already connected network. | Android (existing Xteink cache unchanged) | building (rc.8 feedback fixes) | [sqlite-cache](docs/design/sqlite-cache.md) |
| 13c | **Android feedback on Xteink**: explicit-only Full refresh with one progress number, indefinite cached reads with silent incremental checks, sleep pickers that show their saved state in place, and return to the OTA screen after updating. | X4 Pro, X4; OTA on X3 if flash allows | building (user rulings, W7) | [build notes](docs/design/XTEINK-BUILD-NOTES.md#android-feedback-parity-w7) |
| 13d | **X4 Pro feedback**: named sleep libraries, visible empty picks, top-ups on existing sync connections, responsive refresh scheduling and shared Wi-Fi holds with wake diagnostics. | X4 Pro, X4; source wire format on Android | building (user-approved W8 feedback) | [build notes](docs/design/XTEINK-BUILD-NOTES.md#x4-pro-feedback-w8-200224) |
| 13e | **Complete SD catalog on X4**: Full refresh saves every browsable page and book detail within the shared storage limit, continues on Home and in the reader, and uses Android Wi-Fi modes. | X4 Pro, X4; gated off on X3 | building (user-approved W9 ruling and implementation brief) | [W9 design](docs/design/xteink-full-refresh-sd.md) |
| 14 | **Every setting in the companion**: all of the BookSync plugin's settings (sleep screen included) are set from BookSync Companion and reach KOReader, also when it isn't running; Settings becomes eight sections with search, one line per row and rows that appear only when they apply. KOReader's BookSync menu keeps them, grouped the same way. | Android | building | [companion-settings](docs/design/companion-settings.md) |
| 16 | **Root-certified update signatures**: firmware and plugin updates accept only artifacts signed by a rotatable release key certified by the offline root. | Android, X4 Pro, X4, X3 | building: verifiers log results; root setup and enforced rollout pending | [release-signing](docs/design/release-signing.md) |

## Later

| # | Outcome | Platforms | Status | Design |
|---|---|---|---|---|
| 7 | **Smarter cache**: BookOrbit's UI stays current with local state and syncs in the background, covering USB-added files, books finished while auto-sync is off, and linking BookSync downloads. | Android | idea | |
| 8b | **BookSync plugin hooks the BookOrbit board** (widget registry, `loadBookDetail`, `Activity`, `StateManager`) and replaces KOReader's menus with cleaner ones. 8a (the plugin replaces the user patch) shipped in 0.8.0. | Android | idea | [orbit-plugin](docs/design/orbit-plugin.md) |
| 9 | **No visible app switches**: KOReader stays in front and the companion runs as a background service. | Android | idea | |

## Ideas

| Outcome | Platforms | Status | Design |
|---|---|---|---|
| **Server-served battery comparison data**: a future BookSync server could serve cross-reader battery comparison data to other devices; on-device comparison remains Android-only by design (screen size), per maintainer ruling 2026-11-25. | Server, Android, X4 Pro, X4, X3 | idea (deferred) | |
| Submit the companion for Google Play Protect review. | Android | idea | |
| X3 parity review for each feature above. | X3 | idea | |
| **Repository rename bridge**: ship canonical-first update checks as the next Android Stable and next stable firmware for every reader before renaming; preserve the old-name redirects and accept recovery for readers that miss the bridge. | Android, X4 Pro, X4, X3 | building (maintainer-approved; stable publications and device validation pending) | [rename rollout](docs/repository-rename.md) |
| **One BookSync version from 0.12**: companion, plugin and all Xteink readers share a product version and release channel; previews retain unchanged platform builds, RC/stable converge with passing-test reuse by source fingerprint, and an old-scheme firmware bridge keeps OTA working across the transition. | Android, X4 Pro, X4, X3 | building (maintainer-approved W39; bridge release and device validation pending) | [unified version](docs/design/unified-version.md) |

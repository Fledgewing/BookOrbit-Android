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

Android source audit: [0.12 finish audit](docs/design/booksync-home/ANDROID-012-FINISH.md).
Implemented means present on the feature branch; device acceptance and release remain separate.

Android emulator acceptance covers fresh/0.11 upgrades, every registered widget,
catalog/settings/reading flows and offline refresh continuity; Android building,
X4 Pro/X4/X3 deferred to firmware acceptance. Reproduction: [emulator review](docs/design/booksync-home/F12-EMULATOR-REVIEW.md).

| Outcome | Platforms | Status |
|---|---|---|
| Safe connection setup, slim 0.11 upgrade (retain Wi-Fi/sign-in/Tailscale pairing and native SD books/place; BookSync settings default, history/highlights/stats/matches re-pulled from BookOrbit), verified update recovery and retained device controls through Library, with local diagnostics and first-run guidance. | X4 Pro, X4, X3; Android keeps its approved Home and native system controls | designing ([firmware screen gallery](docs/design/booksync-firmware/mockups.html); B1/B3/B4/B5 approved 2026-11-27; revised B2 once-only Sync from BookOrbit now / Later notice NEEDS APPROVAL) |
| Last 0.11 Xteink bridge drains every pending progress, stats, annotations/bookmarks and finish/state queue item to BookOrbit; offers 0.12 only when queues are empty or no account is signed in; deletes nothing. Existing F31 ordering routes old → bridge → 0.12. | X4 Pro, X4, X3; Android unchanged | approved (slim decision 2026-11-27; F28 in this repo’s `xteink/` overlay on main; implementation, device acceptance and normal release later) |
| Build the owned 0.12 firmware from CrossInk stable v2.0.0 in [booksync-firmware](https://github.com/Fledgewing/booksync-firmware), pinned at `xteink/firmware`, with all device/simulator builds and a 128 KiB app-slot reserve. | X4 Pro, X4, X3; Android unchanged | building (base approved 2026-11-27; repository/CI foundation; retained F26b credentials/Wi-Fi and F26c Tailnet/NVS identity in flight; no settings/reading-record/queue imports; normal F16/F18 sync restores server data; product rewrite and device acceptance pending) |
| Finish the server-free catalog cutover: companion-owned copies, grouping, settings recommendations and end-of-book snapshots/outboxes. | Android (Xteink deferred under Android-first ruling) | implemented on feature/0.12 (F12-Q2 step 5; device acceptance pending) |
| Open the owned Series page from the end-of-book sheet, including the last book and saved offline membership. | Android; X4 Pro, X4, X3 deferred to firmware | building (F12-endsheet implemented; device acceptance pending) |
| Recommended and Discover Home widgets select unread saved books through personal-reading providers; daily random pick and Another. | Android; X4 Pro/X4/X3 deferred to firmware | building (implemented; device acceptance and release pending) |
| Continue reading and Book list show cached covers, series, measured local time left/finish forecast and capability-aware book actions. | Android; X4 Pro/X4/X3 deferred by Android-first ruling | implemented on feature/0.12 (F12 cards and durable arbitrary-book status/Undo/removal commands; device acceptance pending) |
| Word of the day, local Reading buddy, hardware Light, Highlight and A year ago picker widgets through companion projections and a source-aggregating personal-data interface. | Android; X4 Pro/X4/X3 deferred to firmware | building (device acceptance pending) |
| Server-free Android catalog operations: companion-owned covers, refresh, copies, recommendations and end-of-book snapshots and commands. | Android; X4 Pro, X4, X3 later under Android-first ruling | implemented on feature/0.12 (companion-owned cutover complete; device acceptance pending) |
| Independent optional account, sync and OPDS logins, encrypted credentials, origin-aware sign-out and account-wide reading statistics through the library interface. | Android; X4 Pro, X4, X3 later | building (Android F12-K foundation and F12-N plugin screens implemented; device acceptance and firmware follow) |
| Configure one Book list widget with presets, paged counted sources and local Custom filters in the Home editor. | Android building; X4 Pro, X4, X3 follow Android | building (approved design rev 16; device acceptance pending) |
| Two-page Android Home and Stats default (§4), with Library widgets, shared filtered lists/search and saving custom filters as Home tiles. | Android building; X4 Pro, X4, X3 deferred by Android-first ruling | building (authorised 2026-11-25; device acceptance pending) |
| Clear, editable Custom reading values, apply-then-edit quick choices, device-local margins and one-time KOReader copy with Undo. | Android building (approved rev 16); X4 Pro, X4, X3 deferred to firmware implementation | building (F12-M; implemented, device acceptance pending) |
| On-device Home editor: add/remove/move/resize widgets, manage and name pages, reset and atomically save layouts. | Android building (authorised 2026-11-25); X4 Pro, X4, X3 deferred to firmware implementation | building (device acceptance pending) |
| Default owned Home for fresh installs and upgrades, additive migration, once-only upgrade news and clear signed-out shelves; paged widgets share one budgeted batch per paint. | Android; X4 Pro, X4, X3 later | building (authorised 2026-11-25; device acceptance pending) |

The release after 0.11.4 graduates from previews and release candidates. Built in parallel on the
`feature/0.12` branch while 0.11.4 stabilises on `main`; design and mockups need approval first
([BookSync Home design](docs/design/booksync-home/DESIGN.md), in progress). This is the first step
of [backend independence](#planned-backend-independence): BookSync owns the screens on Android and X4 together and BookOrbit
becomes a data source. X3 is a full 0.12 target: BookSync replaces the other compiled Home variants;
flash/heap fit remains a release acceptance gate. The later server-package
phase does not defer owned X4 Home; plain-base cutover follows adapter completeness.

**Widget layout engine and budgeted host contracts:** versioned layouts, immutable class
projections, M8C defaults, pure editing and previous-valid recovery — Android building
(maintainer-approved 2026-11-25); X4 Pro, X4 and X3 deferred to the firmware implementation.
The layout editor and further widgets build on this engine.

All four remaining parity gaps below ship in 0.12 (maintainer ruling 2026-11-25);
design and mockup approval still apply.

| Outcome | Platforms | Status |
|---|---|---|
| **BookSync Home** replaces the BookOrbit Home on Android and Xteink: complete reader-preset widget library retained as the staged target and rebuilt by BookSync from the offline database, instant and offline, with BookSync's own book detail page. | Android, X4 Pro, X4, X3 | building on Android (host/editor/detail and twenty-three widget types implemented; [retained inventory gaps](docs/design/booksync-home/F12-HOME-INVENTORY.md)); firmware later |
| **Retained read-only Home metrics**: distinct Today, streak, account goal, pages, monthly reading and finish forecast cards. | Android; X4 Pro, X4, X3 follow under Android-first ruling | implemented on feature/0.12 ([metrics](docs/design/booksync-home/F12-RETAINED-METRICS.md)); physical acceptance and firmware pending |

| **BookSync Home** replaces the BookOrbit Home on Android and Xteink: complete reader-preset widget library retained as the staged target and rebuilt by BookSync from the offline database, instant and offline, with BookSync's own book detail page. | Android, X4 Pro, X4, X3 | building on Android (host/editor/detail and seventeen widget types implemented; [retained inventory gaps](docs/design/booksync-home/F12-HOME-INVENTORY.md)); firmware later |
| **Retained Library roots and shortcuts**: counted saved catalog roots and named collection/library/list Book list sources. | Android; X4 Pro, X4, X3 follow Android-first | implemented on feature/0.12 ([roots](docs/design/booksync-home/F12-LIBRARY-ROOTS.md)); physical acceptance and firmware pending |

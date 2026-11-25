# Roadmap

Outcomes Orbify plans, in order. A design doc and mockups need the user's approval before an item
moves to building; when it ships it moves into [`docs/FEATURES.md`](docs/FEATURES.md)
(AGENTS.md "Features and roadmap"). Items are outcomes only: designs live in
[`docs/design/`](docs/design/).

Status: idea, designing, approved, building, shipped. Platforms: Android, X4 Pro, X4, X3 (Xteink:
CrossInk 2.x only; 1.6 is retired).

## Next

| # | Outcome | Platforms | Status | Design |
|---|---|---|---|---|
| 1 | **Mark done at end of book**: send the final position, then `read-status=read`, so a finished book no longer stays at 100% in Also Reading. Upstream: [progress finishes a book only at the library's threshold](docs/server-contract.md#progress-finishes-a-book-only-at-the-librarys-threshold). | Android, X4 Pro, X4, X3 | Android shipped (0.9.0); Xteink shipped (2.x rc, xteink-v2.0.0.123) | [end-of-book](docs/design/end-of-book/DESIGN.md), [mockups](https://claude.ai/artifact/QzDMmBphtiPiG41z44CBjk) |
| 2 | **End-of-book screen**: rating, then "Next in series" (from the book detail's [`seriesMembers`](docs/server-contract.md#series-members-in-book-detail)). | Android, X4 Pro, X4; X3 if strings and flash allow | Android shipped (0.9.0); Xteink shipped (2.x rc, xteink-v2.0.0.131) | [end-of-book](docs/design/end-of-book/DESIGN.md), [mockups](https://claude.ai/artifact/QzDMmBphtiPiG41z44CBjk) |
| 2a | **Next book's cover on the End-of-Book page**: the cover at the left of "Next in series", fetched by a sync (or copied from Home) and drawn offline. | X4 Pro, X4; not X3 (flash) | building (patch 0036; ships with the next Xteink release) | [build notes](docs/design/XTEINK-BUILD-NOTES.md#the-next-books-cover-patch-0036-2026-11-22), [mockups](https://claude.ai/artifact/QzDMmBphtiPiG41z44CBjk) |
| 4 | **Local-first Xteink catalog**: the write-through cache on Xteink: catalog screens open from the cache without Wi-Fi and refresh in the background. | X4 Pro, X4, X3 | building: X4s have the cache, the ⟳ on every catalog view and the offline mirror (2.x rc); background revalidation and the X3 to come | [write-through-cache](docs/design/write-through-cache.md), [local-first](docs/design/local-first/DESIGN.md) |
| 5 | **Tap to download**: a book tile downloads the book, or opens it when it is already on the device. | Android, X4 Pro, X4, X3 | idea | |
| 6 | **Series view**: shows which books are on the device and which are only on the server. | Android, X4 Pro, X4, X3 | idea | |
| 10 | **Add-on mode**: Orbify installs, updates and configures KOReader and both plugins without becoming the Home app or managing Wi-Fi and sleep; recommended settings are applied during setup in both modes (only values still at their default; the user's own are listed for review, with Undo). | Android | shipped (0.11.0); §16 lists what waits | [addon-mode](docs/design/addon-mode.md), [mockups](docs/design/addon-mode-mockups.html) |
| 10a | **Setup checklist that reads at a glance**: a summary first ("All set" or "2 things need you"), finished rows folded into one line per group, plain words with one verb per row, and "what you lose without it" on every optional, skipped or unfinished row in both modes. | Android | building (companion built; not released yet) | [companion-checklist](docs/design/companion-checklist.md), [mockups](docs/design/companion-checklist-mockups.html) |
| 6a | **Group catalog lists by series or author on Xteink**, matching Android 0.6.0. | X4 Pro, X4; not X3 | approved | [local-first](docs/design/local-first/DESIGN.md), [mockups](https://claude.ai/artifact/QzDMmBphtiPiG41z44CBjk) |
| 11 | **Sleep screen**: a recommended BookOrbit cover that changes every X hours, or the current book's cover, with optional text and the battery level at sleep. | Android, X4 Pro, X4; not X3 | building: Android; X4 Pro and X4 (patch 0039) | [lock-screen](docs/design/lock-screen.md), [build notes](docs/design/XTEINK-BUILD-NOTES.md#the-sleep-screen-patch-0039-2026-11-24) |
| 12 | **Reading fonts**: an optional Setup item, off by default, that installs Bitter and Literata into KOReader. On Xteink both are already there (Bitter built in, Literata in CrossInk's Download Fonts). | Android | building | [reading-fonts](docs/design/reading-fonts.md) |
| 13 | **KOReader never freezes on background work**: the offline mirror, cache checks and other network, parse and file work run outside KOReader's UI thread (the Orbit Companion, which is required and ships with the plugin), so menus stay responsive during a Full refresh. | Android | building: step 1 (child process) merged; step 2 (the companion runs the mirror and the cache checks, 4 requests at a time; the Full refresh indicator follows the run) in review; step 3 (storage scan, copies, sleep pool, self-update) next | [companion-worker](docs/design/companion-worker.md) |
| 13a | **One offline database, a fast Full refresh with one progress number**: the whole offline cache in one SQLite file the companion writes and KOReader reads (lists reference books by id, so each book is fetched and counted once); the Full refresh's work is fixed at the start, fetched in a pipeline, and shown as one corner % that never goes down. | Android (the progress rule maps to X4 Pro, X4) | building | [sqlite-cache](docs/design/sqlite-cache.md) |
| 13b | **Android feedback on Xteink**: explicit-only Full refresh with one progress number, indefinite cached reads with silent incremental checks, sleep pickers that show their saved state in place, and return to the OTA screen after updating. | X4 Pro, X4; OTA on X3 if flash allows | building (user rulings, W7) | [build notes](docs/design/XTEINK-BUILD-NOTES.md#android-feedback-parity-w7) |
| 14 | **Every setting in the companion**: all of the Orbit plugin's settings (sleep screen included) are set from Orbit Companion and reach KOReader, also when it isn't running; Settings becomes eight sections with search, one line per row and rows that appear only when they apply. KOReader's Orbit menu keeps them, grouped the same way. | Android | building | [companion-settings](docs/design/companion-settings.md) |
| 15 | **OrbiSmart sync**: one "Sync: OrbiSmart" setting; the furthest place wins on every device, a device never pushes behind the server, a move to another device's place is asked once ("Continue from Boox, p. 214? Yes / No") unless known before the page renders, and "Read from here everywhere" moves the shared place back. | Android, X4 Pro, X4; X3 sleep sync only | building: step 1 (shared table, Android) | [orbismart](docs/design/orbismart.md) |

## Later

| # | Outcome | Platforms | Status | Design |
|---|---|---|---|---|
| 7 | **Smarter cache**: BookOrbit's UI stays current with local state and syncs in the background, covering USB-added files, books finished while auto-sync is off, and linking Orbify downloads. | Android | idea | |
| 8b | **Orbit plugin hooks the BookOrbit board** (widget registry, `loadBookDetail`, `Activity`, `StateManager`) and replaces KOReader's menus with cleaner ones. 8a (the plugin replaces the user patch) shipped in 0.8.0. | Android | idea | [orbit-plugin](docs/design/orbit-plugin.md) |
| 9 | **No visible app switches**: KOReader stays in front and the companion runs as a background service. | Android | idea | |

## Ideas

| Outcome | Platforms | Status | Design |
|---|---|---|---|
| Submit the companion for Google Play Protect review. | Android | idea | |
| X3 parity review for each feature above. | X3 | idea | |
| **Shared Orbify release name**: one name (e.g. "Orbify 0.12") shown in the companion, the plugin and the Xteink About screens and in release titles, each with its own technical version underneath; marks which shared feature set (e.g. battery stats) a build has. Update logic and tags unchanged. | Android, Xteink | idea | |

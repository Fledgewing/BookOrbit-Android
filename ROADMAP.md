# Roadmap

Outcomes Orbify plans, in order. A design doc and mockups need the user's approval before an item
moves to building; when it ships it moves into [`docs/FEATURES.md`](docs/FEATURES.md)
(AGENTS.md "Features and roadmap"). Items are outcomes only: designs live in
[`docs/design/`](docs/design/).

Status: idea, designing, approved, building, shipped. Platforms: Android, X4 Pro, X4, X3.

## Next

| # | Outcome | Platforms | Status | Design |
|---|---|---|---|---|
| 1 | **Mark done at end of book**: send the final position, then `read-status=read`, so a finished book no longer stays at 100% in Also Reading. Upstream: [progress finishes a book only at the library's threshold](docs/server-contract.md#progress-finishes-a-book-only-at-the-librarys-threshold). | Android, X4 Pro, X4, X3 | idea | |
| 2 | **End-of-book screen**: rating, then "Next in series" (from the book detail's [`seriesMembers`](docs/server-contract.md#series-members-in-book-detail)). | Android, X4 Pro, X4; X3 if strings and flash allow | idea | |
| 3 | **Local-first home**: overlay local progress, status and outbox state on the cached dashboard, and redraw only when something changed. | Android | idea | |
| 4 | **Local-first Xteink catalog**: keep the list cache and open from it without Wi-Fi. | X4 Pro, X4, X3 | idea | |
| 5 | **Tap to download**: a book tile downloads the book, or opens it when it is already on the device. | Android, X4 Pro, X4, X3 | idea | |
| 6 | **Series view**: shows which books are on the device and which are only on the server. | Android, X4 Pro, X4, X3 | idea | |

## Later

| # | Outcome | Platforms | Status | Design |
|---|---|---|---|---|
| 7 | **Smarter cache**: BookOrbit's UI stays current with local state and syncs in the background, covering USB-added files, books finished while auto-sync is off, and linking Orbify downloads. | Android | idea | |
| 8 | **Orbit KOReader plugin**: replaces the user patch; hooks the BookOrbit board (widget registry, `loadBookDetail`, `Activity`, `StateManager`) and replaces KOReader's menus with cleaner ones. | Android | idea | |
| 9 | **No visible app switches**: KOReader stays in front and the companion runs as a background service. | Android | idea | |

## Ideas

| Outcome | Platforms | Status | Design |
|---|---|---|---|
| Submit the companion for Google Play Protect review. | Android | idea | |
| X3 parity review for each feature above. | X3 | idea | |

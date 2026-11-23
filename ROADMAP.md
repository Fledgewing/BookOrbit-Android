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
| 4 | **Local-first Xteink catalog**: the write-through cache on Xteink: catalog screens open from the cache without Wi-Fi and refresh in the background. | X4 Pro, X4, X3 | approved | [write-through-cache](docs/design/write-through-cache.md), [local-first](docs/design/local-first/DESIGN.md) |
| 5 | **Tap to download**: a book tile downloads the book, or opens it when it is already on the device. | Android, X4 Pro, X4, X3 | idea | |
| 6 | **Series view**: shows which books are on the device and which are only on the server. | Android, X4 Pro, X4, X3 | idea | |
| 10 | **Add-on mode**: Orbify installs, updates and configures KOReader and both plugins without becoming the Home app or managing Wi-Fi and sleep; recommended settings are applied during setup in both modes (only values still at their default; the user's own are listed for review, with Undo). | Android | shipped (0.11.0); §16 lists what waits | [addon-mode](docs/design/addon-mode.md), [mockups](docs/design/addon-mode-mockups.html) |
| 6a | **Group catalog lists by series or author on Xteink**, matching Android 0.6.0. | X4 Pro, X4; not X3 | approved | [local-first](docs/design/local-first/DESIGN.md), [mockups](https://claude.ai/artifact/QzDMmBphtiPiG41z44CBjk) |

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

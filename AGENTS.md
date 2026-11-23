# Orbify

Orbify is one ecosystem for e-readers syncing with a BookOrbit server over Tailscale: Android
readers (KOReader + the Orbit plugin + Orbit Companion) and Xteink readers (CrossInk-Bookorbit
firmware + the Tailnet overlay). Reason about both platforms together: a new feature ships on
every platform whose hardware allows it.

## Map

| Path | What | License |
|---|---|---|
| `android/koreader/` | The Orbit KOReader plugin `orbit.koplugin` (the user patch `2-orbit-android.lua` up to 0.7.x), its tests and `package.sh` (the release zip) | AGPL-3.0-or-later |
| `android/companion/` | Orbit Companion app, package `net.fledgewing.orbitcompanion` | MIT |
| `android/docs/` | Android designs, the plugin–companion interface, setup guide | MIT |
| `xteink/` | CrossInk-Tailnet overlay: MicroLink submodule, shim, UI, patch series per CrossInk line | MIT (binaries GPL-3.0, see `xteink/README.md`) |
| `docs/FEATURES.md` | What Orbify ships, per platform | MIT |
| `ROADMAP.md` | What Orbify plans: outcomes and status | MIT |
| `docs/server-contract.md` | The BookOrbit endpoints we use and how the server really behaves | MIT |
| `docs/design/` | Cross-platform feature designs | MIT |
| `shared/fixtures/` | Recorded responses that both platforms' tests read | MIT |
| `tools/install-usb.sh` | One-shot Android install over USB | MIT |
| `tools/upstreams` | Clones pinned upstream source into `upstream/` (gitignored) | MIT |

## Platforms

| Column | Device | Build |
|---|---|---|
| KOReader-Android | Android e-readers (Boox, Meebook…) | plugin + companion |
| X4 Pro | Xteink X4 Pro, ESP32-S3 + PSRAM | `x4-pro` |
| X4 | Xteink X4 Classic, ESP32-S3 + PSRAM | `x4-classic` |
| X3 | Xteink X3 and C3 X4, ESP32-C3, no PSRAM; flash nearly full | `default` |

Xteink firmware is built on CrossInk 2.x only. CrossInk 1.6 is retired: no builds, no patches
(they are in git history); its readers stay on the stable `xteink-v1.6.1.114` until a final
CrossInk 2.x release becomes the stable one (`xteink/README.md` "Releases and the update feed").

## Product principles

- **Nothing interrupts reading.** While a book is open in the foreground, nothing from Orbify,
  the companion or BookOrbit (as far as we can intercept it) appears on screen, restarts KOReader
  or takes focus. It waits for the next moment nobody is reading, or is dropped when stale. The
  only exceptions are what the reader does in the book: menus they open, the end-of-book sheet.
  Enforced by one gate per side (plugin `reading()`/`Gate.show`, companion `Reading`) and guard
  tests that fail on a new show or notify path that bypasses it
  ([design](docs/design/reading-gate.md)). Xteink firmware follows the same rule.

## Read the source, not memory

`tools/upstreams` checks out BookOrbit (server, web app, `koreader-plugin/`), CrossInk-Bookorbit
2.x, and KOReader at the commits in `tools/upstreams.lock`. Cite `file:line` at the pinned
commit when a design or `docs/server-contract.md` relies on upstream behaviour; re-pin with
`tools/upstreams pin <name> <ref>`.

## Features and roadmap

- Every new feature request goes into `ROADMAP.md` first, as a one-line outcome with its
  platforms and status (idea, designing, approved, building, shipped).
- Its design doc (`docs/design/`) and mockups need the user's approval before the item moves to
  building.
- `docs/FEATURES.md` lists what is shipped. When an item ships, move it from `ROADMAP.md` into
  `docs/FEATURES.md` in the same change, so the two never disagree.
- Both list only what **we** add, never features of KOReader, BookOrbit or CrossInk themselves.
  Where a feature only makes up for an upstream behaviour, give that behaviour one line, linked to
  its section in `docs/server-contract.md`.

## Releases

One repo releases both platforms; the tag prefix says which.

- Android: `v<version>` (`.github/workflows/release.yml`): signed APK, stamped plugin zip,
  `SHA256SUMS`, attestations. Always marked "latest". Keep the package id and the signing
  certificate (SHA-256 `F5:07:8C:…:0A:15`, checked by the workflow): either change breaks updates.
- Xteink: `xteink-v<version>` (`.github/workflows/xteink.yml`, daily or by hand): firmware per
  reader, source archive, licenses, `SHA256SUMS`, attestations. Always `make_latest=false`.
  An upstream rc or beta builds a pre-release, a final upstream release a stable one
  (`xteink/scripts/upstream-line.sh`).
- "latest" must stay an Android release: every companion and plugin (and the old patch) reads `releases/latest`
  (0.6.x through the old BookOrbit-Android URL, and it parses only `v<version>` tags).
- GitHub orders the release list by version-like tag name: `v…` tags first, prefixed tags
  after all of them. So Android keeps plain `v…` tags (its pre-release check reads the list),
  and readers find firmware through the feed `xteink/releases.json` on the `xteink-feed`
  branch (newest stable and pre-release, written by the xteink workflow), never the list. The
  Android pieces also read `android-v` tags and skip `xteink-v` ones.
- A tag is never moved: fix forward with the next version.

## Checks

- Android: `luajit android/koreader/test/test_logic.lua`, `.../test_flows.lua`,
  `bash tools/test/test-install-usb.sh`, and in `android/companion`
  `./gradlew testDebugUnitTest assembleDebug lintDebug` (CI: `.github/workflows/android.yml`).
- Xteink: `xteink/scripts/apply.sh <CrossInk checkout>`, `xteink/test/run-host-tests.sh <checkout>`,
  then `pio run -e <env>` (CI: `.github/workflows/xteink.yml`, all three readers; pushes build the
  CrossInk pinned as `crossink-v2.0` in `tools/upstreams.lock`, daily runs build upstream's newest
  2.x tag, rc included).
- BookOrbit plugin hooks: `luajit android/koreader/test/plugin_compat.lua <plugin dir>`
  (weekly in `.github/workflows/plugin-compat.yml`).
- KOReader hooks: `luajit android/koreader/test/koreader_compat.lua <koreader> [<koreader-base>]`
  (`.github/workflows/koreader-compat.yml`: the pinned `koreader` from `tools/upstreams.lock` on
  every push, KOReader's newest stable tag weekly and on demand). Add each new KOReader symbol the
  plugin uses to that file's list.

## Repo rules

- Commits use the repo's noreply identity; stage explicit paths.
- No personal names, emails, hostnames or IPs in the repo; never print or commit secrets.

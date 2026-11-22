# Orbify

Orbify is one ecosystem for e-readers syncing with a BookOrbit server over Tailscale: Android
readers (KOReader + the Orbify patch + Orbit Companion) and Xteink readers (CrossInk-Bookorbit
firmware + the Tailnet overlay). Reason about both platforms together: a new feature ships on
every platform whose hardware allows it.

## Map

| Path | What | License |
|---|---|---|
| `android/koreader-patch/` | KOReader user patch `2-orbit-android.lua` (later `android/koreader/`, the Orbit plugin) | AGPL-3.0-or-later |
| `android/companion/` | Orbit Companion app, package `net.fledgewing.orbitcompanion` | MIT |
| `android/docs/` | Android designs, the patch–companion interface, setup guide | MIT |
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
| KOReader-Android | Android e-readers (Boox, Meebook…) | patch + companion |
| X4 Pro | Xteink X4 Pro, ESP32-S3 + PSRAM | `x4-pro` |
| X4 | Xteink X4 Classic, ESP32-S3 + PSRAM | `x4-classic` |
| X3 | Xteink X3 and C3 X4, ESP32-C3, no PSRAM; flash nearly full | `default` |

## Read the source, not memory

`tools/upstreams` checks out BookOrbit (server, web app, `koreader-plugin/`), CrossInk-Bookorbit
1.6 and 2.x, and KOReader at the commits in `tools/upstreams.lock`. Cite `file:line` at the pinned
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

- Android: `android-v<version>` (`.github/workflows/release.yml`): signed APK, stamped patch,
  `SHA256SUMS`, attestations. Always marked "latest". Keep the package id and the signing
  certificate (SHA-256 `F5:07:8C:…:0A:15`, checked by the workflow): either change breaks updates.
- Xteink: `xteink-v<version>` (`.github/workflows/xteink.yml`, daily or by hand): firmware per
  reader, source archive, licenses, `SHA256SUMS`, attestations. Always `make_latest=false`.
- "latest" must stay an Android release: companions and patches up to 0.6.2 read
  `releases/latest` (through the old BookOrbit-Android URL) and parse only `v<version>` tags,
  which is why v0.7.0 is tagged `v0.7.0`. The Android pieces read `android-v` and `v` tags; the
  firmware reads the release list and keeps `xteink-v` tags (overlay patch `ota-tag-prefix`).
- A tag is never moved: fix forward with the next version.

## Checks

- Android: `luajit android/koreader-patch/test/test_logic.lua`, `.../test_flows.lua`,
  `bash tools/test/test-install-usb.sh`, and in `android/companion`
  `./gradlew testDebugUnitTest assembleDebug lintDebug` (CI: `.github/workflows/android.yml`).
- Xteink: `xteink/scripts/apply.sh <CrossInk checkout>`, `xteink/test/run-host-tests.sh <checkout>`,
  then `pio run -e <env>` (CI: `.github/workflows/xteink.yml`, all three readers).
- BookOrbit plugin hooks: `luajit android/koreader-patch/test/plugin_compat.lua <plugin dir>`
  (weekly in `.github/workflows/plugin-compat.yml`).

## Repo rules

- Commits use the repo's noreply identity; stage explicit paths.
- No personal names, emails, hostnames or IPs in the repo; never print or commit secrets.

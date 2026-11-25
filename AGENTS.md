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
| `xteink/` | CrossInk-Tailnet overlay: MicroLink submodule, shim, UI, patch series per CrossInk line | MIT; firmware code moved out of the patches (`SPDX-License-Identifier: GPL-3.0-or-later`) and the binaries GPL-3.0, see `xteink/README.md` |
| `docs/FEATURES.md` | What Orbify ships, per platform | MIT |
| `ROADMAP.md` | What Orbify plans: outcomes and status | MIT |
| `docs/server-contract.md` | The BookOrbit endpoints we use and how the server really behaves | MIT |
| `docs/design/` | Cross-platform feature designs | MIT |
| `shared/fixtures/` | Recorded responses that both platforms' tests read | MIT |
| `tools/install-usb.sh` | One-shot Android install over USB | MIT |
| `tools/sideload-android.sh`, `tools/sideload-xteink.sh` | Put a test build on a test device over USB ("Test builds" below) | MIT |
| `tools/upstreams` | Clones pinned upstream source into `upstream/` (gitignored) | MIT |
| `tools/attest-check/` | Fails when the pinned BookOrbit server requires app attestation on a route Orbify calls | MIT |
| `tools/feed-keys/`, `shared/release-signing.json` | Release signing keys for firmware, the feed and the plugin zip ([design](docs/design/release-signing.md)) | MIT |

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
  only exceptions are what the reader does in the book: menus they open, the end-of-book sheet;
  and, by the user's ruling, OrbiSmart's one-draw "Continue from <device>, p. N? Yes / No" popup
  ([orbismart](docs/design/orbismart.md)).
  Enforced by one gate per side (plugin `reading()`/`Gate.show`, companion `Reading`) and guard
  tests that fail on a new show or notify path that bypasses it
  ([design](docs/design/reading-gate.md)). Xteink firmware follows the same rule.

- **KOReader's UI thread stays free; the companion does the work.** Network, parsing, comparing,
  file writes and folder scans for Orbit's own background work run in the Orbit Companion, never on
  KOReader's single thread ([design](docs/design/companion-worker.md)). The companion is required
  and ships with the plugin: no fallback path in the plugin for a job the companion owns, and no
  version-skew handling. One check (`Companion.workerProblem`): missing or another version shows
  "Orbit Companion needed" or "Update Orbit Companion" and nothing heavy runs.

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
- Both release workflows first run the emulated release tests (`release-tests.yml`, below) on the
  release commit; nothing publishes unless they pass.

## Test builds: sideload first, release after

Test a change on a real device before any release: build a test build, sideload it over USB,
and publish the release only once it works there. Test builds are workflow artifacts only: no
tag, no release, never offered by any updater. The scripts print what they will change and
ask before changing it (`--yes` skips the question). Agents never run them against a device.

- Android: `gh workflow run release.yml --ref <branch> -f publish=false`, then
  `tools/sideload-android.sh <run id> [--serial S] [--plugin-only]`. The build is release-signed
  (the only key that updates an installed companion) and versioned `<next patch>-0.test.<run>`
  (`tools/android-test-version.sh`): it installs over the last release, and the next release or
  pre-release is newer, so the device updates normally afterwards. The companion and the plugin
  never pick a test version from a release list (`TestBuild`, `Update.isTest`), and release.yml
  refuses to publish one. The script checks SHA256SUMS and the signing certificate, `adb install
  -r`s the APK (its settings stay), swaps in the plugin as the companion does, and restarts
  KOReader with the companion's `restart` command.
- Xteink: `gh workflow run xteink.yml --ref <branch> -f test_build=true` (a pull request's
  build works too), then `tools/sideload-xteink.sh <run id> --port /dev/cu.usbmodemXXXX --env
  x4-pro|x4|x3`. It checks the image's SHA-256 and chip, refuses a reader whose chip doesn't
  match `--env` or a port another program holds (it stops nothing), reads the offsets from the
  reader's partition table (checked against the build's `.parttable`), writes the image to
  `ota_0` and blanks `otadata` so `ota_0` boots. NVS (Wi-Fi, Tailscale keys, settings) and the
  SD card are untouched. The test build's fourth version number is below every later run's, so
  the reader takes the next release over the air.
- Tests: `bash tools/test/test-sideload.sh` (CI: android.yml).

## Checks

- Android: `luajit android/koreader/test/test_logic.lua`, `.../test_flows.lua`,
  `bash tools/test/test-install-usb.sh`, `bash tools/test/test-sideload.sh`, and in `android/companion`
  `./gradlew testDebugUnitTest assembleDebug lintDebug` (CI: `.github/workflows/android.yml`).
- Xteink: `xteink/scripts/apply.sh <CrossInk checkout>`, `xteink/test/run-host-tests.sh <checkout>`,
  then `pio run -e <env>` (CI: `.github/workflows/xteink.yml`, all three readers; pushes build the
  CrossInk pinned as `crossink-v2.0` in `tools/upstreams.lock`; daily runs first move that pin to
  upstream's newest 2.x tag, rc included, and always build the commit the lock records).
- Workflows: `python3 tools/test/test-workflows.py` and actionlint (CI: `.github/workflows/workflow-lint.yml`):
  actions pinned by SHA, no stored checkout credentials, and no write permission, secret or token
  in a job that runs a build tool. Steps shared by several workflows live in `.github/actions/`.
- BookOrbit app attestation: `tools/upstreams check` (CI: the app-attest job in
  `.github/workflows/plugin-compat.yml`): fails when the pinned server requires app attestation on
  a route Orbify calls (`docs/server-contract.md` "App attestation"). Tests:
  `node --test tools/attest-check/test/check.test.mjs` after `npm ci --prefix tools/attest-check`.
- BookOrbit plugin hooks: `luajit android/koreader/test/plugin_compat.lua <plugin dir>`
  (weekly in `.github/workflows/plugin-compat.yml`).
- KOReader hooks: `luajit android/koreader/test/koreader_compat.lua <koreader> [<koreader-base>]`
  (`.github/workflows/koreader-compat.yml`: the pinned `koreader` from `tools/upstreams.lock` on
  every push, KOReader's newest stable tag weekly and on demand). Add each new KOReader symbol the
  plugin uses to that file's list.

## Emulated release tests

What a release must pass with no device (`docs/design/emulated-release-tests.md`;
CI: `.github/workflows/release-tests.yml`, called by both release workflows, run on pull requests
that change the tests, or by hand from the Actions tab). Locally, with Docker:

- Stage 0, the server kit: `python3 tools/e2e/kit.py up` starts BookOrbit (pinned by digest in
  `tools/e2e/compose.yml`) and seeds the synthetic library (`shared/fixtures/e2e/library.json`);
  `python3 tools/e2e/test_kit.py` tests the fault proxy, `ORBIFY_E2E_LIVE=1` adds the live server.
  `kit.py down` removes it all.
- Stage 1, Xteink: after `apply.sh`, `pio run -e x4-pro-simulator` (or `x4-classic-simulator`,
  `simulator-X3`) in the CrossInk checkout, then
  `python3 xteink/test/e2e/run.py --checkout <checkout> --profile x4-pro [--scenario NAME]`.
  Logs, screenshots and the proxy's request log land in `--out`. Linux needs `libsdl2-dev
  libssl-dev libwolfssl-dev pkg-config`.
- Stage 2, Android: `./gradlew testDebugUnitTest` in `android/companion` (Robolectric included;
  every push runs it in `android.yml`).
- A failing scenario is a bug in the firmware or in the test, never retried into green.

## Upstream projects

Orbify only. Never open pull requests or issues, or send patches, to the projects we build on
(CrossInk-Bookorbit, BookOrbit, KOReader, MicroLink, the CrossInk simulator). Work around
anything upstream inside Orbify: an overlay patch, a build-time edit of a fetched package
(`xteink/tailnet/sim/sim_package.py`), or a test-side shim.

## Repo rules

- Commits use the repo's noreply identity; stage explicit paths.
- No personal names, emails, hostnames or IPs in the repo; never print or commit secrets.

## Dependency checksum updates

The companion uses strict Gradle dependency verification, including POM and module metadata,
in `android/companion/gradle/verification-metadata.xml`. For a dependency update, regenerate
with `./gradlew --write-verification-metadata sha256 testDebugUnitTest assembleDebug assembleRelease lintDebug`,
review the changed coordinates and checksums against their publishing repositories, and run
again without the generation flag. Include Linux's aapt2 artifact as well as the local platform's.
Never disable verification or add broad trust exceptions to make CI pass.

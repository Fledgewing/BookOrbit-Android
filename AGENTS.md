# BookSync

BookSync is one ecosystem for e-readers syncing with a BookOrbit server over Tailscale: Android
readers (KOReader + the BookSync plugin + BookSync Companion) and Xteink readers (CrossInk-Bookorbit
firmware + the Tailnet overlay). Reason about both platforms together: a new feature ships on
every platform whose hardware allows it.

## Map

| Path | What | License |
|---|---|---|
| `android/koreader/` | The BookSync KOReader plugin `orbit.koplugin` (the user patch `2-orbit-android.lua` up to 0.7.x), its tests and `package.sh` (the release zip) | AGPL-3.0-or-later |
| `android/companion/` | BookSync Companion app, package `net.fledgewing.orbitcompanion` | MIT |
| `android/docs/` | Android designs, the plugin–companion interface, setup guide | MIT |
| `xteink/` | CrossInk-Tailnet overlay: MicroLink submodule, shim, UI, patch series per CrossInk line | MIT; firmware code moved out of the patches (`SPDX-License-Identifier: GPL-3.0-or-later`) and the binaries GPL-3.0, see `xteink/README.md` |
| `docs/FEATURES.md` | What BookSync ships, per platform | MIT |
| `ROADMAP.md` | What BookSync plans: outcomes and status | MIT |
| `docs/server-contract.md` | The BookOrbit endpoints we use and how the server really behaves | MIT |
| `docs/design/` | Cross-platform feature designs | MIT |
| `shared/fixtures/` | Recorded responses that both platforms' tests read | MIT |
| `tools/install-usb.sh` | One-shot Android install over USB | MIT |
| `tools/sideload-android.sh`, `tools/sideload-xteink.sh` | Put a test build on a test device over USB ("Test builds" below) | MIT |
| `tools/upstreams` | Clones pinned upstream source into `upstream/` (gitignored) | MIT |
| `tools/attest-check/` | Fails when the pinned BookOrbit server requires app attestation on a route BookSync calls | MIT |
| `tools/feed-keys/`, `shared/release-signing.json` | Release signing keys for firmware, the feed and the plugin zip ([design](docs/design/release-signing.md)) | MIT |

## Platforms

| Column | Device | Build |
|---|---|---|
| KOReader-Android | Android e-readers (Boox, Meebook…) | plugin + companion |
| X4 Pro | Xteink X4 Pro, ESP32-S3 + PSRAM | `x4-pro` |
| X4 | Xteink X4 Classic, ESP32-S3 + PSRAM | `x4-classic` |
| X3 | Xteink X3 and C3 X4, ESP32-C3, no PSRAM; flash nearly full | `default` |

Xteink firmware is built on CrossInk 2.x only. CrossInk 1.6 is retired: no builds, no patches
(they are in git history); its readers stay on the stable `xteink-v1.6.1.114` until a stable
CrossInk 2.x bridge and the later stable BookSync releases become available (`xteink/README.md` "Releases and the update feed").

## Product principles

- **UI calls BookSync's library interface.** Binding on the KOReader plugin, Android companion
  and Xteink overlay. Maintainer rule 2026-11-26, verbatim:
  "all API calls the UI makes should be to our own interface so that we can plumb BookOrbit / Grimmory separately."
  Personal reading data follows the maintainer ruling (2026-11-26), verbatim:
  "I would build it so that all UI calls for that kind of data go through our interface, which then chooses where to fetch / aggregate data from. We start with on-device info and can extend to server but the ui never needs to change."
  Request a personal-data kind, never a source. Companion providers declare capabilities,
  merge in registration order and deduplicate neutral identities; missing/failing providers
  are skipped. Future remote providers register inside their server adapter, never in UI.
  UI code calls only BookSync's library interface; BookOrbit and Grimmory are adapters behind it.
  Gate server-dependent features on adapter capabilities, never server identity. Filters are
  neutral objects that adapters translate, with local fallback on the cached catalog.
  The interface is introduced in 0.12 ([BookSync Home's owned-client design](docs/design/backend-independence.md#1-owned-android-client-and-ledger)).

- **Server adapters own protocol.** Android endpoint paths, authentication, upstream transport primitives, backend JSON and
  backend terms live only in the companion's `server/bookorbit` package (Kotlin).
  Android plugin Lua has no server adapter exemption. `ServerAdapters.kt` wires protocol
  implementations; the plugin loader binds only neutral local retirement metadata. Direct legacy Lua globals are not an interface: use Library or the
  reviewed Server facade; local file IO belongs to generic Store. UI uses the neutral
  library/read model and capability flags. Run
  `python3 tools/test/test-server-boundary.py`; no baseline, suppression or skip list is allowed.
  The guard scans production resources and shared Settings/UI data too; About credit prose may name its credited project.
  See `docs/design/backend-independence.md` for adapter registration and legacy follow-ups.
  A transport cutover must checkpoint every unacknowledged lifecycle phase before retiring
  its source queue. Android sync now uses only neutral Library companion commands; keep policy,
  durable decision state and all five lifecycle phases in the companion single owner. Never activate a replacement position writer while the legacy writer
  can still drain that document; a durable position queue alone is not a lifecycle migration.

- **Nothing interrupts reading.** While a book is open in the foreground, nothing from BookSync,
  the companion or BookOrbit (as far as we can intercept it) appears on screen, restarts KOReader
  or takes focus. It waits for the next moment nobody is reading, or is dropped when stale. The
  only exceptions are what the reader does in the book: menus they open, the end-of-book sheet;
  and, by the user's ruling, BookSync position sync's one-draw "Continue from <device>, p. N? Yes / No" popup
  ([position sync](docs/design/position-sync.md)).
  Enforced by one gate per side (plugin `reading()`/`Gate.show`, companion `Reading`) and guard
  tests that fail on a new show or notify path that bypasses it
  ([design](docs/design/reading-gate.md)). Xteink firmware follows the same rule.

- **KOReader's UI thread stays free; the companion does the work.** Network, parsing, comparing,
  file writes and folder scans for BookSync's own background work run in the BookSync Companion, never on
  KOReader's single thread ([design](docs/design/companion-worker.md)). The companion is required
  and ships with the plugin: no fallback path in the plugin for a job the companion owns, and no
  version-skew handling. One check (`Companion.workerProblem`): missing or another version shows
  "BookSync Companion needed" or "Update BookSync Companion" and nothing heavy runs.

## UI-interface rule

Maintainer ruling (2026-11-26), verbatim:
"This puts all decisions of syncing, aggregating, and anything else in our BookSync interface, and the UI never needs to talk to anything else (other than controlling KOReader as needed)"
Confirmed after concrete examples: "Perfect that's the goal".

Plugin screens, widgets, menus, dialogs, sleep menus, Home host/editor, badges and status
call only `ko/library.lua` and its deliberate interface services, other UI composition,
neutral pure utilities, and KOReader. Transport, source selection, aggregation, caching,
persistence, settings wire formats, command authentication and companion messaging belong
behind the interface. Never reference Companion, Store, Cache, SettingsSync, Jni or private
shared globals from UI, including through aliases or imports. `android/koreader/module-layers.json`
is the complete role inventory, including the purpose of each module. Add a role for every
new file; an unclassified or stale entry fails `python3 tools/test/test-ui-boundary.py`.
No path skips or line exceptions. Mixed modules must split presentation from service work.
The existing per-screen/widget budgets also apply to interface services; moving code does
not authorize catalog work, new subprocesses, network on paint, or additional paint round-trips.

## Screen and widget performance budgets

Recommended and Discover inherit one-book/16 KiB budgets; companion personal-reading providers own ranking and daily selection. Another changes only an interface-owned persisted pick, never scans on paint.

Highlight and A year ago also inherit one-row/16 KiB budgets. Companion providers own
sidecar parsing, calendar selection, aggregation and dedupe; Lua never scans personal data.

Local optional widgets inherit one-row/16 KiB budgets too: companion-owned vocabulary selection
and reading messages; native frontlight scalars only in Library. Paint never scans local history.

Nested group covers and Series next-book previews count as rows in the caller budget;
never hide multiple display records behind a single summary row. Companion materialization
owns their ordering, counts and status labels.

Maintainer rule 2026-11-25: every screen and widget declares a strict budget; library
interface calls inherit the caller's budget; adapter projections preserve the same row/byte limits. Keep filtering, sorting, grouping, counts,
search, stats, battery estimates and catalog joins in the companion; Lua only reads small,
ready-to-draw windows. Enforce deterministic row/window and decoded-byte limits, zero
subprocess spawns and render-path network calls, at most one batched companion round-trip
per Home paint, and at most 16 KiB per widget snapshot. Declare limits in
`logic/budgets.lua`/the widget registry and test missing or exceeded budgets. Log one
info-level timing span per call/paint; host timing is not a device performance test.
Server sign-in commands run off the UI thread; their three-login screen reads one small private state snapshot and never secrets. Account sign-out removes account-origin connectors; directly entered logins stay.
Battery projections also inherit their caller budget: one local row, no more than 14 daily entries,
five charges and three mode estimates inside the 16 KiB snapshot. Battery UI selects companion-formatted
labels and seven-day display windows; it never computes estimates, rates, dates or daily totals.
Stats widgets share one materialized `reading.stats` row per paint; aggregate and resolve per-field
server/local precedence and provenance in the companion, never in Lua.
First-run and upgrade sheets are screens too: declare static row limits and zero-work budgets when they need no library data.

Enforce each caller's remaining row/byte allowance before SQLite returns or Lua decodes a
snapshot, including status JSON behind interface services. Post-paint cover delivery and
acquisition yield in windows of four, including bursts of asynchronous answers. Companion
personal-reading pools belong to one publication batch: read each kind once and calculate
each Discover candidate's daily rank once, never inside a sort comparator. Keep regression
fixtures at 10,000+ books and long reading histories; record host timing separately from device acceptance.

Device targets pending confirmation: Home <500 ms, widget <50 ms, cached library window
<30 ms, editor move <100 ms. Owned Home widgets receive immutable snapshots and a dispatch handle;
only their host owns the batched read and read-model invalidation. Layout moves validate only
their changed page, bounded by the placement count. Home pages and Settings groups inherit
their screen-family budget. Owned list and Search screens inherit the Library screen-family budget. Settings paints read only shared values and bounded library snapshots;
choice catalogs stay in the companion until the library exposes bounded windows. Sleep choice pages read at most six names/counts and 16 KiB; device settings use one lifecycle-cached local row. Filter picker
pages inherit the filter screen budget; facet counts and zero-value ordering stay in the companion.
Home editor moves project only the current page and draw bounded geometry controls (no widget
snapshots, JSON decode, file IO or library round-trip); atomic layout validation/save runs on Done.
Book list settings use a zero-read budget; source picker pages read at most six companion-materialized
source rows and 16 KiB in one batch. Presets share the Book list renderer and widget budget.
Reader progress surfaces reuse a one-row widget budget, including Book info and
Details; completion callbacks redraw only a still-visible user-opened panel.
Explicit reader surfaces may read their bounded local SQLite snapshots while a book
is open; background reads remain memo-only and the reading notification gate stays engaged.

Reader controls copy at most 64 already-loaded native chapter and annotation entries per kind;
the companion projects their marker/position snapshot. Never load a TOC, scan a sidecar or
construct a full bookmark index on a panel paint. Native actions stay behind Library.

Cover lookups use a one-row, 16 KiB local-only budget with zero round-trips; post-paint
cover batches are limited to four and only the companion fetches or writes images.
Copy replacement and finish outboxes are companion-owned, account scoped and checkpointed before legacy sources retire. Grouped lists and end-of-book cards are bounded projections; local recommendation review has eight rows. No catalog transport or whole-list aggregation runs in Lua. Keep queue checkpoints available while reading; pause background transfer work, never persistence of reader intent.

Catalog progress is one companion-published row (16 KiB) with zero polling round-trips.
Catalog/root windows decode at most 24 display rows; native Home batches count every nested
book/name plus their stats row. Plans, query interpretation, refresh policy and search stay
on the companion; preserve outstanding copy/finish/lifecycle queues during later cutovers.

Custom reading editors inherit a named screen budget through the library interface: one small
device-local record, no catalog work, decoded JSON, network, subprocess or companion round-trip.
Each editor paint and style operation logs one info-level timing span; host timings are not device acceptance.

## Read the source, not memory

`tools/upstreams` checks out BookOrbit (server, web app, `koreader-plugin/`), CrossInk-Bookorbit
2.x, and KOReader at the commits in `tools/upstreams.lock`. Cite `file:line` at the pinned
commit when a design or `docs/server-contract.md` relies on upstream behaviour; re-pin with
`tools/upstreams pin <name> <ref>`.

## Features and roadmap

- Plan every feature across Android, X4 Pro, X4 and X3. The platform reference is
  `shared/features.json`, rendered as `docs/FEATURES.md`. Every PR that adds or changes a
  user-facing feature or setting updates all four platform cells, with a reason for every
  partial, missing or not-applicable cell. Put "why not on this device" and maintainer rulings
  in the cell's `reason`; put later ideas in `deferred` (and `ROADMAP.md`). Regenerate with
  `python3 tools/features.py`; check with `python3 tools/test/test-features.py`.
- Every new feature request goes into `ROADMAP.md` first, as a one-line outcome with its
  platforms and status (idea, designing, approved, building, shipped).
- Its design doc (`docs/design/`) and mockups need the user's approval before the item moves to
  building.
- `docs/FEATURES.md` lists what is shipped. When an item ships, move it from `ROADMAP.md` into
  `shared/features.json` and regenerate `docs/FEATURES.md` in the same change, so the two never
  disagree.
- Both list only what **we** add, never features of KOReader, BookOrbit or CrossInk themselves.
  Where a feature only makes up for an upstream behaviour, give that behaviour one line, linked to
  its section in `docs/server-contract.md`.

## Releases

One repo releases both platforms; the tag prefix says which. From 0.12, the product
version comes from shared/version.json on the release commit, shared by the companion,
packaged plugin and every firmware build. The ordering is -preview.N, then -rc.N, then stable. release.yml dispatches firmware at the same immutable tag. Previews may retain older
unchanged platform builds; RC/stable stamp every platform with the same version.
Source fingerprints select preview builds and permit reuse of passing component/release
tests at the same scope; cheap artifact/version/signature checks still run. Android
companion and plugin remain one publication unit with matching installed versions.
See [the rollout and bridge](docs/design/unified-version.md). Main stays on 0.11 until its
bridge has reached devices; 0.12 is prepared on feature/0.12.

The upstream-driven Xteink release policy below applies through 0.11. From 0.12,
firmware tags are xteink-v<booksync version>+crossink.<upstream tag>, with the upstream
"+" replaced by ".". BookSync preview/rc/stable decides the channel. Daily pinning and
publication remain limited to the legacy bridge line; unified builds keep the release
commit's pin and publish only at the matching Android tag.

- Android: `v<version>` (`.github/workflows/release.yml`): signed APK, stamped plugin zip,
  `SHA256SUMS`, attestations. Stable Android releases take "latest". Keep the package id and the signing
  certificate (SHA-256 `F5:07:8C:…:0A:15`, checked by the workflow): either change breaks updates.
- Android/plugin builds start as `vMAJOR.MINOR.PATCH-preview.N`; use `-rc.N` only when a
  maintainer judges it a real release candidate, then the plain version for stable. Preview
  release titles are `BookSync 0.11.4 preview 1`. The next published preview is
  `v0.11.4-preview.1`: bumping the patch makes it newer than every `0.11.3-rc.N` already
  installed. Within a patch, semver orders `preview.N < rc.N < stable`.
  See [version encoding](docs/design/release-versions.md) for Android package codes.
- Xteink: `xteink-v<version>` (`.github/workflows/xteink.yml`, daily or by hand): firmware per
  reader, source archive, licenses, `SHA256SUMS`, attestations. Always `make_latest=false`.
  An upstream rc or beta builds a pre-release, a final upstream release a stable one
  (`xteink/scripts/upstream-line.sh`). Firmware tags keep CrossInk's upstream rc/beta labels;
  they describe the upstream base, not a judgment that our overlay is a release candidate.
- "latest" must stay an Android release: older companions and plugins (and the old patch) read
  `releases/latest` (0.6.x through the old BookOrbit-Android URL, parsing only `v<version>` tags).
  The companion now verifies the signed Android feed on `android-feed`, at `android/releases.json`;
  withdrawals and recovery are described in `docs/design/release-safety.md`.
- GitHub orders the release list by version-like tag name: `v…` tags first, prefixed tags
  after all of them. So Android keeps plain `v…` tags (older pre-release checks read the list),
  and readers find firmware through the feed `xteink/releases.json` on the `xteink-feed`
  branch (current stable/prerelease plus retained legacy bridges, written by the xteink workflow), never the list. The
  Android pieces also read `android-v` tags and skip `xteink-v` ones.
- A tag is never moved: fix forward with the next version.
- Both release workflows require passing emulated release tests (`release-tests.yml`, below).
  From 0.12, identical source fingerprints may reuse passing evidence; version-only promotion
  still rebuilds and checks artifacts. Missing evidence runs the full gate. See the
  [selective release policy](docs/design/unified-version.md#selective-previews-and-promotion).

## Test builds: sideload first, release after

Test a change on a real device before any release: build a test build, sideload it over USB,
and publish the release only once it works there. Test builds are workflow artifacts only: no
tag, no release, never offered by any updater. The scripts print what they will change and
ask before changing it (`--yes` skips the question). Agents never run them against a device.

- Android: `gh workflow run release.yml --ref <branch> -f publish=false`, then
  `tools/sideload-android.sh <run id> [--serial S] [--plugin-only]`. The build is release-signed
  (the only key that updates an installed companion) and versioned `<patch>-preview.<run>`
  (`tools/android-test-version.sh`): the helper continues a preview patch or bumps the patch
  after an RC/stable tag. These workflow artifacts create no release or tag. Published previews
  use the same version format and are offered with Include previews and release candidates;
  choose a number above any preview already sideloaded. Legacy `-0.test.N` artifacts remain
  excluded from release selection and publication. The script checks SHA256SUMS and the signing
  certificate, `adb install
  -r`s the APK (its settings stay), swaps in the plugin as the companion does, and restarts
  KOReader with the companion's `restart` command.
- Xteink: `gh workflow run xteink.yml --ref <branch> -f test_build=true` (a pull request's
  build works too), then `tools/sideload-xteink.sh <run id> --port /dev/cu.usbmodemXXXX --env
  x4-pro|x4|x3`. It checks the image's SHA-256 and chip, refuses a reader whose chip doesn't
  match `--env` or a port another program holds (it stops nothing), reads the offsets from the
  reader's partition table (checked against the build's `.parttable`), writes the image to
  `ota_0` and blanks `otadata` so `ota_0` boots. NVS (Wi-Fi, Tailscale keys, settings) and the
  SD card are untouched. Through 0.11, the test build's fourth version number is below every later run's.
  From 0.12, its BookSync identity is <version core>-0.test.<run>, below preview/rc/stable,
  so the reader takes the next release over the air. Test identities are rejected by the feed picker.
- Tests: `bash tools/test/test-sideload.sh` (CI: android.yml).

## Checks

- Android: `luajit android/koreader/test/test_logic.lua`, `.../test_flows.lua`,
  `bash tools/test/test-install-usb.sh`, `bash tools/test/test-sideload.sh`, and in `android/companion`
  `./gradlew verifySharedVersion testDebugUnitTest assembleDebug lintDebug` (CI: `.github/workflows/android.yml`).
- Xteink: `xteink/scripts/apply.sh <CrossInk checkout>`, `xteink/test/run-host-tests.sh <checkout>`,
  then `pio run -e <env>` (CI: `.github/workflows/xteink.yml`, all three readers; pushes build the
  CrossInk pinned as `crossink-v2.0` in `tools/upstreams.lock`; daily runs first move that pin to
  upstream's newest 2.x tag, rc included, and always build the commit the lock records).
- Workflows: `python3 tools/test/test-workflows.py`, `python3 tools/test/test-release-inputs.py` and actionlint (CI: `.github/workflows/workflow-lint.yml`):
  actions pinned by SHA, no stored checkout credentials, and no write permission, secret or token
  in a job that runs a build tool. Steps shared by several workflows live in `.github/actions/`.
- BookOrbit app attestation: `tools/upstreams check` (CI: the app-attest job in
  `.github/workflows/plugin-compat.yml`): fails when the pinned server requires app attestation on
  a route BookSync calls (`docs/server-contract.md` "App attestation"). Tests:
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

BookSync only. Never open pull requests or issues, or send patches, to the projects we build on
(CrossInk-Bookorbit, BookOrbit, KOReader, MicroLink, the CrossInk simulator). Work around
anything upstream inside BookSync: an overlay patch, a build-time edit of a fetched package
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

Account forms inherit the account screen budget (three state rows, ≤16 KiB), including
confirmations and result sheets. Read the lifecycle-cached neutral state before catalog
ownership exists; typed secrets live only until dispatch or cancellation. Async account
results may redraw only their still-visible initiating form and must reject cancelled attempts.

Storage and folder screens inherit a one-row, 16 KiB local snapshot budget;
Collections uses six projected rows. Capacity, file eligibility and removal
previews belong to the companion; render paths never scan folders. Preserve
reading sidecars and exclude the foreground book from removal previews.

Device-local library projections use their own reserved owner without changing catalog
ownership. They inherit the same screen/widget row, byte and one-batch limits; folder and
sidecar work stays on the companion. Login adoption checkpoints secrets and its migration
marker together in the existing encrypted vault; never activate a second lifecycle writer.

Android plugin Lua has no adapter-directory or composition-root exemption: no server routes,
HTTP clients or vendor identifiers. Legacy class retirement uses one bounded local Library
bootstrap descriptor (one row, 16 KiB, one round-trip, zero network/subprocesses) before instances
start; a missing, late or mismatched companion never claims sync ownership. Retirement metadata
and native setting/gesture identifiers are supplied by the companion adapter, never encoded in Lua.

Home book cards inherit their widget window's row/16 KiB snapshot budget; the companion
projects cover paths, series labels and personal pace. Card paints decode no images or
start cover jobs: the interface defers preparation, bounds bitmap input to 512 KiB,
and cancels delivery after removal, account change or return to reading. The static
book-actions sheet has five rows, zero decoded data and no companion round-trip.

Bounded read-model publication owns enrichment, retained-window invalidation and changed events
for both device and account owners. Lifecycle callers use LibraryReadModel; refreshes inherit
the same per-screen/widget budgets and lazy per-batch aggregation as first publication.

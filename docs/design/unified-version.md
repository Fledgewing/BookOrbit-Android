# One BookSync version from 0.12

Status: building, maintainer-approved W39 decision: use 0.12 and a bridge build.
Platforms: Android companion, KOReader plugin, X4 Pro, X4 Classic and X3/C3 X4.

## Identity and release

The version in shared/version.json is the product identity. For 0.12 and later,
Android's release tag must match it, the companion uses it as versionName, the
packaged plugin uses it as PATCH_VERSION, and every firmware build defines it as
BOOKSYNC_VERSION. The source plugin retains its development placeholder; package.sh
with "shared" stamps the manifest identity. Test APKs retain their explicit test identity.

Preview builds are MAJOR.MINOR.PATCH-preview.N, release candidates are
MAJOR.MINOR.PATCH-rc.N, and stable builds have no suffix. Their ordering is
preview.1 < preview.2 < rc.1 < rc.2 < stable. Test artifacts never publish.
Unified firmware test identities use MAJOR.MINOR.PATCH-0.test.<run>, below every
preview, so the next real release installs over a sideloaded test. Feed selection
rejects test identities even when prereleases are enabled.
From 0.12, release.yml dispatches xteink.yml at the same immutable Android tag
after publishing Android, or directly when Android is unchanged. New builds use
the same commit and manifest; selective previews retain older installed builds.
Firmware publishing accepts only that matching tag; daily runs build the pinned
CrossInk base without publishing another product version. A failed firmware run
can be rerun at the tag; no tag moves. Each platform must have passing release-test evidence for its source inputs.

Firmware tags are xteink-v<version>+crossink.<upstream tag without v>, replacing
the upstream metadata "+" with ".". CrossInk metadata never affects BookSync
precedence. Android retains v<version>, and only stable Android releases take
GitHub's "latest".

About's existing version row reads, for example:

    BookSync 0.12.0 (CrossInk 2.0.0-rc3)

The full fork base and pinned commit remain in release notes and the source archive.
No new screen, prompt or reading interruption is introduced.

## Selective previews and promotion

Maintainer-approved follow-up to W39: unchanged platforms need no preview rebuild,
and passing tests can be reused when their inputs are identical. This relaxation
starts with unified releases from 0.12. Legacy bridge, test-artifact and ordinary
push/PR builds keep their existing full build/test coverage.

`tools/releases/inputs.py` hashes Git-tracked input paths, modes, contents and
submodule pins with SHA-256. The app and plugin have separate input sets; each
firmware environment has an identity including the overlay, CrossInk lock,
shared inputs, build actions and test tooling. The shared version stamp
`shared/version.json` is excluded. Common firmware source changes conservatively
invalidate every reader; this avoids guessing which conditional code is compiled.
Documentation outside build inputs does not invalidate them. New inputs must be
added to the declared sets when introducing another build dependency.

A preview builds only fingerprints changed since each platform's last published
build. Companion and plugin publish together when either changes: their installed
versions must match, and the companion installs its matching plugin release.
They retain separate fingerprints and test evidence. Firmware readers are selected
individually. No empty Android release is created when Android is unchanged:
existing Android updaters expect every plain `v` release to contain the APK and
plugin. Firmware still dispatches at the immutable product tag in that case.
If every platform is unchanged, the workflow summary records the no-op without
publishing another release.

Android's release page marks scheduled firmware builds pending until firmware
publication refreshes its table. Manual firmware publication requires the matching
Android fingerprints first, and matching versions for RC/stable.
Release notes list every platform's current version, marking retained builds
"unchanged". The firmware feed selects a channel head **per reader**, plus legacy
bridges per reader. A retained entry keeps its original tag, asset URL, digest,
BookSync version and signature. An updater sees the same installed identity and
has nothing to install. Missing assets in a newer release never erase another
reader's head. RC and stable always rebuild and stamp every platform with the
manifest version, so installed versions converge.

Successful jobs upload `passed-inputs-*` receipts for 90 days; published releases
retain `RELEASE-INPUTS.json` (Android) or `FIRMWARE-INPUTS.json` (firmware) as
checksummed, attested assets. Receipts record the platform, fingerprint, passed
scope, immutable tag/commit and Actions run. Component evidence (unit/host tests
and a build) cannot replace the emulated release gate. Release evidence includes
the server kit and the platform's release scenarios; the Android receipt also
requires KOReader startup. Diagnostic simulator runs against an upstream override
cannot prove the pinned firmware's inputs.

The read-only planner collects published receipts and receipts from successful
same-repository non-PR Actions runs. PR receipts are recorded but never authorize
a release's test bypass. It scans the latest 100 releases and 100 artifacts;
missing, expired or unmatched evidence runs the full tests. API/download failure
fails planning, never silently authorizes reuse. Evidence is an optimization,
not an alternative release channel. No credentials or write permissions reach
Gradle or PlatformIO.

Each selected platform skips component/release tests only for matching passed
fingerprints at that scope. Release notes say `tests: reused from <tag/commit>`
with scope details. Otherwise that scope runs fully. Stamp-only RC/stable builds
still check the actual APK version, plugin package stamp, firmware version string,
flash budget, checksums and signatures. Full simulator boot scenarios require a
build and server startup; they belong to the reusable gate rather than a seconds-long
artifact smoke test. Tags and existing assets never move to implement promotion.

Validation: `python3 tools/test/test-release-inputs.py` exercises hashing, source
isolation, version-only edits, modes, additions/deletions/renames, submodule pins,
preview dependency selection, RC/stable convergence, scope separation and partial
feed retention. The host OTA tests check partial previews with the real parser.

## Bridge rollout

Before changing the manifest to 0.12 on feature/0.12, publish and device-test the
bridge from main during 0.11 stabilization. The bridge retains the existing
2.0.0.<run>+bookorbit.N tag so installed firmware can reach it. Its release notes
record booksync_version=<manifest version>; the feed copies that into a top-level
booksync_version field. The bridge learns its own identity from BOOKSYNC_VERSION.

The bridge compares BookSync identities when both releases have one, and every
BookSync identity sorts above a release without one. Two legacy identities retain
the upstream comparison. Rebuilt bridges with the same product identity use the
legacy counter; unified builds ignore CrossInk metadata. Invalid BookSync fields
are rejected by the picker. Streaming-parser reset clears the identity.

The feed retains the latest legacy entry in each channel as well as current
BookSync channel heads, indefinitely. Old devices ignore the new field and still
choose the bridge's higher numeric version. Bridge devices choose the BookSync
release. Install order is:

    2.0.0.373 -> 2.0.0.<bridge run> -> 0.12.0-preview.1 -> 0.12.0-rc.1 -> 0.12.0

The same mechanism and per-device asset matching apply to X4 Classic and X3.
Readers with prereleases disabled require a stable-channel bridge before a stable
unified release. Keep the legacy stable entry (including the retired 1.6 line)
until that bridge exists. Never withdraw the only usable bridge without replacing it.

The legacy behavior is grounded in CrossInk-Bookorbit at
87e2e1984481e8a3d996f12b34b50a383f9013b8:
src/network/OtaUpdater.cpp:338 (isUpdateNewer),
src/network/FirmwareVersion.cpp:118 (compare), and the Orbify ota-tag-prefix
overlay patch. W39 changes both the picker and the final installed-version check.
Signature verification continues to bind the exact release tag, not its product alias.

## Validation and coordination

tools/test/test-booksync-version.py checks shared inputs, packaged PATCH_VERSION,
version generation and retained feed bridges. The host OTA test compiles the
actual streaming parser, picker and comparison code and exercises the full chain
for all three asset stems, one-byte chunks, reset/retry, channel filtering, numeric
preview ordering and metadata equality. Existing device builds cover integration.

W38 owns Android preview ordering; W39 uses the same preview.N and rc.N forms.
W35 withdrawal filtering must run before feed head/bridge selection so a withdrawn
bridge is never reintroduced. W37 may rename product paths and feed keys; the
booksync_version protocol field and immutable tag/signature identities stay stable.
No release or device operation is part of this implementation change.

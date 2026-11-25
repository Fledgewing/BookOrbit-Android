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
after publishing Android. Both build the same commit and read the same manifest.
Firmware publishing accepts only that matching tag; daily runs build the pinned
CrossInk base without publishing another product version. A failed firmware run
can be rerun at the tag; no tag moves. Each platform retains its release test gate.

Firmware tags are xteink-v<version>+crossink.<upstream tag without v>, replacing
the upstream metadata "+" with ".". CrossInk metadata never affects BookSync
precedence. Android retains v<version>, and only stable Android releases take
GitHub's "latest".

About's existing version row reads, for example:

    BookSync 0.12.0 (CrossInk 2.0.0-rc3)

The full fork base and pinned commit remain in release notes and the source archive.
No new screen, prompt or reading interruption is introduced.

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
src/network/FirmwareVersion.cpp:118 (compare), and the BookSync ota-tag-prefix
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

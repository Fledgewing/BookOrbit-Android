# Android preview versions (W38)

Approved maintainer/coordinator rule: test Android/plugin builds are previews. A maintainer
chooses `rc` only when a build is a real release candidate; the plain version is stable.
Xteink tags keep the upstream CrossInk rc/beta labels, which describe the firmware base.
Update channels now offer Stable / RC / Preview, selected from the BookSync version,
including firmware `booksync_version`; CrossInk labels do not classify BookSync releases.
See [update channels](update-channels.md).

The next published build is `v0.11.4-preview.1`, titled **BookSync 0.11.4 preview 1**.
Semver sorts the labels lexically, so the patch bump is required to update devices already
on `0.11.3-rc.17`:

`0.11.3-rc.17 < 0.11.4-preview.1 < 0.11.4-preview.2 < 0.11.4-rc.1 < 0.11.4`

The Companion's release picker and Lua version comparator use semver, including numeric
prerelease identifiers. The plugin's `PATCH_VERSION` is stamped with the whole version;
the Companion installs the plugin of its own release. The RC and Preview channels
opt into published release candidates and previews respectively; artifact-only workflow runs never create releases or tags.
`tools/android-test-version.sh` uses the workflow run number (or the next unused number from
published previews), continues an open preview patch and bumps the patch after RC/stable.
A later published preview must exceed any artifact preview installed on a test reader.
Legacy `-0.test.N` releases remain rejected by the picker and release workflow.

Android's package installer also needs increasing integer codes. A single pure Java encoder
(`AndroidVersionCode`) is compiled into both Gradle's buildSrc and the app:

`100000000 + (major * 10000 + minor * 100 + patch) * 10000 + stage`

| Version suffix | Stage |
|---|---|
| `preview.N` | N (1–3999) |
| `rc.N` | 4000 + N (1–3999) |
| stable | 9999 |
| local `dev` / legacy `0.test.N` | 0 |

Minor and patch must be below 100. Codes must not exceed Android's 2100000000 limit; unsupported
suffixes and out-of-range numbers fail the build. This reserves up to major 19 with all minor
and patch values. Build metadata does not change precedence or the code.

Old releases through `0.11.3-rc.17` used `major * 10000 + minor * 100 + patch`, so RC updates
shared one code. Every new encoded version installs over those releases. NewIn decodes both
formats; an old code has no recoverable prerelease information and remains a plain version.
Unit tests check the exact sequence above, old device update selection, both code formats,
and that Gradle's actual BuildConfig code matches the app's encoder.

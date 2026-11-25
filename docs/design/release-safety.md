# Release safety (W35)

The requested Android recovery policy uses a new signed feed on `android-feed`, at
`android/releases.json`. Android previously read GitHub releases directly; the Xteink
OTA feed is separate (`xteink-feed`, `xteink/releases.json`) and is unchanged.

The feed is one atomic JSON envelope containing `payload` (a UTF-8 JSON string) and
`signatures` (the existing SIGNATURES format). The release key certified by
`shared/release-signing.json` signs every payload byte, under tag `android-feed` and
asset name `android-releases.json`. Verification is mandatory even while plugin
signature enforcement is in its transitional logging mode. An unavailable or invalid
feed stops the check; there is no unsigned release-list fallback.

The payload holds all Android releases and a `withdrawn` tag list. Withdrawal is
monotonic: each republication unions the previous signed list, the checked-in seed
list, and an optional workflow-dispatch tag. Version comparison normalizes `v` and
`android-v` aliases. Drafts, test builds and withdrawn versions are never candidates;
pre-release preference still applies. If the installed version is withdrawn, the
newest allowed candidate is offered even when older. APK checksums and signing
certificate checks still apply. Android may refuse an APK with a lower versionCode;
release candidates within one patch share a code and can recover between candidates.
Cross-patch recovery requires a forward recovery release if Android refuses it.
Existing companions must first receive this updater; already released clients cannot
learn the new policy retroactively.

After merge, run `gh workflow run android-feed.yml -f withdraw_tag=v0.11.3-rc.10`.
The seed also withdraws rc.11. This publishes only feed metadata, never a tag or release.
Later withdrawals use the same input; ordinary Android publication republishes the feed.

The reusable release test workflow runs reader startup and Home/history opening flows
on plugin PRs and main pushes. An unconditional result job rejects a skipped reader
job for Android/all invocations, so the release build cannot proceed without it.
The flows use pinned KOReader Trapper/showReaderCoroutine code and the plugin harness,
with an explicit required-scenario manifest and no-exit assertion. They do not run a real
Android reader or a complete CRE engine. Device validation remains required before release.

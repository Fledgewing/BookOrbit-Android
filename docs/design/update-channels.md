# Update channels (W42, 0.12)

Maintainer-approved implementation request, 2026-11-26. Applies to Android (companion
and packaged KOReader plugin), X4 Pro, X4 and X3.

| Setting | Offered BookSync versions | Android description |
|---|---|---|
| Stable | X.Y.Z | tested releases only |
| RC | X.Y.Z and X.Y.Z-rc.N | also release candidates, about to become stable |
| Preview | X.Y.Z, X.Y.Z-rc.N and X.Y.Z-preview.N | every test build |

Android's Updates page displays three selectable rows, each with the description above:

```text
Update channel
● Stable    tested releases only
○ RC        also release candidates, about to become stable
○ Preview   every test build
```

Xteink's System settings row reads `Update channel: Stable`; Confirm cycles
Stable → RC → Preview → Stable using the native enum cycle handler. The selection
persists through restart. Every reader supports the same choices.

Eligibility comes from the Android release's BookSync version or the Xteink feed's
`booksync_version`, never from GitHub's prerelease flag or CrossInk's upstream rc label.
Missing or invalid identities, unsupported labels and artifact-only `-0.test.N` builds
are excluded. Preview means published previews; workflow-only artifacts are never fed
to any updater. Build metadata does not affect the channel.

Stored `include_prereleases` / `otaIncludePrereleases` true migrates once to Preview;
false or unset migrates to Stable. Android also moves the previous schema setting when
no companion preference exists. A stored new channel always wins. The new schema is
`update_channel` on Android and `otaChannel` (0 Stable, 1 RC, 2 Preview) on firmware.
There is no old API or feed fallback for channel selection.

The plugin continues to delegate checks and installation to the companion. No network
or filtering work moves to KOReader's UI thread. Reading gates remain in place.
Changing to a stricter channel does not downgrade; normal version comparison waits
for a newer eligible version. Existing signed-withdrawal recovery on Android is unchanged.

The Android signed feed already retains every Android release. The Xteink feed retains
a head for each product label plus the legacy numeric bridge heads for old readers.
Thus a newer Preview cannot hide the most recent RC. `release.yml` classifies both
`-rc.N` and `-preview.N` as GitHub prereleases through its suffix check and publishes
with `--prerelease`; stable alone uses `--latest`.

Validation covers the version × channel × GitHub flag matrix, streaming/retry behavior
for all three firmware assets, stored migration, and the actual firmware settings cycle,
save and reload path in all three CI simulator profiles. X3 uses the unchanged OTA slot.

Local X3 (`default`) flash measurement at the pinned CrossInk commit: 6,468,451 of
6,553,600 bytes (98.7%); 85,149 bytes remain in the OTA slot and 52,381 bytes remain
below the 99.5% gate. Static RAM: 64,476 of 327,680 bytes (19.7%).
The packaged firmware image is 6,482,336 bytes, leaving 71,264 bytes in the slot.
The CI gate uses PlatformIO's application flash summary above.

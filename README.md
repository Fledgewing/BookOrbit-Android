# BookOrbit-Android

Keeps Android e-readers in sync with a BookOrbit server over Tailscale, the way CrossInk does on Xteink readers.

**New here? Start with the [setup guide](docs/SETUP.md).**

The official BookOrbit KOReader plugin does all syncing and keeps the login. This repo adds:

- `koreader-patch/`: a KOReader user patch that brings the network up (Wi-Fi + Tailscale) before the plugin syncs, syncs on sleep and on a schedule, and sends Home to BookOrbit home.
- `companion/`: "Orbit Companion", an Android app that switches Wi-Fi, wakes Tailscale, holds a short wake lock, turns the screen off for "Sync and sleep", and acts as the Home launcher.

Design and approved mockups: `docs/DESIGN.md`, `docs/mockups.html`.

## Install

From [Releases](https://github.com/Fledgewing/BookOrbit-Android/releases/latest):

1. **Orbit Companion**: download `orbit-companion-<version>.apk` and install it (allow your
   browser or file manager to install unknown apps when Android asks). Open it, then work
   through **Setup** on its status page.
2. **KOReader patch**: tap **KOReader patch installed** on the companion's Setup page (it
   downloads the patch from the same release, checks its SHA-256 and writes it into
   `koreader/patches/`), or copy `2-orbit-android.lua` there yourself (create the folder if
   needed). Then restart KOReader. Needs the GitHub build of KOReader;
   see `koreader-patch/README.md`.

After that, both update themselves from this repo's releases.

## Updates

Both pieces check `https://api.github.com/repos/Fledgewing/BookOrbit-Android/releases/latest`
at most once a day, and only when the network is already up (neither turns Wi-Fi on for an
automatic check; a check started by hand turns Wi-Fi on, Wi-Fi only, and puts it back off
afterwards). Without a network they say so ("No internet: Wi-Fi is off"). If Android blocks the
connection while Wi-Fi and Tailscale are up (EACCES), they say "Internet blocked: is 'Block
connections without VPN' on for Tailscale?": Tailscale routes only the tailnet, so that
setting blocks GitHub; the setup checklist's Tailscale row warns about it.
With **Include pre-releases** on, they look at the five newest releases instead and also take
pre-releases. Each downloads the release's `SHA256SUMS` and refuses a file whose SHA-256
doesn't match.

- **KOReader patch** (Tools › Android sync): **Auto-update patch** (on by default),
  **Include pre-releases** (off), **Check for patch update**, and a status line. The check
  runs about 8 s after a start or wake once the network is up. A newer `2-orbit-android.lua`
  (it must also declare the release's version in `PATCH_VERSION`) is written next to the
  running file and renamed over it, so the patch folder never holds a half-written file. It
  takes effect on the next KOReader start (on firmwares that stop KOReader after sleep, every wake is one).
- **Orbit Companion** (Settings): **Auto-update app** (on by default), **Include
  pre-releases** (off), **Check for updates** (also on the status page), and the version and
  last result. The automatic check runs when the service starts or Wi-Fi comes up (for
  example for a wake pull), with the screen on; an automatic Wi-Fi off waits for its download. The APK must match `SHA256SUMS` *and* be signed with the same certificate as the
  installed app; it is then installed through a `PackageInstaller` session.
  - **Android asks you to confirm each app update.** The companion targets SDK 28 on purpose
    (`WifiManager.setWifiEnabled` stops working at 29+), and Android only allows updates
    without a prompt (`setRequireUserAction(USER_ACTION_NOT_REQUIRED)`, API 31+) when the
    app being installed targets a recent SDK: Q+ on Android 12, R+ on 13, S (31)+ on 14,
    Tiramisu (33)+ on 15, rising each year
    ([`PackageInstaller.SessionParams.setRequireUserAction`](https://developer.android.com/reference/android/content/pm/PackageInstaller.SessionParams#setRequireUserAction(int))).
    The companion still asks for it, so it would take effect if that ever changes. A check
    you start by hand opens Android's install prompt straight away; an automatic one posts
    a notification, "Orbit Companion <version> is ready. Tap to install."
  - Setup row **Install updates** opens Android's "Install unknown apps" page for Orbit;
    allow it once.

## Wi-Fi and the Home button

Two settings are shared by the patch (Tools › Android sync) and the companion
(Settings); changing either changes both.

- **Wi-Fi**: *Always on* (Wi-Fi stays as you set it), *Off while reading* (off once a book's
  sync is done, back as it was when the book closes), or *Just in time* (the default with the
  companion: off after 1/2/5/10 minutes without network use, never during a download or a
  sync; Wi-Fi you turn on by hand, in KOReader or with the launcher's Wi-Fi tile, stays on
  until you turn it off). In every mode, a sleep sync, wake pull, sync while reading or Test
  sync path that has to turn Wi-Fi on turns it back off. KOReader never shows its "turn on
  Wi-Fi?" prompt while the companion can switch Wi-Fi.
- **Home button**: *Back to my book, then BookOrbit home* (default: Home in a book opens
  BookOrbit home on top of it, Home there opens the companion, Home from the companion or any
  other app goes back to the book; with no current book, Home opens BookOrbit home; after
  KOReader was killed with a book open, Home reopens it) or *BookOrbit home* (Home on
  BookOrbit home still opens the companion).

The patch also adds the gesture action **Orbit Companion: apps**; *Apply recommended gestures*
puts it on a two-finger swipe up.

## Verify

Every release asset has a keyless build-provenance attestation from the release workflow
(`.github/workflows/release.yml`):

```
gh attestation verify orbit-companion-<version>.apk -R Fledgewing/BookOrbit-Android
gh attestation verify 2-orbit-android.lua -R Fledgewing/BookOrbit-Android
sha256sum -c SHA256SUMS
```

The APK's signing certificate SHA-256 is:

```
F5:07:8C:85:F8:23:18:30:C1:F1:8D:93:FE:30:D7:1F:87:93:6C:1D:94:24:F2:D8:15:98:3D:1D:21:A9:0A:15
```

Check it with `apksigner verify --print-certs orbit-companion-<version>.apk`. The release job
fails if the APK is signed with anything else.

### One-time move off a debug build

A companion built and installed by hand (`assembleDebug`) is signed with a debug key, and
Android won't update it with a release-signed APK (and the companion's own updater refuses
it: "signed with a different key"). Once:

1. In the companion, note your settings (Wi-Fi after sleep sync, toggles). They don't survive.
2. If "Allow lock screen" (device admin) is on, turn it off first: Settings › Security ›
   Device admin apps › Orbit Companion › Deactivate. Android won't uninstall an active
   device admin.
3. Uninstall Orbit Companion (`adb uninstall net.fledgewing.orbitcompanion`, or from app info).
4. Install `orbit-companion-<version>.apk` from Releases, open it, and redo Setup (Home app,
   battery Unrestricted, device admin, Install updates).

From then on, updates install over it.

## Releasing

Push a tag `vMAJOR.MINOR.PATCH` (or `vMAJOR.MINOR.PATCH-pre`, published as a pre-release).
The workflow builds the APK with `versionName` = the tag and `versionCode` =
`MAJOR*10000 + MINOR*100 + PATCH`, signs it with the release key from the repository
secrets, stamps the tag into the patch's `PATCH_VERSION`, and publishes the APK, the patch,
`SHA256SUMS` and the license files. A tag is never moved: a broken release is fixed forward
with the next patch version.

## Device notes

The code is generic Android; vendor quirks are one table (`Vendor.kt` in the companion,
`VENDORS` in the patch), picked by `Build.MANUFACTURER`/`BRAND` or the vendor launcher being
installed. Meebook (Haoqing) is measured; Boox (Onyx) is an unverified stub.

### Meebook M8C (Android 14, firmware V2.2.1)

- KOReader is the GitHub build, so user patches work.
- The Meebook launcher (`com.haoqing.app.hqreader`) has "App freeze", which disables apps (`enabled=2`); the companion names it from its label and opens its Freeze management.
- After the power button, KOReader keeps running with network for about 1 min 50 s, then the firmware force-stops the foreground app. Battery "Unrestricted" does not prevent it. Services (Tailscale) survive.
- Every wake is therefore a fresh KOReader start.
- No Android or firmware toast was seen when the companion switches Wi-Fi (`setWifiEnabled`; logcat shows none). The "Connecting to Wi-Fi…" message some wakes showed came from KOReader itself and is silenced since v0.2.3.

## License

This repository uses two licenses:

- `koreader-patch/` is **AGPL-3.0-or-later** (see `koreader-patch/LICENSE`). The patch runs inside KOReader and works with the BookOrbit KOReader plugin, both AGPL-3.0.
- Everything else (`companion/`, `docs/`) is **MIT** (see `LICENSE`). The companion app bundles the Kotlin standard library (Apache-2.0); its notices ship inside the app (Settings › Open-source licenses) and with each release (`THIRD-PARTY-NOTICES.txt`).

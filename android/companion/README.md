# Orbit Companion

One APK (`net.fledgewing.orbitcompanion`, Kotlin, plain Views, targetSdk 28 so
`WifiManager.setWifiEnabled` works) for the Orbit KOReader plugin in `../koreader/`. It never
talks to BookOrbit and holds no login. Contract: [`../docs/INTERFACE.md`](../docs/INTERFACE.md).

- **Service** (foreground, ongoing notification): `NET_UP` (Wi-Fi on, Tailscale
  `CONNECT_VPN`, wake lock capped at 25 s), `NET_DONE` (release, then "Wi-Fi after sleep
  sync", or back off when it was off), `WIFI_OFF` (automatic offs never touch Wi-Fi the user
  turned on: it tracks the owner from `WIFI_STATE_CHANGED`), `SETTINGS` (shared Wi-Fi mode,
  idle minutes, Home button), `SLEEP_NOW` (`lockNow()`, device admin with `force-lock` only),
  and `GET http://127.0.0.1:47913/status`. Every Wi-Fi switch logs `wifi:` with the reason,
  owner and mode.
- **Home**: every Home press and boot starts KOReader with `COMMAND = "home_smart"` (or
  `"home"` when Home button is "BookOrbit home"); Home twice within 2 s, or a KOReader that is
  missing or won't stay up, shows the launcher page. The launcher page has a Wi-Fi tile; Wi-Fi
  turned on there is the user's ("manual").
- **Pages**: launcher, other apps (paged, hold to pin; Tailscale, Android Settings and the
  vendor home, if the vendor profile has one, are pinned by default), status, settings,
  setup checklist (its Wi-Fi off/on test leaves Wi-Fi as it found it; "KOReader patch
  installed" installs or updates the patch from this app's release, SHA-256 checked, into
  `koreader/patches/` with the storage permission, which still works at targetSdk 28),
  open-source licenses.
- **Battery**: hours left, % per hour by state and setting, per 100 pages and refreshes, a
  daily history, and Compare with other readers' exports (docs/design/STATS.md). Recorded from
  system broadcasts only; raw rows 90 days, daily rollups forever.
- **Setup needs you**: when a Setup step isn't done (new, or it stopped working), a page lists
  just those steps with "Fix", "Don't ask about this" and "Later"; also a quiet notification,
  a launcher banner and a line in KOReader's Android sync status. After an update it shows
  "What's new" once.
- **Self-update** from GitHub releases (`Updater.kt`; README "Updates"): daily, SHA-256 and
  signing-certificate checked, installed with `PackageInstaller`. At targetSdk 28 Android
  asks the user to confirm each update.
- **Disabled apps**: some vendor launchers "freeze" (disable) apps, KOReader included. The
  companion tells "disabled" apart from "not installed" (`getApplicationEnabledSetting`,
  `MATCH_DISABLED_COMPONENTS`), names the likely disabler from the vendor launcher's label at
  run time ("Disabled by Meebook Launcher"), says so on the launcher page, status page and
  setup checklist ("Not disabled by the system"), and opens the vendor's freeze page, or
  Android's app settings, to undo it.
- **Vendor profiles** (`Vendor.kt`): the only vendor-specific code. Meebook/Haoqing
  (measured), Boox/Onyx (unverified stub), generic Android.

## Build

```
export JAVA_HOME=$(/usr/libexec/java_home -v 17) ANDROID_HOME=$HOME/Library/Android/sdk
./gradlew testDebugUnitTest assembleDebug
```

APK: `app/build/outputs/apk/debug/app-debug.apk` (version `0.0.0-dev`, debug key).

Release builds take `-PorbitVersion=X.Y.Z` (versionCode `X*10000+Y*100+Z`) and sign with the
key named by `ORBIT_KEYSTORE_FILE` (PKCS12), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`
and `ANDROID_KEY_PASSWORD`; without them `assembleRelease` is unsigned. The release workflow
does this. Every build generates `assets/open_source_licenses.txt` from the runtime classpath.

## Install and first run

Normally: the APK from Releases (top-level README "Install"). For a development build:

```
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n net.fledgewing.orbitcompanion/.StatusActivity
```

Then Setup on the status page: each row opens the system page it needs (Home app,
notifications, not disabled by the system, install updates, battery Unrestricted for Orbit,
Tailscale and KOReader, Tailscale, device admin), then run the Wi-Fi off/on test.

## Logs

```
adb logcat -v time -s OrbitCompanion
```

# Orbit Companion

One APK (`net.fledgewing.orbitcompanion`, Kotlin, plain Views, targetSdk 28 so
`WifiManager.setWifiEnabled` works) for the KOReader patch in `../koreader-patch/`. It never
talks to BookOrbit and holds no login. Contract: [`../docs/INTERFACE.md`](../docs/INTERFACE.md).

- **Service** (foreground, ongoing notification): `NET_UP` (Wi-Fi on, Tailscale
  `CONNECT_VPN`, wake lock capped at 25 s), `NET_DONE` (release, then "Wi-Fi after sleep
  sync"), `WIFI_OFF`, `SLEEP_NOW` (`lockNow()`, device admin with `force-lock` only), and
  `GET http://127.0.0.1:47913/status`.
- **Home**: every Home press and boot starts KOReader with `COMMAND = "home"`; Home twice
  within 2 s, or a KOReader that is missing or won't stay up, shows the launcher page.
- **Pages**: launcher, other apps (paged, hold to pin), status, settings, setup checklist.

## Build

```
export JAVA_HOME=$(/usr/libexec/java_home -v 17) ANDROID_HOME=$HOME/Library/Android/sdk
./gradlew testDebugUnitTest assembleDebug
```

APK: `app/build/outputs/apk/debug/app-debug.apk`.

## Install and first run

```
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n net.fledgewing.orbitcompanion/.StatusActivity
```

Then Setup on the status page: each row opens the system page it needs (Home app,
notifications, battery Unrestricted for Orbit, Tailscale and KOReader, Tailscale, device
admin), then run the Wi-Fi off/on test.

## Logs

```
adb logcat -v time -s OrbitCompanion
```

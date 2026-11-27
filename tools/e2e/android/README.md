# Native Android emulator review

These tools install and exercise actual KOReader widgets on an explicitly selected
Android emulator. Every adb invocation carries `-s emulator-N`, and construction
refuses a target unless `ro.kernel.qemu=1`. The host safety tests run in Android CI.
Use a disposable AVD: setup replaces its plugin and seeds synthetic books; the
upgrade test archives its KOReader directory and clears the two app profiles.

Tested with Android 14 Google APIs ARM64, KOReader v2026.07.1 ARM64, a Pixel Tablet
AVD adjusted to 1200×1600 at 240 dpi, and the four-column `android-tablet` layout.
This is emulator acceptance, not a physical M8C timing measurement.

```sh
sdkmanager 'emulator' 'system-images;android-34;google_apis;arm64-v8a'
avdmanager create avd --name booksync-review \
  --package 'system-images;android-34;google_apis;arm64-v8a' --device pixel_tablet
"$ANDROID_HOME/emulator/emulator" -avd booksync-review -port 5580 \
  -no-window -no-audio -no-snapshot -gpu swiftshader_indirect
```

Wait until `adb -s emulator-5580 shell getprop sys.boot_completed` returns `1`.
`wait-for-device` alone does not mean PackageManager is available. Then:

```sh
adb -s emulator-5580 shell wm size 1200x1600
adb -s emulator-5580 shell wm density 240
python3 tools/e2e/android/build.py --out /tmp/booksync-emulator-build
python3 tools/e2e/android/run.py --serial emulator-5580 setup \
  --apk /tmp/booksync-emulator-build/android/companion/app/build/outputs/apk/debug/app-debug.apk \
  --koreader /tmp/koreader.apk \
  --apksigner "$ANDROID_HOME/build-tools/34.0.0/apksigner"
python3 tools/e2e/android/review.py --serial emulator-5580 --out /tmp/booksync-shots
python3 tools/e2e/android/test_driver.py
```

Setup launches the companion once to initialize its status before opening KOReader.
Dismiss KOReader's initial quickstart/color messages before the native review.

`build.py` copies companion sources and shared inputs into an external directory,
preserving strict Gradle verification. Only that disposable copy replaces the
server composition with `E2eServerAdapters.kt`. The fixture implements the neutral
`ServerAdapter`; it reuses `DeviceLibrary`, `LibraryReadModel`, `SeriesPresentation`,
and the normal account worker and sync owner. Sign-in uses the synthetic address
`https://fixture.example.test`, user `reader`, password `fixture`. No HTTP listener
or external service is required. This tests the interface, not the shipping
adapter's HTTP protocol or a live server refresh/download.
Position consent uses a fixed remote-ahead snapshot; local uploads are recorded
separately so background sync cannot alter that scripted second reader.

`run.py setup` reuses `android/koreader/package.sh` for version stamping, settings,
credits and battery assets. APK `install -r` and whole plugin replacement follow
`tools/sideload-android.sh:158` and `:186`. It reads the debug APK's certificate
and pins it only in the staged emulator plugin copy. Production signing policy
and source files are unchanged. EPUBs reuse `tools/e2e/kit.py:151`; synthetic
KOReader sidecars provide saved titles, series and progress.

The test-only user patch `driver.lua` calls real screen entry points and native
button callbacks. `review.py` exercises default Home pages, editor/picker and
add/resize/move/save/reset, sign-in,
Library/filter, Series, Storage, Settings groups, every registered widget, book
opening, top/bottom reader panels, live Custom value edits with native setting
assertions, position consent/acceptance,
end sheet → Series, Full Refresh, and offline Library. It saves PNGs and a small
`review.json` outside the repository. Projection readiness is polled; an assertion
failure ends the run. There are no scenario retries.

For upgrade/fresh-install checks, use another disposable emulator. Supply an
external `git archive origin/main` snapshot containing `android/`, `shared/`,
`tools/booksync-version.py` and `tools/e2e/`, and its debug APK:

```sh
python3 tools/e2e/android/upgrade.py --serial emulator-5582 \
  --legacy-source /tmp/booksync-main \
  --legacy-apk /tmp/booksync-main/android/companion/app/build/outputs/apk/debug/app-debug.apk \
  --apk android/companion/app/build/outputs/apk/debug/app-debug.apk \
  --koreader /tmp/koreader.apk \
  --apksigner "$ANDROID_HOME/build-tools/34.0.0/apksigner" --out /tmp/booksync-shots
```

The upgrade preserves a seven-minute idle setting and synthetic sentinel, checks
the Home migration and once-only news acknowledgment, then verifies a fresh profile
gets BookSync Home without upgrade news. The legacy and current builds use the
same local debug key; no release key is needed.

After the main review, the add-on fallback flow uses the same disposable emulator:

```sh
python3 tools/e2e/android/addon.py --serial emulator-5580 --out /tmp/booksync-addon-shots
```

It checks the native Download fallback, existing helper settings and the reader's
helper deep-link/update summary. It restores the fixture's preferences even when
an assertion fails; it never installs an update or opens a physical reader.

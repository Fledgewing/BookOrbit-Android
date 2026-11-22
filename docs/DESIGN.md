# Android e-readers ↔ BookOrbit sync: design, revision 2 (first device surveyed: Meebook M8C)

Refines `memory/android-ereader-plan.md`. Nothing is built. The mockups are in
`m8c-sync-mockups.html` next to this file.

Code read:
- bookorbit/bookorbit @ 981a78e5 (plugin 2.4.0)
- koreader/koreader @ 1294bb3d
- koreader/android-luajit-launcher HEAD
- tailscale/tailscale-android @ 7a1f470d (2026-11-12)

## Rulings from the mockup review (revision 2)

1. **The official BookOrbit plugin is the only thing that syncs.** It holds the login, does every
   pull and push, and its home screen and views stay. Nothing else ever talks to BookOrbit.
2. **The companion never holds the BookOrbit login.** It has no push of its own, no queue and no
   server row. A missed push stays in the plugin's durable outbox, and the plugin sends it first on
   the next wake.
3. **Sync on sleep, like CrossInk:**
   1. On Suspend (power button) the patch asks the companion for Wi-Fi, Tailscale and a short wake
      lock.
   2. The patch triggers the plugin's own sync and waits for its result, capped at 20 s.
   3. The companion applies its Wi-Fi setting and releases the lock.
4. **A guaranteed path: "Sync and sleep".**
   1. The screen stays on and shows "Syncing…" while the same steps run.
   2. The companion then turns the screen off with `DevicePolicyManager.lockNow()`. This needs a
      one-time device-admin approval.

## What the code reading established

1. **Sleep and wake reach the plugin on Android.**
   - App pause → `RequestSuspend` → `Suspend` (koreader `device/android/device.lua:218-221` →
     `devicelistener.lua:458` → `generic/device.lua:1114-1116`).
   - App resume → `Resume` (`device.lua:177-180`).
   - So the plugin's `_onSuspend` and `_onResume` fire (bookorbit `main.lua:1329-1351`).
   - Switching apps also counts as a pause, so the patch checks that the screen is really off
     before it does a sleep sync.
2. **The Android gaps are about the network, not the sync:**
   - (a) `NetworkMgr:turnOnWifi` and `turnOffWifi` only open Settings (`device.lua:317-329`).
   - (b) The plugin's suspend sync goes into a durable outbox and drains only if a connection
     already exists (`main.lua:411-419`). Otherwise it waits for the next `NetworkConnected`
     (`main.lua:1353-1361`).
   - (c) "Connected" means Wi-Fi only (`device.lua:335-340`), not Tailscale.
   - (d) The default for "BookOrbit is further ahead" is Ask (`main.lua:111`).
3. **The patch can fix all of these without syncing itself:**
   - It replaces `turnOnWifi`/`turnOffWifi` with a call to the companion.
   - KOReader's own `turn_on` path then polls for the connection (up to 45 s) and broadcasts
     `NetworkConnected` (`network/manager.lua:82-133, 517-566`). The plugin answers that event by
     draining its outbox, then pulling.
   - For sleep, the patch calls the plugin's `requestLifecycleOutboxDrain` once the network is up.
     It learns the outcome by wrapping the plugin's `recordSyncSuccess` / `recordSyncError`, or by
     reading the outbox until it is empty.
4. **The 25 s debounce is minor** (`bookorbit_progress_sync.lua:26, 384`). The patch resets
   `pull_timestamp` on `Resume`.
5. **The F-Droid KOReader build ignores user patches** (`frontend/userpatch.lua:27-29`).
6. **Tailscale `com.tailscale.ipn.CONNECT_VPN` / `DISCONNECT_VPN` are real.**
   - The exported `IPNReceiver` handles them through a WorkManager job, and so does a newer no-UI
     `AutomationActivity` (tailscale-android `AndroidManifest.xml`, `IPNReceiver.java`).
   - Older releases may name them differently (1.40 changelog: `VPN_CONNECT`).
7. **The plugin already provides "Make BookOrbit home"** (`catalog_auto_open = "home"`,
   `bookorbit_settings_page.lua:208`, `main.lua:1402-1413`) and gesture actions
   (`main.lua:976-987`: `bookorbit_sync_now`, `bookorbit_this_book`, …).

## Components

| # | Component | Does | Never does |
|---|---|---|---|
| 1 | **BookOrbit plugin** (official, unchanged) | Login, every pull and push, outbox, conflict policy, home and views, its own toasts | (unchanged) |
| 2 | **orbit-android patch** (`koreader/patches/2-orbit-android.lua`) | Routes Wi-Fi on/off to the companion; on Resume: network ready, debounce reset; on Suspend with the screen off: network + wake lock, triggers the plugin's sync, waits ≤ 20 s, reports done/failed to the companion; "Sync and sleep" action; menu; "Apply recommended" sets plugin options | Hold credentials; call BookOrbit APIs (it only checks that the server answers at its base URL, with no login) |
| 3 | **Orbit Companion** (one APK, targetSdk 28) | Wi-Fi on/off (`setWifiEnabled`); Tailscale CONNECT; time-limited wake lock (25 s hard cap); `lockNow()` (device admin, `force-lock` policy); Wi-Fi-off timer; status, settings, setup checklist; launcher HOME activity + apps page | Know the server, the login or the sync state |
| 4 | **Gesture profile** | Readest-style thirds; hold top-right = Sync and sleep; hold top-left = plugin Sync now; swipe up = plugin This book | — |

**How the patch talks to the companion.** An explicit broadcast (`setPackage`) built through
KOReader's JNI bridge (`android.lua:1409-1500`: `JNI:context`, the raw `env`). Payloads are
commands and outcomes only: `NET_UP`, `NET_DONE{ok, seconds}`, `SLEEP_NOW`.
- Not `openLink`: that starts an activity, which pauses KOReader.
- Fallback: a loopback HTTP call to the companion.

**Sleep sequence (power button, 8a).**
1. `Suspend`.
2. The patch checks the screen is off. It skips the sleep sync if one ran in the last few seconds,
   for example from "Sync and sleep" a moment earlier.
3. The patch sends `NET_UP`. The companion takes a wake lock, turns Wi-Fi on if needed and wakes
   Tailscale.
4. The patch waits for the connection and the server's base URL, then calls the plugin's outbox
   drain (the plugin already queued the snapshot in its own `_onSuspend`).
5. The patch waits for the plugin's result, 20 s cap in total, then sends `NET_DONE`.
6. The companion applies the Wi-Fi setting and releases the lock.

**Risk:** Android or the vendor firmware may freeze KOReader, or cut its network, seconds after
screen-off. The push then simply stays in the plugin's outbox until the next wake. The survey
measures this.

**"Sync and sleep" (8b/8c).**
1. Gesture or menu.
2. The patch shows a "Syncing…" message (drawn once, tap to cancel).
3. Same steps 3-5 as above, with the screen on, so KOReader is certainly running.
4. On success or failure (failure shows 3 s of "Couldn't reach BookOrbit … sends first when you
   next wake it"), the patch sends `SLEEP_NOW` and the companion calls `lockNow()`.
5. The Suspend that follows is recognised as just-synced and skipped.

**Wake.**
1. `Resume`.
2. The patch sends `NET_UP` if not connected, waits for Tailscale and the server (≤ 20 s), and
   resets the debounce.
3. The plugin's `NetworkConnected` handler drains the outbox (any missed push goes first), then
   pulls. Further ahead → Silent jump with the plugin's own toast.
4. On failure, the patch banner (10b) shows. Reading is never blocked.

## Wi-Fi modes (v0.2)

One shared setting, stored by the companion (it is the only one that switches Wi-Fi) and
mirrored in the patch menu: newest `settings_at` wins (`SETTINGS` broadcast one way, the
status JSON's `settings` the other; docs/INTERFACE.md).

| Mode | Behaviour |
|---|---|
| Always on | Wi-Fi as the user set it. |
| Off while reading | When a book opens: the open-time pull finishes, then Wi-Fi goes off (`WIFI_OFF auto=0`). When it closes: back to what it was (`NET_UP reason=book_closed`). |
| Just in time (default with the companion) | Off after N idle minutes (1/2/5/10, default 2). |

The patch decides; `WifiPlan` (pure, `test/test_logic.lua`) holds the state machine:
- **Holds.** Every flow that needs the network (`wake`, `open`, `sleep`, `reading`, `test`,
  `update`) holds Wi-Fi and records whether it was on. On release, Wi-Fi that was off is
  restored off in every mode (sleep syncs: by the companion through `NET_DONE restore=off`,
  since KOReader may be frozen; others: by the patch after a 3 s grace).
- **Never off while busy.** Not while a hold is open, an HTTP request is in flight
  (`socket.http`/`ssl.https` wrapped), or the plugin's sync or outbox is busy.
- **Activity** = a request finished, `beforeWifiAction`, or a hold released. KOReader's
  `tx_packets` check (networklistener.lua:101-113) isn't used for the timer because its
  `auto_disable_wifi` needs an interface name Android doesn't give (:184-185).
- **Ownership (A).** The companion records who turned Wi-Fi on (`WIFI_STATE_CHANGED`: ours
  if we asked in the last 60 s, else the user's). Automatic offs (`auto=1`) are refused for
  manual Wi-Fi; KOReader's own Wi-Fi toggle and the launcher's Wi-Fi tile mark it manual.
- **Foreground only.** The patch sends automatic offs only while KOReader is in front, or
  with the screen off.
- **No prompt.** With a usable companion, `wifi_enable_action = turn_on` and
  `NetworkMgr:turnOnWifi/turnOffWifi/isWifiOn` go through it (device.lua:317-342), so
  `runWhenOnline`/`beforeWifiAction` (manager.lua:698, :605-619) never prompt. Without one,
  KOReader's stock behaviour stays, and a network step with Wi-Fi off fails at once.

## Smart Home (v0.2)

"Home button": *Back to my book, then BookOrbit home* (default, `COMMAND = home_smart`) or
*BookOrbit home* (`home`). The patch decides with `HomePlan` (pure, tested; full table in
INTERFACE.md "go home"): reader showing a book → BookOrbit home, opened over the book (the
plugin's public action; the book stays open); BookOrbit home on top → the companion's
launcher page (both modes); elsewhere with a current book (still open, or closed by Home
itself, `home_book`) → the book; elsewhere with none → BookOrbit home; cold start after KOReader was killed
with a book open (`open_book_at_exit`) → that book. Presses step book → BookOrbit home →
companion; Home from another app goes to the book, so the steps never loop. "From another
app" is the companion's `FROM=other_app` when it knows, else a KOReader pause of 2.5 s or more.

## Setup needs you (v0.2.4)

The companion is the Home app and is rarely opened, so a Setup step that stops working (Home
app changed, device admin removed, an app disabled, battery optimisation back on) or a new one
added by an update could go unnoticed. `SetupAttention` (pure, tested) evaluates the Setup
rows when the service starts, after an update, and when the status or launcher page opens:
- **Needed** = not done and not skipped ("Don't ask about this", undone in Settings). Rows
  that only report a test or a sighting (patch answered, Wi-Fi test) never prompt.
- **Prompt** (a page listing only the needed rows, each with "Fix" = the Setup row's action)
  unless snoozed with "Later", which lasts until the next update or a regression (a row
  that was done and isn't now).
- **Delivery:** the prompt on the status page, a quiet notification, a one-line banner on the
  launcher page, and `setup_needed` in `/status` for the patch's menu status. Nothing shows
  when all is done; nothing pops up in a book.
- **After an update:** a one-screen "What's new" from a short per-version list in the app
  (`WhatsNew`), with any needed steps.

## Plugin updates

The patch prefers the plugin's public surfaces (its Dispatcher actions and user settings) and
keeps the few private internals it needs (outbox wait, silent pull/push, position check
without prompting, dashboard detection, `on_done` callbacks) behind a start-up compatibility
check: a missing symbol turns off only that feature, which falls back to the plugin's own
behaviour, and is shown in the menu status and Test sync path. CI checks the same list
against the latest plugin weekly and opens an issue when it changes (koreader-patch/README.md
"Plugin hook points").

## Vendor profiles

The code is generic Android. Vendor quirks (the launcher that "freezes" apps, its freeze
page, a "<Vendor> home" tile) live in one table each: `Vendor.kt` (companion, chosen by
`Build.MANUFACTURER`/`BRAND`, then by the launcher being installed) and `VENDORS` (patch,
by launcher). A disabled app is named "disabled by <launcher label>", the label read at run
time, or "disabled by the system" with no profile. Meebook/Haoqing is measured; Boox/Onyx is
an unverified stub (Boox help center: Apps › App Management › Freeze Settings); anything else
gets the generic profile.

## Decisions

### One-way doors (the user's)

1. **KOReader build.** If the M8C runs the F-Droid KOReader, patches are disabled. Switching to the
   GitHub build means an uninstall (different signing key). The `koreader/` folder on storage
   survives, but app-private data does not.
   - Recommended: back up `koreader/` (settings, sidecars, statistics.sqlite3), then switch.
   - The survey shows whether this applies at all.
2. **Upstream or local.** The Android hooks could be offered to the BookOrbit plugin and to KOReader
   instead of living in a private patch. That is public work under the user's account.
   - Recommended: keep it local and private first.

The earlier door "where the login lives" is gone: the plugin keeps the only copy.

**Not a one-way door, but worth knowing:** the device-admin approval for `lockNow()`. It can be
revoked in Settings › Security › Device admin apps. While it is active, the companion can't be
uninstalled until the approval is revoked.

### Two-way doors (settled)

| Decision | Choice | Why |
|---|---|---|
| Who syncs | Only the plugin | Ruling 1 |
| Companion scope | Network, wake lock, screen off; no login | Ruling 2 |
| Companion + launcher | One APK | One install, one targetSdk-28 exception |
| targetSdk | 28 | `setWifiEnabled` fails for apps targeting 29+; Android 14 installs targetSdk ≥ 23; any prompt is tested by the setup checklist |
| Sleep sync cap | 20 s (patch), 25 s wake-lock hard cap (companion) | A stuck KOReader can't hold the device awake |
| Screen off for "Sync and sleep" | `DevicePolicyManager.lockNow()`; fallback, an accessibility service's `GLOBAL_ACTION_LOCK_SCREEN` (API 28+) | Ruling 4; the fallback is used only if device admin is blocked by the firmware |
| Gesture for it | Hold top-right = Sync and sleep; hold top-left = Sync now; swipe up = This book | Both stay one gesture away; KOReader tap defaults kept |
| Wi-Fi after sleep | "Off after 30 min" default (keep on / 30 min / off now), only while the screen is still off | Fresh sync beats battery |
| Plugin options | Further ahead → Silent; further behind → Don't sync; Auto-sync on; BookOrbit home | Already decided |
| Tailscale keep-alive | Battery Unrestricted (Tailscale, companion, KOReader); Always-on VPN with block-non-VPN off; deviceidle allowlist only if the survey shows Doze kills it; TailSocks last | Stop at the first that works |
| Home button | Shows the launcher page; KOReader auto-opens only at boot | Other apps stay reachable |
| Failure UI | Patch banner on wake; "Syncing…"/failed message for Sync and sleep; companion notifications only for network faults | Sync state belongs to the plugin and shows in its Sync status page |

## Open questions

1. Does KOReader keep running, with network, for 5-20 s after the power button? This decides
   whether 8a is enough or whether "Sync and sleep" becomes the everyday path.
2. Can the patch hook the plugin's completion cleanly (wrap `recordSyncSuccess`/`recordSyncError`,
   or watch the outbox)? Needs a short spike; `bookorbit_progress_sync.lua:320-357` and
   `main.lua:411-470` are the candidates.
3. Does the Meebook firmware allow a device admin and an alternative HOME app?
4. Does Android 14 prompt when a targetSdk-28 app toggles Wi-Fi?
5. Are there volume or page keys to map?

## Unverified facts and how to check them (read-only adb; listed, NOT run)

| Fact | Command |
|---|---|
| Android/SDK version, model | `adb shell getprop ro.build.version.release`; `adb shell getprop ro.build.version.sdk`; `adb shell getprop ro.product.model` |
| Screen size and density | `adb shell wm size`; `adb shell wm density` |
| Physical keys | `adb shell getevent -lp` (lists devices and key codes only) |
| Current HOME app; others allowed | `adb shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME`; `adb shell pm query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME` |
| KOReader build and version | `adb shell pm list packages \| grep -i koreader` (F-Droid name assumed `org.koreader.launcher.fdroid`, unverified); `adb shell dumpsys package org.koreader.launcher \| grep -E "versionName\|targetSdk"` |
| Tailscale version and actions | `adb shell dumpsys package com.tailscale.ipn \| grep versionName`; `adb shell cmd package query-receivers --brief -a com.tailscale.ipn.CONNECT_VPN` |
| Always-on VPN | `adb shell settings get secure always_on_vpn_app`; `adb shell settings get secure always_on_vpn_lockdown` |
| Doze allowlist; background limits | `adb shell dumpsys deviceidle whitelist` (list only, no `+`); `adb shell cmd appops get org.koreader.launcher RUN_ANY_IN_BACKGROUND`; same for `com.tailscale.ipn` |
| Vendor app killers | `adb shell pm list packages \| grep -i -E "power\|guard\|clean\|freeze\|boost\|security"` |
| Device admin support | `adb shell dumpsys device_policy` (lists active admins; shows whether the feature exists) |
| **KOReader runtime and network after screen-off (new)** | Turn on KOReader's debug logging, then press the power button and wait 60 s. Then read: `adb logcat -d -v time \| grep -E "KOReader\|BookOrbit\|UIManager"` (the last timestamp after `onSuspend` shows how long Lua kept running); `adb logcat -d -v time -b events \| grep -i -E "am_(pause\|stop\|freeze)\|screen_toggled"` (activity stop and freeze times); `adb shell dumpsys activity processes org.koreader.launcher \| grep -i -E "frozen\|cached\|procState"`; `adb shell dumpsys connectivity \| grep -i -E "blocked\|restrict"` (network blocked for background apps?); `adb logcat -d -v time \| grep -i -E "wifi.*(DISCONNECT\|CONNECTED)"` (does Wi-Fi drop on screen-off?) |
| Wi-Fi state and reconnect time | `adb shell dumpsys wifi \| grep -i -E "Wi-Fi is\|mWifiState"`; `adb logcat -d -v time \| grep -i -E "wifi.*(CONNECTED\|COMPLETED)"` after a natural wake |
| Android 14 prompt for targetSdk-28 Wi-Fi toggle | Not checkable read-only; the setup checklist's "Wi-Fi off/on test" answers it |
| M8C spec-site claims | `wm size` + `getevent -lp` above |

## Build order

1. **Read-only adb survey**, including the new screen-off runtime check. It decides the KOReader
   build, whether 8a can be the everyday path, any keys, and device-admin support.
2. **Configuration only:** plugin options, Tailscale battery + Always-on, the gesture profile.
   Measure 5 mid-book switches (M8C → phone → Xteink → M8C).
3. **Patch v0, no companion:**
   - wake: Tailscale wake by direct broadcast to `IPNReceiver`, wait for the server, debounce
     reset, banner;
   - "Test sync path";
   - the spike on how to wait for the plugin's result.
4. **Orbit Companion v1:** Wi-Fi on/off, Tailscale wake, wake lock, `lockNow()` + device admin,
   Wi-Fi timer, status, settings and setup checklist.
5. **Patch v1:**
   - route Wi-Fi on/off to the companion;
   - power-button sleep sync (8a);
   - "Sync and sleep" (8b/8c) with its gesture and menu entry.
6. **Launcher:** HOME activity + apps page in the same APK.
7. **Boox pass:** same survey, plus Boox checklist rows ("freeze apps", Wi-Fi off on sleep).

Acceptance at each step: real mid-book switches land on the right page with no manual sync, 5 in a
row.

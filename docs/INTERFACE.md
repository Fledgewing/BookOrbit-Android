# KOReader patch ↔ Orbit Companion interface (protocol 1)

The KOReader patch (`koreader-patch/2-orbit-android.lua`) and the Orbit Companion app talk
through Android intents only. The companion never learns the server, the login or the sync
state: the BookOrbit plugin owns all of that.

Package: `net.fledgewing.orbitcompanion` (placeholder, used everywhere below).

## Patch → companion: explicit broadcasts

The patch builds an `Intent(action)`, calls `setPackage("net.fledgewing.orbitcompanion")`,
adds `FLAG_INCLUDE_STOPPED_PACKAGES | FLAG_RECEIVER_FOREGROUND`, and calls
`Context.sendBroadcast`. The companion declares one exported manifest receiver with an
intent filter for these actions (manifest, not runtime: KOReader may be in the background
and the companion may not be running).

Every extra is a **string**. Every broadcast carries `proto = "1"` and
`sender = "org.koreader.launcher"`.

| Action (`net.fledgewing.orbitcompanion.action.…`) | Extras | Companion does |
|---|---|---|
| `NET_UP` | `reason`, `request_id`, `wifi` (`"1"`/`"0"`), `tailscale` (`"1"`/`"0"`), `wake_lock_s` (`"0"` = none) | Cancel any pending Wi-Fi-off timer. If `wake_lock_s` > 0, hold a partial wake lock for that long, hard-capped at 25 s. If `wifi = "1"` and Wi-Fi is off, turn it on. If `tailscale = "1"`, send Tailscale `CONNECT_VPN`. Record the time it took Wi-Fi to come up, for its status page. |
| `NET_DONE` | `reason`, `ok` (`"1"`/`"0"`), `seconds` (e.g. `"4.2"`), `detail` | Release the wake lock. For `reason` `sleep` or `sync_and_sleep`: record "Last sleep sync", then apply "Wi-Fi after sleep sync": keep on; off after 30 min (the timer turns Wi-Fi off only if the screen is still off when it fires); or off now, only while the screen is off. For `sync_and_sleep` the screen is still on at `NET_DONE` (`SLEEP_NOW` follows), so "off now" waits for the next screen-off, up to 30 s later. |
| `WIFI_OFF` | `reason` | Turn Wi-Fi off (KOReader's own "Wi-Fi off" toggle). |
| `SLEEP_NOW` | `reason` (`sync_and_sleep` or `sync_and_sleep_failed`) | `DevicePolicyManager.lockNow()` when the device-admin approval (`force-lock` only) is granted; otherwise logged and the screen stays on. At most one per 5 s. (The accessibility `GLOBAL_ACTION_LOCK_SCREEN` fallback is not in companion v1; add it only if the firmware blocks device admin.) |

`reason` values: `start` (KOReader just started; every wake is a fresh start on the M8C),
`wake`, `retry`, `sleep` (power button), `sync_and_sleep`, `reading` (sync while reading),
`test` (Test sync path), `koreader_wifi_on`, `koreader_wifi_off`. Unknown reasons must be
accepted and treated like `wake`.

Order for a sleep sync: `NET_UP` (with a wake lock), then exactly one `NET_DONE`, at most
20 s later by default (the patch's "Sleep sync limit"). The companion's own 25 s cap covers
a KOReader that is frozen or killed before it sends `NET_DONE`.

"Sync and sleep": `NET_UP`, `NET_DONE`, then `SLEEP_NOW`. On failure the patch shows its
message for 3 s first.

The companion's setup row "KOReader patch answered" is ticked by any broadcast carrying
`sender = "org.koreader.launcher"` or by a loopback `GET /status`.

## Patch → companion: activities

Started with `Context.startActivity`, `setPackage(...)` and `FLAG_ACTIVITY_NEW_TASK`. The
activity needs an intent filter with the action and `android.intent.category.DEFAULT`.

| Action | Opens |
|---|---|
| `net.fledgewing.orbitcompanion.action.SHOW_STATUS` | Companion status (mockup screen 3) |
| `net.fledgewing.orbitcompanion.action.SHOW_APPS` | The launcher's apps page (mockup screen 2) |

## Companion → patch: "go home"

The launcher starts KOReader explicitly:

```
component: org.koreader.launcher/org.koreader.launcher.MainActivity
action:    android.intent.action.MAIN
flags:     FLAG_ACTIVITY_NEW_TASK
extra:     net.fledgewing.orbitcompanion.extra.COMMAND = "home"   (String)
```

Do not use `ACTION_VIEW`: KOReader treats that as "open this file". `MainActivity` is
`singleInstance`, so a running KOReader gets the intent through `onNewIntent`, which calls
`setIntent` (android-luajit-launcher `MainActivity.kt:205-210`). The patch reads the extra at
start and on every resume, removes it, closes any open book (the reader saves it and the
plugin syncs it as on any close) and opens the plugin's BookOrbit home.

Unknown commands are logged and ignored.

When the companion sends it: on every Home press and at boot (it is the HOME app). A second
Home press within 2 s, or a KOReader that is missing, fails to start or closes within 5 s of
starting, shows the companion's launcher page instead. When Home comes back to the front
without a press (KOReader closed or was killed, e.g. by the M8C firmware about 110 s after the
power button), the companion starts KOReader again *without* the extra, so it reopens the last
book as on any fresh start; with the screen off it waits for the next screen-on.

## Optional: companion status over loopback

`GET http://127.0.0.1:47913/status` → `200` with JSON, for example:

```json
{ "proto": "1", "version": "1.0", "wifi": true, "tailscale": true, "screen_off_permission": true }
```

Bind to `127.0.0.1` only. The patch uses it in "Test sync path" (step 1, "Companion
answered", 1 s timeout) and treats any `200` as an answer; the fields are for display and
may grow. A companion without the endpoint still works for everything else.

## Without the companion

- The patch sends Tailscale's own broadcast itself: action `com.tailscale.ipn.CONNECT_VPN`
  to `com.tailscale.ipn/.IPNReceiver` (explicit component), once at the start of each
  network attempt and once more when Wi-Fi comes up. Present on the M8C (Tailscale
  1.104.6).
- Wi-Fi stays as it is. A background request from KOReader to turn Wi-Fi on just waits for
  Android's Wi-Fi; a request the reader made by hand opens Android's Wi-Fi settings (stock
  KOReader).
- "Sync and sleep" syncs, then asks the reader to press the power button.
- "Open Orbit Companion" and "Open another app…" say the companion isn't installed.

## Why broadcasts, and how the patch sends them

KOReader's Android JNI bridge (android-luajit-launcher `assets/android.lua`) exposes
`JNI:context(vm, fn)` (`android.lua:1400-1416`), which attaches the thread and hands over the
raw `JNIEnv`. With it the patch calls framework classes directly: `new Intent(action)`,
`setPackage`/`setClassName`, `putExtra(String, String)`, `addFlags`, then
`activity.sendBroadcast` or `activity.startActivity`. It also reads
`PowerManager.isInteractive()` (is the screen really off?) and
`ConnectivityManager`/`NetworkCapabilities.hasTransport(TRANSPORT_VPN)` (is Tailscale up?).
Each call checks for a pending Java exception and clears it, so a bad call is logged rather
than aborting KOReader.

Not `android.openLink` (`android.lua:2497`, `MainActivity.kt:631-641`): it only starts an
`ACTION_VIEW` activity, which brings another app to the front and pauses KOReader (a
Suspend). The patch cannot register a broadcast receiver (that needs a Java class), so
answers come back through the launch intent or the loopback status, never as broadcasts.

## Security

The broadcasts are not authenticated: any app on the device could ask the companion to turn
Wi-Fi on, hold a wake lock (25 s cap) or lock the screen. That is acceptable on a
single-user e-reader. Android 14 only reveals the sender when the sender opts in, so the
companion should simply bound what each action can do (the wake-lock cap, at most one
`SLEEP_NOW` per few seconds).

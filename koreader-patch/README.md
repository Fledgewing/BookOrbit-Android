# orbit-android KOReader patch

Gets an Android e-reader's network ready for the official BookOrbit KOReader plugin and tells
the plugin when to sync. The plugin does every pull and push and holds the login; this patch
never calls BookOrbit's API. It only checks that the plugin's server answers at its base
address, with no login.

Needs the GitHub build of KOReader (`org.koreader.launcher`): the F-Droid build ignores user
patches (`frontend/userpatch.lua:27-29`). Tested against KOReader v2026.07.2 and BookOrbit
plugin 2.3.0 (the version on the M8C).

## Install

1. Download `2-orbit-android.lua` from the latest
   [release](https://github.com/Fledgewing/BookOrbit-Android/releases/latest) (it carries
   its version; it then updates itself) and copy it to `koreader/patches/` on the device (create the folder if
   needed), for example:
   `adb shell mkdir -p /sdcard/koreader/patches && adb push 2-orbit-android.lua /sdcard/koreader/patches/`
2. Restart KOReader (on the M8C: power button, wait 2 minutes, wake).

`2-` is KOReader's `late` priority (`frontend/userpatch.lua:13`): it runs once UIManager is
ready, before the file browser or a book opens. The patch is one file because the loader only
runs files directly in `koreader/patches/`.

Remove it by deleting the file. Its settings live under `orbit_android` in KOReader's
`settings.reader.lua`.

## What it does

| When | Steps |
|---|---|
| **Start / wake** (every wake on the M8C is a fresh start) | Network up, wait ≤ 20 s for the plugin's server, then the plugin drains its outbox and pulls, with its 25 s pull debounce cleared for this one pull. On failure, a 6 s "Can't reach BookOrbit" banner with Retry (the plugin's own toast). |
| **Sleep** (Suspend with the screen really off) | Network up, the plugin drains the snapshot it queued in its own `_onSuspend`, the patch waits for the outbox to empty (cap: "Sleep sync limit", 20 s), then tells the companion `NET_DONE`. Skipped when the screen is still on (switching apps also sends Suspend) and right after "Sync and sleep". |
| **Sync and sleep** (action `orbit_sync_and_sleep`) | "Syncing…" message (tap to cancel), network up, the plugin's own sleep snapshot and drain, wait, then the companion turns the screen off. On failure: "Couldn't reach BookOrbit — saved on this device…" for 3 s, then sleep anyway. |
| **Sync while reading** (Off by default; 10/15/30/60 min, 25/50/100 pages, every 1 or 2 chapters) | When due and the page settles (3 s): network up, drain, the plugin refreshes BookOrbit's position without moving or prompting, then: this device ahead → the plugin pushes; BookOrbit ahead and "further ahead" is Silent → the plugin pulls; Ask or Don't sync → nothing until the next wake or open. The plugin's own every-few-pages push is skipped while this is on. |
| **Home** (from the companion launcher, or action `orbit_go_home`) | Closes the book (saved; the plugin syncs it as on any close), then opens the plugin's BookOrbit home. |
| **Wi-Fi requests from KOReader** | With the companion: sent to the companion instead of opening Android's settings. Without: Tailscale is woken and KOReader waits for Android's Wi-Fi; a request made by hand still opens Settings. |

Menu: **Tools › BookOrbit › Android sync** (falls back to a top-level **Android sync** entry
under Tools when the plugin is missing). Toggles; Sync while reading; Sync and sleep now;
Sleep sync limit (10/15/20 s); Apply recommended settings; Apply recommended gestures; Test
sync path; Open Orbit Companion; Open another app…; Auto-update patch; Include
pre-releases; Check for patch update; update status; status.

**Self-update** (top-level README "Updates"): at most once a day, after a start or wake whose
network is already up, the patch asks GitHub for the latest release of this repo, and if it
is newer than its `PATCH_VERSION`, downloads `2-orbit-android.lua` and `SHA256SUMS`, checks
the SHA-256 with KOReader's own `ffi/sha2` (koreader-base `ffi/sha2.lua:5612`, also used by
`frontend/util.lua`), writes `2-orbit-android.lua.new` and renames it over itself. The new
version runs from the next KOReader start. A copy taken straight from the repo says
`0.0.0-dev`; releases stamp the tag into it.

"Apply recommended settings" asks first, then sets the plugin's Auto-sync on, BookOrbit
further ahead → Silent, further behind → Don't sync, Make BookOrbit home, and KOReader's
Action when Wi-Fi is off → Turn on.

"Apply recommended gestures" asks first, then sets, in books only: hold top-right → Sync and
sleep; hold top-left → BookOrbit: sync all books; swipe right along the bottom edge →
BookOrbit: this book (KOReader has no one-finger "swipe up from the bottom"). Nothing else
changes gestures.

Dispatcher actions (for any gesture): `orbit_sync_and_sleep`, `orbit_go_home`,
`orbit_open_companion`, `orbit_open_apps`.

The companion interface is in [`docs/INTERFACE.md`](../docs/INTERFACE.md).

## Plugin hook points (bookorbit.koplugin 2.3.0)

| Use | Plugin code |
|---|---|
| Drain the durable outbox (only when connected) | `requestLifecycleOutboxDrain`, main.lua:414-547 |
| Wait for it: outbox count, coordinator busy, last error | `getLifecycleOutbox():diagnostics()` bookorbit_lifecycle_outbox.lua:303-317; `getSyncCoordinator()` main.lua:361-372, `isBusy`/`queuedCount` bookorbit_sync_coordinator.lua:48-54; `settings.last_error` main.lua:321-333 |
| Sleep snapshot for "Sync and sleep" | `_onSuspend`, main.lua:1340-1351 |
| Pull with the debounce cleared | `pull_timestamp` checked at bookorbit_progress_sync.lua:383-387 (25 s, line 26); `requestProgressPull` main.lua:730-741 |
| Push | `push_timestamp` (bookorbit_progress_sync.lua:307-311); `requestProgressPush` main.lua:717-728 |
| BookOrbit's position without prompting | `fetchRemoteProgress` bookorbit_progress_sync.lua:521-536; `isSamePlace` 145-155; `remoteProgressIsNewer` 157-167 |
| Every-few-pages push (skipped while Sync while reading is on) | `_onPageUpdate` main.lua:1314-1327 → `schedulePeriodicPush` bookorbit_progress_sync.lua:538-543 (instance override) |
| Home | `onBookOrbitOpenDashboard` main.lua:1381-1389 (action `bookorbit_open_dashboard`, main.lua:987-988); with Make BookOrbit home the plugin opens itself after a close, main.lua:1404-1412 and 1472-1475 |
| Test sync path, step 5 | `onBookOrbitSyncBook{quiet, on_done}` main.lua:1269-1288 in a book; `startSweep{quiet, on_done}` main.lua:1246-1253 otherwise |
| Auto-sync toggle (also registers its events) | `onBookOrbitToggleAutoSync` main.lua:1416-1448 |
| Server URL | `settings.server_url` (G_reader_settings `bookorbit`), main.lua:102-125 |
| Menu | `menu_items.bookorbit.sub_item_table`, bookorbit_main_menu.lua:320-366 |

The patch adds itself to the plugin list KOReader instantiates (`PluginLoader:loadPlugins`,
used by readerui.lua:464 and filemanager.lua:418), last, so it gets the same events as a
plugin (Suspend, Resume, PageUpdate, ReaderReady) after the BookOrbit plugin has handled
them. It is kept out of the Plugin manager list.

## Logs

Every step and outcome is logged with timings:

```
adb logcat -v time | grep OrbitAndroid
```

## Tests

Pure logic (scheduling, outbox verdicts, reading decisions, update version comparison and
`SHA256SUMS` parsing), any Lua 5.1-5.4 or LuaJIT:

```
luajit koreader-patch/test/test_logic.lua
```

Flow wiring against stand-ins for KOReader, the JNI bridge and the plugin (LuaJIT only,
because the patch uses `ffi`):

```
luajit koreader-patch/test/test_flows.lua
```

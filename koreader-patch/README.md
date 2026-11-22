# orbit-android KOReader patch

Gets an Android e-reader's network ready for the official BookOrbit KOReader plugin and tells
the plugin when to sync. The plugin does every pull and push and holds the login; this patch
never calls BookOrbit's API. It only checks that the plugin's server answers at its base
address, with no login.

Needs the GitHub build of KOReader (`org.koreader.launcher`): the F-Droid build ignores user
patches (`frontend/userpatch.lua:27-29`). Tested against KOReader v2026.07.2 and BookOrbit
plugin 2.3.0.

## Install

1. Download `2-orbit-android.lua` from the latest
   [release](https://github.com/Fledgewing/BookOrbit-Android/releases/latest) (it carries
   its version; it then updates itself) and copy it to `koreader/patches/` on the device (create the folder if
   needed), for example:
   `adb shell mkdir -p /sdcard/koreader/patches && adb push 2-orbit-android.lua /sdcard/koreader/patches/`
2. Restart KOReader (close it, or on firmwares that stop it after sleep: power button, wait, wake).

`2-` is KOReader's `late` priority (`frontend/userpatch.lua:13`): it runs once UIManager is
ready, before the file browser or a book opens. The patch is one file because the loader only
runs files directly in `koreader/patches/`.

Remove it by deleting the file. Its settings live under `orbit_android` in KOReader's
`settings.reader.lua`.

## What it does

| When | Steps |
|---|---|
| **Start / wake** (on firmwares that stop KOReader after sleep, every wake is a fresh start) | Network up, wait ≤ 20 s for the plugin's server, then the plugin drains its outbox and pulls, with its 25 s pull debounce cleared for this one pull. On failure, a 6 s "Can't reach BookOrbit" banner with Retry (the plugin's own toast). |
| **Sleep** (Suspend with the screen really off) | Network up, the plugin drains the snapshot it queued in its own `_onSuspend`, the patch waits for the outbox to empty (cap: "Sleep sync limit", 20 s), then tells the companion `NET_DONE`. Skipped when the screen is still on (switching apps also sends Suspend) and right after "Sync and sleep". |
| **Sync and sleep** (action `orbit_sync_and_sleep`) | "Syncing…" message (tap to cancel), network up, the plugin's own sleep snapshot and drain, wait, then the companion turns the screen off. On failure: "Couldn't reach BookOrbit — saved on this device…" for 3 s, then sleep anyway. |
| **Sync while reading** (Off by default; 10/15/30/60 min, 25/50/100 pages, every 1 or 2 chapters) | When due and the page settles (3 s): network up, drain, the plugin refreshes BookOrbit's position without moving or prompting, then: this device ahead → the plugin pushes; BookOrbit ahead and "further ahead" is Silent → the plugin pulls; Ask or Don't sync → nothing until the next wake or open. The plugin's own every-few-pages push is skipped while this is on. |
| **Home** (from the companion launcher, or action `orbit_go_home`) | `home`: closes the book (saved; the plugin syncs it as on any close), then opens the plugin's BookOrbit home. `home_smart` (Home button "Back to my book…", the default): in a book → BookOrbit home; on BookOrbit home (the plugin's dashboard on top, main.lua:1384, bookorbit_catalog.lua:1875) → the companion's launcher page (also with `home`); elsewhere with a book open → the book; no book open → BookOrbit home; after KOReader was killed with a book open (`open_book_at_exit`, set on ReaderReady, cleared on close) → that book, opened with `ReaderUI:showReader` (readerui.lua:616) (docs/INTERFACE.md). |
| **Wi-Fi requests from KOReader** | With a usable companion: `NetworkMgr:turnOnWifi`/`turnOffWifi`/`isWifiOn` (Android's, device.lua:317-342; `isWifiOn = isConnected` at :341) go through the companion, and `wifi_enable_action` is set to `turn_on`, so `beforeWifiAction` (manager.lua:605-619) and `runWhenOnline` (manager.lua:698) bring Wi-Fi up without a prompt, and without KOReader's centred "Connecting to Wi-Fi…" message (`turnOnWifiAndWaitForConnection`, manager.lua:539, replaced by the same steps with no widget). That message used to flash on wakes, because the plugin asks for the network 1 s after every resume (main.lua:1329-1337). Network messages left on screen: real failures only (the patch's "Can't reach BookOrbit" banner), and KOReader's own Wi-Fi toggle when the reader uses it. Without one (missing or disabled): Tailscale is woken and KOReader's stock behaviour stays; if Wi-Fi is off, network steps fail at once. |
| **Wi-Fi mode** (shared with the companion) | *Always on*; *Off while reading* (off once the open-time pull is done, restored at close); *Just in time* (default with the companion: off after 1/2/5/10 min without traffic, counted from `socket.http`/`ssl.https` requests; never during a request, the plugin's sync or an outbox drain; only Wi-Fi it turned on; never while another app is in front). Sleep sync, wake pull, Sync while reading, manual patch update and Test sync path put Wi-Fi back off when they had to turn it on. Every decision logs `wifi:` with the reason and mode. The radio state comes from `Settings.Global` `wifi_on` (no permission needed): KOReader has no `ACCESS_WIFI_STATE`, so `WifiManager.isWifiEnabled` throws there. KOReader's own `auto_disable_wifi` can't work here (it needs `getNetworkInterfaceName`, nil on Android, networklistener.lua:184-185). |

Menu: **Tools › Android sync** (its own entry: a menu item with `sorting_hint = "tools"`,
frontend/ui/menusorter.lua:162-189; nothing is added to the plugin's menu). Toggles; Sync while reading; Sync and sleep now;
Sleep sync limit (10/15/20 s); Apply recommended settings; Apply recommended gestures; Test
sync path; Wi-Fi (mode, idle minutes); Home button; Open Orbit Companion; Open another app…; Auto-update patch; Include
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
BookOrbit: this book (KOReader has no one-finger "swipe up from the bottom"); two-finger swipe
up → Orbit Companion: apps (this replaces KOReader's default "increase front light" on
front-lit devices, gestures defaults.lua:129). Nothing else changes gestures.

Dispatcher actions (for any gesture): `orbit_sync_and_sleep`, `orbit_go_home`,
`orbit_open_companion`, `orbit_open_apps` ("Orbit Companion: apps").

The companion interface is in [`docs/INTERFACE.md`](../docs/INTERFACE.md).

## Plugin hook points (bookorbit.koplugin 2.3.0; checked against the latest weekly)

**Public** (the plugin's actions and user settings; stable for users too):

| Use | Plugin surface |
|---|---|
| Home: BookOrbit home | action `bookorbit_open_dashboard` (event `BookOrbitOpenDashboard`), main.lua:987-988 → main.lua:1381-1389; opens over an open book, main.lua:1206-1230 |
| Every-few-pages push off while Sync while reading is on | setting "Push while reading" (`settings.pages_before_update`, bookorbit_settings_page.lua:259-260; read in `_onPageUpdate`, main.lua:1322-1324): set to 0, the reader's value kept and put back |
| Recommended settings | settings `auto_sync`, `sync_forward`, `sync_backward`, `catalog_auto_open` |
| Server URL | `settings.server_url` (G_reader_settings `bookorbit`), main.lua:102-125 |
| Version (compat messages) | `BookOrbit.PLUGIN_VERSION`, main.lua:54/95 (`_meta.lua` has none) |

**Private** (no public equivalent; each behind the start-up compatibility check, `Compat`):

| Use | Plugin code | If it's gone |
|---|---|---|
| Drain the outbox, wait for it: count, coordinator busy, last error | `requestLifecycleOutboxDrain` main.lua:414-547; `getLifecycleOutbox():diagnostics()` bookorbit_lifecycle_outbox.lua:303-317; `getSyncCoordinator()` main.lua:361-372; `settings.last_error` | wake and sleep syncs use the plugin's own sync |
| Silent pull, debounce cleared only if the last pull was < 25 s ago | `requestProgressPull` main.lua:730-741; `pull_timestamp` bookorbit_progress_sync.lua:384-387 (25 s, line 26). The public `bookorbit_pull_progress` is interactive: it jumps even backwards and shows toasts (bookorbit_progress_sync.lua:454-462), which breaks the Silent / Don't sync rule | wake and open pulls use the plugin's own timing |
| Sleep snapshot for "Sync and sleep" | `_onSuspend` main.lua:1340-1351 | sends what the plugin already queued |
| Sync while reading: BookOrbit's position without moving or prompting, then push or pull | `fetchRemoteProgress` 521-536, `isSamePlace` 145-155, `remoteProgressIsNewer` 157-167, `getLastPercent`/`getLastProgress`/`getDocumentDigest` (bookorbit_progress_sync.lua); `requestProgressPush` main.lua:717-728 (the public push action is interactive) | Sync while reading is off |
| "Is BookOrbit home on top?" | the catalog widget `catalog_browser` (main.lua:1207-1230), `dashboardMode` bookorbit_catalog.lua:1875-1877, closed with its `close_callback` | Home there goes back to the book |
| Test sync path, step 5 (needs `on_done`) | `onBookOrbitSyncBook{quiet, on_done}` main.lua:1269-1288; `startSweep{quiet, on_done}` main.lua:1246-1253; `errorLabel` | the step is skipped |
| Auto-sync toggle (also registers its events) | `onBookOrbitToggleAutoSync` main.lua:1416-1448 | not toggled |

At start the patch checks each private symbol's type (`Compat.check`). A missing one turns off
only its feature, logs `OrbitAndroid: compat: <feature> unavailable (plugin <version>)`, and
the menu status and Test sync path say e.g. "BookOrbit 2.5.0 changed: Sync while reading is
off". CI (`.github/workflows/plugin-compat.yml`: pull requests, release tags, weekly) runs
`test/plugin_compat.lua` against the latest `bookorbit/bookorbit` plugin and, on the weekly
run, opens an issue "BookOrbit plugin <ver> changed: <symbols>".

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

# Orbit KOReader plugin

Gets an Android e-reader's network ready for the official BookOrbit KOReader plugin and tells
the plugin when to sync. The plugin does every pull and push and holds the login; Orbit
never calls BookOrbit's API. It only checks that the plugin's server answers at its base
address, with no login.

Up to Orbify 0.7.x this was the user patch `2-orbit-android.lua`; from 0.8.0 it is the plugin
`orbit.koplugin`, with the same behaviour (design: [`docs/design/orbit-plugin.md`](../../docs/design/orbit-plugin.md)).
Tested against KOReader v2026.07.1 (the pin) and v2026.07.2, and BookOrbit plugin 2.3.0 (BookOrbit v3.9.0, the newest release); the hooks also check out against 2.4.1 (BookOrbit main, unreleased).

## Install

Orbit Companion installs and updates it (Setup › "Orbit plugin installed"), and so does
`tools/install-usb.sh`. By hand:

1. Download `orbit.koplugin.zip` from the latest
   [release](https://github.com/Fledgewing/Orbify/releases/latest) and unzip it into
   `koreader/plugins/` on the device, so that `koreader/plugins/orbit.koplugin/main.lua` exists.
   It carries its version and then updates itself.
2. Delete `koreader/patches/2-orbit-android.lua` if it is there: while the old patch is loaded
   the plugin stays off, so nothing is hooked twice.
3. Restart KOReader (close it, or on firmwares that stop it after sleep: power button, wait, wake).

Remove it by deleting the `orbit.koplugin` folder (or turn it off in KOReader's Plugin
manager). Its settings live under `orbit_android` in KOReader's `settings.reader.lua`, as they
did for the patch.

## Layout

`main.lua` loads the files below into one environment shared by the plugin's files, in the
order it lists them, so the code reads as the single patch file did:

- `logic/`: pure logic, no KOReader modules (schedules, plans, update checks, compat, stats,
  clicks, prompts, grouping). `test/test_logic.lua` loads only these.
- `ko/`: the KOReader side (settings, the JNI bridge, the companion, the network, sync,
  sleep, Home, menus, the self-update), ending with the module (`OrbitAndroid`) that
  `main.lua` returns to KOReader's plugin loader.

## What it does

| When | Steps |
|---|---|
| **Start / wake** (on firmwares that stop KOReader after sleep, every wake is a fresh start) | Network up, wait ≤ 20 s for the plugin's server, then the plugin drains its outbox and pulls, with its 25 s pull debounce cleared for this one pull. On failure, a 6 s "Can't reach BookOrbit" banner with Retry (the plugin's own toast). |
| **Sleep** (Suspend with the screen really off) | Network up, the plugin drains the snapshot it queued in its own `_onSuspend`, the patch waits for the outbox to empty (cap: "Sleep sync limit", 20 s), then tells the companion `NET_DONE`. Skipped when the screen is still on (switching apps also sends Suspend) and right after "Sync and sleep". |
| **Sync and sleep** (action `orbit_sync_and_sleep`) | "Syncing…" message (tap to cancel), network up, the plugin's own sleep snapshot and drain, wait, then the companion turns the screen off. On failure: "Couldn't reach BookOrbit — saved on this device…" for 3 s, then sleep anyway. |
| **Sync while reading** (Off by default; 10/15/30/60 min, 25/50/100 pages, every 1 or 2 chapters) | When due and the page settles (3 s): network up, drain, the plugin refreshes BookOrbit's position without moving or prompting, then: this device ahead → the plugin pushes; BookOrbit ahead and "further ahead" is Silent → the plugin pulls; Ask or Don't sync → nothing until the next wake or open. The plugin's own every-few-pages push is skipped while this is on. |
| **Home** (from the companion launcher, or action `orbit_go_home`) | `home`: closes the book (saved; the plugin syncs it as on any close), then opens the plugin's BookOrbit home. `home_smart` (Home button "Back to my book…", the default): in a book → BookOrbit home; on BookOrbit home (the plugin's dashboard on top, main.lua:1384, bookorbit_catalog.lua:1875) → the companion's launcher page (also with `home`); elsewhere with a book open → the book; no book open → BookOrbit home; after KOReader was killed with a book open (`open_book_at_exit`, set on ReaderReady, cleared on close) → that book, opened with `ReaderUI:showReader` (readerui.lua:616) (android/docs/INTERFACE.md). |
| **Wi-Fi requests from KOReader** | With a usable companion: `NetworkMgr:turnOnWifi`/`turnOffWifi`/`isWifiOn` (Android's, device.lua:317-342; `isWifiOn = isConnected` at :341) go through the companion, and `wifi_enable_action` is set to `turn_on`, so `beforeWifiAction` (manager.lua:605-619) and `runWhenOnline` (manager.lua:698) bring Wi-Fi up without a prompt, and without KOReader's centred "Connecting to Wi-Fi…" message (`turnOnWifiAndWaitForConnection`, manager.lua:539, replaced by the same steps with no widget). That message used to flash on wakes, because the plugin asks for the network 1 s after every resume (main.lua:1329-1337). Network messages left on screen: real failures only (the patch's "Can't reach BookOrbit" banner), and KOReader's own Wi-Fi toggle when the reader uses it. Without one (missing or disabled): Tailscale is woken and KOReader's stock behaviour stays; if Wi-Fi is off, network steps fail at once. |
| **Wi-Fi mode** (shared with the companion) | *Always on*; *Off while reading* (off once the open-time pull is done, restored at close); *Just in time* (default with the companion: off after 1/2/5/10 min without traffic, counted from `socket.http`/`ssl.https` requests; never during a request, the plugin's sync or an outbox drain; only Wi-Fi it turned on; never while another app is in front). Sleep sync, wake pull, Sync while reading, manual patch update and Test sync path put Wi-Fi back off when they had to turn it on. Every decision logs `wifi:` with the reason and mode. The radio state comes from `Settings.Global` `wifi_on` (no permission needed): KOReader has no `ACCESS_WIFI_STATE`, so `WifiManager.isWifiEnabled` throws there. KOReader's own `auto_disable_wifi` can't work here (it needs `getNetworkInterfaceName`, nil on Android, networklistener.lua:184-185). |

Menu: **Tools › Android sync** (its own entry: a menu item with `sorting_hint = "tools"`,
frontend/ui/menusorter.lua:162-189; nothing is added to the plugin's menu). Toggles; Sync while reading; Sync and sleep now;
Sleep sync limit (10/15/20 s); Recommended settings (a status line, opens the review page); Test
sync path; Wi-Fi (mode, idle minutes); Home button; Open Orbit Companion; Open another app…; Auto-update patch; Include
pre-releases; Check for patch update; update status; status.

**Self-update** (top-level README "Updates"): at most once a day, after a start or wake whose
network is already up, the plugin asks GitHub for the latest release of this repo, and if it
is newer than its `PATCH_VERSION` (in `main.lua`), downloads `orbit.koplugin.zip` and
`SHA256SUMS`, checks the SHA-256 with KOReader's own `ffi/sha2` (koreader-base
`ffi/sha2.lua:5612`, also used by `frontend/util.lua`), unpacks it with KOReader's
`ffi/archiver` into `orbit.koplugin.new` (every file must sit under `orbit.koplugin/`), checks
the unpacked `main.lua` declares the release's version, and swaps the folder in through
`orbit.koplugin.old`. The new version runs from the next KOReader start. A copy taken straight
from the repo says `0.0.0-dev`; releases stamp the tag into it (`package.sh`).

**Recommended settings** (0.11.0, [design](../../docs/design/addon-mode.md) §5): at KOReader's
start, on update and when the companion's capabilities change, the plugin looks at each item it
has not settled before. An item still at its stock default (BookOrbit's `default_settings`,
KOReader's gestures defaults, or no value saved) is set, with a backup in
`orbit_android.recommended_backup`; an item the user changed is never overwritten, only listed
"to review". Items: BookOrbit Auto-sync on, further ahead → Silent, Make BookOrbit home;
KOReader's Action when Wi-Fi is off → Turn on (only with Wi-Fi via the companion); in books, hold
top-right → Sync and sleep, hold top-left → BookOrbit: sync all books, swipe right along the
bottom edge → BookOrbit: this book, two-finger swipe up → Orbit Companion: apps (only when the
companion offers other apps). A pass that changed something shows one line off-book for 4 s.
The review page lists To review (Use Orbit's / Keep mine), Applied (Undo), Kept yours and
Unavailable. Every pass logs `recommended (why): applied N | to review M | …`.

Dispatcher actions (for any gesture): `orbit_sync_and_sleep`, `orbit_go_home`,
`orbit_open_companion`, `orbit_open_apps` ("Orbit Companion: apps").

The companion interface is in [`android/docs/INTERFACE.md`](../docs/INTERFACE.md).

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
| End of book: mark, sheet, send after the outbox, write back, hold a stale push ([design](../../docs/design/end-of-book/DESIGN.md)) | KOReader `ReaderStatus:onEndOfBook`/`markBook` (readerstatus.lua:38, :212); `enqueueLifecycleSnapshot` main.lua:394; `updateProgress`/`pushProgressAfterBookSync` bookorbit_progress_sync.lua:295, :284; `newClient` main.lua:272; `catalogBook`/`catalogSetReadStatus`/`catalogSetRating` bookorbit_api.lua:737, :705, :709; `StateManager.getBook`/`mutate`/`onDeviceMaps` :253, :307, :348; `BookOrbitSidecar.rememberServerState`/`applyServerStateLive`/`applyServerStateSidecar` :276, :401, :411; catalog `downloadDefaultFile`/`downloadFile` bookorbit_catalog_download.lua:166, :213 | KOReader's own end screen; nothing sent by Orbit |
| Local-first Home: overlay, quiet refresh, ⟳ and stamp ([design](../../docs/design/local-first/DESIGN.md)) | `BoardData.build` bookorbit_board_data.lua:628; catalog `dashboardRootFetch` bookorbit_catalog_dashboard.lua:113, `switchTo` :847, `refreshOnDevice` :592, `refreshCurrent` :475, `boardHeader` (its `statusCluster` upvalue) bookorbit_catalog_board.lua:149-151, `boardRun` :882, `boardRefreshTile` :811, `boardRefreshClock` :846, `listRun`/`listHeader` bookorbit_catalog_lists.lua:739, :1155; `ListView.header` (its `region` upvalue) bookorbit_list_view.lua:93, :162; outbox `listMetadata`/`isBlocked` bookorbit_lifecycle_outbox.lua:225, :247; `sidecarMtime` bookorbit_sidecar.lua:87 | Home stays the plugin's |
| Write-through cache, Refresh / Full refresh, cover ETags ([design](../../docs/design/write-through-cache.md)) | API `request` bookorbit_api.lua:372, `requestBlocking` :261, `runInSubprocess` :336 (the catalog's `fetch` runs requests in a child, bookorbit_catalog.lua:881), `downloadCatalogThumbnail` :747, `getProxy` :215; catalog `evictCachedCovers` bookorbit_catalog_thumbnails.lua:237 (kept off for our ⟳), `scheduleThumbnailDownloads` :274, `thumbnailPath` :199, `invalidateThumbnail`, `dashboardBooks` bookorbit_catalog_dashboard.lua:275, `loadDashboardRoot` :248, `runConnected` bookorbit_catalog.lua:924 (offline: from the cache), API `download` (offline: connect first); end of book downloads with `fetchDeliveryBook` bookorbit_catalog_download.lua:92 and `supportedFiles` bookorbit_catalog_detail.lua:382; outbox `diagnostics().drainable` bookorbit_lifecycle_outbox.lua:303-316 | requests go straight to the server, as before |
| Offline mirror, first paint from the cache, cover logging, remove with a book open (v0.11.1) | catalog `initialDashboardContext` bookorbit_catalog_dashboard.lua:69, `hydrateOnDeviceMaps` bookorbit_catalog.lua:614, `paramsForEntry` :1111, `fetchBookPage` :1133, `loadOnDevice` :1187, `effectiveOrder` :1453; `listDecorateBookQuery`/`listSectionParams` bookorbit_catalog_lists.lua:229, :246; `cancelThumbnailJobs`/`downloadThumbnailBatch` bookorbit_catalog_thumbnails.lua:249, :368; `boardDustRemove` bookorbit_catalog_board.lua:953, `detailRemoveFromDevice` bookorbit_catalog_detail.lua:762; `_onSuspend` main.lua:1340 (skipped on an app switch with the book unchanged) | as before: no mirror, the plugin's own paint and remove |
| Nothing interrupts reading ([design](../../docs/design/reading-gate.md)) | `Toast.show`/`Toast.error` bookorbit_toast.lua:170, :176 (held while reading) | toasts show at once |

At start the plugin checks each private symbol's type (`Compat.check`). A missing one turns off
only its feature, logs `OrbitAndroid: compat: <feature> unavailable (plugin <version>)`, and
the menu status and Test sync path say e.g. "BookOrbit 2.5.0 changed: Sync while reading is
off". CI (`.github/workflows/plugin-compat.yml`: pull requests, release tags, weekly) runs
`test/plugin_compat.lua` against the latest `bookorbit/bookorbit` plugin and, on the weekly
run, opens an issue "BookOrbit plugin <ver> changed: <symbols>".

KOReader loads it like any plugin (`PluginLoader:loadPlugins`, used by readerui.lua:464 and
filemanager.lua:418), sorted by path, so `orbit.koplugin` comes after `bookorbit.koplugin` in
the same plugins folder and gets each event (Suspend, Resume, PageUpdate, ReaderReady) after
the BookOrbit plugin has handled it. It shows in the Plugin manager as "Orbit".

## Logs

Every step and outcome is logged with timings:

```
adb logcat -v time | grep OrbitAndroid
```

## Tests

Pure logic (scheduling, outbox verdicts, reading decisions, update version comparison and
`SHA256SUMS` parsing), any Lua 5.1-5.4 or LuaJIT:

```
luajit android/koreader/test/test_logic.lua
```

Flow wiring against stand-ins for KOReader, the JNI bridge and the plugin (LuaJIT only,
because the plugin uses `ffi`):

```
luajit android/koreader/test/test_flows.lua
```

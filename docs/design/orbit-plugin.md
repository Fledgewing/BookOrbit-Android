# Orbit as a KOReader plugin (roadmap 8a)

Status: shipped in Android 0.8.0. 8b (hooking the BookOrbit board and replacing KOReader's
menus) builds on this and is still to do.

Outcome: everything the user patch `koreader/patches/2-orbit-android.lua` did now lives in the
plugin `koreader/plugins/orbit.koplugin` (`android/koreader/orbit.koplugin`, AGPL), with no
behaviour change. The companion and `tools/install-usb.sh` install, update and verify the
plugin folder as they did the patch, and they delete the old patch.

Citations are KOReader at the pin in `tools/upstreams.lock` (`upstream/koreader`).

## Module layout

The patch was one 4,700-line file of top-level `local`s. The plugin keeps that code as it was
and splits it by section:

- `main.lua`: the header, `PATCH_VERSION` (stamped by `android/koreader/package.sh`), the
  file list, the test export, the old-patch check, and `return OrbitAndroid`.
- `logic/*.lua` (10 files): pure logic with no KOReader modules: schedule, plan, update,
  wifi_plan, home_plan, compat, stats, clicks, prompts, group. `test/test_logic.lua` loads
  only these (`ORBIT_ANDROID_TEST`).
- `ko/*.lua` (25 files): the KOReader side, in the patch's order: base, settings, jni,
  companion, shared, bookorbit, net, sync, wifi, updater, background, runtime,
  clicks_channel, keys, module, start, home, sleep, reading_sync, test_sync_path,
  companion_ui, recommended, menu, wifi_backend, grouping.
- `_meta.lua`: the name and description in KOReader's Plugin manager ("Orbit").

**One shared environment.** `main.lua` `loadfile`s each file in order and `setfenv`s it to one
table whose `__index` is `_G`. The patch's top-level `local x` became a plain `x` in that table,
so the code moved between files unchanged and nothing leaks into `_G`. Converting it to
`require`d modules with explicit exports would touch every cross-reference (about 140 names)
for no behaviour gain. That is left for when 8b reshapes the code anyway. A check during the
split (`luac -l` over every file) found no global reads besides standard ones, the names the
files define, and `G_reader_settings`.

## Load order and patch-time hooks

The patch ran at `late` priority (`reader.lua:190`, `userpatch.applyPatches(userpatch.late)`),
before the file browser or the reader started. It appended its module to
`PluginLoader:loadPlugins` and hid it from the Plugin manager.

A plugin's `main.lua` runs inside the first `PluginLoader:loadPlugins()`
(`frontend/pluginloader.lua:271-289`, `pcall(dofile, mainfile)` at :244). That call happens once
per process, from FileManager's or ReaderUI's init (`readerui.lua:464`). Every plugin's
`main.lua` runs before any plugin is instantiated. So the module-level hooks keep working from
`main.lua`, and no early hook is needed:

| Patch-time step | Now |
|---|---|
| `NetworkMgr` overrides, `wrapRequests("socket.http"/"ssl.https")` | `ko/wifi.lua`, `ko/wifi_backend.lua` at load. The wrapper replaces the `request` field of the module table, so BookOrbit's `local http = require("socket.http")` (`bookorbit_api.lua:9`, which calls `http.request` at :236 and :248) still goes through it. |
| `Clicks.install("load")`, `silentWifiOn()` | At load. This is slightly later than `late`, but still before the first FileManager or ReaderUI finishes init. |
| Cold-start "reopen the killed book" (`open_book_at_exit`) | Unchanged: it runs from the module's init. |
| Append the module to `loadPlugins`, hide it from the Plugin manager | Dropped: KOReader loads it as a plugin and lists it as "Orbit", so it can be turned off there. |

**After BookOrbit.** `enabled_plugins` is sorted by path (`pluginloader.lua:289`). The user
plugins folder is `<data dir>/plugins/` (`:193-198`; `/sdcard/koreader/plugins/` on Android),
and both plugins sit in it, so `bookorbit.koplugin` sorts before `orbit.koplugin`. Orbit therefore
gets each event (Resume, Suspend, PageUpdate, ReaderReady) after BookOrbit, as the appended
patch module did. Built-in plugins (`plugins/…`) now sort after Orbit rather than before it.
Orbit uses one of them, `ui.gestures`, and only from menu actions at run time, never in init.
In case some other setup orders BookOrbit after Orbit, the page-push hook falls back to the
next tick when `ui.bookorbit` is still missing at init (`ko/module.lua`).

## Settings and finding BookOrbit

- Settings stay under `orbit_android` in `G_reader_settings` (`ko/settings.lua`). An upgrade
  from the patch keeps every setting.
- BookOrbit is found as before: `ui.bookorbit`, the instance KOReader registers under the
  plugin's name (`readerui.lua:96`), and the patch's existing `package.loaded` lookups for its
  modules (`ko/bookorbit.lua`). The Compat check (`logic/compat.lua`) is unchanged.
- The module's `name` is now `orbit` (it was `orbitandroid`). Nothing persisted used that
  name, and the Dispatcher action ids (`orbit_*`) are unchanged.

## Old patch and plugin together

The plugin's `main.lua` looks for the patch's hooks: if `PluginLoader.loadPlugins` or
`genPluginManagerSubItem` was defined in a file named `2-orbit-android.lua`, it returns
`{ disabled = true }` (`pluginloader.lua:247`) and installs nothing. The patch keeps running
until it is deleted, so nothing is hooked twice. The companion and `tools/install-usb.sh`
delete the patch (and a stray `.new`) whenever they install the plugin. Test:
`test_flows.lua` "plugin: stays off while the old patch is loaded".

## Install, update, verify

- **Release** (`release.yml`): `android/koreader/package.sh <version>` builds
  `orbit.koplugin.zip`. It holds every file under `orbit.koplugin/`, has `PATCH_VERSION`
  stamped into `main.lua`, and fixes file times and order. It is listed in `SHA256SUMS` and
  attested like the APK. The release no longer carries `2-orbit-android.lua`.
- **Companion** (`PatchInstaller`) downloads the zip from the release matching the app and
  checks its SHA-256 against `SHA256SUMS`. It unpacks the zip into
  `koreader/plugins/orbit.koplugin.orbit-new`, refusing any entry outside `orbit.koplugin/` or
  holding `..` (`PatchFile.zipMember`). It checks the stamped version, then swaps the folder in
  through `.orbit-old`, the same swap the BookOrbit plugin install uses, and deletes the old
  patch. `installedVersion()` reads the plugin's `main.lua`, falling back to the old patch. So
  after an app update over a 0.7.x patch, `UpdateFlow.patchAfterUpdate` installs the plugin
  like any patch update. The companion's restart command and stale-version restart then
  restart KOReader as before, from 0.3.1 and from 0.5.0 respectively.
- **Self-update** (`ko/updater.lua`) checks the zip and `SHA256SUMS` the same way. It unpacks
  with KOReader's `ffi/archiver` into `orbit.koplugin.new`, checks the version, and swaps the
  folder through `orbit.koplugin.old`. `RestartPlan` reads the on-disk version from the
  plugin's `main.lua`.
- **USB** (`tools/install-usb.sh`) checks the zip against `SHA256SUMS` and the attestation,
  unpacks it on the computer with the same member and version checks (`unpack_orbit`), pushes
  it beside the live folder, swaps it in, and deletes the old patch.

## Upgrade from 0.7.0 with the patch installed

1. The 0.7.0 companion updates itself to 0.8.0. Its new process sees the patch's version
   (0.7.0) as installed and installs the plugin zip. The patch file is deleted.
2. The running 0.7.0 patch no longer finds its file, so it makes no restart of its own
   (`RestartPlan.decide` → "none"). The companion's restart command, which the patch has obeyed
   since 0.3.1, restarts KOReader once no book is open, or when the screen next goes off.
3. KOReader starts with only the plugin. It reports 0.8.0, and Setup shows "Orbit plugin
   installed (v0.8.0)".

A 0.7.0 patch whose companion doesn't update finds no `2-orbit-android.lua` in 0.8.0, reports
"has no 2-orbit-android.lua", and keeps running 0.7.0. The companion is required on Android
and updates itself, so this only lasts until the companion's next update.

## Doors

All two-way doors, settled here:

- The shared environment instead of `require`d modules. It can be reshaped any time.
- The 0.8.0 release drops the `2-orbit-android.lua` asset. Patch-only setups stay on 0.7.0
  until the companion updates, and a later release could add the asset back.
- The Setup rows were renamed to "Orbit plugin installed" and "Orbit plugin answered". The row
  ids are unchanged, so snoozes and ignores carry over.

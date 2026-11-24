# KOReader patch ↔ Orbit Companion interface (protocol 1)

The Orbit KOReader plugin (`android/koreader/orbit.koplugin`, up to 0.7.x the user patch
`2-orbit-android.lua`; "the patch" below) and the Orbit Companion app talk
through Android intents only. The companion never learns the login or the sync state: the
BookOrbit plugin owns all of that. One exception: the sleep screen's sharp covers
(docs/design/lock-screen.md L7) need the server URL and the KOReader username, which the plugin
writes into `pool.json`; the companion signs in to OPDS with a login the user types once and keeps
only the OPDS cover token. Never the KOReader key.

Package: `net.fledgewing.orbitcompanion` (placeholder, used everywhere below).

## Patch → companion: explicit broadcasts

The patch builds an `Intent(action)`, calls `setPackage("net.fledgewing.orbitcompanion")`,
adds `FLAG_INCLUDE_STOPPED_PACKAGES | FLAG_RECEIVER_FOREGROUND`, and calls
`Context.sendBroadcast`. The companion declares one exported manifest receiver with an
intent filter for these actions (manifest, not runtime: KOReader may be in the background
and the companion may not be running).

Every extra is a **string**. Every broadcast carries `proto = "1"`,
`sender = "org.koreader.launcher"` and `patch_version` (the patch's `PATCH_VERSION`; the
companion's "KOReader patch installed" row uses it when it can't read the file).

| Action (`net.fledgewing.orbitcompanion.action.…`) | Extras | Companion does |
|---|---|---|
| `NET_UP` | `reason`, `request_id`, `wifi` (`"1"`/`"0"`), `tailscale` (`"1"`/`"0"`), `wake_lock_s` (`"0"` = none), `owner` (`"auto"`/`"manual"`), `mode` | Cancel any pending Wi-Fi-off timer. Wi-Fi it turns on is owned by `owner` (`manual`: the reader asked by hand; already-on Wi-Fi also becomes `manual`). If `wake_lock_s` > 0, hold a partial wake lock for that long, hard-capped at 25 s. If `wifi = "1"` and Wi-Fi is off, turn it on. If `tailscale = "1"`, send Tailscale `CONNECT_VPN`. Record the time it took Wi-Fi to come up, for its status page. |
| `NET_DONE` | `reason`, `ok` (`"1"`/`"0"`), `seconds` (e.g. `"4.2"`), `detail`, `restore` (`"off"` when Wi-Fi was off before) | Release the wake lock. `restore = "off"` on a sleep sync acts as "off now" (unless the owner is `manual`). For `reason` `sleep` or `sync_and_sleep`: record "Last sleep sync", then apply "Wi-Fi after sleep sync": keep on; off after 30 min (the timer turns Wi-Fi off only if the screen is still off when it fires); or off now, only while the screen is off. For `sync_and_sleep` the screen is still on at `NET_DONE` (`SLEEP_NOW` follows), so "off now" waits for the next screen-off, up to 30 s later. |
| `WIFI_OFF` | `reason`, `auto` (`"1"`/`"0"`), `mode` | Turn Wi-Fi off. `auto = "1"` (the patch's automatic off: idle, restore) is refused when the owner is `manual`, and waits while the companion downloads an update. `auto = "0"`: KOReader's own "Wi-Fi off" toggle, or "Off while reading" when a book opens. |
| `SETTINGS` | `wifi_mode` (`always_on`/`off_reading`/`jit`), `wifi_idle_min` (`1`/`2`/`5`/`10`), `home_button` (`smart`/`bookorbit`), `settings_at` (ms since epoch); patch 0.4.8+: `reading_schedule` (an id below), `reading_schedule_applied_at` (ms, the last companion request it applied) | Store the shared settings when `settings_at` is newer than its own. Always record `reading_schedule` (the patch owns it) and drop its own pending request once `reading_schedule_applied_at` ≥ that request's `at`. Sent at start, on a menu change and after applying a request. The sleep screen (cap `sleep_screen`, docs/design/lock-screen.md S1) adds `sleep_mode` (`off`/`recommended`/`current`), `sleep_from` (`up_next`/`want_to_read`/`discover`/`scope:<id>`/`collection:<id>`), `sleep_leave_out` (rules, one per line: `tag:<name>`, `scope:<id>`, `collection:<id>`), `sleep_hours` (`0` = Every sleep, `1`/`3`/`6`/`12`/`24`; an older companion takes `0` as the default 6), `sleep_text` (≤ 60 characters), `sleep_battery` (`1`/`0`), `sleep_style` (`bar`/`overlay`), `sleep_text_position` (`right`/`left`/`top`/`bottom`), `sleep_battery_corner` (`bottom_left`/`bottom_right`/`top_left`/`top_right`); missing ones keep their value. In Add-on mode without the service only these are recorded. |
| `STATS` | `seq`, `period_s`, `pages`, `full`, `partial`, `content` (`text`/`comic`/`webtoon`/`pdf`/`none`), `open` (`1`/`0`), `reading_min`, `wifi_mode`, `reading_schedule`, `reason`; plugin 0.11.1+: `reading` (`1` = a book open in front, not BookOrbit Home or a list over it; `0` on `close`/`suspend`) | Battery stats batch: store the counts with the current state; a book is "in front" while `open=1` (at most 6 min). `reading` drives the companion's reading gate (docs/design/reading-gate.md); without it, `open` and `resume`/`suspend` do. Sent every 5 min with a book open, on open/Resume/Suspend/close, never per page (docs/design/STATS-DESIGN.md). |
| `SETUP_LATER` | none | The setup box's "Later" in KOReader: the companion's own Later (quiet until an update or a step stops working). Companion 0.4.1+. |
| `RELAUNCH` | `reason` (`restart`) | The patch is quitting for a restart (COMMAND `restart`, or from 0.5.0 by itself for a newer patch file on disk, DESIGN "One update"): start KOReader again after 2.5 s. Patch 0.3.1+. |
| `REPORT` | `signed_in` (`"1"`/`"0"`), `recommended` (`none`/`partial`/`reviewed`/`applied`), `conflicts` (a count), `reason` | Companion 0.11.0+: one yes/no about the BookOrbit login and the recommended settings' state, for its Setup rows "Signed in to BookOrbit" and "Recommended settings". Never the server, the account or the key (those go only with `MIRROR` and `CHECK`); other extras are ignored. Sent at start, after a recommended pass and when either value changes. Needs no service. |
| `SLEEP_POOL` | `reason`, `wake` | Companion cap `sleep_screen`: the files in `koreader/settings/orbit-sleep/` changed (below). The picture sink redraws `Pictures/Orbit/sleep.png`; the screen saver reads them at the next sleep. With `wake` = `"1"` (reason `wake`): KOReader resumed after a real sleep (the screen went off, not an app switch); with Every sleep the picture moves on for the next sleep, once per wake (the service's screen-on counts as the same wake). Needs no service. |
| `MIRROR` | `reason`, `server`, `user`, `userkey` | Cap `cache_worker` (docs/design/companion-worker.md): run the offline mirror from `koreader/settings/orbit-cache/mirror/plan.lua` on the cache worker thread (below). The login is used only as `x-auth-user`/`x-auth-key` on requests to `server`, held in memory, never written or logged. A new `MIRROR` replaces a waiting one. Needs no service. |
| `CHECK` | `reason`, `cache_key`, `path`, `mode` (`open`/`refresh`/`full`), `owner`, `server`, `user`, `userkey` | Cap `cache_worker`: ask `server` for `path`, compare with what the plugin would serve under `cache_key` (its entry, else the mirror's pages), save a changed reply and answer with an event (below). Checks go before mirror jobs. Needs no service. |
| `STORAGE` | `reason`, `limit` (bytes, empty: none), `cover_dir`, `mirror_covers` (`"1"`/`"0"`) | Cap `cache_worker`: count everything Orbit stores (the cache's index entries, the index, the mirror, the cover folder) and, over `limit`, remove what StorageLogic says: least recently used browsing entries and plain covers first, then covers saved for offline, never lists and books saved for offline. The companion deletes the covers; the entries go to the plugin in a `storage` event (it owns its index; one used since the count stays). No login. Needs no service. |
| `COPIES` | `reason` | Cap `cache_worker`: which copies on the reader changed in the library (docs/design/keep-copies-current.md), from `koreader/settings/orbit-cache/copies/ask.lua` (below): the newer of the end-of-book cache's, the cache's and the mirror's saved details per book, compared with each copy's hash, and only copies whose file is on the reader. Answers with a `copies` event; the plugin queues and downloads them. No login. Needs no service. |
| `UPDATE` | `reason` | The plugin's "Check for updates" (it downloads nothing itself: the plugin and the companion ship together). A check by hand, as from the companion's Update page: a newer release installs the companion and then the plugin of that release; an up-to-date companion installs the plugin of its own release when the one on disk is older (PatchInstaller). Every mode; needs no service. |
| `SLEEP_NOW` | `reason` (`sync_and_sleep` or `sync_and_sleep_failed`) | `DevicePolicyManager.lockNow()` when the device-admin approval (`force-lock` only) is granted; otherwise logged and the screen stays on. At most one per 5 s. (The accessibility `GLOBAL_ACTION_LOCK_SCREEN` fallback is not in companion v1; add it only if the firmware blocks device admin.) |

`reason` values: `start` (KOReader just started; on firmwares that stop KOReader after sleep,
every wake is a fresh start),
`wake`, `retry`, `sleep` (power button), `sync_and_sleep`, `reading` (sync while reading),
`test` (Test sync path), `open` (a book opened), `book_closed`, `update`, `koreader_wifi_on`,
`koreader_wifi_off`, and Wi-Fi-off reasons such as `just in time: idle 2 min`. Unknown reasons must be
accepted and treated like `wake`.

Order for a sleep sync: `NET_UP` (with a wake lock), then exactly one `NET_DONE`, at most
20 s later by default (the patch's "Sleep sync limit"). The companion's own 25 s cap covers
a KOReader that is frozen or killed before it sends `NET_DONE`.

"Sync and sleep": `NET_UP`, `NET_DONE`, then `SLEEP_NOW`. On failure the patch shows its
message for 3 s first.

The companion's setup row "KOReader patch answered" is ticked by any broadcast carrying
`sender = "org.koreader.launcher"` or by a loopback `GET /status`.

In Add-on mode (companion 0.11.0+, `docs/design/addon-mode.md` §7.1) the receiver routes by
capability: an action reaches the service only when a helper keeps it running; `SETUP_LATER`,
`REPORT` and the book state from `STATS` are recorded without it; the rest are logged and
dropped. In Full every action reaches the service as before.

## The sleep screen's files (cap `sleep_screen`)

In `koreader/settings/orbit-sleep/` (docs/design/lock-screen.md). The plugin writes; the companion
only reads, except `state.json`.

| File | Written by | Holds |
|---|---|---|
| `pool.json` | plugin, at a sync (never at sleep) | `{v, at, source, items: [{id, title, file}], server, user, storage_limit_mb}`: the batch of up to 24 ready covers, in show order; `file` is `covers/<id>.jpg`; `server` is the plugin's `server_url` (`…/api/v1`), `user` its KOReader username (the OPDS sign-in's default), `storage_limit_mb` Orbit's storage limit (the sharp covers take at most a tenth of it, 24 MB cap) |
| `covers/<id>.jpg` | plugin | the pool's covers (400 × 600 thumbnails), fetched by ETag; others pruned. The companion's sharp covers (its own storage, `files/sharp-covers/`) replace them on screen when signed in |
| `current.png`, `current.json` | plugin, when a book opens | the current book's cover and `{v, title, authors, path, id, file, at}` |
| `state.json` | companion | `{v, shown, changed_at, shows: {"<id>": n}}`: the cover shown, when it changed, and with Every sleep how often each ready cover was shown; the plugin's shuffle bag moves past `shown` (hours) and it retires covers shown 3 times (Every sleep) |
| `scopes.json` | plugin | `{v, at, scopes: [{id, title, count}], collections: [...]}`: every smart scope and collection, for the pickers |
| `bag.lua`, `leave_out.lua` | plugin | private: the shuffle bag and the daily Leave-out members |
| `vendor-screensaver.txt` | `tools/install-usb.sh --sleep-screen on` | the three screen-saver values it replaced, for `off` |

`GET /status` and the status file carry the sleep keys in `settings` and
`"sleep": {"shown_by": "…", "sink": "dream"|"picture"}`.

## The cache worker's files (cap `cache_worker`)

In `koreader/settings/orbit-cache/` (docs/design/companion-worker.md). Every file is a Lua literal
in the cache's format (`Cache.encode`; `LuaValue.kt` reads and writes the same), written to a
temp file and renamed. None holds the login. Keys, file names, list pages and cover names follow
`shared/fixtures/cache/worker.json`, which both sides' tests check.

| File | Written by | Holds |
|---|---|---|
| `index.lua`, `<hash>.lua` | plugin (and the companion for a changed `CHECK`) | the plugin's own cache: the index and its entries `{key, body, fetched_at, validated_at, path}`; the companion reads the index for the lists to save |
| `events/<n>.lua` | companion | a check's answer: `{kind = "checked", key, changed, bytes, ids, at}`, `{…, unchanged, saved}` or `{…, err}`; a copies lookup: `{kind = "copies", why, checked, found = {{md5, path, book_id, file_id, why}}, gone}`; a storage count: `{kind = "storage", why, drop = {{key, used_at}}, totals, removed, used, after, limit}` |
| `copies/ask.lua` | plugin, before each `COPIES` | `books` (`md5`, `path`, `book_id`, `file_id`, `incompatible`), `eob` (book id -> `files`, `saved_at`), `owner`, `server`, `detail_template`, `sentinel` |
| `storage.lua` | companion, after each `STORAGE` | the last count's `totals` (`used`, `kept`, `cache`, `cover`, `mirror_cover` bytes) and `at`; the plugin reads it at start |
| `mirror/plan.lua` | plugin, before each `MIRROR` | `run`, `op` (`full`/`resume`/`revalidate`/`covers`), `reason`, `owner`, `lib_version`, `sentinel`, `templates` (per section: `path`, `series_name_path`), `detail_template`, `sections`, `seed_lists`, `seed_details`, `legacy`, `legacy_lists`, `cover_dir`, `covers_on`, `limit` (the worker counts what else is stored at the run's start) |
| `mirror/<hash>.lua` | companion | the mirror's pages and details, in the entry format |
| `mirror/status.lua` | companion, every 5 s and at the end | `{v = 3, runner, run, running, beat, op, at, lib_version, done, total, left, skipped, covers, cover_total, limit_note, revalidating, bytes, cover_keep_n, started_at}` |
| `mirror/summary.lua` | companion, at the end of a run | `{run, why (finished/stopped/no answer/busy), jobs, status, changed, written, written_more, saved, revalidated, bytes_delta, cover_bytes_delta}` |
| `mirror/cover_keep.lua` | companion | the cover names "Save every cover for offline" keeps, for the plugin's pruner |
| `mirror/worker-state.lua` | companion | private: its queue, lists, sizes |
| `mirror/stop` | plugin | stop the run after the job in hand |
| covers, in the plugin's thumbnail folder | companion | `<memoKey>.jpg` and `.etag`, as the plugin names them |

The plugin needs the companion of its own version for any of this (`Companion.workerProblem`):
otherwise it shows "Orbit Companion needed" or "Update Orbit Companion" and sends nothing.

## Patch → companion: activities

Started with `Context.startActivity`, `setPackage(...)` and `FLAG_ACTIVITY_NEW_TASK`. The
activity needs an intent filter with the action and `android.intent.category.DEFAULT`.

| Action | Opens |
|---|---|
| `net.fledgewing.orbitcompanion.action.SHOW_STATUS` | Companion status (mockup screen 3) |
| `net.fledgewing.orbitcompanion.action.SHOW_APPS` | The launcher's apps page (mockup screen 2) |
| `net.fledgewing.orbitcompanion.action.SHOW_SETUP` | The "Setup needs you" prompt (the setup box's "Fix now"). Companion 0.4.1+; the patch falls back to `SHOW_STATUS`. |
| `net.fledgewing.orbitcompanion.action.SHOW_PIN` | The Settings PIN keypad (companion 0.4.4+). The patch's Orbit menu asks for it while `/status` says `pin_locked: true`; it closes at once when no PIN is set or it's already unlocked. The unlock state comes back through `/status`. |
| `net.fledgewing.orbitcompanion.action.RELAUNCH_UI` | Companion 0.11.0+, Add-on only: an invisible window the plugin starts just before it quits for a restart; it starts KOReader again 2.5 s later (no Home role to do it from the background). |
| `net.fledgewing.orbitcompanion.action.SHOW_LAUNCHER` | The launcher page (the one a double Home shows); Home pressed on BookOrbit home. Companions before 0.2.1 lack it; the patch then opens `SHOW_APPS`. |
| `net.fledgewing.orbitcompanion.action.SHOW_SLEEP` | Settings › Sleep screen (cap `sleep_screen`), behind the Settings PIN: the Orbit menu's "Shown by" row. |
| `net.fledgewing.orbitcompanion.action.SLEEP_PREVIEW` | The sleep screen as it would show now, for 5 s or until a tap (cap `sleep_screen`); never moves the rotation on. |

## Companion → patch: "go home"

This applies when Settings › "Home opens" is KOReader + BookOrbit (the default). With another
app chosen, Home starts that app's own launch intent and KOReader gets no command (DESIGN
"Home opens").

The launcher starts KOReader explicitly:

```
component: org.koreader.launcher/org.koreader.launcher.MainActivity
action:    android.intent.action.MAIN
flags:     FLAG_ACTIVITY_NEW_TASK
extra:     net.fledgewing.orbitcompanion.extra.COMMAND = "home" | "home_smart"   (String)
extra:     net.fledgewing.orbitcompanion.extra.FROM = "other_app"   (optional, home_smart only)
extra:     net.fledgewing.orbitcompanion.extra.ROTATION = "portrait" | "landscape" | "reverse_portrait" | "reverse_landscape"   (companions after 0.11.2)
```

`ROTATION` is how the display is held when Home is pressed (`Display.getRotation()` of the
default display), named as KOReader's rotation modes the way KOReader's launcher reads the display
(android-luajit-launcher `extensions/ActivityExtensions.kt:295-302`: on a portrait panel
`ROTATION_90` is `reverse_landscape`). On Android, KOReader's rotation is the activity's requested
orientation, which turns the whole display (koreader-base `ffi/framebuffer_android.lua:78-91`), and
every new file browser sets its own rotation, `fm_rotation_mode` or upright
(`filemanager.lua:63-69`, from `showFiles` `:1321`: KOReader's start, `reader.lua:291`, and every
book close, `readerui.lua:594`). BookOrbit Home sits over the file browser, so it came up in that
rotation, not the held one. The plugin (`HomePlan.rotation`) turns KOReader to `ROTATION` before
BookOrbit Home shows, through `FileManager:onSetRotationMode`; never with a book open (a book keeps
its own rotation), nor with KOReader's "Lock auto rotation" on. Within KOReader, the plugin keeps
the current rotation when a book close opens a new file browser (it replaces
`FileManager.setRotationMode`). Older plugins ignore the extra.

KOReader's start turns nothing either. Its activity starts `nosensor` (android-luajit-launcher
`AndroidManifest.xml:42`), so the display stays as held, but before any plugin loads KOReader turns
it to `closed_rotation_mode` (Device init, `device.lua:350-355`) and then to the file browser's
rotation. The plugin installs an early user patch, `koreader/patches/1-orbit-start-rotation.lua`
(source `orbit.koplugin/patches/`), copied when missing or different. KOReader runs it first
(`reader.lua:26-27`); it reads the display's rotation (`android.orientation.get`), puts it in
`closed_rotation_mode` for this start (KOReader rewrites that at exit), and has the first file
browser skip its rotation once. With it, a Home cold start turns nothing, and the plugin skips
`ROTATION` at the start. Without user patches (the F-Droid build, or patches turned off), the plugin
turns to `ROTATION` after the start: one more turn.

Both commands go through the patch's `HomePlan`. `home_smart` is sent when the shared "Home
button" setting is "Back to my book, then BookOrbit home" (the default), `home` when it is
"BookOrbit home".

| Where KOReader is | `home_smart` | `home` |
|---|---|---|
| Reader showing a book, Home pressed in KOReader | BookOrbit home, opened on top of the book (the book stays open) | BookOrbit home |
| A BookOrbit page past its first (the dashboard's page 2, a list's page 3), nothing over it, Home pressed in KOReader (v0.5.4) | that screen's page 1 | the same |
| BookOrbit home (the plugin's dashboard) is the top widget, Home pressed in KOReader | the companion's launcher page (`SHOW_LAUNCHER`) | the companion's launcher page |
| Any other BookOrbit screen on top (v0.4.9): a book detail, list, search, board, settings, a sheet or dialog over the catalog, the catalog in a non-dashboard mode | BookOrbit's main page (what is over the catalog is closed, then the catalog's own `goDashboard`, or a fresh BookOrbit home) | the same |
| Elsewhere (another app in front, a menu, KOReader settings, the file browser) **with a current book**: one still open, or one Home itself closed (`home_book`) | the book (whatever covers it is closed, or the book is reopened) | BookOrbit home |
| Elsewhere with **no current book** (the user closed it, or none opened) | BookOrbit home | BookOrbit home |
| Cold start after KOReader was **killed with a book open** | that book (reopened) | BookOrbit home |

So presses in KOReader step book → BookOrbit home → companion, and Home from another app
(the companion included) never loops back to the companion. A book the user closed is never
reopened from history. BookOrbit home opens on top of the reader through the plugin's public
action (`BookOrbitOpenDashboard`), so the book stays open; only when the plugin can't do that
does Home close the book, and then it keeps it as `home_book` until the user closes a book
themselves or opens another one. "Killed with a book open" is the patch's `open_book_at_exit` setting:
set on ReaderReady (flushed at once), cleared when the reader closes (Back to file browser,
Home, Exit); a kill or suspend leaves it set. "Dashboard on top": the plugin's catalog widget
(`main.lua:1207-1230`) is `UIManager:getTopmostVisibleWidget()` (the plugin's own test,
`main.lua:1384`) and in its dashboard context (`BookOrbitCatalog:dashboardMode`,
`bookorbit_catalog.lua:1875-1877`).

"From another app" is `FROM = "other_app"` when the companion knows (one of its own pages was
in front, or KOReader had gone away), otherwise KOReader's pause before the command: 2.5 s or
more counts as another app.

Do not use `ACTION_VIEW`: KOReader treats that as "open this file". `MainActivity` is
`singleInstance`, so a running KOReader gets the intent through `onNewIntent`, which calls
`setIntent` (android-luajit-launcher `MainActivity.kt:205-210`). The patch reads the extra at
start and on every resume, removes it, closes any open book (the reader saves it and the
plugin syncs it as on any close) and opens the plugin's BookOrbit home.

Unknown commands are logged and ignored.

When the companion sends it: on every Home press and at boot (it is the HOME app). A second
Home press within 2 s, or a KOReader that is missing, fails to start or closes within 5 s of
starting, shows the companion's launcher page instead. When Home comes back to the front
without a press (KOReader closed or was killed, e.g. by a firmware that stops the foreground
app some time after the power button), the companion starts KOReader again: with
`home_smart` + `FROM = "other_app"` in smart mode (the patch reopens the book KOReader was
killed with), without an extra otherwise; with the screen off it waits for the next screen-on.

### `restart` (patch 0.3.1+)

`COMMAND = "restart"`: the companion installed a newer patch file and the running patch is
older (Setup › "Restart KOReader to finish"). The patch saves the open book's settings (it stays
the book to reopen), sends `RELAUNCH`, and quits. KOReader's own restart
(`UIManager:restartKOReader`, frontend/ui/uimanager.lua:1766) needs a launcher script that
Android lacks (`canRestart = no`, frontend/device/android/device.lua:86), so the companion
starts it again. An older running patch ignores the command; the companion then says "close
KOReader from recent apps and reopen it" instead of showing the button.

From 0.5.5 the patch also keeps the open book as `restart_book` (the quit closes the reader,
which clears `open_book_at_exit`), and the next start reopens it at its saved place.

### `reopen_book` (patch 0.5.5+)

`COMMAND = "reopen_book"`, sent with the start that follows `RELAUNCH` when the companion's
restart went out with a book open: reopen `restart_book`, else KOReader's `lastfile`, unless a
book is already open (BookOrbit home opened by the start is closed first). It covers a restart
done by an older patch, which doesn't keep `restart_book`. Older patches ignore the command.

## Optional: companion status over loopback

`GET http://127.0.0.1:47913/status?patch_version=0.3.1` → `200` with JSON. The query
(patch 0.3.1+) tells the companion which patch is running; patch 0.5.2+ adds `&book=1|0` (a book
is open), so the companion's restart after a patch install waits for the book. Like `patch_version` in the
broadcasts. For example:

```json
{ "proto": "1", "version": "0.2.0", "wifi": true, "wifi_enabled": true, "wifi_owner": "auto",
  "tailscale": true, "screen_off_permission": true,
  "settings": { "wifi_mode": "jit", "wifi_idle_min": 2, "home_button": "smart", "settings_at": 0 } }
```

`settings` are the shared settings (above). The patch reads them on start, resume and when its
menu opens; the newer `settings_at` wins, and the patch pushes its own with `SETTINGS` when they
are newer. `keymap` (v0.4.0): clicker buttons for the patch, keyed by Android keycode, e.g.
`{"87": {"press": "next", "hold": "sync_sleep"}, "66": {"double": "home"}}`.
- Actions: `next`, `prev`, `home`, `back`, `light`, `sync_sleep`.
- Kinds: `press`, `hold` (≥ 0.6 s), `double` (≤ 0.35 s).
- Keys the reader's own buttons also send are left out, so KOReader keeps its meaning for
  them.
- The patch reads the map at start and resume. It handles mapped keys in
  `Input:handleKeyBoardEv` and drops them there, so KOReader never also acts on them. An
  empty map turns this off.

`clicker_service` (v0.4.2): the companion's accessibility service is running.
`vpn_lockdown` (v0.4.3): "Block connections without VPN" as Android reports it (`true`,
`false`, or `null` when unreadable). The patch blames it for a failed update check only when
it is `true`.
`reading_schedule_request` (v0.4.8): "Sync while reading" chosen in the companion, as
`{"id": "pg50", "at": 1763800000000}` (`null` when nothing is pending). The ids are the patch's:
`off`, `min10`, `min15`, `min30`, `min60`, `pg25`, `pg50`, `pg100`, `ch1`, `ch2`. The patch owns
the setting: at start, resume and menu open it applies a request whose `at` is newer than the
last one it applied, saves it (with that `at`) and acknowledges with `SETTINGS`. Chosen while
KOReader isn't running, it simply waits in `/status` for the next start.
`settings.home_opens` (v0.4.8): the companion's "Home opens", `koreader`, `launcher` (the Orbit
launcher page) or `app`; the patch notes it on its Home button menu entry.
`pin_locked` (v0.4.4): a Settings PIN is set and not unlocked right now. Then the patch's Orbit
menu shows only "Enter the Settings PIN…" and starts `SHOW_PIN`. Only a real `true` locks:
no answer (no companion, not running) or an older companion leaves the menu usable, so the
patch never locks anyone out.

### `GET /clicks` (companion 0.4.2+): the click channel

The patch opens `GET /clicks?patch_version=X` on the same port and keeps it open. After an HTTP
200 header, the companion writes one line per event:
- `SERVICE on|off`: the accessibility service is running, or isn't.
- `CLICK <action> <seq>`: do this now. `action` is one of `next`, `prev`, `home`, `back`,
  `light`, `sync_sleep`; a Send-key action arrives as the page turn it means in KOReader.

While a patch listens, the service takes mapped keys with KOReader in front and sends `CLICK`
instead of letting the key through. While the channel is up and the service is on, the patch
ignores mapped keys itself. When the connection closes, both fall back: the service lets keys
through and the patch handles them. The patch watches the socket in KOReader's ALooper, so a
click needs no polling.

`wifi_owner`: `none`, `auto` or `manual`. `setup_needed`: how many Setup steps need the user
(not done and not skipped); the patch shows it as one line in its menu status.
`setup_prompt` (v0.4.1): `{"key": "clicker,keyboard", "rows": ["Clicker buttons (accessibility)", …]}`
while unsnoozed rows need the user, else `null`. The patch shows a one-time box per `key`
("Fix now" → `SHOW_SETUP`, "Later" → `SETUP_LATER`), never with a book on screen.
`keymap` actions also include what a Send-key action becomes in KOReader (`next`/`prev`).

Bind to `127.0.0.1` only. The patch uses it in "Test sync path" (step 1, "Companion
answered", 1 s timeout) and treats any `200` as an answer; the fields are for display and
may grow. A companion without the endpoint still works for everything else.

## Mode and capabilities (companion 0.11.0+)

The companion says what it offers in two places: `mode` and `caps` in `/status` (while its
service runs), and the **status file** `koreader/settings/orbit-companion.json`, written
atomically whenever its mode, caps or setup state change (only if a `koreader/` folder exists):

    {"proto":"1","version":"0.11.0","mode":"addon","caps":["install","setup","stats","relaunch"],
     "setup_prompt":{"key":"…","rows":["…"]},"setup_needed":1,"written_at":…}

`mode` is `full` or `addon`. Caps: `install`, `setup`, `stats`, `relaunch` (always), `sleep_screen` (always, from the sleep screen's release; an older companion never offers it, so the plugin hides the menu), `cache_worker` (always, from the cache worker's release); `home`,
`apps` (Full); `wifi`, `sleep_sync`, `screen_off`, `clicker`, `pin` (Full, or Add-on with that
helper on; `screen_off` also needs the lock-screen permission). The plugin reads `/status` first,
then the file; a companion that answers `/status` without `caps` is older and offers everything.
A file left behind by an uninstalled or frozen companion is ignored. The plugin logs
`companion: mode … caps … (from status|file|legacy|cache, why)`.

COMMANDs added in 0.11.0 (the same extra as `home`): `signin` opens BookOrbit's own sign-in
(`promptLogin`), `recommended` opens the plugin's Recommended settings page.

## Without the companion

- The patch sends Tailscale's own broadcast itself: action `com.tailscale.ipn.CONNECT_VPN`
  to `com.tailscale.ipn/.IPNReceiver` (explicit component), once at the start of each
  network attempt and once more when Wi-Fi comes up.
- The Wi-Fi setting is "Always on" and can't be changed; KOReader's `wifi_enable_action` is
  left as it is. If Wi-Fi is off, network steps fail at once ("Wi-Fi is off") instead of
  waiting. A disabled companion (e.g. by a vendor launcher's app freeze) counts as missing,
  and the menu says who disabled it.
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
Wi-Fi on, hold a wake lock (25 s cap), lock the screen, or save a server of its choosing into
`koreader/settings/orbit-cache/` (`MIRROR`, `CHECK`; any app with storage access can write there
anyway). The BookOrbit login travels only from KOReader to the companion's package in an explicit
broadcast, which no other app receives. That is acceptable on a
single-user e-reader. Android 14 only reveals the sender when the sender opts in, so the
companion should simply bound what each action can do (the wake-lock cap, at most one
`SLEEP_NOW` per few seconds).

`RESET_PIN` (companion 0.4.4+, `net.fledgewing.orbitcompanion.action.RESET_PIN`) is not a
patch broadcast: it removes the Settings PIN and is for USB recovery only. Its receiver
(`.PinResetReceiver`) requires `android.permission.DUMP`, which only the shell (adb) holds,
and on Android 14+ refuses a sender uid other than shell or root when Android reports one.

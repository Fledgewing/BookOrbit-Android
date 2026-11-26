# KOReader plugin ↔ BookSync Companion interface (protocol 1)

The BookSync KOReader plugin (`android/koreader/orbit.koplugin`, up to 0.7.x the user patch
`2-orbit-android.lua`; "the patch" below) and the BookSync Companion app talk
through caller-checked Android provider calls, activities, a click channel and shared files.
BookOrbit owns the account and sync state. The plugin passes credentials only to the verified
companion for background jobs; the companion holds them in memory for the job and never returns
them. See [the security model](../../docs/design/security.md).

Package: `net.fledgewing.orbitcompanion`.

**The contract.** `shared/contract/companion.json` (versioned) lists every command and its
extras, the calls, the pages, the commands on KOReader's start, the click channel's lines, the
status keys, the shared files and `orbit.db`. Both sides test against it (`ContractTest.kt`,
`test_flows.lua` "contract"): each entry must be used on both sides, and neither side may offer
anything the contract lacks. Change the file, both sides and this page in the same change. This
page is the human view.

## Patch → companion: the caller-checked call

The plugin calls `ContentResolver.call(content://net.fledgewing.orbitcompanion.commands,
<action>, null, extras)` through KOReader's JNI bridge (`Jni.call`). The companion's
`CommandProvider` checks the calling UID first: only the KOReader whose signing certificate it
pinned the first time it saw it is accepted (docs/design/security.md "The caller check"). A
provider is started on demand, so a companion that isn't running still answers. The call
returns at once with `ok` (`"1"`, or `"0"` and `why`: `caller`, `unknown`); the command then
runs on the companion's main thread. There is no broadcast path: the companion's receiver is
not exported and takes only the system's boot and package-replaced broadcasts.

Before any call the plugin checks the companion itself: installed under its package name and
signed only by BookSync's release certificate (`Companion.state()` `"ok"`, read with
`PackageManager` over JNI). An app with the companion's name and another signer is
`"untrusted"`: nothing is sent to it, the login least of all, and the menus say so.

Every extra is a **string**. Every call carries `proto = "1"`,
`sender = "org.koreader.launcher"` and `patch_version` (the patch's `PATCH_VERSION`; the
companion's "KOReader patch installed" row uses it when it can't read the file).

| Action (`net.fledgewing.orbitcompanion.action.…`) | Extras | Companion does |
|---|---|---|
| `NET_UP` | `reason`, `request_id`, `wifi` (`"1"`/`"0"`), `tailscale` (`"1"`/`"0"`), `wake_lock_s` (`"0"` = none), `owner` (`"auto"`/`"manual"`), `mode` | Cancel any pending Wi-Fi-off timer. Wi-Fi it turns on is owned by `owner` (`manual`: the reader asked by hand; already-on Wi-Fi also becomes `manual`). If `wake_lock_s` > 0, hold a partial wake lock for that long, hard-capped at 25 s. If `wifi = "1"` and Wi-Fi is off, turn it on. If `tailscale = "1"`, send Tailscale `CONNECT_VPN`. Record the time it took Wi-Fi to come up, for its status page. |
| `NET_DONE` | `reason`, `ok` (`"1"`/`"0"`), `seconds` (e.g. `"4.2"`), `detail`, `restore` (`"off"` when Wi-Fi was off before) | Release the wake lock. `restore = "off"` on a sleep sync acts as "off now" (unless the owner is `manual`). For `reason` `sleep` or `sync_and_sleep`: record "Last sleep sync", then apply "Wi-Fi after sleep sync": keep on; off after 30 min (the timer turns Wi-Fi off only if the screen is still off when it fires); or off now, only while the screen is off. For `sync_and_sleep` the screen is still on at `NET_DONE` (`SLEEP_NOW` follows), so "off now" waits for the next screen-off, up to 30 s later. |
| `WIFI_OFF` | `reason`, `auto` (`"1"`/`"0"`), `mode` | Turn Wi-Fi off. `auto = "1"` (the patch's automatic off: idle, restore) is refused when the owner is `manual`, and waits while the companion downloads an update. `auto = "0"`: KOReader's own "Wi-Fi off" toggle, or "Off while reading" when a book opens. |
| `SETTINGS` | `wifi_mode` (`always_on`/`off_reading`/`jit`), `wifi_idle_min` (`1`/`2`/`5`/`10`), `home_button` (`smart`/`bookorbit`), `settings_at` (ms since epoch); patch 0.4.8+: `reading_schedule` (an id below), `reading_schedule_applied_at` (ms, the last companion request it applied) | Store the shared settings when `settings_at` is newer than its own. Always record `reading_schedule` (the patch owns it) and drop its own pending request once `reading_schedule_applied_at` ≥ that request's `at`. Sent at start, on a menu change and after applying a request. The sleep screen (cap `sleep_screen`, docs/design/lock-screen.md S1) adds `sleep_mode` (`off`/`recommended`/`current`), `sleep_from` (one or more, one per line: `library`/`up_next`/`want_to_read`/`discover`/`scope:<id>`/`collection:<id>`; `library` alone), `sleep_leave_out` (rules, one per line: `tag:<name>`, `scope:<id>`, `collection:<id>`, or `library` alone), `sleep_hours` (`1`/`3`/`6`/`12`/`24`), `sleep_text` (≤ 60 characters), `sleep_battery` (`1`/`0`), `sleep_style` (`bar`/`overlay`), `sleep_text_position` (`right`/`left`/`top`/`bottom`), `sleep_battery_corner` (`bottom_left`/`bottom_right`/`top_left`/`top_right`); missing ones keep their value. **Settings v2** (cap `settings2`, docs/design/companion-settings.md §4): `settings_v` = `2` and `values`, a JSON object of every key in `shared/settings/schema.json` with its own time, `{"<key>": {"v": "<wire>", "at": <ms>}}` (wire: bool `1`/`0`, numbers in decimal, rules one per line); per key, the newer `at` wins, a tie goes to the companion, an invalid value is ignored. A v2 companion ignores the flat extras when `values` is present; the plugin also sends `values` right after it takes the companion's changes (the echo that ends "Waiting for KOReader"). In Add-on mode without the service these are recorded the same way. |
| `STATS` | `seq`, `period_s`, `pages`, `full`, `partial`, `content` (`text`/`comic`/`webtoon`/`pdf`/`none`), `open` (`1`/`0`), `reading_min`, `wifi_mode`, `reading_schedule`, `reason`; plugin 0.11.1+: `reading` (`1` = a book open in front, not BookOrbit Home or a list over it; `0` on `close`/`suspend`) | Battery stats batch: store the counts with the current state; a book is "in front" while `open=1` (at most 6 min). `reading` drives the companion's reading gate (docs/design/reading-gate.md); without it, `open` and `resume`/`suspend` do. Sent every 5 min with a book open, on open/Resume/Suspend/close, never per page (docs/design/STATS-DESIGN.md). |
| `SETUP_LATER` | none | The setup box's "Later" in KOReader: the companion's own Later (quiet until an update or a step stops working). Companion 0.4.1+. |
| `RELAUNCH` | `reason` (`restart`) | The patch is quitting for a restart (COMMAND `restart`, or from 0.5.0 by itself for a newer patch file on disk, DESIGN "One update"): start KOReader again after 2.5 s. Patch 0.3.1+. |
| `REPORT` | `signed_in` (`"1"`/`"0"`), `recommended` (`none`/`partial`/`reviewed`/`applied`), `conflicts` (a count), `reason` | Companion 0.11.0+: one yes/no about the BookOrbit login and the recommended settings' state, for its Setup rows "Signed in to BookOrbit" and "Recommended settings". Never the server, the account or the key (catalog commands resolve credentials privately in the companion); other extras are ignored. Sent at start, after a recommended pass and when either value changes. Needs no service. |
| `SLEEP_REFRESH` | `reason`, `from`, `rules`, `open_id`, `every`, `storage_limit_mb`, `server`, `user`, `userkey`; or `reason`, `scopes_only=1` and the login | Cap `cache_worker`: refresh the sleep screen's pool on the worker thread (`SleepPoolBuilder`): Leave out's member lists once a day, the shuffle bag, the books checked and their covers fetched by ETag, then `pool.json`, `covers/`, `bag.lua`, `leave_out.lua` and `scopes.json` written and the picture redrawn. With `scopes_only` it writes the pickers' files only (`scopes.json`, `tags.json`), never a pool. Each refresh counts the tags again. Answers with a `sleep_pool` event. Needs no service. The login is never written or logged. |
| `SQLITE_STRESS` | `seconds` (default 120) | Debug (docs/design/sqlite-cache.md "Stress test"): writes `orbit-cache/stress.db` nonstop for that long, one 100-row page per transaction, then logs `sqlite-stress writer: …` and writes `orbit-cache/stress-writer.lua` `{writes, errors, max_wait_ms, integrity, first_error, at}`. No login, no service. |
| `SLEEP_POOL` | `reason`, `wake` | Companion cap `sleep_screen`: the files in `koreader/settings/orbit-sleep/` changed (below). The picture sink redraws `Pictures/Orbit/sleep.png`; the screen saver reads them at the next sleep. With `wake` = `"1"` (reason `wake`): KOReader resumed after a real sleep (the screen went off, not an app switch); with Every sleep the picture moves on for the next sleep, once per wake (the service's screen-on counts as the same wake). Needs no service. |
| `PATCH` | `reason`, `id` (a book id, or empty), `fields` (a Lua literal of the changed fields, or empty), `stale_home` (`"1"`/`"0"`); or `wipe` = `"1"`; `remember_id`, `plugin_state`; `old_hash`, `new_hash`, `copy_path` | Cap `cache_worker`: a write the plugin made (`Cache.writeEffect`), patched into the saved book, the lists that name it and other saved replies; Home marked stale. `wipe` empties the database. In order with the checks. `plugin_state` atomically persists the in-memory plugin state; `remember_id` persists the saved detail for the end-of-book sheet; copy identity migration updates sidecar/statistics in the worker. No login. Needs no service. |
| `STORAGE` | `reason`, `limit` (bytes, empty: none), `cover_dir`, `mirror_covers` (`"1"`/`"0"`) | Cap `cache_worker`: count everything BookSync stores (`orbit.db` and the cover folder) and, over `limit`, remove what StorageLogic says: the oldest browsing replies and plain covers first, then covers saved for offline, never lists and books saved for offline nor Home. The companion removes them itself and answers with a `storage` event. No login. Needs no service. |
| `PATCH` (0.12 library) | `library_batch` (Lua literal array of encoded neutral requests, ≤16 entries, ≤128 KiB), `owner` | Same caller-checked worker queue. No login or network. Materializes bounded results in `library_views` in the existing owned SQLite database, with owner checks before and inside publication. The plugin reads ready results through `Library`; filtering, grouping, sorting, counts and joins stay in Kotlin. See [F12-A notes](../../docs/design/booksync-home/F12-A-NOTES.md) for operations, budgets and pending/empty states. |
| `COPIES` | `reason`, `ask` (Lua literal); or `prepare` (one queued copy), `template`, `server`, `user`, `userkey` | Cap `cache_worker`: which copies on the reader changed in the library (docs/design/keep-copies-current.md), from the in-memory `ask`, persisted by the companion in `koreader/settings/orbit-cache/copies/ask.lua` (below): the newer of the end-of-book cache's, the cache's and the database's saved details per book, compared with each copy's hash, and only copies whose file is on the reader. Answers with a `copies` event; the plugin queues and downloads them. `prepare` fetches the delivery detail using the supplied template and samples the existing file hash, answering with `copy_prepared` (`path`, `detail`, `md5`, or `err`). Only preparation needs a login. Needs no service. |
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

The companion's setup row "KOReader patch answered" is ticked by any command carrying
`sender = "org.koreader.launcher"` or by the status call.

In Add-on mode (companion 0.11.0+, `docs/design/addon-mode.md` §7.1) the companion routes by
capability: an action reaches the service only when a helper keeps it running; `SETUP_LATER`,
`REPORT` and the book state from `STATS` are recorded without it; the rest are logged and
dropped. In Full every action reaches the service as before.

## The sleep screen's files (cap `sleep_screen`)

In `koreader/settings/orbit-sleep/` (docs/design/lock-screen.md). The plugin writes; the companion
only reads, except `state.json`.

| File | Written by | Holds |
|---|---|---|
| `pool.json` | companion, at a `SLEEP_REFRESH` (never at sleep) | `{v, at, source, items: [{id, title, file}], server, user, storage_limit_mb}`: the batch of up to 24 ready covers, in show order; `file` is `covers/<id>.jpg`; `server` is the plugin's `server_url` (`…/api/v1`), `user` its KOReader username (the OPDS sign-in's default), `storage_limit_mb` BookSync's storage limit (the sharp covers take at most a tenth of it, 24 MB cap) |
| `covers/<id>.jpg` | companion, at a `SLEEP_REFRESH` | the pool's covers (400 × 600 thumbnails), fetched by ETag; others pruned. The companion's sharp covers (its own storage, `files/sharp-covers/`) replace them on screen when signed in |
| `current.png`, `current.json` | plugin, when a book opens | the current book's cover and `{v, title, authors, path, id, file, at}` |
| `state.json` | companion | `{v, shown, changed_at, shows: {"<id>": n}}`: the cover shown, when it changed, and with Every sleep how often each ready cover was shown; the shuffle bag moves past `shown` (hours) and the refresh retires covers shown 3 times (Every sleep) |
| `tags.json` | companion, at a `SLEEP_REFRESH` | `{v, at, details, tags: [{tag, label, count}]}`: the tags in the saved book details, most used first, for Leave out's tag picker |
| `scopes.json` | companion, at a `SLEEP_REFRESH` | `{v, at, scopes: [{id, title, count}], collections: [...]}`: every smart scope and collection, for the pickers |
| `bag.lua`, `leave_out.lua` | companion, at a `SLEEP_REFRESH` | private (the plugin reads `leave_out.lua` for a rule's book count): the shuffle bag and the daily Leave-out members |
| `vendor-screensaver.txt` | `tools/install-usb.sh --sleep-screen on` | the three screen-saver values it replaced, for `off` |

`GET /status` and the status file carry the sleep keys in `settings` and
`"sleep": {"shown_by": "…", "sink": "dream"|"picture"}`.

`koreader/settings/orbit-recommended.json` (plugin, at every `REPORT`): `{v, at, items: [{id, label,
state, yours, orbit, was, reason}]}`, the Recommended settings review list for the companion. Its
choices come back as the shared setting `recommended_choice` (`id=ours;id2=mine;all=undo`), which the
plugin applies and then clears.

## The cache worker's files (cap `cache_worker`)

In `koreader/settings/orbit-cache/` (docs/design/companion-worker.md, docs/design/sqlite-cache.md).
What is saved is one SQLite database, `orbit.db` (schema: `shared/fixtures/cache/schema.sql`,
`PRAGMA user_version` 1; rollback journal), which only the companion writes and the plugin opens
read-only. The small files beside it are Lua literals in the cache's format (`Cache.encode`;
`LuaValue.kt` reads and writes the same), written to a temp file and renamed. None holds the login.

| File | Written by | Holds |
|---|---|---|
| `orbit.db`, `.nomedia` | companion | lists by position naming books by id, each book once (its list item, detail and search text), other replies by key, the covers kept, the Full refresh's jobs, `meta` (owner, detail template, storage totals, the run's %) |
| `plugin-state.lua` | companion, from `PATCH.plugin_state` | the detail variant it reads and the copies queue |
| `events/<n>.lua` | companion (private spool; never enumerated by the plugin) | a check's answer: `{kind = "checked", key, changed, at}`, `{…, unchanged, saved}` or `{…, err}`; a sleep pool refresh: `{kind = "sleep_pool", why, items, kept, probed, left_out, unknown, skipped, carried, retired, every, fallback, listed, scopes}` (or `scopes_only`, or `err`); a copies lookup: `{kind = "copies", why, checked, found = {{md5, path, book_id, file_id, why}}, gone}`; a storage count: `{kind = "storage", why, totals, removed = {cache, cover, mirror_cover}, used, after, limit}` |
| `copies/ask.lua` | companion, from each `COPIES.ask` | `books` (`md5`, `path`, `book_id`, `file_id`, `incompatible`), `eob` (book id -> `files`, `saved_at`), `owner`, `server`, `detail_template`, `sentinel` |
| covers, in the plugin's thumbnail folder | companion | `<memoKey>.jpg` and `.etag`, as the plugin names them |

W27 startup maintenance uses `PATCH` variants on the same required worker:

- `drain_events="1"`, `events_ack=<id>` acknowledges `events-batch.lua`. The worker removes
  only that batch's spool files and atomically publishes the next batch (at most eight events,
  under 64 KiB). The plugin reads one fixed filename; duplicate ids are ignored. Child-process
  metadata travels with the subprocess result, with no directory spool or UI scan.
- `old_hash`, `new_hash` copies a hash sidecar on the worker. Only two 32-character lowercase
  hex hashes are accepted; paths derive from KOReader's fixed `hashdocsettings` folder.
- `board_year` (Lua literal), `board_key`, `board_now` computes the dashboard calendar and reads
  local daily statistics on the worker; a `board_year` event returns `{key, data={values,start,today}}`.
  The UI uses the last snapshot while the next one is pending.

`STORAGE` owns orphan ETag cleanup and cover eviction. Startup and upstream thumbnail
maintenance only request it. Storage labels use the last worker answer, without opening SQLite.

The plugin needs the companion of its own version for any of this (`Companion.workerProblem`):
otherwise it shows "BookSync Companion needed" or "Update BookSync Companion" and sends nothing.

## Patch → companion: activities

Started with `Context.startActivity`, `setPackage(...)` and `FLAG_ACTIVITY_NEW_TASK`. The
activity needs an intent filter with the action and `android.intent.category.DEFAULT`.

| Action | Opens |
|---|---|
| `net.fledgewing.orbitcompanion.action.SHOW_STATUS` | Companion status (mockup screen 3) |
| `net.fledgewing.orbitcompanion.action.SHOW_APPS` | The launcher's apps page (mockup screen 2) |
| `net.fledgewing.orbitcompanion.action.SHOW_SETUP` | The "Setup needs you" prompt (the setup box's "Fix now"). Companion 0.4.1+; the patch falls back to `SHOW_STATUS`. |
| `net.fledgewing.orbitcompanion.action.SHOW_PIN` | The Settings PIN keypad (companion 0.4.4+). The patch's BookSync menu asks for it while `/status` says `pin_locked: true`; it closes at once when no PIN is set or it's already unlocked. The unlock state comes back through `/status`. |
| `net.fledgewing.orbitcompanion.action.RELAUNCH_UI` | Companion 0.11.0+, Add-on only: an invisible window the plugin starts just before it quits for a restart; it starts KOReader again 2.5 s later (no Home role to do it from the background). |
| `net.fledgewing.orbitcompanion.action.SHOW_LAUNCHER` | The launcher page (the one a double Home shows); Home pressed on BookOrbit home. Companions before 0.2.1 lack it; the patch then opens `SHOW_APPS`. |
| `net.fledgewing.orbitcompanion.action.SHOW_SLEEP` | Settings › Sleep screen (cap `sleep_screen`), behind the Settings PIN: the BookSync menu's "Shown by" row. |
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

**Every command is confirmed.** Any app can start KOReader with this extra, so the plugin obeys a
`COMMAND` only after the companion confirms it sent it: the caller-checked call with method
`net.fledgewing.orbitcompanion.call.TAKE_COMMAND` and the extra `command`. The companion
answers `ok = "1"` once for a command it put on KOReader's start in the last 10 minutes
(`SentCommands`), else `"0"`, and the plugin then ignores the command. The companion puts a
command only on the pinned KOReader's start (docs/design/security.md). Over USB,
`tools/sideload-android.sh` asks for the restart with `adb shell content call --uri
content://net.fledgewing.orbitcompanion.commands --method
net.fledgewing.orbitcompanion.call.RESTART_KOREADER`, a method only the shell UID may call.

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

## Companion status: the status call

The same caller-checked call with method `net.fledgewing.orbitcompanion.call.STATUS` and the
extras `patch_version` (which plugin is running) and `book` (`"1"`/`"0"`: a book is open, so the
companion's restart after a plugin install waits for it). It answers `ok = "1"` and `status`, a
JSON string, while the companion's service runs; otherwise `ok = "0"` and the plugin reads the
status file. For example:

```json
{ "proto": "1", "version": "0.2.0", "wifi": true, "wifi_enabled": true, "wifi_owner": "auto",
  "tailscale": true, "screen_off_permission": true,
  "settings": { "wifi_mode": "jit", "wifi_idle_min": 2, "home_button": "smart", "settings_at": 0 } }
```

`settings` are the shared settings (above); with cap `settings2` they also carry `values` (settings v2,
above), and the top level carries `want_choices` (ms: the sleep screen's picker is open; when it is
newer than the last request it answered, the plugin sends `SLEEP_REFRESH scopes_only=1` with the
login, and the worker writes fresh `scopes.json` and `tags.json`). The status file carries
both too. The patch reads them on start, resume and when its
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
`settings.home_opens` (v0.4.8): the companion's "Home opens", `koreader`, `launcher` (the BookSync
launcher page) or `app`; the patch notes it on its Home button menu entry.
`pin_locked` (v0.4.4): a Settings PIN is set and not unlocked right now. Then the patch's BookSync
menu shows only "Enter the Settings PIN…" and starts `SHOW_PIN`. Only a real `true` locks:
no answer (no companion, not running) leaves the menu usable, so the
patch never locks anyone out.

### `GET /clicks` (companion 0.4.2+): the click channel

The plugin first asks for a key: the caller-checked call with method
`net.fledgewing.orbitcompanion.call.CLICKS` answers `key` and `proof` (random, 128 bits each, good
once within a minute). It then opens `GET /clicks?patch_version=X&key=K` on the loopback port
47913 (the only request the port answers; without a valid key it answers 404) and keeps it open.
After an HTTP 200 header, the companion's first line is `ORBIT <proof>`; the plugin ignores every
line before it and closes a channel whose proof is wrong or missing, so another app listening on
the port can't pose as the companion. Then one line per event:
- `SERVICE on|off`: the accessibility service is running, or isn't.
- `SETTINGS <ms>` (cap `settings2`): a setting changed in the companion; the plugin reads `/status`
  now. The plugin keeps the channel open for this even without a clicker.
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

`mode` is `full` or `addon`. Caps: `install`, `setup`, `stats`, `relaunch` (always), `sleep_screen`, `cache_worker` (always); `home`,
`apps` (Full); `wifi`, `sleep_sync`, `screen_off`, `clicker`, `pin` (Full, or Add-on with that
helper on; `screen_off` also needs the lock-screen permission). The plugin reads `/status` first,
then the file, then the caps seen last time. With none of those available it offers no capabilities.
A file left behind by an uninstalled or frozen companion is ignored. The plugin logs
`companion: mode … caps … (from status|file|cache|none, why)`.

COMMANDs added in 0.11.0 (the same extra as `home`): `signin` opens BookOrbit's own sign-in
(`promptLogin`), `recommended` opens the plugin's Recommended settings page. After 0.11.2 (the
companion's Settings "Do now" buttons): `full_refresh` (Full refresh of BookOrbit), `sync_sleep`
(Sync and sleep now), `test_sync_path` (Test sync path).

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
- "Open BookSync Companion" and "Open another app…" say the companion isn't installed.

## How the patch calls the companion

KOReader's Android JNI bridge (android-luajit-launcher `assets/android.lua`) exposes
`JNI:context(vm, fn)` (`android.lua:1400-1416`), which attaches the thread and hands over the
raw `JNIEnv`. With it the patch calls framework classes directly: for a command or the status,
`new Bundle()`, `putString`, `Uri.parse` and `ContentResolver.call`; for a page of the companion,
`new Intent(action)`, `setPackage`, `addFlags` and `activity.startActivity`; for the companion's
signer, `PackageManager.getPackageInfo` (`signingInfo`, or `signatures` before Android 9),
`MessageDigest` SHA-256. It also reads
`PowerManager.isInteractive()` (is the screen really off?) and
`ConnectivityManager`/`NetworkCapabilities.hasTransport(TRANSPORT_VPN)` (is Tailscale up?).
Each call checks for a pending Java exception and clears it, so a bad call is logged rather
than aborting KOReader.

Not `android.openLink` (`android.lua:2497`, `MainActivity.kt:631-641`): it only starts an
`ACTION_VIEW` activity, which brings another app to the front and pauses KOReader (a
Suspend). The patch cannot register a broadcast receiver (that needs a Java class), so
answers come back through the call's answer, the launch intent and the companion's files.

## Security

The threat model, the caller check and what remains are in docs/design/security.md. In short:
only the pinned KOReader reaches the companion's commands (`CommandProvider`); the plugin sends
nothing, the login least of all, to a companion not signed by BookSync's release certificate; a
command that names a file acts only inside the companion's own folders (`Places`); a command on
KOReader's start goes only to the pinned KOReader.

`RESET_PIN` (companion 0.4.4+, `net.fledgewing.orbitcompanion.action.RESET_PIN`) is not a
patch broadcast: it removes the Settings PIN and is for USB recovery only. Its receiver
(`.PinResetReceiver`) requires `android.permission.DUMP`, which only the shell (adb) holds,
and on Android 14+ refuses a sender uid other than shell or root when Android reports one.

STORAGE may carry `shown` (newline-separated visible cover paths, bounded by the
companion to 100). That form queues timestamp/thumbnail work only; it does not
request a storage sweep. Mirror plans also carry `cover_width`, `cover_height`
(the device's grid cell bounds in pixels) for browsing JPEGs. Sleep covers keep
their separate full-screen dimensions.

The mailbox has one KOReader poll, shared by all callers. Each batch is applied once;
acknowledgements of an unchanged batch retry at ten-second intervals. Over-limit storage
counts coalesce and run at most once per minute. The limit counts live SQLite pages and
covers; reusable pages and the transient rollback journal do not count. A storage check
reclaims substantial free space and reports protected data that cannot be reduced. A
complete bulk generation retires the old list-crawl tables. Downloaded book files are
outside storage accounting and eviction.

Copy preparation uses the cached delivery preference without fetching it on the UI thread
(BookOrbit `c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7`,
`koreader-plugin/bookorbit.koplugin/bookorbit_delivery.lua:33`). Home enters Trapper before
calling catalog actions: upstream `bookorbit_catalog.lua:884` runs fetches synchronously
when called outside Trapper. Partial MD5 sampling matches KOReader
`9192014d8bd82a91dc1012473be0f238dedfdb54`, `frontend/util.lua:1111`.

Statistics migration preserves KOReader Android's WAL journal mode (`frontend/device/generic/device.lua:131` and
`plugins/statistics.koplugin/main.lua:455` at the KOReader pin above); the BookSync cache stays in TRUNCATE mode.

`native_footer_repair` mailbox events carry string scalar literals `before`, `after`,
and a stable `token` for the backup-based global `reader_footer_mode` repair. The
plugin changes only a matching native global setting in memory, never the loaded
footer or document, and persists the token to ignore replay after later user changes.

F12-E extends that same library batch with `{op="battery",limit=1}`. It returns one local-device snapshot: `level`, `charging`, `screen_on`/`standby`/`charging_rate` (`pct_per_hour`, `standard_error`, `hours_measured`, `missing`), `usual_use` (`screen_on_percent`, `window_days`, `hours_observed`), `hours_usual_use`, `hours_reading_nonstop`, `hours_standby_only`, up to 14 `pct_used_per_day` entries, five `recent_charges` and three `modes` (`id`, `wifi_pattern`, `estimated`, `reason`, `hours_usual_use`). Unmeasured values are absent. Times in charges/freshness are epoch milliseconds; durations are hours. Rates, standard errors and blends are computed only in the companion; caller budgets, the existing batch, cache ownership and 16 KiB ceiling apply. See [F12-E notes](../../docs/design/booksync-home/F12-E-NOTES.md).

The existing Settings projection is also available as `Library:modeEstimates()` / `{op="mode-estimates",limit=3}`. It draws from the same model, returning up to three `items` with the existing IDs `saver`, `balanced`, `current`, ready-to-draw UTF-8 `text`, `measured`, `estimated`, `hours_usual_use` and `reason`. It respects a smaller caller row limit. No-history rows retain the honest unavailable line; unmeasured Wi-Fi patterns carry an explicit estimate marker in the text.

### 0.12 reader progress projections (F12-H)

The existing `library_batch` command also accepts `reader` (local `path`, one
normalized book row; optional `native_progress` is the native reader's cached
0–1 fraction, validated and projected by the companion without changing the
saved catalog position) and `battery` (the measured local snapshot described above;
time-left fields remain absent until its evidence thresholds are met). The `book` and `reader` rows include `stats` with
`available`, optional `pages_read`, `reading_seconds`, and inclusive
`days_start_to_finish`. Joins and SQLite aggregation run in the companion;
no metadata file or statistics database is parsed by the reader UI. The
`progress.syncCurrent` capability advertises the existing explicit Sync action
behind the library adapter, with no new sync writer. See
[reader progress notes](../../docs/design/booksync-home/F12-H-NOTES.md).

The owned Home host also uses `lists(limit)` on the library context. Its materialized
rows contain opaque `key`, display `title` and cached `count`; incomplete membership
is “Not saved yet”. Book windows may include `local_path` from the owner-scoped,
worker-checked file ledger. The plugin opens only that local file through
`Library.open`; no widget resolves identities or performs a download. A changed
publication emits `library`; catalog publication emits `library_source`. These reuse
the acknowledged event queue. They invalidate an already visible Home, never show it.

### Owned cover acquisition (0.12 catalog prerequisite)

The trusted `SERVER_COMMAND` operation `covers.acquire` accepts either one opaque
`key` or one `reference` naming an installed local cover-cache entry together with
its opaque originating `owner`, with optional `refresh=true` for explicit revalidation. A reference is validated and translated
only inside the companion adapter; it never carries a server locator or login.
It returns a small result with `local_path` and `stale`, or a neutral error. The
companion resolves account identity and performs acquisition on its existing cache
writer. No destination, credentials, HTTP options or server locator is accepted.
The library `cover` read-model operation returns one saved local reference within
the caller's screen/widget budget. Reading it performs no network or subprocess
work; the normal host batch publishes the snapshot.

Legacy thumbnail batches, author portraits and forced refresh now use this operation
from the parent process. `Library.cachedCover(reference)` reads the one-row
`cover.reference` projection with zero companion round-trips; acquisition publishes
that row on the existing writer. Existing cache hits are imported by the companion
without a network request. The old credential-bearing `RECHECK` broadcast is removed.
Callbacks reject departed generations/accounts and never redraw during reading.
See `docs/design/booksync-home/F12-Q2-NOTES.md` for the remaining catalog cutover.


### Companion-owned catalog control (0.12, F12-Q2 step 3)

`SERVER_COMMAND` operation `catalog.control` accepts `{owner, action, manual}`. `owner`
is the opaque originating namespace; actions are `full`, `refresh`, `resume`,
`incremental`, `covers`, and `stop`. The selected server adapter resolves the captured
account and queues work on the existing cache writer. No endpoint, protocol query,
server locator, credentials or serialized plan crosses from Lua. The command returns
a bounded neutral acknowledgement/status, or a neutral error. A second Full refresh
keeps a running full run; paused bulk work resumes its cursor. Incremental probes
are throttled and storage-blocked runs wait for a larger limit or an explicit action.
Refresh bootstraps an unsaved catalog; otherwise it revalidates the saved generation.

`catalog.state` is a one-row, at most 16 KiB `LibraryReadModel` snapshot. Progress is
published by the writer; plugin progress polling performs **zero** companion
round-trips, network calls or subprocess spawns. Checkpoint/summary/stop files under
`mirror/` are private companion implementation details, never a plugin IPC channel.
An existing checkpoint is retained only with its matching private plan owner.
Ownership transfer waits for an active refresh to stop; lifecycle/position and
copy/finish queues are retained. The old `MIRROR` and `CHECK` broadcasts are removed.

The native connector's catalog/root/Home renderers use neutral `connector.catalog`,
`connector.root` and `connector.home` display snapshots through `ko/library.lua`.
The existing companion `CacheStore`/`BulkCatalog` performs selection, sorting,
counts and offline search. Each window returns at most 24 rows and 16 KiB; Home
counts nested books/names and its stats row, and materializes one batched request.
The Lua connector translates display records into its existing widget inputs;
it never receives backend response JSON. Cached windows open offline without asking
to connect. New materializations redraw only their still-visible initiating view.
Remaining grouping, copies, recommendations and end-of-book transport are separate
follow-up slices. No replacement sync/lifecycle writer is enabled here.

# Companion settings: every setting in the companion, one definition, grouped and searchable

ROADMAP 14. Android (BookSync Companion and the BookSync KOReader plugin). Status: **building** (approved).
Part 1: the schema and per-key sync. Part 2: the companion's sections. Part 3: the KOReader menu.
Mockups: `settings.html` (the design page that goes with the design PR).

`P/` = `android/koreader/orbit.koplugin/`, `C/` = `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/`.
Line numbers are at `4a57fc2` (main).

## 1. Outcome

The user changes BookSync from the **companion** and never needs KOReader's menus. Every setting the
BookSync plugin has is in the companion, a change in either place reaches the other, and a change made
while KOReader isn't running waits and applies at its next start. The companion's Settings page is
short: eight sections with a one-line summary each, a search, and rows that appear only when they
apply. KOReader's BookSync menu keeps its settings, grouped the same way.

The user's words: "I expect them all to be available in the companion too and apply the same
settings"; "the companion should have all the settings (KOReader plugin should have its settings
too, but I primarily interact via the companion)"; "it's getting a bit crowded and clunky".

## 2. What is there today (verified)

- **The plugin** keeps its settings in `G_reader_settings["orbit_android"]` (`P/ko/settings.lua:9-63`)
  and shows them in one flat menu, Tools › BookSync, of about 30 rows (`P/ko/menu.lua:214-289`).
  A toggle logs `setting <key> = <value>` (`P/ko/menu.lua:17`); that is the "setting sync_on_sleep =
  true" line in the logs.
- **Shared settings** exist for 13 keys: Wi-Fi mode, idle minutes, the Home button and the nine
  sleep-screen keys. Each side keeps a copy; the plugin pushes with the `SETTINGS` broadcast
  (`P/ko/shared.lua:139-162`, `android/docs/INTERFACE.md:27`), the companion answers in `/status`
  `settings` (`C/OrbitService.kt:627-650`) and in the status file for Add-on without the service
  (`C/StatusFile.kt:26-27`). **One timestamp, `settings_at`, covers the whole set**: the newer set
  wins as a block (`C/OrbitService.kt:424-431`, `P/ko/shared.lua:82-101`).
- **Sync while reading** is plugin-owned and uses a request instead: the companion puts
  `reading_schedule_request {id, at}` in `/status`, the plugin applies it at start, resume or menu
  open and acknowledges with `reading_schedule_applied_at` (`C/Logic.kt:444-472`,
  `P/ko/shared.lua:62-70`, `C/OrbitService.kt:413-422`). The companion shows "applies when KOReader
  opens" until then (`C/Pages.kt:375-378`). This is the only "queued until KOReader starts" path.
- **The sleep screen page** in the companion shows Pick from, Leave out and Text read-only, with
  "set in KOReader" (`C/SleepPages.kt:41-45`): the scope and collection lists and the tags live in
  the plugin's cache (`P/ko/sleepscreen.lua:390-434`), so the companion has nothing to pick from.
- **The companion's Settings page** (`C/Pages.kt:293-447`) is one scrolling list: Mode, Add-on
  helpers, three segmented controls with their own headings (Wi-Fi after sleep sync, Wi-Fi, Just in
  time), Sync while reading, Home opens, the Home button segmented control, Sleep screen, Clicker
  buttons, six toggles, Check for updates, skipped steps, three PIN rows and Licenses. On an M8C it is
  about three screens, with no grouping: update toggles sit next to Tailscale and the debug log.
- **The Settings PIN**: companion pages are `pinGuarded` (`C/Pages.kt:266`, `C/SleepPages.kt:19`);
  the plugin's menu shows only "Enter the Settings PIN…" while `/status` says `pin_locked`
  (`P/ko/menu.lua:313-314`, `P/logic/prompts.lua:38-41`). No answer means unlocked, so the plugin
  never locks anyone out.
- **COMMAND** on KOReader's launch intent already carries `home`, `home_smart`, `restart`,
  `reopen_book`, `signin` and `recommended` (`C/Core.kt:587-630`, `P/ko/home.lua:30-34`), gated by
  plugin version (`PluginCommands`, `C/Logic.kt:549`).

## 3. Inventory: every plugin setting and its companion equivalent

"Read by" is the code that acts on the value. **Gap** = not settable in the companion today.

### 3.1 Settings

| # | Key | Default | Meaning | Plugin UI today (Tools › BookSync) | Read by | Companion today | |
|---|---|---|---|---|---|---|---|
| 1 | `wifi_mode` | Just in time with a companion that switches Wi-Fi, else Always on | When Wi-Fi is on | Wi-Fi: … › radio | companion (switching), plugin (`Shared.mode`) | Settings › Wi-Fi (segmented) | ok |
| 2 | `wifi_idle_min` | 2 | Just in time: minutes idle before Wi-Fi goes off | Wi-Fi › Just in time › radio | companion | Settings › Just in time (segmented) | ok |
| 3 | `home_button` | `smart` | Home in KOReader: back to my book, then BookOrbit home; or BookOrbit home | In KOReader, Home goes to › radio | plugin (`HomePlan`) | Settings › Home button | ok |
| 4 | `reading_schedule` | `off` | Sync while reading: every N min, pages or chapters | Sync while reading › radio | plugin | Settings › Sync while reading (request) | ok |
| 5 | `sleep_mode` | `off` | Sleep screen: the reader's own, Recommended cover, Current book | Sleep screen › Sleep screen | companion (sink), plugin (pool) | Sleep screen page | ok |
| 6 | `sleep_from` | `up_next` | Pick from: Up next, Want to read, Discover, a smart scope or collection | Sleep screen › Pick from › radio + picker | plugin (pool) | read-only, "set in KOReader" | **gap** |
| 7 | `sleep_leave_out` | none | Leave out rules: tag, smart scope or collection | Sleep screen › Leave out › list, add, remove | plugin (pool) | read-only count | **gap** |
| 8 | `sleep_hours` | 6 | Change cover every 1/3/6/12/24 h | Sleep screen › Change cover every | companion (rotation) | Sleep screen page | ok |
| 9 | `sleep_text` | empty | Text on the sleep screen, ≤ 60 characters | Sleep screen › Text (KOReader input) | companion (draws) | read-only, "set in KOReader" | **gap** |
| 10 | `sleep_battery` | off | Battery level at sleep | Sleep screen › Show battery level | companion | Sleep screen page | ok |
| 11 | `sleep_style` | `bar` | Bar or Overlay | Sleep screen › Style | companion | Sleep screen page | ok |
| 12 | `sleep_text_position` | `right` | Overlay: text on the right, left, top or bottom | Sleep screen › Text position | companion | Sleep screen page | ok |
| 13 | `sleep_battery_corner` | `bottom_left` | Overlay: battery corner | Sleep screen › Battery corner | companion | Sleep screen page | ok |
| 14 | `wifi_via_companion` | on | Ask the companion to turn Wi-Fi on for a sync | Wi-Fi via BookSync Companion | plugin (`P/ko/companion.lua:200`, `P/ko/net.lua:49`) | none | **gap** |
| 15 | `wake_tailscale` | on | Wake Tailscale before syncing | Wake Tailscale before syncing | plugin (`P/ko/net.lua:61`), sent as `NET_UP tailscale` | none (the companion's own "Wake Tailscale with Wi-Fi" is the other half) | **gap** |
| 16 | `sync_on_wake` | on | Sync every time the reader wakes | Always sync on wake | plugin (`P/ko/start.lua:34`) | none | **gap** |
| 17 | `sync_on_sleep` | on | Sync when the screen goes off | Sync when the screen goes off | plugin (`P/ko/sleep.lua:37`) | none | **gap** |
| 18 | `sleep_cap` | 20 s | Longest a sleep sync may take (10/15/20 s) | Sleep sync limit | plugin (`P/ko/sleep.lua:91`) | named in a subtitle only | **gap** |
| 19 | `eob_sheet` | on | BookSync's end-of-book sheet for BookOrbit books | End of book: BookSync's sheet… | plugin (`P/ko/endofbook.lua:221`) | none | **gap** |
| 20 | `eob_auto` | on | Reaching the end marks the book finished | End of book: mark it finished | plugin (`P/ko/endofbook.lua:224`) | none | **gap** |
| 21 | `local_first` | on | Home shows this reader's reading first (restart) | Home shows this device's reading first | plugin (`P/ko/localfirst.lua:660`) | none | **gap** |
| 22 | `offline_cache` | on | BookOrbit opens from BookSync's cache (restart) | BookOrbit opens from BookSync's cache | plugin (`P/ko/cache.lua:24`) | none | **gap** |
| 23 | `mirror_auto` + `mirror_ttl_days` | on, 7 | Automatic Full refresh every 1/3/7/14/30 days, or only by hand | Automatic Full refresh › radio | plugin (`P/ko/mirror.lua:562-566`) | none | **gap** |
| 24 | `mirror_covers` | off | Save every cover for offline | Save every cover for offline | plugin (`P/ko/mirror.lua:335`) | none | **gap** |
| 25 | `storage_limit_mb` | 250 | One limit on everything BookSync stores | Storage limit › radio | plugin (`P/ko/cache.lua:645`) | none | **gap** |
| 26 | `keep_copies_current` | on | Re-download a book whose library file changed | Keep book copies current | plugin (`P/ko/copies.lua:77`) | none | **gap** |
| 27 | `key_log` | on | Log every key (clicker diagnosis) | Log every key | plugin (`P/ko/keys.lua:29`) | none | **gap** |
| 28 | `auto_update_patch` | on | Plugin updates itself | Auto-update patch | plugin (`P/ko/background.lua:98`) | none (the app's own "Auto-update app" is separate) | **gap** |
| 29 | `patch_update_prerelease` | off | Plugin takes pre-releases | Include pre-releases | plugin (`P/ko/updater.lua:163`) | none (the app's own toggle is separate) | **gap** |

### 3.2 Actions and status lines in the plugin menu

| # | Item | Companion today | |
|---|---|---|---|
| A1 | Recommended settings (the review page) | Setup row "Review" starts KOReader on the page (`COMMAND=recommended`) | **gap**: only inside KOReader |
| A2 | Full refresh of BookOrbit | none | **gap** |
| A3 | "Saved for offline · time" and storage used | none | **gap** |
| A4 | Sync and sleep now | only as a clicker action | **gap** |
| A5 | Test sync path | none (Setup's Wi-Fi off/on test is a different test) | **gap** |
| A6 | Check for patch update, its status | covered: the app's update carries the plugin (`C/Updater.kt:440`) | ok |
| A7 | Shown by, Preview | Sleep screen page | ok |
| A8 | Open BookSync Companion, Open another app… | n/a: navigation into the companion | plugin-only |
| A9 | Status line (companion, Wi-Fi, last sleep sync, setup count) | status page, partly | ok (Details gets the rest) |

**Gaps: 24** — 16 settings with no companion row (14-29), 3 shown read-only (6, 7, 9), and 5 actions
(A1-A5). 10 settings are already shared.

### 3.3 Not settings

These `S` keys are state, never shown as settings: `last_sleep_sync`, `shared_settings_at`,
`patch_update_checked_at`, `patch_update_status`, `patch_update_failed_at`, `open_book_at_exit`,
`restart_screen`, `restart_book`, `restart_tried`, `home_book`, `saved_pages_before_update`,
`sleep_current_file`, `reading_schedule_request_at`, `recommended`, `recommended_backup`,
`companion_caps`, `companion_mode`, `orbit_on_device`, `setup_prompt_shown`, `screen_off_hint_shown`,
`refresh_tip_shown`.

### 3.4 Companion-only settings (stay companion-only)

Mode and the Add-on helpers, Wi-Fi after sleep sync, Wake Tailscale with Wi-Fi, Wake lock while
syncing, Notify if Tailscale won't connect, Debug log, Auto-update app, Include pre-releases, Home
opens, Clicker buttons, Settings PIN and Guarded apps, Reading fonts (Setup's optional row) and
Skipped setup steps (`C/Core.kt:82-297`, `C/Pages.kt:293-447`). They act on Android, not on KOReader,
so the plugin doesn't need them; its menu says "Buttons, PIN and setup: in BookSync Companion ›".

## 4. One source of truth and the sync protocol

### 4.1 One definition: the settings schema

A new file, `shared/settings/schema.json`, defines every shared setting once: key, type (`bool`,
`choice`, `int`, `text`, `rules`, `source`), allowed values with their labels, default, section,
label, one-line explanation, search words, **parent** (show only when another setting has a value),
**applies** (`now`, `next_sync`, `restart`), the cap it needs (`wifi`, `sleep_screen`, …) and who
reads it. The plugin's package carries a copy (`package.sh`); the companion's build copies it into
its assets. Both draw their rows from it, and both normalise incoming values with it (today's
`SleepPool.normalize`, `P/logic/sleep_pool.lua:122-137`, and `SleepSettings.merge`,
`C/SleepScreen.kt:41-44`, become one generic check). A test on each side fails when its copy differs
from `shared/settings/schema.json` or when a plugin setting in `DEFAULTS` is neither in the schema
nor on the §3.3 list.

### 4.2 Where values live

**Both sides keep a copy of every shared value, with the time it last changed, per key.** The plugin
keeps its copy in `orbit_android` (what its code already reads, unchanged); the companion keeps its
copy in one generic store keyed by the schema (`SettingsStore`, SharedPreferences `orbit_settings`).
Neither is a "master": the newest change to a key wins. Both run on the same device clock, so the
times compare. A key never set reads as the schema's default on both sides, so the schema is the
one place defaults live.

Before 2026-11 the companion kept `wifi_mode`, `wifi_idle_min` and `home_button` in `Prefs` and the
sleep screen's keys in `orbit_sleep`. `SettingsStore.migrate` moves them into `orbit_settings` once,
before the first read: a value the schema accepts is kept. It commits every replacement and the
migration marker before deleting any old key. A failed destination write leaves the old values for
a later attempt; an interruption during cleanup leaves the committed replacements intact. A companion
downgraded past this change finds those keys at their defaults. `reading_schedule` stays apart: its
value is the plugin's, and the companion's change is a request until the plugin echoes it.

### 4.3 The wire (extends what exists; nothing new to carry it)

| Direction | Carrier (existing) | Today | Adds |
|---|---|---|---|
| plugin → companion | `SETTINGS` broadcast (`P/ko/shared.lua:139-154`) | flat extras + one `settings_at` | `settings_v = "2"` and `values`: JSON `{"<key>": {"v": …, "at": <ms>}, …}` for every schema key |
| companion → plugin | `/status` `settings` (`C/OrbitService.kt:644-650`), and the status file in Add-on (`C/StatusFile.kt:26-27`) | 13 keys + `settings_at` | `settings.values`, the same JSON |
| companion → plugin, "look now" | the `/clicks` channel (`android/docs/INTERFACE.md:240-252`) | `SERVICE`, `CLICK` lines | a `SETTINGS <at>` line; the plugin runs `Shared.refresh("channel")` |
| companion → plugin, actions | `COMMAND` on the launch intent (`C/Core.kt:587-630`) | `restart`, `recommended`, … | `full_refresh`, `sync_sleep`, `test_sync_path` (A2, A4, A5), gated by `PluginCommands` |
| plugin → companion, lists | files in `koreader/settings/orbit-sleep/` + `SLEEP_POOL` (`INTERFACE.md:32`, `:57-69`) | pool, covers, current | `want_choices` → `SLEEP_REFRESH scopes_only=1` (§6.2) |
| plugin → companion, review | a file beside the status file | `REPORT` counts only | `koreader/settings/orbit-recommended.json` (A1, §5.8) |

The flat extras and `settings_at` stay one release for older peers; a v2 reader ignores them when
`values` is present.

### 4.4 Merging

Per key: take the incoming value when its `at` is newer than ours and the schema accepts it; an
invalid value is logged and ignored, never replaced by the default. Equal times: the companion's value
wins (deterministic, and it is where the user works). A time more than a day in the future is treated
as now, so a clock that jumped back can't freeze a key. Every taken change logs one line in today's
form, `setting <key> = <value> (from the companion, was …)` in the plugin and `settings: <key> = …
(from KOReader)` in the companion. `Shared.applySleep` (`P/ko/shared.lua:107-126`) becomes the generic
`Shared.apply`, and its "big change" hook (`Sleep.changed`) becomes a per-key `on_change` in the
schema's reader.

### 4.5 Timing: how a change reaches the other side

- **Changed in the companion, KOReader running:** the companion writes the value, then a
  `SETTINGS <at>` line on `/clicks` if the channel is up. The plugin pulls `/status` and applies.
  Otherwise it applies at the next resume (`P/ko/start.lua:22`), which is when the user goes back
  from the companion to KOReader anyway, or at the next menu open.
- **Changed in the companion, KOReader not running:** stored with its `at`. The plugin applies it at
  start (`P/ko/module.lua:42`), before the start sync reads `sync_on_wake`, then pushes `SETTINGS`
  back. Until that push reports the key at the same `at`, the companion shows the row as
  **Waiting for KOReader · applies when it next opens** (the glyph of the checklist's Checking state).
  This generalises today's Sync while reading request, which becomes an ordinary shared key.
- **Changed in KOReader:** `Shared.set` pushes at once (`P/ko/shared.lua:156-162`); in Add-on without
  the service the companion records it without starting anything (`C/OrbitService.kt:61`, extended
  from the sleep keys to every key).
- **Restart settings** (`local_first`, `offline_cache`): the row says "Applies when KOReader restarts"
  and the companion restarts KOReader at the next screen-off, never with a book in front, as Reading
  fonts does ([reading-fonts](reading-fonts.md) §4).

### 4.6 Conflicts

Both sides changed the same key before they met: the later change wins. The losing side's row then
shows, once, "Changed in KOReader at 14:02" (or "in the companion"), until the next visit to that
section. Different keys never conflict (that is what per-key times fix: today a Wi-Fi change in
KOReader and a sleep change in the companion, made while they can't talk, lose one of the two).

### 4.7 The Settings PIN in both places

Unchanged rule, both UIs: the plugin menu stays locked while the companion says `pin_locked`
(`P/ko/menu.lua:313-314`); every companion settings page stays `pinGuarded`. A change that arrives
through the channel was made behind one of those two locks, so it is applied without asking again.
New: the companion's Settings opens **read-only** while locked (values and summaries, no controls,
one **Unlock** button), as Setup already does ([companion-checklist](companion-checklist.md) §3.9).
The plugin's menu does the same: while locked it shows the whole menu with every control disabled
(submenus still open, so every value can be read), under a first row that opens the keypad.

### 4.8 Plugin-only

Only two menu entries stay plugin-only, and neither is a setting: **Open BookSync Companion** and **Open
another app…**, which open the companion from KOReader. Everything else in §3 is in the companion,
including the Recommended settings review (A1, §5.8).

## 5. Settings information architecture (companion)

### 5.1 The top page

Header "Settings", a **Search** box, then eight section rows, each a noun with its current state in
one line, and **›**. Then a footer: "BookSync 0.12.0 · plugin 0.12.0".

| Section | Summary line (examples) | Holds |
|---|---|---|
| **Reading and Home** | Home: back to my book · end-of-book sheet on | Home opens, Home button in KOReader, Home shows this reader's reading first, End of book: BookSync's sheet, mark finished, Reading fonts |
| **Sleep screen** | Recommended cover · Up next · every 6 h | §6 |
| **Sync and Wi-Fi** | Just in time · sync on sleep and wake | Wi-Fi switching (Add-on helper), Wi-Fi, Off after idle, Sync when the screen goes off, Sync on wake, Sync while reading, Wi-Fi after sleep sync, Sleep sync limit, Keep the reader awake while syncing, Wake Tailscale for syncs, Tailscale alert; Sync and sleep now, Test the sync path |
| **Library and storage** | 120 of 250 MB · saved for offline 2 days ago | BookOrbit opens from BookSync's cache, Automatic Full refresh, Save every cover for offline, Storage limit, Keep book copies current; Full refresh now |
| **Buttons** | Clicker: 2 buttons | Clicker buttons (Add-on helper), the clicker page, BookSync keyboard |
| **Kids and PIN** | PIN on · 3 guarded apps | Settings PIN (Add-on helper), Change PIN, Guarded apps, Turn the PIN off |
| **Setup and mode** | All set · Full mode | the Setup summary (opens Setup), Mode, Recommended settings, Skipped setup steps |
| **Updates and details** | Up to date · automatic | Automatic updates, Include pre-releases, Check for updates, Debug log, Log every key, Let BookSync switch Wi-Fi for syncs, Details, Licenses |

### 5.2 Row wording: one noun, one line

The label is a noun phrase that never changes with the value; the line under it says what the
setting does **in its current value**; the control shows the value in words. Examples (the schema
holds them all):

| Row | Line under it |
|---|---|
| Sync when the screen goes off | Your place and highlights reach BookOrbit before the reader sleeps. |
| Sync on wake | Every wake checks BookOrbit for reading done elsewhere. |
| Sleep sync limit | Gives up after 20 s so the reader can sleep. |
| Wake Tailscale for syncs | Starts Tailscale before each sync, so a server on your tailnet answers. |
| Let BookSync switch Wi-Fi for syncs | Off: syncs fail when Wi-Fi is off instead of turning it on. |
| Home shows this reader's reading first | Your latest page shows at once; BookOrbit fills in after. Applies when KOReader restarts. |
| BookOrbit opens from BookSync's cache | Pages open at once and offline, then are checked. Applies when KOReader restarts. |
| Save every cover for offline | About 100 KB per book. Off: covers are kept as you see them. |
| Storage limit | Pages, offline lists and covers. Book files don't count. Using 120 MB. |
| Keep book copies current | A book whose library file changed is downloaded again, never while you read. |
| End of book: BookSync's sheet | Stars, next in series and a suggestion when you finish a BookOrbit book. |
| End of book: mark it finished | Reaching the end marks the book read in BookOrbit. |
| Log every key | For clicker problems. Keys go to KOReader's log. |

Merged rows (one row, both keys set together, so there is one switch per outcome): **Wake Tailscale
for syncs** = plugin `wake_tailscale` + companion "Wake Tailscale with Wi-Fi"; **Automatic updates**
= "Auto-update app" + `auto_update_patch`; **Include pre-releases** = the app's + `patch_update_prerelease`.
The keys stay separate underneath; Details lists them apart.

### 5.3 Progressive disclosure

A row with a **parent** in the schema shows only while the parent has the value; when hidden, the
parent's line says what it would open ("Recommended cover: pick the list, leave-out rules, how often").

| Parent | Shows |
|---|---|
| Wi-Fi = Just in time | Off after idle |
| Sync when the screen goes off = on | Sleep sync limit, Wi-Fi after sleep sync, Keep the reader awake while syncing |
| Automatic Full refresh ≠ Only by hand | its interval |
| Sleep screen ≠ the reader's own | everything else in §6 |
| Sleep screen = Recommended cover | Pick from, Leave out, Change cover every |
| Style = Overlay | Text position, Battery corner |
| Settings PIN = on | Change PIN, Guarded apps, Turn the PIN off |
| Add-on helper off (Wi-Fi switching, Sleep sync, Clicker buttons, Settings PIN) | only the helper row, with "Without it: …" ([addon-mode](addon-mode.md) §3) |
| a cap the companion lacks (`wifi` without the helper…) | nothing; the section says where it lives |

### 5.4 Search

The search box is the top page's first row; tapping it opens the keyboard. Once it holds text, an
**✕** at its right end clears it in one tap and brings the sections back at once (M8C feedback,
2026-11-24). Results replace the
section list after a 0.5 s pause in typing (one redraw per pause, none per key), grouped by section,
each with the section as a small heading and the row's current value. It matches labels, lines,
value labels and the schema's search words ("screensaver", "lock screen", "wifi", "kid", "cache",
"offline"). Tapping a result opens its section with that row outlined (2 px) and scrolled to the
top. No match: "Nothing matches "foo". Try Wi-Fi, sleep, PIN or storage." Search covers hidden
dependent rows too: a result whose parent is off says "Shown when Sleep screen is on" and opens the
parent.

### 5.5 Sections as pages

Each section is its own page ("‹ Settings" back), one level deep. The page title and "‹ Settings"
are pinned at the top while the rows scroll (`EinkActivity.page`: every `Ui.header` goes into the
pinned slot). A row whose label is the page's own title (Sleep screen's mode) shows only its
control, so a title never shows twice. **No in-between screens:** a section that would hold one row
leading to another page opens that page directly (`SettingsUi.direct`): Buttons in Full mode opens
Clicker buttons, Kids and PIN with no PIN opens Set a PIN; in Add-on each has its helper switch
too, so the section stays (M8C feedback, 2026-11-24). Choices with up to four values are
segmented controls inline; five or more open a radio page (Sync while reading, Storage limit,
Automatic Full refresh, Pick from). Toggles are "On"/"Off" boxes in words (`Ui.toggle`). Actions are
outlined buttons at the bottom of their section, under a "Do now" heading.

### 5.6 E-ink rules

- No animation, no spinner, no timed redraw. A change redraws its page once (today's `render()`).
- Rows at least `Ui.ROW_DP` (76 dp), segmented controls 64 dp, buttons 56 dp; the launcher page's
  status lines are compact rows (`Ui.INFO_ROW_DP`, 48 dp).
- **Text never runs into the control** (`RowLayout`): a fixed 16 dp gap (`Ui.ROW_GAP_DP`) between
  the text column and the control; the control takes at most 45% of the row (`Ui.CONTROL_MAX`) and
  a longer value wraps; the text column takes the rest and wraps. "Waiting for KOReader" and
  "Changed in KOReader at …" sit on a line of their own under the row's line
  (`SettingsUi.line`).
- State by glyph and words, never grey alone: On/Off in words, ● for the chosen radio, the
  checklist's boxes for Waiting for KOReader (…) and Needs you.
- The top page fits one screen on the M8C, Boox Page and Go Color 7; a section may scroll.

### 5.7 The KOReader menu, grouped the same way

Cheap, because it is a regrouping of `P/ko/menu.lua:214-289` with the schema's sections: Tools ›
BookSync gets five submenus, **Reading and Home**, **Sleep screen**, **Sync and Wi-Fi**, **Library
and storage**, **Updates and details**, each with the same labels as the companion; then **Sync and
sleep now**, **Full refresh of BookOrbit**, **Recommended settings**, **Open BookSync Companion**; then
the status line. Buttons, Kids and PIN and Setup are one line: "Buttons, PIN and setup: in BookSync
Companion ›". KOReader's own `help_text` carries the one-line explanation.

### 5.8 Recommended settings in the companion (A1)

Setup and mode › **Recommended settings** shows the review list the plugin has today, from
`orbit-recommended.json` the plugin writes at each pass (item, BookSync's value, yours, state). Each row
offers **Use BookSync's** / **Keep mine**; the choice is a shared key (`recommended_choice`, a map of
item id to choice) and the plugin applies it at its next start or resume, because it changes
KOReader's and BookOrbit's own settings, which only KOReader can write. Until then the row shows
Waiting for KOReader.

### 5.9 The launcher page replaces the in-between Companion page

In Full mode, the launcher page's "⚙ Companion" button opened `StatusActivity`, a status page with
its own Settings button. That in-between page is gone: the button is now **⚙ Settings** and opens
the top page (§5.1). What the page showed moved to the launcher page, which already had Network
and Last sleep sync. What it let you do moved to the matching section. Every item keeps its id
and its PIN behaviour (mockups 13-15).

| Was on the Companion page | Now | PIN |
|---|---|---|
| Settings button | the launcher button, renamed **Settings** | Settings opens read-only while locked (§4.7) |
| Wi-Fi | launcher page (its Wi-Fi row, which was already there) | open |
| Tailscale, Service, Screen-off permission | launcher page (`StatusPanel`) | open |
| Battery › | launcher page | open |
| Last sleep sync, Last wake network ready in, Wi-Fi turns off | launcher page, in the Network card | open |
| Setup summary card | launcher page, right under Other apps / Settings (the old "N setup steps need you" line under Open KOReader said the same and is gone; M8C feedback, 2026-11-24: the main view fits on one screen) | open (Setup's own rules) |
| Frozen apps line | launcher page | open |
| What's new line | launcher page | open |
| App version: update ready, **Install** | launcher page | through the keypad, as before (`PinActivity.thenInstall`) |
| Test network | Sync and Wi-Fi › Do now | hidden while locked |
| App version, Check for updates | Updates and details, first row | `Pin.run`, as before |

`StatusActivity` stays the app's launcher icon, the `SHOW_STATUS` target and the notification's
target. It still runs the first-run Mode choice, the "Setup needs you" prompt and
`Updater.onPageResumed`. In Full mode it then shows the launcher page, which also calls
`Updater.onPageResumed` itself, since its Install row can open Android's prompt. In Add-on mode
the launcher page isn't used, so `StatusActivity` stays the main page: the same `StatusPanel` rows
under a Settings button.

## 6. The sleep screen in the companion

All of [lock-screen](lock-screen.md) S2, on one page in this order. Off: only the first row, with
"The reader shows its own sleep screen."

1. **Sleep screen**: The reader's own / Recommended cover / Current book (segmented).
2. **Pick from** (Recommended): "Up next in series, ToRead ›" (every ticked source) opens the picker (§6.1).
3. **Leave out** (Recommended): "2 rules ›" opens the rule list (§6.3).
4. **Change cover every** (Recommended): 1 / 3 / 6 / 12 / 24 h (segmented, one row).
5. **Text**: the text or "None", **Edit** opens a one-line input with "12 of 60".
6. **Show battery level**: On/Off.
7. **Style**: Bar / Overlay.
8. **Text position** (Overlay): Right / Left / Top / Bottom.
9. **Battery corner** (Overlay): the four corners, as a 2 × 2 grid drawn like the screen; "Moves to
   top left beside the text" when L3b2 applies.
10. **Shown by**: "BookSync screen saver ✓" or "Set up ›" (unchanged, `C/SleepPages.kt:57`).
11. **Preview** (unchanged: 5 s or a tap).

A small live thumbnail of the current screen sits beside the Style row, redrawn once per change
(the same `SleepScreen.render` as Preview, at thumbnail size).

### 6.1 The picker

One page: **Library** (every book) first, then three groups: **Lists** (Up next in series, Want to
read, Discover), **Smart scopes** and **Collections**, each item with its book count and a tick box.
Pick from is a set ([lock-screen](lock-screen.md) R1c, the user's ruling 2026-11-24): a tap ticks or
unticks an item and the page stays; Library clears the others and another clears Library; the last
item can't be unticked (`SleepPoolLogic.togglePick`, Lua `SleepPool.togglePick`). The value is one
item per line in `sleep_from`, synced per key like any other. Under the groups: "Lists from
KOReader, 14:02". The X2 note sits at the bottom: "For a custom field: make a smart scope with that
condition in BookOrbit, then pick it here."

### 6.2 Where the lists come from

The companion's worker writes the lists into `koreader/settings/orbit-sleep/`: `scopes.json`
(`{v, at, scopes: [{id, title, count}], collections: [...]}`, from the server) and `tags.json`
(`{v, at, details, tags: [{tag, label, count}]}`, from the saved book details), both at a
`SLEEP_REFRESH` (`SleepPoolBuilder.scopes`, `.tags`). The worker needs the login, which only the
plugin sends, so the picker asks: `/status` carries `"want_choices": <ms>` while the picker is open,
and the plugin answers at its next refresh with `SLEEP_REFRESH scopes_only=1`. Both companion
pickers load these saved lists on a serial background worker and draw from an in-memory snapshot. Opening either picker requests a refresh; file-change events reload the
snapshot on the worker. Taps update local preferences and the checkmark immediately; status-file
writes, plugin sync and sleep-picture rendering run in the worker. Timing logs record list work
and the tap-to-draw duration. The companion redraws the picker when either file changes. (The
plugin's `choices.json` is gone: it stopped being written when `Sleep.cachedTags` went, `docs/design/sqlite-cache.md`.)

- **KOReader not running, file present:** the lists show with "From KOReader, Monday 14:02".
- **No file yet:** "Open KOReader once to load your smart scopes and collections." The three lists
  still work.
- **A rule or source whose scope is gone:** "Scope not found" (X7), as in the plugin.

The names are the account's own scope and collection names, written to shared storage beside the
pool's titles (`pool.json` already holds book titles there).

### 6.3 Leave out

One page: **Library**, **Tags**, **Smart scopes**, **Collections**, each with a visible tick box.
A tap updates the checkmark and persists on this page; no Add/Remove subpage or Back tap is needed.
**Type a tag…** adds a selected row immediately, even if the saved list does not contain that tag.
Selected scopes or collections missing from the saved lists remain visible and can be unticked.
Library leaves out every book (the sleep screen then shows the current book) and stands alone;
choosing an individual rule clears the Library selection before applying the existing rule helper.
The shared rule strings and membership rules are unchanged. The custom-field note sits below the
choices. Locked settings show the same rows read-only.

## 7. Self-grill log (two-way doors, settled)

| # | Question | Decision | Why |
|---|---|---|---|
| D1 | Which plugin settings come to the companion? | All 29 and actions A1-A5 | The user's words: "ALL"; they don't use KOReader's menus. |
| D2 | Plugin-only? | Only Open BookSync Companion and Open another app… | They are navigation into the companion, not settings. |
| D3 | Where definitions live | One schema file in `shared/settings/`, copied into both builds, guard-tested | One place to add a setting; the two UIs can't drift. Mirrors `shared/fixtures/sleep/cases.json`. |
| D4 | Where values live | Both sides, per-key `{v, at}`, newest wins | Each side must work while the other is off; it extends today's two copies. |
| D5 | Per-key or whole-set time | Per key | Whole-set loses one of two changes to different keys. |
| D6 | Tie | The companion wins | Deterministic, and it is where the user works. |
| D7 | Carrier | Existing `SETTINGS` + `/status` + status file, with one `values` JSON extra | No new IPC; JSON avoids 30 more flat extras. |
| D8 | Old flat extras | Kept one release, then removed | Lets either side update first. |
| D9 | Prompt the plugin when the companion changes something | A `SETTINGS` line on `/clicks` when up; else resume | The channel already exists and is pushed from the companion; resume covers the common path. |
| D10 | Queued changes | Shown per row as Waiting for KOReader until the plugin echoes the key's `at` | Generalises the Sync while reading request; the user sees what hasn't applied. |
| D11 | Sync while reading | Becomes an ordinary shared key; the request fields stay one release | One mechanism. |
| D12 | Restart settings | Restart at the next screen-off, never in front of a book | Reading fonts already does this; nothing interrupts reading. |
| D13 | PIN when locked | Companion Settings read-only with Unlock | Same as Setup §3.9; a kid can say what's set, nothing changes. |
| D14 | Sections | The eight in §5.1 | They follow what the user is trying to change, not which app reads it. |
| D15 | Add-on helpers | The helper switch is the first row of its own section | One place per setting; the section shows its rows once the helper is on. |
| D16 | Two rows for one outcome (Tailscale, updates, pre-releases) | One row sets both keys | The user doesn't care which app does it. |
| D17 | Choices of five or more | A radio page | A segmented control of six on a 6" panel is too small to hit. |
| D18 | Search updates | After a 0.5 s typing pause | One redraw per pause, not per key. |
| D19 | Picker data | A file the plugin writes, refreshed on request through `/status` | The companion never talks to BookOrbit (`INTERFACE.md:5-6`); files in `orbit-sleep/` are the existing path. |
| D20 | Typing text | Android's keyboard in the companion | The reader isn't in KOReader; Android's keyboard is better than KOReader's. |
| D21 | Recommended review in the companion | A file from the plugin plus a shared choice key | Only KOReader can write KOReader's settings; the user still decides from the companion. |
| D22 | KOReader menu | Regroup into the same sections | Cheap (one table), and the two read the same. |
| D23 | Live thumbnail on the sleep page | Yes, redrawn once per change | Saves a Preview round trip for every style change. |

## 8. One-way doors

None. Every change is on-screen layout, wording, or an extension of the existing channel that keeps
the old extras for one release. Setting keys keep their names and defaults, so nothing a reader has set
is reset, and turning the redesign back means drawing the old pages from the same values.

## 9. Building blocks (when built)

| Piece | Owner | Reuse |
|---|---|---|
| Schema | `shared/settings/schema.json` | — |
| Store and merge | plugin `logic/settings_sync.lua` (pure); companion `SettingsSync.kt` (pure, in `LogicTest`) | `Shared.refresh`/`push`, `SleepPool.normalize`, `ReadingSchedule` folded in |
| Shared rule table | `shared/fixtures/settings/merge.json`: per-key merges, ties, future times, invalid values, queued echo | the way `shared/fixtures/sleep/cases.json` is read by both |
| Settings pages | companion `SettingsPages.kt`: top page, section page drawn from the schema, radio page, search | `Ui.row`, `Ui.toggle`, segmented control from `C/Pages.kt:449-472` |
| Sleep page | `SleepScreenActivity`, the Sleep screen section page (`SHOW_SLEEP` still opens it); the picker is `SettingChoiceActivity`, the rules page `LeaveOutActivity` | `SleepScreen.save` through `SettingsStore` |
| Other features' rows | `SettingsSlots.register(section, slot)`: for example, Sharp covers' "sign in once" row in Sleep screen | — |
| Status and info | `StatusPanel` (`C/Pages.kt`): the launcher page, and Add-on's main page | the old `StatusActivity` rows |
| Review file | plugin `ko/recommended.lua` (`orbit-recommended.json`) | `Rec.reportFields` |
| Channel nudge, COMMANDs | `C/ClickChannel.kt`, `P/ko/clicks_channel.lua`, `PluginCommands` | existing |
| Plugin menu | `P/ko/menu.lua` regrouped by schema section | `toggle`, `radios` |

## 10. Tests (when built)

- Merge table, both sides: newer key wins, other keys untouched, tie to the companion, invalid value
  ignored, future time clamped, the plugin's echo clears Waiting.
- Schema guards: both copies equal the shared file; every plugin `DEFAULTS` key is in the schema or on
  the state list; every schema row has a label, a line and a section; every parent names a real key.
- Robolectric: the top page fits 1264 × 1680 without scrolling; a locked PIN shows no controls; a
  hidden child appears after its parent turns on with one render; search finds "screensaver".
- Plugin `test_flows.lua`: a value changed in `/status` while KOReader was off applies at start before
  the start sync.

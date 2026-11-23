# Add-on mode (no launcher takeover) and recommended settings during setup

Status: approved (2026-11-22 PT), shipped in Android 0.11.0 (§16 says what shipped and what
waits). Android only. Mockups: [`addon-mode-mockups.html`](addon-mode-mockups.html) (8 screens).
ROADMAP row 10.

**The user's decisions on the two one-way doors (§15): both yes.**
1. Readers already in use get the recommended settings once, at their next update. The same rules
   apply as on a new reader: only values still at their default change, values the user changed
   are listed for review, a backup allows Undo, and new items in later releases work the same way.
2. The companion learns one yes/no: whether BookOrbit is signed in. Never the server, the account
   or the key.

Revision note (same day): the user ruled that **Add-on mode does not mean KOReader is already set
up**. The mode is about launcher and device management only. How recommended settings are applied
depends on **KOReader's state**, never on the mode (§5).

Citation prefixes:

| Prefix | Source |
|---|---|
| `C/` | companion, `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/` |
| `M/` | companion manifest, `android/companion/app/src/main/AndroidManifest.xml` |
| `O/` | Orbit plugin, `android/koreader/orbit.koplugin/` |
| `B/` | BookOrbit plugin 2.3.0 at v3.9.0 `c1dd6b4`, `upstream/bookorbit/koreader-plugin/bookorbit.koplugin/` |
| `K/` | KOReader v2026.07.1 `9192014`, `upstream/koreader/` |
| `I/` | `android/docs/INTERFACE.md`; `D/` `android/docs/DESIGN.md`; `S/` `android/docs/SETUP.md` |

Related designs, still drafts outside this repo: menus (ROADMAP 8b) and cache / no app switches
(ROADMAP 7, 9). §9 says how Add-on mode changes them.

---

## 1. Outcome

1. **Two modes, chosen on first run, switchable later.**
   - **Full** is today's Orbify. The companion is the Home app, switches Wi-Fi, holds the wake
     lock for sleep sync, turns the screen off, and runs the clicker and PIN services.
   - **Add-on** does not take over the launcher or manage Wi-Fi and sleep. Everything else is the
     same: it still downloads, installs, updates and configures KOReader, the BookOrbit plugin
     and the Orbit plugin. Wi-Fi switching, sleep sync, the clicker service and the Settings PIN
     are optional **helpers**, each off until switched on.
2. **Recommended settings are applied during setup, in both modes.** On a fresh or untouched
   KOReader, Orbit applies them by itself, keeps a backup, and shows one line: "Applied 7
   recommended settings · Review". On a KOReader where the user changed something, Orbit applies
   only the items still at their default, and lists the ones that conflict for the user to pick
   "Use Orbit's" or "Keep mine". Nothing the user changed is ever overwritten silently. Undo
   restores the backup.
3. **The plugin adapts to what the companion offers.** The companion publishes its mode and
   capabilities. The plugin hides or explains what's missing, with no errors. With no companion
   at all, the reading features still work.
4. **Each mode has its own Setup checklist with "Fix next".** In Add-on, only four items are
   required: KOReader, the BookOrbit plugin and the Orbit plugin installed, and signed in to
   BookOrbit. Every permission is optional. Each one says what is lost without it, a declined one
   shows a calm "Off: …", and nothing nags. Reminders reach Add-on users without the
   Home-press prompt, and only for the required items.

Not in scope: Xteink (it has no launcher to take over); changing what Full mode does.

---

## 2. What existed before 0.11.0 (verified)

| Fact | Evidence |
|---|---|
| Recommended plugin settings are applied **only when tapped**, behind a ConfirmBox. They overwrite without checking for user values and keep no backup. | `O/ko/recommended.lua:9-37`, menu entries `O/ko/menu.lua:204-205` |
| Recommended gestures overwrite four `gesture_reader` slots, again on tap only. | `O/ko/recommended.lua:39-66` |
| `silentWifiOn` **silently** sets KOReader's `wifi_enable_action = "turn_on"` whenever the companion is installed and `wifi_via_companion` is on. No backup. | `O/ko/wifi_backend.lua:106-113` |
| The plugin treats "companion installed" as "every companion feature works". About 25 call sites check `Companion.installed()`. | `O/ko/companion.lua:101-102`; `O/ko/shared.lua:16-34`, `O/ko/wifi_backend.lua:17-107`, `O/ko/sleep.lua:91`, `O/ko/home.lua:501`, … |
| Every plugin broadcast starts the foreground service, whatever the action. | `C/OrbitService.kt:38-43` (`CommandReceiver` → `OrbitService.start`) |
| `/status` lives in the service (loopback server) and has no mode or capability field. | `C/OrbitService.kt:555-640` |
| Companion update checks run only from the service (start, Wi-Fi up). | `C/OrbitService.kt:209`, `:380`; `C/Updater.kt:75` |
| The Home-press setup prompt and the KOReader setup box both exist. The box reads `setup_prompt` from `/status`. | `C/Attention.kt:85-103`; `O/ko/home.lua:500-526`; `D/` "Setup needs you" |
| The Setup rows: tips, Not disabled, Install updates, KOReader, BookOrbit plugin, Orbit plugin, Home app, notifications, battery ×3, Tailscale, device admin, clicker, keyboard, Orbit plugin answered, Wi-Fi test. | `C/Pages.kt:473-747` |
| BookOrbit's stock defaults: `auto_sync=false`, `sync_forward=PROMPT`, `sync_backward=DISABLE`, `catalog_auto_open="off"`. They are readable at run time as `p.default_settings`. | `B/main.lua:102-125`, `:179-189` |
| On Android, `hasSeamlessWifiToggle = no`, so BookOrbit's auto-sync guard does not need `wifi_enable_action = turn_on`. | `K/frontend/device/android/device.lua:80`; `B/main.lua:196`, `:1418-1427` |
| "Make BookOrbit home" (`catalog_auto_open="home"`) opens BookOrbit at startup and whenever a book closes. | `B/bookorbit_settings_page.lua:208`; `B/main.lua:1410`, `:1473` |
| KOReader's gestures keep their stock defaults in `gestures.defaults` and mark a value "(default)" with `util.tableEquals`. | `K/plugins/gestures.koplugin/main.lua:249`, `:310-312`; defaults `defaults.lua:62`, `:73` |
| BookOrbit exposes `isLoggedIn()` and `openSignIn` / `promptLogin()`. | `B/main.lua:283-285`, `:967-974` |
| Without the companion, the plugin already wakes Tailscale itself, keeps Wi-Fi "Always on", and makes "Sync and sleep" ask for the power button. | `I/` "Without the companion" |

---

## 3. Capability matrix

"Helper" = optional in Add-on, off until switched on. Full has every row on.

| Feature | Full | Add-on | Plugin only (no companion) |
|---|---|---|---|
| Install and update KOReader (official build, checked) | yes | yes | no (by hand or USB) |
| Install the BookOrbit plugin | yes | yes | no |
| Install and update the Orbit plugin; plugin self-update | yes | yes | self-update only |
| Recommended settings applied during setup, with backup and undo (§5) | yes | yes (same rules) | yes (same rules) |
| BookOrbit sync, local-first home, write-through cache, end-of-book sheet | yes | yes | yes |
| KOReader opens into BookOrbit home (`catalog_auto_open`) | yes | yes | yes |
| Tailscale wake before a sync | companion | plugin (direct broadcast) | plugin |
| Test sync path | yes | yes (fewer steps) | yes (fewer steps) |
| Companion is the Home app; Home → book → BookOrbit home → launcher; boot into KOReader; relaunch after a crash | yes | **no** | no |
| Other apps / launcher page | yes | no (the vendor launcher does this) | no |
| Wi-Fi modes (Always on, Off while reading, Just in time) | yes | helper: **Wi-Fi switching** | no (Always on) |
| Sleep sync with a wake lock; Wi-Fi after sleep sync | yes | helper: **Sleep sync** | best effort, no wake lock |
| Sync and sleep turns the screen off (device admin) | yes | sub-option of Sleep sync | no (asks for the power button) |
| Clicker buttons in KOReader (keymap) and other apps (accessibility) | yes | helper: **Clicker buttons** | no |
| Settings PIN (Orbit settings lock, guarded apps) | yes | helper: **Settings PIN** (cannot guard the vendor launcher's own settings) | no |
| Battery stats | yes | yes | no |
| Restart KOReader after an update | yes | yes, while KOReader is in front (§7.4) | "close and reopen KOReader" |
| Setup reminders | Home prompt, KOReader box, notification, for every step | KOReader box, notification, **only for the four required items and recommended-settings conflicts** | the plugin's own line in Orbit settings |
| Companion foreground service and its notification | always | only while a helper that needs it is on | n/a |

### 3.1 Without each permission (Add-on): the fallback

The user ruled that every feature must work without each optional permission: a fallback, or
hidden with a short note, with no errors and no repeated prompts. In Full mode these permissions
are steps, as today.

| Permission or feature | What it enables | Fallback without it | Where the note shows |
|---|---|---|---|
| Install unknown apps | Orbit installs KOReader and updates itself | KOReader: "Install it yourself" link on the row. Companion updates: the update-ready notification (or Orbit's status page) offers "Download" to the browser instead of installing. | the KOReader row; Orbit's status page |
| Storage access (asked at plugin install) | Orbit copies the plugins into `koreader/plugins/` and writes the status file | The plugin rows show copy-by-hand steps, and the Orbit plugin keeps updating itself (`O/ko/updater.lua`). Without the status file the plugin acts as plugin-only, plus `/status` when a service runs. | the plugin rows |
| Notifications | update-ready and required-step alerts | the same text on Orbit's pages and on Orbit settings' status line in KOReader | nowhere extra (no nag) |
| Accessibility (Orbit clicker) | clicker buttons and Send-keys in other apps; the app guard | clicker buttons still work inside KOReader (the keymap through `/status`, `I/` "keymap"); the PIN still locks Orbit's settings in KOReader | the Clicker page: "Only inside KOReader" |
| Orbit keyboard | Send-key actions in other apps | Send-key actions work as page turns inside KOReader only | the Clicker page |
| Device admin (force-lock) | Sync and sleep turns the screen off | Sync and sleep syncs, then "Synced. Press the power button to sleep." | that message, once with "Orbit can do this for you ›" |
| Battery: Unrestricted | sleep syncs and Wi-Fi-off timers on time | a sleep sync may be cut short; the BookOrbit outbox sends it on wake (`D/` "Risk") | nowhere extra |
| Wi-Fi switching (feature) | Wi-Fi modes | Always on, as without the companion (`I/` "Without the companion") | Orbit settings: one line "Wi-Fi switching: in Orbit Companion ›" |
| Sleep sync (feature) | wake lock while syncing on sleep | the plugin still tries a sleep sync when Wi-Fi is on; the outbox covers the rest | same line |
| Home role | not offered in Add-on | n/a | n/a |

---

## 4. Setup flows

### 4.1 First run: the mode choice (mockup 1)

- The companion's first Setup page, shown while `Prefs.mode` is unset.
- Two cards, no preselection: **Full: Orbit runs the reader** and **Add-on: keep your launcher**.
  Each lists in plain words what it does and does not do. "You can switch later in Settings."
- **Existing installs never see it.** On the first start of the release that ships this, `mode`
  is set to Full when the companion is the Home app or any Full-only step is done (device admin
  granted, accessibility on). Readers already set up therefore stay Full with no prompt. Otherwise
  the choice shows the next time Setup opens.
- `tools/install-usb.sh` asks nothing. The choice happens on the reader (two-way: a
  `--mode` flag can be added later).

### 4.2 Full checklist (mockup 2)

Today's rows, in today's order (`C/Pages.kt:473-747`), plus two:

| Row | New? | Done when | Fix |
|---|---|---|---|
| Tips: Family Link / Managed, Play Protect, freeze tip | | (tips, never counted) | Help / Got it |
| Not disabled by the system | | no app frozen | re-enable page |
| Install updates | | install permission | system page |
| KOReader app installed | | official build | install |
| BookOrbit plugin installed | | ≥ `MIN_VERSION` | install |
| Orbit plugin installed | | current | install / restart |
| **Signed in to BookOrbit** | new | the plugin reports `signed_in=1` (§7.3) | opens KOReader with `COMMAND=signin`: the plugin calls BookOrbit's `promptLogin()` (`B/main.lua:967`) |
| **Recommended settings** | new | the plugin reports `recommended` = `applied` or `reviewed` | opens KOReader with `COMMAND=recommended`: the review page (§5.5) |
| Set Orbit as Home app | | | Home settings |
| Allow notifications | | | |
| Battery: Unrestricted ×3 | | | |
| Tailscale signed in and connected | | | |
| Allow "lock screen" | | | |
| Clicker buttons / Orbit keyboard (shown only when mapped) | | | |
| Orbit plugin answered (info) | | | |
| Wi-Fi off/on test (info) | | | |

Header: "Full setup (12/14)". A one-line row at the top: "Mode: Full · Settings › Mode to change".

### 4.3 Add-on checklist (mockup 3)

Revision note: the user ruled that Add-on users are more careful about permissions. The Add-on
checklist therefore has **two different kinds of row**:
- a short **Required** list: what Orbify can't work without;
- an **Optional permissions and features** list. Each row says what is lost *without* it, not a
  fix to do.

Nothing optional ever nags.

**Required: exactly four rows.** These are the only rows that count in "Add-on setup (3/4)", the
only ones "Fix next" walks, and the only ones that can raise the setup box or the notification.

| Row | Done when | Fix |
|---|---|---|
| KOReader installed | any KOReader that loads `koreader/plugins/` (the official build; §11 for others) | **Install** (needs "Install apps", asked then, see below) or "Install it yourself" (link to KOReader's releases) |
| BookOrbit plugin installed | ≥ `MIN_VERSION` | **Install** (asks for storage access then) or the copy-by-hand steps (`S/` §6) |
| Orbit plugin installed | current | same as above |
| Signed in to BookOrbit | the plugin reports `signed_in=1` (§7.3) | opens KOReader at BookOrbit's sign-in |

Not required, and not counted:
- **Recommended settings** is a status line under Required ("Applied 7 · Review", or "2 to
  review"). It is never a step (§5).
- **Orbit plugin answered** and **Tailscale connected** (only if Tailscale is installed) are info
  lines.
- **"Not disabled by the system"** is shown only while an app *is* frozen, as a warning on the
  row of the app it breaks. A frozen KOReader makes "KOReader installed" not done. Otherwise it
  is absent.

**Optional: what you get with each, and what you lose without it.** Each row has the name, one
plain line "Without it: …", and either **Allow** or a calm state:
- *On*: one line saying what it adds;
- *Off: <what is limited>*: shown after the user declined or never allowed it.

There is no tick and no "open ›", and none of these rows is counted, walked by Fix next,
notified or put in the setup box. If the user turns one off later in Android, the row simply
shows Off.

| Optional | Without it | Allow does |
|---|---|---|
| **Install apps** ("Install unknown apps" for Orbit) | Orbit can't install KOReader or update itself; you install updates yourself from the releases page. | opens the system page |
| **Notifications** | Orbit can't tell you about an update or a setup step; you see them in KOReader's Orbit settings and when you open Orbit. | system page |
| **Clicker buttons in other apps** (accessibility) | Clicker buttons work only inside KOReader, and the Settings PIN locks only Orbit's settings, not other apps. | accessibility page; shown only once a clicker button is mapped or a PIN is set |
| **Orbit keyboard** (input method) | Send-key clicker actions don't work in other apps. | input-method page; shown only while a Send-key action is mapped |
| **Wi-Fi switching** (a feature, no Android prompt) | Wi-Fi stays as you leave it; a sync waits for Wi-Fi you turn on. | a switch; starts Orbit's background service |
| **Sleep sync** (a feature) | Syncs on sleep happen only when Wi-Fi is already on and may be cut short; they finish when you next wake the reader. | a switch; starts the service |
| **Screen off after Sync and sleep** (device admin, only with Sleep sync) | Sync and sleep syncs, then asks you to press the power button. | the device-admin page |
| **Battery: Unrestricted** (Orbit, KOReader; only with Sleep sync or Wi-Fi switching on) | Android may pause Orbit or KOReader while the screen is off, so sleep syncs and Wi-Fi switching off can be late. | the app's battery page |

**Storage access** isn't a row of its own. Android asks for it when the user taps Install on a
plugin row. Declined, the plugin rows show "Copy the plugin by hand" with the steps. The status
file (§6.2) also needs storage access. Without it, the plugin sees no mode, falls back to `/status`
or plugin-only behaviour, and says nothing.

The Settings PIN and clicker mapping are not checklist rows. They are features the user turns on
in Orbit's Settings, as today. The accessibility row above appears once they exist.

### 4.4 Where reminders show in Add-on mode

Only the **four Required rows** and **recommended-settings conflicts** ever remind. Optional
rows never do. In `SetupAttention` terms (`C/Logic.kt:715-792`), every optional row is
`INFO_ONLY` in Add-on: never "needed", never "regressed".

The Home-press prompt (`C/Attention.kt:95-103`) can't exist without the Home role. The other
three channels already exist and stay:

1. **The KOReader setup box** (`O/ko/home.lua:500-526`): one box per set of rows, never in a
   book, "Fix now" / "Later". In Add-on with no service running, it reads `setup_prompt` from
   the status file (§6.2) instead of `/status`. Mockup 8.
2. **The companion's notification** ("Setup steps" channel), posted from the receiver or the
   daily job (§7.2) rather than the service. It is sent only when notifications are allowed.
3. **Orbit settings' status line** in KOReader: "Orbit Companion: 1 setup step ›".

Rows that come from the plugin (Signed in, Recommended settings) are also shown by the plugin
itself, so plugin-only users get them: a "Sign in to BookOrbit" line on its status, and the
recommended-settings line (§5.4).

---

## 5. Recommended settings

### 5.1 The rule: KOReader's state decides, not the mode

Each recommended item has a **stock default** (what KOReader or BookOrbit ships) and **ours**.
When the plugin runs a pass, each item is in one of these states:

| State | Test | What happens |
|---|---|---|
| **already** | current = ours | nothing; counted as applied |
| **at default** | current = stock default (or unset) | **applied automatically**, prior value backed up |
| **conflict** | current ≠ default and ≠ ours: the user changed it | **never overwritten**; listed for review: "Use Orbit's" / "Keep mine" |
| **unavailable** | needs a capability or plugin that's missing | not applied, shown greyed with the reason |
| **skipped / kept** | the user chose Keep mine (or Skip) before | left alone for good, until they change it on the review page |

That gives the two cases the user described, in both modes:
- **KOReader installed fresh by Orbify, or with untouched defaults**: every available item is at
  default, so all are applied, and the plugin shows one line, "Applied 7 recommended settings ·
  Review" (mockup 5). No question is asked.
- **An existing KOReader with changed values**: the at-default items are applied the same way,
  and the conflicts are listed (mockup 4). The line then reads "Applied 4 recommended settings ·
  2 to review".

"Default" is read at run time, never hard-coded where upstream exposes it:
- BookOrbit: `p.default_settings[key]` (`B/main.lua:102`, used the same way at `:179-189`).
- Gestures: `gestures.defaults[id]`, compared with `util.tableEquals`, exactly how KOReader
  marks "(default)" (`K/…/gestures.koplugin/main.lua:310-312`). This keeps the
  device-dependent defaults right (`two_finger_swipe_north` is brighter-frontlight only on
  devices with a light, `defaults.lua:62`).
- KOReader global settings: unset (`nil`) is the default.

### 5.2 The exact list

| Id | Setting | Ours | Stock default | Needs |
|---|---|---|---|---|
| `bo.auto_sync` | BookOrbit › Auto-sync | on, through the plugin's own toggle event (`O/ko/recommended.lua:28-31`) | off | BookOrbit plugin |
| `bo.sync_forward` | BookOrbit › When BookOrbit is further ahead | Silent | Ask | BookOrbit plugin |
| `bo.home` | BookOrbit › Make BookOrbit home (`catalog_auto_open`) | `home`: KOReader opens into BookOrbit at start and after a book closes | `off` | BookOrbit plugin; `Compat.settable` (`O/ko/recommended.lua:23`) |
| `ko.wifi_on` | KOReader › Action when Wi-Fi is off | Turn on | unset (ask) | **Wi-Fi switching** (Full, or the Add-on helper). Without it the stock prompt stays. |
| `g.sync_sleep` | Gesture in books: hold top-right corner | Orbit: Sync and sleep | none | Orbit plugin. Without the screen-off capability the label says "Sync, then press power". |
| `g.sync_all` | Hold top-left corner | BookOrbit: sync all books | none | BookOrbit plugin, Gestures plugin |
| `g.this_book` | Swipe right along the bottom edge | BookOrbit: this book | none | same |
| `g.apps` | Two-finger swipe up | Orbit: other apps | brighter frontlight (devices with a light) | **`apps` capability (Full only)** |
| `g.no_flip` | Tap top-left corner | nothing | toggle page-flipping (`defaults.lua:73`) | ships with 8b menus (its §5); listed here so one engine owns it |
| `o.clean_menus` | Orbit › Clean menus | on | (Orbit's own; see below) | ships with 8b menus |

Notes:
- Today's ConfirmBox also lists "further behind: Don't sync". That is BookOrbit's default
  already (`B/main.lua:112`), so it drops out of the list: it could only ever be a conflict, and
  conflicts are never overwritten.
- **`o.clean_menus`** has no KOReader default to compare with. It counts as at-default when the
  pass finds **no conflicts at all** (KOReader looks untouched), and as a conflict otherwise. A
  user who has customised KOReader is therefore asked before Orbit replaces its menus. This
  replaces the 8b design's "default on for new installs" with the same rule as every other item
  (§9).
- `ko.wifi_on` stops being silent. `silentWifiOn` (`O/ko/wifi_backend.lua:106-113`) goes through
  this engine with a backup. When Wi-Fi switching is on it is **required**, not optional: in a
  conflict the review explains that Wi-Fi switching needs it, and offers "Use Orbit's" or "Turn
  Wi-Fi switching off".
- Orbit's own feature defaults (local-first, offline cache, end-of-book sheet) are not on the
  list. They are Orbit's settings with Orbit's defaults, unchanged.

### 5.3 When a pass runs

- **At plugin start**, once the BookOrbit plugin instance is found (with the existing next-tick
  fallback, `O/ko/module.lua`). A pass runs when:
  - no pass has ever run (`S.recommended` is nil): the **first setup**, whatever the mode; or
  - the list holds an item id this device has never seen (a later release added one); or
  - a capability appeared that unblocks an unavailable item (the user switched a helper on).
- Only the new or unblocked items are considered on later passes. An item once applied, kept or
  skipped is never evaluated again by a pass. So a user who later sets a gesture by hand never
  sees Orbit change it back.
- **Writes happen at any time; messages only off a book** (file browser, BookOrbit home), like
  the setup box.
- **Missing pieces wait, they don't fail.** With the BookOrbit plugin not loaded, its items are
  unavailable and are evaluated again on the first start where it loads. With KOReader's
  Gestures plugin off, the gesture items say "Turn on KOReader's Gestures plugin" (today's text,
  `O/ko/recommended.lua:42`).
- **Existing devices at the update** (anyone on 0.10.x) run their first pass
  then. Items already set by hand count as already; at-default items get applied; conflicts are
  listed. One-way door 1.

### 5.4 What the user sees

- **After a pass that changed something**: one line, off-book, for 4 s, and the same text stays
  on Orbit settings until tapped: "Applied 7 recommended settings · Review" (mockup 5), or
  "Applied 4 · 2 to review" with conflicts. Tapping opens the review page.
- **A pass with only conflicts**: no toast; the companion's "Recommended settings" row and the
  setup box carry it ("Review 2 recommended settings").
- **A pass that changed nothing and found no conflicts**: silent.

### 5.5 The review page (mockup 4)

A KOReader page (BookOrbit's kit, or a plain `Menu` when that kit is missing, like the 8b
fallback). It is opened from the line above, from Orbit settings › Recommended settings, and from
the companion's row (`COMMAND=recommended`).

- **To review** (conflicts first): each row shows the setting, **yours** and **Orbit's**, and two
  buttons, *Use Orbit's* / *Keep mine*. "Use all of Orbit's" and "Keep all mine" at the top
  handle every conflict at once.
- **Applied**: each applied item, with its earlier value ("was: Ask"), and a per-row *Undo*.
- **Unavailable**: greyed, with the reason ("needs Wi-Fi switching in Orbit Companion",
  "needs Full mode").
- Footer: **Undo all** (restores every backed-up value), **Done**.
- "Keep mine" is stored, and the row moves under "Kept yours", where *Use Orbit's* stays
  available.

### 5.6 Backup and undo

- `S.recommended = { rev, at, items = { [id] = "applied" | "already" | "kept" | "unavailable" } }`.
- `S.recommended_backup = { [id] = { had = bool, prior = value, ours = value, at } }`, stored
  with the plugin's settings (`orbit_android` in `G_reader_settings`), so an Orbit update keeps it
  and uninstalling Orbit leaves KOReader's settings as they are.
- **Undo restores the prior value only while the current value still equals ours.** A setting
  the user changed after Orbit applied it is left as it is, and the row says "changed since;
  left as is".
- `bo.auto_sync` undoes through BookOrbit's own toggle event, as it was applied. Gestures are
  restored by writing the prior table back (or removing the key when `had=false`) and flushing,
  as the apply path does (`O/ko/recommended.lua:56-60`).
- Undoing `ko.wifi_on` while Wi-Fi switching is on asks to switch the helper off first.

### 5.7 Who applies them

Always the **plugin**, in KOReader's process. The companion never writes KOReader's or
BookOrbit's settings files: KOReader holds `settings.reader.lua` in memory and rewrites it on
flush, so an outside write would be lost or would clobber the user's changes. The companion
only shows the row and opens KOReader at the review page.

---

## 6. How the plugin detects capabilities

### 6.1 Fields

`/status` gains two fields (proto stays "1"; old plugins ignore unknown fields, `I/` "the
fields … may grow"):

```json
{ "mode": "addon", "caps": ["install", "setup", "stats", "relaunch", "sleep_sync"] }
```

| Cap | Meaning | Full | Add-on |
|---|---|---|---|
| `install` | the companion installs and updates KOReader and the plugins | ✓ | ✓ |
| `setup` | `setup_prompt`, `SHOW_SETUP`, `SETUP_LATER` | ✓ | ✓ |
| `stats` | `STATS` is recorded | ✓ | ✓ |
| `relaunch` | a restart is finished by the companion (§7.4) | ✓ | ✓ |
| `home` | the companion is Home: `COMMAND home/home_smart`, `SHOW_LAUNCHER`, `home_opens` | ✓ | — |
| `apps` | `SHOW_APPS` (and 9's `/apps`) | ✓ | — |
| `wifi` | `NET_UP wifi=1`, `WIFI_OFF`, Wi-Fi modes | ✓ | helper |
| `sleep_sync` | `NET_UP` wake lock, `NET_DONE` Wi-Fi-after-sleep | ✓ | helper |
| `screen_off` | `SLEEP_NOW` works: on, **and** device admin granted | ✓ when granted | sub-option, when granted |
| `clicker` | `keymap`, `/clicks` | ✓ | helper |
| `pin` | `pin_locked`, `SHOW_PIN` | ✓ | helper |

### 6.2 The status file, for when the service isn't running

In Add-on mode with no service helper on, nothing answers on 47913 (§7.2). So the companion also
writes **`koreader/settings/orbit-companion.json`**: `{ proto, version, mode, caps,
setup_prompt, written_at }`. It writes atomically (temp file and rename, as the plugin installs
do), whenever the mode, a helper, a permission or the setup rows change. It is written in both
modes, so the plugin has one way to read it.

The plugin's order, in `Shared.refresh` (`O/ko/shared.lua`):
1. `Companion.state()` (`O/ko/companion.lua:76`). If the companion is missing or frozen, there
   are no caps; a leftover file is ignored.
2. Read the file: mode, caps, setup_prompt.
3. If caps include a service cap (`wifi`, `sleep_sync`, `clicker`, `pin`, `home`), call
   `/status` as today for the live fields. Its `mode`/`caps` win over the file's.
4. **No file and `/status` answers without `caps`** (an older companion): legacy, every cap on,
   today's behaviour exactly.
5. The last caps seen are cached in `S.companion_caps`, so `silentWifiOn` and the other
   load-time hooks (`O/ko/wifi_backend.lua:106`) decide before the first refresh.

### 6.3 One check in the plugin

`Companion.has(cap)` replaces `Companion.installed()` at the ~25 call sites that mean a feature,
not the package (§2). `installed()` stays for "Open Orbit Companion" and the status line. Each
site keeps its existing no-companion branch (`I/` "Without the companion"), now taken whenever
the cap is missing.

### 6.4 What the plugin shows for a missing feature (mockup 6)

- **Settings rows that need a missing cap are hidden**, never greyed, except a single line at the
  bottom of each affected section: "Wi-Fi switching and sleep sync: in Orbit Companion ›" (Add-on),
  or "Needs Orbit Companion" (plugin only). Opening it starts the companion's Settings at that
  helper.
- **Actions that are still reachable** (a gesture, a Dispatcher action, a clicker) degrade:
  - *Sync and sleep* without `screen_off`: syncs, then "Synced. Press the power button to
    sleep." plus, once per device, "Orbit Companion can do this for you ›".
  - *Other apps* without `apps`: "Use your reader's Home button for other apps."
  - Home at BookOrbit home without `home` (`O/logic/home_plan.lua:27` returns `"companion"`):
    becomes `"stay"`. BookOrbit home is the top; Android's Home key goes to the vendor launcher.
- **Never an error box**, never a broadcast to a feature that is off (§7.1 drops them anyway).

---

## 7. The companion in Add-on mode

### 7.1 Broadcasts are routed by capability

`CommandReceiver` (`C/OrbitService.kt:38-43`) stops starting the service for everything:
- **Service actions** (`NET_UP`, `NET_DONE`, `WIFI_OFF`, `SLEEP_NOW`) go to the service only
  when their cap is on; otherwise they are logged once and dropped. `NET_UP` without `wifi` but
  with `sleep_sync` takes the wake lock and leaves Wi-Fi alone.
- **Record actions** (`SETTINGS`, `STATS`, `SETUP_LATER`, the new `REPORT`) are stored by the
  receiver itself (`goAsync`, a short prefs/file write), without the service.
- In Full mode nothing changes: every cap is on, so every action reaches the service as today.

### 7.2 No service unless a helper needs one

- Add-on with no service helper runs **no foreground service and shows no permanent
  notification**. Battery-unrestricted rows then aren't needed, which is one reason for fewer
  steps.
- Companion update checks run from a daily **`JobScheduler` job** with a network constraint,
  calling the existing `Updater.maybeAutoCheck` (`C/Updater.kt:75`). It also runs when the
  companion is opened. The update-ready notification is unchanged.
- The setup evaluation (`Attention.evaluate`) runs on the same job, on `MY_PACKAGE_REPLACED`,
  on `REPORT`, and when a companion page opens. It posts the notification and rewrites the
  status file.

### 7.3 Plugin reports (`REPORT`, new)

The plugin sends `REPORT` at start, after a recommended pass, and after sign-in changes:
`signed_in` (`"1"`/`"0"`, from `isLoggedIn()`, `B/main.lua:283`), `recommended`
(`none`/`partial`/`applied`/`reviewed`), `conflicts` (a count). These tick the two new rows. The
companion still never learns the server, the user or the key. It does learn one yes/no about
the login (one-way door 2).

### 7.4 Restarts without the Home role

Today a restart works because `HomeActivity` is the visible window when KOReader quits, which
lets the companion start KOReader from the background (cache-appswitch "Android constraints").
Add-on has no such window. Instead:
- v0.11.1: an update the user started restarts at once (book or not; the book reopens). An
  automatic one never restarts in front: with KOReader in the background the plugin saves and
  quits, and the new plugin loads at the next start; at screen-off it waits, since nothing can
  start KOReader again ([reading gate](reading-gate.md)).
- Before quitting, the plugin itself starts the companion's translucent relaunch activity with
  `Jni.startActivity` (allowed: KOReader is in front). That activity, now the visible window,
  starts KOReader when the process has gone. If 9's `CurtainActivity` (cache-appswitch A5) has
  landed, it *is* that activity; otherwise a minimal one ships with this item.
- Plugin only: as today without the companion, "Close KOReader and open it again to finish."

### 7.5 What Add-on never does

It never asks for the Home role: `HomeActivity` is **disabled as a component** in Add-on
(`setComponentEnabledSetting`), so Orbit isn't even a Home choice. It never asks for device admin
or accessibility unless the user switches on the helper that needs it. It never sends `home`
commands, never shows the launcher page, never starts KOReader at boot, and never changes Wi-Fi
or holds a wake lock unless a helper is on.

---

## 8. Switching modes (mockup 7)

Settings › **Mode** opens a page that says what will change, then does it in one go.

**Full → Add-on**
1. **Lists the changes:** Home goes back to your reader's launcher; Orbit stops switching Wi-Fi
   and keeping the reader awake for sleep sync; the lock-screen permission is released; the
   clicker service and PIN stop, unless you keep them below.
2. **Keep helpers:** one checkbox per helper, each preset to **off**. A parent who wants the PIN
   kept ticks it.
3. **"Switch to Add-on"** then:
   - checks that another Home app exists (`Pin.homePackages`, `C/Pin.kt:179`); if none, it
     refuses and says why;
   - disables `HomeActivity` (Android falls back to the other launcher, or asks once);
   - releases device admin (`DevicePolicyManager.removeActiveAdmin` on its own component) unless
     the screen-off sub-option is kept;
   - stops the accessibility service with `AccessibilityService.disableSelf()` unless Clicker or
     PIN is kept; if the service isn't connected, it opens Accessibility settings with one line
     of instructions;
   - leaves the Orbit keyboard enabled if it was (Android allows no app to disable an input
     method); it is inert without a Send-key mapping, and the page says how to turn it off;
   - cancels the Wi-Fi timer, releases any wake lock, leaves Wi-Fi as it is, and stops the
     service when no kept helper needs it;
   - rewrites the status file, so the plugin sees the new caps on its next refresh (start,
     resume, menu open).
4. **In KOReader**, the plugin handles the caps it lost:
   - `ko.wifi_on`, when Orbit set it, is undone through the backup (§5.6), because nothing
     switches Wi-Fi any more.
   - `g.apps` (other apps) is undone if Orbit set it and the user hasn't changed it.
   - Every other recommended setting stays: they are about reading, not the mode.
5. A summary: "Now in Add-on mode. Home opens <launcher>." with any step that needs the user
   (accessibility, keyboard).

**Add-on → Full**
1. Lists the changes: Orbit becomes the Home app and asks for the permissions Full needs.
2. Re-enables `HomeActivity`, sets `mode=full`, starts the service, writes the status file.
3. Opens Setup on the Full checklist; "Fix next" walks the new rows (Home app, battery, lock
   screen, …).
4. The plugin's next pass picks up the newly available items (`ko.wifi_on`, `g.apps`) under the
   §5.1 rule.

Both directions are idempotent: running a half-finished switch again completes it.

---

## 9. How Add-on changes the related designs

**8b menus** (draft):
- §4.4 *Orbit settings*: "Sync & Wi-Fi" shows Wi-Fi mode, idle minutes and Sleep sync limit only
  with `wifi` / `sleep_sync`. "Sync and sleep now" stays (it degrades, §6.4). "Buttons › Clicker
  buttons" needs `clicker`. "Home button goes to" stays: it is KOReader's own Home behaviour. "Apply
  recommended settings / gestures" become one row, **Recommended settings ›** (§5.5).
- §5 *Gestures*: "Tap top-left → nothing" joins the one recommended list as `g.no_flip`. 8b's
  "applied only when tapped, never silently" is **replaced** by §5.1: applied automatically
  only at default, with a backup, a visible line and undo.
- §6 *Rollout*: `clean_menus` follows §5.2 (`o.clean_menus`) rather than "on for new installs".
  On an untouched KOReader it is on; on a customised one it is offered for review. On existing
  readers already set up, the 8b one-way door 1 still decides (they are Full and their first pass treats
  it the same way).

**7 / 9 cache and app switches** (draft):
- A1 *Home never shows the companion* and A6 *Boot straight into KOReader*: Full only (`home`).
- A2 *Other apps inside KOReader*: Full only (`apps`). In Add-on the entry is hidden and Home at
  BookOrbit home stays put (§6.4).
- A3 *The Device page*: shown in both modes, with mode-dependent rows:
  - Full: as designed.
  - Add-on: **Mode** (Add-on · Switch ›), the four helper switches, the update row, the Setup row,
    and "More in Orbit Companion ›". *Home opens*, *Wi-Fi after sleep* and the Wi-Fi rows appear
    only with their caps. Helper switches that need an Android permission go through A3a's
    `FixActivity`.
  - Plugin only: hidden, replaced by "Get Orbit Companion for installs, updates and device
    helpers".
- A4 *PIN keypad in KOReader*: needs `pin`.
- A5 *Curtain and restarts*: in Add-on, the plugin starts the curtain itself (§7.4). "Restart at
  screen-off" does not apply, because no window can start KOReader then.
- C4 *The companion's hint* (cache): it needs the service. In Add-on without one, the plugin's own
  walk covers it (C1). That is a slower path, not a loss.

---

## 10. Mode for each device

| Device | Mode | Why |
|---|---|---|
| Readers where Orbit is already Home (Full set up) | Full | the companion is already Home; the PIN and the launcher matter |
| A new reader whose owner keeps the vendor launcher | Add-on (their choice on first run) | keep their launcher; Orbify installs and configures KOReader and the plugins |
| KOReader with the Orbit plugin only | plugin only | reading features; no installs or device helpers |

No device changes mode at the update (§4.1).

---

## 11. Failure handling

| Case | Behaviour |
|---|---|
| No other Home app when switching to Add-on | refused: "Your reader has no other Home app, so Orbit has to stay Home." |
| `disableSelf()` not possible (service not connected) | opens Accessibility settings with "Turn off Orbit clicker" |
| Device admin removal fails | the row stays, with "Settings › Security › Device admin apps" |
| Status file missing, unreadable or half-written | the plugin ignores it and falls back to `/status`, then legacy (§6.2); written by rename, so a half file doesn't happen in practice |
| Status file left by an uninstalled companion | ignored: `Companion.state()` says missing |
| Older plugin with a new companion in Add-on | it sees the companion installed and sends `NET_UP`; the receiver drops it (§7.1), so its sync waits for Wi-Fi as stock KOReader does. The companion installs the matching plugin on its own update anyway (`O` design "One update"). |
| BookOrbit plugin not loaded during a pass | its items are unavailable; re-evaluated on the next start where it loads |
| Gestures plugin off | gesture items unavailable, with today's message |
| `Compat.settable` refuses `catalog_auto_open` | unavailable, logged (`O/ko/recommended.lua:23-27`) |
| The user changes a setting after Orbit applied it, then taps Undo | that row is left as is: "changed since; left as is" |
| KOReader from F-Droid or the Play Store | the KOReader row explains, as today (`D/` one-way door 1, `S/` "Which KOReader?"). Whether the F-Droid flavour loads `koreader/plugins/` is **unverified**: `adb shell pm list packages | grep -i koreader`, then check whether `orbit.koplugin` appears in that build's Plugin manager. |
| A crash in Add-on | KOReader is not restarted (no Home role); the user opens it from their launcher, and `open_book_at_exit` reopens the book (unchanged) |

---

## 12. Tests

**Plugin, `test/test_logic.lua`** (new pure `logic/recommended.lua`):
- state of an item: already / at default / conflict / unavailable, for a BookOrbit key, a
  gesture (table defaults, using `tableEquals` semantics) and a KOReader global;
- fresh KOReader: every available item applied, the line says N;
- customised KOReader: at-default items applied, conflicts listed, nothing changed overwritten;
- `o.clean_menus` is at default only when no conflicts are found;
- a later release adds one id: only that id is evaluated; kept and skipped items stay put;
- a capability appears (helper on): only the unblocked items are evaluated;
- backup and undo round trip; undo leaves a value the user changed since;
- the same results with mode `full`, `addon` and no companion (the mode is not an input).

**Plugin, `test/test_flows.lua`**:
- caps from the file only; from `/status` only; both (`/status` wins); neither with an old
  companion (legacy: all on); missing companion with a leftover file (no caps);
- each degraded action in §6.4 shows its message and sends no broadcast;
- every row of the §3.1 table, with the permission missing: the feature falls back as listed,
  shows its note at most once, and raises no error box;
- Home at BookOrbit home without `home` stays;
- `silentWifiOn` without `wifi` leaves `wifi_enable_action` alone, and with `wifi` records a
  backup;
- Full → Add-on caps change undoes `ko.wifi_on` and `g.apps` only.

**Companion, unit tests** (new pure `ModeLogic`):
- checklist rows per mode and per helper set (Add-on with no helpers has no battery, admin,
  Home or Wi-Fi-test rows);
- Add-on: exactly the four required rows are counted, walked by Fix next and prompted; every
  optional row is `INFO_ONLY`, so declining or later revoking one never sets `setup_needed`,
  never notifies, and never fills `setup_prompt`;
- each optional row's text: "Without it: …" when never allowed, "Off: …" after a decline, "On: …"
  when allowed;
- caps per mode, helper and permission (`screen_off` needs admin granted);
- receiver routing: each action × each cap set → service, record, or drop;
- switch plans in both directions, including refusals (no other Home app), and that running a
  plan twice is a no-op;
- existing-install migration: Home role or a Full-only step → Full; else unset;
- `SetupAttention.idOf` for the new rows ("Signed in to BookOrbit", "Recommended settings").

**On the reader** (acceptance, 5 in a row each): fresh Add-on install on a Boox keeps the Boox
launcher and ends with KOReader opening into BookOrbit home, settings applied; a customised
KOReader keeps every changed value; Full → Add-on → Full leaves a Full setup working.

---

## 13. Slices

Each is small enough for one brief, and ships on its own.

1. **Recommended settings engine** (plugin only). `logic/recommended.lua`, the review page, the
   applied line, backup and undo; `silentWifiOn` and the two menu entries go through it; a pass
   on first setup and on the update. *Answers request 2 for every device, before any mode work.*
2. **Capabilities** (both sides, no behaviour change). `mode`/`caps` in `/status`, the status
   file, `Companion.has(cap)` at every call site, legacy fallback. Full stays exactly as it is.
3. **Plugin reports and the new rows.** `REPORT`, "Signed in to BookOrbit" and "Recommended
   settings" in the Full checklist, `COMMAND=signin` and `COMMAND=recommended`.
4. **Add-on mode, core.** The first-run choice, existing-install migration, `HomeActivity`
   disabled, receiver routing, no service, the daily job, the Add-on checklist (four required
   rows; optional rows as "Without it / Off / Allow", all `INFO_ONLY`), reminders only for
   required rows via the box and the notification, the relaunch activity, and every §3.1
   fallback.
5. **Add-on helpers.** The four switches and the screen-off sub-option, each with its rows.
6. **Switching modes**, both directions.
7. **Docs.** `S/` gets an Add-on section; `I/` gets caps, the status file and `REPORT`;
   `docs/FEATURES.md` gets its rows when each slice ships.

Order: 1 first (independent), 2 before 3–6, 4 before 5 and 6.

---

## 14. Self-grill log (two-way doors, settled)

| # | Question | Options | Decision | Why |
|---|---|---|---|---|
| 1 | Should recommended-settings behaviour depend on the mode? | by mode / by KOReader's state | **By KOReader's state, the same in both modes** | User ruling (revision note). Add-on still installs KOReader fresh in most cases. |
| 2 | How do we tell "the user changed it" from "default"? | a snapshot at install / compare with the stock default per item / a "fresh KOReader" flag | **Per-item compare with the stock default, read at run time** | It is exact per setting, works for a KOReader that predates Orbify, and reuses upstream's own default tables (`B/main.lua:102`, `K/gestures main.lua:310`). A global "fresh" flag would either overwrite one changed gesture or skip everything. |
| 3 | In a conflict, ask or skip? | overwrite / skip silently / list for review | **List for review, change nothing** | User ruling: never overwrite; "apply / keep mine". |
| 4 | Ask before applying at-default items? | ask / apply and say so | **Apply, show one line with Review and Undo** | The user asked for it to happen at setup; undo makes it safe; a question per item is an intervention. |
| 5 | Re-run on every start? | every start / first setup + new ids + new caps | **Only first setup, new ids, newly available items** | Re-running would fight a user who changes a setting by hand later. |
| 6 | Where do the settings get written? | companion edits files / plugin applies | **Plugin, in KOReader** | KOReader rewrites `settings.reader.lua` from memory (§5.7). |
| 7 | Keep "further behind: Don't sync" in the list? | keep / drop | **Drop** | It is BookOrbit's default; it can only be a conflict, and conflicts aren't overwritten. |
| 8 | Is `wifi_enable_action` a recommendation? | always / only with Wi-Fi switching | **Only with Wi-Fi switching, then required** | On Android, BookOrbit's auto-sync doesn't need it (`hasSeamlessWifiToggle = no`); without a switcher "turn on" just opens Settings. |
| 9 | Clean menus in the list? | Orbit default on / offered | **In the list; at default only when KOReader has no conflicts** | A customised KOReader is exactly where replacing menus surprises people; an untouched one gets the simpler menus. |
| 10 | How does the plugin learn the caps when no service runs? | always run the service / a status file / a content provider over JNI | **A status file in `koreader/settings/`, plus `/status` for live fields** | No permanent notification in Add-on; the companion already writes into `koreader/`; a provider would need new JNI code. |
| 11 | What does a missing `caps` field mean? | nothing works / everything works | **Legacy: everything, as today** | Only older companions lack it, and those are Full by construction. |
| 12 | How does Add-on give up Home? | ask the user to change Home / clear preferred activities / disable `HomeActivity` | **Disable the component** | Works on every Android version, can't leave a dangling default, and keeps Orbit out of the Home chooser; reversible. |
| 13 | Service in Add-on? | always / only with helpers | **Only with helpers** | "Wouldn't manage Wi-Fi or sleep or anything"; fewer setup steps (no battery rows); update checks move to a daily job. |
| 14 | Helper granularity | one "device helpers" switch / one per feature | **Four switches and a screen-off sub-option** | Each needs a different Android permission; an owner may want only the clicker. |
| 15 | Helpers kept when switching Full → Add-on? | keep all / drop all / ask with all unticked | **Ask, all unticked** | Matches "off by default"; a parent can keep the PIN in one tap. |
| 16 | Tailscale row in Add-on? | step / info | **Info, only if installed** | Only private servers need it, and the plugin wakes Tailscale itself. |
| 17 | Reminders without the Home prompt | new channel / the existing KOReader box + notification | **Existing box + notification**, fed from the status file | Both exist (`O/ko/home.lua:500`, `C/Attention.kt`); nothing new to learn. |
| 18 | Restarts after an update in Add-on | at screen-off / while KOReader is in front, via an activity the plugin starts | **In front, via the relaunch activity** | A background start is blocked without a visible window (Android 10+); 9's curtain is the same activity. |
| 19 | Home at BookOrbit home in Add-on | open the vendor launcher / do nothing | **Do nothing** | Android's Home key already goes to the vendor launcher; there's no companion launcher page in Add-on. |
| 20 | The default mode on the first-run page | preselect Full / preselect Add-on / none | **None** | One tap either way, and it makes people read both. |
| 21 | Existing installs | show the choice / infer | **Infer Full** from the Home role or Full-only steps | No reader already set up changes; the user rules out prompts that aren't needed. |
| 22 | A mode flag in `tools/install-usb.sh` | now / later | **Later** | The on-device choice covers it; a flag is easy to add. |
| 23 | Which Add-on items are required? | everything Full needs / installs only / installs + sign-in | **KOReader, BookOrbit plugin, Orbit plugin installed, and signed in** | User ruling: required stays minimal. Without sign-in, nothing syncs, so it is the one non-install item. Recommended settings apply by themselves, so they're a status, not a step. |
| 24 | Is "Install unknown apps" required in Add-on? | required / optional | **Optional** | The owner may already have KOReader, or prefer to install it themselves; updates then fall back to a download link. |
| 25 | Storage access: its own row? | a row / asked at plugin install | **Asked at install, no row** | It is only needed by the install itself; the copy-by-hand fallback is on the plugin rows. |
| 26 | A permission the user granted and Android later revoked (e.g. a vendor kills accessibility) | prompt as a regression / calm Off | **Calm Off** in Add-on | User ruling: nothing nags. Full keeps today's regression prompts. |
| 27 | Wording of optional rows | fixes ("Allow X") / losses ("Without it: …") | **Losses, with Allow as the button** | User ruling. |
| 28 | Name | Add-on / Lite / Companion-only | **Add-on** | It is what the user called it; it says "beside your setup", not "less". |

---

## 15. One-way doors (answered yes, 2026-11-22)

Each is written so that "yes" accepts my recommendation.

1. **Existing readers get recommended settings applied once, at the update, and new items in
   later releases the same way.** This covers every reader already set up.
   On each, Orbit applies only the items still at KOReader's or BookOrbit's default (for example
   auto-sync on, Silent when BookOrbit is ahead, KOReader opening into BookOrbit, the corner
   gestures). It never changes a value someone set, lists those to review instead, shows "Applied
   N recommended settings · Review", and keeps a backup for Undo. Behaviour on those readers
   changes without anyone tapping anything. **Recommended: yes.** Asking first on every reader
   would be an intervention per device; Undo makes it safe.
2. **The companion learns one yes/no: whether the BookOrbit plugin is signed in.** Your ruling
   says the companion never holds or knows the login. It still would never see the server, the
   user or the key; the plugin sends only `signed_in=1/0`, so Setup can tick "Signed in to
   BookOrbit" and remind someone who never signed in. **Recommended: yes.** If no, the row
   moves into the plugin only, and the companion's checklist ends at "Orbit plugin answered".

---

## 16. What shipped in 0.11.0, and what waits

| Slice | Shipped | Code |
|---|---|---|
| 1. Recommended settings engine | yes | `O/logic/recommended.lua` (pure), `O/ko/recommended.lua` (reads, writes, review page); `silentWifiOn` and the two menu entries go through it |
| 2. Capabilities | yes | `O/logic/caps.lua`, `Companion.has` in `O/ko/companion.lua`; `C/ModeLogic.kt`, `C/StatusFile.kt`, `mode`/`caps` in `/status` |
| 3. Plugin reports and the new rows | yes | `REPORT` (`Rec.report`), `COMMAND=signin`/`recommended` (`O/ko/home.lua`); `C/StatusFile.kt onReport`, two rows in `C/Pages.kt` |
| 4. Add-on core | yes | `C/Mode.kt` (migration, Home component, daily job, relaunch window), `AddonLogic` in `C/ModeLogic.kt` (routing, required rows, optional rows) |
| 5. Helpers | yes | Settings › Helpers (`C/Pages.kt`), `Mode.helpersChanged` |
| 6. Switching modes | yes | `ModeActivity`, `AddonLogic.toAddon`/`toFull`, `Mode.apply` |
| 7. Docs | yes | `I/`, `S/`, `docs/FEATURES.md` |

Waits for a later release (each is a fallback the design lists, not a lost feature):
- §3.1 "Install apps" declined: the KOReader row's "Install it yourself" link and a browser
  "Download" for companion updates. Today the KOReader row asks for the permission, as in Full.
- §3.1 Notifications declined: the required-step text on Orbit settings' status line in KOReader
  is there (setup_needed), but the update-ready text is not mirrored into KOReader.
- §6.4: the one-line "Wi-Fi switching and sleep sync: in Orbit Companion ›" opens the companion's
  main page, not its Settings at that helper.
- §8 step 2 in Add-on: Settings › Mode's "Keep helpers" keeps Sleep sync and Screen off together
  (one checkbox).
- §9's changes to the 8b menus and the 7/9 cache designs, which are not built yet: `g.no_flip`
  and `o.clean_menus` join `Recommended.ITEMS` with them (the engine's `untouched_only` rule for
  `o.clean_menus` is built and tested).

## 17. Self-grill log while building (two-way doors, settled)

| # | Question | Options | Decision | Why |
|---|---|---|---|---|
| B1 | KOReader's own "prompt" for `wifi_enable_action` | conflict / default | **Default**, like unset | KOReader reads `or "prompt"` (`K/frontend/ui/network/manager.lua:1007`): picking "Ask" in the menu stores the stock value. |
| B2 | The review page widget | BookOrbit's kit / KOReader's `Menu` + `ButtonDialog` | **`Menu` + `ButtonDialog`** | The design allows the plain fallback; fewer BookOrbit internals to track. Both are in `test/koreader_compat.lua`. |
| B3 | The 4 s line: tappable to open the review? | tappable toast / toast + menu row | **Toast naming the menu path, and the menu row keeps the line** | KOReader's `InfoMessage` has no tap action distinct from dismiss; the menu row holds the same text until the page is opened. |
| B4 | Undo after the user changed the value | restore anyway / leave | **Leave, row moves to Kept yours** | Design §5.6; "changed since; left as is". |
| B5 | Undo all and KOReader's Wi-Fi action while Wi-Fi switching is on | turn switching off too / skip it | **Skip it and say why** | Undo all must not silently turn a feature off; the per-row Undo asks. |
| B6 | Caps lost when the companion is only frozen or uninstalled | undo Wi-Fi action and apps gesture / wait | **Undo only when the companion itself reports new caps** (status or file) | A vendor freeze is temporary; undoing and re-applying on every freeze is noise. |
| B7 | A plugin self-update with no companion | quit KOReader (as before) / ask | **Ask once: "close KOReader and open it again"** | §3 row "Restart KOReader after an update"; nothing could start KOReader again. |
| B8 | Where migration runs | a one-off at the update / every service start while unset | **Every `OrbitService.start` and the Setup page, while the mode is unset** | Cheap; covers update, boot and first open in any order. Add-on is only ever set by the user's tap. |
| B9 | SETTINGS and STATS in Add-on with no service | start the service for them / record what matters | **Record what matters (book open/closed for restarts); drop the rest** | No permanent notification in Add-on (§7.2). Battery stats need the service's recorder, so they run only while a helper keeps it. |
| B10 | The PIN in Add-on without its helper | clear it / keep the hash, enforce nothing | **Keep the hash, enforce nothing** | Turning the helper back on restores the same PIN. |
| B11 | The first-run choice: where | its own page / inside Setup | **Its own page (`ModeActivity`), opened by Status and Setup while unset**, with "Later" | Matches mockup 1; Settings › Mode reuses it. |

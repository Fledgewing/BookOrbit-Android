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
launcher page (both modes); any other BookOrbit screen (v0.4.9) → BookOrbit's main page;
a BookOrbit page past its first with nothing over it (v0.5.4: the dashboard's page 2, a list's
page 3) → its page 1 first, by the plugin's own paging (`boardPage`/`boardFlip`,
`listMode`/`listPaging`/`listGoPage`, `Compat.PAGING`; without them the old rule);
elsewhere with a current book (still open, or closed by Home
itself, `home_book`) → the book; elsewhere with none → BookOrbit home; cold start after KOReader was killed
with a book open (`open_book_at_exit`) → that book. Presses step book → BookOrbit home →
companion; Home from another app goes to the book, so the steps never loop.

"Which BookOrbit screen" (v0.4.9, `bookorbitScreen`) comes from `UIManager._window_stack`,
never a flag: the main page is the catalog widget topmost and in `dashboardMode` (plugin 2.3.0
bookorbit_catalog.lua:1875). Anything else with the catalog visible is a sub-screen: the
catalog switched in place to another mode (`current_context.kind`: books, detail, lists,
search, board…), or the plugin's widgets over it (its dialogs, book sheet, settings, menu
pages and main menu sheet). Home then closes what is over the catalog (each by its
`close_callback`, else `UIManager:close`), calls the catalog's `goDashboard`
(bookorbit_catalog.lua:530-537, also its hold-Return), and if that is missing or something is
still over it, closes the catalog and opens BookOrbit home fresh through the plugin's event.
The file browser or a book over the catalog is not BookOrbit (v0.4.6: brought back on top).
CI's plugin_compat checks `goDashboard`, `dashboardMode`, `close_callback` and `current_context`. "From another
app" is the companion's `FROM=other_app` when it knows, else a KOReader pause of 2.5 s or more.

## Home opens (v0.3.2, v0.4.8)

The "Home opens" setting is companion-only; the patch only sees its kind (`/status`
`settings.home_opens`) to label its Home button entry. Its choices:
- KOReader + BookOrbit, the default (`""`): Smart Home as above. Only then does Settings show
  the Home button choice, titled "In KOReader, Home goes to".
- Orbit launcher page (`orbit:launcher`, v0.4.8): Home shows the companion's launcher page.
  It replaces the toggle "Home always opens …" (`home_opens_koreader`), whose off position
  did this; `Prefs.homeApp` migrates `false` to it once (`HomeApp.migrate`).
- Any launchable app: the picker lists known reader apps first (`KnownApps.READERS` plus the
  vendor profile's `readerPkgs`), then the rest A–Z.

With another app chosen:
- A Home press, a boot, or Home coming back uncovered starts that app's launch intent with
  `NEW_TASK | RESET_TASK_IF_NEEDED`, so it resumes where it was.
- It gets no COMMAND extras; `HomeApp.launch` is unit-tested.
- `HomeDecider` is target-neutral, so a double Home still shows the launcher page, and a
  missing, disabled or crashing app falls back to the launcher page.
- The launcher page shows the chosen app as its big first tile, with KOReader still a tile.
- The patch's features (sync on sleep, Just in time Wi-Fi, BookOrbit home) work only inside
  KOReader; Settings says so in one line.

## Clicker buttons (v0.4.0)

Design and decision: [BTKEYS-DESIGN.md](BTKEYS-DESIGN.md). The companion keeps one key map
per clicker profile (InputDevice name + vendor/product ids). Each mapped button has an action
for press, and optionally for hold (0.6 s) and double press (0.35 s).
- **KOReader:** the patch gets the map in `/status` and turns pages exactly. No permission is
  needed.
- **Other apps:** the `ClickerService` accessibility service handles the map. It does key
  filtering only and cannot read window content. It acts only on mapped keys from captured
  clickers, and sends taps on per-app zones (`Vendor.kt` defaults, user overrides), Home,
  Back and Sleep.
- **Setup row** "Clicker buttons (accessibility)", only once a clicker is mapped:
  - done = enabled in Android and connected;
  - a freeze or force-stop is a regression, which feeds "Setup needs you";
  - an info row names Key Mapper (or another key filter) when one is on.
- **One path (v0.4.2):** with the service on, KOReader's mapped keys go through it too; it
  sends the action over `/clicks` and the patch does it exactly. The patch's own key path is
  the fallback when the service is off ([BTKEYS-DESIGN.md](BTKEYS-DESIGN.md#one-path-v042)).
- **Per-app actions (v0.4.1):** a default action per button and kind, and any app can
  override the action itself ("+ Override for another app": app → action → tap zone for page
  actions). KOReader's override decides the patch's `keymap`.
- **Send key (v0.4.1):** Send Volume up/down and Send key… (Page up/down, arrows, Space) go
  through the Orbit keyboard (`OrbitKeysIme`), switched in just for the press by the
  accessibility service and switched back; skipped while a text field is focused; "Keep Orbit
  keyboard active" when switching fails. Setup row "Orbit keyboard enabled" only while one is
  mapped. Details and the volume-key findings: [BTKEYS-DESIGN.md](BTKEYS-DESIGN.md#send-key-v041).

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
- **Delivery:** the prompt on the status page, a notification, a one-line banner on the
  launcher page, and `setup_needed` in `/status` for the patch's menu status. Nothing shows
  when all is done; nothing pops up in a book.
- **Showing up when it matters (v0.4.1).** The companion's own pages are rarely seen (Home goes
  straight to KOReader), so:
  - *At the moment of cause:* a change in the companion that makes a new row needed (the first
    mapped clicker button needs the accessibility service; a Send-key action needs the Orbit
    keyboard) opens the prompt at once, with that row first (`SetupAttention.caused`).
  - *Home press:* a new unsnoozed row shows the prompt once before KOReader; closing it goes on
    to KOReader (`SetupAttention.homePrompt`).
  - *In KOReader:* `/status` carries `setup_prompt` (the unsnoozed rows) and the patch shows a
    one-time box, "Orbit Companion needs 1 setup step: … Fix now / Later", only off a book (file
    browser, BookOrbit home, its menu): at start, resume, Home and on reaching BookOrbit home.
    Fix opens the prompt (`SHOW_SETUP`); Later is the companion's Later (`SETUP_LATER`).
  - *Notification:* channel "Setup steps" at default importance (the old low-importance
    channel hid it from the status bar); each post logs whether notifications are allowed and
    the channel's importance, since vendor ROMs may block them.
- **In-app fixes** (the patch install opens no system page, so no `onResume` follows) re-check
  the rows when they finish. A done row leaves the prompt; with none left it says "All set"
  and closes. The Fix button reads "Installing…" and does nothing while an install runs.
- **Patch row** (`PatchRow`): the installed file's `PATCH_VERSION` decides "outdated"; when the
  file is current but the running patch (its `patch_version` in broadcasts and the `/status`
  ping) is older, the row is "Restart KOReader to finish". That is pending, not a "needs you"
  item (not counted, no notification), with a "Restart KOReader" button (COMMAND `restart`)
  when the running patch knows it, else the recent-apps hint. It clears when the new patch
  reports in.
- **After an update:** a one-screen "What's new" from a short per-version list in the app
  (`WhatsNew`), with any needed steps.

## Settings PIN (v0.4.4)

Kid-proofing, modelled on the Xteink settings PIN (touch keypad). Optional, off by default.

- **Storage:** `Prefs.pinHash` = `pbkdf2-sha256$iterations$salt$hash` (20 000 rounds, 16-byte
  salt) in the app-private prefs; the back-off (failures, locked-until) too. Never the PIN,
  never logged. The unlock window is memory only, so a restart locks (`Pin`, `PinLogic.kt`).
- **Live state (v0.4.6):** one `PinGate` per process holds PIN set, the guard list and the
  unlock; set, clear and Guarded apps change it directly, so the very next window change is
  gated (0.4.4 only noticed after a restart, because setting the PIN also unlocked it).
- **Unlock (v0.4.8):** holds while the user is inside what it covers: the companion's
  protected pages (`PinPage.PROTECTED`), the packages in its scope (the guarded app it was
  entered for, `SHOW_PIN`'s KOReader, any page started from the unlocked flow through
  `EinkActivity.tryStart`: Setup Fix targets, pages opened from Settings) and any guarded
  app. Leaving (an open companion page, or the accessibility service seeing KOReader, Home or
  another launchable app; overlays and system windows don't count) starts a 2-minute grace
  (`PinGate.GRACE_MS`): coming back inside it needs no PIN and ends the grace, leaving again
  starts a fresh one, and when it runs out it locks. `ACTION_SCREEN_OFF` locks at once. The
  15-minute hard cap applies only while the accessibility service is off (`PinGate.watching`).
  Wrong tries (`PinBackoff`): 5 free, then 30 s doubling to 5 min, kept across restarts.
- **Locked pages:** `EinkActivity.pinGuarded` (Settings, Home opens, Clicker buttons and its
  capture and action pages, Guarded apps): a locked resume opens the keypad, Cancel closes
  the page. Actions (`Pin.run`): the launcher's Android Settings tile, Check for updates on
  the status page, turning the PIN off, Setup's Fix buttons (`Pin.fix`). The update-ready
  notification opens the keypad first (`PinActivity.thenInstall`); the install prompt itself
  stays in memory, never in an extra. The launcher and status pages are never gated.
- **App guard** (`ClickerService` → `Pin.onForeground` on each window-state change, logging
  package/activity and the decision): a PIN set, locked, and a guarded entry in front → the
  full-screen keypad on top, Cancel goes Home. Entries are a package, or `package/activity`
  for one screen. Android Settings by default: the screens `ACTION_SETTINGS`,
  `ACTION_APPLICATION_DETAILS_SETTINGS` and similar resolve to, plus `com.android.settings`;
  a vendor package is guarded whole only when it has no Home role and isn't system UI
  (`Guard.settingsEntry`; a Boox resolves Settings into `com.onyx`, its launcher too, so only
  that screen is guarded). The user adds any launchable app except a launcher. Never: the
  companion, KOReader, dialer/telecom/emergency and system UI. **Install window (v0.5.0):**
  from the moment the user starts an update (or the companion starts any install) until the
  install session ends plus 60 s (`PinGate.installStarted/installEnded`, `Guard.INSTALL_GRACE_MS`;
  a session that never reports stops counting after 30 min), the screens an install needs are
  never covered (`Guard.installSurface`): the package installer and permission controller
  (AOSP, Google, and vendor `*.packageinstaller` / `*.permissioncontroller`) and Play
  Protect's dialogs, matched by activity (`com.android.vending` `…finsky.protectdialogs.*`),
  even when the Play Store is guarded; when the event names no Play Store activity, the
  package passes for the window only, and the store's own pages stay guarded. Outside the
  window Play Protect is gated like the rest of the Play Store. **Background popups (v0.5.3):**
  the keypad shows only when the user opens a guarded app: it comes to the front from a
  launcher, recents (system UI) or the companion, or within 2 s of a tap there (accessibility
  click events, package only). A guarded activity appearing over KOReader or another app with
  no such tap (the Play Store's own update or scan UI) is sent back with
  `GLOBAL_ACTION_BACK`, no keypad, nothing unlocked, logged as `pin: background popup from
  <pkg/activity> dismissed` (`Popup`). Reported 11-22 as a keypad "while just reading";
  unconfirmed on a device. Known gap: a link tapped inside KOReader to a guarded app counts as
  a popup too (KOReader's taps produce no accessibility clicks). Seen on a Boox Page 11-22:
  the keypad over `PlayProtectDialogsActivity` failed the update with
  `INSTALL_FAILED_VERIFICATION_FAILURE`, so it took two PINs and two tries. The Setup row "Clicker
  buttons / app guard (accessibility) on" shows while a PIN is set, since the guard needs the
  service.
- **KOReader:** `/status.pin_locked`; the patch's menu shows only "Enter the Settings PIN…"
  and starts `SHOW_PIN`. No answer from the companion → the menu works (`MenuLock.locked`).
- **Recovery:** `RESET_PIN` over adb only: the receiver requires `DUMP` (shell only), and on
  Android 14+ a reported sender uid must be shell or root (`PinReset.allowed`).
- **Known gaps (documented in SETUP):** quick settings in the notification shade, safe-mode
  boot, adb.

## One update (v0.5.0)

One update covers the companion, the patch and KOReader's restart, with one status line.

- **Companion update:** the new process (`MY_PACKAGE_REPLACED` → `Updater.onReplaced`)
  installs the patch from its own release (`PatchInstaller.afterAppUpdate`: the release's
  `SHA256SUMS`, the stamped `PATCH_VERSION`, temp file then rename, as Setup's Install patch
  does) when the installed patch is older; never over a newer patch-only update, and a
  first install stays Setup's step. No prompt.
- **Restart:** the patch (0.5.0+) compares the `PATCH_VERSION` its own file on disk declares
  with the one running (`RestartPlan`). Newer on disk: with no book open it restarts at once
  (at start, resume, or right after our own update); with a book open it waits and restarts
  right after the book is closed (unless another book opened) or when the device next sleeps
  (screen off, after the sleep sync). It never interrupts reading. The restart is the
  existing one (save, `RELAUNCH`, quit; the companion starts KOReader again, the book at exit
  reopens). One try per version (`restart_tried`): a file that still doesn't load is left to
  Setup with the reason, never a restart loop.
- **Status:** KOReader shows "Updated to vX (KOReader restarted)" after the restart; the
  companion's update line says the same once the running patch reports the new version
  (`UpdateFlow`, `Prefs.patchAwaitVersion`).
- **Patch-only update** (patch newer, companion the same): the patch's own updater writes the
  file, then the same restart path runs.
- **The companion restarts too (v0.5.2):** after any patch install it sends `COMMAND=restart`,
  which every patch since 0.3.1 obeys (a 0.4.8 patch did, Boox Page 11-22 01:04), so no
  version needs a manual restart: at once when KOReader has no book open or isn't running,
  else when the book closes (`STATS` reason `close`), on the next Home press or at screen-off,
  whenever KOReader reports no book. Book state: `/status?book=1|0` (patch 0.5.2+) and `STATS`
  `open` (any patch; `suspend` always says 0 and is ignored). Once per version
  (`Prefs.patchRestartSentFor`), so a file that doesn't load never loops (`UpdateFlow.restart`).
- **Any older running patch (v0.5.4):** on every `/status` and at companion start the companion
  compares the running `patch_version` with the file's `PATCH_VERSION`, however the file got
  there (M8C 11-22 ran 0.4.6 with 0.5.3 on disk, put there by an earlier companion, so no
  restart was pending). Older and no book open (`/status?book=0` or `STATS open=0`): restart,
  logged `restart: KOReader runs X, file has Y`. Book open or unknown: after the book, at
  screen-off or the next Home (unknown counts as closed only there). Once per (running, file)
  pair per process (`StaleRestart`), so a version that stays old never loops.
- **No PIN, no false prompt, one notification (v0.5.2):** installing this release's patch,
  restarting KOReader and finishing an update (the update-ready notification) are never behind
  the Settings PIN: they change no setting (`Check.pinFree`). While a patch install or restart
  is under way, Setup doesn't count the patch row as needed, and after an app update Setup is
  evaluated only once the patch step finished; a notification is posted only for steps that
  truly need the user. "What's new" is a line on the status page ("What's new in vX ›"), never
  a notification. 11-22 01:04 the user saw "1 setup step needs you" for the patch already
  installing, then a what's-new notification, then had to enter the PIN to restart KOReader.
- **An update you start restarts now (v0.5.5):** a check by hand, the update notification's
  tap or Setup's "Install patch" restarts KOReader as soon as the patch is installed, book open
  or not ("if I click update myself that means restart KOReader now", M8C 11-22 01:42, where
  the restart waited for the book through five events). The mark (`Prefs.userUpdateAt`, 30 min)
  crosses the app replace; `Prefs.patchRestartNow` names the version. The patch saves the book
  and keeps it as `restart_book`; the relaunch carries `COMMAND=reopen_book` (for a restart by
  an older patch: KOReader's last file), so it reopens where it was. A background update still
  waits for the book's close, Home or sleep; the wait is logged once per version.
  From v0.6.1 every app replace counts as user-started with no mark: at targetSdk 28 each app
  update needs the user's tap on Android's install prompt, and an old process (0.5.4 and
  earlier) never wrote the mark (M8C 11-22 02:06 waited for the book after an update by hand).
  The mark now only matters for a patch-only update; one found in the background still waits.
- **Setup holds its prompts while an update settles (v0.5.5):** for 30 s after the version
  changes, and while the patch install and restart that follow run, Setup prompts and posts
  nothing (`AfterUpdate`); the patch row is pending, and so is the clicker (accessibility) row
  until its service reconnects after the package replace (it re-evaluates on
  `onServiceConnected` and when the grace ends). Only what is still wrong then prompts.
  11-22 01:42:31 the M8C prompted "needs [patch, clicker]" mid-update.
- **Android's "Install update?" stays:** the companion targets SDK 28 (for
  `WifiManager.setWifiEnabled`), and Android skips that confirm only for apps targeting a
  recent SDK (`setRequireUserAction`, README "Updates"). It is the one tap an update needs.
- **Fallback:** no storage access or a failed download or checksum: the status line gives the
  reason and Setup's KOReader patch row keeps Install patch / Restart KOReader (no PIN).

## Setup installs the rest (v0.5.1)

A new device needs only the companion APK sideloaded; Setup installs the rest, one tap each,
downloading only from the official sources (never re-hosted) and logging source and size.

- **KOReader** (`Installers.koreader`): `koreader/koreader` releases/latest, the asset
  `koreader-android-<arm64|arm|x86>-<tag>.apk` for the first of `Build.SUPPORTED_ABIS` that has
  one (`KoreaderRelease.assetFor`), checked against GitHub's asset `digest` (sha256) and against
  KOReader's signing certificate (`KoreaderRelease.OFFICIAL_CERT`, read from the v2026.07.1
  APK with apksigner), then a PackageInstaller session (the install window keeps the PIN off
  its prompts). The row detects F-Droid's build (`org.koreader.launcher.fdroid`, a separate
  app: KOReader returns before applying user patches on that flavor,
  `frontend/userpatch.lua:27-28` at v2026.07.1) and a KOReader signed by anyone else (Android
  won't update across signers: uninstall first). Installed: the row checks for a newer
  release on tap.
- **BookOrbit plugin** (`Installers.plugin`): bookorbit/bookorbit's releases (v3.0.0–v3.9.0)
  carry no assets, and the plugin's own updater downloads its zip from the user's BookOrbit
  server (`bookorbit_api.lua:778-781` `/koreader/plugin/package`, after login), which a new
  device doesn't have yet. So: the latest release tag's `koreader-plugin/bookorbit.koplugin`
  tree (contents API → tree sha → `git/trees/<sha>?recursive=1`), each file from
  raw.githubusercontent.com at that tag and checked against its git blob id (SHA-1 of
  `blob <size>\0` + content; paths must be relative, no `..`). Written to
  `bookorbit.koplugin.orbit-new`, then old aside, new in, old removed (KOReader loads only
  `*.koplugin` folders). Installed only when missing or older than `PluginRelease.MIN_VERSION`
  (2.3.0, what CI's plugin_compat checks): the plugin's own updater
  (`bookorbit_updater.lua`) owns updates after that. KOReader restarts (`COMMAND=restart`)
  when the running patch can; otherwise the row says to restart it.
- **KOReader patch:** the existing one-tap install, in the same block.
- **Up front** (`DeviceChecks`): Family Link (`com.google.android.apps.kids.familylinkhelper`)
  or a managed device (UserManager restrictions such as `no_install_unknown_sources`, other
  device admins) with what it blocks and "approve it in the parent's Family Link app"; Play
  Protect (Play Store present) with "More details → Install anyway"; the vendor freeze row
  (`Vendor.kt`) says what freezing does and where to undo it. These are tips, not steps
  (v0.5.3, `SetupTips`): never counted in Setup's done/total, "steps need you", the
  notification, the Home prompt, Fix next or `setup_needed`; each has "Got it", which hides it
  for good (`Prefs.hiddenTips`, kept across restarts), and "Show hidden tips" at the bottom of
  Setup brings them back.
- **Fix next** (`SetupWalk`): one button walks every pending row in order, each once per walk,
  and continues when the user is back in Setup (a page closed) or an in-app install finished.
- **USB** (`tools/install-usb.sh`, bash, macOS and Linux): the same sources and checks, plus
  `SHA256SUMS` and build attestations for our assets; `--fresh` (lists `/sdcard/koreader`,
  asks y/N) and `--books out.csv` (NeoReader's `Metadata` provider when present, the epub OPF
  read on the device with `unzip -p`, KOReader's sidecar status and last write). Offline tests:
  `tools/test/test-install-usb.sh`; CI runs shellcheck and them. The NeoReader column names
  (`nativeAbsolutePath`, `title`, `authors`, `readingStatus`, `lastAccess`) are unverified on a
  device; missing columns stay empty.

## Page rebuilds keep the scroll position (v0.5.2)

Every page scrolls (v0.5.5): `page()` wraps the page in a ScrollView by default (fillViewport,
so a short page is unchanged). The status page had run off the M8C's screen below "Test
network". Only "Other apps" (paged by the height it gets) and the licenses page (its own
ScrollView) opt out; `UiPagesTest` keeps that list.

Pages redraw by building their views again (`EinkActivity.page`), e.g. "Check for updates",
Fix, Test network or a toggle. `page()` keeps the previous ScrollView's position and restores
it after layout, so the page no longer jumps to the top. Not unit-tested: it is View code that
needs the Android runtime, and the project's tests are plain JVM tests (no Robolectric or
instrumented tests).

## Lists by series and by author (v0.6.0)

Mockups reviewed 11-22 (the list's Sort sheet, Series in a list, a series in the list,
Authors in a list, an author by series). On any library, collection or smart scope, the
Sort sheet gets "By series" and "By author" at the top. They open the plugin's own Series and
Authors views, limited to that list; sort, Reading/Finished, the name filter, the A-Z rail and
paging all work. Tapping a series shows the list's books in it ("Whole series" switches to the
normal series page). Tapping an author shows their books in the list by series, books outside
a series last under "Not in a series", with chips: By series (default), All books (flat) and
All by author (the normal author page, no list filter).

- **Grouped on the device:** BookOrbit's sections endpoint takes no list
  (`KoreaderCatalogSectionQueryDto` whitelists its fields), so the patch reads the list's books
  (100 a page, "Reading N of M books…") with the list's current filters and groups them
  (`Group`, pure, tested). Rows have the shape the plugin draws; the read buckets, filters,
  orders, letters and buckets copy the server (`opds-book.service.ts`, cited in the code). A
  book with no `seriesId` (an older server) groups by its series name.
- **The plugin draws it:** the patch wraps methods on the plugin's catalog class (the list
  methods are copied onto it by `CatalogLists.install`, so the class is where they live) and on
  its API class (`Grouping`). Each wrapper passes through unless its mark is there. A grouped
  view is the plugin's `loadSection`, whose request `fetch` answers from the held books;
  `switchTo` tags the context (`orbit_group`), so reloads and paging stay in the list. The
  patch's marks ride in request params (`orbit*`) and the API's `query` drops them.
- **A row's books:** a library or collection adds `libraryId` / `collectionId` (the server ANDs
  them) and the list's filters; a smart scope goes by `ids` (the server drops other filters with
  `smartScopeId`), and past 200 books (the `ids` cap) the patch answers from the books it holds.
- **Compat:** `Compat.CATALOG_CLASS` and `Compat.API_CLASS` are checked when a UI starts; a
  missing method turns off only this feature (logged once). `test/plugin_compat.lua` checks the
  same methods, the mix-in, the `open-series` / `open-author` actions, the Sort sheet's
  `rows = {`, the section body fields and the context fields in CI (weekly).
- **Known limits:** a book in two series shows under its main series only (the whole-series
  page still has both); author rows show book covers, not photos (the list data has none);
  counts are for the list only ("5", not "5 of 7"); authors sort by their shown name, not
  BookOrbit's sort name (the books carry no sort name); the first open of a large list is slow
  (about 1 s per 100 books) and the view is a snapshot until you leave the list (reopen it to
  refresh).

## Sync while reading in the companion (v0.4.8)

The patch keeps "Sync while reading" (its menu stays). Companion Settings shows the value the
patch reported in `SETTINGS` and offers the same ten options (`ReadingSchedule`). A choice there
is a request (`id`, `at`) carried in `/status.reading_schedule_request`; the patch applies and
saves it at its next start, resume or menu open (`Schedule.request`), restarts its counter and
acknowledges with `SETTINGS` (`reading_schedule_applied_at`), which clears the request. Until
then Settings shows the request with "applies when KOReader opens". The PIN guards the page.

## Plugin updates

The patch prefers the plugin's public surfaces (its Dispatcher actions and user settings) and
keeps the few private internals it needs (outbox wait, silent pull/push, position check
without prompting, dashboard detection, `on_done` callbacks) behind a start-up compatibility
check: a missing symbol turns off only that feature, which falls back to the plugin's own
behaviour, and is shown in the menu status and Test sync path. CI checks the same list
against the latest plugin weekly and opens an issue when it changes (koreader-patch/README.md
"Plugin hook points").

The plugin's event handlers (`onBookOrbitOpenDashboard`, `onBookOrbitSyncBook`,
`onBookOrbitToggleAutoSync`) are reached by sending the event through the live UI, as
KOReader's dispatcher does, never by a type check on the method: KOReader 2025.10+ wraps
every plugin `on*` handler in a HandlerSandbox, a callable table (frontend/pluginloader.lua
v2026.07.1:117-128, :158-164, :263), so `type(p.onX) == "function"` is false there (v0.4.6
and older: Home on the file browser did nothing). The compatibility check counts callables
as functions, and only a full pass is cached per plugin instance, so a check made before the
plugin finished `init` is made again.

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

# Clicker buttons: design (approved, built in v0.4.0)

Goal: a Bluetooth clicker turns pages and runs a few actions on the reader, from the
companion, with no other app. Nothing is built. Mockups: `btkeys-mockups.html` next to this
file. KOReader citations are koreader/koreader @ 1294bb3d and android-luajit-launcher HEAD.

## What the M8C shows today (read-only adb, 2026-11-21 20:2x PT)

- The other app is **Key Mapper 4.5.0** (`io.github.sds100.keymapper`, Play Store). Its
  accessibility service is the only one enabled (`enabled_accessibility_services`) and was
  bound; it holds key filtering, gestures *and* window-content access (capabilities 105).
- **Why it stops:** its `lastDisabledCaller` is `com.haoqing.app.hqreader`, the Meebook
  launcher's App freeze (`toggle_freeze_app<pkg>` in `settings secure`; now 0 for it). A
  frozen (disabled) app loses its accessibility service until it is re-enabled. Its appops show
  the accessibility service re-bound minutes before the check. A force-stop has the same effect.
- Bluetooth was off, so the clicker's keycodes couldn't be read; Key Mapper's maps are
  app-private. The capture screen (below) records them on first use.
- Our app: freeze toggle 0, on the deviceidle allowlist, `ACCESS_RESTRICTED_SETTINGS` default
  (allowed), so its accessibility switch should not be greyed out.

## What clickers send, and why they "don't work everywhere"

Clickers are Bluetooth HID keyboards or consumer-control devices. Common outputs: Volume
up/down (camera-shutter clickers), PageUp/PageDown or arrows (presentation clickers), Enter or
Space, media next/previous/play. Ring-style "TikTok" remotes are pointer devices that send
taps and swipes, not keys: no key mapper can remap those.

Each app decides which keycodes it handles:
- **KOReader** maps only these to page turns (`frontend/device/android/event_map.lua`): Volume
  up/down (24/25), PageUp/PageDown (92/93) and D-pad Left/Right (21/22, via
  `readerpaging.lua:75-76`, `readerrolling.lua:142-144`). Media keys (85/87/88), Space, Enter
  and Up/Down don't turn pages. "Volume key page turning" off (`android_ignore_volume_keys`,
  `device.lua:300-303`, `common_settings_menu_table.lua:357-365`) hands volume keys to Android.
- **Other readers** (Readest, the Meebook reader) mostly honour volume keys at best.
- **Android** keeps volume keys for itself when the app in front doesn't take them.
- A mapper that turns a clicker button into "volume up" as an *action* (changing the volume)
  rather than a *key* never reaches the reader.

## Options considered

| Way | Verdict |
|---|---|
| AccessibilityService, `FLAG_REQUEST_FILTER_KEY_EVENTS` + `onKeyEvent` ([docs](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService#onKeyEvent(android.view.KeyEvent))) | **Chosen for other apps.** Sees and can consume every key, system-wide, no root. Can't inject keys into another app; can `dispatchGesture` (API 24) and `performGlobalAction` (Home, Back, `GLOBAL_ACTION_LOCK_SCREEN` API 28). User grant required. |
| `InputMethodService` | Rejected: gets keys only while a text field has focus. |
| Shizuku / adb `input` injection | Rejected: needs an adb grant after every boot. |
| KOReader patch reads keys itself | **Chosen for KOReader.** The patch adds keycodes to `Device.input.event_map` (loaded at `device.lua:142-147`) and times presses with a wrap of `Input:handleKeyBoardEv` (`input.lua:723`). Exact page turns, no IPC, works without the accessibility grant. |
| Companion broadcasts "next page" to the patch | Rejected: the patch has no broadcast receiver (LuaJIT JNI can't define one), and the only companion→KOReader path, an activity intent (INTERFACE.md "go home"), pauses KOReader on every press. |

## The design

1. **One key map, kept by the companion**, per clicker (`InputDevice` name + vendor/product id,
   so two clickers can differ): button (keycode, scancode for display) × press kind (press,
   long ≥ 0.6 s, double ≤ 0.35 s) → action. Learned on the capture screen, never typed.
2. **KOReader in front: hands off.** The accessibility service passes every key through. The
   patch reads the map from `/status` (`keymap`, new field, keycode-keyed; read at start and
   resume like `settings`) and handles it inside KOReader. Long/double are timed in the patch
   only for keys that have one, so plain presses turn the page with no delay.
3. **Any other app:** the service consumes mapped keys only (unmapped keys and every key from
   the built-in buttons and touch pass untouched) and runs the action. The foreground app comes
   from `TYPE_WINDOW_STATE_CHANGED` events' package name, nothing else.
4. **Actions (small on purpose):**

   | Action | KOReader (patch) | Other apps (service) |
   |---|---|---|
   | Next / previous page | `GotoViewRel ±1` | Tap a zone (default right/left third, mid-height), or a swipe; per-app override |
   | Home / Back | Patch's HomePlan / Back key | `GLOBAL_ACTION_HOME` / `_BACK` |
   | Frontlight on/off | KOReader's `ToggleFrontlight` | Not offered (needs "Modify system settings") |
   | Sync and sleep | Patch's Sync and sleep | Sleep only (`lockNow`, existing device admin) |
   | Nothing (let the app have it) | pass through | pass through |

   Per-app override rows exist for page actions only (zone or "send nothing"). Tap zones per
   reader are stored per package; vendor readers' defaults go in `Vendor.kt`, never in code.

## Permissions and privacy

The accessibility service is declared with `canRequestFilterKeyEvents="true"`,
`canPerformGestures="true"`, **`canRetrieveWindowContent="false"`**, event types
`typeWindowStateChanged` only, `isAccessibilityTool="false"`. Android itself then refuses it
any window or screen text. It uses: key events (only acted on when mapped), the foreground
package name, and taps it sends. It never reads window content, never stores or sends keys
(the capture screen keeps the codes you press while it is open; nothing else is logged
beyond "key 87 → next page in Readest"), and never reaches the network. This text goes in the
service's `android:description`, which Android shows on the grant screen.

## Battery cost

Event-driven: the service runs only when a key is pressed or the foreground app changes. No
polling, alarms, wake locks or Bluetooth scanning. Expect no measurable change; the Battery
page's before/after check (README "Battery stats") verifies it.

## Staying on (the "stops running" fix)

- Our process is already kept by the foreground service, Battery Unrestricted and the "Not
  disabled by the system" Setup row (Vendor.kt names the Meebook freeze).
- New Setup row **"Clicker buttons (accessibility)"**: done = our service is in
  `enabled_accessibility_services` **and** connected (it stamps `onServiceConnected`, clears
  on `onUnbind`). Shown only once a clicker is mapped, so readers without one are never asked.
  A freeze, a force-stop or Android turning it off is a regression: "Setup needs you" fires.
  Fix opens Settings › Accessibility (`ACTION_ACCESSIBILITY_SETTINGS`).
- Info row when another key filter is on: "Key Mapper also remaps keys: turn it off once
  Orbit's buttons work." Two filters both see every key and can fight. The user can then
  uninstall Key Mapper; we never do.

## Failure modes

- Accessibility grant off or unbound → other apps get raw keys; KOReader still works (patch).
- Android 12+ may later show "Orbit can view and control your screen" and offer to turn it off
  (non-tool services); the Setup row catches the result.
- A reader that ignores taps at the zone (pop-up open) → the tap lands on the pop-up.
- Clicker as pointer device (ring remotes) → capture says "This clicker sends taps, not
  buttons; it can't be mapped."
- Keys while the screen is off (wake on clicker) are out of scope.
- `onKeyEvent` must answer within the system's key timeout, so long/double are decided by
  consuming down/up and acting on a timer, never by blocking.

## Settings (companion › Clicker buttons)

Clickers list (each: buttons → actions, Forget); Add a clicker / Add a button (capture);
per-app page actions (zone L/R thirds, top/bottom halves, swipe, nothing); long-press and
double-press on/off per button (off by default: no delay); Show taps (a brief dot, for
checking zones). Shared to the patch: the map only, through `/status`.

## Decisions I made (two-way doors)

| Decision | Choice | Why |
|---|---|---|
| KOReader path | Patch handles keys itself; service passes through | Exact turns, no grant needed, no per-press IPC |
| Other apps | Accessibility key filter + taps | Only no-root, no-adb way |
| Content access | `canRetrieveWindowContent=false` | Least power; enforced by Android, not just promised |
| Foreground app | Window-state events' package name | Works without content access |
| Action list | Page ±, Home, Back, Frontlight (KOReader), Sync and sleep / Sleep, Nothing | "Way overkill" was the complaint |
| Frontlight outside KOReader | Not offered | Would add a second grant (Modify system settings) |
| Long/double press | Per button, off by default | No added latency unless chosen |
| Profiles | Per clicker (name + ids) | Two clickers can differ |
| Map → patch | `/status` `keymap` field, read at start/resume | Existing channel (INTERFACE.md) |
| Setup row | Only once a clicker is mapped | No nag for non-users |
| Key Mapper | Warn only; user uninstalls | Not ours to remove |
| Vendor zones | `Vendor.kt` defaults | House rule |

## Decision (maintainer, 2026-11-21)

Approved **with the Accessibility service**, so clicker buttons work in all apps. One-way
door 1 is taken as written: key filtering, gestures and window-state events only,
`canRetrieveWindowContent="false"`, switched on by the user, nothing read, stored or sent.
Door 2 stays closed: no system settings are changed. Built in v0.4.0:
- `ClickerLogic.kt` (pure, tested): the key map, the press timer, zones and the Setup row;
- `ClickerService.kt`: the service;
- `Clicker.kt`: screens 1–3;
- the patch's `Clicks`: KOReader.

## One-way doors (as proposed)

1. **Add an Accessibility service to Orbit Companion.** It is Android's most powerful app
   permission class. We'd use it only to (a) see key presses and act on the mapped ones,
   (b) learn which app is in front (package name), (c) send taps, Home and Back. We'd declare
   it **unable to read window content** and promise in the app and README never to read,
   store or send screen content or unmapped keys. You switch it on yourself in Settings ›
   Accessibility; it is undone by switching it off. Approve, or keep KOReader-only (the patch
   part alone, no grant, works only in KOReader).
2. Nothing in this design changes system settings (no `WRITE_SECURE_SETTINGS`, no
   `WRITE_SETTINGS`, no Key Mapper changes). If you later want Orbit to re-enable its own
   service after a freeze without you, that needs a one-time adb grant of
   `WRITE_SECURE_SETTINGS`; not proposed.

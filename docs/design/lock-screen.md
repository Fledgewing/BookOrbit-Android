# Sleep screen: a recommended cover or the current book

Status: designing (ROADMAP 11). Mockups: `lockscreen.html` (the design page that goes with this
PR). Nothing here is built; the design needs the user's approval first (AGENTS.md "Features and
roadmap").

Citations are to the pins in `tools/upstreams.lock`: KOReader `v2026.07.1` (K), CrossInk-Bookorbit
`v2.0.0+bookorbit.1-rc3` (C), BookOrbit `v3.9.0` (B, server unless noted). O = this repo.

## What the reader gets

When the reader goes to sleep, its screen shows one of:

1. **Recommended cover**: a book from one of the reader's BookOrbit lists (Up next in series by
   default). It changes every X hours (1, 3, 6, 12 or 24). The reader never wakes to change it.
   If a sleep starts X hours or more after the last change, that sleep gets the next cover.
2. **Current book**: the cover of the book open at sleep. If no book is open, the last book read.

On top of either, two optional extras, both off by default:

- **text** the user types, up to 60 characters on at most two lines;
- **battery**: the level when the reader went to sleep, e.g. `▮ 82%`. It is not live.

Nothing here runs while a book is being read. The image is drawn only when the reader goes to sleep
(reading gate: [reading-gate.md](reading-gate.md)). It is prepared from files already on the device,
so going to sleep never waits for the network.

## Platform facts that drive the design

### Android: KOReader can't draw the sleep screen

| Fact | Source |
|---|---|
| KOReader's sleep screen ("screensaver") is off on Android. `supportsScreensaver()` is false by default, Android doesn't override it, and the "Sleep screen" menu is shown only where it is true. | K `frontend/device/generic/device.lua:566`, `frontend/device/android/device.lua:75-95` (no override; `canSuspend = no` at :87), `frontend/apps/reader/modules/readermenu.lua:289` |
| KOReader learns about sleep only after the fact. `APP_CMD_PAUSE` (screen off, or another app in front) becomes `RequestSuspend`. By then the system has already drawn its sleep screen. | K `frontend/device/android/device.lua:218-221`; O `ko/sleep.lua:9-55` (Orbit's `onSuspend` checks `Jni.isInteractive()` because it can't tell sleep from an app switch) |
| What KOReader offers instead is the **Cover image** plugin. It writes the open book's cover to a file (default `/sdcard/cover.jpg`, `suspend_others.jpg` on Tolino) for the system's sleep screen to show, and it is on Android only for that reason. | K `plugins/coverimage.koplugin/main.lua:9`, `:229-232` (written at `onReaderReady`), `frontend/device/android/device.lua:593-597` |
| **Meebook M8C (Haoqing):** its sleep image is an Android **dream** (screen saver), `com.haoqing.wallpaper/.view.service.HaoqingDreamService`. It is the *default* dream: the user's `screensaver_components` is unset, so the system "falls back" to it. The dream starts as the device goes to sleep, and the panel goes off 13.6 s later. | M8C log (11-23): `Going to sleep due to timeout` (13:51:40.332), `DreamManagerService: Falling back to default dream …HaoqingDreamService`, `Entering dreamland`, `Starting dream … reason='power manager request'`, `HaoqingReceiver: com.haoqing.action.SCREEN_OFF` (:40.385), `Brightness … 'screen_off'` (13:51:53.963) |
| Not yet seen on the M8C: a **power-button** sleep and a sleep **on battery**. The log above was a timeout sleep while on USB (`libsuspend: charge_state===: 1` throughout). Stock Android starts the screen saver only on timeout; Haoqing may start it on every sleep. | the same log; it has no power-button sleep |
| **Boox (Go Color 7, Page):** the sleep image is a picture the user picks in Apps › Screensaver › Screensaver style (one or several images). The power-off image is a separate setting. Owners report that pointing it at the file KOReader's Cover image plugin overwrites works. Not verified on our devices, and nothing shows whether Boox runs Android dreams. | [Boox help: Screensavers](https://help.boox.com/hc/en-us/articles/8569260546196-Screensavers); [MobileRead report, Go Color 7](https://www.mobileread.com/forums/showthread.php?p=4511691) |
| The companion already reads and writes KOReader's folder on shared storage. | O `StatusFile.kt:18` (`koreader/settings/orbit-companion.json`), `Installers.kt:172` |
| A full-screen activity started at `ACTION_SCREEN_OFF` is too late: the broadcast arrives after the panel was handed to the dream or turned off. | O `OrbitService.kt:187`; the log above (`SCREEN_OFF` comes 50 ms after the dream started) |

So on Android the companion supplies the image, in one of two ways (the **sinks**), and the plugin
supplies the covers:

- **Dream sink (Meebook, and any reader whose sleep image is a dream):** the companion ships its own
  `DreamService`, "Orbit sleep screen". The system runs it in place of the vendor's once it is
  chosen as the screen saver. It draws the cover and the extras when the dream starts, which is the
  moment of sleep, so the battery level is right.
- **Picture sink (Boox, and any reader whose sleep image is a picked file):** the companion keeps
  one finished picture, `Pictures/Orbit/sleep.png`, which the user picks once in the vendor's
  screensaver setting. It is redrawn ahead of time (see "Rotation"), so the battery is as of the
  last redraw: within 1%, because it is redrawn at every 1% step.

A **probe** picks the sink for each device. It needs no device work from the design: the companion
logs which component the system binds at sleep (`dumpsys dreams` and the logcat lines above) during
its first sleeps after the feature is switched on. Two log checks gate building: an M8C
power-button sleep on battery, and a Boox sleep (Go Color 7 and Page).

### Xteink: CrossInk draws the sleep screen, before Wi-Fi

| Fact | Source |
|---|---|
| CrossInk's sleep screens: Dark, Light, Custom (`/sleep` folder or `/sleep.bmp`), Cover (the book's cover), Blank, Cover + Custom, Page Overlay, Reading Stats, Minimal, Quick Resume, Minimal Stats (X3 only), Dashboard, Cover Overlay. Cover has Fit/Crop and a filter. | C `src/CrossPointSettings.h:29-50`, `src/SettingsList.cpp:12-24` |
| **Cover is already "current book, else the last book read".** It uses the open book, or `APP_STATE.openEpubPath`, which is saved state. With no path or no cover it falls back to the default screen. | C `src/activities/boot_sleep/SleepActivity.cpp:1016-1062`, `src/CrossPointState.h:24` |
| Every bitmap sleep screen goes through `drawSleepBitmap` (once per grey plane) and then `displayBuffer`. That is one place to draw a band over the cover before the panel refreshes. | C `SleepActivity.cpp:954-968`, `:970-1014`; default screen `:875-901` |
| **Order at sleep:** the sleep screen is drawn first. Then, with Sync on Sleep, the device restarts into a network boot behind that screen, syncs, and draws the screen again from a record the first pass wrote (`SleepScreenPass`, `sleep_redraw_image.txt`). So the cover can't come from the network at sleep: it must already be on the SD card. The redraw after the sync is a second chance to draw. | C `src/main.cpp:1461-1468`, `:1582-1592`, `:1633`; `SleepActivity.h:10-14`; `SleepActivity.cpp:572-573`, `:601-611` |
| The sleep sync runs only with an EPUB open and the battery above its minimum. | C `src/main.cpp:1540-1552` |
| Orbify's sleep sync (X4s) lends the sync's TLS session to catalog requests: first Home and its covers, then the next cover for the End-of-Book page, then the copy refresh and the mirror slice. The covers are decoded with the radio off. | O `overlay/patches/v2.0/0037-…` (`runSleepSync`, `LentConnection`), `orbify/FinishSync.cpp:604` (`fetchNextCover`), `:670` (`decodeNextCovers`), `orbify/core/NextCover.h` |
| Text settings exist: `SettingInfo::String`, edited with the on-device keyboard (buttons or touch) and on the web settings page in File Transfer. | C `src/activities/settings/SettingsActivity.h:180`, `src/SettingsList.cpp:307` (Device Name), `activities/settings/BookOrbitSettingsActivity.cpp:180` (keyboard), `src/network/CrossPointWebServer.cpp:510-512`, `:1915`, `:2032` |
| The X4's clock does not survive deep sleep unless "Keep Clock in Sleep" is on. The X3 has a real RTC. | C `src/CrossPointSettings.h:525-529` |
| The X3 `default` build is at 99.35% of its slot, about 10 KB under the 99.5% CI gate. The X4s are at 96.2% and 93.8%. | O `docs/design/XTEINK-BUILD-NOTES.md` S17 |
| The Settings PIN (patch 0023) guards Settings and the web settings endpoints. | O `overlay/patches/v2.0/0023-settings-pin.patch` (`CrossInkTailnetCuts.h` comment) |

### BookOrbit: where "recommended" comes from

| Fact | Source |
|---|---|
| The device dashboard has one configurable section: `random`, `recently-added`, `want-to-read`, `up-next-in-series` or `smart-scope`. It is also served on its own at `GET /koreader/plugin/catalog/dashboard/sections/:type`, up to 12 books. | B `packages/types/src/koreader.ts:443-449`, `koreader-catalog.controller.ts:48-56`, `koreader-catalog.service.ts:147`, `:381-402` |
| Continue reading is fixed: `readStatus=reading`, `recently_read`, 5 books. | B `koreader-catalog.service.ts:141`, `:241-246` |
| Every catalog read goes through the user's visibility (libraries, restrictions), so a kid's account only ever lists what it may see. | B `koreader-catalog.service.ts:240` (`resolveVisibility`), `:399-402` |
| The catalog thumbnail is a 400 × 600 JPEG with an `ETag` (304 on `If-None-Match`). There is no larger cover for the plugin's login. | B `book-cover-store.service.test.ts:307`, `koreader-catalog.controller.ts:92-100`; [write-through-cache](write-through-cache.md#cover-version) |
| Android's offline mirror already saves the Up next books and their covers. | O `ko/mirror.lua:116`, `:133`; [write-through-cache](write-through-cache.md#offline-mirror-v0111) |
| The Xteink Home snapshot keeps Continue reading (3) and two shelves of 4 books (Discover, Recently added, Want to read, a collection or a SmartScope) with small shelf-size covers. It has no Up next. | C `src/BookOrbitHomeStore.h`, `lib/BookOrbitSync/BookOrbitHomeShelfSource.h` |

## Decisions (two-way doors, settled)

### Sources and rotation

| # | Question | Decision | Why |
|---|---|---|---|
| R1 | Where "recommended" comes from | A setting, **Pick from**: Up next in series (default), Want to read, Discover. If the chosen list is empty, the others are tried in that order. | Up next is the book the reader is most likely to want next, and it is personal. Continue reading is the Current book mode's job. Discover is random, so it is never the default. |
| R2 | Which books count | Up to 12, in the server's order. Skipped: the book open now, books marked read, and books with no cover (`hasCover` false). | The section's own limit (B :147). Order carries meaning, e.g. series position. |
| R3 | How covers get onto the device | **Android:** the plugin keeps a pool, `koreader/settings/orbit-sleep/pool.json`, plus a copy of each cover (≤12 × ~100 KB). It refreshes the pool with the dashboard section on every Home refresh, through the write-through cache (offline: from the cache). **Xteink X4s:** the sleep sync asks for the same section at most once a day on the lent session, stores `pool.bin` (two slots with a CRC, as B3) and fetches the cover **one ahead**: the next cover in the rotation, by `planCover` with the ETag, decoded radio-off to a screen-size BMP in `/.crosspoint/orbify_sleep/`. | Copies on Android, so a cache prune never takes a cover in use. One ahead, so a sleep always has its next cover on the card. The same request on both platforms gives the same list. Reuses NextCover's fetch, ETag and decode path. |
| R4 | The rotation rule | At sleep: if no cover was shown yet, or now − last change ≥ X, and the next cover is on the device, show it and set *last change = now*. Otherwise show the same one. A clock that went backwards resets *last change* to now. | It is the user's rule. A missing next cover never blanks the screen: it waits for the next sleep. |
| R5 | X choices | 1, 3, 6, 12, 24 h. Default **6 h**. | The user's examples. 6 h changes it about twice a day for a daily reader. |
| R6 | Xteink with no clock at sleep (X4 without Keep Clock in Sleep) | The first pass shows the current cover. The sleep sync learns the time, and if a change is due, its redraw (which happens anyway, C main.cpp:1633) shows the next cover and records the change. Without a sync and without a clock, the cover changes at the next sleep that knows the time. The settings row says "Changes when the time is known". | It never wakes the device and never adds a network step. The redraw is already part of every synced sleep. |
| R7 | Android: when the picture sink redraws | When the pool or settings change; at every 1% battery step (`ACTION_BATTERY_CHANGED`); and on a **non-wakeup** alarm at *last change + X*. That alarm is delivered at the next wake after that time, so the sleep after it gets the new cover. | The picture must be ready before the sleep. A non-wakeup alarm never wakes the reader. |
| R8 | Where the decision lives | Pure functions with tests. Android: `SleepScreenLogic.kt` in the companion (`LogicTest`). Xteink: `orbify/core/SleepPick.{h,cpp}` (host test). The rule table is `shared/fixtures/sleep/cases.json`, which both read. | The same rule on both platforms, the way the cache cases are shared. |
| R9 | Current book on Android | At `ReaderReady`, the plugin writes the open book's cover once per document (skipped when the digest is unchanged) with `FileManagerBookInfo:getCoverImage`. It writes `orbit-sleep/current.jpg` and `current.json` (title, author). The file stays after the book closes, so it is "the last book read". | The same call KOReader's Cover image plugin makes (K `filemanagerbookinfo.lua:461`, `coverimage.koplugin/main.lua:127`). The plugin itself isn't used: it pads the cover to the screen, which leaves no room for the band. |
| R10 | Current book on Xteink | CrossInk's own Cover mode, unchanged. Orbify adds only the band. | It already is "open book, else the last one" (C :1016-1062). It costs no flash. |

### Settings

| # | Question | Decision | Why |
|---|---|---|---|
| S1 | Android: where | **KOReader › Tools › Android sync › Sleep screen** (the Orbit menu, behind the Settings PIN like the rest of it, O `ko/menu.lua:313`). The companion shows the same section under Settings › Sleep screen; in Add-on mode that is a helper. The values are shared through the existing `SETTINGS` broadcast (newest `settings_at` wins), with five new extras: `sleep_mode`, `sleep_from`, `sleep_hours`, `sleep_text`, `sleep_battery`. | The reader is in KOReader. The companion owns the sink and the system setup. `SETTINGS` already merges both sides (O `android/docs/INTERFACE.md:27`). |
| S2 | Android: rows | Sleep screen: *The reader's own* (off) / *Recommended cover* / *Current book*. Pick from (Recommended only). Change cover every (Recommended only). Text… (a one-line input, 60 characters). Show battery level. How it is shown: "Orbit screen saver ✓" or "Set up ›". Preview. | Preview is a menu action, so the gate allows it. It shows the screen for 5 s or until a tap, so the user can see what the text does. |
| S3 | Xteink: where | **Settings › Display**, beside CrossInk's own sleep rows. X4s: the Sleep Screen list gains **BookOrbit Pick**, then Pick From, Change Every, Sleep Text, Battery on Sleep Screen. X3: Sleep Text and Battery on Sleep Screen only. | It sits where users already choose a sleep screen. |
| S4 | Xteink: how "BookOrbit Pick" is stored | In Orbify's own setting, `orbifySleep`. Upstream's `sleepScreen` keeps its value; the row is a dynamic enum whose getter and setter read and write both, like `boSyncOnSleep` (C `SettingsList.cpp:476-482`). Choosing BookOrbit Pick leaves `sleepScreen` alone, and choosing any CrossInk mode turns `orbifySleep` off. | No new value in upstream's numbered enum, which upstream may extend. Turning it off brings back exactly what was there. |
| S5 | Text on the X4 Classic (buttons only) | The on-device keyboard (`KeyboardEntryActivity`, as for the BookOrbit user name), or the web settings page in File Transfer, from a phone. Both come with `SettingInfo::String`. | Upstream gives both, and they cost nothing new. No companion exists on Xteink. |
| S6 | Defaults | Off on every reader, including after an update: an update never changes what a reader shows at sleep. A new Android setup offers it as an optional step, not a checklist row. When switched on: Recommended, Up next, 6 h, no text, no battery. | The vendor's or CrossInk's screen stays until the user asks. The extras are optional, as the user asked. |

### Layout

| # | Question | Decision | Why |
|---|---|---|---|
| L1 | Orientation | Always portrait, whatever the reading orientation. | CrossInk already draws sleep screens portrait (C `SleepActivity.cpp:699`). One layout per panel. |
| L2 | Cover | Fit: the whole cover, centred, on white. On Xteink, CrossInk's Fit/Crop and filter settings apply. | A cropped title looks broken. Xteink users already chose Fit or Crop. |
| L3 | Extras | A **band** at the bottom: white, with a 2-px black rule above it. Its height is 7% of the panel (M8C 131 px, Boox 118 px, X4 56 px, X3 55 px). The cover fits into the space *above* the band and never sits under it. The text is left-aligned, one or two lines (two lines make the band taller: 10% of the panel). The battery is right-aligned: an outline icon, then `82%`. With neither extra on, there is no band and the cover uses the full height. | Text never covers the art. On the X4 a 2:3 cover fit to 480 px is 720 px tall, which leaves exactly 80 px: the band costs the cover nothing. |
| L4 | Battery format | Percent only, as of sleep, with no time. | Xteink often has no clock (R6). The same on both platforms. |
| L5 | Text | ≤ 60 characters, at most 2 lines (cut with "…"), in the UI font: Android 9 pt (~38 px on the M8C), Xteink `UI_12`. | Long enough for "If found, please return to the front desk". Short enough for one band. |
| L6 | Colour (Boox Go Color 7) | The cover in colour; the band in black and white. | Kaleido colour is low resolution (150 ppi), so text stays on the B/W layer. |
| L7 | Recommended thumbnail on 300-ppi Android panels | The 400 × 600 thumbnail is scaled to fit, which is soft on the M8C (≈2.9×). If the recommended book is on the device, its own EPUB cover is used instead. | It is the only cover the plugin's login can fetch (B :92). A sharper source would need a server-contract check first. |
| L8 | Labels | None, so nothing says "Recommended" on the screen. | The cover carries its title, and fewer pixels means less ghosting. |
| L9 | Panel sizes | M8C 1404 × 1872, Boox Page and Go Color 7 1264 × 1680 (Boox's published spec, not measured), X4 480 × 800, X3 528 × 792. The sink draws at the panel's real size, read at run time. | Mockups only; nothing is hard-coded. |

### Fallbacks

| # | Case | Shown |
|---|---|---|
| F1 | Recommended, but no pool or no cover on the device (first use, offline since setup) | The Current book screen; if there is none, the default screen. |
| F2 | The next cover isn't on the device yet (offline, fetch deferred) | The same cover as before. *Last change* doesn't move, so the next sleep tries again. |
| F3 | Current book, and the book has no cover | Android: a drawn cover with the title and author on a plain frame. Xteink: CrossInk's own fallback (the default screen). |
| F4 | No book ever read | The Recommended pool if it has covers, else the default screen. |
| F5 | Default screen | Android: a plain page with a book outline and "Sleeping". Xteink: CrossInk's Dark or Light screen. The band is drawn on it when on. |
| F6 | A cover file is unreadable | The next case down; the broken file is removed and fetched again. |
| F7 | Offline | Nothing is fetched at sleep, ever, so offline changes nothing. The rotation continues through the covers already on the device. |

Every fallback logs one line (`ORB Sleep: <mode> -> <shown> (<why>)`, Android `sleep screen: …`).

### Kids' readers and the PIN

| # | Decision | Why |
|---|---|---|
| K1 | Every sleep-screen setting is behind the Settings PIN: Android's Orbit menu and companion settings, and Xteink's Settings and web settings (patch 0023). | A parent sets the text ("Bedtime 8 pm", "Please return to…") and the mode, and the child can't change them. |
| K2 | Recommended covers come from the reader's own account, so the server's visibility rules decide what can appear (B :240). On a reader with a PIN, Discover is not offered. | Up next and Want to read are lists the reader already chose. Random picks are the parent's call, and they can still change this with the PIN. |
| K3 | The sleep screen shows no PIN and no unlock, and waking goes where it always went. | The PIN guards settings, not waking. |

### Add-on mode (Android)

| # | Decision | Why |
|---|---|---|
| A1 | **Sleep screen** is a helper, off until switched on, like Wi-Fi switching and sleep sync ([addon-mode §3](addon-mode.md)). | Add-on leaves sleep to the vendor unless the user asks. |
| A2 | It needs no foreground service. The system binds the dream at sleep. The picture sink redraws from a broadcast receiver and the alarm. | Add-on runs no service unless a helper needs one (addon-mode §7.2). |
| A3 | Current book means the last book read **in KOReader**. A book read in the vendor's own reader isn't seen. | Orbify only sees KOReader. |
| A4 | Switching the helper off: the dream sink puts back the vendor's screen saver (see door 1); the picture sink says "Pick another picture in the Boox Screensaver settings ›" and deletes `sleep.png`. | It leaves the reader as it was. |

### Building blocks

| Piece | Owner | Reuse |
|---|---|---|
| Pool and current cover files | plugin `ko/sleepscreen.lua`; logic `logic/sleep_pool.lua` | write-through cache reads, `Cache` covers, `FileManagerBookInfo:getCoverImage` |
| Rotation rule | companion `SleepScreenLogic.kt`; Xteink `orbify/core/SleepPick` | `shared/fixtures/sleep/cases.json` |
| Dream sink | companion `SleepDream.kt` (`DreamService`, `BIND_DREAM_SERVICE`) | `Vendor` profile picks the sink |
| Picture sink | companion `SleepPicture.kt` | the same renderer as the dream (one `SleepCanvas`) |
| Xteink band and pick | patch `0038-orbify-sleep-screen.patch`: one line in `drawSleepBitmap` and one in `renderDefaultSleepScreen` (the band); one case in `renderSleepScreen` (BookOrbit Pick); the redraw record keeps the cover id and the battery level | `NextCover` fetch, ETag and decode; `LentConnection`; `SettingInfo::String` |
| Switches | `CROSSINK_TAILNET_ORBIFY_SLEEP_BAND` (1,1,1), `CROSSINK_TAILNET_ORBIFY_SLEEP_PICK` (0,1,1) | `tailnet_build.py` |

Tests: the rule table (both platforms), the band layout (`orbify/core` host test: text wrap, band
height, cover rect for each panel), the pool parse (plugin `test_logic.lua`, recorded section reply
in `shared/fixtures/`), and a `ReadingGuardTest` entry for the dream (system-started, never during
reading).

## The X3

- **It gets:** Current book (CrossInk's Cover mode, already there), with the band: **Sleep Text**
  and **Battery on Sleep Screen**. Estimated at 2-3 KB: two settings rows, their strings, and the
  band drawing, which uses renderer calls already linked. It is behind
  `CROSSINK_TAILNET_ORBIFY_SLEEP_BAND`, and the 99.5% gate's drop order takes it out first if the
  build measures over.
- **It doesn't get Recommended.** That needs the pool request and parse, the one-ahead fetch and
  decode, and the rotation state: an estimated 6-9 KB against ~10 KB left. The X3's sleep sync also
  has no lent session for extra requests (0037 S2). This is the same call as the mirror and the
  cache (C1, M9).

## One-way door

1. **How the Orbit screen saver gets chosen on a dream-sink reader (Meebook).** Choosing it means
   writing `screensaver_components` (with `screensaver_enabled` and
   `screensaver_activate_on_sleep`), which are Android secure settings. The companion can't write
   them without `WRITE_SECURE_SETTINGS`, which can only be granted over USB, and Meebook hides the
   system Screen saver page (to check in the probe). The choices:
   - (a) **One USB step, no lasting permission:** `tools/install-usb.sh --sleep-screen on|off` writes
     the three values, keeping the vendor's previous ones in a file to restore. The companion's
     "Set up ›" opens the system page where it exists, and otherwise shows that command.
   - (b) **Grant the permission once over USB:** the companion then switches the screen saver on and
     off itself. A guard test allows only those three keys. The permission stays with the app until
     it is uninstalled, and it allows changing other system settings too.

   **Recommendation: (a).** It touches the system only when asked, holds no new permission, and the
   change is undone by `--sleep-screen off` or by uninstalling (the system then falls back to the
   vendor's dream by itself). The clicker design kept the app from holding
   `WRITE_SECURE_SETTINGS` (`android/docs/BTKEYS-DESIGN.md:250-253`), and (a) keeps that true.

Everything else above is a two-way door.

## Before building

1. Probe logs (no design change expected): M8C power-button sleep on battery; Boox Go Color 7 and
   Page sleep (which component draws, and whether a changed picture file is read again).
2. If the M8C's power-button sleep does not start a dream, the M8C uses the picture sink too, if
   Haoqing's settings can pick a picture. If neither works, the M8C gets the feature only for
   timeout sleeps, and the settings say so.

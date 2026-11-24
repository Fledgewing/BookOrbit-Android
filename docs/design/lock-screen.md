# Sleep screen: a recommended cover or the current book

Status: Android built (ROADMAP 11); Xteink next. Mockups: `lockscreen.html` (the design page that goes with this
PR). The design was approved before it was built (AGENTS.md "Features and
roadmap").

Citations are to the pins in `tools/upstreams.lock`: KOReader `v2026.07.1` (K), CrossInk-Bookorbit
`v2.0.0+bookorbit.1-rc3` (C), BookOrbit `v3.9.0` (B, server unless noted). O = this repo.

## What the reader gets

When the reader goes to sleep, its screen shows one of:

1. **Recommended cover**: a book from one of the reader's BookOrbit lists (Up next in series by
   default). It changes every X hours (1, 3, 6, 12 or 24), or at **every sleep** (a random one of
   the 24 covers kept ready, R4b). The reader never wakes to change it. If a sleep starts X hours or
   more after the last change, that sleep gets the next cover.
2. **Current book**: the cover of the book open at sleep. If no book is open, the last book read.

On top of either, two optional extras, both off by default:

- **text** the user types, up to 60 characters;
- **battery**: the level when the reader went to sleep, e.g. `▮ 82%`. It is not live.

The extras have two **styles**:

- **Bar**: a band below the cover holds them both.
- **Overlay**: they are drawn on the cover. The text runs vertically along the right or left edge
  (you turn the reader to read it), or reads normally along the top or bottom; the battery sits in a corner.

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
| The X4's clock does not survive deep sleep unless "Keep Clock in Sleep" is on. | C `src/CrossPointSettings.h:525-529` |
| The Settings PIN (patch 0023) guards Settings and the web settings endpoints. | O `overlay/patches/v2.0/0023-settings-pin.patch` (`CrossInkTailnetCuts.h` comment) |

### BookOrbit: where "recommended" comes from

| Fact | Source |
|---|---|
| The device dashboard has one configurable section: `random`, `recently-added`, `want-to-read`, `up-next-in-series` or `smart-scope`. It is also served on its own at `GET /koreader/plugin/catalog/dashboard/sections/:type`, up to 12 books. | B `packages/types/src/koreader.ts:443-449`, `koreader-catalog.controller.ts:48-56`, `koreader-catalog.service.ts:147`, `:381-402` |
| Continue reading is fixed: `readStatus=reading`, `recently_read`, 5 books. | B `koreader-catalog.service.ts:141`, `:241-246` |
| Every catalog read goes through the user's visibility (libraries, restrictions), so a kid's account only ever lists what it may see. | B `koreader-catalog.service.ts:240` (`resolveVisibility`), `:399-402` |
| The catalog thumbnail is a 400 × 600 JPEG with an `ETag` (304 on `If-None-Match`). There is no larger cover for the plugin's login. | B `book-cover-store.service.test.ts:307`, `koreader-catalog.controller.ts:92-100`; [write-through-cache](write-through-cache.md#cover-version) |
| The full stored cover is served by OPDS: `GET /api/v1/opds/:bookId/cover`, with an `ETag` (304). It takes an OPDS login (Basic; its own accounts, often the same name and password as KOReader sync) or the cover token `?t=` from any OPDS feed's image links. OPDS must be on server-wide and the account needs `OpdsAccess` (else 403). | B `opds/opds.controller.ts:229`, `opds/opds-auth.guard.ts`, `opds/opds-enabled.guard.ts`, `opds/opds.service.ts:204-209`; O [server-contract](../server-contract.md#opds-covers-for-the-sleep-screen) |
| Android's offline mirror already saves the Up next books and their covers. | O `ko/mirror.lua:116`, `:133`; [write-through-cache](write-through-cache.md#offline-mirror-v0111) |
| **Tags:** only in the book detail (`tags`, with `genres` and `collections`). A book in a list carries none. No endpoint lists the account's tags, and the books query has no tag filter. | B `packages/types/src/koreader.ts:324-343` (list item), `:374-399` (detail), `koreader-catalog.service.ts:1312`; root sections `:160-195` (no tags section); `koreader/dto/koreader-catalog-query.dto.ts` (no tag parameter) |
| **Custom metadata:** not exposed by any plugin endpoint, neither the values nor the field definitions. | the same types; no `custom` in `koreader-catalog.controller.ts` or `koreader-plugin.controller.ts` |
| `GET …/catalog/books` takes `smartScopeId` or `collectionId`, `size` up to 100 (DTO line 88; only `/catalog/manifest` pages at 200, with a cursor and no `hasCover`), and `ids` (≤ 200). With a collection, `ids` narrows the result (an intersection). With a smart scope, the scope's own query runs alone and `ids` is ignored. | B `koreader/dto/koreader-catalog-query.dto.ts:112-135`, `:170-176`; `koreader-catalog.service.ts:1544-1554`; `opds/opds-book.service.ts:359-382` (smart scope returns at :366-369) |
| No `random` sort for book lists: title, author, published, recently added, recently updated, recently read, series. | B `packages/types/src/koreader.ts:212` |
| The account's smart scopes and collections are listed at `GET …/catalog/sections/smart-scopes` and `…/sections/collections` (id, name, count). A smart scope is listed if the account owns it or it is public; a collection the same way. | B `koreader-catalog.service.ts:437-442`, `:880-914`; `opds/opds-book.service.ts:1242-1251`, `:359-363` |
| Smart-scope rules can test custom metadata fields (`custom:<id>`), so a scope can stand for any field condition. | B `packages/types/src/query.ts:31`, `:77`; `server/src/modules/book/book-query-builder.service.ts` |
| The Xteink Home snapshot keeps Continue reading (3) and two shelves of 4 books (Discover, Recently added, Want to read, a collection or a SmartScope) with small shelf-size covers. It has no Up next. | C `src/BookOrbitHomeStore.h`, `lib/BookOrbitSync/BookOrbitHomeShelfSource.h` |

## Decisions (two-way doors, settled)

### Sources and rotation

| # | Question | Decision | Why |
|---|---|---|---|
| R1 | Where "recommended" comes from | A setting, **Pick from**: Up next in series (default), Want to read, Discover, or **a smart scope or collection** the account can see (picked from the two section lists). If the chosen list is empty, Up next, Want to read and Discover are tried in that order. | Up next is the book the reader is most likely to want next, and it is personal. Continue reading is the Current book mode's job. Discover is random, so it is never the default. All three are offered on every reader, the kids' included: the account's own restrictions already filter what each list can hold (B :240). |
| R1c | Several sources, and Library (the user's ruling, 2026-11-24, after the M8C) | **Pick from is a set**: any of *Library* (every book the account can see), Up next in series, Want to read, Discover, and any smart scopes and collections, ticked on one page. Stored one item per line, in the order picked (`sleep_from`, the same shape as `sleep_leave_out`); a single value is a set of one, so stored settings stay valid. Library stands alone: ticking it clears the others, ticking another clears it. Nothing valid is Up next. A refresh tries books from the picked sources **in turn**: each dashboard list is a stream in the server's order, and every picked library, scope and collection share **one shuffle bag** (R1b) over the union of their members, one more stream where its first source was picked; a book counts once. The R1 fallback applies only when every stream is empty, and never tries a list already picked. Library lists `books` with no filter (`sort=recently_added`, the same caps as a scope). Rules and cases: `shared/fixtures/sleep/cases.json` `sources` (`from`, `candidates`), which Android and the X4s both follow. | Readers mix: a series they follow and a "Cosy" collection. Taking turns keeps one big list from crowding out a small one; one bag keeps "no repeat" true across the whole mix. Library is the simplest "anything I own". |
| R1b | A smart scope or collection | A random book from it at each change, with no repeat until every book in it has been shown: a **shuffle bag**. The device lists the members (`books?smartScopeId=` or `collectionId=`, `size=100`, every page, up to 2,000 books on Android and 500 on the X4s), shuffles the IDs and keeps the order on disk. Each change takes the next ID whose cover can be fetched; when the bag is empty it is shuffled again, never starting with the book just shown. The bag is re-listed once a day: new members go in, members that left come out. | There is no random sort on the server (B koreader.ts:212), so the device shuffles. A kept order is what makes "no repeat" true across sleeps and restarts. |
| R2 | Which books count | A **batch of 24** kept ready on the reader, whatever Pick from is: from a dashboard list, its first 24 in the server's order; from a scope or collection, the next 24 of the shuffle bag. A source with fewer gives what it has; the fallback (R1) applies only when it is empty. Skipped: the book open now, books marked read, and books with no cover (`hasCover` false). | The section's own limit (B :147). Order carries meaning, e.g. series position. |
| R3 | How covers get onto the device | **Android:** the plugin keeps a pool, and the companion fetches each pool book's full-size cover (L7); `koreader/settings/orbit-sleep/pool.json`, plus a copy of each cover (24 × ~100 KB). The companion's full-size covers for the batch stay under the sharp-cover cap (a tenth of Orbit's storage limit, at most 24 MB); if 24 don't fit, as many as fit, the least recently used going first. It refreshes the pool with the dashboard section on every Home refresh, through the write-through cache (offline: from the cache). **Xteink X4s:** the same **batch of 24**, whatever Pick from is (the user's ruling, 2026-11-24). The sleep sync asks for the section at most once a day on the lent session (a scope or collection: the bag, R1b) and **tops the batch up a few covers per sleep** (`FETCH_PER_SYNC` = 4) inside the sync's own time budget, adding no network step; the covers are decoded radio-off to screen-size BMPs in `/.crosspoint/orbify_sleep/<id>.bmp` (the JPEG is kept for a re-decode when Fit/Crop or the filter changes). The batch and its counts are `state.bin` (a fixed record with a CRC, the previous one kept as `state.bak`). The cover is the 400 × 600 catalog thumbnail, the largest the X4's KOReader login can fetch: the full-size OPDS cover needs an OPDS login or cover token the X4 does not have, and there is no login screen for it on the X4. | Copies on Android, so a cache prune never takes a cover in use. A batch on the card, so a sleep always has covers ready, offline included, and a few per sleep keep each sync short. The same request on both platforms gives the same list. |
| R4 | The rotation rule | At sleep: if no cover was shown yet, or now − last change ≥ X, and the next cover is on the device, show it and set *last change = now*. Otherwise show the same one. A clock that went backwards resets *last change* to now. | It is the user's rule. A missing next cover never blanks the screen: it waits for the next sleep. |
| R4b | Every sleep (Android) | Each sleep shows a **random** cover of the ready batch, never the one just shown, chosen at sleep from files already on the reader (nothing fetched, offline is fine). A cover is shown up to **3 times**, then retired: the next sync leaves it out and tops the batch back up to 24 with fresh books (from a scope or collection, the next ones in the shuffle bag's order). If every ready cover has had its 3 shows and nothing new has arrived, the ready ones keep cycling. The counts are kept on disk (the companion's prefs, and `shows` in `state.json` for the plugin), so a reboot keeps them. On the picture sink the next picture is written when the reader wakes, ready for the next sleep. **Xteink X4s:** the same rule at each sleep from the BMPs on the card; the counts are in `state.bin`; the sleep sync's redraw draws the same cover again (no second count), and the cover on screen is never the one replaced. | The user's rule. Choosing at sleep must cost nothing; retiring after 3 keeps the batch moving without fetching at sleep. |
| R5 | X choices | *Every sleep* (R4b), 1, 3, 6, 12, 24 h. Default **6 h**. `sleep_hours` = `0` is Every sleep. | The user's examples. 6 h changes it about twice a day for a daily reader. |
| R6 | Xteink with no clock at sleep (X4 without Keep Clock in Sleep) | The first pass shows the current cover. The sleep sync learns the time, and if a change is due, its redraw (which happens anyway, C main.cpp:1633) shows the next cover and records the change. Without a sync and without a clock, the cover changes at the next sleep that knows the time. The settings row says "Changes when the time is known", on its own line under the row (the X4s: without Keep Clock in Sleep). | It never wakes the device and never adds a network step. The redraw is already part of every synced sleep. |
| R7 | Android: when the picture sink redraws | When the pool or settings change; at every 1% battery step (`ACTION_BATTERY_CHANGED`); and on a **non-wakeup** alarm at *last change + X*. With Every sleep there is no alarm: the next picture is written at each wake, and the other redraws keep the cover chosen. Two things report the wake: the service's screen-on receiver, and the plugin's resume after a real sleep (`SLEEP_POOL` with `wake`), which reaches the manifest receiver in every mode, so Add-on mode without the service moves on too. The first moves the picture on; the other, within 20 s, is the same wake (`SleepWake`). That alarm is delivered at the next wake after that time, so the sleep after it gets the new cover. | The picture must be ready before the sleep. A non-wakeup alarm never wakes the reader. |
| R8 | Where the decision lives | Pure functions with tests. Android: `SleepScreenLogic.kt` in the companion (`LogicTest`). Xteink: `orbify/core/SleepPick.{h,cpp}` (host test). The rule table is `shared/fixtures/sleep/cases.json`, which both read. | The same rule on both platforms, the way the cache cases are shared. |
| R9 | Current book on Android | At `ReaderReady`, the plugin writes the open book's cover once per document (skipped when the digest is unchanged) with `FileManagerBookInfo:getCoverImage`. It writes `orbit-sleep/current.jpg` and `current.json` (title, author). The file stays after the book closes, so it is "the last book read". | The same call KOReader's Cover image plugin makes (K `filemanagerbookinfo.lua:461`, `coverimage.koplugin/main.lua:127`). The plugin itself isn't used: it pads the cover to the screen, which leaves no room for the band. |
| R10 | Current book on Xteink | CrossInk's own Cover mode, unchanged. Orbify adds only the band. | It already is "open book, else the last one" (C :1016-1062). It costs no flash. |

### Leave out (a filter on Recommended)

For a reader who doesn't want some covers on show. The rules are generic: nothing here knows any
one server's fields or tags.

| # | Question | Decision | Why |
|---|---|---|---|
| X1 | Which rules | **Leave out** holds any number of rules, combined with **OR** (a book that matches any rule is left out): **Tag** (one or more tags, e.g. `age:18` or a genre tag) and **Smart scope or collection** (membership, e.g. a "Romance" scope). Off (no rules) by default. | What the plugin endpoints really expose: tags per book (detail) and scope or collection membership (books list). |
| X2 | Custom fields | **Not a rule of their own**: no plugin endpoint returns custom metadata or the field definitions (see the facts). A condition on a custom field (≥ N, = value, has a value) is made as a **smart scope** in BookOrbit's web app, whose rules can test custom fields (B query.ts:77), and then picked as a scope rule. The rule list says this under *Add a rule*: "For a custom field: make a smart scope with that condition in BookOrbit, then add it here." | It needs no server or upstream change, and the condition stays in one place, on the server. |
| X3 | Tag rule: matching and picking | Exact, ignoring case and outer spaces. Android: the picker lists the tags seen in book details already cached on the reader (the mirror saves the details of the books on the reader, Continue reading, Up next and the next in each series), with their counts, plus *Type a tag…*. Orbit Companion counts them (`tags.json`, with the pickers' lists and each pool refresh), so the picker opens from one small file. X4s: typed, comma-separated, with the keyboard or web settings (`SettingInfo::String`). | There is no tag list endpoint, so the cached details are the best list the device has. |
| X4 | Tag rule: how a book is checked | From its detail. A recommended book is checked before its cover is fetched (on the X4s up to 8 details per sleep sync; batch covers fetched under other rules are checked again before they show): the detail is asked (or read from the cache), and a book with a left-out tag is skipped and the next one is tried. | Tags are only in the detail (B koreader.ts:389). One request per change, for one book. |
| X5 | Scope or collection rule: how a book is checked | The device keeps the members' IDs, re-listed once a day with the bag (`books?smartScopeId=` or `collectionId=`, every page). Android keeps them in `orbit-sleep/leave_out.json`. The X4s keep a sorted `uint32` file per rule on the SD card (`/.crosspoint/orbify_sleep/lo_s<id>.bin` or `lo_c<id>.bin`, up to 4,000 IDs, 16 KB) and check a book with a binary search on the file, so no heap is used. For a collection, a candidate list can be checked in one request instead (`collectionId` + `ids`, B opds-book.service.ts:376-382). | A smart scope ignores `ids` (B :366-369), so its members have to be listed. |
| X6 | Where it applies | To every Recommended source: Up next, Want to read, Discover, and a picked scope or collection. It does not apply to Current book. | Current book is the book the reader chose to open. |
| X7 | When a check can't be done (first day, offline since the rule was added, detail or members not fetched yet, scope deleted) | **Fail closed**: that book is not shown. If no book passes, the screen shows Current book (F1). A rule whose scope is gone shows "Scope not found" in the list. | Showing a cover the reader asked to hide is the failure that matters. |
| X8 | Several rules, and Library | Leave out was always a set of rules (X1); the companion's pickers tick and untick any number of them on one page, without going back between each. **Library** is one more item: it leaves out every book, so it stands alone (the other rules are part of it) and the sleep screen shows Current book (F1), saying so in the row's line. A dashboard list is not a Leave out rule. Cases: `cases.json` `sources` (`leave_out`, `check`). | The user's ruling, 2026-11-24: Pick from and Leave out offer the same items, each multi-select. |

### Settings

| # | Question | Decision | Why |
|---|---|---|---|
| S1 | Android: where | **KOReader › Tools › Android sync › Sleep screen** (the Orbit menu, behind the Settings PIN like the rest of it, O `ko/menu.lua:313`). The companion shows the same section under Settings › Sleep screen; in Add-on mode that is a helper. The values are shared through the existing `SETTINGS` broadcast (newest `settings_at` wins), with ten new extras: `sleep_mode`, `sleep_from` (one item per line, R1c: a list name, `library`, or `scope:<id>` / `collection:<id>`), `sleep_leave_out` (one rule per line: `tag:<text>`, `scope:<id>`, `collection:<id>`, `library`), `sleep_hours`, `sleep_text`, `sleep_battery`, `sleep_style`, `sleep_text_position`, `sleep_battery_corner`. | The reader is in KOReader. The companion owns the sink and the system setup. `SETTINGS` already merges both sides (O `android/docs/INTERFACE.md:27`). |
| S2 | Android: rows | Sleep screen: *The reader's own* (off) / *Recommended cover* / *Current book*. Pick from (Recommended only): the three lists and *Smart scope or collection…*, which opens a picker with two sections, Smart scopes and Collections, each with its book count. Leave out (Recommended only): the list of rules, each removable, and *Add a rule*: *Tag…* or *Smart scope or collection…* (the same picker), with the custom-field note (X2). Change cover every (Recommended only): *Every sleep* / *1 h* / *3 h* / *6 h* / *12 h* / *24 h*; the companion's page shows the same six, in two rows of three. Text… (a one-line input, 60 characters). Show battery level. Style: *Bar* / *Overlay*. Text position: *Right* / *Left* / *Top* / *Bottom* (Overlay only). Battery corner: *Top left* / *Top right* / *Bottom left* / *Bottom right* (Overlay only). How it is shown: "Orbit screen saver ✓" or "Set up ›". Preview. | Preview is a menu action, so the gate allows it. It shows the screen for 5 s or until a tap, so the user can see what the text does. |
| S3 | Xteink: where | **Settings › Display**, beside CrossInk's own sleep rows. X4s: the Sleep Screen list gains **BookOrbit Pick**, then Pick From (a list screen, each item toggled: Library, Up Next, Want to Read, Discover, then the smart scopes and collections; R1c), Leave Out Tags (typed, comma-separated), Leave Out Scopes (a list screen, each toggled: Library, then the smart scopes and collections; X8), Change Every, Sleep Text, Battery on Sleep Screen, Sleep Extras Style (Bar / Overlay), Sleep Text Position (Right / Left / Top / Bottom) and Battery Corner (the last two shown only for Overlay). The X3 gets none of them. | It sits where users already choose a sleep screen. |
| S4 | Xteink: how "BookOrbit Pick" is stored | In Orbify's own setting, `orbifySleep`. Upstream's `sleepScreen` keeps its value; the row is a dynamic enum whose getter and setter read and write both, like `boSyncOnSleep` (C `SettingsList.cpp:476-482`). Choosing BookOrbit Pick leaves `sleepScreen` alone, and choosing any CrossInk mode turns `orbifySleep` off. | No new value in upstream's numbered enum, which upstream may extend. Turning it off brings back exactly what was there. |
| S5 | Text on the X4 Classic (buttons only) | The on-device keyboard (`KeyboardEntryActivity`, as for the BookOrbit user name), or the web settings page in File Transfer, from a phone. Both come with `SettingInfo::String`. | Upstream gives both, and they cost nothing new. No companion exists on Xteink. |
| S6 | Defaults | Off on every reader, including after an update: an update never changes what a reader shows at sleep. A new Android setup offers it as an optional step, not a checklist row. When switched on: Recommended, Up next, 6 h, no text, no battery. | The vendor's or CrossInk's screen stays until the user asks. The extras are optional, as the user asked. |

### Layout

| # | Question | Decision | Why |
|---|---|---|---|
| L1 | Orientation | Always portrait, whatever the reading orientation. | CrossInk already draws sleep screens portrait (C `SleepActivity.cpp:699`). One layout per panel. |
| L2 | Cover | Fit: the whole cover, centred, on white. On Xteink, CrossInk's Fit/Crop and filter settings apply. | A cropped title looks broken. Xteink users already chose Fit or Crop. |
| L3 | Bar style (the default) | A **band** at the bottom: white, with a 2-px black rule above it. Its height is 7% of the panel (M8C 131 px, Boox 118 px, X4 56 px). The cover fits into the space *above* the band and never sits under it. The text is left-aligned, one or two lines (two lines make the band taller: 10% of the panel). The battery is right-aligned: an outline icon, then `82%`. With neither extra on, there is no band and the cover uses the full height. | Text never covers the art. On the X4 a 2:3 cover fit to 480 px is 720 px tall, which leaves exactly 80 px: the band costs the cover nothing. |
| L3a | Overlay style: the cover | No band: the cover uses the full height, placed as with no extras. | The extras go on top of it. |
| L3b | Overlay style: the text position | **Right** or **Left**: one line, rotated, centred along that edge. On the right it runs top to bottom (turn the reader anticlockwise to read it); on the left, bottom to top (turn it clockwise). Either way the top of the letters faces the edge. Cut with "…" at 90% of the edge's length. **Top** or **Bottom**: read the normal way, not rotated, centred, one line wrapping to a second, cut with "…" after that. Its plate's width is the text's, up to 90% of the panel width. **Default: Right.** | The user's ruling (2026-11-23). Right reads top to bottom, like the spine of an English book, and stays clear of the battery's default corner, bottom left. |
| L3b2 | Text and battery would share a corner | The battery moves to the opposite side, keeping its other half. Text on Top or Bottom flips the battery's top or bottom (bottom left with text at the Bottom becomes top left). Text on Right or Left flips its left or right (bottom right with text on the Right becomes bottom left). The settings row still shows the chosen corner, with "moves to <corner> beside the text" under it. | The user's ruling. The text is never shortened for the battery. |
| L3c | Overlay style: the battery | The same icon and percent as the bar, horizontal, in the chosen corner. **Default: bottom left.** | The user's default. It is the corner least likely to hold a cover's title. |
| L3d | Overlay legibility | Each extra sits on a **plate**: a white rectangle with a black outline (2 px on Android, 1 px on Xteink) and padding of half the font height. The plate's outer edge is inset from the panel edge by 2% of the panel's short side: M8C 28 px, Boox 25 px, X4 10 px. Font: the same as the bar (L5). | A plate is legible over any art, dark or busy, and draws the same everywhere. A halo would need a stroked font pass that Xteink's renderer lacks. |
| L3e | Overlay per device | **M8C** (1404 × 1872, 16 grey levels): plates and text in black on white, 38-px text, about 70 px across the plate. **Boox Page** (mono, 1264 × 1680): the same, 34-px text. **Boox Go Color 7**: the cover in colour; the plates and text on the black-and-white layer only, with no colour, so they stay sharp at 300 ppi while the colour layer is 150 ppi. **X4 Pro and X4** (480 × 800): `UI_12`. The text is drawn by the renderer in a landscape orientation (`setOrientation`, the way upstream draws rotated screens; `drawTextRotated90CW`, C `lib/GfxRenderer/GfxRenderer.h:417-419`, is already linked). The plates are drawn in every grey plane by the same `drawSleepBitmap` hook as the bar, so a grey cover stays grey around them. | One plate design, sized per panel. |
| L4 | Battery format | Percent only, as of sleep, with no time. | Xteink often has no clock (R6). The same on both platforms. |
| L5 | Text | ≤ 60 characters; in the Bar and at Top or Bottom in Overlay at most 2 lines, on the Right or Left edge one line (all cut with "…"), in the UI font: Android 9 pt (~38 px on the M8C), Xteink `UI_12`. | Long enough for "If found, please return to the front desk". Short enough for one band. |
| L6 | Colour (Boox Go Color 7) | The cover in colour; the band in black and white. | Kaleido colour is low resolution (150 ppi), so text stays on the B/W layer. |
| L7 | Recommended covers on Android are always full size | **One way, no setting** (the user's ruling, 2026-11-23, after the M8C showed the 400 × 600 thumbnail soft at ≈2.9×). The companion fetches BookOrbit's full-size cover, `GET /api/v1/opds/<id>/cover?t=<token>`, for each book in `pool.json`, when the plugin's `SLEEP_POOL` says the pool changed (a refresh, so the network is already up), never at sleep. It sends the `ETag` (304 keeps the file), fits the cover to the panel once and stores only that (`files/sharp-covers/<id>.jpg`, the original is never kept), removes covers that left the pool, and keeps the rest under a tenth of Orbit's storage limit (24 MB cap), least recently used first. **Sign-in, once per reader:** Sleep screen › *Sharp covers* asks for the BookOrbit OPDS login (the username prefilled from the plugin's KOReader username, editable: OPDS logins are their own accounts). One OPDS feed (`/opds/recent`) is read with it; the cover token is taken from an image link and kept sealed with an Android Keystore key. The password is never stored or logged and is zeroed after the one request. **Fallback, a state, not a mode:** until signed in, or while OPDS is unavailable, the plugin's thumbnail is shown, and the row says so. A 401 or 403 later (the server's secret changed, OPDS turned off, access revoked) drops the token, the row turns to *Sign in again*, and Setup lists *Sharp sleep-screen covers* under Needs you with "Until then: sleep-screen covers come from the small thumbnail and look soft." Sign-in errors: 401 "OPDS username or password not accepted"; 403 "OPDS is off on this server or for this account". Current book keeps its own EPUB cover. Xteink is out of scope. | The thumbnail is the only cover the plugin's login can fetch (B :92); OPDS serves the stored original (B `opds.controller.ts:229`). The token, not the password, is what the cover route needs, and it is scoped to image paths (B `opds-auth.guard.ts` isTokenImagePath). |
| L8 | Labels | None, so nothing says "Recommended" on the screen. | The cover carries its title, and fewer pixels means less ghosting. |
| L9 | Panel sizes | M8C 1404 × 1872, Boox Page and Go Color 7 1264 × 1680 (Boox's published spec, not measured), X4 480 × 800. The sink draws at the panel's real size, read at run time. | Mockups only; nothing is hard-coded. |
| L10 | Ghosting | Two ways, both optional, both generic (no vendor API): set Orbit Companion to the reader's clearest per-app screen mode (Setup's *Screen mode for Orbit*, companion-checklist §3.11), or turn on Sleep screen › **Clearing flash before the cover** (`sleep_flash`, off by default): the dream shows a full black frame, then a full white one, each held until drawn plus 250 ms, then the cover (`SleepFlash`; logcat "sleep screen: flash sequence done in N ms"). A short partial wake lock (3 s cap) keeps the CPU up for it. Off: the cover is drawn directly. `sleep_flash` is the companion's for now; the plugin keeps the value it doesn't send. | The M8C in its default fast mode ghosted the previous page through the cover (2026-11-23); setting the per-app mode cleared it. A whole-panel black/white change clears ghosting on most controllers whatever the mode, for readers where the mode can't be set. |

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
| K2 | Recommended covers come from the reader's own account, so the server's visibility rules decide what can appear (B :240). All three sources, Discover included, are offered on kids' readers too. | BookOrbit's account restrictions already filter what each account can see (the user's ruling, 2026-11-23). |
| K3 | The sleep screen shows no PIN and no unlock, and waking goes where it always went. | The PIN guards settings, not waking. |

### Add-on mode (Android)

| # | Decision | Why |
|---|---|---|
| A1 | **Sleep screen** is a helper, off until switched on, like Wi-Fi switching and sleep sync ([addon-mode §3](addon-mode.md)). | Add-on leaves sleep to the vendor unless the user asks. |
| A2 | It needs no foreground service. The system binds the dream at sleep. The picture sink redraws from a broadcast receiver and the alarm. | Add-on runs no service unless a helper needs one (addon-mode §7.2). |
| A3 | Current book means the last book read **in KOReader**. A book read in the vendor's own reader isn't seen. | Orbify only sees KOReader. |
| A4 | Switching the helper off: the dream sink puts back the vendor's screen saver (P1); the picture sink says "Pick another picture in the Boox Screensaver settings ›" and deletes `sleep.png`. | It leaves the reader as it was. |

### Building blocks

| Piece | Owner | Reuse |
|---|---|---|
| Pool, shuffle bag and leave-out set | companion `SleepPoolBuilder.kt` (on the cache worker's thread, `SLEEP_REFRESH`); rules `SleepPoolLogic.kt` (bag, Leave out, Every sleep's batch). Current cover and settings: plugin `ko/sleepscreen.lua`, `logic/sleep_pool.lua` | write-through cache reads, `Cache` covers, `FileManagerBookInfo:getCoverImage` |
| Rotation rule, bag and leave-out check | companion `SleepScreenLogic.kt`; Xteink `orbify/core/SleepPick` (bag order, sorted-ID file search) | `shared/fixtures/sleep/cases.json` |
| Dream sink | companion `SleepDream.kt` (`DreamService`, `BIND_DREAM_SERVICE`) | `Vendor` profile picks the sink |
| Picture sink | companion `SleepPicture.kt` | the same renderer as the dream (one `SleepCanvas`) |
| Sharp covers (L7) | companion `SharpCovers.kt` (sign-in, sealed token, fetch, Setup row); rules in `SharpCoversLogic.kt` (token from the feed, status codes, fit, prune) | `SLEEP_POOL`; `pool.json` `server`/`user`; one entry point (`SharpCovers.sync`) for the companion's worker (`docs/design/companion-worker.md`) to absorb |
| Xteink band, overlay and pick | patch `0039-orbify-sleep-screen.patch` and `xteink/orbify/SleepScreen.cpp`, `SleepSettings.cpp`; rules in `core/SleepPick` and `core/SleepLayout` (host tests read `shared/fixtures/sleep/cases.json`, as Android's do). One line in `drawSleepBitmap` and one in `renderDefaultSleepScreen` (the bar or the overlay plates); BookOrbit Pick ahead of `renderSleepScreen`'s switch; the store keeps the cover shown and the battery level for the redraw | `downloadThumbnail`; `JpegToBmpConverter`; `LentConnection` and `orbifyRequest`; `SettingInfo::DynamicEnum`/`DynamicString` |
| Switches | `CROSSINK_TAILNET_ORBIFY_SLEEP` (0,1,1): off on the X3 by design; its settings' strings are left out of the X3's i18n scan (`ORBIFY_I18N_SKIP`) | `tailnet_build.py` |

Tests: the rule table (both platforms), the band and overlay layout (`orbify/core` host test: text wrap, band
height, cover rect, plate rects for each text position and battery corner, and the battery's move, on each panel), the pool parse and build (companion `SleepPoolTest`, recorded section reply
in `shared/fixtures/`), and a `ReadingGuardTest` entry for the dream (system-started, never during
reading).

## Scope sources and Leave out on the X4s

They fit, because nothing is held in memory longer than one page:

- **Picker:** the sleep sync saves the two section lists (first 100 of each) once a day to
  `scopes.tsv`, which Settings reads; Settings never goes online for them. A section reply is a few
  KB, parsed with an ArduinoJson filter for `id`, `title` and `count`. Pick From lists them by name;
  Leave Out Scopes opens straight onto a list of toggles by name (the web settings page types
  `scope:<id>,collection:<id>`).
- **Listing members:** the sleep sync fetches `books?…&size=100` pages on the lent session, at most
  10 pages per sleep (like the mirror's slices). Each reply is parsed as a stream with a filter for
  `items[].id`, `hasCover`, `updatedAt` and `hasNext`. The filtered document holds about 100 small
  records (a few KB), never the reply. The IDs go straight to the SD card. A large scope takes a
  few sleeps to list; until it is complete, X7 applies (fail closed).
- **Using them:** the bag is a file of `uint32` IDs plus a cursor, and the leave-out set is a sorted
  `uint32` file searched in place. Picking a cover reads a few bytes; the heap doesn't grow with the
  scope's size.
- **Tags:** the book's detail, parsed with a filter for `tags`, `hasCover` and `readStatus`, before
  its cover is fetched: at most 8 details per sleep sync.
- **Caps:** bag 500, leave-out 4,000 IDs. Over a cap, the newest (`recently_added`) are kept, and the
  sleep sync logs "lists over 500 books: using the newest 500" (not shown in Settings yet).
- **Memory:** the ID lists are allocated in PSRAM; each request checks `OrbifyHeap::roomForRequest`;
  a decode waits for the next sleep when PSRAM's largest block is under 96 KB ("decode waits").

## The X3

The X3 is left out by design (the user's ruling, 2026-11-23): it keeps exactly the sleep screens
upstream CrossInk ships, and Orbify adds no text, battery, Bar, Overlay, BookOrbit Pick or
settings rows to it. Every sleep-screen switch is 0 for the `default` env in `tailnet_build.py`.
This is not a flash fallback, and its CI gate needs no drop order for it.

## Open decisions

No open decisions. Everything above is a two-way door, settled here, or the user's ruling below.

## Choosing the Orbit screen saver on the Meebook (the user's ruling, 2026-11-23)

Choosing it means writing `screensaver_components` (with `screensaver_enabled` and
`screensaver_activate_on_sleep`), which are Android secure settings that the companion can write
only with `WRITE_SECURE_SETTINGS`. That permission can be granted only over USB, and the Meebook
hides the system Screen saver page (to check in the probe).

| # | Decision |
|---|---|
| P1 | **An optional permission, granted once over USB:** `tools/install-usb.sh --grant-screen-saver` runs `pm grant … WRITE_SECURE_SETTINGS`, and the manifest declares it. With it, the companion switches its screen saver on and off itself. It keeps the vendor's previous three values to restore them, and writes nothing else: a guard test fails on any other `Settings.Secure` key. |
| P2 | **Without the permission:** the one-time command `tools/install-usb.sh --sleep-screen on\|off` writes or restores the three values. The companion's "Set up ›" opens the system Screen saver page where it exists, and otherwise shows that command. |
| P3 | **In the checklist:** an optional row, in the Add-on design's style ([addon-mode](addon-mode.md), the "Optional" table). It is shown only when it helps now (companion-checklist §3.12, the user's ruling 2026-11-24): a dream-sink reader without the permission and without a Screen saver page, whose chosen screen saver doesn't match Sleep screen (on with the reader's own chosen, or off with Orbit's). The M8C, with Orbit's chosen and Sleep screen on, doesn't show it. |

| Optional | Without it | Allow does |
|---|---|---|
| **Screen saver** (`WRITE_SECURE_SETTINGS`, granted over USB): Orbit chooses its screen saver when Sleep screen goes on and puts the reader's own back when it goes off | What the reader shows while it sleeps doesn't follow your Sleep screen setting until you run one USB command, `tools/install-usb.sh --sleep-screen on` (or `off`). | **Show how**: that command for now, and `--grant-screen-saver` to make it automatic |

## Before building

1. Probe logs (no design change expected): M8C power-button sleep on battery; Boox Go Color 7 and
   Page sleep (which component draws, and whether a changed picture file is read again).
2. If the M8C's power-button sleep does not start a dream, the M8C uses the picture sink too, if
   Haoqing's settings can pick a picture. If neither works, the M8C gets the feature only for
   timeout sleeps, and the settings say so.

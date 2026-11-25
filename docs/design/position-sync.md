# BookSync position sync: one setting for seamless, low-battery reading across Orbify

Status: approved with the user's rulings of 2026-11-24 (below). The shared decision table, Android and Xteink firmware wiring are implemented;
device validation remains before release. Platforms: Android (KOReader + BookOrbit plugin + BookSync plugin + BookSync
Companion), X4 Pro, X4, X3. Pins read: BookOrbit `c1dd6b4` (server + `koreader-plugin/`),
CrossInk-Bookorbit `87e2e19` (rc3), Orbify working tree 2026-11-24.

**The user's rulings (2026-11-24), applied throughout.**
1. **Jumps are asked, not silent.** When another place exists, a popup asks: "Continue from
   <device>, p. 214? **Yes / No**", at open or wake **and** when the place turns up after reading
   started (no deferring to sleep). The only silent move: the place is known **before the book or
   page has rendered** (loading, pre-loading): the book opens straight at it. **No** = stay here and
   decline that one remote place (never asked again for it); it is not an override. The popup
   replaces the 4-second "Stay here" line; it is e-ink friendly: one draw, no animation.
2. **A backward override on a finished book starts a reread** in BookOrbit's history: accepted.
3. **"Read from here everywhere"** is the explicit override in the BookSync menu and This book sheet;
   queued offline with the chosen place, and sent before ordinary snapshots.
4. **Furthest wins**; ordinary pushes never go behind the last known server place. Replace the
   old silent jump to any newer-dated place.
5. **The X3 gets the sleep sync only in the first version** (no wake check). Xteink firmware wiring
   is a later separate step; step 1 includes only its host-tested C++ decision function.

**In one paragraph.** Every device syncs at the moments it is already paying for (sleep, open,
wake), never keeps a radio up, and never moves the page by itself while you read. The furthest
place wins. A device never pushes a place behind the server's, so the only way the shared place
moves back is an explicit **"Read from here everywhere"**. Other devices learn of it the next time
they sync. On wake, the page shows at once; the check runs in the background and, if another place
exists, asks once ("Continue from Boox, p. 214? Yes / No"). The Xteink adds a cheap wake check
(X4s only in v1) and pre-fetches the places of the next books you are likely to open during the
sleep sync it already runs.

---

## 1. Current state

### When positions move today

| Moment | Android (plugin + BookSync, recommended settings) | Xteink X4 Pro / X4 | Xteink X3 |
|---|---|---|---|
| Open a book | Plugin pull on open (`main.lua:991-1000`); BookSync brings the network up for it, cap 20 s (`ko/reading_sync.lua:81-101`) | **Nothing** | Nothing |
| Page turns | Plugin periodic push every 3 pages, only if already online (`main.lua:110`, `:1314-1327`); Just-in-time Wi-Fi is off by then, so in practice none | Sync While Reading, off by default (README "Sync while reading", patch 0022); push-only, never applies a newer server place | Not possible (no memory beside an open book) |
| Pause / idle | Nothing | Nothing | Nothing |
| Sleep | Plugin snapshots to its outbox (`main.lua:1340-1351`); BookSync's sleep sync brings the network up and drains it, 20 s cap, 25 s wake lock (`ko/sleep.lua:9-56`, `:93-133`; android/docs/DESIGN.md "Sleep sequence") | **Sleep sync** behind the sleep screen, if Sync on Sleep is on (default **off**, `BookOrbitCredentialStore.h:42`), an EPUB is open and battery ≥10% (`main.cpp:1540-1552`). Restart into a network boot (`:1582-1593`), push or pull for the **open book only** (build notes B4), then the lent session: Home, covers, next cover, copy refresh, mirror slice (S2, S4); 240 s budget, wake press answered in ≤2 s (S5) | Same, but the Home refreshes on its own connection after the session (S2) |
| Wake | BookSync wake flow: network up (≤20 s), outbox drain, then pull (`ko/start.lua:36-68`) | **Nothing.** The book shows the place the last sleep sync left | Nothing |
| Close | Plugin outbox push (`main.lua:1292-1311`) | Nothing (no Wi-Fi at close, S8) | Nothing |
| Manual | "This book" sheet, gestures | Chord or menu: restart into a network boot, sync, maybe a choice screen (`main.cpp:612-700`, `BookOrbitSyncActivity.cpp:565-596`) | Same |

### How conflicts are decided today

- **Android plugin: newest wins, not furthest.** A pulled place is "forward" when its timestamp is
  later than this device's last page turn, whatever its position
  (`bookorbit_progress_sync.lua:464-472`, `remoteProgressIsNewer` `:157-167`). Orbify's
  recommended "further ahead → Silent" (`logic/recommended.lua:24`) then **jumps backward silently**
  to any newer-dated place. Pushes are stamped with send time (`:325`, `os.time()`), and the
  server accepts a behind position stamped "now" (server-contract "The stale-push guard compares
  send times"). So a device opened at an old place and put to sleep drags every other Android
  device back, and can open a reread on the server (≥10 points lower, server-contract "Reread
  evidence"). Only finished books are protected (`Finish.holdPush`, end-of-book §7).
- **Xteink Smart sync**: same place / server moved / local ahead, with a marker of the last sync
  (`BookOrbitSmartSync.h:135-150`). When both moved, or the device went back, it **asks**; in a sleep
  sync nobody can answer, so the progress is "left for the next manual sync"
  (`BookOrbitSyncActivity.cpp:583-588`). Default behaviour is Ask every time (`BookOrbitCredentialStore.h:41`).
- **Server**: a push is dropped only if stamped earlier than the newest known one *and* not further
  (`koreader.service.ts:263-268`, `reachesFurther` `:290-305`). A web-UI "reset" is served as the
  start of the book, dated now, and holds every device's pushes until that device reports the
  start (`:559-591`, `resolveResetHold` `:324-357`). There is no device push channel or long-poll on
  the KOReader routes (`koreader.controller.ts` route list), and no per-book field a device can
  write besides position, device name and timestamp (`KoreaderSaveProgressDto`; `metadata` is not stored).

### Radio cost and timings (from the repo)

| Item | Figure | Source |
|---|---|---|
| Xteink network boot to IP | ~4.8 s | build notes S15 ("IP at 4754") |
| Tailscale register / map | ~0.2 s normally; 3.6 s + 22 s silence when the control plane stalls | S15 |
| TLS handshake, heap starved | 14 s, 47 KB reply 82 s (before the floors) | S1 |
| Heap beside Tailscale (X4 Pro) | ~30 KB internal free; floors now 12 KB kept request, 20 KB new session | S1, H2 |
| Sleep sync budget | 240 s, mirror slice ≤30 s, copies ≤180 s | S4, S5, keep-copies R6 |
| Deep sleep | S3 (X4s): latch kept, real deep sleep, an RTC timer could wake it; C3 (X3): latch released, nothing can wake it but the button | `HalPowerManager.cpp:173-210` |
| Android network up | cap 20 s; wake lock cap 25 s; Just-in-time Wi-Fi off after 2 idle min | android DESIGN "Wi-Fi modes", `ko/settings.lua:16-19` |
| Plugin debounce | 25 s between automatic pushes/pulls | `bookorbit_progress_sync.lua:26` |

**No measured energy per sync exists** in the repo. `orbit-battery-stats/1` ships on both platforms
(XTEINK-BATTERY-STATS.md, STATS-DESIGN.md) and can split standby by `wifi_radio`; §4 estimates are
labelled and should be replaced from it (§6).

### Where the user feels it today

1. **Xteink after reading elsewhere**: wake shows a stale page; the fix is a manual sync (restart,
   ~10-25 s, then often the choice screen). Or they read the stale part again.
2. **Android jumps back** to another device's stale place (newest-wins + stale pushes).
3. **Xteink "left for the next manual sync"** whenever both sides moved: silent, nothing resolves it.
4. **Mid-book jumps on Android** when a pull lands after reading started (BookSync's reading sync and
   the plugin's `NetworkConnected` pull both apply "Silent"; `ko/reading_sync.lua:162-164`).
5. Switching books: the Xteink syncs only the open book, so a book read on Android opens stale.

---

## 2. Design space

| Option | Where | Cost | Verdict |
|---|---|---|---|
| Push on page-turn debounce (every N pages) | A, X4 | A join per push unless the radio stays up; the radio is off while reading | **No** as a default; keep under Custom |
| Push on pause (no turn for 2 min, place moved) | A, X4 | One join per pause, ~1-3/day | **Yes**: covers "put A down, pick B up" without sleeping A |
| Push on close / suspend / sleep | A, X4, X3 | Already paid | **Yes** (exists), with the behind-hold (§3) |
| Pull on open | A (exists), X4 | One join | **Yes**; X4 in the background; X3 via pre-fetched places |
| Pull on wake | A (exists), X4 (new, 0022 task), X3 (new, behind the page) | One join per wake | **Yes**, skipped after a short sleep |
| Pre-position at sleep (pull, apply while asleep) | X (exists), A (new) | Same connection as the push | **Pull yes, apply no** (ruling 1): the place found is asked at the next wake |
| Pre-fetch places of the next likely books at sleep | X (new, lent session), A (not needed: open pull is fast) | ~0.3 s per request on the kept session | **Yes**, top 3 on-device "Continue reading" |
| Server push / long-poll | — | Not offered by BookOrbit's device routes; radios are off anyway | **No** |
| Opportunistic piggyback (radio up for catalog, OTA, mirror) | A, X | Free | **Yes**: every connection runs the open book's check first |
| Keep the radio up for the first N minutes after wake | X4, A | X4: ~80 mA for N min ≈ 1%/5 min; A: ~10 mA | **No**: one pull costs a fraction of that |
| Timed RTC wake to pre-sync while asleep | X4 only (C3 cannot) | ~12 s of radio per wake, even on a shelf | **Not v1**; revisit if late jumps exceed 20% (§6) |
| Android background pulls (WorkManager, Doze windows) | Companion | Breaks ruling 2 (the companion never holds the login, android DESIGN); KOReader frozen | **No** |
| Lent session for the wake check | X4 | Wake check is one GET; no catalog work at wake | Wake stays light; catalog work stays in the sleep sync |

---

## 3. The BookSync position sync policy

### 3.1 One decision, both platforms

A pure function, host-tested on both sides from one fixture file
(`shared/fixtures/orbismart/cases.json`, like `reading-quiet`). It replaces
`BookOrbitSmartSync::decide` (Xteink, in `xteink/orbify/core/`) and the plugin's
forward/backward strategies (Android, in BookSync `logic/`).

Inputs: **L** local place; **R** server place mapped to local pages (Xteink
`BookOrbitRemotePosition::toLocal`; Android `document:compareXPointers`, percent only as fallback);
**M** this device's marker of its last sync (server timestamp + place; Xteink has it,
`BookOrbitSyncMarkerFile`; Android adds one per book in BookSync's settings); **readHere** = L moved
more than one page from M; **serverMoved** = R's timestamp ≠ M's and not merely re-dated
(`onlyRedated`, `BookOrbitSmartSync.h:119`); **T_turn** = this device's last page turn.

| # | Condition | Decision |
|---|---|---|
| 1 | L and R within one page | **same**: refresh M |
| 2 | R is BookOrbit's reset (served by the server, `RESET_DEVICE`) | **follow** (the user reset it in BookOrbit) |
| 7 | Book finished (read on the server or here) and L earlier | **hold**: keep L, no push, no move, until the end-of-book hold releases (≥10 forward turns or Read again); released: **push L** (the reread; the behind-hold does not apply). The end is never a jump target in a reread |
| 3 | R further than L | **take R** (3.2: silent before the page renders, else asked) |
| 4 | L further, server did not move | **push L** |
| 5 | L further, server moved, **not readHere** | **follow** R: it moved back on purpose (an override) |
| 6 | L further, server moved, readHere | R dated more than 10 min after T_turn → **follow**; else **push L** (furthest) |

Checked in the order listed (7 before 3). Two more inputs:

- **Declined** (ruling 1): the reader answered **No** to this remote place (same server timestamp).
  A take or follow becomes **stay**: no move, no push, never asked again for that place. A later
  remote place (another timestamp) is decided afresh. Reading on here past R is rule 4/6 as usual.
- **Queued override** (3.5): sent first. If the server moved after the override was made (R dated
  after it, and not merely re-dated), the override is **dropped** and the rules above decide.
  Otherwise **override**: push L, skipping the behind-hold once.
- **Percent only** (R has no position, §5): same-place tolerance is 2 %, and a backward
  percent-only R is never followed: L is pushed (furthest).

**Behind-hold (all pushes).** A device never pushes a place behind the last server place it knows,
except an override or a released reread (rule 7). Every connection pulls before it pushes (the
Xteink already does; Android's outbox drain waits for BookSync's pull, extending
`hookPluginPagePush`, `ko/module.lua:78`). This is what makes rule 5 safe: inside Orbify, a
backward move on the server is always deliberate.

The table is `shared/fixtures/orbismart/cases.json` (sections `decide`, `apply`, `push`): the Lua
`OrbiSmart` (internal policy identifier; `android/koreader/orbit.koplugin/logic/orbismart.lua`) and the C++
`orbify::orbismart` (`xteink/orbify/core/OrbiSmart.{h,cpp}`) both run every case.

### 3.2 When a place is applied

Ruling 1 replaces the jump window. A take or follow is applied by the moment it is found:

| Moment found | Applied |
|---|---|
| **Before render** (the book is loading, or the place was pre-fetched/known before the first draw) | **now, silently**: the book opens straight at R |
| Open or wake after the page has rendered, while reading, at a pause | **ask** now: the popup |
| Sleep (screen off) | **ask at wake**: remembered, the popup shows on the next wake before any network |
| Close | **no**: the next open decides again, before render |

The popup, drawn once (no animation, no timeout): **"Continue from Boox, p. 214?"** with **Yes** and
**No**; a backward follow reads "Continue from X4 Pro, p. 12 (moved back there)?". **Yes** moves to
R and sets M to it. **No** stays, records R as declined (no push; never asked again for it). It is
not an override; "Read from here everywhere" is. Only one popup at a time: a newer R replaces an
open one. No choice screen anywhere.

### 3.3 Android state machine (per open book, KOReader in front)

| State | Trigger | Action | Timeout |
|---|---|---|---|
| Opening | ReaderReady | Show local page; network up; pull; decide; take/follow → **popup** (the page has rendered); push L | network 20 s |
| Opening, known before render | A remote place already in memory for this book (last pull this session, or remembered at sleep) further than the saved page | Open straight at it, no popup (ruling 1) | — |
| Reading | page turn | Restart the pause timer | — |
| Paused | 120 s without a turn and L moved >1 page since the last push | Network up, pull, decide; push L; take/follow → **popup** (mid-reading discovery, ruling 1); Wi-Fi back per its mode | 20 s |
| Going to sleep | Suspend, screen off (existing sleep sync) | Pull, decide, push (behind-hold); take/follow → remembered for wake | 20 s cap, 25 s wake lock (unchanged) |
| Waking | Resume after a real sleep | Popup for a place remembered at sleep; if slept ≥5 min: wake flow as Opening | 20 s |
| Closing | CloseDocument | Outbox push under the behind-hold | plugin's own |
| Any connect | NetworkConnected | Outbox drain under the behind-hold; the plugin's own pulls never move the reader | — |

Per book, BookSync keeps a **sync marker** M (server timestamp and place of the last sync, the
declined remote place, a queued override) in its settings (`S.orbismart[digest]`).

Under BookSync position sync the plugin's "further ahead" and "further behind" are both **Don't sync** and its
page push is off: BookSync reads with `fetchRemoteProgress`, decides, and calls `syncToProgress` or
`requestProgressPush` (all already hooked, `logic/compat.lua:13-29`). The Wi-Fi mode stays the
user's (Just in time is the right partner).

### 3.4 Xteink state machines

**X4 Pro / X4** (sync beside an open book is possible: patch 0022, wolfSSL in PSRAM, H1-H2):

| State | Trigger | Action | Timeout |
|---|---|---|---|
| Sleep sync | Every sleep with an EPUB open (Sync on Sleep forced on) | 1) queued override, 2) open book: pull, decide, push, or remember R for the wake popup (ruling 1), 3) finish queue, 4) **places of up to 3 other on-device books** from Home's Continue reading, saved as a small "pending place" per book, 5) the lent-session work as today | 240 s (unchanged); wake press 2 s |
| Wake | Power press after ≥10 min asleep | Show the page at once (unchanged wake), start the background task (`trigger=wake`): join, pull, decide; a take/follow asks with the popup | task stops on the existing reader-close wait |
| Open another book | Library / Home | A pending place newer than the book's marker is decided **offline** before the first draw; no pending place → background check as at wake | — |
| Paused | 120 s without a turn, moved | Background pull and push; a take/follow asks | existing task |
| Manual sync | Chord / menu | Same decision, no choice screen | existing |

On the Xteink a take/follow found at wake or a pause is asked with the same popup (ruling 1), drawn
once; one found offline from a pending place before the first draw opens there silently.

**X3** (no memory beside a book; flash 99.38%, F1): **v1 is the sleep sync only** (ruling 5):
pending places on their own connection after the session, as the Home today. Later, not v1: a
**wake check behind the page**: after
≥30 min asleep, draw the page, then restart into a network boot that leaves the panel as is (the
sleep sync's trick, `main.cpp:1582-1593`), pull, decide, and restart into the book: at the new place
with the notice, or at the same page without a redraw. A watcher like the sleep sync's ends it on
any button within 2 s and replays the press. Budget 25 s. Cost of a fast reader: one slow page turn
(~2-3 s) per wake.

### 3.5 "This device overwrites" (override / reset)

| Question | Design |
|---|---|
| Where | Reader menu: **"Read from here everywhere"** (Android: BookSync menu and the "This book" sheet; optional gesture. Xteink: reader menu › Sync). The popup's **No** is not an override (ruling 1). |
| What it does | Pushes the current place now, stamped now, skipping the behind-hold once; sets M to it. |
| How long | One shot. From then on furthest wins again, counted from this place. Rereading from chapter 1 needs it once, not every session. |
| Offline / X3 mid-book | Queued (one per book, newest wins, two-slot file like `orbify_finish.bin`), sent **first** at the next sync. If the server shows reading elsewhere after the override was made, it is dropped and logged; furthest wins. Until it is sent, this device does not move or ask for that book. |
| How others learn | Rules 5-6 at their next pull (wake, open, pause, sleep): an idle device follows; a device with older unsynced reading follows; reading made after it elsewhere is compared by furthest. They ask with the popup ("… (moved back there)?"), or move silently before render. |
| Finished book | Moving 10+ points back on a finished book starts a reread in BookOrbit's history (server-contract "Reread evidence"): accepted (ruling 2). |
| Reset to start | BookOrbit's own reset is followed on every device (rule 2); Orbify adds nothing. |
| Who sees anything | Only the devices that would move: one popup each. |

---

## 4. Battery and disruption estimates (a typical day)

Assumptions (estimates, to be replaced by measurement, §6): two readers, 1 h each in 3 sessions of
20 min, one device switch mid-day. Xteink quick sync (wake, pause) ≈12 s at ≈110 mA ≈ 0.37 mAh;
sleep sync with its catalog work ≈45 s ≈ 1.4 mAh; battery 650 mAh (the X3's gauge figure,
XTEINK-BATTERY-STATS §1; X4 capacity unrecorded). Android quick sync ≈6 s at ≈200 mA above base ≈
0.33 mAh plus a 2-min Just-in-time tail ≈0.33 mAh; battery ≈3000 mAh.

| | Today (Xteink: Smart + Sync on Sleep on; Android: recommended) | BookSync position sync |
|---|---|---|
| X4 radio per day | 3 sleep syncs + ~1 manual sync ≈ 4.7 mAh ≈ **0.7 %** | 3 sleep syncs + 3 wake checks + ~2 pause pushes ≈ 6.0 mAh ≈ **0.9 %** |
| X3 radio per day | ≈ 4.7 mAh ≈ 0.7 % | v1: 3 sleep syncs ≈ 4.2 mAh ≈ **0.65 %** (later, with wake checks: ≈ 5.6 mAh ≈ 0.85 %) |
| Android radio per day | 6 flows ≈ 4 mAh ≈ **0.13 %** | + ~2 pause pushes ≈ 5.3 mAh ≈ **0.18 %** |
| For contrast: radio always on | — | Android Wi-Fi + Tailscale in standby ≈10 mA × 22 h ≈ 7 %/day; Xteink radio up while reading ≈80 mAh/h ≈ 12 % per hour (and impossible asleep) |
| Stale page after switching devices | Xteink: every switch until a manual sync | One popup at wake or open (or none: opened straight there before render); X3 v1: from its own sleep sync |
| Manual syncs | ~1/day on the Xteink (10-25 s each + choice screen) | ~0 |
| Choice screens | Xteink, whenever both sides moved | none |
| Backward surprises | Android jumps back to stale pushes | none: a move back only after an override, and asked |
| Mid-book jumps | Android possible (reading sync, NetworkConnected) | none silent: a place found mid-book is asked |

Net: about +0.2 points of battery per Xteink per day and +0.05 on Android, for zero manual syncs.

---

## 5. Edge cases

| Case | Behaviour |
|---|---|
| Offline for days | Reading accumulates locally; nothing queues but overrides and finishes. On reconnect: pull, decide; furthest wins; a deliberate backward move made meanwhile wins only over reading older than it (rule 6). A late-stamped push is still accepted by the server because it is further (`reachesFurther`). |
| Two devices reading at once | Pause pushes keep the server within ~2 min of each; a place found mid-book is asked once (No declines it); the other side answers at its next wake. |
| Clock skew | Rules 1-5 compare timestamps for equality only (skew-proof). Rule 6 orders clocks with a 10-min margin and falls back to furthest. Xteink sets the clock by NTP at each sync; without Keep Clock in Sleep its page-turn time comes from the WallClock checkpoint. |
| Re-downloaded copy, no local history | No marker: take R if it exists (no choice screen). |
| Different file version (hash moved) | Keep copies current migrates place and marker (keep-copies R5, `BookUpdateMigration`). If the server answers `positionCompatible: false`, R is percent only: take R only if it is further by more than 2 %, never follow a backward percent-only move. |
| Page vs percent between renderers | Never compare raw percentages across platforms when an xpointer exists: Xteink maps the xpointer to spine/page (±1 page, `PAGE_TOLERANCE`); Android compares xpointers. Pushes carry the xpointer (`ProgressMapper::toKOReader`). |
| BookOrbit web reader opening a book | Re-dated only (same chapter, at or before M): ignored (`onlyRedated`; Android gets the same rule). |
| Accidental jump forward on one device (scrubbed to 90 %) | It propagates (furthest). Other devices ask; answer No, then "Read from here everywhere" from the right place on any device. |
| Flip back to check a map, then sleep | Not an override: the behind-hold keeps the server's place and the next wake returns to it. |
| Finished book reread (kids' favourites) | Rule 7: the end is never a jump target; the end-of-book hold decides when the reread pushes. |
| Kids' devices | Own BookOrbit accounts, so no cross-talk; same policy; the override is a reading action, not behind the settings PIN. One account shared by two people is not supported (furthest would fight). |
| Low battery | Xteink sleep sync already skips below 10 % (`main.cpp:1546-1550`); wake and pause checks skip below 15 %. |
| Wake check fails (no Wi-Fi, Tailscale stall S15) | Silent; read from this device's place; the sleep sync tries again. Android keeps its gated wake banner. |
| Popup answered No | That remote place is declined (no push, never asked again); a newer remote place asks again. |
| Several books in play | Xteink pre-fetches 3 on-device Continue reading books per sleep; Android pulls on open. |

---

## 6. Rollout

**Setting.** "Reading position" with two values: **Furthest page wins** and **Custom**.
Help: "BookSync keeps the furthest place you've read on any device, and asks before jumping." Android: first row
of Companion Settings › Sync, mirrored in KOReader's BookSync menu (one schema, companion-settings.md).
Xteink: first row of BookSync › Sync. BookSync position sync presets and hides:

| Platform | Settings it sets (Custom shows them again, last values kept) |
|---|---|
| Android | Plugin: auto-sync on; further ahead and further behind: Don't sync (BookSync decides); push every N pages off. BookSync: sync on wake on, sync on sleep on, Sync while reading → "When you pause". Wi-Fi mode untouched. |
| Xteink | Sync behaviour Smart (BookSync position sync rules), Sync on Sleep on, Sync While Reading → "When you pause" (X4s), Wake check on. Mark Finished at End untouched. |

New installs get BookSync position sync. On update it follows the recommended-settings rule (addon-mode §5): applied
where the sync settings are still at their defaults or Orbify's recommended values; otherwise offered
as a Setup checklist row with "what you lose without it".

**Phases.** 1) The shared decision table (Lua + C++ host-tested function), Android BookSync position sync
(setting, behind-hold, state machine, popup, override, marker). 2) Xteink: X4s sleep sync rules +
pending places + wake check + popup + override; X3 sleep sync rules only (ruling 5). 3) Later: the
X3 wake check behind the page (flash permitting: the X3 is at 99.38 %). Each: sideload test, then release
(AGENTS "Test builds").

**Log lines** (same words on both platforms; one per decision):
- `orbismart: <rule> L=<p> R=<p> -> <decision> (<moment>, <applied>)`, rule one of `rule1`…`rule7`,
  `declined`, `override`, `override-dropped`, `percent`, `no-server`; decision one of `same take
  follow push hold stay override`; applied one of `now ask wake no`
- `orbismart: popup <from>-><to> yes|no after <n> s`
- `orbismart: push held L=<p> R=<p> (behind the server)`
- `orbismart: override sent|queued|dropped`
- `OrbiSmart: pending places saved <n>/<m>`; at open `pending place used (offline)`
- Daily in the battery-stats file: syncs, radio seconds, jumps, late finds, holds, Stay-here count.

**It works when** (per device, real use): 10 device switches in a row land on the right page with no
manual sync; no backward server move without an override line; Stay-here under 10 % of jumps; late
finds under 20 % of wake checks; battery-stats standby and reading rates within +0.5 %/day of the
week before BookSync position sync.

---

## 7. Self-grill

**Two-way doors, settled (recommendation, reason).**

| # | Question | Decision | Why |
|---|---|---|---|
| 1 | One rule set or per platform? | One pure function, one fixture | The two sides already disagree (newest vs smart); one table ends that. |
| 2 | How does an override reach other devices with no server field? | Behind-hold everywhere, so any backward server move is deliberate; idle devices follow it (rules 5-6) | BookOrbit stores nothing else a device can write; a marker in the `device` string would add rows and odd names in BookOrbit's UI and break the plugin's own-push check (`device == Device.model`). |
| 3 | Risk of rule 5 | A stale push from a non-Orbify client (stock KOReader, Kobo) can pull idle devices back | Rare in this setup; the server's own late/reset guards still apply; the fix is one "Read from here everywhere". |
| 4 | Override lifetime | One shot | Sticky modes need an end condition nobody can see. |
| 5 | Jump window | Replaced by ruling 1: asked whenever found, silent only before render | The user's ruling. |
| 6 | Pause push vs interval | Pause, 120 s, moved >1 page | Covers device switches; intervals cost radio while nobody switches. |
| 7 | Timed RTC wakes on the X4s | Not in v1 | Wake check covers it cheaper; revisit from the late-find rate. |
| 8 | Android background pulls | No | Ruling 2 (companion has no login); KOReader is frozen asleep. |
| 9 | Wake-check thresholds | X4 ≥10 min asleep, Android ≥5 min (X3: no wake check in v1) | A short nap rarely follows reading elsewhere; X3's check costs more. |
| 10 | Pre-fetch other books | 3 on-device Continue reading books, X only | Cheap on the lent session; Android's open pull is fast. |
| 11 | Choice screen | Gone under BookSync position sync, kept under Custom; the Yes/No popup is not a choice screen | Furthest wins; the reader only confirms the move. |
| 12 | Same-place tolerance | ±1 page (xpointer/spine-page), 2 % for percent-only | Existing `PAGE_TOLERANCE`; percent across renderers is loose. |
| 13 | Skew margin | 10 min, then furthest | Safe default; an override can be repeated. |
| 14 | X3 wake check redraw | Restart without a redraw when nothing changed | Avoids a flash on an unchanged page. |
| 15 | Kids | Same policy; override not PIN-gated | Rereads are reading, and rule 7 handles favourites. |
| 16 | Name and place | "Reading position: Furthest page wins / Custom", first row of the sync settings | One choice; details only under Custom. |

**Decided by the user.**
Both were decided on 2026-11-24 (rulings 1 and 2 at the top): the jump is a Yes/No popup at open,
wake or mid-reading (silent only before render), an exception to "nothing interrupts reading" that
the user chose; and a backward override on a finished book starting a reread is accepted.

## Xteink firmware wiring (W10)

`OrbiSmartSync` adapts mapped CrossInk positions to the shared decision function. Sleep and
background syncs pull before any ordinary push. A move discovered while the sleep screen or reader
is visible is persisted for the reader's Yes / No popup; another book's prefetched place can
be applied before its first draw. The popup uses CrossInk's existing touch and button mappings,
with no timer or animation. Another background discovery can replace the open question.

Each book has two checksummed `OSM1` records in `/.crosspoint/orbismart/<hash>.0` and `.1`.
The newest complete generation wins. Records are scoped to the BookOrbit server and account and
keep the declined timestamp, pending wire position, last turn, sleep time, finish-hold baseline,
and one exact queued override. A failed write preserves the other slot. An override is tried
before ordinary progress and the finish queue; failed sends retain it, and later remote reading
can drop it under the shared decision rule.

X4 Pro / X4 reuse the cancellable Sync While Reading task: an open/wake check after a real sleep
of at least ten minutes, and a pause check after 120 seconds without a turn and more than one page
of movement. Checks skip below 15% battery. The X3 builds no background task; it consumes sleep
discoveries and cached pending places offline. Sleep sync refreshes Continue reading, then saves
the places of its next three on-device books; the X4s reuse the kept session, and the X3 fetches
them after Home's session closes.

**Wi-Fi coordination:** W9's shared when-to-connect table was absent from main when W10 was
wired. This follows Android's Just in time policy: join for the sync, reuse an already connected
radio, and disconnect only a connection the sync brought up. Sleep owns its existing radio hold.
The Wi-Fi setting stays independent of BookSync position sync; W9 can supply its shared policy at the existing
connection boundary without changing the position decision.

The X3 reader activities compile with GCC `-Oz` and link-time optimization. Its network, OTA, TLS
and MicroLink sources keep their original compiler settings; no reader feature is removed.
The unmodified main baseline had only 697 bytes of headroom below the 99.5% gate, so the
new position state machine needs this reduction. The simulator keeps its normal build settings.

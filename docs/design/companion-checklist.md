# Companion setup checklist: one summary, grouped rows, plain words

ROADMAP 10a. Android only (BookSync Companion). Status: **building**: approved (PR #20) and built in
the companion (`C/ChecklistLogic.kt` for the rules, `C/ChecklistUi.kt` for the drawing,
`Setup` in `C/Pages.kt` for the rows); not released yet.
Mockups: [`companion-checklist-mockups.html`](companion-checklist-mockups.html).

## 1. Outcome

The Setup page answers one question at a glance: **is this reader set up, and if not, what do I
do next?** On a set-up reader it fits on one screen with no scrolling. Only what needs the user is
expanded, each with one verb. Every row that is off, skipped or optional says, in plain words,
what doesn't work without it.

## 2. What is there today (verified)

v0.11.2 on a Boox Page shows one flat list of up to 22 rows of equal weight, each with a tick and
"done" or "open ›" (`C/Pages.kt` `SetupActivity.render`, rows from `Setup.allChecks`). The problems:

- **No summary.** "Full setup (12/14)" is in the header; nothing says "all set" or what's left.
- **Done rows take the same space as open ones.** On a set-up reader, 12 rows of "done" push the
  one open row off screen.
- **Same thing, several rows.** Battery is three rows (BookSync, Tailscale, KOReader).
- **Jargon and internals.** "BookSync plugin answered · last 17:19 (NET_UP)", "(device admin)",
  "Always-on on", "set App battery usage › Unrestricted".
- **Labels are instructions, state is a word on the right.** "Set BookSync as Home app … done".
- **Tests and tips are mixed in with steps.** The Wi-Fi test, "BookSync plugin answered", Play
  Protect and the freeze tip sit between permissions.
- **Losses are only spelled out in Add-on's optional rows.** A skipped Full step, or a required
  step not done, never says what is broken.

`C/` = `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/`.

### 2.1 Every row the companion can show today

| id (`SetupAttention.idOf`) | Today's label | Shown when | States | Action today |
|---|---|---|---|---|
| `managed` | Family Link supervision / Managed device | a supervisor or managing app | tip (Got it) | Help |
| `play_protect` | Play Protect scans installs | Play Store present | tip | Help |
| `freeze_tip` | Launcher can freeze apps | vendor can freeze, nothing frozen | tip | Help |
| `disabled` | Not disabled by the system (KOReader, Tailscale, BookSync) | always (Add-on: only while frozen) | done / frozen | re-enable page |
| `install_updates` | Install updates | always | done / not | system page |
| `koreader` | KOReader app installed (vX) | always | official / missing / other signer / downloading | Install / Check |
| `plugin` | BookOrbit plugin installed (vX) | always | ok / missing / too old / downloading | Install |
| `patch` | BookSync plugin installed (vX) | always | current / outdated / missing / installing / **restart pending** | Fix / Restart KOReader (PIN-free) |
| `signed_in` | Signed in to BookOrbit | always | yes / no / **checking** | Open |
| `recommended` | Recommended settings | always | applied / reviewed / N to review / **checking** / pending next start | Review |
| `home` | Set BookSync as Home app | Full | yes / now: other | Home settings |
| `notifications` | Allow notifications | always | on / off | system page |
| `battery:BookSync`, `battery:Tailscale`, `battery:KOReader` | Battery: Unrestricted (app) | always (Add-on: one optional row with helpers) | on / off / not installed | app battery page |
| `tailscale` | Tailscale signed in and connected | always (Add-on: info, if installed) | connected / not / missing / frozen / lockdown | Tailscale / VPN settings |
| `admin` | Allow "lock screen" (device admin) | Full (Add-on: optional with Sleep sync) | on / off | device-admin prompt |
| `clicker` | Clicker buttons … | a clicker mapped or a PIN set | on / off / not running | accessibility settings |
| `keymapper` | Key Mapper also remaps keys | another key filter is on | warning | accessibility settings |
| `keyboard` | BookSync keyboard enabled | a Send-key action mapped | on / off | keyboard settings |
| `patch_seen` | BookSync plugin answered | always | last time (via) / never | open KOReader |
| `wifi_test` | Wi-Fi off/on test | always | result / never run | Run |
| `screen_saver` (PR #17) | Screen saver | only when it helps now (§3.12) | mismatch | show the USB command |
| `screen_mode` | Screen mode for BookSync | Sleep screen on (any sink) | set by the user / clearing flash on / off | How (I've set it, Use a clearing flash instead, Skip) |

Plus, in Add-on, the optional rows from `AddonLogic.OPTIONAL` (`C/ModeLogic.kt:188`) and the two
helper features (Wi-Fi switching, Sleep sync). Around the list: "Fix next" (`SetupWalk`), "Don't ask
about this" and "Later" on the prompt (`AttentionActivity`, `SetupAttention.ignored` / `snooze`),
"Show hidden tips", and the mode line.

## 3. The design

### 3.1 One page, top to bottom

1. **Header:** "Setup", "‹ Back". (The mode moves to the bottom line, §3.9.)
2. **Summary card**, always first, one of:
   - **All set** ✓ "Everything this reader needs is done." When any optional or skipped item is
     shown, it reads "Everything this reader needs is done. Optional items below." (user's copy).
   - **2 things need you** with a solid **Fix next** button (today's `SetupWalk`) and "Goes
     through each one and comes back here."
   - **Checking…** "Waiting for KOReader to report. Open KOReader once." (only when nothing needs
     the user and something is still checking).
   - **First run:** "Let's set up this reader · 8 steps" with **Start** (§3.8).
3. **Needs you** (only when not empty): every row that needs the user, from any group, expanded:
   name, what is wrong, what doesn't work until it's fixed, and one verb button. A row that worked
   before and stopped says "Stopped working" first. Order: what blocks the most first (installs,
   sign-in, then the rest in group order).
4. **Groups**, each one line when everything in it is fine:
   `✓ Apps · KOReader, BookOrbit plugin, BookSync plugin 0.11.2 ›`. Tapping a group expands it in
   place; only one group is expanded at a time.
5. **Optional** group (when it has rows, either mode): each row with "On: …" or "Without it: …".
6. **Tips** (one line, "2 tips ›") and **Details** (diagnostics, §3.6).
7. **Bottom line:** "Full mode · change in Settings" (or Add-on).

On a set-up reader that is: header, summary, 5 group lines, Optional, Tips, Details, mode: one
screen on the M8C, Boox Page and Go Color 7.

### 3.2 Groups

| Group | Rows (Full) | Collapsed line when fine |
|---|---|---|
| **Apps** | KOReader, BookOrbit plugin, BookSync plugin | KOReader 2025.10, BookOrbit plugin, BookSync plugin 0.11.2 |
| **BookOrbit** | Signed in, Recommended settings | Signed in · recommended settings on |
| **Permissions** | Home app, Install apps, Notifications, Battery, Screen lock, Clicker buttons, BookSync keyboard | 5 of 5 allowed |
| **Connection** | Tailscale, Wi-Fi off/on test | Tailscale connected · Wi-Fi test passed 17:02 |
| **Optional** | rows the user may leave off (§3.5) | 1 of 3 on |

"Not disabled by the system" has no row of its own in either mode: while an app is frozen it is a
Needs you row on the app it breaks ("KOReader is frozen by the launcher · Re-enable"), as Add-on
already does (§4.3 of addon-mode). "BookSync plugin answered" moves to Details; when the plugin has
never answered, the BookSync plugin row shows "Checking…" instead (§3.4).

### 3.3 Wording: one noun, one state line, one loss line, one verb

The **label is a noun** that never changes with the state. The **state line** says what is true now.
When the row isn't done, a **loss line** says what doesn't work. The **button is one verb**.

| Row | Label | Done | Not done: state · loss | Verb |
|---|---|---|---|---|
| koreader | KOReader | Version 2025.10 | Not installed · Until then: nothing to read with | Install |
| plugin | BookOrbit plugin | Version 1.8 | Not installed · Until then: no library, no sync | Install |
| patch | BookSync plugin | Version 0.11.2 | Older than this app · Until then: new fixes don't reach KOReader | Update |
| patch (restart) | BookSync plugin | — | Installed; KOReader still runs 0.11.1 · It restarts when the screen next goes off | Restart KOReader |
| signed_in | BookOrbit account | Signed in | Not signed in · Until then: nothing syncs | Sign in |
| recommended | Recommended settings | Applied 7 | 2 of yours differ · Nothing changes until you choose | Review |
| home | Home app | BookSync is the Home app | Now: Boox launcher · Until then: Home doesn't open your book | Set |
| install_updates | Install apps | Allowed | Not allowed · Until then: updates are a download link | Allow |
| notifications | Notifications | Allowed | Off · Until then: updates and steps show only when you open BookSync | Allow |
| battery | Battery | Unrestricted for BookSync, Tailscale, KOReader | KOReader is restricted · Until then: sleep syncs can be late | Fix |
| admin | Screen lock | Allowed | Not allowed · Until then: Sync and sleep asks you to press the power button | Allow |
| clicker | Clicker buttons | On in every app | Off · Until then: buttons work only inside KOReader | Turn on |
| keymapper | (on the Clicker row) | — | Key Mapper is also on · Two key filters fight | Turn off |
| keyboard | BookSync keyboard | On | Off · Until then: Send-key works only inside KOReader | Turn on |
| tailscale | Tailscale | Connected | Not connected · Until then: no sync with your server away from home Wi-Fi | Connect |
| wifi_test | Wi-Fi off/on test | Passed 17:02 (reconnects in 4 s) | Not run yet · never counted | Run |
| frozen | KOReader (or Tailscale, BookSync) | — | Frozen by the launcher · Until then: it can't start, sync or update | Re-enable |
| screen_saver | Screen saver | (hidden: nothing to do) | (optional, shown only when it helps, §3.12) Sleep screen is on, but the reader still uses its own screen saver, so BookSync's cover doesn't show while it sleeps / Sleep screen is off, but BookSync's screen saver is still the reader's · Without it: what the reader shows while it sleeps doesn't follow your Sleep screen setting until you run one USB command | Show how |
| screen_mode | Screen mode for BookSync | On: BookSync draws in the reader's clearest screen mode. / On: the clearing flash runs before the cover. | (optional) Set BookSync Companion to the reader's clearest screen mode (often called HD, Clear or Quality) in its per-app display settings, so the sleep screen draws without ghosting. · Without it: the sleep screen may show ghosting from the last page. | How |

Gone from the screen: "done", "open ›", "(device admin)", "Always-on on" (moved to Details),
"(NET_UP)" (Details), "set App battery usage › Unrestricted" (the battery detail says it where it
applies).

**The loss lines are everywhere, in both modes** (user ruling 2026-11-23): every optional row and
every skipped row shows "Without it: …"; every required row not yet done shows "Until then: …".
One table holds them, keyed by row id (today's `AddonLogic.OPTIONAL.without` grows to every id);
Full and Add-on read the same table. A guard test fails on a row id with no loss line.

### 3.4 States

| State | Glyph (black on white, no colour) | Counts as | Shown |
|---|---|---|---|
| **Done** | filled black box, white ✓ | done | collapsed into its group's line |
| **Needs you** | empty box, thick border; bold verb button | open | in Needs you, expanded, with the loss line |
| **Set by the reader** | filled box ✓ | done | in its group; state line "Set by the reader" and ⓘ |
| **Off / skipped** | box with a dash – | not counted | Optional rows: "Without it: …" and **Allow**. A Full step the user skipped ("Don't ask about this") goes to its group with "Skipped · Without it: …" and **Allow**; never in Needs you, never prompted, until the user taps Allow |
| **Checking** | box with … | not counted, not open | "Checking… open KOReader once" (no spinner, no timer redraw) |

**Set by the reader** is the Boox case: BookSync's battery page says "not available". A separate fix
re-checks the battery settings directly; this state is shown only when the reader's own battery
settings are already right and can't be changed. The words never name a cause. The ⓘ opens a
one-screen note: "This reader's own battery settings already keep BookSync running, and they can't be
changed here. There's nothing to do." Rule: a
setting the reader doesn't let anyone change, and that is already in the state BookSync needs, is
done. If the reader blocks it in the *wrong* state, the row is Needs you with "Can't be changed on
this reader · Without it: …" and no button (Help instead).

### 3.5 Merged rows and the battery detail

- **Battery**: one row for every app that is installed (BookSync, KOReader, Tailscale if installed).
  Done: "Unrestricted for BookSync, Tailscale, KOReader". Not done: names the app(s) left; **Fix**
  opens the first one's battery page and comes back (the walk). Tapping the row opens **Battery
  detail**: one line per app with its own state and verb, and "Set by the reader ⓘ" where that
  applies. Internally the three ids stay (`battery:BookSync` …) so skips and snoozes still apply per app.
- **Key Mapper** is a line on the Clicker buttons row, not a row.
- **Frozen** joins the row of the app it breaks.
- **BookSync plugin answered** and the Wi-Fi test results move to Details; the Wi-Fi test keeps its
  **Run** row in Connection.

### 3.6 Details (diagnostics)

A page from the last line of the Setup page: everything a support conversation needs, in a
monospace-free plain list: last answer from the BookSync plugin ("17:19, after Wi-Fi came up"; the raw
`NET_UP` in brackets on this page only), plugin version KOReader runs, report fields (signed in,
recommended state, conflicts), each battery app's raw state, Always-on VPN, lockdown, frozen apps,
mode and helpers, last Wi-Fi test summary. A **Copy for support** button writes it to the
clipboard. Nothing here is counted.

### 3.7 Modes

Both modes use the same page, groups, states and loss lines. The differences are which rows are
required:

| | Full | Add-on |
|---|---|---|
| Counted ("2 things need you", Fix next, prompts) | every row in Apps, BookOrbit, Permissions, Connection | only KOReader, BookOrbit plugin, BookSync plugin, BookOrbit account (`AddonLogic.REQUIRED`) |
| Recommended settings | a step | a status line in BookOrbit ("Applied 7 · Review"); its conflicts still remind |
| Permissions group | yes | none: its rows are in Optional (`AddonLogic.optionalIds`), with Wi-Fi switching and Sleep sync |
| Connection | Tailscale is a step | Tailscale info, only if installed |
| Optional group | the rows the user may leave off: Screen saver (PR #17), Screen mode for BookSync (§3.11), Reading fonts ([reading-fonts](reading-fonts.md)), and any skipped step | Install apps, Notifications, Clicker buttons, BookSync keyboard, Wi-Fi switching, Sleep sync, Screen lock, Battery, Screen saver, Screen mode for BookSync, Reading fonts |
| Home app | a step | no row |

In both, an Optional row shows "On: …" when on, otherwise "Without it: …" and **Allow**; never
counted, walked or prompted (`AddonLogic.optState` unchanged).

### 3.8 Where it lives

- **First run.** After the mode choice (`ModeActivity`, unchanged), Setup opens with the summary
  "Let's set up this reader · 8 steps" and **Start**, and Needs you lists the steps numbered.
  Start runs today's `SetupWalk` (each step's system page, then back here). While walking, the
  summary reads "Step 3 of 8: Notifications" with **Stop**. No separate wizard: one page, one walk.
- **Ongoing.** The status page's "Setup (12/14)" button becomes a summary row: "Setup: all set ✓"
  or "Setup: 2 things need you ›". The "Setup needs you" prompt (`AttentionActivity`) draws the same
  Needs-you rows (same words, loss lines, verbs), keeping "Don't ask about this" and "Later".
- **A new item after an update.** It appears where it belongs with a **New in 0.12** tag. A
  required one also joins Needs you and the existing after-update prompt (`Attention.onStart` grace
  then `evaluate`). An optional one never prompts: it shows in Optional with the tag, and the
  What's new line names it. The tag stays until the row is done or the next update.

### 3.9 The Settings PIN (kids' readers)

Setup stays readable without the PIN (today `SetupActivity` isn't `pinGuarded`; fixes go through
`Pin.fix`). With a PIN set and locked:

- Summary reads **"2 things need a grown-up"** and its button is **Unlock to fix** (the PIN keypad;
  after it, the page is the parent's view until the unlock ends).
- Rows show state and loss lines, no verb buttons, except PIN-free follow-through (`pinFree`:
  update the BookSync plugin, Restart KOReader), which keeps its button.
- Hidden while locked: Allow on Optional rows, "Don't ask about this", "Show hidden tips", Copy for
  support, the mode line's link.
- The parent's view (unlocked) is the normal page.

### 3.10 E-ink rules

- No animation, no spinner, no timed redraw. "Checking…" is static text; rows re-check on resume
  and after a fix, as today. Expanding a group is one redraw.
- Buttons 56 dp tall (today's `heightDp = 56`), rows at `Ui.ROW_DP` or taller; the summary button
  full width.
- State never by grey alone: glyph + words. The summary card has a 2 px black border.
- A set-up reader fits on one screen; an expanded group may scroll.

### 3.11 Screen mode for BookSync

E-ink readers keep a display (refresh) mode per app; in a fast one the sleep screen's cover
draws over the last page and it ghosts through. No Android API reads or sets that mode, so the
row is purely **Optional**: never counted, walked or prompted, never in Needs you or the
summary count, no "New in" badge. Left alone it shows only its hint and "Without it: the sleep
screen may show ghosting from the last page." in the Optional group. Shown while Sleep screen is
anything but the reader's own (either sink). Wording is generic: one or two common mode names
(HD, Clear, Quality), never a brand.

**How** opens the steps and three buttons:
- **I've set it**: stored (`Prefs.screenModeDone`); the row reads "On: BookSync draws in the
  reader's clearest screen mode."
- **Use a clearing flash instead**: turns on Sleep screen › *Clearing flash before the cover*
  (`sleep_flash`, lock-screen.md L10); the row reads "On: the clearing flash runs before the
  cover." Turning the flash off again reopens the row.
- **Skip**: nothing changes.

First run: the Sleep screen page shows the same row, marked optional, right under the mode
picker once a sleep screen is chosen, until it is finished; the first-run Setup page has it in
Optional.

### 3.12 Screen saver (`screen_saver`)

What the USB-granted permission (`WRITE_SECURE_SETTINGS`, lock-screen.md P1) really does: when
Sleep screen is turned on, BookSync makes its own screen saver the reader's; when it is turned off, it
puts the reader's own back (`SleepScreen.chooseOurs` / `restoreVendor`). Nothing else uses it. Once
BookSync's screen saver is chosen (by the one-time `tools/install-usb.sh --sleep-screen on`, or the
reader's own Screen saver page), the sleep screen works without it: the M8C case (user, 2026-11-24).

So the row is shown **only when it helps on this reader right now** (`SleepSetup.shown`, detected):
the reader uses a screen saver (dream sink), the permission is not granted, the reader hides its
Screen saver page (`ACTION_DREAM_SETTINGS` doesn't resolve), and what it shows while asleep doesn't
match Sleep screen: on while the reader's own screen saver is still chosen, or off while BookSync's
still is. Otherwise it is hidden, granted or not. When shown, the state line says what is wrong in
plain words and **Show how** gives the one command for now (`--sleep-screen on` or `off`) and the
grant that makes it automatic from then on ("BookSync switches the screen saver itself whenever you
turn Sleep screen on or off"). The Sleep screen settings' *Shown by* row keeps its own Set up.

## 4. Self-grill log (two-way doors, settled)

| # | Question | Decision | Why |
|---|---|---|---|
| D1 | One page or a summary page plus a group page each? | **One page, groups expand in place** | Fewer page loads on e-ink; one back press. |
| D2 | Several groups open at once? | **One at a time** | Keeps the page on one screen. |
| D3 | Where do open rows show: in their group or in Needs you? | **Needs you, expanded; their group line says "1 needs you"** | The user sees what to do without opening anything. |
| D4 | Group set | **Apps, BookOrbit, Permissions, Connection, Optional, Tips, Details** | Matches how the rows are fixed (installers, the plugin, Android settings, the network); diagnostics out of the way. |
| D5 | Labels | **Nouns; state in the line below** | A label that changes with the state is what made "Set BookSync as Home app · done" read oddly. |
| D6 | Battery: one row or three | **One row + detail page, ids kept per app** | Same fix, same reason; per-app skips still work. |
| D7 | "Not disabled" row in Full | **Only while frozen, on the app's row** | It is a fault, not a step; Add-on already does this. |
| D8 | "BookSync plugin answered" | **Details; "Checking…" on the BookSync plugin row when never answered** | It is a sighting, not a step (`INFO_ONLY`). |
| D9 | Set by the reader | **Done, with ⓘ** | Nothing to do, and the user ruled it met. |
| D10 | Skipped Full steps | **Off state in their group, "Without it", Allow** | Calm, and they can come back to it. |
| D11 | Loss lines | **Every optional, skipped and not-done required row, both modes; one table, guard test** | User ruling 2026-11-23. |
| D12 | First run | **The same page + Start (SetupWalk)** | One code path; the walk already exists. |
| D13 | Count shown | **"2 things need you", not "12/14"** | A count of what's left is the actionable number. |
| D14 | New-item tag lifetime | **Until done or the next update** | Long enough to be noticed, gone without a dismiss tap. |
| D15 | Kids: hide Setup? | **Read-only, "Unlock to fix"** | A kid can tell a parent what's wrong; nothing changes without the PIN. |
| D16 | Tips | **One collapsed line; Managed device shows under the summary** | Managed explains other failures, so it stays visible; the rest are reading material. |
| D17 | Ids decoupled from labels | **An explicit `id` on `Check`; `idOf` kept for stored prefs** | Relabelling must not reset skips and snoozes (`setupIgnored` etc. are keyed by id). |
| D18 | The attention prompt | **Same row component** | One set of words across prompt and page. |

## 5. One-way doors

None. Every change is on-screen wording and layout; stored skips and snoozes keep their ids (D17),
and the plugin's setup box reads the same prompt rows.

## 6. Tests (when built)

- `SetupGroupsTest`: every row id maps to one group; collapsed lines; summary state for each mix
  (all done, needs you, checking only, first run); one group expanded at a time.
- Loss-line guard: every id `Setup` can show has a loss line; Full and Add-on read the same text.
- States: set-by-reader counts as done; skipped never in Needs you; checking never counted.
- Battery merge: per-app ids kept; a skip on `battery:Tailscale` survives.
- PIN: locked view has no verb except `pinFree` rows.
- Robolectric render of the all-set page on 1264×1680 fits without scrolling.

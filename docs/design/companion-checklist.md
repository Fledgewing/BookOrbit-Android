# Companion setup checklist: one summary, grouped rows, plain words

ROADMAP 10a. Android only (Orbit Companion). Status: **designing**. Nothing here is built.
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
- **Same thing, several rows.** Battery is three rows (Orbit, Tailscale, KOReader).
- **Jargon and internals.** "Orbit plugin answered · last 17:19 (NET_UP)", "(device admin)",
  "Always-on on", "set App battery usage › Unrestricted".
- **Labels are instructions, state is a word on the right.** "Set Orbit as Home app … done".
- **Tests and tips are mixed in with steps.** The Wi-Fi test, "Orbit plugin answered", Play
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
| `disabled` | Not disabled by the system (KOReader, Tailscale, Orbit) | always (Add-on: only while frozen) | done / frozen | re-enable page |
| `install_updates` | Install updates | always | done / not | system page |
| `koreader` | KOReader app installed (vX) | always | official / missing / other signer / downloading | Install / Check |
| `plugin` | BookOrbit plugin installed (vX) | always | ok / missing / too old / downloading | Install |
| `patch` | Orbit plugin installed (vX) | always | current / outdated / missing / installing / **restart pending** | Fix / Restart KOReader (PIN-free) |
| `signed_in` | Signed in to BookOrbit | always | yes / no / **checking** | Open |
| `recommended` | Recommended settings | always | applied / reviewed / N to review / **checking** / pending next start | Review |
| `home` | Set Orbit as Home app | Full | yes / now: other | Home settings |
| `notifications` | Allow notifications | always | on / off | system page |
| `battery:Orbit`, `battery:Tailscale`, `battery:KOReader` | Battery: Unrestricted (app) | always (Add-on: one optional row with helpers) | on / off / not installed | app battery page |
| `tailscale` | Tailscale signed in and connected | always (Add-on: info, if installed) | connected / not / missing / frozen / lockdown | Tailscale / VPN settings |
| `admin` | Allow "lock screen" (device admin) | Full (Add-on: optional with Sleep sync) | on / off | device-admin prompt |
| `clicker` | Clicker buttons … | a clicker mapped or a PIN set | on / off / not running | accessibility settings |
| `keymapper` | Key Mapper also remaps keys | another key filter is on | warning | accessibility settings |
| `keyboard` | Orbit keyboard enabled | a Send-key action mapped | on / off | keyboard settings |
| `patch_seen` | Orbit plugin answered | always | last time (via) / never | open KOReader |
| `wifi_test` | Wi-Fi off/on test | always | result / never run | Run |
| `screen_saver` (PR #17) | Switch the screen saver from Orbit | Sleep screen on, dream sink | on / off | show the USB command |

Plus, in Add-on, the optional rows from `AddonLogic.OPTIONAL` (`C/ModeLogic.kt:188`) and the two
helper features (Wi-Fi switching, Sleep sync). Around the list: "Fix next" (`SetupWalk`), "Don't ask
about this" and "Later" on the prompt (`AttentionActivity`, `SetupAttention.ignored` / `snooze`),
"Show hidden tips", and the mode line.

## 3. The design

### 3.1 One page, top to bottom

1. **Header:** "Setup", "‹ Back". (The mode moves to the bottom line, §3.9.)
2. **Summary card**, always first, one of:
   - **All set** ✓ "Everything this reader needs is done." and, when there are any, "1 skipped ·
     2 optional off" (tappable: jumps to them).
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
   `✓ Apps · KOReader, BookOrbit plugin, Orbit plugin 0.11.2 ›`. Tapping a group expands it in
   place; only one group is expanded at a time.
5. **Optional** group (when it has rows, either mode): each row with "On: …" or "Without it: …".
6. **Tips** (one line, "2 tips ›") and **Details** (diagnostics, §3.6).
7. **Bottom line:** "Full mode · change in Settings" (or Add-on).

On a set-up reader that is: header, summary, 5 group lines, Optional, Tips, Details, mode: one
screen on the M8C, Boox Page and Go Color 7.

### 3.2 Groups

| Group | Rows (Full) | Collapsed line when fine |
|---|---|---|
| **Apps** | KOReader, BookOrbit plugin, Orbit plugin | KOReader 2025.10, BookOrbit plugin, Orbit plugin 0.11.2 |
| **BookOrbit** | Signed in, Recommended settings | Signed in · recommended settings on |
| **Permissions** | Home app, Install apps, Notifications, Battery, Screen lock, Clicker buttons, Orbit keyboard | 5 of 5 allowed |
| **Connection** | Tailscale, Wi-Fi off/on test | Tailscale connected · Wi-Fi test passed 17:02 |
| **Optional** | rows the user may leave off (§3.5) | 1 of 3 on |

"Not disabled by the system" has no row of its own in either mode: while an app is frozen it is a
Needs you row on the app it breaks ("KOReader is frozen by the launcher · Re-enable"), as Add-on
already does (§4.3 of addon-mode). "Orbit plugin answered" moves to Details; when the plugin has
never answered, the Orbit plugin row shows "Checking…" instead (§3.4).

### 3.3 Wording: one noun, one state line, one loss line, one verb

The **label is a noun** that never changes with the state. The **state line** says what is true now.
When the row isn't done, a **loss line** says what doesn't work. The **button is one verb**.

| Row | Label | Done | Not done: state · loss | Verb |
|---|---|---|---|---|
| koreader | KOReader | Version 2025.10 | Not installed · Until then: nothing to read with | Install |
| plugin | BookOrbit plugin | Version 1.8 | Not installed · Until then: no library, no sync | Install |
| patch | Orbit plugin | Version 0.11.2 | Older than this app · Until then: new fixes don't reach KOReader | Update |
| patch (restart) | Orbit plugin | — | Installed; KOReader still runs 0.11.1 · It restarts when the screen next goes off | Restart KOReader |
| signed_in | BookOrbit account | Signed in | Not signed in · Until then: nothing syncs | Sign in |
| recommended | Recommended settings | Applied 7 | 2 of yours differ · Nothing changes until you choose | Review |
| home | Home app | Orbit is the Home app | Now: Boox launcher · Until then: Home doesn't open your book | Set |
| install_updates | Install apps | Allowed | Not allowed · Until then: updates are a download link | Allow |
| notifications | Notifications | Allowed | Off · Until then: updates and steps show only when you open Orbit | Allow |
| battery | Battery | Unrestricted for Orbit, Tailscale, KOReader | KOReader is restricted · Until then: sleep syncs can be late | Fix |
| admin | Screen lock | Allowed | Not allowed · Until then: Sync and sleep asks you to press the power button | Allow |
| clicker | Clicker buttons | On in every app | Off · Until then: buttons work only inside KOReader | Turn on |
| keymapper | (on the Clicker row) | — | Key Mapper is also on · Two key filters fight | Turn off |
| keyboard | Orbit keyboard | On | Off · Until then: Send-key works only inside KOReader | Turn on |
| tailscale | Tailscale | Connected | Not connected · Until then: no sync with your server away from home Wi-Fi | Connect |
| wifi_test | Wi-Fi off/on test | Passed 17:02 (reconnects in 4 s) | Not run yet · never counted | Run |
| frozen | KOReader (or Tailscale, Orbit) | — | Frozen by the launcher · Until then: it can't start, sync or update | Re-enable |
| screen_saver | Screen saver from Orbit | On | (optional) Without it: Sleep screen needs a USB command to turn on or off | Show how |

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

**Set by the reader** is the Boox case: Orbit's battery page says "not available" because the
reader already exempts the Home app or device admin. The separate fix makes the check count it as
met; this design gives it its words. The ⓘ opens a one-screen note: "This reader keeps Orbit
running because it is the Home app. There is no switch for it here, and none is needed." Rule: a
setting the reader doesn't let anyone change, and that is already in the state Orbit needs, is
done. If the reader blocks it in the *wrong* state, the row is Needs you with "Can't be changed on
this reader · Without it: …" and no button (Help instead).

### 3.5 Merged rows and the battery detail

- **Battery**: one row for every app that is installed (Orbit, KOReader, Tailscale if installed).
  Done: "Unrestricted for Orbit, Tailscale, KOReader". Not done: names the app(s) left; **Fix**
  opens the first one's battery page and comes back (the walk). Tapping the row opens **Battery
  detail**: one line per app with its own state and verb, and "Set by the reader ⓘ" where that
  applies. Internally the three ids stay (`battery:Orbit` …) so skips and snoozes still apply per app.
- **Key Mapper** is a line on the Clicker buttons row, not a row.
- **Frozen** joins the row of the app it breaks.
- **Orbit plugin answered** and the Wi-Fi test results move to Details; the Wi-Fi test keeps its
  **Run** row in Connection.

### 3.6 Details (diagnostics)

A page from the last line of the Setup page: everything a support conversation needs, in a
monospace-free plain list: last answer from the Orbit plugin ("17:19, after Wi-Fi came up"; the raw
`NET_UP` in brackets on this page only), plugin version KOReader runs, report fields (signed in,
recommended state, conflicts), each battery app's raw state, Always-on VPN, lockdown, frozen apps,
mode and helpers, last Wi-Fi test summary. A **Copy for support** button writes it to the
clipboard. Nothing here is counted.

### 3.7 Modes

Both modes use the same page, groups, states and loss lines. The differences are which rows are
required:

| | Full | Add-on |
|---|---|---|
| Counted ("2 things need you", Fix next, prompts) | every row in Apps, BookOrbit, Permissions, Connection | only KOReader, BookOrbit plugin, Orbit plugin, BookOrbit account (`AddonLogic.REQUIRED`) |
| Recommended settings | a step | a status line in BookOrbit ("Applied 7 · Review"); its conflicts still remind |
| Permissions group | yes | none: its rows are in Optional (`AddonLogic.optionalIds`), with Wi-Fi switching and Sleep sync |
| Connection | Tailscale is a step | Tailscale info, only if installed |
| Optional group | the rows the user may leave off: Screen saver (PR #17), and any skipped step | Install apps, Notifications, Clicker buttons, Orbit keyboard, Wi-Fi switching, Sleep sync, Screen lock, Battery, Screen saver |
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
  update the Orbit plugin, Restart KOReader), which keeps its button.
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

## 4. Self-grill log (two-way doors, settled)

| # | Question | Decision | Why |
|---|---|---|---|
| D1 | One page or a summary page plus a group page each? | **One page, groups expand in place** | Fewer page loads on e-ink; one back press. |
| D2 | Several groups open at once? | **One at a time** | Keeps the page on one screen. |
| D3 | Where do open rows show: in their group or in Needs you? | **Needs you, expanded; their group line says "1 needs you"** | The user sees what to do without opening anything. |
| D4 | Group set | **Apps, BookOrbit, Permissions, Connection, Optional, Tips, Details** | Matches how the rows are fixed (installers, the plugin, Android settings, the network); diagnostics out of the way. |
| D5 | Labels | **Nouns; state in the line below** | A label that changes with the state is what made "Set Orbit as Home app · done" read oddly. |
| D6 | Battery: one row or three | **One row + detail page, ids kept per app** | Same fix, same reason; per-app skips still work. |
| D7 | "Not disabled" row in Full | **Only while frozen, on the app's row** | It is a fault, not a step; Add-on already does this. |
| D8 | "Orbit plugin answered" | **Details; "Checking…" on the Orbit plugin row when never answered** | It is a sighting, not a step (`INFO_ONLY`). |
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

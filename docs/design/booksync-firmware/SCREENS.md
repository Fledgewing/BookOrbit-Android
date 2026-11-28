# BookSync 0.12 firmware screen inventory

Status: **approved — 27 Nov 2026**, with the keyboard change. The maintainer
approved [the firmware mockups](mockups.html) on `feature/0.12` (PR #202), with
one change, verbatim: "On screen keyboard should always be on the bottom for touch".
B1/B3/B4/B5 retain that approval. The maintainer approved the slim **B2 revision
on 2026-11-27 (~18:45 PT)**; prior B2 import presentation is superseded, subject to slice dependencies.
[Gallery](mockups.html) · [plan](PLAN.md) · [approved Home revision 16](../booksync-home/DESIGN.md).
Each row below links one screen/state, with all three device views and captions.
Implementation expands per state/control into the plan’s small UI slices; service work
and UI work proceed under their plan slice dependencies. Android keeps its approved Home/reader
and system settings; these approved screens are firmware-specific. Nothing ships in this PR,
so shipped feature cells remain unchanged.

The gallery uses the approved 480 × 800 design viewport and frame tokens, not a claim
about physical panel resolution or measured font fit. X4 Pro has touch and frontlight;
X4 Classic has button focus and no frontlight; X3 has text/button presentation, no
frontlight, no USB drive and no S3 core dump. Every unsupported state is drawn with its
reason and a usable exit. Text keyboards use select/previous/next focus on button readers; the drawn first
key is initial focus. Settings codes retain the native digit-by-digit adjustment
on button readers and the touch keypad on Pro.

## Source audit

Audited BookSync integration commit: `30419e0d1a2e6bd115f318c129776bb3cd7924c1`.
The supplied CrossInk clone’s checkout is later (`d53849e1c620b7d600d9fe02b544fdf1534d4f51`);
all CrossInk evidence below was read using `git show` at **stable v2.0.0**
`2cdd6117568c8877c3180d5fac8d5b20e55d1ac7`, the plan’s base. The clone was not modified.
Paths beginning `src/` refer to that stable commit, not the working checkout.

- **B1 Wi-Fi restyle** — [`src/activities/network/WifiSelectionActivity.cpp:1206`](https://github.com/uxjulia/CrossInk/blob/2cdd6117568c8877c3180d5fac8d5b20e55d1ac7/src/activities/network/WifiSelectionActivity.cpp#L1206). Existing list, scan, password, join, save and forget behaviour is restyled. Captive-network recovery is proposed; no browser is added.
- **B1 private pairing restyle** — [`xteink/tailnet/ui/TailnetLoginActivity.cpp:100`](../../../xteink/tailnet/ui/TailnetLoginActivity.cpp#L100). Existing phone approval, manual Check and waiting/error behaviour is restyled. The illustration is not a scannable code; no invented short-code pairing protocol.
- **B1 route restyle** — [`xteink/tailnet/ui/TailnetSettingsActivity.cpp:349`](../../../xteink/tailnet/ui/TailnetSettingsActivity.cpp#L349). Existing automatic, match-library and fixed-region choices are restyled. Region names here are synthetic; actual names come from Library.
- **B1 connection restyle** — [`xteink/tailnet/ui/TailnetSettingsActivity.cpp:95`](../../../xteink/tailnet/ui/TailnetSettingsActivity.cpp#L95). Existing enable, logout confirmation and re-pair behaviour is restyled; library sign-in stays separate.
- **B1 network recovery proposal** — [`xteink/tailnet/ui/TailnetNetPhase.cpp:1`](../../../xteink/tailnet/ui/TailnetNetPhase.cpp#L1). New quiet recovery replaces legacy C3 activity/restart routing. A connection never parks or restarts foreground reading.
- **B2 slim upgrade notice — APPROVED (2026-11-27)** — [plan decision](PLAN.md#slim-upgrade-decision--2026-11-27). F26b/F26c retain credentials/Wi-Fi and Tailnet/NVS identity; F29 activates only these and presents the once-only notice. CrossInk native SD files remain untouched; F16/F18 restore server data through normal sync.
- **B2 capacity proposal** — [`docs/design/booksync-firmware/PLAN.md:139`](../../../docs/design/booksync-firmware/PLAN.md#L139). New durable-queue presentation; legacy queues are policy references, not a safe migration or capacity UI.
- **B2 scoped reset proposal** — [`docs/design/booksync-firmware/PLAN.md:267`](../../../docs/design/booksync-firmware/PLAN.md#L267). New settings-only reset proposal; it does not discard queued work or reset pairing. Broader reset is not offered.
- **B2 downgrade warning proposal** — [`docs/design/booksync-firmware/PLAN.md:291`](../../../docs/design/booksync-firmware/PLAN.md#L291). New warning; older software cannot reverse remote writes or guarantee that new saved records are readable.
- **B3 update restyle and recovery** — [`src/activities/settings/OtaUpdateActivity.cpp:120`](https://github.com/uxjulia/CrossInk/blob/2cdd6117568c8877c3180d5fac8d5b20e55d1ac7/src/activities/settings/OtaUpdateActivity.cpp#L120). Existing check, offer, progress, failure and completion screens are restyled. Signed trust, deferred installation and rollback recovery add plan-defined states.
- **B4 display restyle** — [`src/SettingsList.cpp:45`](https://github.com/uxjulia/CrossInk/blob/2cdd6117568c8877c3180d5fac8d5b20e55d1ac7/src/SettingsList.cpp#L45). Existing display settings retain their values; this is presentation through Library Settings, not another settings store.
- **B4 calibration restyle** — [`src/activities/settings/ScreenCalibrationActivity.cpp:28`](https://github.com/uxjulia/CrossInk/blob/2cdd6117568c8877c3180d5fac8d5b20e55d1ac7/src/activities/settings/ScreenCalibrationActivity.cpp#L28). Existing edge/corner adjustment, save, cancel, restore and save-failure behaviour is restyled.
- **B4 ruled lines restyle** — [`src/SettingsList.cpp:120`](https://github.com/uxjulia/CrossInk/blob/2cdd6117568c8877c3180d5fac8d5b20e55d1ac7/src/SettingsList.cpp#L120). Existing Off, Light, Medium and Dark guide-line settings are restyled.
- **B4 font restyle and errors** — [`src/SettingsList.cpp:73`](https://github.com/uxjulia/CrossInk/blob/2cdd6117568c8877c3180d5fac8d5b20e55d1ac7/src/SettingsList.cpp#L73). Existing built-in/card font choice and publisher-font values are retained. Explicit progress/read-failure recovery is proposed.
- **B4 controls restyle** — [`src/SettingsList.cpp:270`](https://github.com/uxjulia/CrossInk/blob/2cdd6117568c8877c3180d5fac8d5b20e55d1ac7/src/SettingsList.cpp#L270). Existing long-press actions are restyled. Only supported buttons/actions are projected; no touchscreen is assumed on button readers.
- **B4 frontlight restyle** — [`src/SettingsList.cpp:57`](https://github.com/uxjulia/CrossInk/blob/2cdd6117568c8877c3180d5fac8d5b20e55d1ac7/src/SettingsList.cpp#L57). Existing frontlight schedule and restore-on-wake settings are restyled on X4 Pro. Classic and X3 have no frontlight.
- **B4 settings-lock restyle** — [`xteink/orbify/SettingsPinActivity.cpp:1`](../../../xteink/orbify/SettingsPinActivity.cpp#L1). Existing settings-code entry is restyled. Forgot-code recovery is proposed and does not bypass the lock; this is not card encryption.
- **B4 USB drive restyle** — [`src/activities/network/UsbDriveActivity.cpp:18`](https://github.com/uxjulia/CrossInk/blob/2cdd6117568c8877c3180d5fac8d5b20e55d1ac7/src/activities/network/UsbDriveActivity.cpp#L18). Existing prepare, host ownership, eject/disconnect and restart behaviour is restyled on S3. X3 uses card removal; no USB drive support is invented.
- **B4 card recovery proposal** — [`docs/design/booksync-firmware/PLAN.md:174`](../../../docs/design/booksync-firmware/PLAN.md#L174). New explicit storage-failure presentation over retained storage hardening; no format-card or unsent-work eviction action.
- **B4 dictionary restyle and errors** — [`src/activities/reader/DictionaryDefinitionActivity.cpp:1533`](https://github.com/uxjulia/CrossInk/blob/2cdd6117568c8877c3180d5fac8d5b20e55d1ac7/src/activities/reader/DictionaryDefinitionActivity.cpp#L1533). Existing selection/lookup/read-error behaviour is retained. Explicit empty and book-specific confirmation layouts complete the restyle.
- **B4 bounded search proposal** — [`docs/design/booksync-firmware/PLAN.md:192`](../../../docs/design/booksync-firmware/PLAN.md#L192). New bounded search presentation; no full-book search activity was found in the stable source inventory. Engine/cancel/publication must be separately proven.
- **B5 crash restyle and summary** — [`src/activities/home/CrashActivity.cpp:33`](https://github.com/uxjulia/CrossInk/blob/2cdd6117568c8877c3180d5fac8d5b20e55d1ac7/src/activities/home/CrashActivity.cpp#L33). Existing crash reason screen is restyled as a user-opened summary. Persistent dedup/export are new; X3 has no S3 core dump.
- **B5 diagnostics proposal** — [`docs/design/booksync-firmware/PLAN.md:174`](../../../docs/design/booksync-firmware/PLAN.md#L174). New local report and recovery controls over the planned diagnostics read model; no automatic upload or reading interruption.
- **B5 export proposal** — [`docs/design/booksync-firmware/PLAN.md:270`](../../../docs/design/booksync-firmware/PLAN.md#L270). New local export flow. Library prepares a redacted report; UI never reads raw logs, credentials or files.
- **B5 recovery proposal** — [`docs/design/booksync-firmware/PLAN.md:270`](../../../docs/design/booksync-firmware/PLAN.md#L270). New one-boot basic-settings proposal; permanent saved values and security protection remain unchanged.
- **B5 report-removal proposal** — [`docs/design/booksync-firmware/PLAN.md:270`](../../../docs/design/booksync-firmware/PLAN.md#L270). New report-only removal confirmation; this does not clear reading state, upgrade originals or saved changes.
- **B5 first-run proposal** — [`docs/design/booksync-firmware/PLAN.md:270`](../../../docs/design/booksync-firmware/PLAN.md#L270). New firmware welcome, shown only with no book open. Existing Home remains the approved revision-16 design.
- **B5 service choice proposal** — [`docs/design/booksync-firmware/PLAN.md:169`](../../../docs/design/booksync-firmware/PLAN.md#L169). Library Account provides available services. This service picker and the slim B2 restore action name BookOrbit; adapter protocol details never enter UI.
- **B5 news proposal** — [`docs/design/booksync-firmware/PLAN.md:270`](../../../docs/design/booksync-firmware/PLAN.md#L270). New once-only firmware upgrade news; it waits for Home and never appears over a book.

Additional stable evidence: `WifiSelectionActivity.cpp:1384` saves a password after
joining and `:1447` confirms forgetting; `UsbDriveActivity.cpp:18` paints before
relinquishing card ownership and `:68` keeps the host owner through computer sleep;
`DictionarySelectActivity.cpp:123` offers a per-book dictionary override.
[platformio.ini:220](https://github.com/uxjulia/CrossInk/blob/2cdd6117568c8877c3180d5fac8d5b20e55d1ac7/platformio.ini#L220)
disables USB drive/touch on C3, while `:390` documents Classic’s buttons, USB drive
and absence of frontlight. BookSync `xteink/orbify/CrashRecord.h:1` limits core-dump
capture to S3; `core/CopyQueue.*` and `core/FinishQueue.*` are legacy policy inputs,
not proof of a durable new capacity or migration UI. `SettingsPinActivity.*` retains
code protection, not disk encryption. `OtaManifest.h`, `OtaReturn.*` and
`core/UpdateSignature.*` supply update policy behind Library; no UI may call them.

No native full-book search, migration conflict, local diagnostic-export or first-run
news activity was found in the stable `src/` filename/symbol audit. Those are marked
proposals rather than attributed to upstream. A new search engine is separately
budgeted/tested under F41r; a renderer must not scan a book.

## Boundary and interaction contract

- UI consumes immutable Library values and sends intents only. Service labels in
  captions are proposed facade groups, not new public API names or direct services
  accessible by the renderer. Credentials, adapter fields, network routes, mutable
  jobs, logs and file handles never enter UI. Paint performs no I/O or parsing.
- User opens all controls/recovery screens. Unsolicited progress, errors, news,
  navigation, installation and restart wait for ReadingGate and a valid delivery
  ticket; expired results are dropped. No background task opens a book or steals
  reading focus. The existing approved position consent and end-of-book exceptions
  are unchanged. The refused-connect view is an explicit user-opened in-book action.
- Progress is coarse and non-animated. During C3 framebuffer release the last
  prepainted wait panel remains; do not promise live percentages or new drawing.
  Cancel is an intent serviced when ownership is safe. A connection failure returns
  to saved books and never restarts or parks foreground reading.
- Back/Cancel retires presentation ownership, not durable queued work. Passwords
  stay masked; leaving entry clears the transient value. PIN entry uses the retained
  engine rules; wrong-code errors never unlock settings. A reset cannot bypass it.
- The QR in the static gallery is deliberately non-scannable. Live pairing uses the
  existing approval URL supplied privately through the Library pairing model; no
  synthetic hostname, address or account is shown. The runtime retains the existing
  readable live link and manual Check; no phone-assisted handoff is included (Q1). Regions and book names are synthetic.
- Destructive confirmations default focus to Keep/Cancel. Settings reset is narrowly
  scoped; unsent work, original imports, credentials and pairing are retained.
  No format, erase-all, discard-queue or reset-identity action is proposed.
- Installation first verifies trust, root, device and layout through Library, then
  admits at Home. Once writing starts, Back and Cancel are disabled (the static
  header says Please wait in install/restart views). Recovery text is shown
  only after the service proves which image actually booted. Rollback is offered
  only with an available verified image and compatible durable-state proof.
- USB drive remains exclusive host ownership. A sleeping computer has not ejected.
  Explicit forced disconnect warns about unfinished computer writes; safe restart
  remounts and rebuilds projections behind Library. X3 powers off for card removal.
- First-run can skip sign-in. Retained credential/identity activation resumes
  idempotently and preserves unreadable originals. No 0.12 reading-record or
  pending-queue importer runs; the 0.11 bridge drains work before the update offer
  (empty queues or no signed-in account). Unknown deliveries never become guessed acknowledgments. At pending-queue capacity, saved books
  remain read-only; operations that cannot record durably are blocked with a message (Q2). Never evict unacknowledged work.

## B2 slim upgrade revision — NEEDS APPROVAL

The 2026-11-27 slim decision removes the former import progress/conflict/anchor and
migration-recovery scenes. The [new notice](mockups.html#upgrade-notice) has all
three device views and says:

- **What carried over:** Wi-Fi, sign-in and Tailscale pairing. Your books and
  CrossInk's own place in each book stay on the card.
- **What starts fresh:** BookSync settings reset to defaults.
- **Get your reading back:** Reading history, highlights and stats come back from
  BookOrbit when you sync.
- Actions: **Sync from BookOrbit now**, **Later**.

Show once at Home after a 0.11 upgrade, never over a book. F29 durably checkpoints
dismissal for either action (Back means Later); repeated boots do not show it again.
Now invokes normal F16 catalog / F18 lifecycle sync through Library, re-pulling
positions, annotations/bookmarks, stats and book matches. Match-by-identity reuses
existing SD files without re-downloading where possible. Later leaves saved books
usable and normal sync can restore the data afterwards. Data absent from BookOrbit
cannot be restored by that sync; original files and queues are never deleted.
Pro offers touch actions; Classic and X3 start focus on Sync from BookOrbit now,
Previous/Next changes focus and Select activates. X3 uses text with no touch controls.
Static notice paint performs zero library reads, network, parsing or file work;
services own activation, dismissal and sync.

Existing B2 queue-capacity/reset/downgrade views remain drawn for normal 0.12 use,
not legacy import. B1/B3/B4/B5 are unchanged. B5's approved Home-news illustration
is retained; the 0.11 upgrade uses this B2 explanation without duplicate notices.
F28 belongs to this repo's `xteink/` overlay on main: the last 0.11 bridge sends
all pending progress, stats, annotations/bookmarks and finish/state work to
BookOrbit, then offers 0.12 only with empty queues or no signed-in account.
F31 already provides old → bridge → 0.12 ordering. Implementation and release of
that bridge follow later through the normal flow; this PR changes docs only.

## Screens and plan slices

| Screen | State | Approved build slice (dependencies apply) | Library service group |
|---|---|---|---|
| [wifi-list — Wi-Fi](mockups.html#wifi-list) | normal; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [wifi-empty — No networks found](mockups.html#wifi-empty) | empty; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [wifi-scan — Looking for networks](mockups.html#wifi-scan) | progress; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [wifi-hidden — Other network](mockups.html#wifi-hidden) | entry; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [wifi-password — Wi-Fi password](mockups.html#wifi-password) | entry; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [wifi-joining — Connecting](mockups.html#wifi-joining) | progress; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [wifi-save — Save this password?](mockups.html#wifi-save) | confirmation; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [wifi-ready — Wi-Fi connected](mockups.html#wifi-ready) | normal; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [wifi-failed — Could not connect](mockups.html#wifi-failed) | error; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [wifi-captive — This network needs a web sign-in](mockups.html#wifi-captive) | recovery; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [wifi-forget — Forget this network?](mockups.html#wifi-forget) | confirmation; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [private-off — Private connection](mockups.html#private-off) | normal; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [pair-loading — Getting sign-in ready](mockups.html#pair-loading) | progress; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [pair-scan — Pair this reader](mockups.html#pair-scan) | waiting; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [pair-connected — Reader paired](mockups.html#pair-connected) | normal; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [pair-failed — Pairing did not finish](mockups.html#pair-failed) | error; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [pair-expired — Sign-in has expired](mockups.html#pair-expired) | recovery; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [relay — Connection route](mockups.html#relay) | normal; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [relay-regions — Choose a region](mockups.html#relay-regions) | normal; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [relay-empty — Regions not saved yet](mockups.html#relay-empty) | recovery; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [private-logout — Unpair this reader?](mockups.html#private-logout) | confirmation; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [private-repair — Reader unpaired](mockups.html#private-repair) | recovery; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [network-wait — Connecting safely](mockups.html#network-wait) | progress; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [network-refused — Connect after reading](mockups.html#network-refused) | recovery; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [network-recover — Connection could not start](mockups.html#network-recover) | error; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [pair-checking — Checking approval](mockups.html#pair-checking) | progress; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [pair-unapproved — Not approved yet](mockups.html#pair-unapproved) | waiting; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [pair-no-wifi — Connect to Wi-Fi first](mockups.html#pair-no-wifi) | recovery; X4 Pro / X4 Classic / X3 | B1: F10/F11 → F43 | Library Device / network intents (F10–F12, F43) |
| [upgrade-notice — Welcome to BookSync 0.12](mockups.html#upgrade-notice) | once-only upgrade; X4 Pro touch / X4 Classic buttons / X3 text | B2 revision **NEEDS APPROVAL**: F26b/F26c → F29; F12 quiet gate; F16/F18 sync | Library upgrade values and normal sync intents |
| [queue-status — Saved changes](mockups.html#queue-status) | normal; X4 Pro / X4 Classic / X3 | B2: F07/F17 | Library SyncOwner / saved-change status (F07, F17) |
| [queue-near — Saved changes are nearly full](mockups.html#queue-near) | warning; X4 Pro / X4 Classic / X3 | B2: F07/F17 | Library SyncOwner / saved-change status (F07, F17) |
| [queue-full — No room for more saved changes](mockups.html#queue-full) | error; X4 Pro / X4 Classic / X3 | B2: F07/F17 | Library SyncOwner / saved-change status (F07, F17) |
| [queue-reconcile — Checking saved changes](mockups.html#queue-reconcile) | recovery; X4 Pro / X4 Classic / X3 | B2: F07/F17 | Library SyncOwner / saved-change status (F07, F17) |
| [reset-confirm — Reset BookSync settings?](mockups.html#reset-confirm) | confirmation; X4 Pro / X4 Classic / X3 | B2: F29/F38k | Library settings/recovery values and intents (F29, F38k) |
| [downgrade — Older software may miss changes](mockups.html#downgrade) | warning; X4 Pro / X4 Classic / X3 | B2: F29/F38k | Library settings/recovery values and intents (F29, F38k) |
| [reset-done — Settings restored](mockups.html#reset-done) | normal; X4 Pro / X4 Classic / X3 | B2: F29/F38k | Library settings/recovery values and intents (F29, F38k) |
| [reset-failed — Settings could not be restored](mockups.html#reset-failed) | error; X4 Pro / X4 Classic / X3 | B2: F29/F38k | Library settings/recovery values and intents (F29, F38k) |
| [queue-recovered — Saved changes have room again](mockups.html#queue-recovered) | normal; X4 Pro / X4 Classic / X3 | B2: F07/F17 | Library SyncOwner / saved-change status (F07, F17) |
| [update-ready — Update ready](mockups.html#update-ready) | normal; X4 Pro / X4 Classic / X3 | B3: F30/F31 → F32 | Library update values and intents (F30–F32) |
| [update-download — Downloading update](mockups.html#update-download) | progress; X4 Pro / X4 Classic / X3 | B3: F30/F31 → F32 | Library update values and intents (F30–F32) |
| [update-check — Checking update](mockups.html#update-check) | progress; X4 Pro / X4 Classic / X3 | B3: F30/F31 → F32 | Library update values and intents (F30–F32) |
| [update-space — Not enough space for the update](mockups.html#update-space) | error; X4 Pro / X4 Classic / X3 | B3: F30/F31 → F32 | Library update values and intents (F30–F32) |
| [update-network — Download stopped](mockups.html#update-network) | error; X4 Pro / X4 Classic / X3 | B3: F30/F31 → F32 | Library update values and intents (F30–F32) |
| [update-deferred — Install when you are ready](mockups.html#update-deferred) | waiting; X4 Pro / X4 Classic / X3 | B3: F30/F31 → F32 | Library update values and intents (F30–F32) |
| [update-confirm — Install and restart?](mockups.html#update-confirm) | confirmation; X4 Pro / X4 Classic / X3 | B3: F30/F31 → F32 | Library update values and intents (F30–F32) |
| [update-install — Installing update](mockups.html#update-install) | progress; X4 Pro / X4 Classic / X3 | B3: F30/F31 → F32 | Library update values and intents (F30–F32) |
| [update-restart — Restarting](mockups.html#update-restart) | progress; X4 Pro / X4 Classic / X3 | B3: F30/F31 → F32 | Library update values and intents (F30–F32) |
| [update-signature — This update cannot be trusted](mockups.html#update-signature) | error; X4 Pro / X4 Classic / X3 | B3: F30/F31 → F32 | Library update values and intents (F30–F32) |
| [update-root — Update trust could not be checked](mockups.html#update-root) | error; X4 Pro / X4 Classic / X3 | B3: F30/F31 → F32 | Library update values and intents (F30–F32) |
| [update-board — This update is for another reader](mockups.html#update-board) | error; X4 Pro / X4 Classic / X3 | B3: F30/F31 → F32 | Library update values and intents (F30–F32) |
| [update-layout — This update does not fit this reader](mockups.html#update-layout) | error; X4 Pro / X4 Classic / X3 | B3: F30/F31 → F32 | Library update values and intents (F30–F32) |
| [update-interrupted — Update did not finish](mockups.html#update-interrupted) | recovery; X4 Pro / X4 Classic / X3 | B3: F30/F31 → F32 | Library update values and intents (F30–F32) |
| [update-rollback — Return to the previous version?](mockups.html#update-rollback) | confirmation; X4 Pro / X4 Classic / X3 | B3: F30/F31 → F32 | Library update values and intents (F30–F32) |
| [update-no-rollback — Previous version unavailable](mockups.html#update-no-rollback) | recovery; X4 Pro / X4 Classic / X3 | B3: F30/F31 → F32 | Library update values and intents (F30–F32) |
| [update-success — Update complete](mockups.html#update-success) | normal; X4 Pro / X4 Classic / X3 | B3: F30/F31 → F32 | Library update values and intents (F30–F32) |
| [update-rollback-progress — Starting the previous version](mockups.html#update-rollback-progress) | progress; X4 Pro / X4 Classic / X3 | B3: F30/F31 → F32 | Library update values and intents (F30–F32) |
| [display — Screen and display](mockups.html#display) | normal; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [calibration — Screen edges](mockups.html#calibration) | normal; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [calibration-fail — Screen edges were not saved](mockups.html#calibration-fail) | error; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [calibration-reset — Restore screen edges?](mockups.html#calibration-reset) | confirmation; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [rules — Reading lines](mockups.html#rules) | normal; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [font-assets — Fonts on this reader](mockups.html#font-assets) | normal; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [font-loading — Preparing font](mockups.html#font-loading) | progress; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [font-error — This font could not be opened](mockups.html#font-error) | error; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [shortcuts — Button shortcuts](mockups.html#shortcuts) | normal; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [shortcut-choice — Hold the Back button](mockups.html#shortcut-choice) | normal; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [light-schedule — Light schedule](mockups.html#light-schedule) | normal; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [light-clock — Set the time first](mockups.html#light-clock) | recovery; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [pin-settings — Settings lock](mockups.html#pin-settings) | normal; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [pin-new — Choose a settings code](mockups.html#pin-new) | entry; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [pin-repeat — Enter the code again](mockups.html#pin-repeat) | confirmation; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [pin-unlock — Unlock settings](mockups.html#pin-unlock) | entry; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [pin-wrong — That code did not match](mockups.html#pin-wrong) | error; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [pin-remove — Remove the settings code?](mockups.html#pin-remove) | confirmation; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [pin-forgot — Forgot your settings code?](mockups.html#pin-forgot) | recovery; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [usb-confirm — Use the card on a computer?](mockups.html#usb-confirm) | confirmation; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [usb-prepare — Preparing card transfer](mockups.html#usb-prepare) | progress; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [usb-wait — Connect your computer](mockups.html#usb-wait) | waiting; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [usb-active — Computer is using the card](mockups.html#usb-active) | normal; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [usb-disconnect — Has the computer ejected the card?](mockups.html#usb-disconnect) | confirmation; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [usb-failure — Card transfer could not start](mockups.html#usb-failure) | error; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [usb-return — Returning to your books](mockups.html#usb-return) | recovery; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [sd-missing — Card not found](mockups.html#sd-missing) | error; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [sd-readonly — Card cannot be changed](mockups.html#sd-readonly) | error; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [sd-full — Card is full](mockups.html#sd-full) | recovery; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [dictionary-list — Dictionary](mockups.html#dictionary-list) | normal; X4 Pro / X4 Classic / X3 | B4: F41r (separate engine/cancel/publication slices) | Library reader lookup/search intents (F41r) |
| [dictionary-empty — No dictionary on this card](mockups.html#dictionary-empty) | empty; X4 Pro / X4 Classic / X3 | B4: F41r (separate engine/cancel/publication slices) | Library reader lookup/search intents (F41r) |
| [dictionary-lookup — Looking up “lantern”](mockups.html#dictionary-lookup) | progress; X4 Pro / X4 Classic / X3 | B4: F41r (separate engine/cancel/publication slices) | Library reader lookup/search intents (F41r) |
| [dictionary-no-match — No definition found](mockups.html#dictionary-no-match) | empty; X4 Pro / X4 Classic / X3 | B4: F41r (separate engine/cancel/publication slices) | Library reader lookup/search intents (F41r) |
| [dictionary-error — Dictionary could not be read](mockups.html#dictionary-error) | error; X4 Pro / X4 Classic / X3 | B4: F41r (separate engine/cancel/publication slices) | Library reader lookup/search intents (F41r) |
| [dictionary-change — Use this dictionary for this book?](mockups.html#dictionary-change) | confirmation; X4 Pro / X4 Classic / X3 | B4: F41r (separate engine/cancel/publication slices) | Library reader lookup/search intents (F41r) |
| [search-entry — Search this book](mockups.html#search-entry) | entry; X4 Pro / X4 Classic / X3 | B4: F41r (separate engine/cancel/publication slices) | Library reader lookup/search intents (F41r) |
| [search-progress — Searching this book](mockups.html#search-progress) | progress; X4 Pro / X4 Classic / X3 | B4: F41r (separate engine/cancel/publication slices) | Library reader lookup/search intents (F41r) |
| [search-empty — No matches in this book](mockups.html#search-empty) | empty; X4 Pro / X4 Classic / X3 | B4: F41r (separate engine/cancel/publication slices) | Library reader lookup/search intents (F41r) |
| [search-error — Search could not finish](mockups.html#search-error) | error; X4 Pro / X4 Classic / X3 | B4: F41r (separate engine/cancel/publication slices) | Library reader lookup/search intents (F41r) |
| [search-unsupported — Search is unavailable for this file](mockups.html#search-unsupported) | unavailable; X4 Pro / X4 Classic / X3 | B4: F41r (separate engine/cancel/publication slices) | Library reader lookup/search intents (F41r) |
| [search-stop — Stop searching?](mockups.html#search-stop) | confirmation; X4 Pro / X4 Classic / X3 | B4: F41r (separate engine/cancel/publication slices) | Library reader lookup/search intents (F41r) |
| [calibration-edit — Adjust top edge](mockups.html#calibration-edit) | entry; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [calibration-corners — Adjust screen corners](mockups.html#calibration-corners) | entry; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [light-time — Schedule start time](mockups.html#light-time) | entry; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [pin-mismatch — The codes did not match](mockups.html#pin-mismatch) | error; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [pin-save-failed — The code could not be saved](mockups.html#pin-save-failed) | error; X4 Pro / X4 Classic / X3 | B4: F38k per control → F43 | Library Settings / Device / Storage intents (F38k, F43) |
| [dictionary-definition — lantern](mockups.html#dictionary-definition) | normal; X4 Pro / X4 Classic / X3 | B4: F41r (separate engine/cancel/publication slices) | Library reader lookup/search intents (F41r) |
| [search-matches — Matches for “lantern”](mockups.html#search-matches) | normal; X4 Pro / X4 Classic / X3 | B4: F41r (separate engine/cancel/publication slices) | Library reader lookup/search intents (F41r) |
| [crash-summary — Previous restart](mockups.html#crash-summary) | normal; X4 Pro / X4 Classic / X3 | B5: F43 (F29 for upgrade news) | Library Device / diagnostics intents (F43; F29 for upgrade news) |
| [crash-empty — No restart report saved](mockups.html#crash-empty) | empty; X4 Pro / X4 Classic / X3 | B5: F43 (F29 for upgrade news) | Library Device / diagnostics intents (F43; F29 for upgrade news) |
| [diagnostics — Recovery options](mockups.html#diagnostics) | normal; X4 Pro / X4 Classic / X3 | B5: F43 (F29 for upgrade news) | Library Device / diagnostics intents (F43; F29 for upgrade news) |
| [export-confirm — Save a recovery report?](mockups.html#export-confirm) | confirmation; X4 Pro / X4 Classic / X3 | B5: F43 (F29 for upgrade news) | Library Device / diagnostics intents (F43; F29 for upgrade news) |
| [export-progress — Saving recovery report](mockups.html#export-progress) | progress; X4 Pro / X4 Classic / X3 | B5: F43 (F29 for upgrade news) | Library Device / diagnostics intents (F43; F29 for upgrade news) |
| [export-done — Recovery report saved](mockups.html#export-done) | normal; X4 Pro / X4 Classic / X3 | B5: F43 (F29 for upgrade news) | Library Device / diagnostics intents (F43; F29 for upgrade news) |
| [export-failed — Report could not be saved](mockups.html#export-failed) | error; X4 Pro / X4 Classic / X3 | B5: F43 (F29 for upgrade news) | Library Device / diagnostics intents (F43; F29 for upgrade news) |
| [recovery-start — Start with basic settings](mockups.html#recovery-start) | recovery; X4 Pro / X4 Classic / X3 | B5: F43 (F29 for upgrade news) | Library Device / diagnostics intents (F43; F29 for upgrade news) |
| [report-clear — Remove this restart report?](mockups.html#report-clear) | confirmation; X4 Pro / X4 Classic / X3 | B5: F43 (F29 for upgrade news) | Library Device / diagnostics intents (F43; F29 for upgrade news) |
| [first-run — Welcome to BookSync](mockups.html#first-run) | normal; X4 Pro / X4 Classic / X3 | B5: F43 (F29 for upgrade news) | Library Device / diagnostics intents (F43; F29 for upgrade news) |
| [server-choice — Choose your library service](mockups.html#server-choice) | normal; X4 Pro / X4 Classic / X3 | B5: F37a/F43 | Library Account (F37a) |
| [upgrade-news — A familiar place for your books](mockups.html#upgrade-news) | normal; X4 Pro / X4 Classic / X3 | B5: F43 (F29 for upgrade news) | Library Device / diagnostics intents (F43; F29 for upgrade news) |
| [recovery-active — Basic settings for this start](mockups.html#recovery-active) | recovery; X4 Pro / X4 Classic / X3 | B5: F43 (F29 for upgrade news) | Library Device / diagnostics intents (F43; F29 for upgrade news) |

## Recorded coordinator decisions (Q1–Q7)

These are coordinator calls. The maintainer approved the mockups after seeing
them on 27 Nov 2026; the maintainer's requested change is recorded above.

- **Q1 — Pairing on button readers:** Keep the existing QR, live link and manual Check; no phone-assisted handoff.
- **Q2 — Queue at capacity:** Read-only saved-books path at capacity; operations that can't record durably are blocked with a message; never evict unacknowledged work.
- **Q3 — Retained imports (slim revision, 2026-11-27):** Only credentials/Wi-Fi and Tailnet identity activate; preserve unreadable originals. No reading-record or queue replay on 0.12. B2 revision APPROVED (2026-11-27).
- **Q4 — Reset and forgotten code:** Approve settings-only reset, one-boot basic settings and a separate verified forgot-code recovery; nothing erases books or sign-ins.
- **Q5 — Rollback admission:** Offer Return to previous only for versions proven compatible after F29/F32; otherwise show Previous version unavailable.
- **Q6 — Diagnostic scope and retention:** Local redacted export to SD, keep the last 5 reports, user can delete them; X3 gets a bounded summary.
- **Q7 — First-run and upgrade news:** Optional first-run setup; once-only upgrade news on Home.

## Acceptance before implementation approval becomes shipment

For every text-entry screen, the acceptance criterion is: **touch on-screen keyboard
always docked at the bottom**. Content, fields and actions remain visible above it;
button-device presentation is unchanged. This applies to `wifi-hidden`,
`wifi-password`, `pin-new`, `pin-repeat`, `pin-unlock` and `search-entry`, and to
any later text-entry state.

Each state needs render/Back/focus coverage in all three simulator profiles and a
matching Library fake for success, cancellation, error and stale delivery. Prove
zero work during paint, no overlay/restart while reading, bounded X3 memory, card
ownership and no unacknowledged eviction. Firmware size/margin and real-device
sideload acceptance remain PLAN gates; this document measures neither. Essential
recovery UI remains a cutover blocker until its implementation passes these gates.

Historical validation of the original approved gallery (before the slim B2 revision): headless-browser inspection of all
126 states / 378 device views found no content clipping, broken internal anchors,
page errors or horizontal overflow at 1200 px and 390 px widths. Representative
password, pairing, import conflict, install, calibration, code-entry, USB ownership
and crash-summary views were rendered and visually inspected. Repository branding
and feature-reference tests pass. This is browser QA, not firmware/device evidence.

Approval-change validation: all six X4 Pro text/keypad views dock the keyboard at
the screen bottom with fields and actions visible above it. All 252 button-device
views are unchanged. The 378-view clipping/anchor/overflow checks pass at 1200 px
and 390 px widths; password and code-entry renders were visually inspected.

Slim B2 revision validation (2026-11-27): all 117 states / 351 device views have
no clipped content, broken gallery anchors, page errors or horizontal overflow at
1200 px and 390 px widths. The three new notice views were rendered and visually
inspected. All 107 articles outside B2 are byte-for-byte unchanged; existing frame
styles are unchanged. Branding and feature-reference checks pass. This verifies
the documentation rendering, not firmware behavior or device fit. B2 was subsequently approved on 2026-11-27 (~18:45 PT).

## F37a account additions — APPROVED (2026-11-27)

The approved `server-choice` picker remains buildable on all three profiles.
The Home gallery has X4 account examples but no X3 account form or capability
state, and the B1 QR is private-connection pairing rather than library sign-in.
The [F37a account gallery](mockups.html#F37a) adds explicit three-profile states:

- [account-out](mockups.html#account-out) — Your server.
- [account-in](mockups.html#account-in) — Your server.
- [account-limited](mockups.html#account-limited) — Your server.
- [account-manual](mockups.html#account-manual) — Sign in to your server.
- [account-busy](mockups.html#account-busy) — Signing in.
- [account-phone](mockups.html#account-phone) — Sign in from your phone.
- [account-wait](mockups.html#account-wait) — Waiting for sign-in.
- [account-expired](mockups.html#account-expired) — Sign-in has expired.
- [account-failed](mockups.html#account-failed) — Could not sign in.
- [account-two-step](mockups.html#account-two-step) — Use your phone to sign in.
- [account-old](mockups.html#account-old) — This service needs an update.

These additions are **APPROVED (2026-11-27)**, including their strings, focus and
capability states. Maintainer approval (~21:40 PT): “All approved”. This is explicit
account approval, separate from B1–B5 approval. The account-manual Pro
keyboard is a direct screen child docked below the fields/actions. Button entry
keeps key focus; X3 uses bounded text. Phone sign-in retains QR, a readable live
link and manual Check (Q1), with no invented short-code handoff. The illustration
is deliberately non-scannable. Services validate and redact the public link;
credentials and raw responses never enter display snapshots or logs.

Account/owner epochs scope every result. Back/Cancel retires presentation and
clears transient fields; closed forms never repaint or reopen, even if account
authentication subsequently succeeds. Account changes invalidate old deliveries.
Approval does not waive F15/F12 tests, the sole-writer boundary, firmware size
gates or maintainer hardware acceptance. F37b/F37c remain separate slices.

## F35a X3 Home widgets — APPROVED (2026-11-27)

The maintainer approved the [Settings list and its six states](F35a-X3-editor.md)
on 2026-11-27 (~18:45 PT): list, add, remove, reset, no space and save failure.
Keep widget and Keep layout receive initial focus. F35a services, host tests,
three-profile simulator scenes and maintainer device acceptance remain required.

## F40w Home widget additions — NEEDS APPROVAL

The [F40w inventory](F40w-widgets.md) and [widget gallery](f40w-widgets.html)
replace the initial text-template proposal with 38 widget-specific main designs,
three profile views each and compact state strips. They adapt the Android cards
and document each firmware difference, including X3 text layouts.
All additions are **NEEDS APPROVAL**. Existing Home revision-16 and B1–B5
approvals remain unchanged; placeholder cards do not approve new widget content.
No firmware implementation or pin update is included.

## F36b detail additions — NEEDS APPROVAL

The [detail/actions inventory](F36b-DETAIL.md) and
[three-profile gallery](f36b-detail.html) propose missing X3 detail and
three-profile offline, download/cancel/error, status/Undo, removal and Back
states. All additions are **NEEDS APPROVAL**. Existing revision-16 X4 detail
approval remains unchanged. Firmware F36b presentation stays off pending these
approvals and the public Library detail/F20/removal contracts. F36a/F36c and
F20 recovery proposals remain separate. No firmware pin or shipped feature cell
changes are included.

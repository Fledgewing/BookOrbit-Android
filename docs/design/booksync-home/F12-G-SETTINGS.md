# Android Settings presentation parity

Approved revision 16 presentation, Android first under the maintainer's 2026-11-25
authorization. No device, release, tag or firmware change. X4 Pro, X4 and X3 follow
Android; X3 still needs a measured firmware fit.

Reuse references on the starting commit `4d082fa0`: `ko/menu.lua:173` owns the eight
Settings groups and `:318` the PIN policy; `logic/settings_ui.lua:5` owns the three
mode bundles and `:45` their companion-formatted estimates. `ko/library.lua:16`
provides inherited screen budgets and `:29` the bounded read port;
`LibraryReadModel.kt:24` publishes into the existing cache database. The companion's
`SettingsUiLogic.kt:137` owns normalized sleep choices, and `SleepPoolLogic.kt:69`
(and plugin `logic/sleep_pool.lua:95`) own source selection. These paths are under
`android/koreader/orbit.koplugin/` and
`android/companion/app/src/main/java/net/fledgewing/orbitcompanion/` respectively.
No parallel cache, catalog, sleep selection policy or server transport was added.

The owned Settings presenter uses those same rows, with bounded display pages,
native focus and Back. A Mode card shows all three mode names, the selected mode,
its description and measured estimate, or Your own settings and Battery depends
on your mix. Tapping cycles the three bundles; changed individual values retain
the existing Back to Balanced action. PIN-locked cards and nested choices cannot
change values. Back from a group returns to Settings, and Back from a choice
returns to its initiating page and focus. Native button construction remains the
owner of tap/focus geometry; its fixed label container holds the multiline card
(KOReader pin `9192014d8bd82a91dc1012473be0f238dedfdb54`,
`frontend/ui/widget/button.lua:200-216`). All controls are at least 50 logical px.

Sleep after exposes 5/10/15/30 minutes idle and Never in BookSync. Android owns
the timeout: the companion writes only `Settings.System.SCREEN_OFF_TIMEOUT` on
an explicit trusted command, on its worker. If Android requires WRITE_SETTINGS,
the user's selection opens Android's permission page; returning and choosing
again performs the write. This is a user-opened Settings action, included in the
reading gate's call-site audit. No automatic permission launch occurs. Firmware
power behavior is unchanged. Android/vendor power policy and KOReader's own
screen-awake behavior may further constrain the effective timeout; device
acceptance is still required.

Device settings are a small private lifecycle snapshot through Library, independent
of account ownership. The provider refreshes it off-thread; group paints read
only that snapshot. An async write returns a device record, never an account
record, and redraws only its still-visible initiating Settings owner. Missing
companion state disables the timeout control and says Not available.

Updates starts with Installed (version and installed channel), one channel picker,
Check now and What's new; existing automatic update and key-log controls follow.
Installed identity does not change when the selected update channel changes.
About starts with Version and This reader; shared credits remain available with
the PIN locked. Home starts Edit layout, Reset layout, Home screen, Page names;
the existing Home-button policy follows those four approved rows.

Sleep source and exclusion browsing reuses normalized companion SleepChoices.
The new neutral `sleep.choices` library operation exposes at most six names and
counts per call, with total/next, including lists, collections, libraries and
exclusion tags. Loading, error, empty, not-saved and unavailable counts remain
explicit. Current selections persist through category and page changes. Existing
source exclusivity and rule normalization remain the shared owners' behavior;
users can also remove stored exclusions or type a tag inside BookSync.

Every screen and widget declares strict deterministic limits; Library inherits
the caller's budget. Choice pages read at most six rows and 16 KiB in one batch;
they may draw at most ten small control/choice rows, paged before painting.
Settings groups retain their screen-family budget. Device snapshot reads account
for one cached local row and zero decode/round-trip work during paint. Filtering,
counts, sorting and choice-catalog decoding stay in the companion, with no render
network or subprocesses. Call and paint info timing spans remain mandatory.
Host tests do not prove the pending M8C <500/<50/<30/<100 ms device targets.

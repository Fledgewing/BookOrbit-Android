# Android design review, pass 4

Baseline: `7b8311cc`, on `feature/0.12`. Android only, under the maintainer's
2026-11-25 authorization. The fetched `origin/design/booksync-home` still carries
revision 14; the approved revision 16 notes and prototype imported into
`feature/0.12` are the visual reference for this pass. DESIGN §3.5, §6 and §8.5
still govern widget ownership, neutral adapters and staged delivery.

This is a review of the installed foundation, not sign-off on full prototype
parity. The flow simulator constructs the native widget trees and exercises
paint paths; it does not provide a real KOReader framebuffer or prove font
metrics, wrapping, grayscale appearance or device latency. No device was used.

## Confirmed defects fixed

References in this table are at the baseline commit, under
`android/koreader/orbit.koplugin/`.

| Severity | Finding | Fix and regression |
|---|---|---|
| P2 | `ko/home_widgets.lua:50`: 30 px headers, 28–38 px retry/open/resume controls and 40–48 px book/list rows violate the 50 px touch minimum. | Headers/actions are at least 50 px; list rows are 52 px. Compact cards place actions side by side. The flow sweep constructs every installed Continue reading, Book list (both styles), Lists, Library and Battery size in ready, empty, loading, error and both offline states; checks target dimensions, bounds and mutual intersections. |
| P2 | `ko/battery.lua:23`, `:62`, `:65`, `:78`: widget link, Close, tabs and daily paging are too small. | Increase targets to 50 px, reserve the title band, and check screen controls alongside the existing six-size/tab flows. |
| P2 | `ko/home_editor.lua:145`: Configure is 40 px high. | 50 px, with a separate toolbar band; regression checks it cannot overlap move/remove or page controls. |
| P2 | `ko/home_host.lua:58`, `:79`: every page says BookSync, and the owned Home has no settings destination. | Show the actual page name, add the Home menu and use the existing Settings rows/PIN policy. The flow drives the menu and tests locked/unlocked native tab contents. Close/Edit/chips now meet the touch minimum too. |
| P2 | `ko/home_host.lua:242`: Back from a list on Library or Stats resets to page 1. | Remember the originating Home page until leaving the list; regression opens a list from Stats and returns there. |
| P2 | `ko/reader_panel.lua:50`, `logic/reader_panel.lua:19`: the battery estimate is inert and reformatted from hours in Lua. | Consume the companion's `display.page_estimate`, make it a Battery action even while learning, and verify no additional render read. |
| P2 | `ko/reader_panel.lua:36`: no BookSync Settings destination in the reader panel. | Add an action using the same Settings owner; dismiss the initiating panel first. Test the dispatch and dismissal. |
| P3 | `ko/menu.lua:282`: Settings has a ninth root companion shortcut despite already having Advanced under About. | Keep the eight approved groups; regression checks the root count. |
| P2 | `ko/home_widgets.lua:70`: short Continue reading cards omit the percentage. | Show it at every supported hero size, including offline-with-data; size/state regression checks the label. |

| P2 | `logic/layout.lua:194`: new M8C layouts include the extra Library page from the X4 default. | New/reset layouts use the approved Home + Stats pages. Exact placement regression covers both pages; existing saved layouts are not migrated. |
| P2 | `ko/home_host.lua:87`: cover shelves use the text-row capacity, collapsing wide shelves to fewer than three covers despite enough columns. | Bound shelf windows by columns; keep list windows bounded by 52 px rows. Regression verifies a 4×2 shelf requests four books within the same batch. |

## Screen and widget comparison ledger

This ledger distinguishes tested implemented behavior from remaining staged work.
The latter remains on ROADMAP; this review does not label it shipped.

| Surface | Comparison and disposition |
|---|---|
| Home / Stats pages | Page names, navigation, Back, account setup targets and one batched read tested in `test/home_host_flows.lua`. New/reset M8C layouts match the two-page revision-16 default (`logic/layout.lua:181`); saved layouts remain intact. Larger Library widgets remain available in the editor. |
| Continue reading | One plain bar, Resume/Details routing and percentage retained. `ko/home_widgets.lua:64` still uses a typographic cover placeholder and lacks the companion-projected time-left/finish forecast, series and overflow actions. These require further owned read-model/widget work. |
| Book list / presets / Lists | Existing source/style/sort/caption and Cancel/Done draft semantics retained (`test/booklist_flows.lua`). Counts and exclusion stay in the companion. Touch geometry fixed. Real covers, richer row composition and full-height narrow Lists treatment remain presentation work. |
| Library widget / Storage | Group and device links tested. Compact Library uses one combined count/link band so its targets fit. `ko/storage.lua` now owns real companion-projected storage figures/bar, confirmations and folder selection; the Library widget adds Collections. `DeviceStorage.kt` measures StatFs and the tracked file/cache index. Host regressions cover missing capacity and stale previews; M8C visual/timing acceptance remains pending. |
| Battery widget and four tabs | Existing learning/missing/error labels, bounded daily windows, actual-level glyphs and charges retained (`test/battery_flows.lua`). Targets fixed. Grouped rates, export/compare and efficiency metrics remain explicitly deferred in `shared/features.json`. No replacement battery model. |
| This week / Year / When you read / Records | Existing native paint paths and one shared materialization exercised in `test/test_reading_stats.lua` and Home flows. Retain explicit per-field provenance and separate possibly overlapping local-today minutes: more truthful than demo totals. `logic/reading_stats.lua:29` still has simplified calendar/legend, peak and records typography compared with the prototype. |
| Clock and later picker widgets | Clock now has a snapshot renderer. Word, Reading buddy and Light are installed in both Android picker sizes with local companion projections; see [local widget evidence](F12-G-LOCAL-WIDGETS.md). Highlight and Year ago require authorized server snapshots and remain staged with Recommended/Discover. |
| Home editor / Rename / picker / Book list configuration | Existing geometry-only moves, draft cancellation, atomic Done, keyboard Rename and paged source windows retained; Configure touch target fixed. `ko/home_editor.lua:113` draws geometry cards rather than dimmed live previews, preserving the maintainer's zero-read move budget. Tags/toolbar/next-size copy remain visually different from the HTML. |
| Owned Library / Search / filter sheet / pickers | Existing neutral filters, companion counts, exclusion context, paging and removable chips retained; check `test/booklist_flows.lua` and `test/test_filter_sheet.lua`. Chips enlarged without replacing the settled sheet. The g-series slice adds companion-materialized grouped cover rows, full-Series progress dots and an owned Series destination; cached covers and bulk transfer jobs remain staged. |
| Reader top / Book info / Details | Bounded progress, missing-data states, native menu escape, async visibility guard and plain bar tested in `test/reader_panel_flows.lua`. Battery and Settings destinations fixed. The reader slice extends the same owner with the header icons, separate bottom scrubber/quick settings panel and native Contents/annotations/Go to/search/bookmark dispatch. See [reader implementation and limits](G-READER-NOTES.md); framebuffer/font fit and device latency remain unverified. |
| End of book / Series | `ko/endsheet.lua:77` retains the existing end-of-book flow and its regressions, rather than replacing transport-owned end actions while another worker changes them. The g-series slice adds the owned Series page and `SeriesUI.show(key)` for a later end-sheet entry; this slice leaves the transport-owned end actions intact. |
| Settings: Your server | Existing account and independent sync/OPDS forms, signed-out/own-login states, sign-out/remove confirmations and stale/cancelled result guards retained. `test/test_account.lua` plus flow tests cover the settled forms; no phone UI introduced on Android. |
| Settings: Sync, Wi-Fi & power | The g-settings follow-through retains the existing row owners and adds the full Mode card, Your own settings/Back to Balanced, inactive-setting explanations and Sleep after inside BookSync. Companion estimates and lifecycle-cached device state remain bounded; Android timeout permission/policy still needs device acceptance. See `F12-G-SETTINGS.md` and `test/settings_flows.lua`. |
| Settings: Library & downloads | Existing shared storage limits/cache/copy settings and full refresh retained (`ko/menu.lua:243`). Storage page and the companion-persisted folder chooser now open from these rows; real-device acceptance remains pending. |


| Settings: Reading | Settled Custom apply-then-edit, live previews, one-time copy/Undo and status strip preserved. Existing tests cover engine dispatch, wrapping style operations and lifecycle. |
| Settings: Home | The g-settings follow-through orders Edit layout, Reset layout, Home screen, Page names as approved; the existing Home-button policy follows. Existing editor/selection owners, Back and focus are retained (`test/settings_flows.lua`). |
| Settings: Sleep screen | The g-settings follow-through retains shared rows and browses lists, collections, libraries and exclusion tags inside BookSync. Companion `sleep.choices` projects at most six names/counts and 16 KiB per call, with loading/error/empty/not-saved states; selection rules remain the existing sleep owners. |
| Settings: Updates / About | The g-settings follow-through adds installed-channel summaries, What's new and This reader while preserving the single channel picker and locked-menu credit access. Installed identity is independent of the selected channel. No update transport edits; real framebuffer appearance remains unverified. |
| Status strips | Existing status-layout simulator regressions retained, including bounded cells and preview behavior (`test/status_layout_flows.lua`). |

## Reuse and performance

Builds on `ko/home_host.lua:29` (one screen owner), `ko/home_widgets.lua:29`
(native button construction), `ko/library.lua:16` / `:29` (inherited budgets),
`ko/menu.lua:173` / `:318` (shared groups and PIN policy), `ko/reader_panel.lua:5`
(existing EndSheet subclass), `logic/sheet_layout.lua` (measured reader rows) and
`logic/home_host.lua:15` (grid projection). No parallel cache, store or adapter.

Every screen/widget keeps its declared `logic/budgets.lua` budget. Filtering,
counts, joins and estimates remain companion work; Lua only draws bounded rows.
Zero subprocesses/render network, one Home batch and 16 KiB widget snapshots
remain enforced. No new render reads were added. Existing info timing spans
remain; host timings do not establish the <500/<50/<30/<100 ms device targets.
The Settings entry uses KOReader at pin
`9192014d8bd82a91dc1012473be0f238dedfdb54`,
`frontend/ui/widget/touchmenu.lua:479` (standalone defaults), `:780` (a tab is the
row array itself), and `frontend/apps/reader/modules/readermenu.lua:405` (native
construction). The compatibility symbol guard now covers that constructor.

Server transport, `ko/net.lua`, adapters and sync/outbox code were not changed.
No hypothetical edge-case machinery, firmware changes, device actions or releases.

# BookSync Android 0.12 finish audit

Audited `origin/feature/0.12` at `e44c9428` (2026-11-27). Scope is every
Android outcome in ROADMAP.md's “Next release (0.12)” section, including its
second table and the widget-engine paragraph. Firmware-only rows and firmware
pins are excluded. “Done” means implemented in the audited source, not released
or accepted on a physical reader. Existing device-acceptance gates remain open.
No device, release, tag or workflow dispatch is authorised by this audit.

Paths below use `P = android/koreader/orbit.koplugin`,
`C = android/companion/app/src/main/java/net/fledgewing/orbitcompanion`.
References are to the audited commit. Rows deliberately retain roadmap duplicates
so no Android outcome disappears during reconciliation.

## Source audit

| Android 0.12 outcome | Code state | Evidence and remaining work |
|---|---|---|
| Finish server-free catalog cutover: copies, grouping, recommendations, finish | Done | `C/server/bookorbit/CatalogWorkflow.kt:100` imports old queues; `:141` owns copy/finish commands; `:295` drains ordered finish work. `C/server/bookorbit/BookOrbitProjection.kt:351` owns grouping. `P/ko/recommendations.lua:1` presents Library-owned recommendations. F12-Q2 step 5 is present; the older pending rows are stale. |
| Open owned Series from the end sheet, including last book/offline membership | Done | `P/ko/finish.lua:73` opens Series and restores the sheet/session; `P/ko/series.lua:53` reads bounded saved membership. Emulator review explicitly checks this route (`tools/e2e/android/review.py:93`). |
| Recommended and Discover widgets, daily pick and Another | Done | `C/CatalogPersonalReading.kt:6` is the saved-catalog provider; `C/PersonalReading.kt:1` owns selection; `P/logic/widget_registry.lua:25` registers the widgets. No Lua ranking or transport. |
| Continue reading / Book list cards, covers, forecasts, actions | Done after audit | Cards, covers and forecasts were present at the audited base. The card-actions follow-up adds capability-gated status/Undo with durable position proof and safe confirmed removal; see [card implementation notes](F12-CARDS.md#arbitrary-book-actions). Physical appearance/latency acceptance remains separate. |
| Word, Buddy, Light, Highlight and A year ago | Done | `P/logic/widget_registry.lua:21` and `:25` register all five; `P/ko/local_widgets.lua:3` renders local snapshots. Personal sources aggregate behind Library. |
| Server-free covers, refresh, copies, recommendations, finish (duplicate) | Done | `P/ko/library.lua:514` dispatches cover work; `:679` dispatches refresh. Copy/finish ownership is `C/server/bookorbit/CatalogWorkflow.kt:141`. The row saying these are pending is stale. |
| Independent account/sync/OPDS logins, encryption, sign-out, account stats | Done | `P/ko/account.lua:1` uses Library; `C/AccountVault.kt:20` encrypts private credentials. `P/ko/library.lua:401` owns account commands and `C/ServerCommands.kt:33` routes login removal. No UI backend requests. |
| Configurable Book list presets, counted sources, Custom filters | Done after audit | `P/ko/booklist_config.lua:42` paints bounded source pages; `:22` opens the shared filter. `P/ko/home_editor.lua:165` configures the selected widget. |
| Two-page Home / Stats defaults, shared lists/search, save filters | Done | `P/ko/home_host.lua:15` resolves layouts; `:38` shares one paint context. `P/logic/widget_registry.lua:11` defines the installed widget contracts. List/search use the owned host and filter sheet. |
| Editable Custom reading values and copy/Undo | Done | `P/ko/custom_reading.lua:1` owns the approved editors; native style operations remain behind `P/ko/reading_style.lua:1`. Emulator review checks persisted native values (`tools/e2e/android/review.py:88`). |
| Home editor add/remove/move/resize/pages/reset/atomic save | Done | `P/ko/home_editor.lua:19` creates the editor, `:153` renames, `:192` resizes, `:207` resets, `:213` saves through Library. |
| Default owned Home, additive upgrade/news, signed-out shelves, one batch | Done | `P/ko/settings.lua:52` calls additive migration; `:65` persists migration/news together. `P/ko/home_host.lua:388` shows pending news; `:399` acknowledges once. The host owns paint batching. |
| Widget layout engine and budgeted host contracts (paragraph) | Done | `P/logic/widget_registry.lua:5` binds per-widget budgets; `P/ko/home_host.lua:15` validates layouts; `P/ko/library_services.lua:84` atomically saves through LayoutStore. |
| BookSync Home / complete staged reader-preset library / detail | Done after audit | The [retained inventory](F12-HOME-INVENTORY.md) now maps every approved retained card, source, root and local control to its implementation and verification. Thirty widget types are installed; Book list presets remain distinct selections rather than being counted as extra widget types. The approved read-only library is complete on Android. Local completion/goal settings, crash presentation and reader-inline companion surfaces remain separate approved follow-ups; physical acceptance and release remain pending. |
| Widget-first shared Home editor (duplicate) | Done on Android | `P/ko/home_editor.lua:19` and Library layout services implement the Android editor. Firmware editor variants are outside this task. |
| Tap to download on Home/lists/Series/detail | Done after audit | [Download jobs](F12-DOWNLOADS.md) adds bounded file/destination selection, progress, Cancel, explicit Resume, offline consent, missing-file recovery and departure-safe opening through Library. Streaming, linking and controls stay in their companion owners. Series next-N remains the separate row below. |
| Series in order/read state/download next | Done after audit | Ordered membership and grouped progress plus [exact next-N previews and durable queues](F12-SERIES-DOWNLOADS.md) are implemented on Android; physical acceptance and firmware remain. |
| Stable / RC / Preview channels, migration, no channel downgrade | Done | `C/Logic.kt:244` defines product-version eligibility; `:272` picks permitted versions; `:276` controls installation ordering. `C/SettingsStore.kt:60` migrates the old opt-in once. `P/ko/menu.lua:336` provides the one reader picker. Signed withdrawal recovery is deliberately retained. |
| Companion measured battery / usual-use / charges / Wi-Fi estimates | Done | `C/BatteryEstimate.kt:13` computes usual days; `:49` charges; `:107` snapshots; `:148` formats labels. Device measurement acceptance remains pending, not missing model code. |
| In-book progress, info/details, cached stats, manual Sync | Done | `P/ko/reader_panel.lua:299` reads bounded progress; the top panel owns a user-invoked Sync with visible-panel callback checks. `P/ko/library.lua:339` dispatches current sync. Full owned specialist navigation is a separate row below. |
| Reusable filter sheet / facets / chips / Home list action | Done | `P/ko/filter_sheet.lua:1` is the owned sheet; `P/ko/library.lua:345` reads companion facets; `P/ko/booklist_config.lua:22` reuses it. |
| Reading statistics and Stats widgets / completion and goal settings | Done after audit | The maintainer approved the [settings design/mockups](F12-F-NOTES.md#local-completion-and-goal-settings) on 2026-11-27. [#233](https://github.com/Fledgewing/BookSync/pull/233) adds the companion-owned durable local completion ledger, exact Undo, provenance-qualified additive 0.11 import and a 1–999/Off yearly goal that carries its target forward. Account totals remain separate when overlap is unknown. Native settings and upgrade checks pass; physical acceptance remains. |
| Library interface / neutral filters / adapters / cached fallback | Done for implemented Android operations | `P/ko/library.lua:254` owns budgets/read contexts; `C/LibraryReadModel.kt:45` publishes batches; `C/server/bookorbit/BookOrbitProjection.kt:120` implements saved projections. `tools/test/test-server-boundary.py` and `test-ui-boundary.py` enforce the boundary without skip lists. Missing commands are not permission to bypass it. |
| Server-free plugin / lifecycle migration (duplicate) | Done | `C/server/bookorbit/CatalogWorkflow.kt:100` and the owned lifecycle import preserve queues; F12-Q2 step 5 retires the Lua adapter. The “parallel catalog/cover/finish pending” text is stale. |
| Grouped reader settings, modes, battery, one update channel | Done | `P/ko/menu.lua:264` exposes mode/reset, `:336` Updates; `P/ko/settings_view.lua:126` pages sleep choices. Battery and Custom editors are integrated. Physical validation remains pending. |
| Persistent deduplicated crash summary, never auto-upload | Done after audit, approved Companion scope | The maintainer approved the [design/mockups](../crash-summary.md) on 2026-11-27. [#232](https://github.com/Fledgewing/BookSync/pull/232) adds an atomic private 8 KiB record, at most four deduplicated allowlisted fingerprints, exact previous-handler delegation and explicit Clear/Copy in Setup → Details. It never retains exception messages or uploads automatically. Native KOReader capture remains a separately designed handoff under the approved scope, recorded in the later roadmap. |
| Add-on mode and setup checklist | Done after audit | Approved fallbacks are verified in [add-on mode](../addon-mode.md#android-012-fallback-verification). [Menu recommendations](F12-MENU-RECOMMENDATIONS.md) add the two missing descriptors, fix the initial-fetch pending deadlock, protect customized bindings and restore exact prior menu ownership on Undo. Physical acceptance remains. |
| Unified in-book menus | Done after audit | [Owned reader navigation](F12-READER-NAVIGATION.md) implements cached Contents/saved-item windows, native page/percent and cancelable search, per-lifetime reversible hooks and native/plugin escape. Explicit enable/disable and the separate [add-on recommendation integration](F12-MENU-RECOMMENDATIONS.md) are implemented. Physical acceptance and firmware remain. |
| No visible app switches (stretch) | Done after audit, approved ordinary-action scope | The maintainer approved [reader-inline Status/Helpers and system-action return](READER-COMPANION-SURFACES.md) on 2026-11-27. [#234](https://github.com/Fledgewing/BookSync/pull/234) implements bounded Library snapshots, explicit helper controls, live permission/protection/dependency checks and book/menu-scoped return. Permission never enables a helper. Setup, security and explicit other-app actions retain their approved external routes. Background ownership and transparent restart were already implemented. |

## Dependency order and UI gates recorded at the first audit

1. Reconcile stale roadmap statements in the audit PR; do not mark unreleased work shipped.
2. Complete arbitrary-book commands and Series jobs through Library/adapter owners.
3. Complete approved add-on fallbacks and checklist behavior, preserving 0.11 state.
4. Complete approved in-book increments independently, retaining stock escape.
5. Propose crash-summary presentation and local statistics controls in docs-only PRs;
   merge proposals, list NEEDS APPROVAL, and do not build their visible controls yet.
6. Reconcile the staged Home inventory and stretch app-switch scope against explicit
   approved surfaces; report any unapproved additions separately.

Each implementation PR requires unit and the area's existing emulator flows, required
checks green, a rebase against the current target, then squash merge. Firmware sources
and pin stay untouched. Physical device acceptance and release publication are separate.

## Verification of audited base

- Lua logic: **256 passed, 0 failed**.
- Lua flows: **264 passed, 0 failed**.
- Companion: **828 tests, 0 failures, 0 errors, 4 skipped**; shared-version verification, debug APK and debug lint passed.
- Server boundary: **12 tests**; UI boundary: **6 tests**; feature matrix: **4 tests**; emulator harness safety: **8 tests**. All passed.
- Existing emulator scenarios are `tools/e2e/android/review.py` and `upgrade.py`;
  harness safety tests alone are not emulator acceptance.

## Late source-picker follow-up

Final cross-feature acceptance exposed a cold paged Source response arriving after
the picker’s bounded polling window. The ready row was cached, but the modal had
no Library observer. [The source-picker repair](F12-SOURCE-PICKER.md) adds a neutral
observer without replacing Home’s subscriber; a failing regression covers late
arrival, covered dialogs and close. This completes the existing approved control.

## Scope clarification for later backends

The approved 0.12 adapter boundary is implemented for BookOrbit and local libraries.
[DESIGN §6](DESIGN.md#6-small-adapter-boundary-proposed-not-a-frozen-protocol)
explicitly says “Grimmory shaped, not claimed implemented”; the opening scope of
[backend independence](../backend-independence.md) keeps new backends and the portable
ledger in later phases with their own acceptance. The Next release row previously
said “BookOrbit/Grimmory adapters”, which overstated this increment. It now names
the implemented adapters and later-backend contracts. No Grimmory credential
collection, backend or portable-ledger migration is claimed complete here.

## Final outcome reconciliation

Every Android outcome from the audited Next release table is either implemented
or tracked in the approval/implementation ledger below. “Implemented” remains
an unreleased feature-branch state; physical-reader acceptance is pending.
The original source references and baseline test counts above stay anchored to
`e44c9428`; follow-up notes and the retained inventory describe the later changes.

| Approval gate | Merged docs-only proposal | Implementation state |
|---|---|---|
| Persistent crash summary | [#206](https://github.com/Fledgewing/BookSync/pull/206), [approved design/mockups](../crash-summary.md) | Approved 2026-11-27; [#232](https://github.com/Fledgewing/BookSync/pull/232) merged, Companion scope. |
| Local completion ledger and device goal settings | [#207](https://github.com/Fledgewing/BookSync/pull/207), [approved design/mockups](F12-F-NOTES.md#local-completion-and-goal-settings) | Approved 2026-11-27; [#233](https://github.com/Fledgewing/BookSync/pull/233) merged. |
| Ordinary companion status/helper screens inside the reader | [#211](https://github.com/Fledgewing/BookSync/pull/211), [approved design/mockups](READER-COMPANION-SURFACES.md) | Approved 2026-11-27; [#234](https://github.com/Fledgewing/BookSync/pull/234) merged, ordinary-action scope. |

The target branch subsequently added the docs-only bedtime and Rest your eyes
reminders outcome in [#231](https://github.com/Fledgewing/BookSync/pull/231) and
[#236](https://github.com/Fledgewing/BookSync/pull/236). The [design and mockups](../reminders.md)
were subsequently approved for Android as well as firmware in [#239](https://github.com/Fledgewing/BookSync/pull/239). This outcome was added after the pinned initial audit and is being implemented separately in [#242](https://github.com/Fledgewing/BookSync/pull/242) and the active Android reminder integration branch. It is not included in the completed 29-outcome claim or the test totals below; its Library delivery, reader UI and emulator acceptance remain pending.
Firmware-only outcomes, including rows saying Android is unchanged, remain outside
this Android task. No firmware files or pins, devices, releases, tags or workflow
dispatches are part of these finish PRs.

## Verification of the completed approved Android scope

The combined Achievements and reader-companion code passes **954 JVM tests**, with
**0 failures, 0 errors and 4 existing skips**; shared-version verification, debug
assembly and lint pass. Lua passes **265 logic tests and 313 flows**. Boundary
checks pass **12 server + 6 UI tests**, feature generation **4 tests**, and emulator
host safety **14 tests**. Fixture limitations remain documented in the
[native tools guide](../../../tools/e2e/android/README.md): native tests use an
isolated ServerAdapter, while adapter protocol and durable-work behavior are JVM
coverage and the pinned live server kit is a CI check.

Native acceptance includes the **70-screen/action review with all 30 widget
types**, **17 focused Achievements/year/series/Unopened checks**, **10 crash-summary
checks**, **15 reader-companion checks**, **8 source/root checks**, **10 local
goal/completion checks**, and **4 proven 0.11 completion-import checks**. The
separate 0.11 Home upgrade and fresh-profile checks also pass. Proven import leaves
the borrowed native sidecar and legacy finish queue byte-for-byte unchanged.
Earlier per-outcome native evidence remains linked from the implementation notes.

The final cold-profile review exposed test-driver assumptions, which are fixed:
profile reset archives both fixture directories; Filter closes through its real
callback; Home readiness includes every visible widget snapshot; immutable window
bounds use indexed rows. The 20-second screen deadline remains. The Details-page
unit test waits for asynchronous diagnostics rather than racing its loading frame.
The reader-companion integration settles the permitted position-consent action
before recording the page that a system-action return must preserve.

These are feature-branch implementation and emulator results. Physical-reader
acceptance, timing measurements and publication remain pending. The shared version
retains the branch's existing identity; this work creates no release or tag.

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
| Configurable Book list presets, counted sources, Custom filters | Done | `P/ko/booklist_config.lua:42` paints bounded source pages; `:22` opens the shared filter. `P/ko/home_editor.lua:165` configures the selected widget. |
| Two-page Home / Stats defaults, shared lists/search, save filters | Done | `P/ko/home_host.lua:15` resolves layouts; `:38` shares one paint context. `P/logic/widget_registry.lua:11` defines the installed widget contracts. List/search use the owned host and filter sheet. |
| Editable Custom reading values and copy/Undo | Done | `P/ko/custom_reading.lua:1` owns the approved editors; native style operations remain behind `P/ko/reading_style.lua:1`. Emulator review checks persisted native values (`tools/e2e/android/review.py:88`). |
| Home editor add/remove/move/resize/pages/reset/atomic save | Done | `P/ko/home_editor.lua:19` creates the editor, `:153` renames, `:192` resizes, `:207` resets, `:213` saves through Library. |
| Default owned Home, additive upgrade/news, signed-out shelves, one batch | Done | `P/ko/settings.lua:52` calls additive migration; `:65` persists migration/news together. `P/ko/home_host.lua:388` shows pending news; `:399` acknowledges once. The host owns paint batching. |
| Widget layout engine and budgeted host contracts (paragraph) | Done | `P/logic/widget_registry.lua:5` binds per-widget budgets; `P/ko/home_host.lua:15` validates layouts; `P/ko/library_services.lua:84` atomically saves through LayoutStore. |
| BookSync Home / complete staged reader-preset library / detail | Partly done | Owned Home/detail and the accepted widget set exist. `P/logic/widget_registry.lua:11`–`:28` is the actual installed semantic inventory; the design's full staged reader-preset mapping is broader. The [retained Home inventory audit](F12-HOME-INVENTORY.md) enumerates each missing metric/decor card, shelf/source, count/root and local control with source evidence. Series jobs are now complete; local completion/goal settings are a separate approval gate. Do not label the full staged mapping shipped merely because the host exists. |
| Widget-first shared Home editor (duplicate) | Done on Android | `P/ko/home_editor.lua:19` and Library layout services implement the Android editor. Firmware editor variants are outside this task. |
| Tap to download on Home/lists/Series/detail | Done after audit | [Download jobs](F12-DOWNLOADS.md) adds bounded file/destination selection, progress, Cancel, explicit Resume, offline consent, missing-file recovery and departure-safe opening through Library. Streaming, linking and controls stay in their companion owners. Series next-N remains the separate row below. |
| Series in order/read state/download next | Done after audit | Ordered membership and grouped progress plus [exact next-N previews and durable queues](F12-SERIES-DOWNLOADS.md) are implemented on Android; physical acceptance and firmware remain. |
| Stable / RC / Preview channels, migration, no channel downgrade | Done | `C/Logic.kt:244` defines product-version eligibility; `:272` picks permitted versions; `:276` controls installation ordering. `C/SettingsStore.kt:60` migrates the old opt-in once. `P/ko/menu.lua:336` provides the one reader picker. Signed withdrawal recovery is deliberately retained. |
| Companion measured battery / usual-use / charges / Wi-Fi estimates | Done | `C/BatteryEstimate.kt:13` computes usual days; `:49` charges; `:107` snapshots; `:148` formats labels. Device measurement acceptance remains pending, not missing model code. |
| In-book progress, info/details, cached stats, manual Sync | Done | `P/ko/reader_panel.lua:299` reads bounded progress; the top panel owns a user-invoked Sync with visible-panel callback checks. `P/ko/library.lua:339` dispatches current sync. Full owned specialist navigation is a separate row below. |
| Reusable filter sheet / facets / chips / Home list action | Done | `P/ko/filter_sheet.lua:1` is the owned sheet; `P/ko/library.lua:345` reads companion facets; `P/ko/booklist_config.lua:22` reuses it. |
| Reading statistics and Stats widgets / completion and goal settings | Partly done | `C/ReadingStats.kt:133` emits null local finish/target values; `:172` supplies remote goals only. There is no owned local completion ledger or local goal setting in `shared/settings/schema.json`. Existing server-first precedence and overlap-safe Today must remain. New setting controls need mockup approval before implementation. |
| Library interface / neutral filters / adapters / cached fallback | Done for implemented Android operations | `P/ko/library.lua:254` owns budgets/read contexts; `C/LibraryReadModel.kt:45` publishes batches; `C/server/bookorbit/BookOrbitProjection.kt:120` implements saved projections. `tools/test/test-server-boundary.py` and `test-ui-boundary.py` enforce the boundary without skip lists. Missing commands are not permission to bypass it. |
| Server-free plugin / lifecycle migration (duplicate) | Done | `C/server/bookorbit/CatalogWorkflow.kt:100` and the owned lifecycle import preserve queues; F12-Q2 step 5 retires the Lua adapter. The “parallel catalog/cover/finish pending” text is stale. |
| Grouped reader settings, modes, battery, one update channel | Done | `P/ko/menu.lua:264` exposes mode/reset, `:336` Updates; `P/ko/settings_view.lua:126` pages sleep choices. Battery and Custom editors are integrated. Physical validation remains pending. |
| Persistent deduplicated crash summary, never auto-upload | Not started | No crash-record store, uncaught-exception handler, startup dedupe or Library diagnostics projection exists in Android production sources. `P/ko/library_diagnostics.lua:2` only tests the sync path; `C/Pages.kt:18` is not crash persistence. There is no approved crash-summary screen/mockup: prepare a docs-only proposal and retain NEEDS APPROVAL for visible presentation. |
| Add-on mode and setup checklist | Partly done | The approved core and checklist are implemented (`C/Mode.kt:25`, `C/ChecklistLogic.kt:9`). At the audit base, `C/Pages.kt:559` still requires install permission instead of manual-install fallback and `C/Mode.kt:244` combines Sleep sync and Screen off. The add-on follow-up implements those fallbacks, update-ready mirroring and helper navigation; menu recommendation integration remains dependent on the reader-menu slice. `docs/design/addon-mode.md:754`–`:763` identifies additional update-ready mirroring/helper deep-link/recommendation follow-ups; these must be checked and completed, not treated as shipped by the umbrella row. |
| Unified in-book menus | Partly done | Top/bottom panels, presets and stock escape exist. `P/ko/reading_style.lua:198`–`:202` sends Contents, annotations, Go to and Search to stock screens. Owned hierarchical navigation, saved-item lists, basic go form and search presentation remain; so do the per-lifetime reversible hook/disable and third-party coexistence acceptance in DESIGN §13. Existing native specialist tools and exact reading position must remain available. |
| No visible app switches (stretch) | Partly done / NEEDS APPROVAL | Background worker ownership and owned Home are implemented. The audit initially treated `C/Mode.kt:192` as a visible restart screen; `android/companion/app/src/main/AndroidManifest.xml:183` and `android/companion/app/src/main/res/values/styles.xml:25` show it is already transparent. The real ordinary-action gap is `P/ko/library_services.lua:35`–`:47` opening status/helpers/setup. [Reader-inline proposal and mockups](READER-COMPANION-SURFACES.md) are unapproved and remain unbuilt; explicit Android/security/other-app actions are retained. |

## Dependency order and UI gates

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

# Android Battery UI (F12-O)

Android implementation authorised 2026-11-25. Read the approved rev-16 design from
`origin/design/booksync-home` at `db461a9a7c0581e61680ce1db5ee9e7cf73f21c6`:
DESIGN.md §3.5 (widget-first/layout data), §6 (adapter boundary), §8.5 (staging),
DESIGN-NOTES.md's widget table and Battery page, layout.schema.json, and
prototype.html's W.battery, batteryView and modeBat. M8C is android-tablet,
four columns. This is building work on feature/0.12, not a release. X4 Pro,
X4 and X3 follow Android under the maintainer's explicit Android-first ruling.

## Existing modules reused

- `android/koreader/orbit.koplugin/ko/home_widgets.lua:4` registers the renderer;
  `:18` supplies the existing canvas/text/button helpers. No parallel widget host.
- `android/koreader/orbit.koplugin/ko/home_host.lua:27` owns a Home paint's batched
  reads and its widget failure boundary. Battery reuses the existing need and adds dispatch.
- `android/koreader/orbit.koplugin/ko/library.lua:72` supplies mode estimates;
  `:73` already supplies the one-row battery operation. No new library operation.
- `android/koreader/orbit.koplugin/logic/widget_registry.lua:15` already declares
  all six Android Battery sizes. The layout engine's default Stats placement is
  reused; the editor discovers registration rather than receiving a second list.
- `android/koreader/orbit.koplugin/ko/menu.lua:199` already builds the sync/power
  group and its three companion-backed mode cards. Replace only the disabled
  Battery placeholder with navigation to the owned page.
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/BatteryEstimate.kt:26`
  already projects the three mode lines; `:107` computes the bounded battery model.
  Extend that model with companion-formatted display labels, not another model.
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/StatsStore.kt:188`
  remains the sole worker-side snapshot provider and preserves clock boundaries.

F12-J merged during integration (`6434d007`). Its existing
`logic/battery_widget.lua:1` and `ko/home_widgets.lua:130` interim Battery registration
are extended here; no parallel scalar formatter or second Battery registration remains.
The renderer consumes F12-J's immutable `snapshot.data` contract and keeps the shared
Stats batching, Home navigation, saved filters and foreground-stack gate. Compact
geometry tests retain the gauge bounds at short and narrow approved spans.

## UI and snapshot contract

`logic/battery_widget.lua` only selects display rows and geometry. `ko/battery.lua`
registers 2×2, 1×2, 2×1, 4×3, 2×3 and 4×2 through the existing registry. Estimates
say “at your usual use” (“· usual use” on one-column tiles); the other figures
say “reading non-stop” and “standby only”. Medium/large tiles add rates, recorded
weekly use and the last charge; large adds the charging rate and explicit missing
page-efficiency evidence. Widgets have no daily chart, following the design notes.
The glyph uses the snapshot level, including unknown level after a clock correction.

The user-opened Battery page has Overview, Rates, Daily and Charges tabs. Overview
includes usage share and all three mode estimates; Daily selects seven of at most
14 companion-formatted rows, with measured drop bars; Charges shows at most five.
Settings → Sync, Wi-Fi & power → Battery opens the same page as the widget.
The existing reading gate recognizes this user-opened page during construction
and while visible; closing restores the book gate. The required companion check
is shared with Home. A cold projection can redraw only the already-visible page, with at most five
scheduled checks; closing cancels it. It never shows or reopens a page on an event.

The additive `display` member contains encoded UTF-8 labels, bounded tab rows/counts
and daily bar fractions. Existing numeric consumers and mode-estimates stay intact.
The companion formats durations, uncertainty, calendar labels, charges and daily
usage, and sums the recorded weekly use. The plugin does no battery calculation,
date conversion, aggregation, catalog work, JSON decoding or server parsing.
Missing measurements stay missing, including missing uncertainty. The existing
clock-reset/time-change filtering determines evidence; UI never fills a gap from
the current wall clock. Empty daily history is not displayed as zero usage.

The model does not yet supply page/refresh efficiency or content/front-light rate
breakdowns: the page names the missing measurements explicitly. Export/compare
remain in the existing companion UI; adding those actions to the owned page and
richer rate breakdowns is later work, not dummy buttons or synthetic values here.

## Performance and validation

Every screen and widget has strict deterministic budgets; calls inherit the caller's
budget. Battery screen/widget each read one row, decode at most 16 KiB and spawn
zero subprocesses, with zero render-path network calls. Home retains at most one
batched companion round-trip. Daily pagination only selects seven rows; all heavy
work remains in the companion. Existing library/Home timing plus Battery render
spans log actual device milliseconds. Host tests do not establish the pending
<500 ms Home, <50 ms widget, <30 ms cached window or <100 ms editor device targets.
AGENTS.md retains this rule for later slices.

Logic tests cover labels, distinct loading/error/learning/ready states, absent clock-boundary evidence and daily
pagination. Flow tests exercise all sizes through the real Home host, widget/page
navigation, tabs, pagination, Settings, cold/closed-page callbacks and oversize
rejection. Companion tests cover bounded display labels, missing/future samples,
explicit usual-use wording, charges and the 16 KiB envelope alongside F12-E's clock
and rate regressions. Feature-matrix generation/checks and the Android verification,
unit tests, APK build and lint run without accessing devices. Device validation
remains with the maintainer; this slice publishes no build, tag or release.

# KOReader reading status matches Xteink (W17)

Status: approved in chat, 2026-11-24 19:47 PST ("Yes do it."), including the
Xteink spaced page format; implemented by W17.
Platform: Android. Xteink already has configurable status slots; the shared format
fixture and host test will keep the Orbify preset consistent on both platforms.

![Proposed reading layouts](reading-status-layout.svg)

## Native feasibility, checked against pinned source

KOReader v2026.07.1, commit `9192014d8bd82a91dc1012473be0f238dedfdb54`:

- `frontend/apps/reader/modules/readerfooter.lua:660`: item order is a list of unique
  modes. `:414` provides one dynamic filler, sized from the remaining line width.
- `readerfooter.lua:804`: left/right/centre alignment wraps the entire horizontal
  group. `:2129` concatenates generated items into a single string; `:1946` offers
  bar, bullet, middle dot and no separator. There are no independent left, centre
  and right item anchors. A filler can split two groups, but cannot keep a chapter
  at the physical centre between unequal side groups.
- `frontend/apps/reader/modules/readercoptlistener.lua:366`: the alternate top
  status bar belongs to CRE documents. It cannot supply a top clock for PDF/CBZ.
- `frontend/apps/reader/modules/readertypeset.lua:540`: CRE page margins add the
  footer height unless reclaimed. `frontend/apps/reader/modules/readerview.lua:751`
  reserves footer height in paged documents; `:1060` recalculates on visibility
  changes. `readerview.lua:344-346,359-363,449-456` identifies the rendered
  page bounds from `state.offset.y` and `visible_area.h`; only screen surround
  outside those bounds is safe to use as PDF/CBZ margin.

Native settings do not meet the complete request. Use a custom BookSync renderer
integrated into the reader view, retaining native footer gesture handling.

CrossInk v2.0.0+bookorbit.1-rc3, commit `87e2e1984481e8a3d996f12b34b50a383f9013b8`:

- `src/components/themes/BaseTheme.cpp:861` draws top/bottom status lanes and uses
  theme font metrics and display insets; `:94` places the battery icon before its
  percentage in reader mode; `:935` formats clock, battery, pages and percentages.
- `src/components/UITheme.cpp:334` selects SMALL_FONT_ID by default, or UI_10/UI_12
  for the two larger preferences. Android will use KOReader's small UI face with
  device scaling rather than copying unscaled panel pixels.
- `src/util/ReaderStatusBarConfig.h:46` includes the middle dot among supported
  separators. The upstream page item is `N/M` (`BaseTheme.cpp:958`), not the
  example's spaced slash. Orbify's shared preset will use `12 / 340 · 4%`, as
  requested, on both platforms; this is a small Orbify formatting change on Xteink.

These references are relative to each pinned upstream repository, not overlay-
modified checkout lines. Implementation must add every newly used KOReader hook
or symbol to `android/koreader/test/koreader_compat.lua`.

## Appearance and behaviour proposed for approval

The top strip contains only a centred clock, using KOReader's 12/24-hour preference.
The bottom strip contains an outlined battery and percentage at the left, chapter
at the physical screen centre, and `N / M · P%` at the right. All are monochrome,
with no divider line or progress bar. The SVG shows EPUB, PDF and a long chapter.
No chapter metadata means an empty centre, including CBZ without an outline.

Measure both sides first. The centre's available width is twice the distance from
screen centre to the nearer side group's inner edge, minus a small gap. Truncate
the chapter on Unicode boundaries with a single ellipsis using rendered widths.
On very narrow displays suppress the chapter first; if needed omit battery percent
before its icon. Do not overlap the page group. Percent uses document reading
progress, clamped to 0–100 and rounded to the nearest whole percent; page numbers
use KOReader's document pagination. Missing/unknown totals show no progress group.

W29 follows the maintainer's rulings in the task brief: draw inside the book's
existing top and bottom margins and reuse the sleep-screen battery. No additional
space is reserved by default. Fit each strip's measured font height independently
to its margin, with the size setting as a maximum and one scaled pixel of padding
on each side. A margin too small even for the smallest font leaves that strip hidden.

“Add space for the status bar” defaults off. Offer it in the reader when either
margin cannot accommodate the selected size (keep it available while enabled so
it can be turned off). When on, add only `max(0, chosen strip height - margin)`
on each visible side. A sufficiently large margin adds nothing. Native saved
margins remain untouched. For CRE page mode, apply the missing pixels through
the margin setter. For paged documents, use only blank screen surround outside
the rendered page, never guessed whitespace within PDF/CBZ content. Scroll modes
have no safe page-edge margin: hide the strips by default; opting in reserves
the minimum strip viewport and translates draw, highlight and hit coordinates.
Retain the reading anchor and regenerate zoom/scroll geometry when space changes.
If rotation or zoom consumes surround before relayout, fit the current draw to
the actual available margin and defer any needed space adjustment to the next tick.

Keep KOReader's footer controller and tap regions; replace its visible rendering
while enabled. A footer-toggle gesture hides/shows the BookSync bottom strip through
the same native visibility state. It must continue to reach the native controller,
and the top/menu gesture regions must remain available. Menus cover the reader
normally; the status renderer is a reader child, never a floating window.

The setting is BookSync › Reading › “Status bar: BookSync layout (matches Xteink)”,
default off, with an Android-only shared schema entry. Off restores native footer/top
bar and margin/viewport state, including values that were absent originally.
Do not write BookSync's temporary geometry into book or global native settings.
Cancel hooks and timers on close/disable; keep enable/disable idempotent. Shared
setting changes apply at a safe reader layout update, preserving the reading anchor.

Repaint on page changes, minute boundaries and battery events. Time/battery-only
updates dirty only the changed strip using partial refresh, and are suspended when
the reader is covered or asleep. Ordinary page turns retain KOReader's page refresh
policy; enabling or changing geometry may require its normal document relayout.
No additional full refresh is requested by BookSync's status timer or battery handler.

## Implementation notes

W27 made `status_orbit_layout` default false (saved choices remain), and added
Small (14 pt), Medium (18 pt) and Large (22 pt), default Small. W29 keeps those
choices as maxima, fits each margin independently, and adds `status_orbit_add_space`
(default false). Strip height is measured text plus two scaled padding pixels;
only missing pixels are reserved when explicitly enabled. Horizontal inset is two
scaled pixels. The SVG illustrates the unchanged book margins and default-off settings.

The sleep glyph actually lives in the companion's `SleepCanvas`, not the Lua sleep
menu. Its outline, terminal and proportional fill now live in one declarative
rectangle drawing program, `shared/ui/battery.json`. `BatteryGlyph.draw` in Kotlin
and Lua interprets that same program on their respective canvases; both sleep and
reading call that entry point. There is no separate status battery geometry or
charging mark. The glyph scales with the fitted text. The companion packages the
program as a Java resource, and `package.sh` puts the same file in the plugin zip.
Tests check both call sites, packaged resource equality and empty/half/full pixels.
Xteink and the shared format fixture are unchanged. Only instance methods and
private copies of footer settings are changed; disabling restores inherited slots,
footer visibility/mode, the native text generator, header state and timers. Native
footer gesture handlers remain in charge, and their temporary mode is not persisted.

CRE page mode uses its margin setter only to add missing space when opted in.
When extra space is enabled, CRE scroll mode needs a reduced engine viewport
and translated draw/hit coordinates: `frontend/document/credocument.lua:908-934`
only adds the top margin in page mode, while
`frontend/apps/reader/modules/readerrolling.lua:895-899,1133-1138` derives scroll
steps and the final position from screen height and footer height (pinned KOReader
commit above). The temporary height adjustment is scoped to those scroll operations.
With extra space enabled, paged documents use the reduced viewport for zoom and scroll-state regeneration,
with draw, highlight and hit coordinates translated below the clock.

X4 and X4 Pro use the shared spaced page format; centered/custom status groups keep
their configured separator. X3's build flag is zero: preprocessing retains the exact
native page/percent formatting and excludes the new formatter header. The existing
99.5% firmware flash gate remains mandatory.

## Implementation and verification after approval

- Put pure formatting/layout/truncation logic in the plugin's logic directory and
  UI/lifecycle integration in its ko directory. No network, scans or background work.
- Add `shared/fixtures/status/format.json` and its registry entry; have Lua tests
  and an Xteink host test read it. Apply any Xteink preset format adjustment through
  Orbify's overlay, with no upstream contribution.
- Cover Unicode, empty chapter, narrow widths, unequal sides, percent boundaries,
  12/24-hour midnight/noon and unknown totals with Lua unit tests.
- Flow tests cover native state snapshot/restore, repeated toggles, book close,
  clock cleanup, zero reservation by default, text fitting, minimum opt-in CRE and paged reservation, and gesture
  delegation. Add partial dirty-region checks for minute/battery updates.
- Run plugin logic/flow suites and pinned KOReader compatibility checks. Run the
  affected Xteink host suite. CI is the merge gate; no device tools or release tags.
- One PR holds this design and implementation. Keep this outcome in ROADMAP until
  shipped; then move it into FEATURES in the same change. Real-device visual and
  gesture verification is for the user before a release.

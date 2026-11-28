# F40w compact X4 widgets — APPROVED (2026-11-28)

Status: **APPROVED (2026-11-28)** for every main view, state and optional larger view.
This replaces #241's large main cards with the maintainer's 0.11-density brief.
The proposed scope reduction was withdrawn: **X4 keeps exactly the 30 installed
Android 0.12 registry types, with no invented widget type**. Maintainer approval on 2026-11-28 (~00:45 PT): “I approve all the screens / widgets”.
Approval covers all 30 types, every state and optional size at this compact density.
This record changes no firmware, Android, pin, defaults or reader behavior.

[Review the replacement gallery](f40w-widgets.html). It starts with fully composed
Home, Library and Stats examples on X4 Pro and X4 Classic, followed by each
widget's smallest useful main view, Book list presets and clearly separate
optional larger views. X3 is outside this X4 design review; it remains off for
unapproved new widgets. Existing approved X3 and reader surfaces are untouched.

## Registry and renderer audit

BookSync source: `ee07eadb` on `feature/0.12`. The executable audit loads the real
[`logic/budgets.lua`](../../../android/koreader/orbit.koplugin/logic/budgets.lua),
[`logic/widget_registry.lua`](../../../android/koreader/orbit.koplugin/logic/widget_registry.lua),
[`ko/home_widgets.lua`](../../../android/koreader/orbit.koplugin/ko/home_widgets.lua),
[`ko/reading_stats.lua`](../../../android/koreader/orbit.koplugin/ko/reading_stats.lua),
[`ko/local_widgets.lua`](../../../android/koreader/orbit.koplugin/ko/local_widgets.lua)
and [`ko/clock.lua`](../../../android/koreader/orbit.koplugin/ko/clock.lua), without
invoking renders, and checks that every registered type has an installed renderer.
The resulting 30 IDs exactly match the gallery's registry inventory.

- **Achievements stays:** it is registered and rendered by LocalWidgets, including
  earned/total, latest/date, next/progress and source. Its main is a compact wide
  strip, not the former large trophy composition.
- **Library sources is not a widget:** no such registry ID or Home renderer exists.
  Source pickers remain part of Book list configuration; Library retains its own
  counts/storage and existing browse destinations. Authors, Series and On card
  are links/data inside Library, not invented independently installed types.
- **Finish forecast stays separate**, as Android registers it. Continue also keeps
  its existing time-left/finish fields; neither presentation is removed.
- Battery, Goal, Today, Pages, Monthly, Lists, Word, Light, Moon, Glyph, Buddy,
  Highlight, Year ago, Dust, controls and Next stop all stay because Android builds
  them. Whether they happened to appear in the two 0.11 photos does not change
  this corrected scope.
- Also reading, Recently added, Want to read, Finished, Pick back up, Up next,
  Finished this year, Unopened and On device are **Book list presets**, not extra
  widget IDs. All nine remain, along with custom/smart/list/author/series sources
  from [`logic/booklist.lua`](../../../android/koreader/orbit.koplugin/logic/booklist.lua).
  Their counts, ordering, year and opening-history meanings remain distinct.

## Density evidence and physical sizes

Both supplied 0.11 Home and Library photos were inspected locally. Only card
proportions, hierarchy and arrangement were used. The photos, greeting, personal
book/author data and observed counts are not committed or transcribed into the
mockups. Every mockup cover, title and value is invented.

The 0.11 BookSync reference is `origin/main` at `bf384383`, version
`0.11.3-rc.17`, with its pinned CrossInk source
`0695f2e1456e2cfcaa7218027f1b3b71050a8f7b`. Read directly at that immutable pin:

- [`BookOrbitHomeLayout.h:17`](https://github.com/agosez/CrossInk-Bookorbit/blob/0695f2e1456e2cfcaa7218027f1b3b71050a8f7b/src/components/themes/bookorbit/BookOrbitHomeLayout.h#L17): two columns, six rows, 12 px margins, 8 px gutters and 24 px header icons.
- [`BookOrbitHomeLayout.cpp`](https://github.com/agosez/CrossInk-Bookorbit/blob/0695f2e1456e2cfcaa7218027f1b3b71050a8f7b/src/components/themes/bookorbit/BookOrbitHomeLayout.cpp): hero and shelf geometry, cover slots, bounded also-reading rows and compact stats cells.
- [`BookOrbitHomeHomePage.cpp:185`](https://github.com/agosez/CrossInk-Bookorbit/blob/0695f2e1456e2cfcaa7218027f1b3b71050a8f7b/src/components/themes/bookorbit/BookOrbitHomeHomePage.cpp#L185): conditional account Goal versus local Finished; the reading page uses a hero and compact Streak/Week/Sync cells.
- [`BookOrbitHomeStatsPage.cpp`](https://github.com/agosez/CrossInk-Bookorbit/blob/0695f2e1456e2cfcaa7218027f1b3b71050a8f7b/src/components/themes/bookorbit/BookOrbitHomeStatsPage.cpp): dot/year history, time-of-day/weekday charts, Records/Activity, conditional Highlight/Next badge and a Finish by card.
- [`BookOrbitHomeLibraryPage.cpp`](https://github.com/agosez/CrossInk-Bookorbit/blob/0695f2e1456e2cfcaa7218027f1b3b71050a8f7b/src/components/themes/bookorbit/BookOrbitHomeLibraryPage.cpp): one-row shelves of four covers and small count/navigation tiles.

The old code confirms conditional Highlight, Next badge, Goal and Finish by
already exist on 0.11, despite not being visible in the supplied two photos.
Other previously suggested removals are not standalone 0.11 Home widgets. Battery
is visible in the status header; BookSync's battery-stats overlay adds a Settings
activity, not a Home widget. These findings are evidence only: the maintainer's
corrected Android-parity scope above supersedes the withdrawn 0.11-only filter.

The [firmware gallery](mockups.html) supplies the device frame, black/white style
and focus tokens. This gallery fixes a **480 × 800 design viewport**, 64 px header,
42 px footer, 12 px side margins and 8 px gutters. The remaining six rows are
108 px high. This recreates the photo density rather than scaling large cards
inside mostly empty screens.

| Proposed compact span | Actual main footprint | Meaning |
|---|---:|---|
| 1×1 | 224 × 108 px | Small half-width value, chart, pick or control tile. |
| 2×1 | 456 × 108 px | A wide compact chart, passage, record or multi-field strip. |
| 2×2 | 456 × 224 px | The hero, one four-cover shelf row, or three book rows. |

These are **proposed firmware review units**, not silent changes to Android's
size registry or F33 persisted layouts. Pixel footprints are authoritative here.
After approval, the firmware layout adapter must validate class spans, preserve
custom layouts/unknown records and use renderer dimensions at runtime. No user
layout is rewritten by this docs change. Larger cards below are optional only.

## Main-size inventory — exactly Android's installed types

All entries are **APPROVED (2026-11-28)** on both X4 profiles. The order is Continue /
Also reading / Recently added / Book list, Stats, then the rest; the first two
shelf/list presets appear next to Continue while remaining one Book list type.

| Widget ID | Widget | Main size | Main drawing |
|---|---|---|---|
| `continue-reading` | [Continue reading](f40w-widgets.html#continue-reading) | 2×2 · 456×224 px | One reverse hero, cover, saved position, Resume, time left and finish. |
| `booklist` | [Book list](f40w-widgets.html#booklist) | 2×2 · 456×224 px | Smart-scope example; three cover/progress rows and a header All count. |
| `this-week` | [This week](f40w-widgets.html#this-week) | 1×1 · 224×108 px | Big total and seven mini bars, current period emphasized. |
| `reading-streak` | [Reading streak](f40w-widgets.html#reading-streak) | 1×1 · 224×108 px | Large current streak, last-seven dots and small best-streak label. |
| `year-in-reading` | [Year in reading](f40w-widgets.html#year-in-reading) | 2×1 · 456×108 px | Dot heatmap with day/time summary; no quarter bars or rings. |
| `when-you-read` | [When you read](f40w-widgets.html#when-you-read) | 1×1 · 224×108 px | Peak time, after-18 share and mini 24-hour histogram. |
| `reading-records` | [Reading records](f40w-widgets.html#reading-records) | 2×1 · 456×108 px | Pages, longest session, best day, books and best streak in one strip. |
| `today` | [Today](f40w-widgets.html#today) | 1×1 · 224×108 px | Large known minutes and separate local/account availability. |
| `reading-goal` | [Reading goal](f40w-widgets.html#reading-goal) | 1×1 · 224×108 px | Account completed/target, mini fraction bar and pace/status. |
| `pages-read` | [Pages read](f40w-widgets.html#pages-read) | 1×1 · 224×108 px | Today/lifetime timed page visits; no unique-printed-page claim. |
| `monthly-reading` | [Monthly reading](f40w-widgets.html#monthly-reading) | 2×1 · 456×108 px | All twelve month bars/values, known total and previous month. |
| `finish-forecast` | [Finish forecast](f40w-widgets.html#finish-forecast) | 1×1 · 224×108 px | Large measured time left, finish date and current-book label. |
| `battery` | [Battery](f40w-widgets.html#battery) | 1×1 · 224×108 px | Battery level and usual-use estimate; rates/modes in optional larger view. |
| `library` | [Library](f40w-widgets.html#library) | 1×1 · 224×108 px | Library/on-card totals and a small storage bar; browse links in optional larger view. |
| `lists` | [Lists](f40w-widgets.html#lists) | 1×1 · 224×108 px | One named list and count with All in the header; larger list optional. |
| `recommended` | [Recommended for you](f40w-widgets.html#recommended) | 1×1 · 224×108 px | One cover/title pick with history-based source label. |
| `discover` | [Discover](f40w-widgets.html#discover) | 2×2 · 456×224 px | One row of four covers, Another icon and header All count. |
| `highlight` | [Highlight of the day](f40w-widgets.html#highlight) | 2×1 · 456×108 px | Bounded two-line excerpt and book/source attribution. |
| `yearago` | [A year ago](f40w-widgets.html#yearago) | 1×1 · 224×108 px | Saved book, minutes/days/stop position and historic date. |
| `word` | [Word of the day](f40w-widgets.html#word) | 1×1 · 224×108 px | Headword, bounded context/source and native lookup target. |
| `buddy` | [Reading buddy](f40w-widgets.html#buddy) | 1×1 · 224×108 px | Small original static reading-owl symbol and local message. |
| `dust` | [Gathering dust](f40w-widgets.html#dust) | 2×1 · 456×108 px | One local book/age/pool strip with Open and Next. |
| `achievements` | [Achievements](f40w-widgets.html#achievements) | 2×1 · 456×108 px | Earned/total, latest/date, next/progress and source in a wide strip. |
| `sync-controls` | [Sync now](f40w-widgets.html#sync-controls) | 1×1 · 224×108 px | Large saved-result age and Sync now; no Refresh substitution. |
| `reader-toggles` | [Quick controls](f40w-widgets.html#reader-toggles) | 2×1 · 456×108 px | One row of four native control targets, at least 50 px high. |
| `light` | [Light](f40w-widgets.html#light) | 1×1 · 224×108 px | Pro-only level, passive meter and 50 px −/+; Classic hardware reason. |
| `clock` | [Clock / date](f40w-widgets.html#clock) | 1×1 · 224×108 px | One combined digital time/date tile. |
| `moon` | [Moon phase](f40w-widgets.html#moon) | 1×1 · 224×108 px | Small crescent, phase, illumination and approximate next change. |
| `glyph` | [Glyph of the day](f40w-widgets.html#glyph) | 1×1 · 224×108 px | Actual-font sample, name/code point and source in a small tile. |
| `next-stop` | [Next stop](f40w-widgets.html#next-stop) | 2×1 · 456×108 px | Current → next → end with timing and remaining chapters. |

### Book list presets — same type and renderer

Every preset's main view is 2×2 (456 × 224 px). Also reading, On device and the
custom smart-scope example use three 54 px rows. Recently added, Want to read,
All finished, Pick back up, Up next in series, Finished in 2026 and Unopened use
one row of four covers. Their header count comes from the saved source, not four
preview items. Other registered source categories remain selectable without
becoming new widget types. No private source or display name is used here.

### Optional larger views

Only the end section shows larger examples: Battery, Library, Year in reading
and Lists at 2×2 (456 × 224 px). They add detail; they do not redefine the main
size. Main sizes remain useful before any resize. The larger Library view keeps
Authors / Series / Collections reachable; those destinations also remain in the
existing browse surface. Larger context/source text is optional, not another ID.

## One header-link rule

Every existing list/shelf All link reads **All (n) ›** and sits at the top-right
of that widget's header. There is no bottom “See all”, bottom All, or count inferred
from the visible window. Also reading, Book list, Lists and every shelf preset
share this rule. Discover's Another shuffle target sits immediately to the left
of its All link; each has its own 50 px target, without overlapping covers.
Small count/control cards need no invented All link when Android supplies none.

Touch targets are at least 50 px where actions are drawn. Cover targets are larger;
book rows are 54 px. Classic uses Previous/Next/Select and visible focus with the
same geometry. Charts and summary-only widgets remain read-only. A browser drawing
does not prove native font or touch fit: device acceptance remains required.

## Scope and presentation differences from Android

- The registry set is identical. Dedicated Library sources, Authors, Series,
  On-card and Finished are not added as independent widget types; their existing
  Library links and Book list configurations remain. No Android widget or preset
  is dropped by this revision.
- The main pixel allocations are firmware-specific, deliberately much smaller than
  #241 and many Android tablet spans. Black/white fills, dot/mini-chart evidence,
  compact typography and one digital Clock/date replace oversized showcase views.
  The photo's personal greeting and content are never copied.
- Continue and Book list retain covers. Recently added and shelf presets show four
  covers as on 0.11. The requested four-cover Discover drawing requires a bounded
  firmware projection of four ready-to-draw books; Android's current one-book
  personal-pick budget is **not changed by this docs PR**. Before implementing it,
  review the explicit four-row Library projection/budget in the provider slice,
  charge every cover/book row and test the cap. Never issue four extra UI reads,
  manufacture preview books or conceal records inside one budget row. Recommended
  remains a one-book pick. All other per-kind budgets remain binding.
- Light is supported only on Pro. Classic keeps its named card/reason and cannot
  dispatch a frontlight intent. X3 is not added or implicitly approved here.

## State strips and implementation gates

Each registered type has one compact strip: empty/not-saved, off, unsupported,
stale and oversize. Known zero differs from absence. Off retains layout without
fabricating an empty history; on Pro Light it means zero intensity, while Classic's
hardware reason always wins. Stale retains the actual widget and adds an age label;
it neither connects nor claims a successful sync. Oversize refuses the offending
payload with Retry and leaves siblings usable. Provider/source errors stay neutral.

Everything remains behind Library values/intents. One F34 visible-page batch,
provider-owned source precedence/ranking/formatting and SyncOwner as sole writer.
No filesystem, decode, parsing, network, scan or allocation work in paint. Covers
are prepared after paint through the existing bounded cover service. No new store,
backend route, direct hardware client or native reader policy is introduced.

Each future F40w widget still needs its own provider projection then renderer,
independent known/complete-empty/not-saved/off/unsupported/stale/oversize tests,
geometry/focus/sibling-isolation and stale-delivery/account checks. Word needs its
bounded lookup-capture seam before projection. Account goals never substitute a
local count, and unknown days never turn into zero. These compact scenes are approved; implementation still requires the listed
provider, renderer, boundary, resource and test gates.

Implementation PRs must run the appropriate host/simulator suites, actual Pro,
Classic and C3 builds and the unchanged 131,072-byte free-slot gate. Report image,
map/static-RAM deltas and bounded allocation peaks. No build size, internal heap,
stack watermark or physical contrast measurement is claimed by these mockups.
Maintainer-only hardware acceptance checks the compact cards offline, header-link
focus, native actions and unchanged open/close/resume place. Test Pro frontlight
physically; Classic emits no light intent. Agents do not access devices/serial.
No cache-format change or cache reset is needed for this docs work.

## Documentation verification

The executable Android inventory has 30 IDs and 30 installed renderers. The gallery
has the same 30 registry articles, 60 Pro/Classic main views, nine Book list preset
examples (18 views), three composed page examples (six views) and four optional
larger examples (eight views). Each registry type has five shared state cells
(150 total). No extra registry ID is inferred from a preset or a browse link.

Browser QA checks fixed pixel footprints, six-row page containment, clipped cover
content, horizontal overflow, 50 px action/header targets, header All placement,
unique IDs, links and Classic frontlight truth at 1440, 1200 and 390 px widths.
There are 128 rendered cards, 150 state cells and 34 header All links per viewport:
384 card checks, 450 state checks and 102 header-link checks. Review the composed
pages and every main card visually. Product-name tests pass (8); feature-reference tests pass (4). Local links,
unique IDs, registry parity, action targets and header placement pass; no page
errors, clipping or overflow remain. All 30 main designs and the composed pages
were visually reviewed. These are docs checks, not firmware/device acceptance.

Reproduce the Android registry/renderer side of the audit from the repository root:

```sh
luajit - <<'LUA'
local p = "android/koreader/orbit.koplugin/"
for _, f in ipairs({"logic/budgets.lua", "logic/widget_registry.lua",
    "ko/home_widgets.lua", "ko/reading_stats.lua", "ko/local_widgets.lua", "ko/clock.lua"}) do
    dofile(p .. f)
end
local ids = {}
for id in pairs(WidgetRegistry) do
    assert(HomeWidgets.renderers[id], id .. " has no installed renderer")
    ids[#ids + 1] = id
end
table.sort(ids)
assert(#ids == 30)
for _, id in ipairs(ids) do print(id) end
LUA
```

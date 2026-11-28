# F40w firmware widgets — NEEDS APPROVAL

Status: **NEEDS APPROVAL**. This proposal adds missing firmware presentations;
it does not approve itself, install widgets, change default layouts or bump the
firmware pin. Existing Home revision-16 and B1–B5 approvals remain unchanged.

[Review the gallery](f40w-widgets.html). Every widget has known, empty/not-saved,
off, unsupported, stale and oversize previews on X4 Pro, X4 Classic and X3.
Each proposed size can be selected independently. Deep links encode widget,
state and size, for example `#also-reading/known/1×2`. Synthetic values only.
The 480 × 800 design viewport follows the approved firmware gallery; it does
not claim physical font fit, measured memory or hardware acceptance.

## Approval audit and stopping point

The audit used BookSync integration `552d04b5` and firmware `75033369`.
The plan's F40w row requires an approved widget scene and X3 text action.
Home `DESIGN.md:166`–`212` defines content semantics and `:403`–`436` gives
example spans. Those paragraphs do not draw the missing per-profile states.
Home `prototype.html:674`–`678` has Book list presets; `:948`–`1038` draws
Week, Year, Hours and Records on X4. `:1146`–`1151` draws Recommended as
“Coming later” and Highlight, Buddy, Discover, Year ago, Word and Light as
“Later release · optional”. These placeholders are not approved ready cards.
The Home screenshot gallery has no X3 Home widget scene. Firmware `SCREENS.md`
covers B1–B5 and F35a's X3 editor, not this state matrix. B4 frontlight Settings
approval does not by itself approve a Home frontlight widget.

Consequently no additional widget has a complete approved three-profile
presentation for this series' acceptance states. Firmware implementation stops
here. The proposed order below starts with PLAN's F40w sequence; once approved,
use actual approved scene order, one widget per small firmware PR, provider
projection before renderer, at most six widgets in a series. This docs PR bundles
only approval gaps. Book list, Lists, Library and Battery are included because
Android's registry ships them; existing F34 behavior is not reimplemented here.

## Proposed scene inventory

All entries and sizes below are **NEEDS APPROVAL** on all three firmware
profiles. Existing known X4 examples remain approved independently. Every link
opens the known preview; the state and size controls expose the remaining gaps.
Spans are proposals drawn from Home design and the Android registry, not a
promise to copy Android geometry or expand the firmware registry automatically.

| ID | Widget | Proposed firmware spans | Projection / acceptance meaning |
|---|---|---|---|
| `also-reading` | [Also reading](f40w-widgets.html#also-reading/known/1×2) | 1×2, 2×2 | Saved in-progress selection; local finish/Undo overlay. |
| `streak` | [Reading streak](f40w-widgets.html#streak/known/1×2) | 1×2, 2×2 | F39 day buckets, timezone and coverage; ? is unknown. |
| `week` | [This week](f40w-widgets.html#week/known/1×2) | 1×2, 2×2, 2×1 | F39 day buckets and source watermark. |
| `today` | [Today](f40w-widgets.html#today/known/1×2) | 1×2, 2×2 | F39 known local daily total; account coverage separate. |
| `goal` | [Reading goal](f40w-widgets.html#goal/known/2×2) | 2×2 | Saved account goal only; never substitute a device count. |
| `buddy` | [Reading buddy](f40w-widgets.html#buddy/known/2×1) | 2×1, 2×2 | Local reading activity only; deterministic static message. |
| `highlight` | [Highlight of the day](f40w-widgets.html#highlight/known/2×1) | 2×1, 2×2 | F39 authorized saved passage, source and book identity. |
| `discover` | [Discover (random)](f40w-widgets.html#discover/known/2×1) | 2×1, 2×2 | F39 daily deterministic unread selection; persisted Another offset. |
| `recently-added` | [Recently added](f40w-widgets.html#recently-added/known/1×2) | 1×2, 2×2, 2×3 | Canonical saved added order and completeness; Shelf variant. |
| `year` | [Year in reading](f40w-widgets.html#year/known/2×3) | 2×3, 2×4 | F39 calendar buckets; absent days remain unknown. |
| `forecast` | [Finish forecast](f40w-widgets.html#forecast/known/2×2) | 2×2 | Measured pace and known native locator; no guessed account pace. |
| `hours` | [When you read](f40w-widgets.html#hours/known/1×2) | 1×2, 2×1, 2×2 | Worker session histogram with time-zone and coverage evidence. |
| `records` | [Reading records](f40w-widgets.html#records/known/2×2) | 2×2, 2×3 | F39 available aggregates; unknown record remains labelled. |
| `year-ago` | [A year ago](f40w-widgets.html#year-ago/known/2×1) | 2×1, 2×2 | F39 saved anniversary book/minutes/days/stop locator. |
| `finished-in-year` | [Finished in 2026](f40w-widgets.html#finished-in-year/known/1×2) | 1×2, 2×2, 2×3 | Year-specific finishedOn selection; capped preview is not complete count. |
| `word` | [Word of the day](f40w-widgets.html#word/known/2×1) | 2×1, 2×2 | Bounded native lookup capture required before projection. |
| `pick-back-up` | [Pick back up](f40w-widgets.html#pick-back-up/known/1×2) | 1×2, 2×2, 2×3 | Saved in-progress books in older-last-read order; Shelf variant. |
| `recommended` | [Recommended for you](f40w-widgets.html#recommended/known/2×2) | 2×2 | F39 provider-ranked saved pick; distinct from random Discover. |
| `sources` | [Library sources](f40w-widgets.html#sources/known/2×2) | 2×2, 2×3 | Opaque saved source labels/counts; incomplete total stays unknown. |
| `sync` | [Sync now](f40w-widgets.html#sync/known/2×2) | 2×2 | Sole SyncOwner result/freshness; distinct from catalog Refresh. |
| `toggles` | [Quick controls](f40w-widgets.html#toggles/known/2×2) | 2×2 | Library intents for Wi-Fi/Night/Rotate/Sync; capability-gated controls. |
| `light` | [Light](f40w-widgets.html#light/known/2×1) | 2×1, 2×2 | Hardware frontlight snapshot; Pro only, never invent Classic/X3 support. |
| `clock` | [Clock](f40w-widgets.html#clock/known/1×1) | 1×1, 1×2, 2×1, 2×2 | Local established/approximate/unknown time and 12/24-hour choice. |
| `moon` | [Moon phase](f40w-widgets.html#moon/known/1×2) | 1×2, 2×2 | Local date-derived phase; sample values are illustrative. |
| `pages-turned` | [Pages turned](f40w-widgets.html#pages-turned/known/2×2) | 2×2 | Native counters and coverage; page visits are not unique printed pages. |
| `glyph` | [Glyph of the day](f40w-widgets.html#glyph/known/1×2) | 1×2, 2×2 | Available local font sample only; no font download. |
| `monthly-rings` | [Monthly reading](f40w-widgets.html#monthly-rings/known/2×3) | 2×3 | All 12 F39 month totals; ? denotes unknown month. |
| `next-stop` | [Next stop](f40w-widgets.html#next-stop/known/2×2) | 2×2 | Captured TOC/locator and measured pace; no reader call during paint. |
| `achievements` | [Achievements](f40w-widgets.html#achievements/known/2×2) | 2×2 | Authorized saved summary; off and unsupported differ from zero earned. |
| `battery` | [Battery](f40w-widgets.html#battery/known/1×1) | 1×1, 1×2, 2×1, 2×2, 2×3 | F43 hardware level and bounded history; no invented time-left estimate. |
| `booklist` | [Book list](f40w-widgets.html#booklist/known/1×2) | 1×2, 1×3, 2×1, 2×2, 2×3, 2×4 | F34 Shelf; per-source rank, completeness and independent acceptance. |
| `lists` | [Lists](f40w-widgets.html#lists/known/1×2) | 1×2, 1×3, 2×2, 2×3 | Opaque saved list keys; no client evaluation of rules. |
| `library` | [Library](f40w-widgets.html#library/known/1×1) | 1×1, 1×2, 2×1, 2×2, 2×3 | F34 Browse plus worker storage summary; no visible-window fake total. |

## State and action rules proposed for review

- Known: render only immutable Library values. Known zero remains a real zero;
  an absent day, source total, clock or pace remains unknown. Account and device
  reading totals stay separate unless F39 reconciles their watermarks.
- Empty/not-saved: the gallery illustrates a named absence. Implementation needs
  separate complete-empty and not-saved fixtures, with the correct source copy;
  no automatic fetch and no invented zero. Off has its own copy and Settings
  action, never masquerading as empty. The disabled-source preview applies only
  where the service actually supports disabling; otherwise off is a hidden
  widget preserved in layout and tested as producing no query or paint.
- Unsupported: show the source/hardware reason and Back. Light is supported only
  on X4 Pro. X4 Classic and X3 show “This reader has no frontlight” in every
  selector state and cannot emit frontlight intents. Light Off on Pro means
  intensity zero and offers Turn on; a disabled widget is separately hidden.
- Stale: retain the saved payload and disclose source freshness. Stale does not
  claim a successful sync, require a connection or hide local state. Open actions
  still validate identity and capability through Library.
- Oversize: refuse the offending payload within the widget budget, show Retry,
  preserve siblings, and never truncate a book key or execute partial text.
  The displayed error is fixed copy, not a rendering of oversized input.
- X3: bounded text, Previous/Next focus, Select dispatch and Back to Home. No art,
  touch controls or hidden hardware capability. Pro/Classic show the same values;
  small cards omit preview rows rather than alter totals. Week/Hours bars have
  textual values; a hatched unknown bucket is not zero.
- Actions shown as Reading history, Goal, Sources, Achievements, Battery details,
  Contents or Settings reuse only an approved destination backed by Library. If
  that destination or intent is absent, its renderer remains blocked; this
  gallery does not approve new panels, create settings or activate live sync.
  Word first needs bounded lookup capture. Light needs the actual F43 capability
  and intent seam. Discover's Another selection belongs to the service.

## Implementation evidence still required after approval

Each widget gets independent production-code provider and renderer fixtures for
known, complete empty, not saved, off/hidden, unsupported, stale and oversize.
Include sibling isolation, each listed span, account changes, canceled/stale
results, exact book actions and zero filesystem/network/allocation work in paint.
Use one F34 visible-page batch through Library; providers remain outside UI.
No adapter-specific data enters a widget and SyncOwner remains the only writer.

Run each scene in `x4-pro-simulator`, `x4-classic-simulator` and `simulator-X3`,
with synthetic storage and fake transport. Record exact scene links, captures,
bounded allocation peaks and available process measurements. Simulator heap is
not ESP32 internal heap, largest-block or task-stack acceptance.

For every implementation PR, build `x4-pro`, `x4-classic` and `default` locally;
record actual image bytes, ELF/map and static-RAM deltas against its rebased main.
Require `6,553,600 - image bytes >= 131,072` on every device and a green required
BookSync firmware check before squash merge. This docs-only PR changes no image;
no hardware build or firmware size is represented as measured here.

Maintainer-only hardware verification after implementation: open Home offline on
each device, add the approved widget, exercise its supported sizes and actions,
then open/close an EPUB and confirm position and reader behavior are unchanged.
Pro Light must change the physical frontlight; Classic/X3 must offer no light
intent. Inspect internal free/largest RAM and task stack watermarks. No cache
format is changed by these mockups and no cache reset is requested. Agents never
access devices or serial ports.

## Documentation validation

Browser QA exercised all 33 entries, six selector states and 76 size choices:
1,368 profile/state/size combinations at each of 1440 px and 390 px viewport
widths (2,736 rendered view checks). No content clipping, horizontal overflow,
page errors or false frontlight actions on Classic/X3 remained. Light Off,
Streak narrow and Word stale views were visually inspected. Local documentation
links resolve. Product-name tests pass (8), and feature-reference tests pass (4).
These checks validate the proposal gallery only; there are zero new firmware
host tests or simulator scenarios and no application-image measurement.

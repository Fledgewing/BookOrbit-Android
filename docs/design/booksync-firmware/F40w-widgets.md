# F40w firmware widget designs — NEEDS APPROVAL

Status: **NEEDS APPROVAL** for every scene and state. This follow-up replaces
PR #230's generic text cards with widget-specific drawings. Merging design work
is not maintainer approval and does not enable firmware widgets or change the pin.
Existing Home revision-16 and B1–B5 approvals remain unchanged.

[Review the replacement gallery](f40w-widgets.html). It contains **38 widget and
shelf designs, 114 main device views, and 190 compact state cells**. Main views
use X4 Pro touch, X4 Classic buttons and X3 text. Each widget has one state strip
for empty, off, unsupported, stale and oversize, shared across the three profiles
with hardware exceptions written explicitly. Previous widget/state/size deep links
still scroll to that widget; the replacement uses simple widget anchors.

## Visual basis and reading order

Audited BookSync source: `74b3ff7e` on `feature/0.12`.
The [revision-16 screenshot gallery](../booksync-home/mockups.html), especially
`m8c-home-1`, `m8c-home-2`, `x4pro-home-1` and `x4pro-home-2`, supplies the
cover/row hierarchy, reverse Continue card, reading charts, storage bar and
large-number composition. The [firmware gallery](mockups.html) supplies the
480 × 800 design viewport, device frame, serif/sans typography, outlined actions,
Classic focus and X3 square text presentation. Main size labels live in review
captions, never inside the drawn firmware screen. No debug row or filler card
appears beneath a widget.

Ordering follows the coordinator's Android 0.11 usage priority: Continue / Also
reading, Recently added, Book list, Stats, then Library, Personal, Controls/time.
This is the supplied editorial priority, not measured usage telemetry. Continue
and the retained Want to read / Up next / Unopened / Gathering dust presentations
join the original 33 entries so the visual inventory includes the current Android
registry and meaningful Book list variants. This does not add installed firmware
widgets or change defaults.

Android implementation evidence (paths are in this BookSync repository):

| Family | Source read before drawing | Preserved visual / semantic role |
|---|---|---|
| Continue, Book list, Also reading, shelves, Lists | [`ko/home_widgets.lua:93`](../../../android/koreader/orbit.koplugin/ko/home_widgets.lua#L93), hero `:127`, shelf `:148`, rows `:170` | Reverse hero, covers, one solid progress bar, row metadata, distinct shelf captions and list counts. |
| Week, Year, Hours, Records | [`logic/reading_stats.lua:89`](../../../android/koreader/orbit.koplugin/logic/reading_stats.lua#L89), week `:119`, hours `:140`; [`ko/reading_stats.lua`](../../../android/koreader/orbit.koplugin/ko/reading_stats.lua) | Calendar, seven daily bars, 24-hour histogram, large record and metric grid. |
| Today, Streak, Goal, Pages, Monthly | [`logic/reading_stats.lua:18`](../../../android/koreader/orbit.koplugin/logic/reading_stats.lua#L18) | Daily emphasis, seven-day evidence, goal fraction/pace, today/lifetime split and twelve monthly totals. |
| Battery | [`ko/battery.lua:9`](../../../android/koreader/orbit.koplugin/ko/battery.lua#L9) | Battery level glyph, estimate, reading/standby rates and details destination. |
| Library/storage | [`ko/storage.lua:32`](../../../android/koreader/orbit.koplugin/ko/storage.lua#L32) | Separate account/device totals, patterned capacity bar and browse links. |
| Highlight, Year ago, Recommended, Discover | [`ko/local_widgets.lua:12`](../../../android/koreader/orbit.koplugin/ko/local_widgets.lua#L12) | Passage/source, anniversary summary, history-based pick versus random unread pick, Open/Another. |
| Word, Buddy, Light, Moon, Glyph, Next stop, Dust, controls | [`ko/local_widgets.lua:43`](../../../android/koreader/orbit.koplugin/ko/local_widgets.lua#L43); [`logic/local_widgets.lua`](../../../android/koreader/orbit.koplugin/logic/local_widgets.lua) | Captured local context, static reading message, hardware capability, local phase/font sample, chapter timing, pool provenance and existing controls. |
| Clock | [`ko/clock.lua:4`](../../../android/koreader/orbit.koplugin/ko/clock.lua#L4); [prototype `W.clock`](../booksync-home/prototype.html) | Large time/date, seven-day date strip and Battery link. |
| Forecast | [`ko/home_widgets.lua:223`](../../../android/koreader/orbit.koplugin/ko/home_widgets.lua#L223) | Current book, measured time remaining and finish date; no guessed pace. |
| Achievements | [Home DESIGN §3.1](../booksync-home/DESIGN.md#31-preset-tile--owned-content-mapping) | Earned/total/latest/next/progress contract; no installed Android renderer to copy. |

The HTML/SVG illustrations and synthetic covers are independently drawn for this
proposal. No upstream sprite, font asset, cover image or pose code is copied.
Reading values are independent invented snapshots for each composition, not one
shared Home publication or measurements from a device. Synthetic cover lettering
avoids personal credits; production cards keep the saved author/source metadata.
The year example's 257 known reading days, quarter totals, nine unknown dates and
future blank cells agree; the week total includes only its six known days.

## Main-size scene inventory

Every row and all three profile views are **NEEDS APPROVAL**. A main size is a
reviewed composition, not approval of all registry spans. Later alternate sizes
need their own fit review. Also reading and Lists explicitly use X3 class overrides of 2×2 and 2×3,
respectively, for the full text column. They do not inherit a spatial editor
or touch target. Battery uses a 2×3 main view to retain its full estimate block.

| Priority | Widget | Main size | Visual treatment |
|---|---|---|---|
| 01 | [Continue reading](f40w-widgets.html#continue-reading) | 2×2 | Reverse cover hero; X3 chapter, large percentage and resume ledger. |
| 02 | [Also reading](f40w-widgets.html#also-reading) | X4 1×2; X3 2×2 | Two cover/progress rows; X3 numbered progress rows. |
| 03 | [Recently added](f40w-widgets.html#recently-added) | 2×2 | Three covers with added-date captions; X3 dated title rows. |
| 04 | [Book list](f40w-widgets.html#booklist) | 2×3 | Cover stamps, position bars and reading metadata; X3 ruled title rows. |
| 05 | [This week](f40w-widgets.html#week) | 2×2 | Seven daily bars; X3 two-column day/minute ledger. |
| 06 | [Year in reading](f40w-widgets.html#year) | 2×3 | 365-day calendar plus quarter bars; X3 quarter/day ledger and annual metrics. |
| 07 | [When you read](f40w-widgets.html#hours) | 2×2 | 24-hour histogram with peak emphasis; X3 four labelled time bands. |
| 08 | [Reading records](f40w-widgets.html#records) | 2×3 | Large lifetime page figure and four-metric record grid. |
| 09 | [Reading streak](f40w-widgets.html#streak) | 2×2 | Current/best hierarchy and seven day rings; X3 last-seven-day ledger. |
| 10 | [Today](f40w-widgets.html#today) | 2×2 | Oversized daily minutes, date masthead and separate device/account totals. |
| 11 | [Reading goal](f40w-widgets.html#goal) | 2×2 | Completed/target emphasis, solid fraction bar, remaining/required pace. |
| 12 | [Finish forecast](f40w-widgets.html#forecast) | 2×2 | Current title, large time left, position bar and finish-date ledger. |
| 13 | [Monthly reading](f40w-widgets.html#monthly-rings) | 2×3 | Twelve monthly bars; X3 twelve labelled values in two columns. |
| 14 | [Pages read](f40w-widgets.html#pages-turned) | 2×2 | Monospaced daily odometer and separate lifetime count. |
| 15 | [Battery](f40w-widgets.html#battery) | 2×3 | Level glyph, usual/reading/standby estimates, two rates and weekly use. |
| 16 | [Lists](f40w-widgets.html#lists) | X4 1×3; X3 2×3 | Icon/name/count rows; X3 full-width ruled list. |
| 17 | [Library](f40w-widgets.html#library) | 2×2 | Account/device headline totals, patterned storage bar and browse rows. |
| 18 | [Want to read](f40w-widgets.html#want-to-read) | 2×2 | Cover shelf with saved-pick captions; X3 saved-title list. |
| 19 | [Pick back up](f40w-widgets.html#pick-back-up) | 2×2 | Cover shelf with older-last-read captions; X3 dated progress list. |
| 20 | [Up next in series](f40w-widgets.html#up-next) | 2×2 | Series-number cover shelf; X3 numbered reading order. |
| 21 | [Finished in 2026](f40w-widgets.html#finished-in-year) | 2×2 | Year-specific finished shelf and year control; X3 dated finishes. |
| 22 | [Unopened](f40w-widgets.html#unopened) | 2×2 | Local cover shelf with opening-record disclosure; X3 title ledger. |
| 23 | [Recommended for you](f40w-widgets.html#recommended) | 2×2 | One cover-led history-based pick; X3 typographic recommendation. |
| 24 | [Discover](f40w-widgets.html#discover) | 2×2 | One cover-led daily unread pick with Open/Another; X3 title/actions. |
| 25 | [Library sources](f40w-widgets.html#sources) | 2×2 | Numbered source rows, independent counts and missing-source label. |
| 26 | [Highlight of the day](f40w-widgets.html#highlight) | 2×2 | Oversized quotation mark, passage, attribution and book action. |
| 27 | [A year ago](f40w-widgets.html#year-ago) | 2×2 | Calendar date block, book title, reading metrics and stop position. |
| 28 | [Word of the day](f40w-widgets.html#word) | 2×2 | Large dictionary headword, context quotation and lookup action. |
| 29 | [Reading buddy](f40w-widgets.html#buddy) | 2×1 | Original static reading owl and message; X3 message-led composition. |
| 30 | [Gathering dust](f40w-widgets.html#dust) | 2×2 | Age-led local cover pick, pool count/size and Open/Next. |
| 31 | [Achievements](f40w-widgets.html#achievements) | 2×2 | Trophy, earned/total, latest award and next-threshold bar. |
| 32 | [Sync now](f40w-widgets.html#sync) | 2×2 | Result seal, per-kind saved-work ledger and Sync action. |
| 33 | [Quick controls](f40w-widgets.html#toggles) | 2×2 | Four controls in a 2×2 matrix; X3 labelled square control rows. |
| 34 | [Light](f40w-widgets.html#light) | 2×1 | Bulb, level, non-draggable indicator and decrease/increase on Pro only. |
| 35 | [Clock](f40w-widgets.html#clock) | 2×2 | Large analog/digital pair; X3 large digital date/calendar composition. |
| 36 | [Moon phase](f40w-widgets.html#moon) | 2×2 | Lit-side crescent drawing with phase/illumination; X3 phase typography. |
| 37 | [Glyph of the day](f40w-widgets.html#glyph) | 2×2 | Large actual-font sample, name, code point and source baseline. |
| 38 | [Next stop](f40w-widgets.html#next-stop) | 2×2 | Current/next/end chapter route with time-to-next and remaining count. |

## Differences from Android and reasons

The following are deliberate **proposals**, not claims that an Android drawing
or firmware change has already been approved. Everything remains NEEDS APPROVAL.

| Widgets / profile | Difference | Why |
|---|---|---|
| Every widget, Pro / Classic | Strict black/white fills, outlines and pattern distinctions; firmware frame, action/focus and serif/sans tokens. | E-ink legibility and consistency with the approved firmware gallery; no reliance on Android's gray intensity levels. |
| Every widget, Classic | Previous/Next/Select and visible card/action focus replace touch affordances. | Button-only input; no gesture or keyboard assumption. Read-only charts stay read-only. |
| Every widget, X3 | Purpose-built text hierarchy, ruled ledgers and numbered rows. Covers/complex charts/analog dial/owl/trophy are omitted; numbers, source, uncertainty and supported actions remain. Glyph keeps its actual sample because that is its content. | Text-first constrained profile, with meaningful layouts rather than a universal title/body/button card. X3 Continue uses a white resume ledger instead of the reversed hero. |
| Reading streak, Pro / Classic | Seven labelled rings instead of the Android metric renderer's rectangular day strip. | Coordinator requested bar/ring evidence; rings distinguish known zero from an unknown day while keeping current/best prominent. |
| Year in reading, Pro / Classic | Calendar retained; compact quarter bars added and future days left blank. X3 shows the same quarter counts in a ledger. | Make annual growth legible at firmware width while preserving the Android calendar and unknown-date distinction. |
| Clock, Pro / Classic | Large analog face added beside digital time. X3 keeps the large digital time. Battery link and seven-day date strip remain. | Requested clock-face presentation; no second clock data source or refresh timer. |
| Moon, Pro / Classic | Original lit-side crescent drawing beside the existing phase/illumination/next-change fields; Android's local renderer is text-only. | Requested visual phase; label remains approximate and date-dependent. |
| Forecast, every profile | Solid position bar added below measured time left. | Requested progress treatment, using the same known book position; no new forecast calculation. |
| Buddy, Pro / Classic | Original static reading-owl illustration; Android currently renders the local message as text. | Give the optional buddy an identity without animation or copied sprite/pose code. X3 remains message-led. |
| Recommended, Discover, Gathering dust, Pro / Classic | A cover is added to the local renderer's text pick. | Carry the approved Home book-card recognition pattern into pick widgets. Missing covers still need a typographic fallback. |
| Word, every profile | Main view uses 2×2 instead of the current X4 registry's compact 2×1; larger headword and context block. | Preserve word/context/source/lookup together; adapts the Android tablet's 2×2 family. No alternate-size approval is implied. |
| Today and Pages read, every profile | Today gains a date masthead; Pages uses a daily odometer above the separate lifetime total instead of Android’s side-by-side numbers. | Give daily reading and lifetime visits distinct visual hierarchy while retaining the Android fields and coverage labels. |
| Library sources, every profile | Dedicated numbered Home source card adapted from Android’s source picker; Android has no separate installed widget renderer for this ID. | Keep PLAN’s retained source content reviewable without claiming an existing Android card. |
| A year ago, every profile | Calendar-style date block and separate minutes/days columns replace the Android plain summary lines. | Keep the original date/book/summary/stop-position content readable at a glance. |
| Next stop, every profile | A chapter route links current, next and end instead of Android's stacked text lines. | Make the relationship between the existing chapter and timing fields visible. No native engine call is added. |
| Sync, every profile | Result seal and per-kind saved-work ledger replace plain result/age lines. | Distinguish a saved result from waiting local work; still one SyncOwner action, distinct from Refresh. |
| Light, Pro | A bulb and non-draggable level indicator supplement the two existing decrease/increase actions. Classic/X3 show the hardware reason with no controls. | Recognizable device control without inventing slider dragging, brightness support or a light on unsupported hardware. |
| Achievements, every profile | Original trophy/latest/next composition, with a text counterpart on X3. | Android has no installed renderer for this retained contract. This is explicitly a new proposal, not an approved Android port. |

Book list and shelf variants preserve their separate source, rank and caption
meanings. Counts belong to the full saved source, never the visible preview.
Battery's illustrative estimates/rates may be shown only with sufficient measured
coverage; missing rates remain unknown. The gallery does not enable a provider.

## Compact state strips and boundaries

Each widget has exactly one five-cell strip below its three device views. Empty
has widget-specific copy; not-saved remains a separate implementation fixture.
Off means a hidden layout instance with no query/paint unless a real provider has
an off state. For Pro Light, off means level zero with Turn on available; for
Classic/X3, the hardware reason takes precedence in every state. Achievements off
never means zero earned. Stale retains the widget's own drawing and adds a saved-age
badge, without connecting. Oversize refuses that payload and offers Retry while
siblings remain usable. Unsupported retains the name, concrete reason and Back.
The shared strip is an approval aid, not an extra full-screen widget or new flow.

Only Library values and intents may reach the future UI. Provider precedence,
ranking, cover acquisition, stats, clock/date, hardware truth and persistence stay
behind that interface. One visible F34 batch; one SyncOwner writer. No parsing,
scan, filesystem, allocation or network work during paint. Actions reuse only
approved destinations; this document does not approve any new panel or setting.

After scene approval each widget still needs independent provider/renderer tests
for known, complete-empty, not-saved, off, unsupported, stale and oversize, all
supported sizes, sibling isolation, stale deliveries and account changes. Run the
three simulator profiles and actual device builds, report images/maps/static RAM
and the 128 KiB reserve. Simulator results cannot replace hardware heap/stack or
font/contrast acceptance. Word still needs bounded lookup capture; Light needs
the device capability and supported intent. Nothing changes the reader.

Maintainer-only hardware acceptance after implementation: open Home offline on
Pro, Classic and X3, inspect card/action focus and typography, exercise supported
actions, open/close a book and confirm unchanged saved place. Check Pro frontlight
physically; Classic/X3 emit no light intent. No devices or serial ports are used
for this docs work, and no cache reset is needed.

## Documentation validation

The replacement has 38 distinct main designs × three profiles (114 views), plus
38 compact five-state strips (190 cells). Browser layout checks cover 1440 px,
1200 px and 390 px widths: 342 main-view checks and 570 state-cell checks.
Check screen/card containment, clipped cover content, horizontal overflow,
internal links, page errors and Classic/X3 frontlight truth. Visual review covers
all main designs and representative desktop/mobile crops. Product-name tests pass (8); feature-reference tests pass (4). Local link,
unique-anchor, state-count and removed-debug/filler checks pass. These are documentation checks, not
new firmware host/simulator tests or physical-device acceptance.

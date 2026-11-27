# BookSync Android 0.12 owned reader navigation

Implements the approved DESIGN §13 Android reader-only seams. No KOReader core
patch, firmware or pin changes. These are feature-branch sources, without release
or physical-reader acceptance.

Menu hooks belong to one live ReaderUI instance and only intercept native default
tap/swipe/menu-key entry points. Native menu builders stay unchanged, including
invisible construction for menu search. A scoped bypass opens the current native
top/config menu and its real registered plugin items. Closing a document, disabling
BookSync menus or closing the plugin restores only hooks still owned by BookSync;
a later third-party wrapper/custom gesture is preserved. Missing/foreign hooks
leave native menus usable. Existing native containers close through their native
close paths before an owned sheet opens.

Reading settings has the approved BookSync reading menus switch. The stored
`clean_menus` flag enables interception only when true; explicit Tools entries
remain usable. The separate add-on recommendation outcome owns its untouched-only
setup application and conflict review. This change does not silently take over a
customized reader.

Contents and combined bookmarks/highlights use at most eight cached native entries
per window (one summary plus eight rows, 16 KiB). No TOC load, annotation scan,
sidecar parse or sort happens in paint. Hierarchy, native printed/hidden-flow page
labels, original document locators, bookmark/highlight distinctions and navigation
history stay native. Token, document, list and row-identity guards reject stale
selection. Native Contents settings and annotation editing/notes/highlight/dictionary
paths remain explicit escape actions; BookSync adds no second annotation writer.

The basic Go to form validates page and percent boundaries and retains printed
page labels. Relative/pinned/non-linear syntax stays in Native page/flow options.
Merely opening or dismissing a menu does not change position or typesetting.

Owned query/results wrap the native document search in Trapper's cancelable
subprocess. Literal, case-insensitive search uses the native default flags and caps
matches at 128. The worker bounds retained context, boxes and the private result
envelope at 256 KiB before serialization. Results expose only a bounded visible
window; locators remain exact. Match selection uses native navigation/highlight
operations and one history entry. Empty results, errors, cancellation and stale
book/query completion are distinct. No background callback opens a result sheet
after departure. Advanced native regex/options/keyboard remain available.

Visible row count is derived from the shared layout plan with a reserve for native
button-table padding and separators. This is smaller than the eight-row data cap
when necessary; short displays retain the native fallback. An owned top/bottom panel whose measured controls cannot fit also opens its native counterpart rather than clipping or crashing. The native emulator
caught a too-tall results sheet and the corrected fit includes the padding that
native widgets add outside their requested content height.

## Verification

- Lua logic 256 and flows 281 (ten added reader-hook/navigation regressions over
  the merged Series baseline). Server/UI boundaries 12/6; feature matrix 4;
  emulator harness safety 8. Pinned KOReader compatibility passes, including every
  new native symbol; local ffi checks need a separate koreader-base checkout.
- Thirteen native emulator checks cover taps/top/bottom panels, unchanged menu
  position, native registered-plugin escape, custom gesture ownership, cached
  Contents, page/percent, bookmark preservation, search/match/no-result, disable,
  landscape, long-EPUB asynchronous search and cancellation. The long fixture has
  twenty chapters and 8,000 synthetic paragraphs. No physical device is touched.
- The existing full screen review runs alongside these area-specific checks.
  Companion behavior is unchanged; its merged baseline has 876 JVM tests with
  zero failures/errors and four skips. Required CI reruns it on the PR commit.

Native behavior citations use pinned KOReader
`9192014d8bd82a91dc1012473be0f238dedfdb54`: menu builders/search/registering at
`frontend/apps/reader/modules/readermenu.lua:390,524,529`; Contents locators/history
at `readertoc.lua:984`; saved-item navigation at `readerbookmark.lua:505,782`;
printed/hidden-flow labels at `readerannotation.lua:523` and
`readerbookmark.lua:646`; native search/navigation at `readersearch.lua:680,873`;
subprocess ownership/cancellation/serialization at `frontend/ui/trapper.lua:500`.
Paths without a prefix are under `frontend/apps/reader/modules/`. These are pinned
source facts, not assumptions about a newer KOReader release.

One emulator run recorded five navigation construction samples at 0.4–10.4 ms
(50 ms target), and four native search-worker samples at 7.2–254.8 ms, including
the long EPUB. Worker elapsed time includes native asynchronous polling. These
are emulator observations, not physical-reader latency guarantees.

# Android reader panels

Android-only implementation under the 2026-11-25 authorization. The approved
revision-16 prototype on `feature/0.12` is the presentation reference; the fetched
`origin/design/booksync-home` currently contains revision 14. The widget/layout,
adapter and staged-delivery contracts in DESIGN §3.5, §6 and §8.5 still apply.
No device, USB, firmware, release or tag operation is part of this change.

The existing reader owner (`ko/reader_panel.lua:4`) retains EndSheet's measured
rows (`ko/endsheet.lua:241`) and SheetLayout (`logic/sheet_layout.lua:61`). Its
header orders Home, title/author, Sync or account setup, Settings and bookmark;
the next band orders Contents, Bookmarks, Search, Go to, Book info and the
KOReader escape. Book info and Details retain their existing bounded progress
and saved-statistics surfaces. Sync keeps the existing writer and visibility
check; completion cannot reopen a dismissed panel.

The separate bottom panel contains the chapter/page line, chapter arrows and
touch scrubber, then Font/Size, Margins/Line spacing, Contrast/Status bar in two
columns, hardware-supported Light/Warmth sliders, More reading settings and
Edit presets. The merged Custom owner (`ko/custom_reading.lua:162`) still applies
a Custom choice first and edits it on the next tap. Edit presets opens the
existing Reading settings group with the existing Settings PIN policy.

All native control dispatch goes through Library's existing local-reader adapter
in `ko/reading_style.lua:143`; all book, battery and marker display data comes
through `ko/library.lua:16`. `LibraryReadModel.kt:40` adds the neutral
`reader.controls` operation, implemented in `ReaderControls.kt`. No server
adapter or sync/end-of-book transport was changed. The companion normalizes,
deduplicates and orders markers and formats page/chapter labels. Lua copies
at most 64 already-loaded native entries per marker kind and performs at most
32 cached TOC comparisons; it never loads or walks a full TOC or sidecar.
Long books sample markers across the book. Chapter labels retain the actual
native chapter count/index rather than reporting the sample count as a total.
Unavailable locator data stays explicitly unavailable. Estimates are not
invented from the prototype's synthetic reading pace.

Top and bottom are separately anchored and tap-outside/Back dismiss them. Native
dialogs are opened after dismissing the panel. Keyboard focus follows the header,
action tiles and quick controls; the bottom starts on the scrubber. Select grabs
or releases it, Left/Right step chapters while grabbed, and Back first releases,
then closes. Touch targets are at least 50 logical px. Native top tap/swipe no
longer opens the stock configuration menu underneath the owned top panel.

## Pinned native actions

Read at KOReader `9192014d8bd82a91dc1012473be0f238dedfdb54`. Paths below are
relative to that checkout, under `frontend/`:

| Action/state | Source |
|---|---|
| Contents | `apps/reader/modules/readertoc.lua:806` |
| Bookmarks and highlights | `apps/reader/modules/readerbookmark.lua:675` |
| Toggle bookmark; native annotation page | `apps/reader/modules/readerbookmark.lua:370`, `:604` |
| Go to; fulltext search | `apps/reader/modules/readergoto.lua:33`; `readersearch.lua:294` |
| EPUB chapter/percentage navigation (0–100) | `apps/reader/modules/readerrolling.lua:704`, `:725`, `:749` |
| PDF percentage navigation (0–1), chapter navigation | `apps/reader/modules/readerpaging.lua:1182`, `:1191`, `:1201` |
| Font size | `apps/reader/modules/readerfont.lua:203` |
| Native footer mode and redraw | `apps/reader/modules/readerfooter.lua:2423`, `:2485` |
| Native header fallback | `apps/reader/modules/readerrolling.lua:1246` |
| Frontlight/warmth state and setters | `device/generic/powerd.lua:126`, `:169`, `:216`, `:240` |
| Native style menu escape | `apps/reader/modules/readerconfig.lua:128` |
| Compound native top tap/swipe (replaced at the existing seam) | `apps/reader/modules/readermenu.lua:478`, `:489` |
| ButtonTable's native focus controls and font field names | `ui/widget/buttontable.lua:93`, `:128` |

Owned status strips retain `ko/status_layout.lua:155` as their owner. Clock hides
only that owner's top lane; Bottom bar hides only its bottom lane. Native footer
and header controls are used when the owned strips are disabled.

## Budgets and validation

Every screen/widget has a named budget in `logic/budgets.lua`. Top reads four
bounded rows (book, battery, controls, capabilities), bottom two (book, controls),
with one batched worker request each. Each widget snapshot remains at most
16 KiB. No render-path network or subprocess; no catalog filtering, sorting,
counts, joins or estimates in Lua. Native action and input calls and panel paints
log info timing spans. Device targets remain <500 ms Home, <50 ms widgets,
<30 ms cached library and <100 ms editor moves; host tests cannot establish them.

The existing Lua flow/logic harness covers actions, missing/pending/marked states,
visibility and close guards, EPUB/PDF units, marker bounds, native menu escape,
focus/Back and Custom behavior. Companion tests cover marker normalization,
invalid positions and encoded snapshot size. The pinned-symbol guard covers the
new native APIs. Flow construction is not a KOReader framebuffer or proof of
font metrics, grayscale appearance or real-device latency; device validation
remains required before any release.

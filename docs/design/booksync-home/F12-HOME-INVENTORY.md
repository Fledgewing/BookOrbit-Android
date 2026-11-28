# BookSync Android 0.12 retained Home inventory

Source audit of `origin/feature/0.12` at `0c4b869f` (2026-11-27), expanding the
umbrella Home row in ANDROID-012-FINISH.md. A host, an editor and seventeen installed
widget types do not implement the entire approved DESIGN §3.1 content inventory.
The original audit did not enumerate these missing mappings sufficiently.

`P` is `android/koreader/orbit.koplugin`; `C` is
`android/companion/app/src/main/java/net/fledgewing/orbitcompanion`. References below
are to that commit. Existing approved DESIGN §§3.1–3.4 and rev 16 authorize these
read-only cards, shelves and controls. Their implementation does not wait for the
separate, unapproved local completion/goal **settings** proposal.

| Retained content | Source state | Evidence / exact missing work |
|---|---|---|
| Currently reading | Done | `P/logic/widget_registry.lua:11`; `P/ko/home_widgets.lua:126` renders cover, progress and Resume. |
| Distinct Also reading | Done | `P/logic/layout.lua:188` installs its separate visible Book list; `P/logic/booklist.lua:8` retains the preset. |
| Reading streak | Done after audit | Separate card with current/longest streak and seven-day markers, independently labeled by source. [Implementation and verification](F12-RETAINED-METRICS.md). |
| This week and distinct Today | Done after audit | Existing Week and new distinct Today card; unproven local overlap stays separately labeled. [Implementation and verification](F12-RETAINED-METRICS.md). |
| Account reading goal | Done after audit | Read-only saved account target/year/completions with pace/progress and ahead/behind; missing completion stays unknown. Local settings remain NEEDS APPROVAL. [Implementation and verification](F12-RETAINED-METRICS.md). |
| Reading buddy | Done | `P/logic/widget_registry.lua:21`; `C/LocalWidgets.kt:29` uses known local reading state. |
| Highlight of the day | Done | `P/logic/widget_registry.lua:25`; `P/ko/local_widgets.lua:22` renders passage/source and explicit open. |
| Discover and Another | Done with labeled local source | `C/CatalogPersonalReading.kt:7` selects saved neutral catalog rows; `P/ko/local_widgets.lua:19` supplies Another. It does not claim server-generated ranks. |
| Recently added | Done | `P/logic/layout.lua:190` installs the separate shelf; `P/logic/booklist.lua:9` retains the preset. |
| Year in reading | Done | `P/logic/widget_registry.lua:17`; `P/ko/reading_stats.lua:5` renders the bounded annual model. |
| Distinct Finish forecast card | Done after audit | Separate read-only current-book card using the existing worker measured-pace forecast, with explicit insufficient-history state. [Implementation and verification](F12-RETAINED-METRICS.md). |
| Reading hours / When you read | Done | `P/logic/widget_registry.lua:18` and the reading-statistics renderer retain the hour distribution. |
| Personal records | Done | `C/ReadingStats.kt:130` supplies measured session/page/streak records; `P/logic/widget_registry.lua:19` retains their card. |
| A year ago | Done | `P/logic/widget_registry.lua:25`; `P/ko/local_widgets.lua:22` retains its source/summary and empty state. |
| Finished in YEAR with year selector | Not started | `P/logic/booklist.lua:11` offers all Finished, without a year selector or year-filtered source. A capped shelf must not become a total. |
| Word of the day | Done | `P/logic/widget_registry.lua:21`; `P/ko/local_widgets.lua:43` includes vocabulary source/context and lookup. |
| Distinct Pick back up shelf | Done after audit | [Owned source and native preset](F12-PICK-BACK-UP.md) select older in-progress books, exclude the current hero before filters/paging and preserve counted See all. Four native checks pass; physical acceptance remains. |
| Up next in series shelf | Not started | Series next-N is now implemented, but there is no Up next shelf source/preset in `P/logic/booklist.lua:6`–`:12`. A title suggestion is not a source. |
| Want to read shelf | Done | `P/logic/layout.lua:190`; `P/logic/booklist.lua:10` retains its separate selection. |
| Unopened and distinct Gathering dust | Not started | Registry and Book list source vocabulary lack both (`P/logic/widget_registry.lua:11`–`:28`, `P/logic/booklist.lua:6`). Need downloaded-never-opened identity/history, age/count/size and daily Next selection. Server unread is not equivalent. |
| Rich library counts and browse roots | Done after audit | Counted All books/In progress/Recently added/On device/Libraries/Authors/Series/Collections/Your lists roots, with explicit incomplete-index/local-file coverage. [Implementation and verification](F12-LIBRARY-ROOTS.md). |
| Named collection / Smart-scope shortcuts | Done after audit | Named collection and library sources join existing dynamic-list shortcuts, preserving opaque account-scoped membership and six-row paging. [Implementation and verification](F12-LIBRARY-ROOTS.md). |
| Sync / Wi-Fi / Night / Rotate controls | Done after audit | [Native Library controls](F12-QUICK-CONTROLS.md); six native checks and the 68-screen review pass; physical acceptance remains. |
| Clock/date | Done | `P/logic/widget_registry.lua:20`; `C/ClockWidget.kt:19` retains the local date/week. |
| Moon phase | Done after audit | Local mean-cycle phase/illumination/next primary change, with explicit approximation and invalid-date states. [Implementation and verification](F12-LOCAL-DECOR.md); nine native checks and the 65-screen review pass; physical acceptance remains. |
| Pages lifetime/today | Done after audit | Separate Today/lifetime timed page-visit card, attributed to this reader. A visit belongs to its start day; it is not an exact physical page-turn counter. [Implementation and verification](F12-RETAINED-METRICS.md). |
| Glyph of the day | Done after audit | Daily Latin sample/name/code point and actual local font family, with a native missing-glyph probe. [Implementation and verification](F12-LOCAL-DECOR.md); nine native checks and the 65-screen review pass; physical acceptance remains. |
| Monthly reading / Tree rings | Done after audit | Separate twelve-calendar-month totals/bar comparison, with previous-month duration and source coverage. [Implementation and verification](F12-RETAINED-METRICS.md). |
| Next stop | Done after audit | [Local cached TOC and measured pace](F12-NEXT-STOP.md); six native checks and the 66-screen review pass; physical acceptance remains. |
| Achievements | Not started | No achievement normalization/provider or installed card; retain earned/total, latest and next with progress, separating unsupported/off from zero. |

Implementation order: expand neutral read models and cached adapter projections;
add the approved metric/decor cards; add the missing shelf sources and source
picker options; add counts/root shortcuts and local controls. Keep one bounded
host batch, explicit coverage/source labels, zero transport/scan/fork in paint,
and existing layouts/user data intact. Firmware remains outside this task.

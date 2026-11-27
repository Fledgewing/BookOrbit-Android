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
| Reading streak | Partly done | Current/longest are available in `C/ReadingStats.kt:130` and the records renderer. `P/logic/widget_registry.lua:16`–`:20` has no separate streak card with seven-day history. |
| This week and distinct Today | Partly done | Week is installed at `P/logic/widget_registry.lua:16`; `C/ReadingStats.kt:133` supplies Today seconds. The distinct Today card is absent. |
| Account reading goal | Partly done | `C/server/bookorbit/BookOrbitLibrary.kt:25` normalizes cached server target/year/completed count. No goal widget is registered (`P/logic/widget_registry.lua:11`–`:28`), including required pace/ahead-behind. Local settings remain NEEDS APPROVAL separately. |
| Reading buddy | Done | `P/logic/widget_registry.lua:21`; `C/LocalWidgets.kt:29` uses known local reading state. |
| Highlight of the day | Done | `P/logic/widget_registry.lua:25`; `P/ko/local_widgets.lua:22` renders passage/source and explicit open. |
| Discover and Another | Done with labeled local source | `C/CatalogPersonalReading.kt:7` selects saved neutral catalog rows; `P/ko/local_widgets.lua:19` supplies Another. It does not claim server-generated ranks. |
| Recently added | Done | `P/logic/layout.lua:190` installs the separate shelf; `P/logic/booklist.lua:9` retains the preset. |
| Year in reading | Done | `P/logic/widget_registry.lua:17`; `P/ko/reading_stats.lua:5` renders the bounded annual model. |
| Distinct Finish forecast card | Partly done | Forecast data/rendering exists on the current-book card (`P/ko/home_widgets.lua:138`–`:139`). The separately retained forecast card is absent from the registry. |
| Reading hours / When you read | Done | `P/logic/widget_registry.lua:18` and the reading-statistics renderer retain the hour distribution. |
| Personal records | Done | `C/ReadingStats.kt:130` supplies measured session/page/streak records; `P/logic/widget_registry.lua:19` retains their card. |
| A year ago | Done | `P/logic/widget_registry.lua:25`; `P/ko/local_widgets.lua:22` retains its source/summary and empty state. |
| Finished in YEAR with year selector | Not started | `P/logic/booklist.lua:11` offers all Finished, without a year selector or year-filtered source. A capped shelf must not become a total. |
| Word of the day | Done | `P/logic/widget_registry.lua:21`; `P/ko/local_widgets.lua:43` includes vocabulary source/context and lookup. |
| Distinct Pick back up shelf | Not started | No preset/source in `P/logic/booklist.lua:6`–`:12`; an arbitrary renamed reading shelf does not install the retained older-in-progress selection. |
| Up next in series shelf | Not started | Series next-N is now implemented, but there is no Up next shelf source/preset in `P/logic/booklist.lua:6`–`:12`. A title suggestion is not a source. |
| Want to read shelf | Done | `P/logic/layout.lua:190`; `P/logic/booklist.lua:10` retains its separate selection. |
| Unopened and distinct Gathering dust | Not started | Registry and Book list source vocabulary lack both (`P/logic/widget_registry.lua:11`–`:28`, `P/logic/booklist.lua:6`). Need downloaded-never-opened identity/history, age/count/size and daily Next selection. Server unread is not equivalent. |
| Rich library counts and browse roots | Partly done | `C/server/bookorbit/BookOrbitProjection.kt:375` emits total/on-device only. `P/ko/storage.lua:72` links Authors/Series/Collections; Libraries and Smart-scope root/count presentation still need their retained paths and completeness labels. |
| Named collection / Smart-scope shortcuts | Partly done | Book list accepts opaque list keys at `P/logic/booklist.lua:20`, but its categories at `:3` exclude collections. Need collection shortcuts alongside existing list shortcuts, preserving opaque IDs. |
| Sync / Wi-Fi / Night / Rotate controls | Partly done | Sync and reading/native settings paths exist. No retained More/Home control widget is registered (`P/logic/widget_registry.lua:11`–`:28`). Keep Sync distinct from catalog Refresh and gate hardware features. |
| Clock/date | Done | `P/logic/widget_registry.lua:20`; `C/ClockWidget.kt:19` retains the local date/week. |
| Moon phase | Not started | No phase/illumination/next-change model or widget in the installed registry. Local date-derived data needs an honest approximation/unknown state. |
| Pages lifetime/today | Partly done | `C/ReadingStats.kt:130` exposes lifetime timed page visits, explicitly defined at `:55`; Today visit count and a distinct card are absent. Do not mislabel timed visits as exact physical turns. |
| Glyph of the day | Not started | No glyph sample/name/code point/font-source model or registered card. |
| Monthly reading / Tree rings | Partly done | Annual seconds exist (`C/ReadingStats.kt:125`); `:216`–`:227` contains month **axis labels**, not twelve monthly totals/comparative growth. The separate card is absent. |
| Next stop | Partly done | `C/ReaderControls.kt:21` supplies current chapter; no retained card supplies next chapter, time to next/end and remaining chapters from bounded reader capture + measured pace. |
| Achievements | Not started | No achievement normalization/provider or installed card; retain earned/total, latest and next with progress, separating unsupported/off from zero. |

Implementation order: expand neutral read models and cached adapter projections;
add the approved metric/decor cards; add the missing shelf sources and source
picker options; add counts/root shortcuts and local controls. Keep one bounded
host batch, explicit coverage/source labels, zero transport/scan/fork in paint,
and existing layouts/user data intact. Firmware remains outside this task.

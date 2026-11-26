# Android local optional widgets

Android-only, under the maintainer's 2026-11-25 build authorization. Word, Reading
buddy and Light retain the prototype picker names and 2×1/2×2 sizes. The prototype
still draws placeholders for these; meaningful copy follows DESIGN §3.1/§3.4.
Highlight's authorized passage and A year ago's server snapshot remain staged,
alongside Recommended and Discover, under this slice's server-data exclusion.

Reuse: `ko/home_widgets.lua:4` registers isolated renderers; `ko/home_host.lua:89`
reads through `ko/library.lua:29` into `LibraryReadModel.kt:25`. The same Home owner
owns invalidation, batching, Back and editor placement; no alternate store/cache or
transport. `logic/local_widgets.lua` contains presentation state only; the existing
`ko/reading_style.lua:228` owner applies Light changes behind Library.

KOReader evidence at pinned commit `9192014d8bd82a91dc1012473be0f238dedfdb54`:

- `plugins/vocabbuilder.koplugin/db.lua:8` names the borrowed settings database;
  `:12` and `:25` define vocabulary/context and title. The companion uses one
  read-only SELECT, selecting one daily row and bounding SQL text columns. Missing
  DB/history shows “Look up a word while reading.” Missing title is explicit.
- `frontend/apps/reader/modules/readerdictionary.lua:838` is the native lookup;
  `frontend/apps/filemanager/filemanager.lua:411` also installs that module. Lookup
  is an explicit tap, retains KOReader's dictionary dialogs, and returns to Home.
- `frontend/device/generic/powerd.lua:126` returns the already-cached frontlight
  scalar; `:216` owns mutations. The existing Library reader-control action wraps
  this owner; no sysfs access, vendor command or render-time hardware query.
- `plugins/statistics.koplugin/main.lua:406` defines `page_stat_data`; the existing
  `ReadingStats.kt:34` aggregation owns reading history and streaks. Buddy uses
  only its local output, never account totals or fabricated completion state.

Each widget has a one-row/16 KiB budget, a timing span, and no render network,
subprocess, history scan or separate companion round-trip. Home keeps one batch.
Word's host-owned minute heartbeat permits daily rollover without widget timers.
Light unsupported/error/loading and Word/Buddy missing/empty/loading/error/offline
states keep the named card. Compact retry messages are 50 px targets. The picker
uses installed registrations; cancelling preserves the existing editor draft rule.

Logic, native-tree flows, companion projection and pinned native-symbol checks
cover states and boundaries. No device was used: framebuffer wrapping, supported
vendor frontlight behavior and <50 ms/<500 ms targets await device acceptance.

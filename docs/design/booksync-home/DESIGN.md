# BookSync Home, tap to download and series

Status: **designing — awaiting maintainer approval**, W36, 25 November 2026.
Design and [self-contained mockups](mockups.html) only; no implementation or
release is authorized. This is the UI portion of
[backend independence step 1](../backend-independence.md#1-owned-android-client-and-ledger),
not approval of that document's ledger, export or server proposals.
Revision 3 retains every reader-preset content type and makes X3 a full 0.12
target by replacing all other Home paths. Revision 2 incorporated the maintainer's cross-platform ruling: owned X4 Home in
0.12 alongside Android, eventual plain-firmware base, and unified product versions.

## 1. Existing behavior and evidence

Local paths below are relative to Orbify. Upstream `B/` means
`upstream/bookorbit/` at pinned v3.9.0,
`c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7`; `X/` means
`upstream/crossink-v2.0/` at v2.0.0+bookorbit.1-rc3,
`87e2e1984481e8a3d996f12b34b50a383f9013b8`. Both checkouts were read at
these commits. `P/` abbreviates `B/koreader-plugin/bookorbit.koplugin/`.
Upstream references describe behavior, not code to copy.

| What exists | Source (`file:line`) |
|---|---|
| Launcher Home commands still route to the BookOrbit/smart Home paths; reading gates recognize the upstream catalog over a book. | `android/koreader/orbit.koplugin/ko/home.lua:20`, `:172`, `:196` |
| Local status/progress is layered over server data; pending writes survive stale responses; today's calendar is requested from the companion. These are wrappers, not an owned Home. | `android/koreader/orbit.koplugin/ko/localfirst.lua:74`, `:107`, `:219`, `:269`, `:358` |
| API caching still wraps BookOrbit's client and catalog; SQLite has one companion writer and bounded read snapshots in KOReader. | `android/koreader/orbit.koplugin/ko/cache.lua:6`; `android/koreader/orbit.koplugin/ko/store.lua:6`, `:25`, `:40`; `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/CacheStore.kt:314` |
| Four upstream pages (Home, Insights, Library, Decor), presets and customized tile layouts exist. | `P/bookorbit_board_store.lua:116`, `:169`, `:201` |
| Hero/Also Reading and all shelf types; Finished label uses a year but its list query has no year predicate; Want to read has no See all list. | `P/bookorbit_board_widgets.lua:108`, `:853`, `:959`, `:974`, `:1007`; `P/bookorbit_catalog_board.lua:994` |
| All widget types including buddy and other decor. | `P/bookorbit_board_widgets.lua:409`, `:455`, `:520`, `:552`, `:651`, `:776`, `:901`, `:1098`, `:1246`, `:1274`, `:1326`, `:1419`, `:1477`, `:1540`, `:1596`, `:1713`, `:1769`, `:1899`; `P/bookorbit_board_decor.lua:1397` |
| Download root precedence: download_dir, home_dir, device home, lastdir. Server devicePath is sanitized underneath it; one supported file opens/downloads, multiple files use a chooser. Download completion links file identity. | `P/bookorbit_download_root.lua:12`; `P/bookorbit_catalog_download.lua:30`, `:49`, `:109`, `:152`, `:291`, `:316` |
| Xteink already opens local rows, downloads remote rows, stages partial files, supports cancellation, and has a download index. The existing download fetches detail first. | `X/src/activities/browser/BookOrbitCatalogBrowserActivity.cpp:1220`, `:1243`, `:1353`, `:1535`, `:1573`, `:1589`, `:1601`; `X/src/BookOrbitDownloadIndex.h:23` |
| Full refresh and local-first additions are shipped on Android / in X4 rc builds; X3 complete cache is gated. | `docs/FEATURES.md:51`; `docs/design/bulk-catalog-refresh.md:1` |

Read alongside: [local-first](../local-first/DESIGN.md) (approved offline prompts,
local overlay and grouping), [SQLite](../sqlite-cache.md) (manual Full refresh,
bounded waits and storage admission), [bulk refresh](../bulk-catalog-refresh.md)
(#107/#110/#111 lineage, canonical rows, ordering and secondary memberships),
[end of book](../end-of-book/DESIGN.md), [sleep](../lock-screen.md),
[status layout](../reading-status-layout.md), and
[shared catalog inventory](../../../shared/fixtures/catalog/sections.json).
Older local-first/end-of-book upstream line references include retired 1.6 behavior;
the Xteink statements above were checked against the current pinned 2.x source.

## 2. Outcome and boundaries

BookSync owns Home, catalog lists, series and book detail on Android and X4 in
0.12, including X3 with a text layout and replacement Home budget. Android uses independently authored KOReader widgets;
Xteink uses our own firmware activities and SD database (§8). No BookOrbit board registry, layout engine, detail screen,
Activity or catalog UI is called on this route. KOReader still supplies its normal
widget and document APIs. The required, same-version companion owns networking,
JSON parsing, queries/derivation, folder scans, transfers and file writes. The
plugin sends bounded commands and renders small results. No local HTTP daemon.
A local read-only, bounded SQLite window is allowed as the companion-published
read model; it is not an adapter or a path to server APIs. No background scans or
large result sorting on the UI thread.

Home paints from the published offline generation plus local reading/file state.
No connection, authentication or refresh round trip blocks first paint. Missing
covers get typographic placeholders. A missing database yields an immediate empty
Home with On device, Settings and Full refresh; a worker scan populates local
books. Missing/wrong-version companion shows the existing workerProblem message;
no heavy fallback runs in Lua. A busy database uses the last small window or a
quiet placeholder and schedules another bounded read, never a blocking loop.
“Instant” means no network wait, not a measured latency claim; measure cold/warm
first paint before acceptance.

Only a user-started **Full refresh** shows refresh progress: one monotonic corner
percentage, below 100 until every required phase publishes, with existing
pause/error/completion states. Incremental checks and ordinary Refresh show no
spinner, toast or completion notice. The freshness line reports the last successful
snapshot, independently of connectivity. A direct Refresh may ask to connect,
then quietly check this view; Full refresh remains an explicit menu command.
Published data survives cancellation, storage exhaustion and network failure.
A changed tile alone repaints; use coarse progress steps and no animation on e-ink.
While reading, no Home repaint, notification, restart or automatic open takes focus.

### Companion-published Home read model

Proposed bounded results are `HomeWindow(generation, section, offset, limit)`,
`SeriesWindow(seriesKey, offset, limit)`, `BookSummary(bookKey)` and
`JobState(jobId)`. The companion materializes display rows and compact Reading
summaries into the owned offline database; title/cover refs, contextual membership,
source rank, reading/file state, freshness and field availability are separate
from backend payloads. Canonical books, memberships and rank sequences already
exist in the bulk plan; normalized Home summaries are proposed additions, not
fields claimed to exist today. A snapshot carries owner, generation and coverage
per source. Local intent overlay is independent of catalog generation and cannot
be erased by publishing a refresh. Summary totals use a source watermark and only
unacknowledged deltas newer than it; if overlap cannot be reconciled, show local
and server summaries separately instead of adding them.

A missing source says “Not saved yet”; a complete empty source says “No books.”
Base-catalog publication can enable Home before secondary membership completes,
while the series source retains its own completeness flag. Account revocation
must not publish a successful empty generation. Freshness is per source, with
Home showing the oldest successful stamp among visible sources; a local open
never claims the server was refreshed. Rich detail and cover availability remain
independent. An offline window read has no side effect beyond a cheap request to
the companion for a later eligible check.

## 3. Content parity with the reader preset

The maintainer supplied a **content-types-only** inventory and the settings values
`reader` / `outline`; no screenshots or device settings file were supplied to this
worktree. No device was accessed. Do not infer personal layout/content from those
values or commit names, accounts, hosts, book titles or quotes from the device.
All mockup values are invented examples, not an export of the maintainer's data.

At the pinned BookOrbit commit, `P/bookorbit_board_store.lua:28` identifies
`catalog_board`, `:115-163` defines the starter pages, and `:166-182` reads the
preset/style. **reader changes page order, not the content set**: Home, Insights,
Library, Decor. Portrait layouts at 2, 4 and 6 columns retain Word of the day and
all Decor content (`:122-135`, `:143-149`). We preserve the union because UI scale,
orientation and custom placement were not supplied. The landscape preset omits
some placements, not permission to remove their content. Outline is presentation,
not a content filter. Earlier revisions incorrectly treated useful Decor as
ornament and collapsed Pick back up; this revision supersedes those choices.

BookSync navigation becomes **Home / Insights / Library / More**, with paged
content within each tab. Browse indexes remain in Library; More includes Decor,
controls and Settings. Existing content is visible by default, including a named
empty/unavailable card where its source has no data. Users may deliberately hide
or reorder cards later; migration never silently hides a content type. Duplicate
clock drawings or repeated links may share one presentation, but their distinct
information and actions remain accessible. Android and Xteink use the same content
IDs and source/completeness rules; X3 uses text instead of elaborate art.

### 3.1 Preset tile → owned content mapping

Each row is retained content, not a promise of identical artwork or backend
semantics. Neutral presentation may consume a cached BookOrbit-specific summary.
Cached card data lives in our offline database; no upstream UI/renderer runs.

| Preset tile / supplied data | Owned visible content and placement | Source / boundary |
|---|---|---|
| `hero`, continueReading | **Currently reading**, resume position and cover, Home. | Cached reading IDs/ranks plus local progress/file overlay. |
| `also`, in-progress | **Also reading / In progress**, a distinct visible list after resume; not merely buried in a filter. | Same canonical records, separate selection and local overlay. |
| `streak`, readingStreak | **Reading streak**, current, longest and last seven days, Home/Insights. | Saved account summary plus explicitly separate pending local contribution. |
| `week`, `today` | **This week** daily minutes and total; **Today** minutes, separate labeled cards. | Cached readingYear/local session aggregates, coverage and source watermark. |
| `goalpace`, readingGoal | **Reading goal**, completed/target/year, required pace and ahead/behind status, Home/Insights. | Cached server goal/completed count; unavailable if unsupported. Do not substitute a device-only count for an account goal. |
| `buddy` | **Reading buddy**, state and reading message retained on Home; original static drawing or text on X3. | Known reading/streak/finish state; no copied sprite or pose code. |
| `highlight`, highlightOfTheDay | **Highlight of the day**, passage, book/source and open action. | Saved authorized snapshot, marked unavailable if absent; no remote fetch at Home entry. |
| `shelf(random)`, discover | **Discover** shelf and Shuffle, Home/Library. | Cached server selection, distinct from explicitly labeled local sample. |
| `shelf(recent)` | **Recently added** shelf and complete cached list. | Canonical recently-added order and source completeness. |
| `heatmap`, readingYear | **Year in reading**, annual heatmap/calendar and total, Insights. | Saved day buckets + local pending deltas without double counting; no fake zero for unknown days. |
| `forecast` | **Finish forecast**, remaining time / expected finish for the current book, Insights. Keep the card, not detail-only. | Measured local pace and known locator, or “Not enough reading yet.” |
| `hours` | **Reading hours**, hour-of-day distribution and peak time, Insights. | Worker-derived session histogram with source/coverage. |
| `records` | **Personal records**, longest session, most-read day and other available records, Insights. | Cached aggregates; retain each known metric, unknown values explicit. |
| `yearago`, yearAgo | **A year ago**, book, reading minutes/days and stop position, Insights. | Cached server snapshot + availability; retained even when the current snapshot is empty. |
| `shelf(finished)`, finishedThisYear | **Finished in YEAR**, year-specific shelf/count, Insights. | Preserve the dashboard's year selection and finishedOn, not a generic all-finished replacement. See §3.3. |
| `word` | **Word of the day**, word/context/source and lookup, Insights. **It is in reader and stays.** | KOReader vocabulary snapshot on Android; owned lookup history on firmware (§3.4). |
| `shelf(pickup)` | **Pick back up**, a distinct visible shelf of older in-progress books, Library. | Saved `reading` / `recently_read` ascending order plus local-state overlay; not merged into Currently reading. |
| `shelf(upnext)` | **Up next in series**, Library/Home. | Preserve bounded dashboard selection/rank; complete membership on the Series page. |
| `shelf(wtr)` | **Want to read**, Library/Home. | Saved server selection and pending intent; disclose cap, no fabricated complete list. |
| shelves.unopened + `dust` | **Unopened** list AND **Gathering dust** daily pick, age/count/size and Next pick action, Library/More. | Local downloaded-but-never-opened history; saved shelf joins IDs. Distinct from server unread and Not on device. |
| `link` + totalBooks / browseCounts | **Library counts** and links: all books, authors, libraries, collections, series, Smart scopes, in progress and on device. | Cached totals with provenance; do not replace an incomplete server total with the count of a visible window. |
| boardNames | **Named collection / SmartScope shortcuts**, Library, alongside their indexes. | Opaque scope IDs + saved labels/memberships; no client evaluation of scope rules. All fixtures use synthetic scope names. |
| sections | **Continue reading, Recently added, Libraries, Collections, Smart scopes, Authors, Series, All books**. | Retain every root destination; all finite browse identities work from the saved catalog. |
| `sync`, `toggles`, `light` | **Sync now**, sync result/freshness; Wi-Fi, Night, Rotate and Sync controls; frontlight control where hardware supports it, More. | Local controls/active sync owner; no hardware capability invented on X3. Sync is distinct from catalog Refresh. |
| `clock`, `analog` | **Clock/date**, retain timezone/time uncertainty and clock control; duplicate analog/digital drawing may share one card/header. | Local clock; X3 explicitly flags approximate/unknown time until established. |
| `moon` | **Moon phase**, phase name, illumination and next change, More. | Local date-derived information; text on X3, unknown when date is unknown. No copied art. |
| `odometer` | **Pages turned**, lifetime and today counters, More. | Own reading counters with source/coverage, not a cached book percentage. |
| `glyph` | **Glyph of the day**, sample, name/code point and font/source, More. | Locally available font sample; missing glyph is an explicit card state. |
| `rings` | **Tree rings / Monthly reading**, 12 monthly totals and comparative growth, More. | Same saved day/session data as Year in reading, separate visible monthly presentation. Text totals on X3. |
| `chapters` | **Next stop**, current/next chapter, time to next/end and remaining chapters, More. | Reader-captured locator/TOC and worker pace; show pending/unknown when unavailable. |
| `badge`, achievements | **Achievements**: earned/total, latest award and next achievement with progress/threshold, More/Home. | Cached authorized BookOrbit summary; latest and next both visible, off/unsupported distinct from zero earned. |

Evidence: shelves/counts/goals/highlights/year/word mapping is in
`P/bookorbit_board_data.lua:665-740`; achievement normalization `:503-540`;
local unopened scan/selection `:547-608`. Decor's meaningful fields are at
`P/bookorbit_board_decor.lua:413` (moon), `:485` (pages), `:576` (glyph),
`:714` (months), `:927` (chapter timing), `:1069` (achievements), `:1271` (dust).
Server dashboard supplies year-finished and achievement summaries at
`B/server/src/modules/koreader/koreader-catalog.service.ts:245-340`.

### 3.2 Backend-neutral retention and offline behavior

Keep canonical book rows, primary/secondary memberships, ranked shelf selections,
account totals, day/session aggregates and rich card snapshots separate. Store
source, generated time, coverage, optional field availability and owner. Shared
fixtures assert every content ID's presence and values, not only book order.
BookOrbit summary selection/ranking is adapter-owned; another backend may not
provide achievements/goals/highlights/year-ago. Keep an explicit “Unavailable from
this backend” card rather than silently dropping a reader-preset content type.
Local equivalents are labeled “On this reader” and never impersonate server
history. Account summaries and device summaries are shown separately when their
watermarks cannot be reconciled. No duplicated local/server minutes or awards.

Missing summary data triggers only an eligible background check; no network or
history crawl blocks drawing. Cached snapshots remain offline. Permission loss,
feature-off, unknown, incomplete and genuinely empty are distinct states. Cards
containing a book use the same safe open/download/details behavior as shelves.
Author/series grouping, status/format/scope sorting, offline search, On device and
Not on device remain available in Library, with explicit incomplete coverage.

### 3.3 Finished in year is retained, without inventing a list predicate

The dashboard's `finishedThisYear` is a real year-specific selection, including
finishedOn (`B/server/src/modules/koreader/koreader-catalog.service.ts:332-340`);
retain it with goal year/count on the **Finished in YEAR** card. The old card's
linked general list has no year predicate
(`P/bookorbit_catalog_board.lua:994-1007`): this does not justify removing the
card's year semantics. BookSync opens the saved year selection first, then pages
a complete year index only when completion-date coverage is proven. A separate
**All finished** link may show the general status list. Missing completion dates
are labeled Date unknown, never attributed to the current year using lastReadAt.
If the year selection is capped, label Saved selection and preserve server count;
local completions overlay it with provenance until acknowledged. Year rollover
retains previous snapshots and marks the new year's summary as pending until known.

### 3.4 Data that comes from the reader, not the backend

Word of the day is sourced from KOReader's vocabulary DB, not a network dictionary
(`P/bookorbit_board_data.lua:267-302`). The companion reads a bounded read-only
snapshot off the UI thread and publishes one word/context record to the owned
Home DB. No BookOrbit UI code or Lua vocabulary scan is retained. An empty pool
shows “Look up a word while reading.” On X4/X3, propose recording dictionary
lookups through the owned reader event/worker path into SD vocabulary history;
select a daily word locally, preserving context/source when captured. No lookup
history or dictionary means the same named empty card, not a removed feature.
Cross-device vocabulary transfer is outside this design; no backend field is
invented to make it appear supported. Chapter timing, page counters, records and
monthly/hourly aggregates similarly use bounded reader captures and worker-owned
SD projections. X3's text cards share these meanings without an animation engine,
vector artwork library or full series/catalog in RAM.

## 4. Tap to download and file ownership

Availability and reading state are independent: **On device / Server only** can
coexist with **Unread / Reading 42% / Read**. Unknown is explicit. Pending local
read state wins over stale snapshots and says “Not synced” only under the existing
outbox rule. On device means a verified linked file currently exists; a cover in
the cache never qualifies.

| Tile state | Primary action and result |
|---|---|
| On device | Open immediately at the local position. Missing file: clear stale availability and show the download action; no silent network call. |
| Server only, online | Select the saved supported file/variant, start download, show bytes or percent and **Cancel** on this tile; then open if this originating screen is still active. |
| Server only, offline | “Not downloaded — connect to get it” with **Connect and download / Cancel**. Connect only on acceptance, then download and open; failure offers Try again. Nothing queues merely because of an offline tap. |
| Downloading | Tile body opens job information; explicit Cancel stops that job. Repeated taps deduplicate by account/book/file/variant. Unknown size shows received bytes, never a made-up percentage. |
| Error / canceled | Keep the row and position; inline reason with Retry or normal Download. Cancel never deletes a complete existing file. |
| No supported file / access revoked | Explain the problem; no transfer. Cached local books remain openable when permitted by device storage; remote actions require current authorization. |

For multiple readable files show BookSync's small format/variant chooser before
transfer, unless a compatible preference is already saved. X4 offers EPUB only.
Adapters return transferable file descriptors; details need not be fetched if
cached manifest files suffice. Revalidate expiring download locators in the worker.
Use per-job IDs and ordered progress events; a late event cannot resurrect a
canceled job. Pause/restore app state without losing destination or bytes. Interrupted
jobs may resume after an explicit retry; no surprise auto-open after relaunch.
Navigating away or opening another book revokes automatic open, leaving “On device”
on return. Bulk downloads never open books automatically. A final completion races
safely with Cancel: once committed it is a saved book, but canceled intent never
opens it. No successful open until validation, atomic publish and identity linking
all succeed; a link failure is retryable without redownloading.

**Destination:** preserve existing settings and safe folder rules. Android adopts
KOReader's download_dir → home_dir → device home → lastdir precedence, displays the
resolved root in Settings and before a first download, and appends the adapter's
sanitized relative devicePath (title/author fallback). Root changes affect new
transfers only. X4 retains its SD catalog path policy
(configured download folder plus safe devicePath, title/author fallback;
`X/src/activities/browser/BookOrbitCatalogBrowserActivity.cpp:187`, `:198`). No migration
moves existing books. Reject traversal, absolute paths and symlink escapes; never
overwrite an unrelated collision. Resolve collisions with an identity suffix or
ask to select a destination. Existing linked copies open at their registered path.
A replacement follows the approved copies-current migration and preserves sidecars.
The companion handles hashing, validation, directory creation and atomic staging.
On Android a narrow compatibility bridge registers the verified digest/file/book/path
with the still-installed sync plugin (`P/bookorbit_state_manager.lua:446`); it
neither renders UI nor downloads through upstream code. Portably retaining this
mapping belongs to the wider step-1 identity/ledger review.

**Storage:** downloaded books and their reading sidecars never count toward
BookSync's cache limit and are never evicted (existing rule:
`docs/design/write-through-cache.md:102`). Partial book transfers use actual free
disk space, not cache quota; reserve headroom and fail clearly if insufficient.
Cache pruning can free eligible covers/metadata under existing protection rules,
never make room by deleting a book. Transfer accounting is separate from Full
refresh; downloading is visible because the user asked, silent refresh is not.

**Long press / More:** Details; Open or Download; View series (choose membership
when several); Mark read / Mark unread; Remove download if present. X4 Classic
uses its button action menu. Mark read uses the existing final-progress/status
ordering and durable sync owner, changes local UI at once and has Undo; it never
pretends a server acknowledgment. Remove download asks for confirmation, deletes
only the identified book file, retains reading state/annotations, and never sends
a server delete. Refuse while that file is open or being replaced; another open
book may remain open. For USB files not matched confidently, open locally and
exclude backend mutations until explicitly matched.

## 5. Series and detail

A Series page lists **every accessible cached member** in contextual reading order,
not just next unread or the server preview. Page-sized windows; no whole-series
JSON in Lua/RAM. Each row shows its contextual number, title, author, availability,
reading state and transfer action. Decimal indexes sort numerically (1, 1.5, 2);
null indexes follow numbered entries in a stable stored order. Equal indexes
retain source rank, then stable identity. Never imply that unavailable/filtered
books are known: show “Saved membership incomplete” when the later phase has not
published; keep the previous complete membership while replacement stages.

Primary and secondary series are separate membership records:
`(account, series ID, book ID, contextual index, source rank, primary?)`. The book
canonical primary series is never overwritten by a secondary feed. Duplicate
names with distinct IDs stay distinct; disambiguate in the picker using library
or a short identity label. Name-feed compatibility is confined to BookOrbit's
adapter. This reuses the W30 bounded later phase
(`docs/design/bulk-catalog-refresh.md:68`), not an eager all-series crawl.
Detail links expose all known memberships, not only the primary one.

**Download next N:** default N=3, editable 1–10. Starting after this series' current
reading member (otherwise its last finished member, otherwise the beginning),
select the next N eligible unread, server-only members in contextual order; skip
read, already local and active jobs. Show the exact titles/count and estimated
bytes, or “size unknown”, before starting. No wrapping; offer a starting row if
there are earlier unread gaps, and never silently choose a different series.
Incomplete membership disables the bulk action with a reason, while single-book
actions work. Offline, preview from saved data then offer Connect and download N.
One sequential queue bounds memory and network use. Each row can cancel, and the
queue has Cancel remaining; completed books stay. Stop on loss of connection or
auth, retain the queue for explicit Resume; report per-book format/space errors.
The summary reports requested/saved/skipped/failed counts, no auto-open.

Book detail is independently owned: cover or placeholder, title/authors, all
series links, reading status and local pending marker, rating, description, format
and size, primary Open/Download, and More. Descriptions are plain text derived by
the companion, with bounded expansion; no embedded web content. Rich detail is
lazy: an unseen offline detail has title/authors/files/state plus “Description
not saved” / “Rating not saved”, not invented blanks. Previously fetched values
remain with a saved timestamp. Online detail fetch runs in the companion and
updates only changed regions. Rating writes require capability, use the active
sync owner and preserve the existing end-of-book rating/status order. Read-only
adapters display rating without stars that imply editing.

End-of-book Next in series and Home use the same order/availability/action model;
Undo, rating and finish-job semantics remain as approved. Sleep picks consume the
same published source IDs/covers, keep their own quotas/rotation and never cause
a fetch at sleep. Home cover pruning cannot remove a sleep cover in use. Reading
status remains paint-only inside existing margins; Home creates no reader footer,
margin or timer changes. Update reading() and companion Reading to recognize
BookSync screens over a loaded book, preserving the existing reading gate and
position-sync exception without granting background jobs a new show path.

## 6. Small adapter boundary (proposed, not a frozen protocol)

Android path: **BookSync widgets → companion commands/read model → adapter**.
KOReader receives normalized fields, capabilities, job results and opaque
identities, never endpoint URLs, credentials or backend JSON to interpret.

| Operation | Normalized input / result |
|---|---|
| capabilities | Catalog/detail/download, supported formats, scopes, selections, progress/status/rating read/write capabilities and limits. |
| catalog | Account scope, cursor/query → bounded books, memberships, ordered selections, optional summary snapshots, next cursor and completeness. Adapter owns full versus incremental plans and staging. |
| detail | Book key → optional plain description, cover reference, series memberships, rating/status and file descriptors, with freshness and field availability. |
| download | Book + revision/file/variant → worker transfer job; bytes/total?, cancel, validated local artifact + identity. Expiring locators remain private to adapter. |
| progress/status | Read remote state; project a typed local intent to the sole sync owner; return ack/conflict/retry/unsupported. Preserve raw locator provenance and exact revision; no automatic cross-edition conversion. Rating is an optional extension. |

Common identity is `(adapter, account namespace, remote book ID, file revision)`;
a UI bookmark is never a title-based cross-backend match. Keep unknown statuses
as raw adapter values with a safe display. Canonical statuses are unread, reading,
read, rereading, on hold, abandoned, unknown; preserve information when projecting
to the backend's vocabulary. Errors are offline, unauthorized, forbidden, missing,
unsupported, space, retryable, conflict and canceled; do not disguise unauthorized
as an empty catalog. Account changes isolate cache, jobs, files mappings and
pending writes; never send an old owner's job with new credentials.

**BookOrbit first on Android:** catalog adapter normalizes the existing manifest/books,
indexes, dashboard selections and lazy detail sources from the bulk plan. It
owns SmartScope IDs, query syntax, delivery variants and authentication. At this
step progress/status intents pass through one compatibility bridge to the current
BookOrbit lifecycle/finish outboxes; do not add a second companion writer for the
same state. The UI sends only companion commands, and the companion coordinates
that bridge. Existing plugin sync can keep running in coexistence mode; its UI
is only reached via explicit rollback. Full adapter ownership of sync is a later,
checkpointed part of step 1, with its own review.

**Grimmory shaped, not claimed implemented:** same operations with explicit
capabilities and namespaced IDs. Until pinned source/authorized synthetic tests
verify its API, no endpoint names, auth method, series completeness, arbitrary
SmartScope support or write guarantee is promised here. Validate catalog/detail/
file/progress/status mapping and failures before enabling it. Unsupported
recommendations hide their slot or use explicitly labeled local Discover;
unsupported history remains unavailable. This design adds no server dependency,
export v1, irreversible ID migration or Grimmory credential collection.

## 7. Migration and rollback

Proposed setting in companion and KOReader: **Home screen: BookSync / BookOrbit**.
Keep the current default during design/testing. After design approval,
implementation and maintainer device acceptance, propose BookSync as the default
for new installs; existing installs get an explicit choice outside reading.
A default flip is reversible and must not accompany a database purge.

Preflight checks companion version, published cache ownership and current sync
configuration. Keep download roots, sidecars, bookmarks, old Home layout/settings
and existing outboxes. Backup configuration/mapping before importing any
BookSync-owned preferences; do not clone and drain pending writes twice. The
installed BookOrbit plugin remains responsible for sign-in and sync until replaced.
Home/launcher/restart return routes switch together, preserving back-to-book
semantics and add-on mode. No automatic restart while reading.

Rollback changes only routing to the existing BookOrbit Home. Stop BookSync-only
UI transfer scheduling, allow cancel/finish of active transfers, and retain linked
completed files; keep exactly one sync owner. No uninstall, downgrading schema,
deleting downloaded books or replaying external history. If BookOrbit is missing,
show its dependency state and retain BookSync's local Open/Settings access. Test
rollback after offline reads, partial downloads, queued mark-read and a restart.
The escape setting must be reachable without successfully opening either Home.

## 8. Xteink is a 0.12 client, not a later port

**0.12 scope:** BookSync Home replaces the BookOrbit Home on **Android, X4 Pro
X4 Classic and X3 together**. X3 fit is a release gate for this scope, not
permission to defer its owned Home.
The [X4 mockups](mockups.html#x4-home) are acceptance screens for the release,
not illustrations of a later roadmap phase. Home/Insights/Library/More, all inventory
entries in §3, series (including secondary memberships), detail, tap-to-download,
next-N, cancellation and offline errors have the same behavior and shared fixture
expectations as Android. Local Files, Recent books, Settings and OTA remain
reachable without a working backend or Home database. Replacing Home must not
replace the reader engine or remove these recovery routes.

### 8.1 Owned UI and SD database

On Xteink the path is **BookSync activity → BookSync read model/jobs → BookSync
adapter → transport**. There is no Android companion; its responsibilities belong
to our firmware worker. Our layer draws every screen from **our SD offline
database**, not `BookOrbitHomeStore` or the BookOrbit theme. “Database” here is
our existing bucketed canonical records, membership/rank indexes and atomic
published-generation marker, not a new requirement to embed SQLite. Existing
entry points: `xteink/orbify/BulkCatalog.h:9`, `CacheStore.h:45`,
`BulkCatalog.cpp:59`, and the [bulk design](../bulk-catalog-refresh.md#platform-implementation).
Today those APIs still accept BookOrbit URLs/JSON filters; the proposed read model
adds typed HomeWindow/SeriesWindow/BookSummary calls so our UI does not reconstruct
URLs or depend on BookOrbit structs. Existing SD generations can be read/imported
by the BookOrbit adapter; retain the prior generation during migration.

Use window-sized reads, bounded JSON filters and worker-owned writes. No whole
library or series in RAM. Base and secondary membership completeness remain
separate; retain the previous complete series until replacement publishes. Status,
progress, file availability and pending intents overlay cached server rows before
the first paint. Missing/corrupt SD data yields local files and Settings immediately,
with an explicit Full refresh action; it never forces a radio boot on Home entry.
Metadata/covers share the cache quota, while book files and reading state remain
outside eviction. Silent incremental refresh and manual-only Full refresh progress
are identical to Android. Cancellation/power loss keeps the last published catalog.

Pro touch and Classic Select have identical actions; hold Select/More substitutes
for long press, Back cancels a transfer, and page buttons navigate. Outline the
focused row. Compact paged shelves retain access to every section; text/calendar
cards can replace richer layouts without dropping state or actions. A reader in
front remains uninterrupted: worker events cannot open Home, flash a tile over a
book, launch a modal or restart the reader. X4 transfers run in the worker and
update the initiating tile only while that screen is visible. Navigating away
revokes auto-open, and bulk never auto-opens. End-of-book, sleep sources and status
layout use the same owned read model and existing reading gate.

X3 is a **full 0.12 target**, 528×792, button-only, no PSRAM. BookSync Home
**replaces**, rather than joins, the existing Home variants. Exclude BookOrbit,
Classic, Lyra, Lyra 3 Covers, Lyra Carousel, Cover Grid, Minimal and Dashboard Home
renderers/routing/assets from the X3 link, including their setting choices.
Do not merely hide a runtime menu: remove references and source units or guard
Home-specific paths so linker GC can discard them. Retain generic reader/list
styling, file browser, fonts, Settings, sync, OTA and signed recovery; theme classes
that also draw reader/list screens cannot be removed wholesale. Persisted old
Home/theme selections map to the sole BookSync Home without losing unrelated
reader styling. Other devices may retain optional Home alternatives if budget
allows, but all reader-preset *content* belongs to our one Home.

Text/paged SD cards keep every §3 content ID and all download/series/detail
behavior. Network boot may own transfers on C3, with saved return location and
cancel state; never require reader plus TLS plus full catalog in RAM. Failures
of flash/heap/SD/recovery gates block the X3 portion of 0.12 acceptance and require
further scoped replacement work or maintainer scope review—no automatic fallback
to shipping the old Home as the new feature. Measured symbol inventory and a
clearly estimated replacement budget are in §8.4 / [flash audit](flash-audit.md).

### 8.2 What currently depends on CrossInk-Bookorbit

The current production pin is X (defined in §1), **not plain CrossInk**. Its README
explicitly says BookOrbit sync/catalog are fork additions and KOReader Sync was
removed to make room (`X/README.md:1`, `:3`). Our code calls these additions
throughout; renaming Home cannot make the fork optional.

Counts below are reproducible from this Orbify tree's 58 files in
`xteink/overlay/patches/v2.0/*.patch`: count each `diff --git a/PATH b/PATH`
header whose PATH matches the row. Repeated edits to one path in different patches
count again. “Patch files” counts each patch once within that category; categories
overlap. Baseline is Orbify `653e50d` (the initial draft's merge of main).
The brief's 19/17/30/8 are useful earlier touch estimates; this inspected
tree yields 18/20/27/8 file-edit headers, not claims about independent modules.

| Dependency | File-edit headers / patch files now | Evidence and what BookSync must own |
|---|---:|---|
| `src/network/BookOrbitCatalogClient.*` | 18 / 11 | `X/src/network/BookOrbitCatalogClient.h:12`; `xteink/orbify/RefreshRunner.cpp:27`, `:97`; `BulkCatalog.cpp:168`. Own catalog+manifest transport, normalization, detail/cover requests, connection reuse, auth/error mapping and refresh entry points. |
| `lib/BookOrbitSync/*`, including credentials | 20 / 11 | `X/lib/BookOrbitSync/BookOrbitCredentialStore.h:29`, `:68`, `:144`; `BookOrbitSyncClient.h:11`; `xteink/orbify/FinishSync.cpp:137`. Own account namespace, login/auth storage, device identity, matching, locator capture, progress/status/rating projection, durable queues, sessions and annotations/bookmarks currently supplied by the fork. No loss of existing supported sync when removing it. |
| `src/BookOrbitHomeStore.cpp` | 4 / 4 | `X/src/BookOrbitHomeStore.h:9`, `:26`, `:33`. Replace bounded server Home snapshot/cover handling with owned Home projections from our SD catalog plus local reading summaries. |
| `src/activities/browser/*` | 27 / 14 | `X/src/activities/browser/BookOrbitCatalogBrowserActivity.cpp:1220`, `:1353`, `:1589`, `:1601`. Own browse/series/detail/actions, safe destination policy, transfer/resume/cancel, validation, atomic file swap, file index/linking and return-to-reader routing. Reuse generic base file/reader primitives, not the old catalog UI. |
| `src/activities/home/*` | 8 / 5 | `X/src/activities/home/HomeActivity.cpp:28`, `:832`; `HomeActivity.h:20`. Register our activity directly, remove BookOrbit theme/store dependencies, retain local files/settings routes and restore focused row/page after transfer. |
| Reader, end-of-book, sleep and networking seams | Overlap with the rows above and mixed patches | `xteink/orbify/EndPage.h:25`, `FinishSync.cpp:235`, `SleepScreen.cpp:25`, `:144`, `:1026`; `xteink/tailnet/tailnet_build.py:168`. Replace BookOrbitCatalogLink/download index/client calls with owned keys/jobs; preserve finish ordering, copy migration, cover rotation, Wi-Fi holds, network boot and no-interruption gates. |

Also audit ActivityManager/network-boot targets, BookOrbit settings/auth activities,
theme registration, i18n/language packs and build/simulator hooks. Login today is
fork UI (`X/src/activities/settings/BookOrbitAuthActivity.cpp:40`); its replacement
must support URL/account entry, test connection, credentials, sign out and revoked
access without exposing secrets. Credential migration is a local, one-time,
owner-checked import with private backup/rollback—not a plain-text export or a
remote history replay. Keep Tailscale identity separate from backend credentials.

The adapter must preserve currently used library access restrictions, download
variants, exact file identity and stale-push guards. Progress, bookmarks,
annotations and sessions need a feature-by-feature ownership checklist, even
though Home does not draw all of them. Removing their fork implementation before
an equivalent exists would regress shipped sync. A facade is isolation, not proof
that we have removed the fork.

### 8.3 Base comparison at fixed source revisions

Design inspection pins (not production lock changes):

- **CI:** plain [CrossInk v2.0.0](https://github.com/uxjulia/CrossInk/tree/2cdd6117568c8877c3180d5fac8d5b20e55d1ac7),
  commit `2cdd6117568c8877c3180d5fac8d5b20e55d1ac7`.
- **CP:** [CrossPoint 2.0.0](https://github.com/crosspoint-reader/crosspoint-reader/tree/42d58daaabcf469a2e5e1ba871714fb9dcf51d29),
  commit `42d58daaabcf469a2e5e1ba871714fb9dcf51d29`.

Both were read as detached source checkouts. CI/CP paths below are relative to
those commits. No candidate is enabled, built or substituted into `tools/upstreams.lock`
by this design. Before a port build, add the selected exact pin and recursively
pinned SDK/dependency sources to the build/reproducibility plan.

| Concern | Plain CrossInk (CI) | CrossPoint (CP) | Implication |
|---|---|---|---|
| Fonts | Bitter/Lexend built in, scalable S3 faces and SD font workflow (`CI/README.md:33`, `:63`, `:78`; `src/activities/settings/FontDownloadActivity.cpp:187`). | SD custom fonts, S3 TTF/OTF/TTC and C3 cpfont (`CP/README.md:30`, `:137`); own font-download activity. | CrossInk preserves our current font choices and settings more directly. Confirm Literata assets/catalog compatibility rather than copying another repo's font binaries. |
| Themes/status/sleep | Minimal and Dashboard alongside inherited themes (`CI/README.md:35`; `src/CrossPointSettings.h:370`; `src/components/UITheme.cpp:24`). | Classic/Lyra/RoundedRaff and sleep/status controls (`CP/README.md:52`; `src/components/UITheme.cpp:17`). | Our Home is independent of theme. CrossPoint would still need migration for CrossInk-only theme/sleep preferences and visual regression checks for status margins. |
| Reader/local library | Existing CrossInk EPUB activity and local reading state (`CI/src/activities/reader/EpubReaderActivity.cpp:2541`, `:6222`). | EPUB reader, bookmarks, dictionaries, local indexed library (`CP/README.md:20`, `:38`; `src/activities/reader/EpubReaderActivity.cpp:241`). | Both are viable readers. CrossPoint is not a drop-in same-line rebase; reader lifecycle/status/bookmark hooks differ. Retain positions and verify locators on real sample EPUBs. |
| Settings and sync | CrossInk settings plus its own KOReader auth/sync (`CI/src/CrossPointSettings.h:638`; `src/activities/settings/KOReaderAuthActivity.cpp:1`). | Native settings and KOReader sync (`CP/src/CrossPointSettings.h:354`; `README.md:20`). | Neither supplies our complete BookOrbit adapter. Disable competing native sync for BookSync-managed books; preserve unrelated user choices. |
| OTA/recovery | `CI/src/network/OtaUpdater.cpp:1`, `src/network/OtaBootSwitch.cpp:1`. | `CP/src/network/OtaUpdater.cpp:1`, `src/activities/settings/OtaUpdateActivity.cpp:14`. | Keep Orbify signed feed, TLS, source archive and A/B boot validation. Native OTA alone is not our trusted update path. |
| Devices/tooling | `default`, `x4-pro`, `x4-classic` and our familiar simulators (`CI/platformio.ini:219`, `:371`, `:393`, `:477`, `:553`). | X3/C3 and S3 supported, with `x4pro` / `x4c` environment names (`CP/README.md:9`; `platformio.ini:306`, `:392`, `:477`). | Both support hardware, but CP needs environment/simulator/CI mapping and SDK integration work. Neither proves our overlay fits. |
| SDK | FreeInk SDK submodule plus additional assets (`CI/.gitmodules:1`). | FreeInk SDK submodule (`CP/.gitmodules:1`). | Pin recursive dependencies and audit HAL/input/network differences; no assumed ABI compatibility. |
| Top-level license | MIT (`CI/LICENSE:1`, `:6`). | MIT (`CP/LICENSE:1`, `:5`). | X's top-level `LICENSE:1` is MIT too. A base switch is not a reason to relabel existing GPL files or the combined firmware MIT. |

License scope matters: Orbify files marked GPL-3.0-or-later retain that license;
MIT base/overlay notices and third-party notices remain. Current binaries are
GPL-3.0-or-later because of the complete component set, including wolfSSL
(`xteink/README.md:389`, `:397`); changing the top-level base does not remove those
dependencies or source-distribution obligations. Audit the complete selected build
and corresponding source before distribution, including SDK and font licenses.
This comparison records each repository's LICENSE, not a claim that every file or
linked dependency is MIT.

Release metadata checked 25 November 2026 through the repositories' GitHub releases
API (latest six non-draft entries; this is a small observation window, not a
stability benchmark): [CrossInk releases](https://github.com/uxjulia/CrossInk/releases)
show v1.5.1 September 11, v1.6.0 September 21, v1.6.1 October 4, rc3 November 19
and **v2.0.0 final November 25**; [CrossPoint releases](https://github.com/crosspoint-reader/crosspoint-reader/releases)
show 1.6.0 September 5, 1.6.5 September 27, 2.0.0rc October 19 and **2.0.0 final
November 1**. [BookOrbit-fork releases](https://github.com/agosez/CrossInk-Bookorbit/releases)
show 2.x rc2 November 14 and rc3 November 22 alongside 1.6 maintenance releases.
There is no basis to call the newly published CrossInk final field-proven, or to
infer fewer bugs from CrossPoint's older final label. Pin, run our suite and get
maintainer device acceptance; do not automatically follow either default branch.

**Recommendation: plain CrossInk as the eventual base**, conditional on port and
recovery evidence. It preserves more of the user-facing font/theme/settings and
hardware/simulator shape we already support. CrossPoint is a credible fallback
if CrossInk maintenance ceases or a measured CP build materially improves fit,
but its wider hook/settings port is extra work, not needed for owning Home.
Keep the current BookOrbit fork during the first 0.12 slice; do not couple a UI
release to an unproven reader/base migration.

### 8.4 Flash and patch budget: measured baseline, proposed destination

The brief's X3 98.7% is historical: `docs/design/XTEINK-BUILD-NOTES.md:45`
records 98.69% after the early finish change. Later W8 measurements at rc3
(`:535`) record the following. These are recorded results, **not fresh builds
of this design**, and must not be mixed with a current branch or a plain-base build.

| Device | W8 used / 6,553,600 bytes | Free to slot end | Free to 99.5% gate (6,520,832) |
|---|---:|---:|---:|
| X4 Pro | 6,375,685 (97.29%) | 177,915 | 145,147 |
| X4 Classic | 6,218,742 (94.89%) | 334,858 | 302,090 |
| X3/C3 | 6,514,417 (99.40%) | 39,183 | 6,415 |

**Newer X3 evidence for this revision:** public run
[45688398918](https://github.com/Fledgewing/Orbify/actions/runs/45688398918)
(commit `0ebe1858cfd9ca213715b44d8daeba5ed265429f`) used **6,466,767 B
(98.68%)**, leaving **54,065 B** to the actual 6,520,832 B gate. Its debug ELF
contains **17,520 B** of named BookOrbit Home presentation symbols and **5,108 B**
of CoverGridHomeUi symbols. Dropping these is a **22,628 B gross-removal estimate**,
not a measured net saving; do not count generic theme code used by the reader.
A further **23,608 B** in HomeActivity includes shared routing and gets zero
savings credit. The [flash audit](flash-audit.md) records source/hash/method and
an estimated replacement envelope: 54,065 + 22,628 − 8,192 integration reserve
= **68,501 B**, with a **49,152 B design target** for the new text Home/SD projections
leaving **19,349 B** under the gate if the assumptions hold. No after-build/map
was fabricated; actual compile-time elimination, image size, heap and recovery
are mandatory release evidence. Other Home paths may save more, but get no
unmeasured credit. This targets X3 by replacing redundant implementations,
not by dropping content or deferring Home.

CI/CP both define 0x640000-byte dual app slots (`CI/partitions.csv:4`,
`CP/partitions.csv:4`). Their bare firmware and **base + complete BookSync layer**
flash/heap headroom per device are unmeasured here. Removing fork code may save
space, but adding owned equivalents and restoring native sync can cost it back.
X3 is targeted by removing redundant Home code; estimated savings do not satisfy
the final release fit check. Compare identical toolchain,
feature flags, dependencies and partition layout for current base, CI and CP;
record ELF/map sections and actual firmware bytes separately for all three
readers, cold/warm heap and peak parse/transfer allocations. Require the existing
99.5% gate and safe heap headroom with TLS/Tailscale, not a bare-reader fit.
Disable unused native KOReader sync to avoid duplicate writer/code costs, without
silently removing other promised reading features.

Current series: **58 patch files, 295 file-edit headers, 97 unique paths,
881 hunks, +6,132/−819 lines**. This excludes owned `orbify/`/`tailnet/` sources;
those remain substantial code even if patch count shrinks. A mechanical path
classification finds 8 patches touching only BookOrbit-named paths, 30 mixed and
20 touching no BookOrbit-named path (22 distinct BookOrbit-named paths total).
Method: backend path means contains `BookOrbit`, starts `lib/BookOrbitSync/`, or
starts `src/components/themes/bookorbit/`; count headers/hunks and added/removed
lines excluding `+++`/`---`. Names are only an audit aid, not proof of isolation.

| Stage | Patch-series expectation | What it means |
|---|---|---|
| Current | 58 files, figures above | Real baseline from this design branch. |
| 0.12 owned Home on current base | Actual total not yet known; expect temporary integration work, not an immediate net reduction | Retire Home/catalog UI patches as owned activities take over; keep sync/download/login patches behind the adapter until replaced. |
| Plain CrossInk + owned adapter | Planning budget: review the 20 base-only patches, and consolidate remaining integration into at most six seam groups (Home/activity routing, reader/end-of-book, sleep, settings/login, transport/network boot, build/OTA). Approximately 26 patch files before further consolidation is a **design target**, not an apply-tested result. | Zero patch targets on removed BookOrbit paths; owned C++ sources carry the replacement behavior. Mixed patches must be split, not discarded. Actual diff/hunk totals require the port. |
| CrossPoint alternative | No defensible patch-count saving before a port; same six owned integration seams plus CrossInk feature/settings work | A smaller fork ancestry does not establish a smaller Orbify maintenance burden. |

Do not copy the 58-patch series onto the new base and suppress failures. Create a
new exact-pin series; each retained behavior gets an owned module and minimal
hook, with source provenance and shared tests. The eight backend-only patches
are migration candidates, not eight safe deletions: TLS, retry and refresh logic
must survive in owned code. `xteink/scripts/apply.sh:24` currently expects specific
configuration and environments; port that validation, CI and source packaging too.

### 8.5 Staged delivery and rollback

1. **0.12, all reader platforms:** owned Home/Insights/Library/More, Series and Detail; BookOrbit
   adapter facade and SD read model on the current pinned firmware base. All new
   UI, refresh, end-of-book and sleep consumers call our adapter/read model, never
   BookOrbit UI or network classes directly. During transition only a private
   `LegacyBookOrbitTransport` behind the adapter may call fork sync/download/login
   primitives. Label this as compatibility, not backend independence completed.
   One active sync writer; do not run facade and legacy outboxes in parallel.
2. **Complete firmware ownership:** independently implement BookOrbit catalog +
   manifest/detail, safe transfer/download index, credentials/login, progress/status,
   sessions/annotations/bookmarks used today. Replace each legacy transport call
   behind the unchanged adapter. Audit source/build references and exercise
   offline/cancel/retry/revocation/power-cut and no-interruption cases. Exit gate:
   no required BookOrbit-fork symbol/assets/schema except an explicit read-only
   migration importer; the reader and Tailscale remain base/platform services.
3. **Base cutover, separate maintainer approval:** build plain CrossInk + our layer
   at an exact pin, migrate settings/account/file mappings with backups and no
   destructive position conversion, run all device profiles and release emulation,
   then maintainer device tests. Preserve native OTA partitions and signed recovery.
   The cutover can follow 0.12; owned X4 Home in 0.12 does not wait for it.

Before base cutover, Android/X4 can route to old Home if it is retained. X3 has
no alternate Home code in its 0.12 image: its rollback is a signed prior firmware
even while still on the current base.
After cutover, the BookOrbit Home no longer exists: **rollback is a signed previous
firmware**, not a setting. Retain a last-known-good image plus source, preserve
SD books/sidecars/local queues and NVS/Tailscale credentials, and make migrations
additive/checkpointed with previous-version backups. Do not allow old and new
writers to drain the same queue. Test downgrade-readable settings or restore the
backup explicitly; never silently downgrade a database or replay accepted writes.
Prove OTA/SD recovery on USB-locked devices before cutting over; agents use only
host/simulator tests, maintainer performs device acceptance. Recovery publication
and any base change need approval; this design changes neither pin nor updater.

### 8.6 Grimmory-ready on Xteink

Use the same conceptual operations and normalized identity/state/error model as
§6: capabilities, catalog, detail, download job and progress/status (optional
rating/history). Android implements them in the companion, Xteink in the firmware
worker; binary encodings and schedulers need not match. Login/credential storage
is a platform service selected by adapter, never hardwired into Home. Endpoint
strings and BookOrbit integer IDs stay inside the adapter or migration importer;
series/book keys at the UI boundary are namespaced and contextual.

BookOrbit is first. Add synthetic adapter contract cases for Grimmory-shaped
capabilities now in the future implementation plan, then verify real Grimmory
routes/auth at a pinned source revision before enabling it on either platform.
No invented progress/annotation conversion and no promise to fit two complete
direct adapters simultaneously on X3. If server-assisted X3 is needed, that is an
explicit later profile; a BookSync server is not a 0.12 Home prerequisite.
Lua, JVM and C++ consume the same expected projection/job/error cases (§9), with
X4 touch/button and X3 button/text equivalents declared in fixtures; backend or
reader data availability is explicit, never a blanket X3 Home exclusion.

### 8.7 One BookSync version from 0.12

Maintainer direction: **one canonical BookSync version** across Android Companion,
KOReader plugin and Xteink firmware, starting at `0.12.0` (same prerelease suffix
on a coordinated candidate). This replaces the old idea of merely sharing a
release name while maintaining independently numbered product versions. Xteink
About shows `BookSync 0.12.0`; `CrossInk <tag> (<commit>)` is base metadata only,
not the product version or the source of release-channel policy. The same manifest
version stamps every artifact; per-device build IDs/hashes identify rebuilds,
not separate feature versions. Host/About mockups show this explicitly.

Current workflow derives a four-part version from upstream and run number
(`.github/workflows/xteink.yml:37`, `:191`, `:281`). Simply changing that to 0.12
would compare below installed 2.x firmware. Before shipping unified versions,
design and test an explicit **legacy → canonical version transition**: a bridge
update in the legacy feed teaches old readers to consume canonical BookSync
version/channel plus a monotonic signed migration/build identity. Readers that
never take the bridge need a documented manual recovery/update path; do not offer
0.12 as an apparent downgrade to an unchanged numeric comparator. Test feed/cache
replay, failed bridge install, rc→final, future patch, new-base metadata changes,
rollback and skipped bridge. Signed rollback must authorize an exact previous
artifact hash through a newer recovery record (or the existing validated A/B
boot rollback), not disable signature checks or reset monotonic replay guards.
Keep old published tags immutable. The bridge is
compatibility metadata, not another BookSync product version.

Retain platform tag namespaces (`v0.12.0`, `xteink-v0.12.0`) and firmware feed
routing; “latest” remains Android and Xteink releases remain `make_latest=false`.
Do not infer channel from an upstream rc after unification: BookSync rc/stable is
its own acceptance decision, with base provenance disclosed. Signed artifact/feed
contracts, legacy parsing and bridge release ordering need their own implementation
review before release; this design does not change workflows or publish a bridge.

### 8.8 Approval and acceptance gates

Design review includes both device mockups, §3's full inventory and the staged
adapter/base/version ownership—not Android first with Xteink deferred. Implementation
can use parallel platform slices on `feature/0.12` only after approval; no code is
authorized by this draft. Acceptance adds: owned X4 first paint with network off;
no old Home/catalog UI invocations; consumer imports confined to our adapter;
sole sync writer; login and credential migration/rollback; positions/bookmarks/
annotations/session preservation; SD power cuts during publication and transfer;
full X4 touch/button and X3 button/text fixture parity; complete preset-content
inventory (including empty/unsupported states); X3 alternative-Home symbol absence
and A/B map/fit report; version bridge/feed tests;
and signed OTA/SD rollback across the proposed base switch. CrossPoint/CrossInk
comparison builds are future evidence, not performed in this design change.

## 9. Verification plan (future implementation, not tests added here)

Reuse `shared/fixtures/catalog/sections.json`, `catalog/bulk-refresh/`,
`bookorbit/catalog-book.series-*.json`, `bookorbit/finish-cases.json`,
`localfirst/overlay-cases.json`, `localfirst/stamp-cases.json`, `storage/cases.json`,
`sleep/cases.json` and `status/format.json`. Add synthetic `home/` cases only when
implementing, with registry readers for Lua UI projections, JVM jobs/adapters and
C++ projections/queues. Same expected book IDs, membership order, availability,
action labels and errors on every capable platform; device-specific layout snapshots.
Do not add fixture registry rows now without their required consumers.

Acceptance matrix: every inventory entry and empty/unsupported state; all finite
browse identities offline after Full refresh; missing detail/cover; stale cache
plus local read/Undo; two same-named series and secondary/fractional/null members;
paging and earlier gaps; next-N filtering/cancel/resume; file chooser/variant;
revoked access; free-disk versus cache-quota exhaustion; missing/moved/colliding
files; failure between file publish and link; repeated taps/events and cancel at
completion; app death; owner switch; rollback and single-writer assertions.
Reject per-book detail crawls during catalog refresh and network calls on offline
navigation. Measure first-paint latency, request counts, SD/SQLite bytes and X4
heap/flash. Test Full refresh monotonic progress independently of downloads;
assert no UI/focus/restart while reading and no background refresh notices.
Run relevant plugin logic/flow/compatibility, companion and Xteink host/simulator
suites when those components change. CI and later maintainer device visual checks
are gates; mockup dimensions alone are not device validation.

## 10. Two-way doors decided in this proposal

| Decision | Rationale |
|---|---|
| Home / Insights / Library / More with paged cards, no layout editor | Preserve all reader-preset content by default; deliberate hide/reorder stays reversible. X3 rollback uses firmware. |
| Finished in YEAR shelf plus separate All finished | Retain dashboard year selection; never invent a year filter for the old general list. |
| Tap opens/downloads; details on long press/More | The maintainer's requested fast path; discoverable hint and explicit Details on every menu. |
| Next N defaults to 3, one transfer at a time | Predictable storage/connection use; count and concurrency can change later. |
| Typographic covers and original static/text buddy | Keep buddy, word and meaningful Decor content; artwork may change without losing information. |
| Opt-in migration for existing installs | Limits surprise and makes comparison/rollback easy; new-install default reviewed after acceptance. |
| Operation names and physical schema remain internal | Validate both adapters before any public compatibility promise. |

These settle the design draft, not approval to build.

## 11. One-way doors for the maintainer (approval questions)

These are externally lasting or potentially destructive commitments, separate
from the reversible UI choices. Recommended answers are proposals.

1. **Code provenance:** approve independently authored UI/adapters with no copied
   BookOrbit board code/assets, preserving AGPL Lua / MIT companion boundaries?
   Confirm before any implementation reuse; distribution cannot undo provenance.
2. **Identity and retained reading data:** may Home rely only on namespaced backend
   aliases plus exact revisions for now, with no title-based merging, destructive
   rekey or ledger/export-v1 freeze? Durable portable IDs/history remain a separate
   step-1 approval; a bad merge could attach annotations to the wrong edition.
3. **External writes during coexistence:** approve one existing BookOrbit sync
   owner per platform, with intents through the companion/firmware adapter and no
   bulk replay of history? Any future
   writer takeover needs a checkpoint/backup review; rollback cannot unsend writes.
4. **Support commitment (maintainer ruling captured):** complete cached
   Home/Series/Detail on **Android, X4 Pro, X4 and X3 in 0.12 together**, with
   BookSync the sole compiled X3 Home.
   The maintainer directed this scope; measured fit/recovery remain release gates,
   not automatic platform deferral. Grimmory capabilities still require validation.
5. **Firmware base switch:** approve the staged destination **plain CrossInk +
   our layer**, removing the CrossInk-Bookorbit layer only after owned sync,
   downloads, credentials/login and all used history features pass acceptance?
   This is a one-way door for support/recovery: the old Home setting cannot restore
   removed firmware, persisted-state migrations and signed updater lineage must
   remain recoverable, and already projected backend writes cannot be unsent.
   CrossPoint stays a compared alternative; cutover needs a separate explicit
   review of measured fit, licensing/source inventory and signed rollback (§8.5).
6. **Version/update lineage:** the maintainer has directed one BookSync version
   from 0.12; approve the bridge/legacy-feed transition contract before any release?
   Immutable tags, signed migration identities and readers that miss the bridge
   are lasting compatibility obligations (§8.7).

Maintainer also reviews the full inventory (every retained reader-preset content type and changed layout
organization), offline prompt, series ordering, detail/actions and Android/X4/X3
mockups before changing status from designing. Draft PR acceptance alone does
not authorize implementation or a default flip.

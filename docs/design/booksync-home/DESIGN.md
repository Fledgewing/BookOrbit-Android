# BookSync Home, tap to download and series

Status: **designing — awaiting maintainer approval**, W36, 25 November 2026.
Design and [self-contained mockups](mockups.html) only; no implementation or
release is authorized. This is the UI portion of
[backend independence step 1](../backend-independence.md#1-owned-android-client-and-ledger),
not approval of that document's ledger, export or server proposals.

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

BookSync owns Home, catalog lists, series and book detail as independently authored
KOReader widgets. No BookOrbit board registry, layout engine, detail screen,
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

## 3. Home inventory: keep, merge, drop

Default pages are **Home / Browse / Reading**. Each is paged, not an endlessly
scrolling dashboard. Home starts with Currently reading, then Up next in series,
Want to read and Recently added. On Android, each shelf has a small cover window
and a link where a complete source exists. Page indicators expose overflow.
Browse provides every index, sorting/filtering/grouping and search. Reading holds
calendar/stats and Finished. Users can hide/reorder sections with a simple list;
there is no free-form widget grid. Empty sections say why; hidden sections remain
reachable through Browse. No new title/author/status queries are run on entry.

“Neutral” describes the client concept; it does not assert that every backend
provides the same selection or history. All sources are rendered from local
records, including cached server-selected memberships and summary snapshots.

| Upstream tile/section | BookSync disposition and local source | Backend boundary |
|---|---|---|
| Hero / Currently reading | Keep one large resume row, local last-opened first; cached reading rank plus local overlay. | Neutral; absent local position shows server percent without inventing a locator. |
| Also Reading / In progress / Pick back up | Merge into Currently reading → All reading, with Recent / Oldest first. Preserve server order ranks, then overlay local completions/rereads. | Neutral; local-only books remain visible. |
| Up next in series | Keep shelf; cached bounded server selection first, local completion overlay; Series page is the complete accessible inventory. Do not silently substitute a new recommendation algorithm. | Neutral slot; BookOrbit selection is adapter-provided. |
| Want to read | Keep cached server selection and locally pending intent; show “Saved selection” if capped. No invented complete See all. | Neutral status/shelf capability; unsupported adapters hide it with an explanation in settings. |
| Recently added | Keep first window of complete cached recently-added rank, See all paged locally. | Neutral when adapter supplies addition order. |
| Shelf / Discover / random | Keep one Discover section, drawing cached selected IDs; an explicit Shuffle chooses locally among eligible cached records. Distinguish “From saved library” from cached server recommendations. No network on shuffle. | Neutral local sample; BookOrbit's recommendation selection retained as source metadata. |
| Libraries / All books | Keep separate named libraries and All books; never assume a library means a user shelf. | Adapter scope identities; neutral display. |
| Collections / Smart scopes | Keep separate Browse indexes, memberships stored by opaque IDs; scope rules are never evaluated client-side. | Collections are neutral where supported; BookOrbit SmartScopes retain that name and capability. |
| Authors / Series / On device / Not on device | Keep; local membership/rank windows, device intersection and series/author grouping. Not on device explicitly says when coverage is incomplete. | Neutral; no extension of upstream's newest-500 promise without complete cache. |
| Search | Keep offline title/author search labeled “Saved library”; explicit server search is a capability and prompts to connect offline. | Neutral query; adapter-specific search support. |
| Finished in YEAR | Keep as **Finished** with all cached finished/recently-read IDs. A year picker is only offered with reliable completion dates; missing dates go in “Date unknown.” | Neutral. This avoids claiming a year filter the current link never applies. |
| Goal pace / streak / week / today / heatmap / calendar / hours / records | Merge into Reading summary and calendar, with drill-down cards. Cache aggregates and local pending deltas separately to prevent double counting. Mark “On this reader” versus “From server”; unknown history is unavailable, never zero. | Neutral presentation; BookOrbit aggregates remain snapshots with provenance, not a portable ledger. |
| Forecast | Merge into book detail: “Time left on this reader,” only with enough local rate data. | Neutral, optional; no fabricated duration. |
| Highlight / Year ago | Keep optional Reading cards only when cached authorized data exists. No history crawl during Home entry. | Capability-based; source and coverage visible. |
| Reading buddy | Keep one optional static, independently drawn monochrome buddy in Reading summary; based on today's known local minutes, no animation. | Neutral; no upstream art or pose code reused. |
| Clock / Sync / toggles / Light | Merge into header and menu: clock, battery, connection, Sync now, reading controls/frontlight when supported. Sync now is distinct from catalog Refresh. | Local platform controls; sync state from its active owner. |
| Word-of-day | Drop from Home: unrelated to selecting or tracking a book; no reliable offline source promised. | No backend dependency introduced. |
| Decor: analog clock, moon, odometer, glyph, rings, chapters, badge, dust | Drop duplicate clocks and ornamental tiles. Useful reading totals move to Reading summary; no copied graphics. | Local design choice; no arbitrary upstream widget compatibility. |
| Presets / custom four-page board | Replace with section ordering/hiding, not a board-layout import. Preserve old settings for rollback; show a one-time migration explanation outside reading. | BookSync setting, independent of backend. |

BookOrbit server selection order is authoritative for capped dashboard sources:
`B/server/src/modules/koreader/koreader-catalog.service.ts:372`.
Rows supply status/progress and cover/list metadata at `:1187`; manifests omit
rich fields at `:597`. The existing bulk plan preserves ordered sources and
hydration; Home consumes them rather than fetching detail for every tile.

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

**BookOrbit first:** catalog adapter normalizes the existing manifest/books,
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

## 8. Xteink parity and delivery slices after approval

X4 Pro and X4 Classic get the same Home/Browse/Reading, Series, Detail and action
semantics through Orbify's overlay. Xteink has no Android companion: the firmware
worker is the equivalent adapter boundary, reading SD canonical/index windows.
No SQLite requirement or new self-hosted service is imposed on firmware. X4 Pro
touch taps and Classic Select do the same thing; hold Select/More replaces long
press, Back cancels an active download, and page buttons navigate pages. A focused
row is outlined, with no reliance on gray alone. X4's compact Home shows one
resume row and two small shelves; remaining sections are reachable on subsequent
pages. Reading stats can be text/calendar rows with the same unknown-data rules.
Transfer progress stays in the row on X4 with bounded repaint frequency, no
full-screen modal forced over a book. Direct firmware adapter is BookOrbit first;
neutral server packages and Grimmory firmware remain the wider roadmap's phases.

X3 remains an explicit fit decision: 528×792, button-only, no PSRAM and near-full
flash. Do not promise an SD full catalog, rich illustrations or background
transfer alongside the reader. Preserve current screens until the 99.5% flash
gate, bounded parser/heap and network-boot recovery tests pass. If fit permits,
use text Home/Series/Detail with paged SD reads and progress in the network boot;
otherwise document the capability gap and keep current download/open. X3 is not
made backend-independent merely by changing a header.

Proposed slices: (1) adapter/read-model contract and BookOrbit read-only screens;
(2) single-book transfer/linking and detail/actions with the sole sync bridge;
(3) complete secondary-series view and next-N queue; (4) X4 touch/button parity
against the same cases; (5) X3 fit evidence and maintainer default-choice review.
Each requires approved design/mockups before code, then normal tests and device
acceptance by the maintainer before any release. No agents run device tools.

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
| Three pages, reorder/hide sections, no layout editor | Faster reading choices, smaller UI surface; old layout retained for rollback. |
| Finished label without a year by default | Truthful with current order source; year filter can follow reliable date coverage. |
| Tap opens/downloads; details on long press/More | The maintainer's requested fast path; discoverable hint and explicit Details on every menu. |
| Next N defaults to 3, one transfer at a time | Predictable storage/connection use; count and concurrency can change later. |
| Typographic covers and static optional buddy | Self-contained offline fallback and low refresh cost; original artwork can evolve. |
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
   owner, companion-mediated intents and no bulk replay of history? Any future
   writer takeover needs a checkpoint/backup review; rollback cannot unsend writes.
4. **Support commitment:** approve complete cached Home/Series/Detail on Android
   and X4 Pro/X4, with X3 explicitly conditional on measured fit, and Grimmory
   capability validation before enabling it? Do not promise universal direct-mode
   or X3 parity before evidence.

Maintainer also reviews the full inventory (especially dropped decor/layout
customization), offline prompt, series ordering, detail/actions and both device
mockups before changing status from designing. Draft PR acceptance alone does
not authorize implementation or a default flip.

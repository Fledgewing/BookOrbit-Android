# W26: Full refresh in minutes

Status: designing; implementation waits for approval of this shared plan and the UI
review below. Targets: Android under two minutes and X4 under ten minutes for 10,000
books. These are acceptance targets, not measured results.

This replaces the exhaustive list walk and eager details in Android's
`CacheWorker` / `CatalogPlan` and Xteink's `RefreshRunner` / `core/RefreshPlan`.
It preserves the complete offline browse inventory from
`shared/fixtures/catalog/sections.json` and the coverage work in #89.
It supersedes W9's eager-detail requirement, retaining its SD worker, storage
budget, Wi-Fi ownership and resumability. OTA and TLS are outside this change.

## Verified server contract

All upstream references below are relative to BookOrbit commit
`c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7` (the pinned v3.9.0).
The local checkout was verified at that commit.

| Fact | Pinned source |
|---|---|
| Manifest accepts size 200, opaque cursor, and scope filters. | `server/src/modules/koreader/dto/koreader-catalog-query.dto.ts:159-235` |
| Manifest enumerates by immutable book ID; a version change does not restart it. Contract changes return `restartRequired`. | `server/src/modules/koreader/koreader-catalog.service.ts:533-594` |
| Manifest carries id, title, author names, series name/index, formats and transfer files; no book-level dates, status, cover flag or series ID. | `server/src/modules/koreader/koreader-catalog.service.ts:597-669` |
| Books accepts size 100, sort, status, format, scope and IDs. IDs accept comma-separated values (up to 200); request batches of 100 with size 100. | `server/src/modules/koreader/dto/koreader-catalog-query.dto.ts:50-156` |
| Book rows carry series ID, status/progress, last-read and added/updated dates, cover flag and links. No detail request is needed for these. | `server/src/modules/koreader/koreader-catalog.service.ts:1187-1205` |
| Author/series index pages accept size 100; libraries, collections and SmartScopes return their whole index. | `server/src/modules/koreader/dto/koreader-catalog-query.dto.ts:260-304`; `server/src/modules/koreader/koreader-catalog.service.ts:435-448` |
| Section metadata includes author IDs/photos, series IDs, expected counts and member states absent from the manifest. | `server/src/modules/koreader/koreader-catalog.service.ts:967-1040` |
| Dashboard section endpoints select their own bounded ordered IDs; clients must preserve that order. | `server/src/modules/koreader/koreader-catalog.service.ts:372-432` |
| Library version hashes file/link/history state, not all book metadata or reading state. | `server/src/modules/koreader/koreader-plugin.service.ts:314-336` |

For 10,300 eligible books, complete manifest enumeration takes 52 requests (assuming
no failures or concurrent additions). The reported 24,744 Android requests and
85-minute Xteink estimate are input baselines; reproduce them with the benchmark
before claiming a measured improvement.

## One data model and fetch plan

1. Enumerate `/api/v1/koreader/plugin/catalog/manifest?size=200` to completion.
   Persist each page and its next cursor in one durable checkpoint. Deduplicate by
   ID. Use the same account, device and file variant throughout the run. Reject
   repeated/non-advancing cursors; handle `restartRequired` by discarding the staged
   generation and starting a new one, without dropping the published cache.
2. Save canonical book records plus separate membership/order records. Library
   means all manifest books; author membership uses author names. Series membership
   uses hydrated series IDs where available, with name selectors retained for
   legacy routes. Never merge two server series IDs solely because names match.
   Derive title, author, series-index and format views locally. Store once per book,
   never once per list/sort/filter combination.
3. Fetch root/Home/Discover and the three shelf indexes. Fetch author and series
   indexes once at size 100 for their non-derived metadata, retaining server IDs
   and summary fields; derive membership, counts and supported index variants
   locally. Do not crawl each author's or series' book list.
4. Fetch every library, collection and SmartScope membership using books size 100,
   all pages. These endpoints return rows, not an IDs-only projection; extract IDs
   and reuse their rich rows globally. Do not infer collection or SmartScope rules.
5. Fetch dynamic sources at size 100: Recently added, reading/Continue reading,
   Finished and the dashboard Want to read / Up next sections. Reuse identical
   sources across Home and browse. Fixed dashboard endpoints keep their server cap;
   adding an unsupported size parameter cannot enlarge them. Preserve returned
   selection order. See coverage and ordering below.
6. Collect missing rich-row IDs after reusing all fetched rows; fill by
   `/books?ids=<up to 100 IDs>&size=100`. Merge by ID, never response position.
   Account for omitted/deleted/inaccessible IDs and terminate without an infinite
   retry. Do not fetch per-book details during Full refresh.
7. Build local indexes and publish the completed generation. The previous cache
   remains usable while staging. Partial failures keep the old relevant list and
   report incomplete coverage; they cannot produce a successful completion stamp.

### Rich fields and ordering

The list-row enrichment set is `seriesId`, `progressPercentage`, `lastReadAt`,
`readStatus`, `addedAt`, `updatedAt`, `hasCover`, `thumbnailUrl` and `detailUrl`.
These support badges, date groups, cover decisions, navigation and the existing
sort/filter sheets. Title, authors, series name/index and formats come from the
manifest. `files` supports local copies and download selection without details.
Description, rating, tags, genres, publisher, ISBNs and related-detail sections
remain lazy detail data; do not fabricate them as a fully cached server detail.

Every book in All books can appear in a list row. Consequently complete offline
sort/filter behavior can require rich rows for the whole catalog, not just Home's
visible twelve. A cold upper bound for that hydration is 103 requests for 10,300
books, often already covered by Recently added and membership pages. Batch only
the remaining missing IDs. No per-book detail field is required by list rows.

Publication ordering is exposed by series lists but published dates are absent
from both manifest and rich rows. Fetch a global published-order ID sequence at
size 100 and store rank, then intersect with membership; verify tie behavior
against server responses. Date/status order is also server-defined: reuse global
ordered sources and verify local subset ordering and ties rather than assuming
`lastReadAt` alone reproduces it. Any mismatch becomes an explicit additional
ordered source, never an eager detail crawl. Record those costs in the benchmark.

### Recently added and offline scope

Home requests twelve books per shelf
(`koreader-plugin/bookorbit.koplugin/bookorbit_catalog_dashboard.lua:16-18,175-194`).
That is not the offline coverage limit: Recently added also opens a normal paged
list with no fixed top-N cap, and Not on device scans the newest 500 books
(`bookorbit_catalog_lists.lua:383-409,452-487`;
`bookorbit_catalog.lua:1187-1249`). Fetch all its size-100 pages and reuse those
rows for hydration; slice the first twelve for Home. Xteink consumes the same
canonical complete sequence and applies its own screen-size window.

Finished in YEAR is a UI label; its linked query is finished/recently_read with
no year predicate (`bookorbit_catalog_board.lua:994-1007`). Preserve that behavior;
do not add an invented year filter. Want to read and Up next preserve the bounded
server dashboard selection plus any separate list endpoint exposed on a platform.

Offline must serve every finite identity in `sections.json`, including combinations
of order, status, library, format, device IDs, author and series, plus letter jumps,
offsets and arbitrary UI page sizes. Search text remains outside this finite
coverage promise. Author biography/photo and detail-only metadata remain lazy;
previously fetched values stay available offline. An unseen detail screen can
show the cached title/authors/files and request its richer body when online.

## Incremental refresh and deletion

Start each new enumeration at the beginning; an old terminal cursor is not a
delta cursor. Checkpoint cursors resume only an interrupted run with the same
query/account/device identity. Compare complete manifest records, not only file
`contentVersion`: title or author changes need not modify file content. Reuse
unchanged records and indexes. Only a completed, valid enumeration can remove
missing IDs from published membership. A version change during enumeration is
not a transactional snapshot: retain old data until completion and schedule
reconciliation if concurrent changes leave the generation inconsistent.

Refresh dynamic lists and scope memberships even when manifest file versions are
unchanged. Refresh rich-row state through these sources and size-100 batches for
remaining IDs as needed for the complete offline promise; there is no proven
reading-state delta API. A matching library version alone cannot skip metadata
or reading-state work. Skip unchanged writes, index rebuilds, details and covers;
do not promise zero network requests for unchanged catalogs.

Invalidate cached details when observed metadata/file state changes, but refetch
only on demand. Covers remain a separate lazy, screen-size background queue under
the existing storage limit; Full refresh completion does not wait for every cover.

## Platform implementation

Android: network/JSON/derivation/writes run in the companion worker. Add canonical
manifest and membership/rank storage to SQLite, and answer existing list-window
identities from those indexes. The plugin submits the plan and reads small cached
windows. Preserve reading gates, bounded database waits and worker version checks.

X4 Pro/X4: retain #93's global worker and SD budget/checkpoint ownership. Stream
manifest pages and rows into SD records and disk indexes; keep page-sized buffers
and window-sized reads. Do not retain 10,000 rich JSON objects or all list identity
combinations in RAM. A size-200 manifest includes files and may be substantially
larger than 200 list rows: measure peak heap and parser limits before enabling it.
Keep the old published generation on cancellation, no network, SD failure or
storage-limit exhaustion. The worker must not take focus during reading.

X3: remain gated unless all required builds fit under the existing 99.5% gate and
RAM/parser tests pass. The cited 98.7% is an input, not a fresh measurement.
No OTA/TLS code or configuration changes.

## UI review (both platforms)

The existing screens and controls retain their layout. These text mockups show
the observable states to approve; percentages are illustrative, not timing claims.

```text
Catalog                              37%
Continue reading
Recently added
Library / Authors / Series / Shelves

Catalog                              Done
[Every browse list works with network disabled]

Book title
Author · Series 2
[cached files / existing download controls]
[richer description appears after an online detail fetch;
 previously fetched details remain available offline]
```

Only a manual Full refresh shows existing progress/completion feedback. Progress
is monotonic and stays below 100 until all required data/indexes are published;
discovery cannot cause a backwards jump. Preserve existing pause/error labels and
silent incremental behavior. While reading, only existing permitted indicators
may update; no new popup or focus change is introduced.

## Shared fixture, verification and performance evidence

Add synthetic fixtures under `shared/fixtures/catalog/bulk-refresh/`, registered
in `REGISTRY.json`, consumed by JVM and C++ tests. Include cursor pages, rich rows,
dashboard selections, overlapping scopes and expected ID sequences/windows.
Cover duplicate series names with distinct IDs, fractional/null series indexes,
multiple authors/files/formats, missing IDs, timestamp ties, status changes,
metadata-only updates, additions/deletions, restartRequired, repeated cursors,
interruption and publication failures. Keep the existing section inventory as
the coverage authority; extend its behavioral coverage to Xteink.

Generate a deterministic 10,300-book benchmark from the fixture schema. Both
implementations must run the same catalog shape and expected browse windows.
Reject any per-book-detail or cover request during the catalog phases. Disconnect
the fake transport after publication and enumerate all supported list identities
and windows, including later pages and filters, asserting expected contents and
zero network calls. Test lazy detail requests and persistence separately.

Log each phase's requests, received payload bytes and monotonic elapsed seconds:
manifest, section metadata, memberships, dynamic selections, missing-row batches,
ordering sequences, local indexing/publication. Include failures/retries and a
total; covers/details log separately. Never log credentials or response bodies.
Compare cold, unchanged and changed runs. Record JVM and simulator measurements,
peak memory and SD bytes. Do not present request arithmetic as measured results.

The base enumeration is 52 requests. A complete Recently added traversal is 103
requests and can supply all rich rows. Other membership/ordering/section work adds
to that total; its cost depends on scope count and overlap. This is hundreds of
requests for ordinary libraries rather than tens of thousands, but no universal
request cap is possible with arbitrary server-defined scopes.

Estimate real-device time from measured phase request counts and bytes, separately
accounting for request latency, throughput, parsing and SD/SQLite work. Publish
assumptions and uncertainty. JVM/simulator results cannot establish that the real
device targets pass. The maintainer tests the eventual workflow artifacts on USB;
agents use no devices and publish no releases/tags.

## Delivery

Based on #93 while open; rebase onto main after its merge before final delivery.
After design approval, implement and validate Android and Xteink against the same
fixtures, with separate PRs if useful. Run the touched tests and component suites;
merge origin/main before each push and merge only when all checks are green.
Move W26 into FEATURES only as each platform actually ships; keep pending platform
status explicit. Clean up only clean worktrees and merged branches.

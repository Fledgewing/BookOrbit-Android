# F12-Q2 catalog transport migration

Status: **covers and mirror/store cutovers implemented; remaining catalog cutover incomplete**. The legacy
Lua catalog adapter and its callers are still present. The maintainer authorised
merging this prerequisite as step 1 of 5; it does not complete the server-free
plugin slice.

The library now exposes an explicit `acquireCover(key, callback)` command and a
one-row `cover(key)` snapshot. `ServerAdapter.acquireCover` resolves an opaque key
against the captured sync account and queues work on the existing cache writer.
The companion uses account-scoped cover folders; an old account's file cannot
satisfy another account's request. Account folders participate in the existing
storage counter and eviction path. The companion imports existing local cache hits
without network access; unsupported adapters return an explicit unsupported result.
The parent thumbnail worker dispatches bounded batches of four references through
the library, including author portraits. Forced refresh uses the same command.
`cache.lua`, its direct HTTP/fallback downloader and `cover_child.lua` are deleted;
the catalog interpreter/mirror have since moved into the companion (step 3 below). No replacement sync writer is activated.

Reuse: `ko/library.lua:161` owns paint counters, `ko/store.lua:29` owns generic
local reads, `LibraryReadModel.kt:29` owns bounded snapshot publication,
`CacheWorker.kt:468` owns cover naming, and its existing `fetchCover` owns
conditional transport, response limits and thumbnail processing. `CoverProtocol`
normalizes the saved native server base; newly admitted image bytes invoke the
existing storage policy on the companion, while hits perform no folder scan. Acquisition adds
no executor, database or HTTP implementation. A snapshot reads one saved local
reference, never an image body or a server reply. An explicit acquisition may seed a pristine
projection namespace when catalog caching is off; it never adopts existing
catalog data or changes an existing owner. Ownership races retry at most twice
from the deferred worker, and departure cancels those retries. The existing caller budget
applies: zero render network/subprocesses, at most one batch per Home paint and
at most 16 KiB per widget. Acquisition logs a timing span; host timings do not
establish device acceptance.

Cache hits need no network. A revision change conditionally validates an older
file without removing it. Offline failure returns the older local reference;
failed revisions remain eligible for retry. Results contain no credentials or
server locators. Every reference command carries its originating opaque owner. Managed credentials
are captured for that owner; the legacy settings lookup must match it exactly.
A queued command cannot adopt a later account's credentials. Account mismatch is
rejected before transport.

Remaining required work:

- Move copies, recommendations and end-of-book state and
  queues behind neutral companion operations and snapshots.
- Replace legacy query/grouping callers and remove the remaining scoped Lua files.
- Preserve the cross-slice end-of-book hold and event-watcher contracts used by
  F12-Q until both sides are switched and tested.
- Strengthen the plugin Lua boundary guard after those callers are gone, and
  exercise the plugin against a toy adapter with no server/plugin dependency.

No default change, device operation, release, tag, legacy queue deletion or
claim of shipped feature coverage is included.

## Step 2 source and performance evidence

Pinned BookOrbit `c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7`:
`koreader-plugin/bookorbit.koplugin/bookorbit_catalog_thumbnails.lua:368` forks for
thumbnail batches; `:391` selects book covers versus author portraits; `:199` owns
versioned cache references. The adapter now intercepts these paths before that
worker runs. Its low-level download methods can return only a saved local hit.
Native account data comes from `G_reader_settings` (`main.lua:145` at that pin);
the companion extracts only the literal account table using the existing safe
tokenizer in `StatusMarginRepair.kt:49`. It neither executes settings nor imports,
changes or drains any sync/lifecycle queue. Account mismatch fails before IO or
transport; saved credential data is never sent by a cover command.

Every lookup inherits `cover-cache`: one row, at most 16 KiB decoded, zero network,
subprocesses and companion round-trips. It logs its library read/paint spans.
Acquisition runs from the existing post-paint timer, in windows of four, and logs
worker timing. Reference metadata retains only 64 entries and verifies the exact
reference as well as its hash; account changes isolate the entire projection. No directory enumeration or image writes remain in plugin code.
Host timings are not device acceptance. Android-first implementation remains the
maintainer's ruling; firmware cover transport is deferred to its own cutover.


## Step 3: mirror and store

The adapter `mirror.lua`, `store.lua` and `library_bookorbit.lua` are deleted. Refresh
planning extends `CatalogPlan.kt`/`MirrorLogic.kt`; its inventory is checked against
`shared/fixtures/catalog/sections.json`. Commands use the existing server queue and
`AdapterWorker` cache writer, and execution reuses `CacheWorker`/`FastCatalogRefresh`
and `BulkCatalog`. Cached query windows reuse `CacheStore.read`; offline search moved
into that same store over its existing search column. `LibraryReadModel` publishes the
neutral windows; `ko/store.lua:149` remains the one-row reader. The transport binding
is co-located with the owned `ko/library.lua` interface, replacing its backend-only file.

Native catalog fetches no longer fork or fall through to upstream catalog HTTP.
They read ready display records and convert them to existing widget inputs inside
the connector. Native Home uses one bounded bundle. Offline reads never ask to connect;
background publications redraw only the visible matching context/account. A one-row
`catalog-refresh` budget caps progress at 16 KiB, zero network/forks/round-trips. Every
nested Home book/name and the stats row is charged. New calls/paints and companion
control/projection work retain info-level spans; host times are not device acceptance.

`catalog.control` carries only an opaque originating owner, action and manual flag.
The companion captures credentials privately and builds/stores its plan itself. The
credential-bearing `MIRROR`/`CHECK` broadcasts are retired. Full-refresh repeats retain
the run; failed bulk runs resume; storage pressure does not start an automatic retry
loop. Ownership changes stop an active catalog writer before reassignment; status
snapshots require a matching checkpoint owner. Private plans carry a separate server
locator so managed opaque IDs can never be mistaken for URLs.

Reuse/source evidence: `LibraryReadModel.kt:29` bounds publication; `CacheStore.kt:200`
windows existing rows; `CacheStore.kt:240` interprets saved protocol queries only in the
companion; `CacheWorker.kt:1001` retains the existing bulk runner/checkpoints. Pinned
BookOrbit `c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7` uses the fork in
`koreader-plugin/bookorbit.koplugin/bookorbit_catalog.lua:881` and connects before native
catalog loads at `:924`; both paths are replaced for bounded catalog reads. Native detail
queries are defined in `bookorbit_api.lua:737`; query templates now stay in Kotlin.

The removed Lua interpreter/transport flow tests are replaced by companion fixture
coverage (`CacheStoreTest`, `FastCatalogTest`, `CacheWorkerTest`, `CatalogControlTest`)
and focused Lua interface tests. The SQLite lock/page-turn, covers, reading gate,
installer, sync and remaining legacy feature tests stay in the plugin harness.
Small compatibility hooks preserve the still-owned copies queue and the parallel
sync worker's watcher contract; no copy, finish or lifecycle queue is truncated or
retired. Grouping's old aggregation, copies, recommendations and finish operations
remain for steps 4–5. Android-first remains the maintainer's ruling; firmware
implementation is deferred. No devices, releases or tags are involved.

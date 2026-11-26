# F12-Q2 catalog transport migration

Status: **cover cutover implemented; remaining catalog cutover incomplete**. The legacy
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
live non-cover caching/events remain in the existing catalog `store.lua` for the
following steps. No replacement sync writer is activated.

Reuse: `ko/library.lua:20` owns paint counters, `ko/store.lua:29` owns generic
local reads, `LibraryReadModel.kt:29` owns bounded snapshot publication,
`CacheWorker.kt:468` owns cover naming, and its existing `fetchCover` owns
conditional transport, response limits and thumbnail processing. `CoverProtocol`
normalizes the saved native server base; newly admitted image bytes invoke the
existing storage policy on the companion, while hits perform no folder scan. Acquisition adds
no executor, database or HTTP implementation. A snapshot reads one saved local
reference, never an image body or a server reply. The existing caller budget
applies: zero render network/subprocesses, at most one batch per Home paint and
at most 16 KiB per widget. Acquisition logs a timing span; host timings do not
establish device acceptance.

Cache hits need no network. A revision change conditionally validates an older
file without removing it. Offline failure returns the older local reference;
failed revisions remain eligible for retry. Results contain no credentials or
server locators. Account mismatch is rejected before transport.

Remaining required work:

- Move mirror planning/refresh, copies, recommendations and end-of-book state and
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

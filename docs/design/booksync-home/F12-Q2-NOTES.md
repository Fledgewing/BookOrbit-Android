# F12-Q2 catalog transport migration

Status: **cover-command prerequisite only; catalog cutover incomplete**. The legacy
Lua catalog adapter and its callers are still present. This change must not be
merged or described as the completed server-free plugin slice.

The library now exposes an explicit `acquireCover(key, callback)` command and a
one-row `cover(key)` snapshot. `ServerAdapter.acquireCover` resolves an opaque key
against the captured sync account and queues work on the existing cache writer.
The companion uses account-scoped cover folders; an old account's file cannot
satisfy another account's request. Account folders participate in the existing
storage counter and eviction path. Existing installed legacy cover folders have
not been imported. Unsupported adapters return an explicit unsupported result.

Reuse: `ko/library.lua:20` owns paint counters, `ko/store.lua:29` owns generic
local reads, `LibraryReadModel.kt:29` owns bounded snapshot publication,
`CacheWorker.kt:468` owns cover naming, and its existing `fetchCover` owns
conditional transport, response limits and thumbnail processing. Acquisition adds
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

- Replace the thumbnail subprocess caller with parent-owned neutral dispatch;
  no JNI is safe inside the fork. Preserve installed cover-cache hits/offline use.
- Move mirror planning/refresh, copies, recommendations and end-of-book state and
  queues behind neutral companion operations and snapshots.
- Replace legacy query/grouping callers and remove all eight scoped Lua files.
- Preserve the cross-slice end-of-book hold and event-watcher contracts used by
  F12-Q until both sides are switched and tested.
- Strengthen the plugin Lua boundary guard after those callers are gone, and
  exercise the plugin against a toy adapter with no server/plugin dependency.

No default change, device operation, release, tag, legacy queue deletion or
claim of shipped feature coverage is included.

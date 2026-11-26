# Complete SD catalog on X4 (W9)

Approved scope: the user's W9 implementation brief and explicit rulings on SD storage,
Android Wi-Fi parity and continuing a Full refresh while navigating Home/catalog/reader.
X4 Pro and X4 Classic have PSRAM and ship this path. X3 retains its existing catalog;
`CROSSINK_TAILNET_ORBIFY_MIRROR` and `CROSSINK_TAILNET_ORBIFY_CACHE` remain off there.
No OTA verifier, TLS trust or BookSync position sync decisions change.

## Work and memory

The main loop schedules `RefreshRunner` on a FreeRTOS task with its 16 KiB stack in
PSRAM. The main task reaps the suspended worker with the matching capability-aware API. It never draws, changes an
activity or takes input. Navigation observes a small mutex-protected snapshot. A catalog
activity's `Walk` attaches to that snapshot; exiting it cannot stop the worker. An active user-requested walk defers automatic sleep without pretending there was user input.
Manual sleep cancels and joins the worker before SD shutdown, retaining its checkpoint for wake.

A new explicit run renames its previous journal generation in constant time; old
markers are removed afterward, one file at a time with cancellation checks. Sleep
never waits for a whole-directory delete. Account edits quiesce the worker before
shared credentials change and discard the previous account's pending inventory. Three append journals on SD contain enumeration, remaining book pages and deduplicated
book details. The walker reads one bounded record and one response page at a time; it
never builds a library-sized vector. Dedup markers and cached replies use sharded SD
directories. Every catalog response streams through the existing downloader to CacheStore.
Filtered catalog JSON documents use the existing X4 PSRAM allocator; author/series
requests use 20-row pages rather than the server's 60-row default. This keeps the
transient strings and vectors small. Large cache-hashing documents use PSRAM too and every worker request checks
OrbifyHeap's internal-heap floor. Saved foreground reads bypass the network mutex and have
per-task cache modes, so the worker's Full mode cannot turn a foreground hit into a fetch.
Network requests and connection creation/destruction are serialized around the existing
client's shared temporary path and kept connection.

Enumeration reads the root, every facet page, and the first page of each linked book list.
Each book scope includes all five X4 sorts, both directions and all four read-status
choices, including the author list's default spelling; shelves keep their fixed server order.
The first page supplies totals and page size; every subsequent page is queued. All-books
supplies the distinct detail count before the data phase. Data pages queue book IDs once,
across lists and resumes, without changing the denominator. Enumeration displays 0%; the
data phase uses the fixed denominator and a persisted high-water percentage. A server-side
library mutation during a run can change how many IDs actually exist; errors are retained
and never retried indefinitely. A subsequent explicit Full refresh starts a new inventory.

Pinned source: BookOrbit `c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7`,
`server/src/modules/koreader/koreader-catalog.service.ts:461` (book paging), `:490`
(total/size response), `:968` and `:1005` (author/series totals and pages), `:1050`
(facet page envelope), `:730` (details). CrossInk
`87e2e1984481e8a3d996f12b34b50a383f9013b8`,
`src/network/BookOrbitCatalogClient.cpp:522` (facet browser request) and `:463`
(book browser request). These are source lines before applying BookSync's overlay.

## Storage and final state

The schema is the source of choices and defaults: `storage_limit_mb` defaults to 250 MB
and includes 100/250/500 MB, 1/2.5/5/10 GB and No limit. PlatformIO generates the C++
choice table from `shared/settings/schema.json`; byte arithmetic is 64-bit. Settings ›
BookOrbit has Storage limit, Wi-Fi and Off after idle rows beside the catalog settings.
Books themselves do not count. Cached JSON, SD metadata/journals and Home/sleep cover files count toward the
budget; a 16 MiB card safety reserve applies even with No limit.

The old 150-request, 20-facet-row, 30-detail, 200-cache-entry and 2 MB eviction limits no
longer constrain a Full refresh. Per-reply CRC sidecars live on SD; the previous small
index migrates once. Successful cached reads neither evict nor revalidate saved pages.
Storage exhaustion keeps all successfully stored replies, persists a terminal result and
removes the request marker. It cannot restart at sleep, wake or the next main-loop tick.
The final message is `Stopped at storage limit: N of M saved — raise it in Settings`;
SD exhaustion instead names the SD card. A stop during the 0% enumeration phase
labels the inventory incomplete: the final discovered count is a lower bound, not
a claim that every list has already been counted. Settings retains that result, and the refresh
screen wraps it. An explicit Full refresh after changing storage starts a new inventory.

The incremental path follows main: an already-connected sleep sync fetches the
recently_updated head. SD reverse references locate only affected saved pages; changed
metadata is merged locally and only details whose updatedAt changed are fetched. It never schedules
a Full refresh or fetches every saved list merely because a cache is old.

## Wi-Fi and verification

The policy follows Android `logic/wifi_plan.lua`, `ko/wifi.lua` and `ko/net.lua` on main.
All three modes permit requested open/wake/sleep, reading and genuine miss flows. A saved
page never connects. `always_on` restores a previously-off radio after its flow;
`off_reading` also turns it off while reading and restores its pre-book state on closing;
`jit` also turns it off after the chosen 1/2/5/10 idle minutes (default 2). Holds defer off
until every owner releases, with Android's three-second grace. Off work runs on a worker,
so the Wi-Fi driver's delays cannot block main-loop input. The hidden sleep sync
releases its last hold and turns the radio off before local cover decoding and SD shutdown. BookSync position sync moments and decisions
are unchanged. Lua and C++ read `shared/fixtures/wifi/policy.json` for connection decisions.

Host tests cover paging beyond the former cap, detail deduplication, fixed progress,
checkpoint restore, 64-bit budgets, unlimited storage and the card reserve. Simulator tests
exercise the real server, a refresh started on Home, offline last-page reads, and a forced
SD-full terminal result. `run.py --proxy-port 0` gives parallel workers separate proxy
listeners. A simulator's scripted free-space report changes no real disk.

Logs report pages saved, saved work/total, SD bytes, elapsed time and actual HTTP requests
per second. The final estimate for 10,300 books scales the measured run by its all-books
count. This includes the measured library's facet/list overhead; a different distribution
of authors, series and collections changes the estimate. Simulator throughput measures
local HTTP and host storage; device TLS, SD and Tailscale performance still need the user's
test build check before release.

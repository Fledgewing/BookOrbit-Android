# F12-Q: companion-owned Android sync

Status: the Android plugin's **sync path is server-free** on feature/0.12. F12-Q2
owns the remaining covers/catalog/mirror/copies/recommendations/end-of-book cutover.
This is source implementation, not a release or device acceptance claim. Xteink
remains deferred under the maintainer's Android-first authorization.

## Existing modules extended

Reuse anchors from the prerequisite commit 71f7fc5d: the neutral library command
boundary (`android/koreader/orbit.koplugin/ko/library.lua:134`), serial companion
worker (`android/companion/app/src/main/java/net/fledgewing/orbitcompanion/LibraryAccount.kt:42`),
`ProgressOutbox` and its existing `Sql` transaction / `LuaValue` ports. The queue
facade now delegates to `LifecycleQueue`; it is not another writer. Existing reading
cadence (`logic/schedule.lua`) and Wi-Fi leases (`logic/wifi_plan.lua`) still govern
native lifecycle work. The pure position policy reuses the shared fixture contract
at `shared/fixtures/orbismart/cases.json`, now exercised against `PositionPolicy.kt`.

The library adds only neutral `sync.*` commands and one pure preview operation.
`SyncOwner.kt` serializes policy, consent, per-document marker/override/decline state,
account-scoped capture, retry and delivery on the existing companion executor.
Backend routes, credentials, JSON and legacy source formats stay in
`server/bookorbit/BookOrbitSync.kt`, `LegacyLifecycleImport.kt` and the adapter binding.
The plugin's `ko/position_sync.lua` captures native locators and bounded geometry;
`ko/reading_sync.lua` owns native lifecycle scheduling and the one-draw consent UI.
No sync request or backend response parsing remains in the plugin.

## Writer retirement and migration

`ko/server/bookorbit/quiesce.lua` is migration-only: it disarms the installed legacy
class and API before instances initialize. Unknown startup ordering refuses activation.
It never invokes the retired transport. The companion requires this retirement
handshake before importing or sending anything. KOReader's built-in sync is unchanged.

Pinned upstream `bookorbit` at c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7 stores
five independently acknowledged phases: match, stats, annotations, state and progress
(`koreader-plugin/bookorbit.koplugin/bookorbit_lifecycle_outbox.lua:33`). Its loader
validates metadata and payload generations (`:183`); capture timestamps are preserved
by `bookorbit_api.lua:582`. The importer selects the newest valid generation, falls
back on damaged newer generations, and imports the entire immutable snapshot plus
all phase acknowledgments and pending remote applications. Pending applications reopen
their phase even when its original exchange was acknowledged.

Every job has an adapter and opaque sync-account namespace, distinct from catalog
ownership. Per-account legacy state proves ownership where available; ambiguous or
corrupt sources remain untouched for recovery. Import checkpoints, source hashes and
payloads commit in one SQLite transaction **before** any source file moves. Originals
then move into `booksync-retired-lifecycle`; interrupted individual renames resume
from the checkpoint. Imported jobs cannot drain before retirement completes. Tests
inject crashes before and after checkpoint, during retirement and after retirement.

The companion imports prior marker/override/decline state and known rating/review
state without overwriting newer owned records. It keeps positions and timestamps
immutable across retries, consumes overrides once, rejects stale consent and isolates
accounts. Every shared policy fixture passes, including resets, rereads and behind-hold.
A crash after delivery but before acknowledgment can replay a request; exactly-once
server delivery is not claimed. Proven old-account rating/review history is imported
under its own namespace too, preserving explicit clears when a different login is active.

Custom direction preferences are translated inside the companion adapter, including
values saved before the automatic preset. The single owner preserves Keep, prompt and
lifecycle-push decisions; scheduled prompt checks stay quiet. A known silent placement
can run before the first draw; after draw it uses the approved one-draw consent rather
than a hidden jump. Native code sends only the selected mode and geometry.

Annotations and book-state changes wait until the document closes before writing its
sidecar. Closed-file writes precede acknowledgments. Native xpointer verification uses
one small companion row per callback; its durable queue survives restarts. Malformed
sidecars are retained rather than overwritten. Statistics use bounded 256-row windows
with a composite cursor, preserving rows sharing a timestamp. Network and sidecar work
run off the reader thread. Close capture occurs on CloseDocument, before KOReader
clears its document (`koreader` 9192014d, `frontend/apps/reader/readerui.lua`).

## Performance and parallel boundary

The strict screen/widget rule remains binding: every screen/widget has a row and byte
budget, no render-path network or subprocess, at most one batched companion round trip
per Home paint and at most 16 KiB per widget snapshot. Consent and native verification
have named one-row / 16 KiB budgets in `logic/budgets.lua`, with info timing spans.
The synchronous prerender preview reads an immutable in-memory publication; it does no
SQL, network or disk IO. Old-path previews for the same document are invalidated
when another path updates its state, and delayed captures cannot claim the current
reader's sidecar lease. Cached position files are bounded to 16 KiB. Commands and drains
log milliseconds. Host timing is not device acceptance; the maintainer's device targets
remain pending confirmation.

The journal holds at most 1,000 pending jobs and reads windows of 24. Legacy payloads
have a 200 MiB safety cap and remain companion-private; they never reach the reader.
Private decision records are bounded to 64 KiB; public projections are at most 16 KiB.
Offline capture commits before transport, and a companion restart repeats the retirement
handshake without losing the journal. Home paints gain no sync call.

The five retired Lua implementations (sync, reading_sync, lifecycle, orbismart,
localfirst) are deleted. The latter's unrelated cached catalog display helpers survive
as `ko/server/bookorbit/local_view.lua` for Q2. Neutral middleware event hooks bridge
its existing jobs without adding any sync transport. The boundary guard rejects retired
sync primitive calls and sync routes in **every** plugin Lua file, including adapter
files. Companion toy-adapter tests exercise capture, restart, decisions, delivery and
account isolation without using the production backend.

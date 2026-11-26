# Backend independence

Status: Android implementation authorised on 25 November 2026 on `feature/0.12`.
The maintainer explicitly approved the widget system and Android-first delivery. This covers
its adapter boundary; portable ledger, new backends and firmware remain later phases with
their existing design/approval requirements. The [roadmap](../../ROADMAP.md#planned-backend-independence)
records the order below.

BookSync is on a journey to backend independence. Readers should work with whichever library
server the user chooses (BookOrbit first, Grimmory as the second acceptance backend, others
later), and the user's reading (positions, history, highlights, ratings and shelves) should
move with them between servers. The steps: own the KOReader client and keep BookSync's own
copy of read state; serve compact per-device packages from an optional BookSync server; move
backend-specific code behind adapters; bring the Xteink readers along. The server stays
optional: direct mode remains available.

## Phases

### 1. Owned Android client and ledger

Design the owned KOReader plugin and required companion **together with** the read-state
ledger; there is no separate ledger-first implementation phase. The plugin owns UI and small
lifecycle/locator captures. The companion owns network, parsing, scans, file writes, durable
queues and local ledger storage. Preserve the reading gate, caller trust and existing position
policy ([shared cases](../../shared/fixtures/orbismart/cases.json)).

Keep BookSync's own positions, status/reread attempts, sessions, highlights/annotations,
ratings and shelves, with provenance, stable event IDs and deletion records. Separate durable
history/outboxes from the disposable catalog. Open export should use a documented, versioned
manifest plus UTF-8 JSON Lines, checksums, typed locators and preserved unknown fields; exclude
credentials and retain original sidecars/import backups. Export must be readable without BookSync.

BookOrbit and Grimmory are acceptance backends from the first adapter design. Direct Android
mode uses companion adapters behind a neutral model, without a local HTTP daemon. Import only
available, authorized history and report gaps. Migration backs up first, previews mappings and
uses one active sync writer. Unsupported history remains in BookSync; do not promise lossless
position/highlight conversion across editions or backend schemas.

### 2. Server first API: catalog packages

Deploy BookSync as a **self-hosted container from the start** (Kubernetes or Docker).
Its first API serves authenticated **per-device catalog packages**: a scoped manifest,
immutable/resumable catalog chunks and profile-sized covers, initially consumed by Android.
Packaging and refresh scheduling belong inside the service; there is no separate cron or
standalone packaging job. Initial backend ingest is read-only adapter work, not shared-ledger sync.

Design Android, X4 and X3 profiles together. Scope packages and assets on the server, validate
bounds/checksums, and install complete generations atomically without replacing pending local
state. Measure cold ingest separately from warm delivery, metadata separately from covers.
Keep encoding and server language experimental until measurements justify them.

### 3. Shared ledger and backend adapters

Extend the service with the durable shared ledger/event API and BookOrbit + Grimmory read/write
adapters. Keep backend endpoint/auth/status details out of server-mode clients. Acknowledge events
only after durable commit, deduplicate retries and track backend projection separately from
BookSync acceptance. Preserve per-account isolation, conservative identity matching, explicit
conflicts and unknown-delivery reconciliation. Maintain open export, durable volume backups,
separate secret recovery and a tested restore with newer client queues.

Direct mode stays supported. A server outage means cached reading and queued events; changing
to direct mode is an explicit checkpointed transition, never automatic fallback to a second
state authority. Backend permissions and capabilities remain binding; service placement grants
no additional access ([server contract](../server-contract.md#app-attestation)).

### 4. Xteink clients

Add the neutral package/event client for X4 Pro, X4 and X3, preserving everything each device
can supply. Use bounded streaming/index access and durable SD queues; do not require a full
catalog in RAM. Validate simulator power-cut recovery, flash/heap budgets and authenticated
transport before committing to parity. A separate X3 server firmware profile may remove direct
backend code to fit; direct firmware remains available. Server installation alone does not
make existing firmware backend-neutral. Maintainer-run device acceptance still precedes release.

## Six one-way decisions

These recommended answers are **proposed**, not approved commitments. Internal route names,
codecs, storage layout and implementation language can change during experiments.

| Decision | Recommended answer (proposed) |
|---|---|
| 1. Who owns history, and how much is retained? | **Proposed:** BookSync retains portable state/events in every mode; keep sessions and meaningful transitions by default, optional raw page history, with explicit retention/deletion policy and account isolation. Uncaptured/deleted history cannot later be reconstructed. |
| 2. Which identity/locator guarantee is durable? | **Proposed:** permanent BookSync UUIDs, namespaced aliases and exact file-revision hashes; confirm ambiguous edition matches. Preserve raw locators without promising exact cross-edition placement. |
| 3. Which code provenance and licenses ship? | **Proposed:** independently authored implementations, no backend code/assets copied into BookSync; audit reuse and record provenance. Retain AGPL Lua and MIT companion; propose MIT for independent server/adapters, with license review before distribution. Keep backend insurance archives separate. |
| 4. May migration write external history? | **Proposed:** import/read and dry-run first; private backup and explicit target/per-field selection before writes. Preserve unsupported/lossy history locally; no blind replay of sessions or state. |
| 5. What service-free support is promised? | **Proposed:** keep direct BookOrbit mode and validated direct Grimmory on Android; publish hardware-specific capabilities. Do not promise dual-backend direct X3 parity before measuring fit. |
| 6. When is protocol/export v1 frozen? | **Proposed:** only after BookOrbit, Grimmory, Android and an X3 prototype pass common identity/state/error cases. Thereafter preserve archive readability and document client compatibility/migrations. |

## Cheap experiments before approval to build

Use synthetic fixtures and isolated services; these are proposed experiments, not completed work.

| Experiment | Evidence / decision |
|---|---|
| Enumerate a synthetic 10k catalog through both adapters; compare basic/rich fields, collections, request counts and cover bytes. | Establish direct-mode baseline and cold-ingest versus warm-package benefit; avoid adopting unverified performance claims. |
| Test minimum-permission history import and write/read round trips on both backends, including timeout after commit. | Capability gaps, auth renewal, side effects and duplicate-session risk; no live data required. |
| Round-trip identity/export/events: changed editions, stale reader, reread, deleted annotation, clock skew and repeated upload. | No lost or double-counted history; unknown records survive and ambiguous matches remain unresolved. |
| Generate Android/X4/X3 sample packages; prototype X3 parser/transport with direct backend excluded. | Measure wire size, decode RAM, linker maps, flash margin and cover quality before choosing codec/profile. |
| Revoke scope during package generation; interrupt generation commits; restore an older server with newer device queues. | No unauthorized old assets, destructive empty-library inference or lost unacknowledged events. |

Each phase needs its own acceptance review. No mirrors, jobs, deployment, devices or upstream
changes are created by this documentation change.

## Android adapter enforcement (F12-L)

`ServerAdapter` is the worker-facing contract. It covers capabilities, bounded catalog
windows, manifest, detail/covers, download jobs, progress/status, lists, statistics, account
and connector credentials. Unsupported projection operations return `error=unsupported`;
unsupported account commands raise neutral `ServerFailure("unsupported")` and clear secret
inputs. Capability flags determine UI availability. Do not advertise an operation just because the interface
has a method. The cached catalog projection retains read-only detail/status and no list-write action.
Native sync and OPDS commands use the account session and advertise their actual connector
capabilities; unavailable operations retain explicit errors, avoiding a second sync writer.

`LibraryReadModel` owns bounded publishing, owner checks, the existing `library_views`
table and per-call timing. It depends on `ProjectionStore` and `ServerAdapter`, not a server
implementation. The existing `CacheStore` implements that persistence seam within the
adapter; the existing catalog, bulk/mirror worker and normalizer moved there without a
second database or HTTP client. ReadingStats aggregation/merging and LibraryFacets remain neutral. The bounded `sources` operation returns at most six neutral names/counts; server-section
translation and current-book exclusion stay in the adapter. Cached server statistics
cross `ServerAdapter.cachedReadingStats` as `RemoteReadingStats`, never backend JSON; the
publisher shares one lazy combined aggregate per batch. `CachedListProjection` owns the legacy
sleep picker's cached-section translation; shared picker code receives `SleepChoices` and
uses the neutral label Lists. Backend terms and authentication headers are guarded too.
`ServerAdapters.kt` is the sole Kotlin composition root. It also constructs the native
account session through `ServerAdapter`; `LibraryAccount` never imports an implementation
and reports only neutral `ServerFailure` codes. Native authentication, sync/OPDS credentials,
provisioning and raw account-stat normalization live inside the adapter. Shared encrypted
storage and `AccountStats.combine` process only neutral values. Worker command routing, connector
installation and cover setup use neutral service contracts; their protocol implementations
are under `net.fledgewing.orbitcompanion.server.bookorbit`.

To add an adapter:

1. Implement `ServerAdapter` under `server/<id>` and normalize all server fields there.
   Preserve account namespaces and opaque keys; do not coerce another backend's keys to
   the first adapter's numeric IDs. Return explicit unavailable/error states.
2. Register its factory in `ServerAdapters.kt`; supply its persistence and worker services
   at that composition root. Do not import implementations into screens or projections.
3. Publish only supported capabilities and gate UI through the library interface. Add
   independent fixtures and contract cases like the fake and acquisition-only test adapters
   in `ServerAdapterTest.kt`. Never reuse the shipping adapter's fixtures to prove neutrality.
4. Run `python3 tools/test/test-server-boundary.py`, both Lua harnesses and companion tests.
   The guard scans every production Kotlin/Java/Lua source, strips comments while preserving
   strings, rejects protocol fields/routes and implementation imports, and tests its own
   rejection behavior. There are no frozen baselines or suppression annotations. The CI
   plugin-test action runs it explicitly; the existing Lua harness invokes it too.

The same guard scans production resources and shared Settings/UI definitions. About credit
prose may name the credited project; routes and protocol fields remain forbidden there.
The Settings schema uses a neutral `server-home` choice. Each client binds that choice through
the existing adapter Home key when loading the schema, preserving installed wire values.

Every screen/widget keeps its declared budget in `logic/budgets.lua` / the registry.
Adapter calls inherit those limits: at most 24 rows and 16 KiB per widget snapshot, no
render-path network/subprocesses, one batched companion round-trip per Home paint. Counts,
filtering, sorting, joins, stats and battery work stay on the companion worker; timing spans
record real device milliseconds. Moving protocol ownership adds no new screen or widget.

### Lua compatibility adapter and remaining transport work

F12-Q's [checkpoint notes](booksync-home/F12-Q-NOTES.md) track the companion transport
cutover. Its durable position queue prerequisite is not wired into lifecycle hooks;
the Android plugin is not yet server-free. The remaining paths below still apply.

The owned UI still calls `ko/library.lua`; it receives normalized bounded projections.
`ko/server/bookorbit.lua` binds the existing plugin account and compatibility operations.
The reviewed facade callers are `ko/home.lua` (reading gate/Home), `ko/start.lua` (toast),
`ko/notices.lua` (catalog lifecycle), `ko/test_sync_path.lua` (explicit test action),
`ko/sleepscreen.lua` (credential handoff). Only
`main.lua` loads implementation files. Guards forbid additional facade consumers and still
check every reviewed caller for protocol fields/routes and direct imports. The remaining
legacy lifecycle callers (`ko/wifi.lua`, `ko/sleep.lua`, `ko/module.lua`,
`ko/endsheet.lua`, `ko/menu.lua`) may obtain the compatibility plugin through `serverPlugin`;
owned UI cannot. The remaining middleware callers are `ko/net.lua` (cache resume),
`ko/shared.lua` (settings follow-up jobs) and `ko/main_loop.lua` (timing wrappers).
Direct shared implementation globals are forbidden even in these reviewed files. Local
file IO and directory/clock providers live on generic `Store`; legacy protocol lookups and
search live in the adapter. The storage provider has no facade permission. Historical Home wire values and cover-cache folder names stay in the adapter,
so the guard rejects backend names in every casing without breaking installed settings.
Its adapter package owns the old cache/mirror/copies, finish, grouping, local-first and
position-sync hooks; pure protocol helpers live in `logic/server/bookorbit`. Generic cache
encoding remains `logic/cache.lua`; `ko/store.lua` keeps the small owned projection read.
The legacy query interpreter moved to `ko/server/bookorbit/store.lua`. The shared `Cache`
object contains only codec/local utilities; legacy paging, response assembly, cache keys and
normalization live on private `ServerCache`, whose direct use is guarded too.

The maintainer explicitly permits routing oversized migrations through this one Lua adapter
for this slice. Remaining server calls **inside that adapter**, to move to companion commands
in a later transport/sole-sync-owner slice, are:

- `ko/server/bookorbit.lua`: `probeServer` (HEAD reachability in the background child).
- `ko/server/bookorbit/store.lua`: the surviving non-cover request wrappers bridge the
  upstream catalog API and cached replies. Mirror/copies still construct private protocol
  plans sent to the companion worker. The former `cache.lua`, cover downloader and thumbnail
  child scanner are removed. Cover acquisition and forced refresh use neutral companion
  commands; the plugin reads only bounded local cover references.
- `ko/server/bookorbit/endofbook.lua`: compatibility detail/status/rating calls through the
  existing finish outbox. Preserve sole-writer ordering when moving these.
- `ko/server/bookorbit/grouping.lua`: rollback catalog reads through the upstream client.
  Owned lists/filtering use companion projections; do not reuse this full-list path for Home.
- `ko/server/bookorbit/sync.lua`, `reading_sync.lua` and `lifecycle.lua`: legacy outbox,
  pull/push, remote-progress parsing and upstream snapshot/settings bindings. Root start/sleep/
  Wi-Fi flows call the adapter facade; the guard also forbids upstream primitive API names.
- `ko/server/bookorbit/orbismart.lua`: upstream progress client interception. Keep the approved
  one-draw position prompt and reading gate while moving sync ownership.

These are adapter-contained compatibility implementations, not permission to introduce new
Lua HTTP, backend JSON, full-catalog work or legacy views into the owned client. Firmware
adapter enforcement remains deferred under the Android-first instruction.

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

## UI interface ownership (UI-LAYER)

Maintainer ruling (26 November 2026), verbatim:
"This puts all decisions of syncing, aggregating, and anything else in our BookSync interface, and the UI never needs to talk to anything else (other than controlling KOReader as needed)"
Confirmed after concrete examples: "Perfect that's the goal".

Android UI depends on `Library` and its deliberately exposed services, KOReader, other
presentation modules, and pure neutral geometry/formatting utilities. It never chooses a
backend/source, arbitrates sync, interprets a wire record, reads a cache file, persists state
or sends a companion message. The full role inventory is
[`module-layers.json`](../../android/koreader/module-layers.json); `test-ui-boundary.py`
checks every role and uses LuaJIT compilation (without executing code) to distinguish actual
global dependencies from locals and table fields. It rejects internal globals even when
aliased or passed as callbacks, indexed globals, private module imports, dynamic environment
access and file/transport imports. The guard runs beside the server boundary in plugin CI.
There is no file baseline or allowlisted source line. New files require classification.

`ko/library_services.lua` supplies intent operations for layout load/save, settings read/write,
companion availability/status and activity requests, authenticated launch intake, sleep
refresh/settings, recommendation choices, report send and bundled presentation resources.
`ko/library_lifecycle.lua` owns startup coordination; `ko/library_diagnostics.lua` owns sync
path diagnostics. Native navigation/drawing remains in UI. Consent is drawn in
`ko/position_prompt.lua`; the position service owns its decision, answer command and move.
Service coordinators request generic notices from `ko/service_notices.lua` rather than
housing widget constructors. Boot-only `ko/settings.lua` is a persistence/schema service,
not the Settings screen (`ko/menu.lua` / `ko/settings_view.lua`).

This is a behavior-preserving extraction, reusing the implementation at commit `609a3745`:

| Existing implementation | Reused behind the interface |
|---|---|
| `ko/home_editor.lua:4-28` | JSON codec in `library_services.lua`; existing atomic primary/backup helpers from `logic/layout.lua:349-366` move to private `ko/layout_store.lua`. |
| `ko/home.lua:9-25`, `:74-109`, `:344-386`, `:412-443` | Authenticated command intake, restart/relaunch, start-patch installation and reopen in services / `home_lifecycle.lua`. |
| `ko/sleepscreen.lua:26-354`, `:456-464` | Existing files, cover export, refresh and activity requests in `sleep_backend.lua`; only menu/native UI hook stays in `sleepscreen.lua`. |
| `ko/recommendations.lua:3-95` | Existing observation, backup/checkpoint, comparison and report in `recommendations_backend.lua`; review UI calls intent methods. |
| `ko/menu.lua:51-61`, `ko/status_layout.lua:167-171` | Bundled About and battery drawing resources through `Library.resources`. |
| `logic/cache.lua:15-47`, `:119-124`, `ko/store.lua:53`, `ko/wifi.lua:142` | Pure serialization, count formatting, injectable clock and vararg packing in `logic/ui_util.lua`, with legacy internal compatibility wrappers. |

All paths above are relative to `android/koreader/orbit.koplugin/`. Existing logic/flow
regressions cover drawing, lifecycle, reading gates and atomic layout recovery; interface
contract tests add command trust, settings, transport intents and resource operations.
This extraction adds no catalog scan, JSON decoding, network or subprocess on a paint.
Existing `logic/budgets.lua` limits still govern screens/widgets and their library calls;
host timing is not device acceptance. Android is implemented first under the authorised
0.12 scope; X4 Pro, X4 and X3 remain deferred to their interface cutover, with the same rule.

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

### Android sync is server-free; remaining catalog compatibility

The Android plugin's sync path now calls only neutral commands through `ko/library.lua`.
The companion's single `SyncOwner` owns policy, durable marker/override/decline state,
offline queues and delivery through `ServerAdapter`. The production adapter alone owns
backend requests and payloads. The native reader captures small locators/geometry and
shows the approved one-draw consent prompt. It does not call a server for sync.

[F12-Q notes](booksync-home/F12-Q-NOTES.md) document the retirement handshake, five-phase
legacy import, generation fallback, account provenance and crash boundaries. Checkpoints
commit before source retirement; uncertain ownership retains the original files. The
old Lua sync, reading_sync, lifecycle, orbismart and localfirst implementations are
removed. KOReader's own built-in sync remains independent. The guard checks retired
sync calls/routes in every plugin Lua file, including private adapter files, without
an exemption. Shared policy fixtures and a neutral toy companion adapter cover the new
owner, offline restart, override, stale consent and account isolation.

Cover acquisition and refresh now use neutral companion commands; the plugin reads
bounded local references. The former cover downloader and thumbnail child scanner
are removed. Mirror planning and catalog refresh now run in the companion; the neutral library reads
bounded snapshots and dispatches `catalog.control`. The Lua mirror, catalog interpreter
and old library binding are deleted. The F12-Q2 catalog slice now owns grouping,
copies, recommendations and end-of-book commands as well. The native catalog display bridge is now retired, and the
owned Home/Library surfaces consume the bounded read model. Neutral lifecycle signals route
non-sync jobs through Library. No Lua facade consumer or adapter-directory exemption remains.

Catalog-side copies, grouping, recommendations and end-of-book are also companion-owned
(F12-Q2 step 4). The four legacy Lua modules are deleted; `ko/library.lua` dispatches neutral
`catalog.action` and `settings.recommendations` commands and reads bounded snapshots.
`CopiesLogic`, `CacheWorker`, `BookOrbitProjection` and the existing read model own catalog
work. Account-scoped copy/finish queues checkpoint legacy sources and acknowledge identity
and writeback phases. Finishes follow SyncOwner delivery; no retired native writer is called.
Native scalar settings and gesture aliases use bounded companion-supplied metadata; the private Lua compatibility root is deleted.

Every screen/widget keeps its budget. Consent and bounded native verification add named
one-row / 16 KiB budgets; finish has three rows and recommendation review has eight.
Commands, drains and paints log timing spans. No sync is added to Home paint. Heavy capture,
sidecar processing and statistics stay on the companion. Device targets remain pending
maintainer confirmation. Firmware enforcement is deferred under the Android-first ruling.

### Final Android Lua guard (F12-Q2 step 5)

The catalog compatibility root and local native catalog display bridge are retired. All
plugin Lua paths now receive the same protocol/vendor/transport guard, including adapter
directories and composition roots; there are no Lua exemptions. Owned Home/Library surfaces
consume neutral windows. The companion owns protocol and sends one bounded local retirement
descriptor before legacy classes instantiate; the native bridge only disables methods.
Signer/version mismatch, late loading or an unknown startup seam never authorizes the owned
sync writer. Settings/gesture bindings are opaque native metadata, not server JSON. Sleep
requests carry no credentials. See [Q2 notes](booksync-home/F12-Q2-NOTES.md#step-5-enforce-every-lua-path)
for migration boundaries, reuse evidence and deterministic startup/render budgets.

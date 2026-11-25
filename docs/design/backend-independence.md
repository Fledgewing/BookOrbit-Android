# Backend independence

Status: **proposed, awaiting approval** (24 November 2026). Deferred roadmap work;
no implementation is authorized. Design and any reader-facing mockups need approval under
AGENTS.md before building. The [roadmap](../../ROADMAP.md#planned-backend-independence)
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

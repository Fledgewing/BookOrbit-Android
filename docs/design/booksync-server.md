# BookSync server and owned clients

Status: **proposed, awaiting approval** (24 November 2026). Deferred roadmap work;
no implementation is authorized. Design and any reader-facing mockups need approval under
AGENTS.md before building. The [roadmap](../../ROADMAP.md#planned-continuity-and-booksync-ownership)
records the order below.

BookSync should preserve reading history independently of library backends and offer one
stable device interface. The server stays optional: direct mode remains available.

## Phases

### 1. Insurance first

Preserve BookOrbit before replacing any client or sync behavior. Keep a source mirror of
**every release tag**, including the source/build inputs needed to build its container image,
in a **private location chosen by the maintainer**. Preserve the AGPL license, notices and
applicable terms with each archive. Record tag-to-commit mappings and checksums; retain prior
copies if a tag changes or disappears. Document a build from the retained inputs and keep
built images by immutable digest in a private registry/archive with an independent backup.

A scheduled job will discover and mirror new release tags, build their container images,
retain the source and images, and report missing inputs or failed builds. It must not prune
previous releases or automatically upgrade a running service. Apply the same plan to Grimmory
as an optional second insurance archive. Choosing storage, creating mirrors/registries and
installing jobs are future work, not part of this proposal.

Source and images alone do not preserve existing reading stats and information: those live
in the BookOrbit database. Back up the database consistently, library files, deployment
configuration and secrets (secrets separately), and retain the matching image/schema version.
Document and periodically run an isolated restore drill: restore without the upstream repository
or registry, start the retained image against a restored database, verify library access and
representative reading history, and demonstrate rebuilding the image from the mirror. Record
recovery steps and results privately; never test restoration over the production database.

Evidence: BookOrbit at the pinned commit
`c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7`, `LICENSE:1–3` (AGPL);
`server/src/modules/reading-session/reading-session.repository.ts:23–25`
(database-backed sessions/statistics), and
`server/src/modules/reading-session/book-reading-session.controller.ts:14–23`
(per-book session reads/writes). This insurance restores the existing backend; the portable
BookSync ledger below adds independent state ownership.

### 2. Owned Android client and ledger

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

### 3. Server first API: catalog packages

Deploy BookSync as a container on the **maintainer's Kubernetes cluster from the start**.
Its first API serves authenticated **per-device catalog packages**: a scoped manifest,
immutable/resumable catalog chunks and profile-sized covers, initially consumed by Android.
Packaging and refresh scheduling belong inside the service; there is no separate cron or
standalone packaging job. Initial backend ingest is read-only adapter work, not shared-ledger sync.

Design Android, X4 and X3 profiles together. Scope packages and assets on the server, validate
bounds/checksums, and install complete generations atomically without replacing pending local
state. Measure cold ingest separately from warm delivery, metadata separately from covers.
Keep encoding and server language experimental until measurements justify them.

### 4. Shared ledger and backend adapters

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

### 5. Xteink clients

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
| Insurance drill on one retained release, then inventory every release's build inputs. | Can source and image be restored without upstream access, with database history intact? Identify unavailable dependencies before promising reproducibility. |
| Enumerate a synthetic 10k catalog through both adapters; compare basic/rich fields, collections, request counts and cover bytes. | Establish direct-mode baseline and cold-ingest versus warm-package benefit; avoid adopting unverified performance claims. |
| Test minimum-permission history import and write/read round trips on both backends, including timeout after commit. | Capability gaps, auth renewal, side effects and duplicate-session risk; no live data required. |
| Round-trip identity/export/events: changed editions, stale reader, reread, deleted annotation, clock skew and repeated upload. | No lost or double-counted history; unknown records survive and ambiguous matches remain unresolved. |
| Generate Android/X4/X3 sample packages; prototype X3 parser/transport with direct backend excluded. | Measure wire size, decode RAM, linker maps, flash margin and cover quality before choosing codec/profile. |
| Revoke scope during package generation; interrupt generation commits; restore an older server with newer device queues. | No unauthorized old assets, destructive empty-library inference or lost unacknowledged events. |

Each phase needs its own acceptance review. No mirrors, jobs, deployment, devices or upstream
changes are created by this documentation change.

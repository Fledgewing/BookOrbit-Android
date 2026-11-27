# BookSync Android 0.12 download jobs

Implementation of the approved rev 16 §§4–5 single-book transfer contract. Series
next-N is a separate outcome; this slice makes its sequential job primitive available.
No firmware sources or pins change. This is feature-branch source, not a release or
physical-reader acceptance.

Library owns prepare/start/status/cancel/Resume and bounded in-memory progress.
Home, list and Series row bodies start the same explicit job for server-only books;
Details has an Open/Download action and setup route when downloading is unavailable.
The owned format chooser displays supported saved-manifest choices and destination.
Offline tapping first asks Connect and download/Cancel; declining creates no job.
The chooser and Settings use the same current native download/home/device-home/last-folder precedence; each job freezes its resolved path. A missing previously local file clears availability and asks the companion to refresh
local joins, without starting a transfer. Existing local books retain their paths.

CatalogTransfers persists at most 32 account-scoped jobs, deduplicated by book,
file and variant. Credentials and expiring locators never enter the journal.
Status and Cancel bypass the catalog worker's transfer queue; transport and final
publication stay on that sole worker. Restart pauses interrupted work until an
explicit Resume. Received bytes have a total only when known; no guessed percentage.
Each job freezes its chosen destination. Different-format/file choices remain distinct.

BookTransferHttp streams bounded chunks, enforces 512 MiB and 200 MB headroom,
rejects redirects and supports exact Range recovery only with a strong validator.
If the server declines Range, an explicit Resume restarts safely. A completed staging
file can be reused for a link retry. Final reader-hash validation and atomic publish
precede local identity registration; unrelated collisions use an identity suffix or
fail, and a selected missing revision never falls back to another primary file.
Sidecars, annotations, existing complete books and 0.11 migration queues are retained.
Canceled staging is discarded; interrupted staging remains available for Resume.

Only a still-visible originating single-book intent may auto-open after completion.
Cancel, departure, reading another book, restart and bulk revoke automatic opening.
Late status callbacks cannot replace a newer job ID. Worker completion refreshes
bounded local-file views and posts an interface invalidation; it never opens UI.

## Budgets and validation

- File chooser: at most eight manifest rows / 16 KiB; native ButtonDialog supplies
  overflow scrolling (`frontend/ui/widget/buttondialog.lua:189–198` at pinned
  KOReader `9192014d8bd82a91dc1012473be0f238dedfdb54`). Destination labels are bounded.
- Job information: one row / 16 KiB. Home transfer overlays are charged to each
  existing widget/page byte budget; immutable cached source rows stay unchanged.
- Paints perform no network, scans, hashing or forks. Visible progress uses one
  bounded status command per second and stops when the originating surface departs.
- Companion: 862 tests, zero failures/errors, four skipped; shared version, debug
  APK and lint. Lua logic 256 and flows 269. Server/UI boundaries 12/6, matrix 4,
  emulator safety 8. Streaming tests include partial recovery, Range rejection,
  malformed ranges, unknown size, cancellation and space/auth refusal.
- Native emulator: five transfer checks plus the existing 57-screen review. The
  fixture uses the production durable job control with synthetic bytes; real HTTP
  and catalog linking are covered by JVM integration tests. The offline harness
  disables both Wi-Fi and mobile data and waits for disconnection. Initial connectivity/setup failures are retained as local evidence. A Resume run also caught stale same-ID state replies; state sequence guards and a regression now prevent an older canceled reply replacing Resume. No physical-device claim is made.

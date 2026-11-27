# BookSync Android 0.12 Series downloads

Implements approved DESIGN §5 on Android. Firmware and its pin are outside this
change. This is feature-branch implementation, without a release or physical-reader
acceptance claim.

The companion selects one explicit series in contextual order. Default N is three,
editable from one through ten. The current reading book anchors the selection;
otherwise it uses the most recently read in-progress book, the last finished book,
or the beginning. Only unread, known server-only books are eligible. Active or
recoverable jobs are skipped. Selection never wraps. An earlier eligible gap offers
an explicit starting position, with another preview.

The preview lists the exact titles and known sizes, or says size unknown. Offline
use requires Connect and download. Cached/fetched manifests resolve supported file
choices one book at a time, with explicit choice when several are supported. The
final review lists every chosen format, size and the resolved native destination.
Read-only rows use the native dialog's scrollable button table; the title stays
short so ten-book reviews cannot consume the controls' height. No job starts before
Start downloads. Start recomputes the saved selection token and refuses a changed
selection instead of substituting other books. Destinations and variants freeze in
the durable job records.

The adapter executes one file per catalog actor turn, yielding between files.
Status and cancellation bypass transfer IO. Per-row Cancel leaves later books
queued; Cancel remaining preserves completed files. Offline/auth loss pauses the
remaining queue. Per-file format/validation/space failures remain visible and do
not prevent later eligible files. Resume is explicit after failure or restart.
Summary counts requested, saved, skipped and failed; bulk completion never opens a
book or shows background UI. Polling stops when the queue sheet departs.

Four retained Series queues share the bounded transfer plane (32 jobs per account,
128 across accounts). Exact plans persist before individual job creation; a crash
between creation and checkpoint reattaches through owner/book/file/variant dedupe.
Completed row checkpoints survive eviction of old terminal transfer history. Each
new job has private staging; old interrupted jobs retain the legacy staging name.
Cancel discards only its own validated staging and leaves complete books intact.

During partial catalog publication, the previous complete Series membership stays
visible and bulk downloading is disabled. Repeated failed refreshes retain that
complete generation. Ordinary single-book downloads remain available. No App Attest
workaround or transport is added outside the server adapter.

## Validation

Companion unit/integration tests cover selection/anchors/gaps, bounds, sequential
actor steps, file errors, offline pause, explicit restart recovery, account isolation,
per-row/all cancellation, journal/history recovery, private staging and exact file
choices. Native emulator flows exercise preview, N editing, format choices, queue
controls and departure without auto-open, alongside the existing full screen review.
The emulator uses production durable queue controls with synthetic bytes; actual
HTTP streaming, identity publication and catalog coverage are JVM integration tests.

Series preview/queue snapshots have eleven rows and 16 KiB maximum. Native page
paint performs no transport, scans or forks. Cover nodes use the existing deferred,
cancelable bitmap path. The Series page reserves at least 50 scaled pixels for its
download action and keeps it separate from book targets.

Local verification: 876 companion tests (zero failures/errors, four skipped),
shared-version verification, debug APK and lint; 256 Lua logic / 271 flow checks;
server/UI boundaries 12/6, feature matrix 4 and emulator safety 8. Native checks
cover six Series interactions plus the existing 57-screen review. Initial local
harness/fixture failures remain in evidence; corrected tests exercise the intended
keyboard, Unicode and changed-catalog states. No physical device was used.

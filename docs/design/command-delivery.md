# Android command delivery tickets

Shape A approved for implementation on 2026-11-27; shape B (consumer scopes with
command/timer slots) is deferred. This is an internal Android lifecycle correction,
not a new feature or a firmware implementation. UI continues to use Library only;
server protocol remains behind ServerAdapter in the companion.

## Existing seams

The implementation extends `android/koreader/orbit.koplugin/ko/library.lua`:
current account reloads, bounded command transport, post-paint card cover acquisition
and catalog refresh cleanup. Account presentation stays in `ko/account.lua`;
position run completion stays in `ko/position_sync.lua`. It reuses `logic/budgets.lua`
and `logic/cache.lua` for byte limits and bounded decoding, rather than introducing
another transport, scheduler, state store or position writer.

## Ticket contract

Library feature calls preserve the accepted boolean and may return a second value,
an idempotent retirement closure. Dispatch rejection may invoke the callback
synchronously, before that closure is assigned. Retiring a settled ticket is harmless.
An explicit retirement suppresses presentation, unschedules command polling and drops
consumer references. It never cancels the companion's durable job.

The private delivery implementation owns bounded request/result encoding, the initial
and subsequent polls, once-only settlement and validation before effects. Library
chooses named policies: owner-bound catalog/download/cover results, account-transition
reconciliation, or device-lifetime position/settings work. Owner-bound delivery checks
both the opaque owner and its lifecycle epoch, so A → B → A cannot revive an old
ticket. Optional consumer eligibility is monotonic: the first invalid poll settles
canceled and cannot resume later. Automatic invalidation delivers `error="canceled"`
to a live consumer so it can clear busy state; explicit retirement delivers nothing.
The Home download host clears busy state without showing a cancellation popup.

The 120-second limit bounds **pending waits**, not whether a reply counts. A ready
reply first observed by an overdue poll still delivers if its ticket remains live.
A pending reply at or after 120 seconds settles unavailable; subsequent completion
cannot revive the ticket. This preserves the earlier ready-before-deadline-check order.

Stored command replies never install account identity. Account commands reconcile
through current `SERVER_STATE`, then deliver that current state to their live form.
A newer reload retires the previous pending retry and inherits its waiters; epochs
reject stale retry closures. The existing bounded lifecycle retries remain distinct
from presentation polling. Durable account events invoke that same reconciliation,
including when a sign-in form has closed. Historical replies cannot overwrite newer
owner state. Hidden live account forms may adopt the model, but repaint only when
visible. Back, close and a new attempt retire the prior presentation ticket.

Device folder/sleep effects have a separate device-lifetime ticket. Retiring their
presentation drops the view callback while the durable result still updates the local
folder setting or cached device snapshot. Hidden Storage pages retain their result;
closed pages retire presentation. Recommendations retain their device lifetime and
existing expected-value checks.

Catalog refresh still owns its multi-step run explicitly: replacement first retires
the old command and local status timer and releases exactly that run's counted Wi-Fi
lease. Idempotent cleanup cannot clear a newer run. Run matching, heartbeat staleness,
coalescing and healthy long-running refresh semantics remain feature-specific.

Position runs name and unschedule their completion timer on success or timeout.
The maintainer changed the consent ruling after PR #197, verbatim:
**'"sync to this position" does make sense to interrupt your reading for'.**
The caller-facing timeout completes the caller once; it does **not** retire consent.
A late consent prompt is still shown, even mid-reading, while its presentation ticket
is live: the same native document and path remain open, the owner and owner epoch
are unchanged, and no newer position run has superseded it. A → B → A account
transitions cannot revive an old prompt. A new run supersedes old presentation at
invocation, including while activation is pending. Existing mode and close/sleep
prompt guards remain in place.

Only stale presentation is dropped; capture/decision/journal work continues through
the sole companion writer. Owner/epoch eligibility stays behind Library; ReadingSync
owns native-document and run identity. Answer-token validation and durable verification
remain in their existing owners.

## Performance and verification

Every screen and widget keeps its declared `logic/budgets.lua` limits; Library calls
inherit them. Tickets add no paint reads, network, subprocesses, catalog parsing or
new render round-trips. Command results remain at most 16 KiB; acquisition stays
post-paint, and bitmap input stays capped at 512 KiB. Existing info timing spans
remain on Library calls. Device latency targets still require device confirmation.

`android/koreader/test/test_delivery.lua` exercises Library feature interfaces with
the real delivery implementation and fake JNI, clock and scheduler. It covers
terminal transport, late-ready and pending deadlines, account retirement/current
state/reload ordering, owner epochs, cover retirement, downloads, catalog leases,
position completion/late consent, and durable local settings. Existing native image
resource, UI rendering/focus, recommendation policy and companion sole-writer tests
remain separate. Both UI and server boundary guards run without skips.

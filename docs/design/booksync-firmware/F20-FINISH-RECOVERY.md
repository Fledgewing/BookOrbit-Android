# BookSync F20 finish recovery — NEEDS APPROVAL

Status: **NEEDS APPROVAL**. Docs only. No firmware UI is enabled by this proposal.

The approved [end-of-book design](../end-of-book/DESIGN.md), section 5,
already covers Finished, sends at next sync, Undo and rating. The approved
[Home design](../booksync-home/DESIGN.md), sections 5 and 11, retains those
semantics. F20 implements the service journal; F41 owns reader presentation.

The [additional mockups](f20-finish-recovery.html) propose the missing
unknown-delivery and pending compensation presentations for X4 Pro, X4 Classic
and X3. They do not amend the approval of existing finish/Undo/rating views.
Until these states are approved, keep their UI off.

| State | Text and actions | Service meaning |
|---|---|---|
| Result unknown | Finish saved on this reader. Waiting to confirm the server result. Actions: Undo; Back to book. | An attempted write may have committed. Retain it and reconcile. Never say sent or failed based on timeout. |
| Undo pending | Undo saved on this reader. Waiting to confirm the earlier finish before restoring your previous choice. Action: Back to book. | Durable compensation follows the original receipt; no blind resend or guessed acknowledgment. |
| Previous value unknown | Your earlier choice is not available. Keep reading while the finish result is checked. Action: Back to book. | No fabricated previous status/rating. The service refuses an unsafe restoration. |

X4 Pro uses touch rows and keeps hardware buttons available. Classic and X3
use Previous/Next, Select and Back, starting on Back to book. X3 uses bounded
text only. Back returns to the exact native reading position; it retires only
presentation ownership. No automatic popup interrupts reading. These are
user-opened end-of-book details; paint consumes Library values without I/O.

A newer local choice invalidates an old Undo. A newer remote choice is preserved
by the adapter's guarded compensation contract. Unknown outcomes remain queued.
At journal capacity, refuse a change that cannot be stored; never evict a receipt
or pending work. Existing approved B2 capacity presentation remains the only
capacity UI.

This proposal changes no shipped feature cells, reader behavior, firmware pin,
server protocol, device state or release input. Android keeps its approved
presentation and existing service semantics; firmware service parity does not
approve these additional device states.

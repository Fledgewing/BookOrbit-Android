# Android Home book cards (F12 cards)

Android implementation on feature/0.12; unreleased, with device appearance and latency
acceptance pending. X4 Pro, X4 and X3 follow the authorised Android-first build;
X3 additionally needs measured flash fit. No firmware, device or release changes.

The existing host (`ko/home_host.lua:105`) reads the same bounded window and passes
an immutable snapshot to the existing card renderer (`ko/home_widgets.lua:33`).
`LibraryReadModel.kt:72` enriches only returned display rows with saved cover paths,
series text, local progress, time-left and finish-date strings. It reuses adapter
`cover` projections and the ordered `PersonalReading.kt:16` source registry;
`DevicePersonalReading.kt:19` starts with the device's bounded, read-only sidecar
parser (`DeviceLibrary.kt:13`). No catalog scan, source selection or stats join
moves into UI code. Later providers can supply personal fields behind that registry.

`ReadingStats.kt:32` measures seconds per fractional page using the book's exact
KOReader checksum and each visit's recorded total page count. Layout changes do not
mix absolute page counts. At least five positive visits of at most ten minutes are
required; invalid pages, future visits and other book identities are excluded.
Remaining time uses the saved native position. Expected finish uses this reader's
last fourteen calendar days of timed reading, including zero days, from the existing
Stats aggregation. Missing identity/position/pace stays “Not enough reading yet”; a
missing daily estimate stays “Finish date unavailable”. Neither label implies
account-wide activity or an acknowledged server update.

Pinned KOReader evidence: commit `9192014d8bd82a91dc1012473be0f238dedfdb54`,
`plugins/statistics.koplugin/main.lua:406` defines raw timed visits and their
`total_pages`; `:435` explains rescaling across layouts; `:464` defines book identity
and checksum. This calculation reads the raw visits, never the rescaled view.

Cover preparation reuses `Library.acquireCover` (`ko/library.lua:417`) and its
companion command, plus cached adapter references. `Library.prepareCardCover`
(`ko/library.lua:452`) defers work until after first paint, coalesces misses and
rejects canceled, hidden, account-switched and reading-foreground callbacks.
The placeholder is replaced by a fitted native bitmap when available; freeing the
card (including native CloseWidget) cancels delivery and releases its bitmap.
The callback invalidates its initiating Home window so the prepared bitmap is
actually repainted; replacing or covering Home rejects delivery. Shelf covers use a
transparent native input container whose gesture rectangle follows its painted
position, so the bitmap remains visible and its tap target remains live. Invalid/oversized images keep the
placeholder. No network or decoding occurs in the initial paint.
At the same pinned KOReader commit, `frontend/ui/uimanager.lua:225` sends
CloseWidget and `:454` documents window-level repaint;
`frontend/ui/widget/container/inputcontainer.lua:66` updates gesture coordinates;
`frontend/ui/widget/imagewidget.lua:600` and `:614` release native bitmaps on close.

Continue reading keeps percentage, one plain progress bar and Resume/Details.
Missing progress is explicitly unknown (—), never fabricated as zero percent.
Larger cards add author/series and finish date; smaller ones prioritize title,
percentage and time left. Book list retains caption settings, bounded source order
and both styles, with covers, richer rows and a per-book overflow target. Short
shelves use rows when there is insufficient room for cover and separate 50 px
controls. Host queries, pagination and drawing share `HomeHostPlan.cardGeometry`;
short rows retain title, percentage and time left while taller rows add series and
finish forecast. Paging consumes exactly the visible rows, so no books are skipped. All installed sizes and
six states plus setup run through the existing bounds/intersection flow sweep.

Overflow decisions live in `Library.cardActions` (`ko/library.lua:427`): Details,
Open or Download, View series when available, Mark read/unread and Remove download
when present. Details/Open/Series reuse existing host routes; Download reuses the catalog's validated atomic-file and ledger workflow. **Mark status
and Remove download are disabled:** the current adapter exposes no safe arbitrary-
book mutation command. Implementing them needs the durable sync owner/Undo and an
identified-file, open/replacement-protected confirmation operation respectively;
this slice does not substitute direct sidecar writes or Lua file deletion. This
part of DESIGN §4 remains unfinished and is recorded in the roadmap/matrix/ledger.

Performance limits remain in `logic/budgets.lua`: one shared Home batch, zero render
network/subprocesses, bounded rows and at most 16 KiB decoded per widget. Cover
paths/forecast strings share that existing snapshot, with no extra cover lookup on
paint. Bitmap input is separately bounded to 512 KiB. The static overflow sheet
has at most five rows, zero decoded bytes and zero round-trips. Existing per-paint,
per-publication and new deferred-decode info spans expose device milliseconds;
host timings do not prove the 500/50/30 ms device targets.

Validation: plugin logic and flow suites, including every card size/state/style;
UI/server boundary guards; companion unit tests (ReadingCardTest covers layout
changes, invalid/missing history, exact checksum identity and source precedence),
shared-version verification, debug assembly and lint. No device acceptance claimed.


## Arbitrary-book actions

Approved rev 16 §5.1 overflow now exposes status and removal only when the
Library capabilities permit them. Unknown status remains disabled. A manual
status intent updates cached/native status immediately, retains its exact previous
status/date for Undo and shows a local-save confirmation rather than a server ack.
Done, dismiss or reader restart releases the hold; Undo replaces the held intent.
The existing native position and annotations never become a fabricated 100% finish.

CatalogWorkflow owns the account-scoped outbox. A durable token links its saved
native capture to the existing LifecycleQueue/SyncOwner; only that owner sends
positions. A bounded backlog cannot turn enqueue success into position proof.
Lifecycle book-state exchange suppresses manual status until the explicit outbox
writes after the progress checkpoint. Rejections retain the local intent for an
explicit retry. Pending overrides survive stale catalog replies and an in-flight
refresh generation. A later independent catalog generation may reflect changes
made on another device.

ReaderSidecar retains the adapter's existing native metadata-location rules.
Live native documents receive in-memory summary/cache updates; the companion
retains the writeback until closure and never rewrites an open sidecar. Status
phase tokens reject late replies from older marks. Rating/review and annotation
sync remain in their existing owners; legacy queues/import proofs stay intact.

Remove download first previews a tracked file, then revalidates its identity token,
account and current-book exclusion before removing only that file. Native sidecars,
annotations and unrelated books remain. Navigating away drops late dialogs/redraws.
The two action surfaces each receive one bounded command result (≤16 KiB); no scan,
hash, transport or file write runs on the KOReader UI thread.

Validation: companion 847 tests (0 failures/errors, 4 skipped), Lua logic 256 and
flows 266. Native emulator review covers all existing 57 screens plus four card
checks (Undo, Done, cancel, confirmed removal preserving the exact sidecar bytes).
The native status presentation uses a test-only Library double; production adapter,
held intent, owner isolation, position ordering and writeback are exercised by JVM
integration tests. Emulator evidence is local; no physical reader was touched.

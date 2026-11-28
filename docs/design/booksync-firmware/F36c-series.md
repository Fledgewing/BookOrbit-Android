# F36c Series and download next N — NEEDS APPROVAL

27 November 2026. **NEEDS APPROVAL.** Documentation only. No firmware, submodule
pin, shipped feature cell or release changes. Existing Home revision-16 and B1–B5
approvals remain unchanged. [Three-profile gallery](f36c-series.html).

## Approval gap

The approved Home gallery contains `x4pro-series` and `x4c-series`, but no X3
Series page or explicit three-profile next-N review, editor, queue and failure
scenes. B3 update-download screens are firmware updates, not book downloads.
The proposed additions below do not inherit approval from those other screens.
F36c remains off until the missing states and its service dependencies are ready;
no partially navigable firmware Series route is introduced by this proposal.
F36a Library/lists and F36b detail/actions retain their separate ownership.

## Reference and behavior

Audited Android source at integration commit
`aa5c9b9f202e030d6636b07df15837b031501aed` on `feature/0.12`:

- `android/koreader/orbit.koplugin/ko/series.lua:18–102`: header, bounded page,
  saved/empty/error states, row actions, incomplete membership and paging.
- `android/koreader/orbit.koplugin/ko/series.lua:180–345`: explicit queue monitor,
  cancellation/resume, file review, default count 3, editor bounds 1–10,
  offline preview, earlier-gap action and closed-sheet guards.
- `android/koreader/orbit.koplugin/logic/series.lua:4–18`: state classification
  and page geometry; no transport policy in presentation.
- [Home design §5](../booksync-home/DESIGN.md#5-series-and-detail) and
  [Android Series download implementation](../booksync-home/F12-SERIES-DOWNLOADS.md)
  define eligibility, ordering, durable plans and queue behavior.

Library selects unread, known server-only eligible members after the current
reading anchor, otherwise the last finished member, otherwise the beginning.
Read/local/active or recoverable jobs are skipped. No wrapping; an earlier gap
requires an explicit new start and another preview. Primary and secondary
memberships keep their own contextual decimal indexes and source rank.
The interface, not UI, owns ordering, aggregation, selection, safe paths,
file eligibility, account isolation, queue state and all transfer work.

Default N is 3, editable 1–10. The preview names the actual selection and each
known size or “Size unknown”. Up to ten selected titles use bounded pages on
firmware instead of Android's scrollable dialog. Review files, then final
confirmation, precedes Start downloads. No aggregate size is invented when an
item's size is unknown. An exact-selection token prevents replacement books
from being silently substituted when the catalog changes.

The queue is sequential and durable under the sole writer. Individual Cancel
leaves later books queued; Cancel remaining keeps completed books. Offline or
lost authorization pauses work for explicit Resume. Format/validation/storage
errors remain visible per book; later eligible items continue where possible.
Summary counts requested, saved, skipped and failed. Bulk downloads never open
a book automatically. Back closes presentation polling; late results never
reopen a departed sheet or steal the reader's focus.

## Proposed states — all NEEDS APPROVAL

Every linked article has X4 Pro touch, X4 Classic buttons and X3 text/buttons.
The departure article is a Back acceptance storyboard, not a new product screen.

| Scene | Display | Back behavior |
|---|---|---|
| [series-ready](f36c-series.html#series-ready) | The Lantern Cycle | Return to the caller at its saved page and focus; a reader caller retains its exact position. |
| [series-offline](f36c-series.html#series-offline) | The Lantern Cycle | Return to the caller without connecting. |
| [series-loading](f36c-series.html#series-loading) | Series | Return to the caller; retire the request. |
| [series-not-saved](f36c-series.html#series-not-saved) | Series | Return to the caller; no download is queued. |
| [series-empty](f36c-series.html#series-empty) | Series | Return to the caller. |
| [series-error](f36c-series.html#series-error) | Series | Return to the caller. |
| [series-incomplete](f36c-series.html#series-incomplete) | The Lantern Cycle | Return to the caller. |
| [series-unsupported](f36c-series.html#series-unsupported) | Series | Return to the caller. |
| [series-saved](f36c-series.html#series-saved) | The Lantern Cycle | Return to the caller. |
| [series-unknown](f36c-series.html#series-unknown) | The Lantern Cycle | Return to the caller. |
| [series-preview](f36c-series.html#series-preview) | Download next 3 | Close the preview and return to the Series page. |
| [series-preview-pages](f36c-series.html#series-preview-pages) | Download next 10 | Close the preview; retain the Series page. |
| [series-count](f36c-series.html#series-count) | Download how many? | Discard the edit and restore the previous preview. |
| [series-count-invalid](f36c-series.html#series-count-invalid) | Download how many? | Discard the invalid edit; keep the previous number. |
| [series-offline-preview](f36c-series.html#series-offline-preview) | Download next 3 | Close without connecting or queuing. |
| [series-connect-failed](f36c-series.html#series-connect-failed) | Could not connect | Return to Series without queuing. |
| [series-gap](f36c-series.html#series-gap) | Download next 3 | Return without selecting earlier books. |
| [series-no-eligible](f36c-series.html#series-no-eligible) | Download next 3 | Return to Series. |
| [series-files](f36c-series.html#series-files) | Choose file · Stone Path | Cancel file resolution and return to Series. |
| [series-file-unavailable](f36c-series.html#series-file-unavailable) | Stone Path | Return to Series; no job has started. |
| [series-review](f36c-series.html#series-review) | Download 3 books? | Return to the exact preview; start nothing. |
| [series-stale](f36c-series.html#series-stale) | Series preview unavailable | Return to Series; no substitute queue is created. |
| [series-queue](f36c-series.html#series-queue) | Series downloads | Close the queue sheet; downloads continue under the sole worker. |
| [series-paused](f36c-series.html#series-paused) | Series downloads paused | Close the sheet; keep paused work for explicit resume. |
| [series-auth](f36c-series.html#series-auth) | Series downloads paused | Return without opening account UI automatically. |
| [series-resume](f36c-series.html#series-resume) | Series downloads paused | Keep the queue paused. |
| [series-file-error](f36c-series.html#series-file-error) | Series downloads | Close the sheet and retain results. |
| [series-validation-error](f36c-series.html#series-validation-error) | Series downloads | Close the sheet; no unverified file opens. |
| [series-format-error](f36c-series.html#series-format-error) | Series downloads | Close the sheet; retain complete files. |
| [series-row-canceled](f36c-series.html#series-row-canceled) | Series downloads | Close the sheet; leave later items running. |
| [series-canceled](f36c-series.html#series-canceled) | Series downloads canceled | Return to Series with saved availability updated. |
| [series-complete](f36c-series.html#series-complete) | Series downloads complete | Return to Series; open a book only on a later explicit selection. |
| [series-departure](f36c-series.html#series-departure) | Back to the caller | Return normally from the caller. |

## Profile details and acceptance after approval

X4 Pro uses the existing monochrome header, rows and action pills. The count
keypad is a direct child docked below content/actions and above the footer.
X4 Classic uses first-row or explicit action focus and Previous/Next/Select/Back;
number input adjusts a digit, with bounds validation before Review. X3 keeps
bounded text rows and the same actions, without cover bitmap allocation.
Each state caption names initial focus and the exit. File review never selects
an unsupported format; all Xteink transfers remain EPUB-only.

The gallery is static documentation: it supplies no network, parsing, file IO,
queue writes or executable product controls. Proposed firmware acceptance uses
F22 queries, F23 verified transfers, F25 scoped covers and F34 navigation through
Library only. The service must expose bounded next-N preview/queue operations
before UI can implement Android's semantics; UI must not reconstruct the plan
by scanning paged results or dispatching unrelated single downloads.

After approval, host neutral snapshot/action tests and all three simulator
profiles must cover every applicable state, count bounds, secondary membership,
unknown size, account change, stale preview, Back/Cancel and late delivery.
Paint performs zero service work. Three hardware builds must report actual
application bytes, map/static-RAM deltas and at least 131,072 free slot bytes.
This docs change has no firmware measurements or device acceptance claim.

Maintainer hardware verification after implementation: on X4 Pro, X4 Classic
and X3/C3 X4, open a saved series offline, navigate pages and return to the same
caller/reader position. Preview N=1, 3 and 10; cancel before connection; exercise
pause/resume, per-row/all cancellation and full-card/invalid-file errors. Expect
completed files to remain and no automatic open after leaving the view. No EPUB
cache format change or cache clearing is proposed. Agents do not access devices.

## Documentation validation

Chromium checked all 99 device views at both 1200 px and 390 px widths: 198
view checks, no content clipping, horizontal overflow, broken anchors or page
errors. Series, count editor, preview, queue and error articles were rendered
for visual inspection; button row and numeric focus match their captions, and
touch numeric keypads remain docked above the footer. All 128 existing articles
in the approved firmware gallery are byte-for-byte unchanged.

Feature matrix checks: 4 passing. Android reference suites: 265 logic checks
and 313 flow checks passing, plus 12 policy tests reported by the logic runner.
The flow harness emitted two read-only `/settings` mkdir warnings but completed
with zero failures. These are host/reference checks, not firmware acceptance.
No firmware build, simulator scene or application-size measurement was performed
for this docs-only proposal. Those checks remain mandatory for implementation.

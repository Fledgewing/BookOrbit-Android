# F36c Series and download next N — APPROVED (2026-11-28)

Revision 2 · **APPROVED (2026-11-28)** by the maintainer at ~00:45 PT:
“I approve all the screens / widgets”. All revised compact scenes and states.
[Three-profile gallery](f36c-series.html). Implementation and device acceptance
remain required. No firmware, pin, shipped feature cell or release changes.
Home revision-16 and B1–B5 approvals remain unchanged. F36c implementation
depends on its Library services and tests; F36a/F36b remain separate.

## Photo comparison and visual rules

Reviewed the two supplied 0.11 X4 Home and Library photographs locally. The
revision adopts their compact cover-led rows/shelves, bold sans headings,
large numeric values with small labels, thin outlined cards and top-right icons.
The first draft's sparse text-only cards and generic BOOK rectangles are replaced
with original monochrome vector jackets and tighter spacing on X4. X3 retains
bounded text with the same state/action meanings. No photo, private identity,
reading record, title, account, host or address from the photographs is committed.
Every example is synthetic; illustrated covers are original geometric artwork.

“All (n) ›” is at the top-right of a preview header, never below the items or as
a bottom “See all”. The existing Android grouped Series context demonstrates
this placement and opens the existing Series page. The full Series page already
lists all members; adding a redundant All route there would invent an action.
Search remains the Series page's top-right header icon. All, Back, Search and
primary actions retain at least 50 design-pixel targets around their compact
labels/icons. Card icons stay at the
top-right; Series totals and queue counts use large values with small labels.
No random Discover, Home widget, account or additional firmware screen is added.

## Android is the behavior reference

Audited plugin at integration commit `7271551677142919e27bcf1592b870c8f89c9f9d`:
`android/koreader/orbit.koplugin/ko/series.lua`, with state classification in
`android/koreader/orbit.koplugin/logic/series.lua`. Companion context:
`SeriesPresentation.kt` and `server/bookorbit/SeriesTransfers.kt`.
[Home §5](../booksync-home/DESIGN.md#5-series-and-detail) and
[Android queues](../booksync-home/F12-SERIES-DOWNLOADS.md) explain selection and
persistence. Paths in the table below use `ko/series.lua` unless prefixed.

The gallery has **32 state examples / 96 device views of eight existing
Android surface families**, not 32 new screens: grouped list, Series page,
preview, count input, file chooser, final review, one-button notice and queue.
Paused and terminal results are data variants of the queue.
The eight named surface families, including the existing grouped-list context, are
presentation references; no new navigation route is proposed. All shown states
map to source branches below. Count-invalid, per-book failures and completion
are data in existing dialogs. Back departure and late delivery are acceptance
assertions only; the first draft's invented departure screen is removed.

| Example | Existing Android branch | Back / Cancel |
|---|---|---|
| [series-group-context](f36c-series.html#series-group-context) | `series.lua:102–157` · groups | Return to the previous Library context. |
| [series-ready](f36c-series.html#series-ready) | `series.lua:53–92` · series | Return to the caller at its saved context; a reader caller retains its native position. |
| [series-offline](f36c-series.html#series-offline) | `series.lua:53–92` · series | Return to the caller at its saved context; a reader caller retains its native position. |
| [series-incomplete](f36c-series.html#series-incomplete) | `series.lua:53–92` · series | Return to the caller at its saved context; a reader caller retains its native position. |
| [series-saved](f36c-series.html#series-saved) | `series.lua:53–92` · series | Return to the caller at its saved context; a reader caller retains its native position. |
| [series-unknown](f36c-series.html#series-unknown) | `series.lua:53–92` · series | Return to the caller at its saved context; a reader caller retains its native position. |
| [series-loading](f36c-series.html#series-loading) | `logic/series.lua:4–11; ko/series.lua:25–37` · series | Return to the existing caller; retire presentation. |
| [series-not-saved](f36c-series.html#series-not-saved) | `logic/series.lua:4–11; ko/series.lua:25–37` · series | Return to the existing caller; retire presentation. |
| [series-empty](f36c-series.html#series-empty) | `logic/series.lua:4–11; ko/series.lua:25–37` · series | Return to the existing caller; retire presentation. |
| [series-error](f36c-series.html#series-error) | `logic/series.lua:4–11; ko/series.lua:25–37` · series | Return to the existing caller; retire presentation. |
| [series-preview](f36c-series.html#series-preview) | `series.lua:284–311` · preview | Close the dialog and return to Series. |
| [series-offline-preview](f36c-series.html#series-offline-preview) | `series.lua:293–297` · preview | Close the dialog and return to Series. |
| [series-gap](f36c-series.html#series-gap) | `series.lua:288–310` · preview | Close the dialog and return to Series. |
| [series-preview-ten](f36c-series.html#series-preview-ten) | `series.lua:289–311` · preview | Close the dialog and return to Series. |
| [series-count](f36c-series.html#series-count) | `series.lua:299–307` · count | Cancel closes the editor to Series, because the preview was closed before opening it. Native Back first dismisses keyboard/input as appropriate. |
| [series-count-invalid](f36c-series.html#series-count-invalid) | `series.lua:299–307` · count | Cancel closes the editor to Series, because the preview was closed before opening it. Native Back first dismisses keyboard/input as appropriate. |
| [series-files](f36c-series.html#series-files) | `series.lua:258–279` · files | Close the dialog and return to Series. |
| [series-review](f36c-series.html#series-review) | `series.lua:246–255` · review | The explicit Back button re-requests the preview; no job starts. |
| [series-connect-failed](f36c-series.html#series-connect-failed) | `series.lua:295–296` · notice | Close the dialog and return to Series. |
| [series-file-unavailable](f36c-series.html#series-file-unavailable) | `series.lua:260` · notice | Close the dialog and return to Series. |
| [series-preview-error](f36c-series.html#series-preview-error) | `series.lua:287` · notice | Close the dialog and return to Series. |
| [series-incomplete-notice](f36c-series.html#series-incomplete-notice) | `series.lua:287` · notice | Close the dialog and return to Series. |
| [series-unavailable](f36c-series.html#series-unavailable) | `series.lua:188–190` · notice | Close the dialog and return to Series. |
| [series-no-eligible](f36c-series.html#series-no-eligible) | `series.lua:288` · notice | Close the dialog and return to Series. |
| [series-queue](f36c-series.html#series-queue) | `series.lua:192–234` · queue | Close the dialog and return to Series. |
| [series-paused](f36c-series.html#series-paused) | `series.lua:203–216` · queue | Close the dialog and return to Series. |
| [series-auth](f36c-series.html#series-auth) | `series.lua:203–216` · queue | Close the dialog and return to Series. |
| [series-resume](f36c-series.html#series-resume) | `series.lua:203–216` · queue | Close the dialog and return to Series. |
| [series-file-error](f36c-series.html#series-file-error) | `series.lua:192–217; SeriesTransfers.kt:51–62` · queue | Close the dialog and return to Series. |
| [series-row-canceled](f36c-series.html#series-row-canceled) | `series.lua:194–201` · queue | Close the dialog and return to Series. |
| [series-canceled](f36c-series.html#series-canceled) | `series.lua:213–218; SeriesTransfers.kt:51–74` · queue | Close the dialog and return to Series. |
| [series-complete](f36c-series.html#series-complete) | `series.lua:192–234; SeriesTransfers.kt:51–62` · queue | Close the dialog and return to Series. |

## Action parity corrections

- Preview lists exact selected titles/sizes and the actual available count.
  Default N=3; integer range 1–10. Review files or explicit Connect and download N,
  Change number, optional Start at earlier gap and Cancel are Android's controls.
  Ten items remain in the same bounded scrollable dialog, without a new pager
  route, Next-page button or extra confirmation.
- Count input closes the old preview before opening. Cancel returns to Series,
  not the previous preview. Invalid Review leaves the same input open; Android
  adds neither an error screen nor a disabled Review label. Pro's numeric keyboard
  remains docked at the bottom with content/actions visible above it.
- File choice offers only supported options; a single option skips the chooser.
  Final review includes selected files, sizes/unknown sizes, destination and any
  No supported file · will fail line. Start downloads submits the exact token.
  The explicit review Back button requests another preview.
- Android notices have only Back. “Try again” in notice text is not another Retry
  button. Changed preview/start errors use the existing notice; the first draft's
  Review again screen is removed. Read-capability errors use the existing page
  load error, not a separate unsupported destination.
- Running/paused/terminal results update the same queue sheet. Paused queues show
  Resume remaining when connected or Connect and resume remaining when offline,
  including auth-loss pauses. Connection failure during resume leaves that same
  sheet open. No sign-in redirect, recovery wizard or automatic resume is added.
- Per-row Cancel affects one job. Cancel remaining preserves complete files.
  Completed/canceled rows are disabled; Android can retain the Cancel suffix on
  canceled row text, but it is not an active control. A terminal batch omits
  Cancel remaining. Requested/saved/skipped/failed counts are service values.
  Per-file format, validation and space failures remain queue-row status.
- Back stops queue polling; late callbacks require the same host, series and
  visible dialog. A departed dialog never reopens, and bulk completion never
  opens a book or presents a completion popup. No separate departure, successful
  download or cancellation confirmation screen is proposed.

Library owns selection, current/last-finished anchors, contextual decimal and
secondary-membership order, eligibility, safe destinations and durable queue
policy. It skips read/local/active/recoverable jobs and never wraps. Earlier gaps
require explicit choice and another preview. Incomplete membership disables bulk
action with its reason while existing eligible single-book actions remain.
Unknown bytes/device state stay unknown. UI does not reconstruct a plan by
scanning pages or dispatching unrelated single downloads. One sync writer remains.

## Acceptance after presentation approval

X4 Classic uses logical focus/Select/Back; X3 uses bounded text equivalents.
Pro uses existing row targets and the bottom-docked numeric keyboard. Scroll
windows stay within the eleven-row/16 KiB Series-download snapshot budget;
Series pages use bounded membership windows and deferred scoped covers. Painting
performs no network, parsing, folder scan, queue write or cover acquisition.

Host neutral snapshot/action tests and all three simulator profiles must cover
count bounds, incomplete/secondary membership, unknown sizes, exact-token refusal,
row/all cancellation, restart/resume, account changes and retired delivery.
The maintainer should later verify offline Series → preview → Cancel/Back returns
to the same caller/reader position on X4 Pro, X4 Classic and X3/C3 X4; then check
N=1/3/10, explicit connection, pause/resume and per-book failures. Completed books
must remain and leaving the sheet must prevent auto-open. Agents do not touch
devices. No cache format change/reset is proposed.

Before implementation can merge, three hardware images must report actual bin,
map/static-RAM deltas and at least 131,072 free bytes per app slot. These docs
neither build firmware nor claim hardware/simulator acceptance.

## Documentation validation

Chromium checked all 96 device views at 1200 px and 390 px widths: **192 view
checks**, no clipping, horizontal overflow, broken anchors or page errors.
Checks also cover top-right All (n) placement, existing surface families,
one-button notices, disabled canceled rows and bottom-docked numeric keyboards.
The initial reused revision-1 probe expected a different keypad DOM parent;
the revision-2 check measures its actual bottom edge against the footer and
verifies that actions stay above it. Layout and focus were visually inspected
for the grouped context, saved/offline Series, preview (including ten items),
count editor, queue, per-book error and no-eligible notice on all three profiles.
All **128 existing firmware-gallery articles are byte-for-byte unchanged**.

Repository branding: **3 passing**. Feature matrix: **4 passing**. Android
reference suites: **265 logic checks**, **12 policy tests** and **313 flow checks**
passing. The flow harness emitted two read-only `/settings` mkdir warnings but
finished with zero failures. These checks validate docs and reference behavior;
there is no firmware build, simulator or measured-size claim in this docs PR.

# BookSync F36b book detail — NEEDS APPROVAL

27 November 2026. Docs-only missing-state proposal for PLAN.md F36b, the
`F36a–c` detail/actions increment. No firmware code, Library contract, build input,
submodule pin or shipped feature cell changes. No release or device work.

[Gallery](f36b-detail.html) · [screen inventory](SCREENS.md#f36b-detail-additions--needs-approval).
Every proposed scene has X4 Pro touch, Classic button and bounded X3 text views.
Existing Home revision-16 approval is unchanged. This proposal does **not** grant
approval to any of these additions.

## Why implementation remains off

The approved Home gallery has `shots/x4pro-details.webp` and
`shots/x4c-details.webp`, and `prototype.html:1448–1472` draws the normal X4
detail layout. There is no X3 detail example and no complete three-profile
inventory of detail offline/download/error/removal/Back states in the approved
firmware gallery. `PLAN.md` section 5 requires the exact illustrated state and
approval for additional states. Build neither a speculative X3 adaptation nor
new recovery dialogs. These missing states prevent a complete F36b presentation.

At firmware base `f4eacdaa`, `src/booksync/interface/Library.h:17–65` exposes
bounded queries, cover acquisition, Open and download methods, but no detail,
status/Undo or removal operations; `interface/Commands.h:6` contains only shell
intents. Do not bypass Library to fill those gaps. F20 must provide the durable
finish/status/Undo interface before its presentation can be wired. Detail and
removal values/intents must likewise be published behind Library, with any
service increment reviewed separately. This docs PR does not implement them.

## Android 0.12 reference and differences

Reference: integration commit `aa5c9b9f` on `feature/0.12`; plugin paths below
are relative to `android/koreader/orbit.koplugin/`.

- `ko/reader_panel.lua:428–445`: primary Open/Download is based on saved local
  availability/capability; View series restores the same initiating document.
- `ko/home_host.lua:7–99`: transfer callbacks require a live origin; departing
  clears auto-open. Offline transfer requires Connect and download / Cancel.
  Multiple formats use a chooser; unknown total never invents a percentage.
- `ko/library.lua:579–590`: overflow offers Details, Open/Download, conditional
  View series, capability-gated Mark read/Mark unread, and local removal only.
  Unknown status is not writable. This slice adds no arbitrary status editor.
- `ko/home_host.lua:353–405`: status saves locally, holds Undo, releases on
  Done/close and checks stale replies; removal previews before confirmation,
  rejects open/unavailable files and revalidates the confirmation token.
- `ko/library.lua:595–651`: status/Undo and removal dispatch neutral intents
  through Library. Delivery acceptance is never remote acknowledgment.
- Home `DESIGN.md:439–553`: verified files and reading status are independent;
  native position/sidecars survive removal; missing detail says not saved.
  Display saved rating read-only here; rating editing is a separate F20 surface.

The drawings adapt these meanings to approved firmware frame/focus tokens.
Button focus and recovery wording shown here are proposals where no exact
approved drawing exists. Pro uses touch targets of at least 50 design pixels;
Classic uses an outlined initial action; X3 drops cover artwork and uses short
text/action pages. All data is synthetic. These are design viewports, not
hardware font/physical fit measurements.

## Proposed scene inventory

All rows are **NEEDS APPROVAL** on all three profiles. Normal X4 detail is a
context drawing; existing approval remains authoritative. Initial focus below
applies to button readers. Back closes the current choice and restores its
caller; on detail itself it restores the original list/page/book focus.

| Scene | Presentation | Initial button focus |
|---|---|---|
| [detail-local](f36b-detail.html#detail-local) | Book details | Open |
| [detail-remote](f36b-detail.html#detail-remote) | Book details | Download |
| [detail-offline](f36b-detail.html#detail-offline) | Book details | Open |
| [detail-offline-remote](f36b-detail.html#detail-offline-remote) | Book details | Download |
| [detail-metadata](f36b-detail.html#detail-metadata) | More book information | Previous page |
| [detail-menu](f36b-detail.html#detail-menu) | Book actions | Open |
| [detail-limited](f36b-detail.html#detail-limited) | Book actions | Open |
| [detail-consent](f36b-detail.html#detail-consent) | Not downloaded | Cancel |
| [detail-connect-error](f36b-detail.html#detail-connect-error) | Could not connect | Try again |
| [detail-files](f36b-detail.html#detail-files) | Choose a file | EPUB · Standard · 2.4 MB |
| [detail-download](f36b-detail.html#detail-download) | Downloading | Cancel download |
| [detail-download-unknown](f36b-detail.html#detail-download-unknown) | Downloading | Cancel download |
| [detail-canceling](f36b-detail.html#detail-canceling) | Stopping download | Back |
| [detail-canceled](f36b-detail.html#detail-canceled) | Download canceled | Download |
| [detail-download-error](f36b-detail.html#detail-download-error) | Download stopped | Try again |
| [detail-auth-error](f36b-detail.html#detail-auth-error) | Download unavailable | Back |
| [detail-space-error](f36b-detail.html#detail-space-error) | Not enough space | Back |
| [detail-verify-error](f36b-detail.html#detail-verify-error) | Download could not be verified | Back |
| [detail-link-error](f36b-detail.html#detail-link-error) | Download not ready to open | Try again |
| [detail-ready](f36b-detail.html#detail-ready) | Book details | Open |
| [detail-missing](f36b-detail.html#detail-missing) | Book file not found | Download |
| [detail-open-error](f36b-detail.html#detail-open-error) | Book could not be opened | Back |
| [detail-status](f36b-detail.html#detail-status) | Saved on this reader | Undo |
| [detail-status-error](f36b-detail.html#detail-status-error) | Reading status could not be saved | Try again |
| [detail-undo-stale](f36b-detail.html#detail-undo-stale) | Status changed | Back |
| [detail-remove](f36b-detail.html#detail-remove) | Remove download? | Keep download |
| [detail-remove-blocked](f36b-detail.html#detail-remove-blocked) | Download cannot be removed | Back |
| [detail-remove-error](f36b-detail.html#detail-remove-error) | Download could not be removed | Back |
| [detail-removed](f36b-detail.html#detail-removed) | Book details | Download |
| [detail-back](f36b-detail.html#detail-back) | Return to your list | The Lantern Room |

Undo is proposed only for an F20 status intent, never file removal. Unknown
finish delivery, pending compensation and unavailable prior values belong to
[the separate F20 proposal](https://github.com/Fledgewing/Orbify/pull/240), also
NEEDS APPROVAL; this gallery neither duplicates nor approves those scenes.
Series destination/download-next belongs to F36c and lists/search to F36a.
The Back drawing specifies the return contract, not a replacement list design.

## Implementation and acceptance after approval

UI consumes immutable bounded Library values and typed intents only. The
worker owns lookup, detail normalization, verification, file tokens, storage,
status ordering and the sole sync writer. Never read files, parse, decode,
scan, write or start network during paint. Cover acquisition is post-paint
through F25; no second framebuffer or image decode on X3. Page long description
and memberships instead of keeping an unbounded object. The proposed detail
budget is one bounded book projection, at most 16 KiB; action menu at most five
rows, no paint I/O. Real C3 allocation/static RAM measurements are still required.

Before UI: add host tests compiling production code with neutral Library fakes
for metadata availability, supported files, missing local file, capability
refusal, position-before-finish, Undo/stale token, removal open/replacement
refusal, and owner/epoch isolation. Add matching simulator scenes for
`x4-pro-simulator`, `x4-classic-simulator` and `simulator-X3`: offline first
paint, consent Cancel, known/unknown progress, explicit cancel, each error,
remove Keep/Remove, Back/focus restoration and no late auto-open or repaint.
Test cancel/commit and A → B → A races; zero network/file work during paint.
Retain CrossInk reader regression coverage.

Build `x4-pro`, `x4-classic` and `default`, reporting actual app bytes, map and
static-RAM delta, plus simulator allocation/stack measurements where meaningful.
Each image must leave at least 131,072 bytes of the 6,553,600-byte app slot.
This docs-only proposal provides no firmware binary, host/simulator pass claim
or size measurement. Firmware implementation remains blocked by the missing
approvals and public contracts, not by an assumed size saving.

Maintainer hardware verification after implementation: on Pro touch, Classic
buttons and X3, open detail offline, restore the same list focus with Back,
exercise consent/download/cancel/error, mark read/Undo, confirm removal while
preserving position/annotations, and verify foreground reading is never stolen.
No EPUB cache reset is needed for this presentation work; native files and reader
behavior must remain unchanged. Agents do not access devices or serial ports.

## Documentation validation

The static gallery contains 30 proposed states and 90 device views. Browser QA
at 1200 px and 390 px checks all internal scene anchors, action/footer bounds,
screen width and page overflow, with zero page errors. Six representative
three-profile scenes are rendered for visual inspection: local detail, actions,
offline remote detail, unknown-total download, pending status/Undo and removal.
These checks establish documentation fit only, not firmware rendering or hardware
acceptance. The feature-reference suite remains unchanged and passes 4 tests.

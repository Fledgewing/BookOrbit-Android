# F36a Library and lists — APPROVED (2026-11-28)

Maintainer approval: **APPROVED (2026-11-28)**, ~00:45 PT: “I approve all the screens / widgets”.
All revised compact scenes and states are approved; implementation and device acceptance remain required.
[Gallery](f36a-library.html) · [plan F36a–c](PLAN.md) · [inventory](SCREENS.md).
All 30 state variants have X4 Pro touch, X4 Classic button and X3 text views.

F36a owns Library counts, browse roots, grouped author/series lists, On card,
saved Smart-scope/list selection and the shared list view. F36b owns book
detail/actions; F36c owns Series and download-next. This proposal draws only the
F36a entry/return boundary to those owners, never their panels. No firmware source,
submodule pin, feature cell, release or existing approval changes.

## Approval coverage

The approved Home revision-16 gallery has `x4pro-list-by-series` and
`x4c-list-by-series`, plus Library low-space views. Its general Library/list
screens are Android examples, and it has no X3 catalog/list scene set.
The firmware B1–B5 inventory has no F36a Library/list entries. General text fallback
rules do not illustrate the required X3 offline, Back, download and error scenes.
The [F36a assignment](PLAN.md) requires approved scenes in every profile; the
previously missing presentations are now approved by this record. Existing approved Home
and B1–B5 presentations retain their approval.

## Android 0.12 evidence

Audited integration commit: `aa5c9b9f202e030d6636b07df15837b031501aed`.
Paths and line numbers below refer to that immutable commit, read locally.
The plugin is the behavior reference; this gallery proposes firmware presentation.

- `android/koreader/orbit.koplugin/ko/storage.lua:47` and `:126`: Library totals,
  on-device availability, capability-filtered browse roots and bounded source pages.
  Author/series roots open grouped book lists; every root remains reachable.
- `android/koreader/orbit.koplugin/ko/home_host.lua:331`, `:427`, `:440`, `:461`
  and `:502`: source/scoped list dispatch, one shared list/filter owner, cursors,
  nested navigation and Back restoration.
- `android/koreader/orbit.koplugin/ko/series.lua:115` and `:158`: grouped query,
  contextual membership, partial group links, complete counts, saved progress
  and actual previous-page cursors. A series header opens the separate Series owner.
- `android/koreader/orbit.koplugin/ko/home_host.lua:4`, `:42`, `:57`, `:90`:
  download chooser, explicit offline consent, job deduplication, cancel/resume and
  completion scoped to the originating owner. A late result cannot open a book.
- [Home design §§3.2, 4–5](../booksync-home/DESIGN.md) and
  [revision-16 notes §§3, 9–11](../booksync-home/DESIGN-NOTES.md): known empty versus
  missing coverage, paged lists, neutral filters and X3 text controls. Saved list
  identities are opaque; UI never evaluates Smart-scope rules or saves server lists.

## Photo comparison and Android parity revision

The maintainer’s supplied 0.11 X4 Home and Library photographs were inspected
locally. The Library photograph governs **density and layout**: Discover cover
row, Recently added cover row, then a 2 × 2 grid of compact half-width tiles.
Catalog shows **10020 books**, Authors **2725**, Series **1480**, and On card
**6 books · 5 BookOrbit**. Each tile has a large number and a top-right outline
icon. There is no menu-row replacement for these tiles. The Home photograph
confirms dense cards and a top-right All link in a shelf header.

The revised proposal puts **All (n) › at the top-right of every relevant header**:
Discover, Recently added and partial author/series groups. Known complete groups
show n books without an All link. Unknown coverage does not invent n; use an
unknown marker and retain the existing incomplete-state rules. Shelf icons sit
at the far right alongside the All link. List counts and tile values are Library
projections, not UI-calculated totals. On-card source attribution is supplied as
neutral display metadata; the photograph’s source label is an example, not a
backend condition or a new firmware API field.

Private photographs are not committed, embedded or linked from this proposal;
no personal greetings, names, titles or artwork were transcribed. The displayed
numbers are the requested illustrative reference values. Cover drawings and book
titles are synthetic. X3 preserves order and actions as bounded text, without
cover bitmaps. This is a photo comparison, not a device test.

Android 0.12 remains the **behavior** reference. The current audit also inspected
`ko/reader_panel.lua:300` and `:485`: Details uses the existing ReaderPanel details
owner, not another catalog summary page. F36a draws only its list return, keeping
page, filters and focus; F36b retains that owner’s metadata, missing-data states,
series links and supported actions. Tap/Select uses the existing open/download
path; More/long press opens existing actions and Details. No new detail navigation
or details-before-download fetch is introduced here.

Every gallery article now names an existing surface: the Library dashboard,
Android’s Browse library index (`ko/storage.lua:126`), shared scoped/grouped list,
file chooser, offline-consent dialog, existing no-login prompt, or job-info dialog.
Preparing and errors are variants within the existing list; completion updates
availability rather than opening a new success screen. Browse library is the
existing root index behind Catalog, not an added second Library page. Existing
filter and Series owners are reused, never duplicated. No article authorizes a
screen or destination absent from Android 0.12. Source evidence remains pinned
to the audited commit above; this revision changes docs only.

The four-cover Discover row is the requested presentation target. Android’s
current Discover provider has a one-book/16 KiB budget. As in the parallel compact
widget proposal, a four-book row needs a separate bounded provider/projection
increment before implementation; these docs do not widen any budget, change
Android behavior or authorize catalog work during paint.

## Presentation and ownership

The gallery uses the grayscale frame vocabulary with proposed F36a content and
focus, revised against the maintainer’s two 0.11 X4 photographs. The previous
sparse menu layout is superseded. On card is the firmware wording for the neutral On this device
filter, not a different availability rule. Counts have published coverage and
provenance. Unknown totals are not zero; account revocation is not empty data.
Missing covers use existing F25 placeholders; no cover implies file availability.

Library entry and paint never connect. Services own sorting, joins, counts,
querying, storage, transfer and validation behind Library. Paint consumes a bounded
published value only, with no parse, file access, scan or network. No adapter DTO,
credential, mutable store or raw job is exposed. One sync writer remains in charge.

Pro taps rows or page arrows. Classic/X3 Prev/Next move the focus through rows,
actions and footer arrows; Select activates and Back restores the parent. Pages
never split a row or strand a group heading. Focus starts at the first outlined
row/action except the explicit Back-restoration scene. X3 uses text without cover
art or another framebuffer. Runtime dimensions and safe bounds govern firmware;
these design frames are not measured font fit on the physical X3 panel.

The existing approved filter design remains the semantic reference; this proposal
shows its entry/return only. Additional missing filter/picker states need explicit
approval before implementation, rather than being inferred from this gallery.
An account or Series handoff likewise requires its own slice's approved states.

Offline tap: Cancel/Back starts nothing; Connect and download explicitly admits
connection, then the normal supported-file chooser. Download progress is coarse,
unknown size shows bytes, and cancellation never deletes a complete file.
Leaving the initiating view retires auto-open and late repaint ownership while
retaining durable work. Preparing, unsupported-file, space and access failures are inline row states;
verified completion changes the row to On card or opens only for the eligible
initiating owner. There is no preparing, failure or completion destination.
User-opened job information may show Resume; background
completion cannot reopen a closed screen, steal reading focus or restart a device.

## Proposed scenes — every row APPROVED (2026-11-28)

| Scene | Existing surface | Example state |
|---|---|---|
| [library](f36a-library.html#library) | Library dashboard | Saved catalog · 10,020 books |
| [library-browse](f36a-library.html#library-browse) | Existing Browse library index | Saved catalog indexes |
| [library-offline](f36a-library.html#library-offline) | Library dashboard | Offline · Saved catalog |
| [library-missing](f36a-library.html#library-missing) | Library dashboard | Catalog not saved yet |
| [library-loading](f36a-library.html#library-loading) | Library dashboard | Loading saved catalog |
| [library-error](f36a-library.html#library-error) | Library dashboard | Could not load the catalog |
| [authors](f36a-library.html#authors) | Shared list | 10,020 books · By author |
| [series-groups](f36a-library.html#series-groups) | Shared list | 10,020 books · By series |
| [on-card](f36a-library.html#on-card) | Shared list | 6 verified books |
| [lists](f36a-library.html#lists) | Shared list | 12 saved lists |
| [scope](f36a-library.html#scope) | Shared list | 84 books · Saved list |
| [list-page](f36a-library.html#list-page) | Shared list | 10,020 books · List order |
| [list-back](f36a-library.html#list-back) | Shared list | 84 books · Saved list |
| [list-empty](f36a-library.html#list-empty) | Shared list | 0 books · Complete saved result |
| [list-missing](f36a-library.html#list-missing) | Shared list | Not saved yet |
| [list-incomplete](f36a-library.html#list-incomplete) | Shared list | Saved membership incomplete |
| [list-error](f36a-library.html#list-error) | Shared list | Could not load this list |
| [lists-unsupported](f36a-library.html#lists-unsupported) | Existing source-list availability state | Unavailable from this source |
| [download-options](f36a-library.html#download-options) | Existing Download chooser | The Paper Coast |
| [download-offline](f36a-library.html#download-offline) | Existing offline-consent dialog | The Paper Coast |
| [download-preparing](f36a-library.html#download-preparing) | Shared list · inline row state | The Paper Coast |
| [download-progress](f36a-library.html#download-progress) | Existing download-job information dialog | The Paper Coast |
| [download-unknown](f36a-library.html#download-unknown) | Existing download-job information dialog | The Paper Coast |
| [download-failed](f36a-library.html#download-failed) | Existing download-job information dialog | The Paper Coast |
| [download-canceled](f36a-library.html#download-canceled) | Existing download-job information dialog | The Paper Coast |
| [download-unsupported](f36a-library.html#download-unsupported) | Shared list · inline row state | The Paper Coast |
| [download-login](f36a-library.html#download-login) | Existing no-download-login prompt | The Paper Coast |
| [download-space](f36a-library.html#download-space) | Shared list · inline row state | The Paper Coast |
| [download-access](f36a-library.html#download-access) | Shared list · inline row state | The Paper Coast |
| [list-saved](f36a-library.html#list-saved) | Shared list · verified availability | Download complete · originating list retained |

## Acceptance after approval

Before implementation, add neutral snapshot/action host tests for all roots,
scoped opaque IDs, correct counts/coverage, grouped fractional/secondary membership,
complete versus partial groups, local availability, filters, actual page cursors
and nested Back/focus restoration. Add download consent/chooser/dedup/cancel/resume,
unknown size, space/access/unsupported failures, account switch and retired-owner
completion cases. UI includes only Library/public values and approved graphics/input.

Run every approved scene on `x4-pro-simulator`, `x4-classic-simulator` and
`simulator-X3` with synthetic SD/NVS and fake transport. Prove zero paint I/O,
o automatic connection on entry, no stale result redraw/open, unchanged reader
position and no presentation over foreground reading. Run the firmware host and
boundary suites, three real builds and required BookSync firmware check; report
actual image/map/static RAM deltas and at least 131,072 free application bytes per
device. Simulator heap is not hardware acceptance.

Maintainer hardware verification after implementation: on X4 Pro tap Library,
Authors, Series, On card and a saved list; use only buttons for the same path on
Classic and X3. Page a grouped list, return from a panel and confirm page/focus;
open an on-card EPUB and return at its unchanged position. With Wi-Fi off, verify
saved lists still work and remote selection asks consent; Cancel connects to
nothing. Test a download failure and Back before completion: no late navigation,
restart or reading overlay. No parser/cache format changes are proposed, so no
EPUB cache reset is required. Agents do not access devices or serial ports.

## Documentation verification

Browser checks passed for all 30 scenes / 90 device views at both 1200 px and
390 px: no clipped content, broken scene anchors, page errors or horizontal
overflow. Local gallery destinations exist. Library, offline Library, grouped lists, Back restoration and download dialogs
were rendered and visually inspected against the density reference. Repository branding (3 tests), feature
references (4 tests) and `git diff --check` pass. These results validate mockups,
not firmware functionality, performance or memory fit. Host/simulator scenarios and hardware image sizes are intentionally
unmeasured because this PR contains no implementation.

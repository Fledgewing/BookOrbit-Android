# F36a Library and lists — NEEDS APPROVAL

27 November 2026. **Docs-only proposal. No new scene is approved by this PR.**
[Gallery](f36a-library.html) · [plan F36a–c](PLAN.md) · [inventory](SCREENS.md).
All 30 scenes have X4 Pro touch, X4 Classic button and X3 text views.

F36a owns Library counts, browse roots, grouped author/series lists, On card,
saved Smart-scope/list selection and the shared list view. F36b owns book
detail/actions; F36c owns Series and download-next. This proposal draws only the
F36a entry/return boundary to those owners, never their panels. No firmware source,
submodule pin, feature cell, release or existing approval changes.

## Why this needs review

The approved Home revision-16 gallery has `x4pro-list-by-series` and
`x4c-list-by-series`, plus Library low-space views. Its general Library/list
screens are Android examples, and it has no X3 catalog/list scene set.
The firmware B1–B5 inventory has no F36a Library/list entries. General text fallback
rules do not illustrate the required X3 offline, Back, download and error scenes.
The [F36a assignment](PLAN.md) requires approved scenes in every profile; those
missing presentations stay off until explicit approval. Existing approved Home
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

## Presentation and ownership

The gallery uses the approved grayscale frame vocabulary with proposed F36a
content and focus. On card is the firmware wording for the neutral On this device
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
retaining durable work. User-opened job information may show Resume; background
completion cannot reopen a closed screen, steal reading focus or restart a device.

## Proposed scenes — every row NEEDS APPROVAL

| Scene | Title | Example state |
|---|---|---|
| [library](f36a-library.html#library) | Library | Saved catalog · 2,418 books |
| [library-more](f36a-library.html#library-more) | Library | Saved catalog · 2,418 books |
| [library-offline](f36a-library.html#library-offline) | Library | Offline · Saved catalog |
| [library-missing](f36a-library.html#library-missing) | Library | Catalog not saved yet |
| [library-loading](f36a-library.html#library-loading) | Library | Loading saved catalog |
| [library-error](f36a-library.html#library-error) | Library | Could not load the catalog |
| [authors](f36a-library.html#authors) | Authors | 2,418 books · By author |
| [series-groups](f36a-library.html#series-groups) | Series | 2,418 books · By series |
| [on-card](f36a-library.html#on-card) | On card | 312 verified books |
| [lists](f36a-library.html#lists) | Your lists | 12 saved lists |
| [scope](f36a-library.html#scope) | Short reads | 84 books · Saved list |
| [list-page](f36a-library.html#list-page) | All books | 2,418 books · List order |
| [list-back](f36a-library.html#list-back) | Short reads | 84 books · Saved list |
| [list-empty](f36a-library.html#list-empty) | Short reads | 0 books · Complete saved result |
| [list-missing](f36a-library.html#list-missing) | Short reads | Not saved yet |
| [list-incomplete](f36a-library.html#list-incomplete) | Series | Saved membership incomplete |
| [list-error](f36a-library.html#list-error) | Short reads | Could not load this list |
| [lists-unsupported](f36a-library.html#lists-unsupported) | Your lists | Unavailable from this source |
| [download-options](f36a-library.html#download-options) | Download | The Paper Coast |
| [download-offline](f36a-library.html#download-offline) | Not downloaded | The Paper Coast |
| [download-preparing](f36a-library.html#download-preparing) | Preparing download | The Paper Coast |
| [download-progress](f36a-library.html#download-progress) | Downloading | The Paper Coast |
| [download-unknown](f36a-library.html#download-unknown) | Downloading | The Paper Coast |
| [download-failed](f36a-library.html#download-failed) | Download stopped | The Paper Coast |
| [download-canceled](f36a-library.html#download-canceled) | Download canceled | The Paper Coast |
| [download-unsupported](f36a-library.html#download-unsupported) | Cannot download this book | The Paper Coast |
| [download-login](f36a-library.html#download-login) | Download unavailable | The Paper Coast |
| [download-space](f36a-library.html#download-space) | Not enough space | The Paper Coast |
| [download-access](f36a-library.html#download-access) | Download unavailable | The Paper Coast |
| [download-saved](f36a-library.html#download-saved) | On card | The Paper Coast |

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
overflow. Local gallery destinations exist. Library and offline-consent scenes
were rendered and visually inspected. Repository branding (3 tests), feature
references (4 tests) and `git diff --check` pass. These results validate mockups,
not firmware functionality, performance or memory fit. Host/simulator scenarios and hardware image sizes are intentionally
unmeasured because this PR contains no implementation.

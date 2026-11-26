# F12-I: Android Home editor

Android implementation authorised 2026-11-25, overriding DESIGN.md §8.8's earlier
no-code/parallel-platform restriction for this build. The approved source is
`origin/design/booksync-home`: DESIGN.md §3.5 (widget contracts/layout-as-data),
§6 (adapter boundary), §8.5 (stages), DESIGN-NOTES.md revision 8+,
layout.schema.json and prototype.html (`android-tablet`, four columns).
X4 Pro, X4 and X3 follow in the firmware implementation. No release or device
acceptance is claimed.

## Reuse

References below are to the starting feature/0.12 commit `543d67d`:

- `ko/home_host.lua:4` consumes the same `S.home_layout`; `:11` supplies the
  installed renderer subset and `:29` owns capability reads through Library.
- `ko/home_widgets.lua:4` registers installed widgets; `:18-31` supplies canvas,
  placement, text and button helpers. `logic/home_host.lua:13` supplies grid-to-pixel
  rectangles and `:51` supplies the capability-filtered projection. Picker eligibility
  uses that same projection, never adapter identity or server JSON.
- `logic/layout.lua:226`, `:257`, `:285`, `:312`, `:319` and `:353` already own
  move/resize, add/remove, pages and atomic save. This slice adds only a current-page
  projection and save-boundary empty-object tags for KOReader's dkjson encoder.
- `ko/cache.lua:29`, `:40-60` already supply the data directory, bounded file reads
  and atomic temp-file rename. Layout.save retains a previous-valid `.bak` before
  replacing `home-layout.json`. No new storage implementation or catalog is added.
- `ko/sleepscreen.lua:450-470` already uses KOReader InputDialog, getInputText and
  onShowKeyboard; the editor uses the same keyboard flow.

KOReader pin `9192014d8bd82a91dc1012473be0f238dedfdb54` points its `base` submodule
to `6e4bc81af4e04f78d81677a323a780a71b29702a`. At that base commit,
`thirdparty/dkjson/CMakeLists.txt:4-9` installs dkjson.lua 2.10 in `common`.
Its object/array tags and an explicit null sentinel preserve unknown JSON fields;
trailing input is rejected. No upstream server behaviour is relied upon.

## Interaction and storage

The opt-in Home has an Edit button. Tap a tile to select it, then use the four
arrows, Size (only declared spans), or Remove. Collisions and failed moves use the
existing layout engine and show feedback without replacing the last valid draft.
The picker shows installed, capability-eligible widgets with names, descriptions
and every allowed size. Free cells open that picker with a preferred slot. Add
tries the allowed sizes and creates a page if none fits the current page.

Pages can be added after the current page, deleted, reordered, and renamed by the
page name or Rename button with KOReader's keyboard. Automatic names come from
the first widget; manually named pages retain their names. Reset and page deletion
ask for confirmation. Unknown/uninstalled placements remain reserved and preserved;
they never execute a renderer or read data in the editor.

Draft operations are pure and leave the published document untouched. Done (or
Back after leaving picker/selection) validates and saves through Layout.save.
Only a successful save replaces S.home_layout and redraws Home. Write failure
keeps the editor open with feedback and retains the previous primary/backup.
On restart Home loads the saved layout once, recovering its previous valid backup
or defaults; recovery feedback is shown in the editor. The existing library API
and companion read model need no new operation for layout editing.

## Performance rule

Every screen and widget declares a strict budget; library calls inherit it.
Filtering, sorting, grouping, counts, search, stats, battery estimates and catalog
joins remain companion work. The editor draws geometry only, never widget snapshots.
`logic/budgets.lua` declares editor and picker limits: current-page placements
at most 128, at most 208 draw controls, picker at most three rows/24 controls,
zero decoded bytes, subprocesses, render network and companion round-trips.
Move tests poison unrelated pages and assert every deterministic ceiling; encoding,
full-document validation and IO happen on Done, never on arrow presses.

Info spans cover operation, draw construction, actual paint and save. Editor controls
are 50 logical px tall; default M8C grid cells exceed that size. Size, rename and confirmation dialogs inherit the editor screen family. The <100 ms move
and <500 ms Home device targets remain unconfirmed; host timing proves neither.
No device, adb, tag or release was used.

## Follow-on slices

The editor consumes HomeWidgets.register and registry name/description/sizes, so
new independent renderers automatically appear when installed and capability-eligible.
Book-list configuration can use the existing FilterView onSave callback and add
settings edits through the layout engine. Device visual/performance acceptance
and firmware editors remain with the later platform work.

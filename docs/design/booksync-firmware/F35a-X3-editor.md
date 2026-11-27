# F35a X3 Home editor — NEEDS APPROVAL

Status: **NEEDS APPROVAL**. Merging this proposal does not approve its presentation.
The approved Home design §3.5 specifies an X3 Settings list, but revision 16's
screenshots/prototype illustrate only the X4 editor. F35a implements the shared
service and approved X4 presentations; the X3 editor remains disabled.

[Proposed X3 scenes](f35a-x3-editor.html). Synthetic data only. No keyboard.

- Entry: Settings → Home widgets. Previous/Next changes row focus; Select opens
  or activates; Back returns. Focus stays on a visible row after every operation.
- List: installed Continue reading, Shelf and Browse instances, an Add widget row,
  Reset layout and Done. Select an instance to offer Remove / Keep; Keep starts
  focused. Unsupported instances remain saved and occupy their cells.
- Add: Continue reading / Shelf / Browse only. Select requests a new instance in
  available cells; no space leaves the layout unchanged and shows a bounded error.
- Reset: Keep layout (initial focus) / Reset layout. Reset affects Home layout
  only, never books, reading state, pairing or pending sync work.
- Save failure: retain the previous complete revision; Back returns to the list.
  Retry is an explicit new intent, never an automatic destructive fallback.

The UI uses Library values/intents only; worker-side changes are revision-checked,
validated and atomically published using F33. No paint I/O. Add/remove/reset are
F35a; reorder belongs to F35b, page operations to F35c. Device acceptance remains
pending; no hardware or serial access is part of this proposal.

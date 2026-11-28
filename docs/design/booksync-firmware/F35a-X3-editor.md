# F35a X3 Home editor — APPROVED (2026-11-27)

Status: **APPROVED (2026-11-27)** by the maintainer at approximately 18:45 PT.
The Settings list and all six illustrated states are approved for F35a implementation
on the shared editor service. Device acceptance remains pending.

[Approved X3 scenes](f35a-x3-editor.html). Synthetic data only. No keyboard.

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

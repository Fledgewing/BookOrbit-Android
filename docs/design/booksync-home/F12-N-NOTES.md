# F12-N · Android server and login screens

Authorised Android-first implementation of the approved prototype's account flows (§20–§22
of `DESIGN-NOTES.md`, `origin/design/booksync-home`), 2026-11-25/26. The M8C uses the
Android tablet profile; these forms do not change the four-column Home layout-as-data.
X4 Pro, X4 and X3 follow later. Phone setup is a labelled “on the X4 build” stub.

## Reuse

- `ko/library.lua:71`: the existing bounded `account.state` read, plus an explicit neutral
  command entry point. `ko/library_bookorbit.lua:133` already queued and polled private worker
  commands; extend that port instead of creating a second transport.
- `ko/menu.lua:173`: existing grouped settings and budgeted paints. Your server uses this
  group; its account/login forms reuse the native ButtonDialog/keyboard pattern from
  `ko/filter_sheet.lua:114` and `ko/menu.lua:137`.
- `ko/home_host.lua:26`: the existing Home paint and capability snapshot; its account member
  supplies the subtitle without another read. `ko/reader_panel.lua:30` does the same for
  the user-opened reader top panel. No layout engine or widget renderer is duplicated.
- `LibraryAccount.kt:41`, `ServerCommands.kt:11`, `ServerAdapter.kt:6`: the same serialized
  companion worker, bounded command jobs and neutral adapter operations as F12-K.
  `BookOrbitServerAdapter.kt:21` normalizes display identity/outcome alongside its existing
  encrypted credential provenance. No UI understands server JSON, endpoints or auth headers.
- Native keyboard verification: pinned KOReader
  `9192014d8bd82a91dc1012473be0f238dedfdb54`,
  `frontend/ui/widget/inputdialog.lua:381` passes `text_type` to the masked field;
  `:594` clears it with `setInputText`. The compatibility inventory includes that method.

## Performance and ownership

Every screen and widget has a strict budget, inherited by its library calls. The companion
owns filtering, sorting, grouping, counts, search, stats, estimates and joins; Lua draws only
small windows. Account summary, form, confirmation and result screens share the account
budget: three state rows, 16 KiB decoded, zero subprocesses, zero render network calls,
at most one queued batch. Display controls have a separate twelve-row ceiling. Each paint
and explicit command logs an info timing span without field values. Host checks do not
prove the proposed device targets (Home <500 ms, widget <50 ms, cached library <30 ms,
editor <100 ms). Device acceptance remains pending; no device was accessed.

The existing lifecycle state call now also returns a bounded public snapshot, containing
only display names/addresses, availability, provenance and provisioning outcomes. Its
in-memory adapter copy works before any catalog namespace exists and after sign-out. Home
and the reader reuse that state inside their capability row. There is no paint-time provider
call. Account commands accept transient typed secrets; provider results, cached state, jobs,
settings and logs never contain passwords, derived keys or tokens. Native input fields and
form password state clear after use, dispatch or cancellation.

Back invalidates an attempt generation; late success/error cannot resurrect the form. A
successful result lists Found/Created/Kept independently for both connectors. Failed provisioning
says Not set instead of claiming success. Done focuses the first changed login, or Sign in
again when neither changed. Remove focuses Keep it first; sign-out focuses Stay signed in.
Only account-origin logins are removed by sign-out, matching the existing encrypted-store rule.

The neutral command port adds `account.signIn`, `account.signOut`, `login.save`,
`login.remove`, and `login.replace` over existing LibraryAccount operations. This is an
additive interface extension, not a second account implementation. The pinned server has no
native two-step challenge; the UI accepts the neutral two-step error for adapters that do,
and labels the deferred phone path honestly. HTTP 404/426 at sign-in maps to server-too-old.
Browser/OIDC and firmware phone pairing remain later work.

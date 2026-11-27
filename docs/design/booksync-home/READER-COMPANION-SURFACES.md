# Reader-inline companion surfaces — NEEDS APPROVAL

This is a proposal for the Android 0.12 “No visible app switches” stretch outcome,
not approval or implementation. [Mockups](reader-companion-surfaces-mockups.html)
cover the new visible controls. Keep building the already approved reader menus,
transfers and add-on behavior while this proposal awaits the maintainer.

## Existing behavior and the real gap

Background account/catalog/position work already uses companion services and the
Library interface. Owned Home, account forms and reader settings stay in KOReader.
The add-on restart bridge is already visually transparent: `Mode.kt:192`,
`AndroidManifest.xml:183–187` and `res/values/styles.xml:25–31` make it translucent,
without preview, background, dimming or a recent-task entry. Its presence is not
evidence of a drawn companion screen. All Android paths below are relative to
`android/companion/app/src/main/` unless prefixed otherwise.

The remaining ordinary transitions are explicit reader actions:
`android/koreader/orbit.koplugin/ko/library_services.lua:35–47` opens companion
status, helpers, PIN or setup. The approved add-on helper deep-link deliberately
opens that existing companion surface; it does not approve an inline replacement.
A universal no-switch promise would also misrepresent Android permission/security
screens, protected parent settings, launching another app and manual APK install.
Those remain explicit, clearly labeled user actions under this proposal.

## Proposed slice and states

1. **Reader Status:** a bounded local summary, last sync/update state and at most
   four actionable checklist rows. No automatic page opening, notifications or
   prompts while reading. Unknown/stale state stays visible as unknown/stale.
2. **Reader Helpers:** existing Wi-Fi switching and Sleep sync controls inside an
   owned reader sheet. Read state and capability from Library; preserve add-on
   defaults and the existing protected settings policy. Changes requiring the PIN
   go through the existing protected companion flow, not a new reader PIN handler.
3. **Permission required:** explain what is off and what the user loses, with
   **Open Android settings** and **Later**. Never claim a permission was granted
   until the companion observes it on return. Granting permission does not turn a helper on; the reader makes that choice explicitly. No invisible permission acceptance.
4. **Return:** restore the exact reader/menu context after an explicitly requested
   system action. If the book/session changed, discard that context. A background
   permission change updates saved state only and never reopens a sheet.

The approved external companion entry remains a recovery route. Native Android
security, a parent challenge and opening another application remain visible when
requested. The stretch outcome is “ordinary BookSync status and helper actions
stay in the reader”; it is not permission to hide or bypass those boundaries.

## Interface, budgets and acceptance after approval

- UI requests one neutral summary/helper snapshot through Library, no backend
  names, endpoints, credential parsing or direct companion implementation types.
- At most four summary/action rows and one 16 KiB snapshot per sheet; zero paint
  network/forks/scans and at most one batch. New controls inherit reader tokens.
- Background service events may invalidate an already visible sheet; they cannot
  show one. Missing/mismatched companion uses the one existing worker-problem gate.
- Reuse current settings/mode/helper policy and encrypted credentials. No alternate
  sender, migration rewrite, password retention or version-skew fallback.
- Tests must cover Full/add-on, missing/denied/revoked permission, protected changes,
  departure and another book opening, return without focus theft, bounded replies,
  and the existing emulator reading/upgrade flows. Physical acceptance is separate.
- Android only in this slice. All three firmware platforms retain their separately
  planned settings surfaces; no firmware source or pin is changed by this proposal.

## Approval requested

Approve the four mocked states, their wording and the bounded ordinary-action
scope above. Until then, keep these new reader surfaces unbuilt and list this
outcome as **NEEDS APPROVAL**. The existing explicit companion routes remain.

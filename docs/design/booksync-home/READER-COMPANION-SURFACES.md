# Reader-inline companion surfaces — APPROVED (2026-11-27)

Maintainer approved the four [mocked states](reader-companion-surfaces-mockups.html)
and this Android 0.12 scope on 2026-11-27. Approval includes the coordinator
change: Reader Status and Reader Helpers use Library snapshots; only an explicit
user-requested system action may depart and restore its still-current context.
Permission never enables a helper, PIN stays in the protected companion flow,
and background changes never show a sheet.

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
Those remain explicit, clearly labeled user actions under this approved scope.

## Approved slice and states

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

## Interface, budgets and acceptance

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
  planned settings surfaces; no firmware source or pin is changed by this slice.

## Approval recorded

The four mocked states, wording and bounded ordinary-action scope above are
**APPROVED (2026-11-27)**. The existing explicit companion recovery routes remain.

## Implementation on feature/0.12

Reader Status and Reader Helpers are owned KOReader sheets. Their interface service
reads the caller-checked `READER_COMPANION` local snapshot, with four materialized
rows, at most 16 KiB and one call per paint. Static controls have a nine-row display
ceiling. Snapshot and paint emit one timing span each. Setup and update checks are
labeled saved/unknown; no checklist, catalog, folder or network scan runs on paint.

The existing policy matters here: Full mode includes the helpers; Add-on's existing
Wi-Fi and Sleep sync opt-ins remain off by default. Sleep sync itself does not need
the lock-screen permission. The permission explanation therefore names **Screen
off after sync**, the operation that actually requires it. Granting it neither
sets the screen-off helper nor enables Sleep sync. The normal worker owns helper
writes and rechecks protection, mode and permission at execution time. A successful
write follows the existing service/status lifecycle and refreshes capabilities.

The explicit system action uses an isolated transparent activity for a result.
Android rejects device-admin consent started as a new task; the bridge starts that
child from a foreground activity with no NEW_TASK flag. It never paints a companion
screen, asks for a PIN or changes a helper. Protected settings and recovery open
the existing native pages only when requested.

Library owns a one-use ticket for the exact reader instance/document/session.
The sheet remembers its page, focus and underlying menu. Only foreground return
after an actual departure can consume the ticket; a changed book, reader session
or underlying menu drops it. Helper completion may redraw only the still-visible
foreground initiating sheet. A background permission change cannot issue a return
ticket or open a sheet.

Reproduce the unit and native evidence with:

```sh
luajit android/koreader/test/test_logic.lua
luajit android/koreader/test/test_flows.lua
python3 tools/test/test-ui-boundary.py
python3 tools/test/test-server-boundary.py
python3 tools/test/test-features.py
(cd android/companion && ./gradlew verifySharedVersion testDebugUnitTest assembleDebug lintDebug)
python3 tools/e2e/android/test_driver.py
python3 tools/e2e/android/reader_companion.py --serial emulator-N --out /tmp/reader-companion
python3 tools/e2e/android/review.py --serial emulator-N --out /tmp/reader-review
```

Use the existing [upgrade/fresh-install flow](../../../tools/e2e/android/README.md)
after these checks. Physical reader acceptance remains separate; no release is
part of this implementation.


Native Android 14 review captures (1200×1600, synthetic books/accounts):
[Status](evidence/reader-companion/status.png),
[Helpers](evidence/reader-companion/helpers.png),
[permission explanation](evidence/reader-companion/permission.png),
[return with permission available and the helper still off](evidence/reader-companion/return.png),
[existing protected settings](evidence/reader-companion/protected.png).


Validation on 2026-11-27: 261 Lua logic tests and 308 flow tests passed; Companion
ran 919 JVM tests with zero failures/errors and four existing skips (915 passed),
plus shared-version verification, debug assembly and lint. UI/server boundary
guards passed all 18 tests, feature generation all four checks, and emulator host
safety all ten checks. Native Android 14 passed 15 reader-companion checks, the
existing 68-screen reading review, three Add-on recovery checks, and the four
upgrade/fresh-profile captures. Upgrade retained the seven-minute idle setting and
synthetic sentinel and verified the once-only news acknowledgment. All device
commands targeted the disposable emulator; no physical reader was used.

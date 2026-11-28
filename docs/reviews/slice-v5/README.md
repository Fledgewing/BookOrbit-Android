# V5: native companion visual review

[Comparison gallery](index.html). Each image places the approved crop or explicitly
labelled family reference on the left and the native capture on the right.

This change owns native Kotlin presentation. `CompanionStyle` supplies the shared
system typefaces, scale, insets, card shapes and drawn section icons; `Ui` applies
them to the existing View controls. It changes neither the settings schema nor
Library commands, permission policy, checklist state rules or X1 routing. The
three edits in `LauncherActivity.render` change tile presentation only.

Native coverage: Full and Add-on status, the Settings overview and all eight
sections (including lower scroll positions), helper recovery and locked settings,
Setup needs-you/all-set/group/battery, local-goal off/editor/on, and crash
saved/empty/cleared/unavailable. The all-set and expanded-group pictures use the
production checklist renderer with immutable synthetic completed rows in an
external fixture Activity. The other native pages are their production Activities.

## Validation

- `tools/e2e/android/build.py` fixture build, preserving strict dependency verification.
- A dedicated Android 14 ARM64 AVD at 1404×1872, 300 dpi. The fixture uses the repo's
  fake ServerAdapter and EPUB/covers/series/reading-sidecar seed, without HTTP.
- `./gradlew lintDebug testDebugUnitTest --tests '*ChecklistPageTest' --tests '*SettingsPagesTest' --tests '*LocalReadingSettingsTest' --tests '*UiPagesTest'`:
  29 passed, zero skipped; lint zero errors, 36 warnings.
- The launcher Settings regression taps the new tile container and verifies its
  unchanged SettingsActivity destination. The existing smaller-reader checklist
  fit assertion also passes.
- The existing `reader_companion.py` flow **failed**, at its first status assertion:
  the fresh profile's initial KOReader color-rendering notice was still visible
  over the status sheet. It was not retried into green. Later direct Lua sheet
  captures dismiss exactly that notice and demonstrate appearance only; they do
  not establish external permission-return acceptance.

No physical reader, release, signing policy, dependency update or upstream change.

## Remaining differences

- The reader status/helpers/permission/return sheets are Lua ButtonDialogs. They
  remain visibly different from their approved HTML (typography, vertical action
  layout and sheet geometry). V5's Kotlin changes cannot style these widgets;
  they are included in the gallery as unresolved, rather than claimed as matched.
- The Full launcher reference predates §5.9's extra Setup/status inventory. Its
  primary tile is shorter to keep the current inventory visible, and Companion
  remains renamed Settings as that section requires. The settings callback and
  KOReader/Home behavior are unchanged.
- `companion-settings.md` references `settings.html`, which is absent from the
  branch and its original design commit. The Settings comparison uses the
  supplied reader-family images, clearly marked as references, while retaining
  the companion's specified search/eight-section inventory and controls.
- Android renders system sans/serif and its own status/navigation/IME chrome.
  Browser samples use the host's system fonts and illustrative chrome. E-ink
  ghosting and physical timing are not measured by an emulator.
- Snapshot fields, current version, clock, permissions and synthetic content
  differ from sample values. Goal/crash forms use the shared square form-button
  variant; Setup retains its rounded checklist actions.
- The goal HTML still bears its historical NEEDS APPROVAL label; this slice follows
  the maintainer's explicit request to implement it. No new goal policy was added.

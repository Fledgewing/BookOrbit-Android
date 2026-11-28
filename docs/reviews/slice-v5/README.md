# V5: native companion visual review — Round 1

[32-pair comparison gallery](index.html) · [Measured scale](scale-measurements.md)

The shared `CompanionStyle` roles now reproduce the approved width-normalized
scale instead of reducing text and controls to fit. All sampled capital/digit
heights and control dimensions differ by at most **3.6%**, against a 10% review
budget. The report measures original image pixels before gallery resizing; its
Pillow script and JSON results are included.

The launcher hero, circle-over-label tiles and status rows retain their approved
proportions. All §5.9 rows remain present below them; the page scrolls. Goal and
crash forms use the larger standalone-form scale, including their fields and
actions. Checklist type uses its own approved illustration scale. Settings uses
the full-width reader-family references selected in Round 1; it is not scaled
as if those captures were the smaller standalone illustrations.

Settings schema, Library commands, permission policy, checklist rules and X1
routing are unchanged. Launcher edits affect drawing dimensions and type only.
Reader Lua surfaces belong to V4 and are excluded from this gallery.

## Validation

- Dedicated Android 14 ARM64 AVD, **1404×1872 / 300 dpi**, with the repo's fake
  ServerAdapter and synthetic seeded EPUBs, covers, series and reading sidecars.
- Fixture APK assembly preserves strict Gradle dependency verification.
- 29 focused Kotlin tests pass, including the smaller-reader checklist fit,
  unchanged launcher Settings destination, numeric goal persistence and adjacent
  goal-action layout. `lintDebug`: zero errors, 36 warnings.
- Fifteen emulator-driver safety/seed tests pass.
- **All 15 `reader_companion.py` acceptance checks pass**, including Full/Add-on,
  denied/granted permission without helper enablement, protected Settings,
  return context, silent background revocation and changed-book retirement.
- The seed sets and flushes `color_rendering=true` before KOReader's first-run
  notice test. At pinned KOReader `9192014d8bd82a91dc1012473be0f238dedfdb54`,
  `reader.lua:190` runs late user patches; `reader.lua:195` checks this setting and
  `reader.lua:197` sets it when showing the notice. This prevents the known notice
  before the reviewed sheet opens, rather than dismissing arbitrary dialogs or
  relaxing the acceptance assertions.

Commands:

```sh
python3 tools/e2e/android/test_driver.py
(cd android/companion && ./gradlew lintDebug testDebugUnitTest \
  --tests '*ChecklistPageTest' --tests '*SettingsPagesTest' \
  --tests '*LocalReadingSettingsTest' --tests '*UiPagesTest')
python3 tools/e2e/android/reader_companion.py --serial emulator-N --out <evidence>
python3 docs/reviews/slice-v5/measure-scale.py --gallery <gallery> --out <report>
```

The native all-set/group fixtures use production `ChecklistUi` with immutable
synthetic completed rows in an external fixture Activity. Other companion images
show production Activities. Intentional crash examples run only in the disposable
fixture process. No physical reader, production BookOrbit call, release, signing
change, dependency update or upstream change was made.

## Remaining environmental differences

Android supplies its own system fonts, status/navigation chrome and keyboard.
Snapshot version, local clock, permission state and synthetic sample values differ
from browser illustrations. E-ink ghosting and physical timing are not measured by
an emulator. These do not change the measured width-normalized type/control scale.

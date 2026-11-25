# X3 Home replacement: measured inventory and estimated budget

W36 revision 3, design only. No source was changed to remove Home code and no
new firmware was built. **Symbol bytes are measured; reclaimed flash and the
replacement cost are estimates until an A/B link proves them.** No device access.

## Artifact and baseline

Read-only download from [Orbify run 45688398918](https://github.com/Fledgewing/Orbify/actions/runs/45688398918),
overlay commit `0ebe1858cfd9ca213715b44d8daeba5ed265429f`, current-base rc3
`87e2e1984481e8a3d996f12b34b50a383f9013b8`. Artifact
`firmware-default-2.0.0.376-bookorbit.1-rc3` includes the X3/C3 ELF, image and
partition table; this is a public build artifact, not reader data.

| Item | Measured value |
|---|---:|
| CI final PlatformIO Flash used | 6,466,767 / 6,553,600 B (98.68%) |
| CI 99.5% gate | 6,520,832 B |
| Headroom to CI gate | 54,065 B |
| Physical `.bin` size (includes image overhead) | 6,480,640 B |
| Physical image room to slot end | 72,960 B |
| `.flash.text` | 3,765,708 B |
| `.flash.rodata` | 2,614,084 B |

CI reads PlatformIO's final Flash line (`.github/workflows/xteink.yml:300-309`);
physical image size and that accounting differ, so neither is substituted for the
other. The earlier W8 table is historical; this artifact confirms the maintainer's
approximately 98.7% figure on a newer build. Actual gate arithmetic is
`6,553,600 * 995 / 1000 = 6,520,832`, correcting the prior draft's 100-byte error.

SHA-256 image: `0ae9969deec7980150f6726e3b72bdd2cd7b49e19c989be26b0bdc9cb21802fe`.
SHA-256 compressed ELF: `98b29b3ab44effbd702fb523780d939cf218ab8e2be6b969782ccf3ed875f915`.
The downloaded image also matches the artifact's supplied checksum.

## Flash-resident symbol inventory

Used the available RISC-V ESP toolchain's `riscv32-esp-elf-nm -S -C --defined-only`
and `riscv32-esp-elf-size -A` on the decompressed ELF. Sum the union of address
intervals `(address, address + size)` within each disjoint class group, not the
raw sum of aliases. Restrict to defined T/t/R/r/V/v symbols in flash mapped text
and rodata ranges (0x42000000–0x42400000 / 0x3c000000–0x3c800000 for this ELF).
Match names starting `Class::` or exactly `vtable for Class`. Exclude std wrapper
names, unnamed/shared assets, IRAM/RAM, inline bodies not attributed to a class,
alignment and debug data. These exclusions make this a reproducible named-symbol
inventory, not complete object/map attribution or guaranteed linker savings.

| Group | Measured unique symbol bytes | Credit in estimate |
|---|---:|---|
| BookOrbit Home presentation: HomePage, StatsPage, LibraryPage, Tiles, Ui, Model, ReadingData, Layout, Stops, Text (all prefixed `BookOrbitHome`) | 17,520 | Candidate removal with the old Home; preserve all content in our implementation. |
| `CoverGridHomeUi` | 5,108 | Candidate removal; preserve generic list/reader primitives. |
| `HomeActivity` | 23,608 | **0** credited: contains shared routing/local file/settings logic that must move or remain. |
| `BookOrbitHomeStore` | 6,175 | **0** credited while sync/sleep/import consumers need it. |
| `BookOrbitHomeRefreshActivity` | 2,142 | **0** credited until adapter replacement is complete. |
| `SavedItemsHomeActivity` | 8,122 | **0** credited: bookmarks/saved reading items remain accessible. |
| Generic theme/reader/list renderers, fonts and assets | Not attributed here | **0** credited; not safe to count whole theme classes as Home-only. |

The first three groups together occupy **46,236 B** of named flash symbols.
Only the first two contribute the **22,628 B gross-removal planning assumption**.
Classic/Lyra/Minimal/Dashboard/Carousel Home branches, strings and vtables may free
additional bytes, but this audit assigns them zero rather than guessing. Do not
claim all 46,236 B or whole-theme sizes as a saving. Shared references, compiler
inlining and replacement glue may reduce the reclaimable amount.

## Estimated X3 replacement envelope (not a linked result)

| Budget term | Bytes | Status |
|---|---:|---|
| Current headroom to CI gate | +54,065 | Measured build log |
| Drop old BookOrbit presentation + CoverGrid Home | +22,628 | Estimate using the measured symbol inventory above |
| Reserve new routing/import/adapter integration glue | −8,192 | Planning allowance, not measurement |
| Envelope left for new Home + SD read projections/summary handling | **68,501** | Derived estimate |
| Target new code/data envelope (text/paged views, shared row renderer) | −49,152 | Design budget only, not a size claim |
| Remaining allowance under CI gate | **19,349** | Conditional estimate |

This scenario would use 6,501,483 B in CI Flash accounting (about 99.20%).
With the same image overhead, the estimated physical image is 6,515,356 B,
inside the existing slot; actual image bytes must also be checked. If *none* of
the candidate symbols is reclaimed, the same 49,152 + 8,192 B addition exceeds
the CI gate by 3,279 B. This is why compile-time replacement and an A/B link are
required; hiding a Home selector at runtime is insufficient. The envelope must
include newly enabled X3 SD catalog/projection code, summaries and vocabulary
capture as well as drawing, not just the Home activity object file.

X3 is nevertheless a full 0.12 **design target**, not a deferred optional Home:
BookSync is its only compiled Home. Keep content, reduce drawing complexity and
factor shared text/page renderers. Do not fund the budget by removing word,
achievements, history or reading/sync/recovery features. Fit failure requires
further scoped work or maintainer scope review before release.

## Acceptance measurement after design approval

At one overlay/base/toolchain/dependency pin, link (A) current Homes, (B) current
base with other Home paths/assets/setting registrations excluded, (C) B plus the
owned text Home and full SD/adapter feature set. Keep `.map`, ELF and size reports;
compare section/symbol/object contributions and exact image bytes per step.
Assert absence of alternative Home constructors/registrations and their dedicated
assets, while retaining reader/list/Settings/font symbols. Test migrated old
Home/theme selections and local Files/Recent/Settings/OTA entry points. Compare
identical release flags with linker GC; no disabled cache/adapter switch may make
C pass by silently excluding required functionality. Require the 99.5% gate,
physical slot fit, bounded C3 heap/parser/SD windows, network-boot return/cancel,
power-cut recovery and signed previous-image rollback. Repeat full X4 builds to
catch shared-theme regressions. Retain measured artifacts as CI evidence; no
source implementation or synthetic “after” map exists in this design PR.

## Revision 4: widget host/editor split (estimated)

The 49,152-byte monolithic replacement target above is superseded by the
[widget/editor breakdown](DESIGN.md#36-what-it-takes-estimates-not-measurements).
Do not count both budgets. X3 host/engine plus its Settings list is estimated
7–14 KiB, leaving 54,165–61,333 B of the estimated 68,501 B envelope for installed
widgets and SD projections. A full spatial X3 editor is not required if tight.
X4 host/editor is estimated 16–32 KiB: the same public run reports X4 Pro
6,491,033 B / 29,799 B below the gate, so the top end exceeds current headroom
before any widget cost. No X4 Home-removal saving has been measured. Measure
engine-only, each editor and each widget increment independently on every reader;
one removed native Home is not evidence that all future widgets/editors fit.
Starter builds retain future layout records without compiling future renderers.

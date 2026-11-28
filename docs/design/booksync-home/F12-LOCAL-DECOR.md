# Retained local Moon and Glyph cards

DESIGN §3.1 retains Moon phase and Glyph of the day as read-only Home editor
choices. Both are additive widgets; existing defaults and saved layouts remain.
The companion supplies one row / 16 KiB for each through `local.moon` and
`local.glyph`. Choice, calendar arithmetic and display formatting stay off the
reader thread. The visible host owns refresh: hourly for Moon, once a minute for
the daily Glyph boundary, with no hidden timer after Home closes.

Moon shows its phase name, approximate illumination, next primary phase/date and
an explicit Approximate / local date source line. The model uses the
[NASA new-moon epoch](https://eclipse.gsfc.nasa.gov/phase/phases1901.html)
(2000-01-06 18:14 UT) and
[mean synodic month](https://eclipse.gsfc.nasa.gov/help/moonorbit.html).
Constant-period interpolation is BookSync's approximation, not an ephemeris or a
claim that individual lunations have equal lengths. Dates outside 2000–2100 are
unavailable, with guidance to set the reader's date. No network or artwork is used.

Glyph uses an original deterministic 26-letter Latin sample for the reader's local
day, with its name, Unicode code point and actual loaded interface-font family.
It probes that exact font for the character; missing font/glyph is an explicit
unavailable card, rather than displaying a fallback as though it were the sample.
There is no font directory scan or download. Native text rendering uses the same
probed face. The pinned font API is KOReader `frontend/ui/font.lua:330` at
`9192014d8bd82a91dc1012473be0f238dedfdb54`; `ftsize:hasGlyph` and `getInfo().name`
are `ffi/freetype.lua:69` and `:148` at the pinned base
`6e4bc81af4e04f78d81677a323a780a71b29702a`.
Both new native symbols are covered by the compatibility inventory.

## Verification

Four companion tests cover primary phases/approximation, timezone dates, bounded
illumination, daily glyph stability/name/code/source and invalid clocks. Native
font-probe flow tests exercise the production Library wrapper, all permitted spans,
immutable snapshots, honest missing glyph/date states and zero transport/scan work
in the renderer. Native acceptance uses the real companion rows and real font
probe; missing-state presentation uses temporary Library test doubles.

Validation: 891 JVM tests (zero failures/errors, four skipped), version verification,
debug assembly and lint; 259 Lua logic and 290 flow tests; 12 server-boundary,
six UI-boundary, four matrix and ten emulator-driver tests. The pinned KOReader
symbol check passes (base FFI checked by native use and CI). Nine dedicated
native checks and the full 65-screen review pass. Visual review confirms clear
text at the smallest permitted sizes. Measured construction spans were 0–0.6 ms
for Moon (six samples) and 0–0.4 ms for Glyph (ten), below the 50 ms budget.

Firmware implementation, physical acceptance and publication remain separate.

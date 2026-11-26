# Android layout engine implementation notes (F12-B)

The maintainer authorised Android implementation on 2026-11-25. This implements the
layout-data foundation, not a shipped Home screen. X4/X3 remain data entries; firmware
projection, reflow and editors come later. No device, release or tag is involved.

The approved design is on `origin/design/booksync-home`, commit
`89d2577d970977949ae035aaab2143da1185d6a7`: `DESIGN.md:238-310`,
`DESIGN-NOTES.md:92-190`, `layout.schema.json`, and `prototype.html:1263-1298` under
`docs/design/booksync-home/`. The M8C prototype has **Home and Stats**, not a third
Library page (`prototype.html:1123-1126`). Library is a tile on Home; the separate
Library page belongs to X4. The default stores the approved future Stats widgets;
only an installed renderer's registry subset may render or query them.

## Reuse and boundaries

- `android/koreader/orbit.koplugin/main.lua:36` loads pure logic into the existing
  shared environment; `android/koreader/test/test_logic.lua:6` is the existing harness.
  The new modules extend these rather than introducing another loader or test runner.
- `ko/cache.lua:40-60` already supplies bounded `OC.readFile` and atomic
  `OC.writeFile`. `Layout.load/save` accept those callbacks and a JSON codec.
  The future host invokes persistence outside reading, never from a paint or move.
  This is layout configuration, not another catalog cache.
- `ko/store.lua:6-10` already reads bounded database windows owned by the companion;
  `ko/db.lua:7` keeps writes in the companion. Widget `dataNeeds` name only owned
  library-interface sources; the host must extend the existing read-model path.
- `logic/caps.lua:29` resolves companion service capabilities. Adapter capability
  names supplied to `Layout.resolve` are a separate set, never a server name.
  `logic/home_plan.lua:27` and `ko/home.lua:9` retain Home navigation/command ownership.
  The layout engine supplies data; it replaces neither navigation nor scheduling.
- `logic/sheet_layout.lua:16` continues to own sheet geometry. The new grid engine
  owns semantic tile coordinates; it introduces no KOReader widget/drawing code.

## Contract for the next host slice

`Layout.default`, `parse`, `validate`, `serialize`, `resolve`, `move`, `resize`, `add`,
`remove`, `page`, `reset`, `load` and `save` are pure except for explicitly injected
storage/codec callbacks. `page` supports add/remove/reorder/rename. Failures return
`nil, reason`; rejected edits leave their input untouched. Revisions increment once
per successful edit. Move/resize edit the Android override; shared page operations
edit the semantic page list. A blocked band swap returns `move to page: ...`; the
host offers the prototype's move-to-page action. Add tries the requested slot then row-major free space at the requested span; no
room leaves the layout untouched. A resize searches the current
position first, then x-major/y-minor free positions, matching the prototype.

Input must be validated once at the load/import boundary before editing. Move/resize
use copy-on-write and validate only the edited page. Unchanged pages/settings remain
shared, so all returned layout documents must be treated as immutable. The loops
are bounded by 128 placements and at most 12×12 grid cells. Encoding, full validation
and storage happen on explicit save, not on every arrow press. Resolution returns
owned snapshots and never mutates base settings or class overrides.

Pass the installed renderer registry subset explicitly; the full `WidgetRegistry`
is a semantic destination catalog, not proof that its renderers have shipped.
Unknown widget/version placements reserve their coordinates on save but are omitted
from resolved render/query lists. Unknown fields, settings and unsupported class
overrides survive edits and JSON round trips. A class override shallowly merges
settings keys into base settings; nested values replace the corresponding key.
Android has four columns and eight default rows; accepted layouts may use up to
12 rows. Only Android class semantics are validated by default. A future platform
host can request explicit additional classes with `validate`'s third argument;
it must first supply suitable reflow/overrides and installed spans.

The injected codec must reject malformed/trailing JSON and preserve arrays, objects
and nulls, including empty values. Array/object tables use `__jsontype` metatable tags;
null uses a table tagged `null`. Plain empty tables created by the engine mean
objects; empty arrays are tagged. Wrap the platform codec at the host boundary to
satisfy this contract; do not use `Cache.encode` (Lua serialization) or
`SleepPool.json` (empty tables become arrays) for layout persistence. The test JSON
helper has an opt-in typed mode; existing fixtures keep their previous behavior.
The 128 KiB byte cap applies before decode and after encode; settings/unknown trees
also have a depth-24 and 32,768-value bound. IDs/page names have an 80-byte bound.

`save` validates/encodes first, atomically publishes the previous valid primary to
`.bak`, then atomically publishes the new primary. Failed writes leave the primary
valid; a corrupt primary never replaces a good backup. `load` tries primary, backup,
then the owned default, returning a Settings reason for recovery/default fallback.
Atomic publication inherits the supplied writer's guarantees (rename visibility,
not an additional power-loss/fsync guarantee).

## Performance rule (maintainer, 2026-11-25)

Every screen and widget declares a budget, and library calls inherit the budgets
of their callers. `logic/budgets.lua` is the single table for screen families and
widget contracts. Every Home page uses `screens.home`; every Settings group uses
`screens.settings`. Library, Details, Series, filter sheet, editor and reader top
panel each have entries. Registry `budget` and each `dataNeeds[].budget` reference
that table. Source parameters declare a typed window limit; the host supplies the
specific neutral filter/settings and batches needs into one snapshot request.

Filtering, sorting, grouping, counts, search, stats aggregation, battery estimates
and catalog joins belong in the companion. The plugin reads ready-to-draw windows;
no full-catalog scans or large server-JSON decoding in Lua, and no subprocess fork
per read. Enforce row/window and decoded-byte limits, zero spawns, zero render-path
network calls, at most one batched companion round-trip per Home paint, and widget
snapshots no larger than 16 KiB. These are deterministic limits, checked with
`Budgets.check` on measured counters including explicit zeroes. Home checks aggregate
paint counters as well as each widget's counters. Limits cover the whole call,
including multiple sources; a source does not receive a separate allowance.

Use `Budgets.span(id, monotonicClock, infoLogger)` at actual call/paint boundaries
for one info-level milliseconds line. This slice has no render/read calls to time.
Device targets awaiting maintainer confirmation are Home <500 ms, widget <50 ms,
cached library window <30 ms and editor move <100 ms. Host tests enforce counters,
not elapsed time. No UI or shipped feature cell changes until the host is connected.

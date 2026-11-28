# Retained Android Home metric cards

DESIGN §§3.1–3.4 and the approved retained inventory authorize six distinct,
read-only cards: Today, Reading streak, Account reading goal, Pages read,
Monthly reading and Finish forecast. They are additive editor choices. Existing
saved layouts and the two default pages are unchanged. Local completion and goal
settings remain subject to their separate proposal's approval.

`RetainedMetrics` creates one compact worker snapshot from the same reconciled
account/local statistics as the existing Stats cards. Today keeps unproven local
overlap separate. Streak and its seven-day history each carry their own source.
Account goal uses saved target/year/completions; unknown completion has no invented
zero/progress, and an old year has no current-year pace. Pages explicitly count
native timed page visits, by visit-start day, with this-reader provenance.
Monthly reading aggregates twelve calendar months from the saved daily coverage,
labels its period and compares the previous month; no future days are borrowed.
Finish forecast remains a separate one-book card using the existing measured
local pace and insufficient-history state.

Each metric card has a one-row/16 KiB ceiling. Five cards share `reading.metrics`
in one host batch, independently from annual `reading.stats` on the same page.
The host owns visible-only minute invalidation; cards perform geometry and paint
only. Calendar work, aggregation and formatting stay in the companion. No server
protocol, scan, sidecar parse or subprocess enters widget paint.

## Verification

Companion after rebase: 883 tests, zero failures/errors, four skipped; shared-version verification,
debug build and lint pass. Four new model tests cover precedence/source separation,
goal year/unknown states, compact budgets and leap-day calendar totals. Existing
native-statistics tests also verify Today visit-start counting across midnight/DST.
Lua: 258 logic tests and 286 flows. Added checks cover all permitted sizes,
independent provenance, missing values, immutable snapshots and a mixed page sharing
one row per operation. Server/UI boundary suites: 12/6.

The first native smoke run exposed a test gap: fallback error cards still satisfied
its transport/batch assertions. Visual review caught the seven-day/monthly renderer
using Lua's length operator on immutable proxy arrays (length zero). The planner now
checks bounded indices, regression tests use nested immutable proxies and the native
flow rejects error fallback cards. Failed evidence is retained; acceptance requires
the corrected native run and full registered-widget review.

The corrected native flow passes 19 checks across every permitted card span,
including the real companion projection and explicit missing-state presentation.
Visual review also found the compact monthly chart needed more vertical room and
the streak strip needed footer clearance; both have small-viewport regressions.
The final full review passes all 63 screens, including all 23 registered widgets.
Feature matrix: four tests; emulator driver safety: eight tests.

Reproduce after fixture setup:

```
python3 tools/e2e/android/retained_metrics.py --serial emulator-5580 --out <evidence>
python3 tools/e2e/android/review.py --serial emulator-5580 --out <review>
```

The native metrics flow first checks the real companion RPC. Rich account and
unavailable presentation states then use a temporary Library snapshot double while
retaining real native renderers/layout/batching; model precedence is verified in JVM
tests. Firmware, physical acceptance and publication remain separate.

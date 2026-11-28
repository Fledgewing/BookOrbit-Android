# Retained Finished in YEAR

DESIGN §3.3 retains the cached dashboard year selection, its goal year/count and
finishedOn dates. The new Book list preset opens the current reader-calendar year;
the existing Source picker chooses each saved year. All finished remains a separate
general status source. Default pages and existing saved layouts remain.

An additive cache table archives each bounded twelve-book dashboard selection before
replacement and seeds an existing cached response on first read. It does not bump
the cache schema version or replace reader data. Account/server changes wipe both
archives and acknowledgement keys. New-year account totals stay unknown until saved;
past selections remain available. Missing dates are explicitly unknown, never
filled from last-read timestamps. The card preserves the account's finished total
separately from the Saved selection count. Filters and paging apply to that saved
selection; there is no claim of a complete year predicate or completion index.

The existing finish/status writer retains at most 32 explicit local completion
proofs for this read-only shelf, separate from its sync jobs. Undo/unread replaces
that book's proof. Pending books carry their local mark date and awaiting-account
provenance; they never increment an unproven account total. A cached matching or
later finishedOn acknowledges a book/date, and that acknowledgement survives its
later departure from the capped shelf. No settings UI, device goal, full completion
ledger or statistics import is introduced by this outcome.

Pinned BookOrbit `c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7`:
`server/src/modules/koreader/koreader-catalog.service.ts:145` caps the finished
selection at twelve; `:332`–`:340` preserves finishedOn. UI receives only neutral
Library sources/context. No request is added, and reads never call the network.
One bounded Book list window remains in the host batch; archived decoding,
filtering, counting and acknowledgement work stay on the companion worker.

## Verification

Companion tests cover rollover, capped selection versus account total, additive
old-cache seeding without a version change, missing dates/counts, owner wipe,
known empty versus pending, paging/filtering, local pending deduplication and
acknowledgement after a book leaves the cap. Existing finish/status tests verify
the writer integration. Lua tests retain the neutral year request and immutable
selection context. Native review exercises the real source picker, saved year
shelf, separate account total, counted See all and pending-year presentation.

Native testing exposed two integration gaps. Source-picker work could remain
paused because owned Home did not mirror its foreground transition to the
companion until the five-minute stats tick. Home show/close now reports the single
reading gate immediately through Library, with `visibility_only=1`; the companion
skips measurement recording for those reports. A regression verifies that bulk
work resumes with no added battery row.

Busy-cache cleanup also used native convenience calls whose error path can retain
prepared statements, and silently ignored transaction-end failures. BookSync now
finalizes its own scalar/transaction statements on success or error, skips reads
when BEGIN fails, and rolls back/retires a failed transaction. Two forced-busy Lua
regressions fail before this repair and pass after it. The pinned base
`6e4bc81af4e04f78d81677a323a780a71b29702a`,
`thirdparty/lua-ljsqlite3/init.lua:352`–`:375`,
[defines the convenience-call cleanup order](https://raw.githubusercontent.com/koreader/koreader-base/6e4bc81af4e04f78d81677a323a780a71b29702a/thirdparty/lua-ljsqlite3/init.lua).
The workaround stays in BookSync; upstream sources remain unchanged.

The native fixture initially used an invalid tab and later assigned its temporary
layout before the first layout-file load. The harness now uses Insights, primes
Home, asserts layout validity and verifies the actual widget signature. A unique
neutral request nonce forces a fresh view so a previously ready row cannot hide
an integration failure. The reading precondition uses the real Home Close callback,
and the fixture position-consent popup is explicitly accepted before waiting
for frontmost Home to repaint.

Physical acceptance, firmware implementation and publication remain pending.

Verification: **906 JVM tests**, zero failures/errors, four skips; shared-version,
debug APK and lint pass. **260 Lua logic / 296 flows**, boundary guards **12/6**,
feature matrix **4**, emulator driver **10**. The five native year checks pass;
current/past minimum-size/See all/unknown-year screenshots were inspected.

The original fixture shared one document identity across all books; a declined
remote position therefore contaminated the later consent scenario. Fixture captures
now hash the synthetic book path, and the year review accepts its consent. The
production policy correctly retains a No answer and is unchanged.

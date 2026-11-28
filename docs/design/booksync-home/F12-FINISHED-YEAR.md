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

Physical acceptance, firmware implementation and publication remain pending.

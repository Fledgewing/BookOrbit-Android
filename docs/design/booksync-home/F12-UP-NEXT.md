# Retained Up next in series shelf

Approved DESIGN §3.1 retains this saved server selection separately from Series
next-N download jobs. The Add widget Book list preset and Source picker preserve
its bounded connector rank by default. Explicit user sorts/filters remain local.
See all retains the same source and Saved selection label; complete membership
continues to belong to the owned Series page. Existing defaults/layouts remain.

The adapter reads only the already-fetched cached section. No route, server call
or attestation bypass is added. It caps decoding to twelve source records,
normalizes through Library, applies existing local status intents and tracked-file
availability, and publishes only the requested bounded window. Missing/malformed
section data differs from a known empty selection. A local-only library cannot
invent a substitute recommendation and does not offer this account-backed preset.

Pinned BookOrbit `c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7`:
`server/src/modules/koreader/koreader-catalog.service.ts:147` caps sections at
twelve; `:372`–`:416` returns the section and restores its original selection order.
The existing refresh plan already fetches this section. UI uses the neutral
`series-next` source; protocol vocabulary stays inside the adapter.

## Verification

Companion tests cover saved order without a full catalog, paging/counts, explicit
sorts, filter/facet counts, missing/malformed/known empty and local capability cuts.
Lua tests verify the separate preset/provider order and counted See all/filter
source. Native review uses the actual cached projection, shelf, source picker and
See all; no live server is required.

Physical acceptance, firmware implementation and publication remain pending.

Verification: **909 JVM tests**, zero failures/errors, four skips; shared-version,
debug APK and lint pass. **261 Lua logic / 297 flows**, boundary guards **12/6**,
feature matrix **4**, emulator driver **10**. Four native checks pass for the real
cached rank, source picker/minimum span, counted See all and filtered selection;
all four screenshots were inspected. The harness waits for the restored fixture
owner after startup instead of treating companion readiness as account readiness.

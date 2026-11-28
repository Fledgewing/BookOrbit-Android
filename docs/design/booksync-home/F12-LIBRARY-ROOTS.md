# Android retained Library roots and shortcuts

The approved DESIGN §3.1 retained mapping includes Library counts, all browse
roots and named collection/list shortcuts. The existing Home menu and Library
widget now open the counted Library root page. Its destinations cover All books,
In progress, Recently added, On this device, Libraries, Authors, Series,
Collections and Your lists. The latter is the neutral UI name for saved dynamic
scopes. Existing Storage actions and general catalog lists remain reachable.

Named Libraries and Collections join the existing Book list source picker. Each
category uses six-row, 16 KiB pages, keeps the selected source focused after its
category rows and preserves opaque account-scoped identities. Choosing a source
uses saved membership; it never interprets dynamic-scope rules in the reader.

The adapter computes counts from the complete saved generation. During secondary
index publication the root counts remain unknown rather than becoming zero.
Local-device mode labels its own file coverage, supplies local author/series
sources and does not fabricate server libraries, collections or dynamic scopes.
The native page hides roots unsupported by its Library capabilities. The compact
Library tile retains its existing book/device/storage actions and exposes the full
root page through its first available browse row; the Home menu also exposes it.

All collection/library membership and protocol fields remain in the server
adapter. The UI consumes neutral `library.summary` and `sources` projections.
Counts, joins, source paging, file scans and sorting stay on the companion worker;
root rendering uses one row and source rendering six rows in a single batch.
Existing saved layouts, titles and source identities remain valid.

## Verification

Two new adapter tests cover opaque account isolation, pagination, membership,
capability gating and incomplete-versus-known-zero root counts. The existing
local-device series test now also checks neutral source/count projection and
unsupported roots. Lua flows cover all six picker categories, actual named-root
navigation, list routing, root counts, unsupported capabilities and unknown counts.
Native reproduction after fixture setup:

```
python3 tools/e2e/android/library_roots.py --serial emulator-5580 --out <evidence>
python3 tools/e2e/android/review.py --serial emulator-5580 --out <review>
```

The initial native run exposed a pre-upgrade ready view retaining the old summary
shape. Changed summary/source requests now carry a neutral projection revision,
so they materialize immediately with a new cache identity; old data is retained.

The native flow checks the real local companion RPC, then uses a temporary Library
snapshot double for rich server states while keeping the production native roots,
source picker, pagination and list routing. Remote adapter semantics are JVM-tested.
Firmware, physical-reader acceptance and publication remain outside this slice.

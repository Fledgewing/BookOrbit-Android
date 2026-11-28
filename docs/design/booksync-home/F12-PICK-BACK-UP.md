# Android Pick back up shelf

The approved DESIGN §3.1 retained inventory calls for a distinct older-in-progress
shelf. Pick back up is now an Add widget Book list preset and a counted built-in
source, separate from Currently reading and Also reading. Existing saved layouts
and the two default pages are unchanged.

Its provider selects reading/rereading books oldest-last-read first and removes the
current hero before filtering or paging. A filter that omits the hero must not
remove the first matching older book instead. The source picker starts this shelf
with provider order, avoiding an inherited newest-first sort from Reading now;
subsequent explicit user sorts still work. Unknown last-read dates remain after
dated entries and carry an explicit Last read unknown caption. See all and its filter retain the same
source, exclusion and total. The local-file provider uses native saved reading
state and the same selection rule. No server unread inference or arbitrary age
cutoff is introduced.

The retained upstream selector is independently named at
`koreader-plugin/bookorbit.koplugin/bookorbit_board_store.lua:64` and uses the
reading/recently-read ascending query at
`koreader-plugin/bookorbit.koplugin/bookorbit_catalog_board.lua:996`, pinned
BookOrbit commit `c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7`.
BookSync implements this through its own neutral Library provider and existing
bounded Book list renderer, without calling that plugin or its server from UI.
Counts, sorting, filters and local metadata reads remain companion work. The
widget retains its existing row/16 KiB budget, single host batch, deferred covers
and capability-aware actions.

## Verification

New remote/local provider tests cover oldest-first order, rereading, current-book
exclusion, totals and a query that excludes the hero before paging. Lua tests cover
the distinct preset/default source order, See all and filter routing. The native
flow uses the real local companion projection, then the actual shelf/list and
Add widget preset picker, restoring its synthetic layout afterward.

```
python3 tools/e2e/android/pick_back_up.py --serial emulator-5580 --out <evidence>
```

Physical acceptance, firmware implementation and publication remain separate.

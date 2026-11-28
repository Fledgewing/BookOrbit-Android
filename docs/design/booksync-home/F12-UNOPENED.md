# Unopened files and Gathering dust

The approved DESIGN §3.1 / §3.4 inventory retains both a local Unopened Book list
source and a daily Gathering dust pick, with file age, pool count/size and Next.
They are independent of server unread status. Existing defaults/layouts remain.

The companion scans configured device/download roots and uses canonical paths,
read-only native opening history and conservative sidecar absence. A file with any
local, central, hashed or legacy sidecar is excluded. The active native file is
excluded before counts, filtering and daily choice. Missing, oversized or malformed
history is unavailable, not an empty known opening ledger. Links outside roots
and uncertain sidecar probes are excluded. The UI never scans or parses files.

The caption is **No saved opening record**, since deleted/pruned native history
cannot prove that a file was never opened in its lifetime. File age is modification
age, not a claimed download time. Dates in the future/unknown stay unknown. The
worker retains oldest-file order and chooses a stable local-day index; explicit
Next advances only today's index, saved through the existing Library settings.
The pool is reconstructed on the worker so opening a file removes it next refresh.
One lazy pool is shared by the list and pick within a host batch. Only bounded list
windows and one-row / 16 KiB pick snapshots reach KOReader.

Unmatched device files retain explicit local Open. They cannot forge account
status/detail or tracked-download removal actions. Existing catalog/removal flows
remain unchanged for their normal rows. No file is deleted by this outcome.

Pinned KOReader `9192014d8bd82a91dc1012473be0f238dedfdb54`:
`frontend/readhistory.lua:12`, `:89`–`:119` saves native opening history;
`frontend/docsettings.lua:118`–`:175` defines local/central/hash candidates and
`:182` the legacy history name; `datastorage.lua:54`–`:76` defines fixed roots.
`frontend/util.lua:1111`–`:1127` defines the partial-MD5 sample offsets, mirrored
on the worker only. Central/legacy path indexes canonicalize aliases. Folder work
and its reading-pause checkpoints run before the cache transaction, and unopened
windows skip irrelevant pace enrichment. The retained predecessor's
selection is BookOrbit `c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7`,
`koreader-plugin/bookorbit.koplugin/bookorbit_board_data.lua:547`–`:635`.

## Verification

Companion tests cover history/current-file exclusion, local/central/hash/legacy
sidecars, corrupt/missing history, escaped links, canonical path aliases, bounded
snapshots, daily stability/reconstruction, Next and file-age provenance. Lua tests
check the distinct source, persisted choice, malformed actions and per-row account
capability restrictions. Native review uses synthetic files outside the fixed
59-book library and real worker projections, plus the native Next/Open controls.

Physical acceptance, firmware implementation and publication remain pending.

Native review caught an indexed-history normalization bug: KOReader dumps `[1]`
keys, while the companion literal parser represents map keys as strings. The
initial positional-only fixtures missed it. A native-format regression fails
before the repair; the reader now accepts only contiguous canonical numeric keys,
rejecting gaps and alternate spellings. Parsing remains literal-only and read-only.

# Android 0.12 performance review

Reviewed base: `6a49570d` on `feature/0.12`. Android only, under the maintainer's
Android-first authorization. This is a review/fix of implemented features, not a
new feature or a device performance sign-off.

## Method and limits

The enforced limits are deterministic: logical display rows (including nested
previews), decoded bytes, 16 KiB widget snapshots, zero render network/subprocess
calls and at most one host-owned Home batch. Device targets remain Home <500 ms,
widget <50 ms, cached library window <30 ms and editor move <100 ms. Host elapsed
time is diagnostic evidence only. Cold companion materialization is off the UI
thread and is **not** the cached Lua window-return measurement.

`PerformanceBudgetTest` uses a real SQLite catalog with 10,000 books, 100 authors,
a 100-volume series, 10,000 sleep sources and 50,000 reading visits spanning more
than a year. A tracked local book has a sidecar, highlight, saved cover reference
and measured forecast. Highlight, A year ago, Recommended and Discover must return
ready data, not merely bounded empty/error results. The history reader returns
at most 256 visits per cursor, in 197 queries including the terminal empty cursor.
`PersonalReadingBudgetTest` separately measures two picks over 10,000 unread
identities and enforces provider-read/rank counts, including batch/time invalidation.

Before/after runs use the same fixtures against the reviewed base and this change.
Baseline instrumentation adds only constructor injection for the counted rank and
sleep-choice source; it retains the old ranking/accounting implementations. The
new regressions fail on the base. Temporary paths can change payload lengths by a
few bytes; that is not a performance improvement. No elapsed-time threshold is used
as a test assertion.

## Misses fixed in their owner

| Screen/widget/service | Budget | Measured before | After |
|---|---|---|---|
| Library/storage tile: second read after 10,000 B already consumed | Entire tile ≤16,384 B | Next read asks for 16,384 B; overrun checked after decode | Next read asks for 6,384 B; SQL excludes larger bodies before decode |
| Failed decode | Charge every decoded byte, even on a miss | 10,000 decoded bytes charged as 0 | Charged as 10,000; the remaining allowance falls to 6,384 |
| Exhausted widget | No further read/decode | Row allowance checked after read | Rejected before adapter read |
| Card covers: 12 visible jobs | Four jobs per deferred work window | 12 independently scheduled jobs | One drain; 4 + 4 + 4, including queued asynchronous deliveries |
| Discover: two picks / 10,000 identities | One provider read and one rank/candidate per kind/time/batch | Two provider reads; digest/hex formatting inside comparisons; 2,775 ms | One read, 10,000 ranks; 17 ms |
| Interface status file/Binder | ≤16 KiB JSON decoded | Unbounded file read / unchecked Binder JSON | Read sentinel at 16,385 B; reject excess before decode (1 MB regression fixture) |
| Scalar projection accounting | One display row | Summary, Storage, Clock, Battery, Stats and account logged 0 | Each logs 1; same count as Lua |

The cover test also cancels a queued job and delivers a burst of twelve worker
answers: no bitmap callback runs until a four-job drain. Retiring the last queued
job removes its drain and retires any live delivery ticket. Existing owner/generation
and departure tests still apply. File input remains capped at 512 KiB; real bitmap
decoding and e-ink paint latency require device acceptance.

Explicit reader surfaces retain their bounded cold SQLite access while reading;
the regression also verifies that this access rejects an undersized caller byte
allowance before decoding. Background reads still use the reading-time memo gate.

## Companion projections: every data-backed screen/widget family

Cells are `logical rows / encoded bytes / host materialization ms`. Each individual
result has a 16,384 B ceiling. Limits below are the requested display windows, within
the caller's screen/widget budget. Timing changes other than Discover are normal
single-run variation, not claimed optimizations.

| Screen/widget | Budget (rows / bytes) | Measured before | After |
|---|---|---|---|
| Continue reading | 1 / 16,384 | 1 / 977 / 132 | 1 / 977 / 86 |
| Book list | 12 / 16,384 | 12 / 7,043 / 164 | 12 / 7,043 / 111 |
| Library | 24 / 16,384 | 24 / 13,703 / 115 | 24 / 13,703 / 93 |
| Details | 1 / 16,384 | 1 / 506 / 1 | 1 / 506 / 2 |
| Library summary | 1 / 16,384 | 1 / 110 / 92 | 1 / 110 / 92 |
| Storage | 1 / 16,384 | 1 / 401 / 3 | 1 / 401 / 0 |
| Series | 24 / 16,384 | 21 / 4,560 / 76 | 21 / 4,560 / 78 |
| Filter | 24 / 16,384 | 24 / 3,059 / 109 | 24 / 3,059 / 97 |
| Source picker | 6 / 16,384 | 6 / 449 / 453 | 6 / 449 / 476 |
| End sheet | 3 / 16,384 | 1 / 306 / 1 | 1 / 306 / 0 |
| Highlight | 1 / 16,384 | 1 / 334 / 2 | 1 / 334 / 0 |
| A year ago | 1 / 16,384 | 1 / 300 / 3 | 1 / 300 / 3 |
| Recommended | 1 / 16,384 | 1 / 287 / 124 | 1 / 287 / 132 |
| Discover | 1 / 16,384 | 1 / 290 / 996 | 1 / 290 / 33 |
| Word | 1 / 16,384 | 1 / 136 / 0 | 1 / 136 / 0 |
| Buddy | 1 / 16,384 | 1 / 147 / 0 | 1 / 147 / 0 |
| Light | 1 / 16,384 | 1 / 132 / 0 | 1 / 132 / 0 |
| Clock | 1 / 16,384 | 1 / 468 / 1 | 1 / 468 / 0 |
| Battery | 1 / 16,384 | 1 / 2,368 / 0 | 1 / 2,368 / 0 |
| Stats | 1 / 16,384 | 1 / 5,163 / 2 | 1 / 5,163 / 0 |
| Settings account | 1 / 16,384 | 1 / 20 / 0 | 1 / 20 / 0 |
| Settings sleep | 6 / 16,384 | 6 / 371 / 4 | 6 / 371 / 3 |

All four Stats widgets (This week, Year in reading, When you read and Reading
records) share the one `reading.stats` row per Home paint. Library adds its storage
row: two rows in total. End-sheet rendering is separately exercised at its full
three-row allowance; the catalog fixture has no related suggestion and returns one.
Lists, collection/source pages, grouped lists and the source/filter controls retain
their existing bounded paging tests. Personal ranking/catalog joins and long-history
aggregation remain solely in the companion. Lua consumes the materialized windows.

## Lua screen paints and UI services

These measurements come from `BOOKSYNC_PERF_REPORT=1` on the actual flow harness,
including the isolated reader panel worlds. They count fake/native widget display
and real Library boundary calls, not physical e-ink pixels or native font/bitmap
cost. Each before/after entry is `rows / decoded bytes / companion batches`; these
paths retain their counts. Both runs report zero render network calls and spawns.
The companion table above supplies the ready large-library payload measurements;
flow fixtures deliberately also cover empty, loading, error and unavailable states.

| Screen/family | Budget (rows / decoded bytes / batches) | Measured before | After |
|---|---|---|---|
| home | 128 / 131,072 / 1 | 8 / 2,580 / 1 | 8 / 2,580 / 1 |
| library | 32 / 32,768 / 1 | 13 / 980 / 1 | 13 / 980 / 1 |
| search | 32 / 32,768 / 1 | 5 / 980 / 1 | 5 / 980 / 1 |
| details | 3 / 49,152 / 1 | 2 / 512 / 1 | 2 / 512 / 1 |
| book-info | 3 / 49,152 / 1 | 2 / 512 / 1 | 2 / 512 / 1 |
| series | 25 / 32,768 / 1 | 4 / 780 / 1 | 4 / 780 / 1 |
| reader-top-panel | 4 / 65,536 / 1 | 4 / 1,024 / 1 | 4 / 1,024 / 1 |
| reader-bottom-panel | 2 / 32,768 / 1 | 2 / 512 / 1 | 2 / 512 / 1 |
| battery | 1 / 16,384 / 1 | 1 / 2,500 / 1 | 1 / 2,500 / 1 |
| storage | 1 / 16,384 / 1 | 1 / 700 / 1 | 1 / 700 / 1 |
| storage-folder | 1 / 16,384 / 1 | 1 / 700 / 1 | 1 / 700 / 1 |
| collections | 6 / 16,384 / 1 | 1 / 400 / 1 | 1 / 400 / 1 |
| filter | 32 / 32,768 / 1 | 0 / 150 / 1 | 0 / 150 / 1 |
| filter-picker | 24 / 16,384 / 1 | 1 / 150 / 1 | 1 / 150 / 1 |
| booklist-sources | 6 / 16,384 / 1 | 6 / 900 / 1 | 6 / 900 / 1 |
| end-of-book | 3 / 16,384 / 1 | 3 / 300 / 1 | 3 / 300 / 1 |
| account | 3 / 16,384 / 1 | 0 / 0 / 1 | 0 / 0 / 1 |
| settings-sync | 32 / 32,768 / 1 | 3 / 256 / 1 | 3 / 256 / 1 |
| settings-library | 32 / 32,768 / 1 | 1 / 700 / 1 | 1 / 700 / 1 |
| settings-about | 32 / 32,768 / 1 | 1 / 0 / 0 | 1 / 0 / 0 |
| settings-sleep-choices | 6 / 16,384 / 1 | 1 / 160 / 1 | 1 / 160 / 1 |
| Home editor move | ≤128 placements, ≤208 draw nodes, 0 bytes/batches | 6 placements, 25 nodes, 0 bytes/batches | Same |
| Book list configuration | 0 reads/decoded bytes/batches | 0 | 0 |
| Custom font/margins/spacing/contrast and copy editors | One local style record; 0 decoded bytes/batches | One local record; 0 bytes/batches | Same |
| Static card overflow | Five display rows, 0 decoded bytes/batches | ≤5; 0 bytes/batches | Same |
| Upgrade news | Five static rows, 0 decoded bytes/batches | 5; 0 bytes/batches | Same |

Settings root has eight groups. Display rows before/after are Account 5/5,
Sync 18/18, Library 6/6, Reading 14/14, Home 4/4, Sleep 12/12, Updates 6/6,
About 5/5; each inherits the 32-row Settings contract. Display rows are distinct
from decoded read-model rows in the table. Account forms/results/removal/sign-out,
filter pickers, storage confirmation, battery tabs, book actions and editor pickers
reuse their named budgets and existing state/interaction flow tests. Native reader
controls sample at most 64 already-loaded chapter and annotation entries per kind;
the regression includes 10,000 of each and prohibits loading/scanning on paint.

Home widget boundary counters are shown below. `0` on shared Stats tiles means
that the host already charged the shared row to Year in reading; Clock's flow
fixture is pending, while its ready row is measured in the companion table above.
Cells are `rows / decoded bytes`, with zero additional widget round-trips.

| Widget | Budget (rows / bytes) | Measured before | After |
|---|---|---|---|
| battery | 1 / 16,384 | 1 / 2,500 | 1 / 2,500 |
| booklist | 12 / 16,384 | 5 / 400 | 5 / 400 |
| buddy | 1 / 16,384 | 1 / 100 | 1 / 100 |
| clock | 1 / 16,384 | 0 / 0 | 0 / 0 |
| continue-reading | 1 / 16,384 | 1 / 400 | 1 / 400 |
| discover | 1 / 16,384 | 1 / 100 | 1 / 100 |
| end-of-book | 3 / 16,384 | 3 / 300 | 3 / 300 |
| highlight | 1 / 16,384 | 1 / 100 | 1 / 100 |
| library | 2 / 16,384 | 2 / 800 | 2 / 800 |
| light | 1 / 16,384 | 1 / 100 | 1 / 100 |
| lists | 8 / 16,384 | 1 / 150 | 1 / 150 |
| reader-controls | 1 / 16,384 | 1 / 256 | 1 / 256 |
| reader-progress | 1 / 16,384 | 1 / 256 | 1 / 256 |
| reading-records | 1 / 16,384 | 0 / 0 | 0 / 0 |
| recommended | 1 / 16,384 | 1 / 100 | 1 / 100 |
| this-week | 1 / 16,384 | 0 / 0 | 0 / 0 |
| when-you-read | 1 / 16,384 | 0 / 0 | 0 / 0 |
| word | 1 / 16,384 | 1 / 100 | 1 / 100 |
| year-in-reading | 1 / 16,384 | 1 / 1,306 | 1 / 1,306 |
| yearago | 1 / 16,384 | 1 / 100 | 1 / 100 |

The widget registry and `layout_tests.lua` enumerate every declared widget and
screen budget, reject missing/over-limit counters and preserve the 16 KiB snapshot
ceiling. Host widget construction/deferred paint and interface operations retain
info timing spans. Shared Stats widgets intentionally charge the one physical
read once; they still validate each snapshot against their individual widget limit.

The #184 interface services retain their owners: small in-memory settings/native
style values, one lifecycle-cached device row, one-time bounded layout loading,
explicit layout saves, packaged static resources (659 B credits / 402 B battery),
and command dispatch. UI and server boundary guards pass without exemptions.
No new catalog scan, sort, large JSON decode, subprocess, transfer or blocking
cover acquisition is introduced into Lua render paths.

## Reuse and regression evidence

Source references at the reviewed base `6a49570d`:

- `android/koreader/orbit.koplugin/ko/library.lua:176`: existing paint contexts,
  aggregate/widget usage and one host flush, extended for remaining allowances.
- `android/koreader/orbit.koplugin/ko/store.lua:149`: existing one-row SQLite read,
  owner/reading/busy gate and memo, extended with a pre-decode caller byte ceiling.
- `android/koreader/orbit.koplugin/logic/cache.lua:100`: existing bounded work-window
  helper reused by the card-cover drain.
- `android/koreader/orbit.koplugin/ko/home_host.lua:40` and
  `ko/home_widgets.lua:37`: existing host and deferred bitmap renderer, unchanged.
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/LibraryReadModel.kt:27`:
  existing single companion publisher, extended for accurate scalar row spans and
  injectable sleep-choice fixture input.
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/PersonalReading.kt:13`:
  existing provider precedence/dedupe/selection owner, extended with batch-local pools.

Reproduce without a device:

```sh
luajit android/koreader/test/test_logic.lua
BOOKSYNC_PERF_REPORT=1 luajit android/koreader/test/test_flows.lua
python3 tools/test/test-ui-boundary.py
python3 tools/test/test-server-boundary.py
(cd android/companion && ./gradlew verifySharedVersion testDebugUnitTest assembleDebug lintDebug)
```

Companion test XML includes sanitized `PERF` lines with rows, bytes, provider/rank
counts and elapsed spans. The audit fixture uses plain JVM SQLite with injected
sleep choices, avoiding Android/Robolectric JDBC classloader coupling. No test or
boundary skip list was added. No device, adb, tag or release was used.


## Reader companion sheets (approved 2026-11-27)

Reader Status and Helpers each inherit four materialized rows, 16 KiB decoded
bytes and one local companion call per paint, with zero network calls or spawns.
The permission explanation shares that bounded snapshot; static actions have a
nine-row display limit. `ReaderCompanion` reads existing local preferences and the
native protected/permission policy; it never evaluates the full checklist or reads
the catalog. The Lua service checks bytes before decoding and rejects an incorrect
helper-row count. Unit fixtures cover oversized replies and foreground-only
completion/return; the emulator flow captures all four approved states.

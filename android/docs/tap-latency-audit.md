# Tap / hold latency audit

Verdict: **BookSync had UI stalls; the reported accidental dictionary lookup is
not yet attributed.** No recorded touch down/up reproduces it. Device delivery
latency remains possible. Do not change the reader's gesture preferences silently.
This fix concerns KOReader on Android; Xteink does not run these Lua paths.

## Gesture timing at the pin

KOReader `9192014d8bd82a91dc1012473be0f238dedfdb54` (v2026.07.1):

- `upstream/koreader/frontend/device/gesturedetector.lua:69` defaults hold to
  500 ms; `:106` reads `ges_hold_interval_ms`.
- `frontend/device/input.lua:1083` preserves the input event timestamp as `timev`.
  `gesturedetector.lua:675` arms the hold callback from that down timestamp and
  the hold interval (`:690`). The callback checks that the same contact is still
  down and in tap state (`:680`); it does not compare a future up timestamp.
- `input.lua:609` uses event origin + delay for monotonic input (`:648`), or
  current UI time for an unknown/non-monotonic clock. Crucially, `:1531` polls
  input even for an expired deadline; `:1533` processes available input before
  timeout callbacks. Only a polling timeout runs the hold callback (`:1536`,
  `:1585`). A queued up therefore normally cancels the hold before it fires.

The pinned KOReader base is `6e4bc81af4e04f78d81677a323a780a71b29702a` (the
`base` gitlink). Its `ffi/input_android.lua:25` preserves native monotonic
MotionEvent timestamps; down/up generation is at `:71` / `:83`.
`input.waitForEvent` (`:214`) polls ALooper once (`:236`) and drains Android's
input queue (`:258`). This backend has no `setTimer`: the polling-timeout path
above applies. Merely blocking Lua across 500 ms does **not** prove that a short
tap becomes a hold. A lift still unavailable when the expired timer is checked
can produce a hold; a device trace is needed to distinguish that from other
Android delivery issues. BookSync does not rewrite touch timestamps or timers.

## Reading-time paths and changes

Paths below are relative to `android/koreader/orbit.koplugin/`.

| Entry / work | Finding and prevention |
| --- | --- |
| `ko/net.lua:91`, `ko/server/bookorbit/bookorbit.lua:82` | Definite bug: every server HEAD was synchronous, with socket waits up to 1.5 s and DNS outside that timeout. Reading sync, pause sync and wake/open could reach it. HEAD now runs in `Background.run`; the child lifetime is capped too. `scheduleIn` alone never moves work off-thread. |
| `ko/store.lua:41`, `ko/db.lua:17` | Already had a 20 ms busy timeout, rather than the stress test's multi-second retry loop. Multiple reads can accumulate waits. During reading, the UI now returns only decoded memory hits or misses: no directory creation, SQLite open, inode stat, PRAGMA or query. Catalog children still read SQLite through their own connections. |
| `ko/reading_sync.lua:114`, `ko/server/bookorbit/orbismart.lua:507` | Page updates count/schedule work; custom chapter scheduling consults the in-memory TOC. Sync network preparation now uses the child probe. The pinned BookOrbit `bookorbit_progress_sync.lua:521` fetches progress through `runInSyncCoroutine`. |
| `ko/server/bookorbit/endofbook.lua:663` | Page turns formerly called `bookOf`, including plugin state lookup/copy on every turn. They now use a digest primed before reading (`:707`), keyed by reader and file. |
| `ko/server/bookorbit/endofbook.lua:498` | Outbox completion could run synchronous catalog detail/finish calls and write files during reading. This work now waits for the next sync outside the reading gate; completion callbacks still run. A sent notice is discarded once the sheet has closed. |
| `ko/status_layout.lua:15`, `:28`, `:311` | Page/position handlers only mark the status region dirty. Painting uses local text layout, TOC and battery APIs, without network or orbit.db. Layout/paint and minute callbacks are timed; actual device rendering cost remains to be measured. |
| `ko/keys.lua:21`, `:44`, `ko/clicks_channel.lua:94` | Mapped EV_KEY handlers only; unhandled keys pass through, touch ABS/SYN handling is untouched. The wait wrapper preserves real event batches. Channel reads are nonblocking. Channel setup formerly allowed a 1 s loopback wait; now capped at 20 ms. |
| `ko/companion.lua:256`, `:324`, `ko/jni.lua:168`, `ko/wifi.lua:103` | Companion commands/status, package checks, Wi-Fi/VPN and battery calls are synchronous Android bridges. They have no Lua-enforced real-time bound; persistent timing logs cover these operations and their surrounding scheduled callbacks. No device measurements establish their worst case. |
| `ko/server/bookorbit/cache.lua:307`, `ko/server/bookorbit/mirror.lua:240`, `ko/runtime.lua:43` | Cache replies/mirror progress poll small files; stats sends a companion command. These callbacks are timed as a whole, including file operations and follow-up UI work. Heavy mirror/cache/copy processing belongs to the companion; copies are gated by `reading()` (`ko/server/bookorbit/copies.lua:208`, `:264`). Filesystem and Android IPC latency cannot be guaranteed by a Lua wall-clock assertion. |

The context log's `sqlite-stress: ... max busy wait 1950 ms` measures the
explicit stress reader/writer, not a recorded page turn. Its reader deliberately
retries (`ko/sqlite_stress.lua:61`); it is not evidence of a 1950 ms normal
`Store.read`. No timing from that log establishes the accidental hold's cause.

## Persistent measurements and regression checks

`ko/main_loop.lua:9` logs
`booksync: main-loop stall N ms in <where>` for work exceeding 100 ms. It covers
BookSync's event/bridge functions and complete BookSync scheduled callbacks,
including status ticks and cache/mirror polling; it excludes input waiting and
child-process work. Labels contain operation names or source locations, no book
or account data. Returns, errors and callback cancellation retain their meaning.
Timing is observational: it cannot preempt an Android binder call or disk stall.

`android/koreader/test/test_flows.lua` holds a real exclusive SQLite lock while
running 25 page updates plus 50 warm/cold cache reads: zero database accesses and
under 50 ms for the entire batch. It also verifies the server probe executes only
in the background, finish work is skipped during reading, and diagnostics preserve
returns/errors and cancel scheduled callbacks by their original identity.
These are host budgets, not a claimed M8C worst case. Capture the retained stall
logs alongside input debugging if accidental holds persist on a test build.

## Native setting

In an open book: **Settings → Long-press on text → Do nothing**. KOReader's
`frontend/apps/reader/modules/readerhighlight.lua:364` lists the actions;
`:743` builds the menu and `:2118` disables highlighting for `nothing`.
The persisted key is `default_highlight_action = "nothing"` (`:2729`).
This disables text-hold handling (`:1676`, `:1756`), including dictionary lookup.
The same menu also has **Dictionary on single word selection** (`:746`), controlled
by `highlight_action_on_single_word`; turning just that option off retains other
long-press actions. BookSync adds no duplicate setting and changes neither key.

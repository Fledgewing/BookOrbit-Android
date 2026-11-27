# Emulated release tests

Status: **stages 0-2 built** (2026-11-23), following §7; stages 3-5 not started. §8 says what was
built and where it differs from the plan. This is test infrastructure, not a feature, so it has no
ROADMAP row.

**Outcome.** Before each release, a CI stage runs the device scenarios that are tested by hand
today. It runs on both platforms and against a BookOrbit server with scripted faults. It leaves
real hardware with a short, named list of what only hardware can show. It is a release gate: it
runs on a release or on demand, never on every push. The push CI (`android.yml`, `xteink.yml`'s
host tests) stays as it is.

Pins used below: BookOrbit `v3.9.0` `c1dd6b4` (image `ghcr.io/bookorbit/bookorbit:3.9.0` exists);
CrossInk-Bookorbit `v2.0.0+bookorbit.1-rc3` `87e2e19`; KOReader `v2026.07.1` `9192014`
(`tools/upstreams.lock`).

## 1. What broke in hand testing, and where it lives

| # | Scenario | Platform | Where the bug or rule is |
|---|---|---|---|
| A1 | Home's first paint flashes Download, then Resume | Android | [write-through-cache](write-through-cache.md) "first paint" (l.116); PR #10 item 4 |
| A2 | Full refresh progress and the offline mirror: retry, resume, pages of 50 and 25 | Android | write-through-cache "No answer (v0.11.2)"; `cache/cases.json` `mirror.retry`, `mirror.small_pages` |
| A3 | Offline list paging (`Cache.slice`) | Android | write-through-cache "Pages" |
| A4 | Covers don't blank (no `evictCachedCovers`; ETag 304) | Android | write-through-cache "Refresh and Full refresh", "Cover version" |
| A5 | A changed copy is replaced only when the book isn't open | Android | [keep-copies-current](keep-copies-current.md) "When" |
| A6 | Nothing shows while reading (`reading()`, `bookorbitOverBook`) | Android | [reading-gate](reading-gate.md) "The gate"; PR #10 item 1 |
| A7 | Update flow: install-session states; KOReader restart rules | Android | `UpdateSession` (`Logic.kt:260`), `Installers.kt:126`; reading-gate "Restarts after an update" |
| A8 | Storage limit with LRU eviction | Android | write-through-cache "Storage limit (v0.11.2)"; `cases.json` `storage` |
| X1 | A power press wakes the reader during the sleep sync | Xteink | sleep-sync watcher (`core/SleepSyncDeadline.h`) |
| X2 | Sleep-sync time budget (240 s, then a forced sleep) | Xteink | sleep-sync budget, `core/SleepSyncDeadline.h` |
| X3 | Heap starvation: mirror + Tailscale + TLS | Xteink | session lending and `orbify/HeapFloor.h` |
| X4 | DNS `udp_remove` core-lock panic | Xteink | commit `9db15e3`, `tailnet/shim/TailnetLwipLock.c` |
| X5 | Mirror URL building (the `\x1f` separator turned into a space gave a 400) | Xteink | `core/Mirror` `Plan::add` |
| X6 | Copy refresh (match check `LOW_MEMORY`, replace in place, carry-over) | Xteink | `orbify/CopyRefresh`, session lending |
| X7 | End-of-Book page layout and gestures | Xteink | `orbify/EndPageActivity`, `core/EndPageLayout` |
| X8 | The catalog's ⟳ feedback | Xteink | patch 0035 M5-M7 |
| X9 | Cover fetch under a heap floor | Xteink | `orbify/HeapFloor.h`, Home cover floor |
| X10 | OTA download and boot | Xteink | patch 0030; `ota_release_pick_test.cpp` |

## 2. What already exists (reuse first)

- **Plugin flows on a fake KOReader.** `android/koreader/test/test_flows.lua` (4,294 lines) loads the
  whole plugin against stand-ins for KOReader, JNI and the BookOrbit plugin, on a fake clock. Its
  own header says it "proves nothing about the device" (l.1-4). It is the right layer for A2, A3,
  A6, A8 logic, and already covers each v0.11.2 fix (PR #10 "Tests").
- **Companion pure logic.** `UpdateSession` is pure and tested (`UpdateSessionTest`, `LogicTest`).
  The Android parts (`Updater.sessionAlive` → `packageInstaller.getSessionInfo`,
  `Installers.onSessionStatus`) have no test.
- **Xteink pure logic and a render path.** `xteink/test/run-host-tests.sh` builds `orbify/core`
  against ArduinoJson and runs the shared tables (`orbify_test …`, l.44-59). The End-of-Book PNGs come
  from `eob_render.cpp`, which draws `core/EndPageLayout`'s ops with FreeType from CrossInk's font
  sources and checks the touch rules (l.60-72). CI uploads them as `eob-page-*` (`xteink.yml:254`).
  `lwip_lock_test.c` checks the `dns_clear_cache` wrapper against stand-in lwIP headers (l.74-76).
- **Upstream already has a desktop simulator and an end-to-end harness against a real BookOrbit.**
  This is the main finding:
  - CrossInk-Bookorbit (a CrossPoint fork) builds `[env:simulator]`, `simulator-X3`,
    `x4-pro-simulator` and `x4-classic-simulator` at rc3 (`platformio.ini:381-445`). They link
    `uxjulia/crossink-simulator`, pinned at `e9879b6` (l.365), an SDL2 host build of the firmware.
  - **Input and screenshots.** The simulator has scripted input:
    `CROSSPOINT_SIM_INPUT_SCRIPT='900:DOWN;…;3000:QUIT'`, with buttons, `POWER`, `SLEEP`, `HOME`,
    X4 Pro `TAP`/`SWIPE`, and `…_AFTER_WAKE` / `…_AFTER_REBOOT` scripts for the processes it
    re-execs. Screenshots are BMPs (`CROSSPOINT_SIM_SCREENSHOTS`).
    BookSync's shared sleep-sync helper opts into `ORBIFY_SIM_INPUT_FROM_POLL`: its short
    Power press is timed from the first input poll. Absolute scripts can lose both button
    edges when settings setup takes longer than the scheduled press (observed: setup at
    3877 ms, press at 2500–2620 ms). The package's `src/HalGPIO.cpp:392-400` at simulator
    `e9879b6d9c5f98f9db57c8c4c2dfee573f1585e8` processes all expired events in one poll.
    The opt-in shim and host regression preserve the press duration after a late boot;
    absolute input/screenshot clocks and scenario deadlines remain unchanged. No retries.
  - **Network.** Host-backed HTTP goes through `curl`, or with `CROSSPOINT_SIM_USE_SDK_HTTP=1`
    the SDK's real HTTP and resumable download run over OpenSSL. `CROSSINK_SIM_HTTP_MOCK_ROOT`
    serves fixtures.
  - **Stack checks.** A task stack-budget check is available (simulator README, "Automated QA and
    screenshots", "Notes", "Checking task stack budgets").
  - **The harness.** `test/integration/` runs that simulator against the official BookOrbit image
    plus Postgres in Docker Compose. `seed/seed.py` sets up the user, the KOReader credentials and
    the library, and plays a "synthetic device". `harness/run_scenarios.py` gives each scenario
    its own SD directory, runs the binary with `SDL_VIDEODRIVER=dummy`, and asserts on the SD
    tree and the server API. It has ~35 scenarios at rc3. Several are ours almost verbatim:
    - `sleep_sync_cancel`: "A Power press during the sleep sync cancels it and boots the device
      the way a power-button wake does";
    - `outdated_copy_holds_changes` and `book_update_offer`: the server writes metadata into the
      file;
    - `book_update_carries_state`;
    - `catalog_deep_listing`.
  - **Measured cost.** Upstream's `integration` job, on recent successful runs, took 22-24 min.
    Of that, the simulator build took 3 min 9 s, server start 29 s, seeding 26 s, and the
    scenarios 18 min 45 s (job steps of run 2026-11-22 21:58 UTC).
  - **Flakiness.** Of the last 20 `main` pushes, 11 failed. 5 of the 6 failures sampled failed in
    "Build the simulator", not in a scenario. The simulator was fetched unpinned at the time; the
    README says this is where "an upstream simulator change shows first". rc3 pins it.
- **The overlay already guards for the simulator, but doesn't build there.**
  - Patches 0004, 0020-0024, 0027 and 0036 carry `#ifdef SIMULATOR` blocks.
  - The BookSync switches are set only by `tailnet_build.py`, for `SWITCH_ENVS = ("default",
    "x4-pro", "x4-classic")` (l.63, l.213-230). `overlay/platformio.local.ini` hooks only those
    three envs, and the headers default every `CROSSINK_TAILNET_ORBIFY_*` to 0 (patches 0029,
    0035). So **a simulator build today has no BookSync features**.
  - `BookOrbitSyncClient::orbifyRequest` returns `-1` under `SIMULATOR` (patch 0027 l.113). That
    is the finish queue's writes, and only those: the mirror and the copy refresh use the catalog
    client's own fetches, which upstream's scenarios already run in the simulator.

## 3. Android: the options

### 3.1 Option A-E: Android emulator (AVD) in Actions, real KOReader APK + companion

- **Runner.** Standard Linux runners have KVM. Since 2024-04-02, 2-vCPU GitHub-hosted Linux runners
  get hardware-accelerated Android virtualization; enable it with a udev rule
  ([changelog](https://github.blog/changelog/2024-04-02-github-actions-hardware-accelerated-android-virtualization-now-available/)).
  `ReactiveCircus/android-emulator-runner` recommends `ubuntu-latest` over macOS and caches an AVD
  snapshot ([README](https://github.com/ReactiveCircus/android-emulator-runner)). BookSync is public,
  so standard-runner minutes cost nothing
  ([billing](https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-actions/about-billing-for-github-actions)).
- **KOReader on x86.** KOReader v2026.07.1 ships `koreader-android-x86-…apk` beside arm and arm64
  (release assets; `InstallLogicTest` already picks it for an `x86_64, x86` ABI list). Use an
  API 30 `google_apis` x86_64 image: it runs 32-bit x86, and it can translate ARM in-process as a
  fallback ([Android Developers, 2020-03](https://android-developers.googleblog.com/2020/03/run-arm-apps-on-android-emulator.html)).
  The companion targets SDK 28 and installs as is.
- **Driving the UI.** KOReader draws its own widgets into one surface: UiAutomator sees no tree,
  only coordinates. So the driver lives inside KOReader: a test-only plugin, `orbit-e2e.koplugin`
  (never packaged), pushed with `adb push` next to `orbit.koplugin`. It:
  - reads a scenario script;
  - sends KOReader events (open BookOrbit Home, hold ⟳, open a book, close it, suspend);
  - writes one JSONL line per BookSync log event and per paint of an BookSync widget;
  - takes screenshots with KOReader's own `Screen:shot` (`frontend/ui/widget/screenshoter.lua:63`).

  `adb shell screencap` is the cross-check. System UI (the package installer's prompt) is
  accessible, so UiAutomator drives that.
- **What only the AVD shows.**
  - Real Android process rules. The `subprocess_no_result` bug (JNI called in a forked child,
    write-through-cache l.142) cannot happen off Android.
  - Real broadcasts between the plugin and the companion (`android/docs/INTERFACE.md`).
  - Real `PackageInstaller` sessions.
  - Lifecycle: screen off (`input keyevent KEYCODE_SLEEP`) and KOReader in the background, which
    the restart rules (A7) turn on.
  - Wi-Fi off (`svc wifi disable`) for the offline cases.
- **Flakiness.** Emulator boot is the known flaky step; snapshot caching and a boot-completed wait
  are standard. KOReader's first start asks for storage access. Grant it with `appops`, or pre-seed
  its settings before the first launch. That is a fixed setup step, not a per-test risk. Pixel
  diffs are flaky; JSONL assertions are not. So screenshots are artifacts for review and never
  compared.
- **Cost (estimate).**
  - Emulator start from a cached snapshot: 1-3 min.
  - APK installs: under 1 min.
  - 15-20 scenarios at 20-60 s each.
  - Job total: about 20-30 min, free on this public repo.

### 3.2 Option A-D: KOReader's Linux desktop build, headless

- **The build and its knobs.** KOReader publishes `koreader-linux-x86_64-….tar.xz` and an AppImage
  (release assets). Its SDL device reads emulation knobs: `EMULATE_READER_VIEWPORT`,
  `DISABLE_TOUCH`, `EMULATE_READER_FORCE_PORTRAIT` (`frontend/device/sdl/device.lua:173-184`).
  Under `xvfb-run` it is a normal process; the same `orbit-e2e.koplugin` drives it and calls
  `Screen:shot`.
- **The catch.** BookSync refuses to load off Android: `ko/base.lua:16` (`if not Device:isAndroid()
  then … INACTIVE`). A desktop run needs a test-only preload that:
  - reports Android;
  - supplies the `android` module and JNI from `test_flows.lua`'s fakes (wifi, foreground, screen,
    broadcasts).

  That is a moderate shim, and it makes the desktop run a mix: the real KOReader widget stack,
  catalog, BookOrbit plugin and cache, with fake Android.
- **What it shows that `test_flows.lua` can't.**
  - The real window stack. The A6 bug was `reading()` misreading what was on top: a BookOrbit
    pill or a KOReader message over Home.
  - The real BookOrbit plugin's catalog code paths: its child processes, `refreshCurrent`, the
    cover queue.
  - Real paging against a real server.
  - The real paint order (A1).
- **What it misses.** Everything in 3.1's "only the AVD" list.
- **Cost (estimate).** About 8-12 min: no emulator boot; KOReader starts in seconds.

### 3.3 Faking the companion's install-session states

Yes, at two levels.

1. **JVM, deterministic, every state.** Add Robolectric to the companion's unit tests.
   `ShadowPackageInstaller` creates sessions, answers `getSessionInfo`, and can fail one
   (`setSessionFails(int)`; Robolectric 4.x
   [javadoc](https://robolectric.org/javadoc/4.16/org/robolectric/shadows/ShadowPackageInstaller.html)).
   `onSessionStatus` takes a plain `Intent`, so a test sends it each status with its message:
   - `STATUS_PENDING_USER_ACTION`;
   - `STATUS_SUCCESS`;
   - `STATUS_FAILURE_ABORTED` (3) with `INSTALL_FAILED_ABORTED`;
   - a session that disappears;
   - a stale session (`STALE_MS`).

   This covers the M8C case: three taps while Play Protect held the first session. The tap → phase
   → status-line chain runs through `Updater` itself, not only `UpdateSession`. These tests run on
   every push with the rest of `testDebugUnitTest`. That is the cheapest place to catch A7's
   regressions.
2. **AVD, real installer, the happy and cancel paths.** The test serves a newer signed debug APK
   from the fake releases feed. The companion commits a session, and UiAutomator either
   confirms the system prompt (→ SUCCESS, KOReader restart rules) or cancels it (→ "Android
   cancelled the install; tap to try again"). The Play Protect hold-up itself can't be reproduced
   on an emulator; level 1 covers its effect.

### 3.4 Android: what each option catches

| | `test_flows` today | A-D desktop | A-E AVD | JVM Robolectric |
|---|---|---|---|---|
| A1 first-paint flash | logic | **yes** (paint log) | **yes** | - |
| A2 Full refresh, retry, resume, 50/25 | logic | **yes** (fault proxy) | **yes**, plus real network loss | - |
| A3 offline paging | logic | **yes** | **yes** (Wi-Fi really off) | - |
| A4 covers don't blank | partly | **yes** (real `refreshCurrent`, real files, 304s) | **yes** | - |
| A5 replace only when not open | logic | **yes** | **yes** | - |
| A6 reading gate | logic | **yes** (real stack) | **yes**, plus companion notifications | `ReadingGuardTest` |
| A7 install sessions | - | - | real prompt, confirm and cancel | **all states** |
| A7 restart rules | `RestartPlan` | in-KOReader parts | **yes** (screen off, background, relaunch) | `LogicTest` |
| A8 storage limit LRU | logic | **yes** (real files, small limit) | **yes** | - |
| JNI-in-child class (`subprocess_no_result`) | no | no | **yes** | - |

## 4. Xteink: the options

### 4.1 Option X-Q: Espressif's QEMU fork

Espressif's QEMU supports ESP32, **ESP32-S3** and **ESP32-C3**. From its feature table
([esp-toolchain-docs/qemu](https://github.com/espressif/esp-toolchain-docs/blob/main/qemu/README.md)):

| Feature | ESP32-S3 | ESP32-C3 |
|---|---|---|
| PSRAM (QPI/OPI) | yes | n/a |
| SD/MMC | no | n/a |
| Ethernet (OpenCores, emulation-only) | yes | yes |
| Wi-Fi | **no** | **no** |
| RGB framebuffer (emulation-only) | yes | yes |
| GP SPI | **no** | **no** |
| GPIO matrix / IOMUX | **no** | **no** |
| UART, timers, eFuse, flash encryption | yes | yes |

What follows for these readers:
- The X4/X3 e-paper panel and the SD card are on SPI. QEMU has no GP SPI, so neither works, and
  the real firmware would stall at display or card init.
- With no GPIO matrix, there are no buttons.
- With no Wi-Fi, the WiFi-tier and RX-buffer behaviour behind X3 slow OTA downloads (patch 0030
  O3) is absent. MicroLink's Wi-Fi bring-up is absent too.

So QEMU can't run the reader. It could run a **purpose-built ESP-IDF test app** on openeth: lwIP,
MicroLink, mbedTLS/wolfSSL, the `dns_clear_cache` wrapper and an HTTPS fetch loop. Built with
lwIP's core-locking assertions on, that app would be the only emulated place where a real lwIP
`udp_remove` called off `tcpip_thread` asserts (X4). It would also give real ESP-IDF heap numbers
for TLS plus a DERP session, minus the Wi-Fi driver's buffers, which on the device are what leaves
~30 KB free (the shared-heap analysis in XTEINK-BUILD-NOTES.md). That makes it a spike with a narrow payoff (stage 4, optional).

### 4.2 Option X-S: the upstream CrossInk/CrossPoint simulator

Section 2 described it. It is an SDL host build of the whole firmware: activities, renderer,
fonts, storage on a host directory, the BookOrbit sync and catalog clients over host HTTP, sleep
and wake as process re-exec, `ESP.restart()` as re-exec, and desktop threads for tasks.

To run BookSync in it:
1. Add simulator envs to `overlay/platformio.local.ini` (`x4-pro-simulator`,
   `x4-classic-simulator`, `simulator-X3`) with a `sim` mode in `tailnet_build.py`. That mode sets
   the BookSync switches from the matching reader column and builds no MicroLink. Tailscale is not
   in the simulator; the fake server is reachable directly.
2. Route `orbifyRequest` under `SIMULATOR` through the same host HTTP shim the sync client uses,
   instead of `return -1`.
3. Add a **scripted heap** to the simulator side of `orbify/HeapFloor`. Under `SIMULATOR`, free and
   largest-block values come from a timeline (`ORBIFY_SIM_HEAP="0:120000/60000;30000:20000/14000"`),
   so the floors' decisions run. These are the decisions: wait, stop a transfer, resume its
   `.part` next sleep, skip a cover decode without a 54 KB block.
4. Write BookSync scenarios into a copy of upstream's harness pattern, under `xteink/test/e2e/`. They
   reuse `seed.py`, the compose file and the runner by pinning upstream's files at the CrossInk pin;
   our scenarios live in our repo.

What it can and can't show:
- **Timing.** The simulator runs in real time. Scenarios that are about *a step that doesn't check
  for a press*, or *a budget that isn't enforced*, reproduce exactly: the fault proxy stalls a reply
  for 90 s and the input script presses `POWER` at 10 s. The sleep-sync wake/budget bug (one step blocked 82 s)
  is that shape.
- **Heap.** The simulator can't show real heap or fragmentation: its README says neither the shims
  nor native TLS are "evidence of wolfSSL heap use or ESP32 certificate behavior".

### 4.3 Option X-H: host build of the overlay logic against a fake HAL, rendering to PNG

This exists: `orbify/core` and the host tests, plus `eob_render`. Two ways to extend it:
- **More renderers.** Render the catalog header ⟳ and stamp states, and the Full refresh progress
  line, to PNG the same way. That means pulling their layout into `core/` as `EndPageLayout` was.
- **More shared tables.** Every Mirror request kind through add, serialize, parse and decode, which
  the mirror URL fix already adds.

It is fast (seconds) and exact for logic and layout. It can't show flows across activities, the
real sync's ordering, input handling in the real activity (0032 P4: input falling through to page
turns), or anything on the network.

### 4.4 Xteink: what each option catches

| | X-H host (today + renders) | X-S simulator + fault proxy | X-Q QEMU test app | Only a device |
|---|---|---|---|---|
| X1 power press during sleep sync | `SleepSyncDeadline` rules | **yes**: stalled step + `POWER` | - | the watcher's real-task restart timing |
| X2 time budget | rules | **yes**: 240 s budget with proxy stalls (one slow scenario) | - | - |
| X3 heap starvation | floor rules | floor **decisions** (scripted heap) | partial: real TLS heap, no Wi-Fi | **the real numbers** (`esp-aes: Failed to allocate`) |
| X4 DNS / `udp_remove` lock | wrapper rule (`lwip_lock_test`) | no (no lwIP) | **yes**, with core-lock asserts | the race with real STUN timing |
| X5 mirror URL building | **yes** (round trip) | **yes**: the real server answers 400 to a bad query | - | - |
| X6 copy refresh | queue and hash rules | **yes**: the real server rewrites the file (upstream's `book_update_offer` pattern); `BookUpdateMigration` carry-over, which isn't host-tested today | - | `LOW_MEMORY` on a second TLS session |
| X7 EOB layout and gestures | layout and touch rules + PNGs | **yes**: real activity input (`TAP`, `SWIPE`, Home swipe, stale tap), screenshots, fonts registered by the End-of-Book activity | - | e-ink refresh and ghosting |
| X8 ⟳ feedback | stamp text | **yes**: tap, hold, offline "Couldn't connect", screenshots | - | - |
| X9 cover under heap floor | `planCover` | decision via scripted heap; 304/200 via the real server | - | a real 54 KB block |
| X10 OTA | release pick, retry | the check UI against a mocked feed (`CROSSINK_SIM_HTTP_MOCK_ROOT`); the simulator stubs the flash itself | - | **download, flash, boot, rollback** |

## 5. The BookOrbit side: a fake server or the real one

**Recommendation: the real BookOrbit 3.9.0 in Docker, seeded, behind a small scripted fault proxy.**
Recorded fixtures stay for the host tests (`shared/fixtures/`).

- **Real server.** Upstream's harness already does this (`ghcr.io/bookorbit/bookorbit` + `pgvector/pgvector:pg18`,
  `docker compose up --wait` in 29 s, seed in 26 s). We pin `:3.9.0` by digest, not `latest` as upstream
  does. Several of our bugs exist only because of real server behaviour that a replay would have to
  re-implement and would get wrong:
  - a metadata write changes the file hash ([server contract](../server-contract.md#a-metadata-write-changes-the-file-hash));
  - `match-check` records unknown hashes;
  - `generatedAt` and Discover change on every reply;
  - ETag/304 on thumbnails;
  - a query the server rejects with 400 (X5).

  A replay server would have passed X5.
- **Fault proxy** (`tools/e2e/bofault`, one small Go or Python file). It sits between the devices
  and the server, and a scenario file gives it rules matched on method, path and query:
  - `delay` (slow replies; X2 stalls);
  - `status` (400, 500);
  - `timeout` (accept, never answer: A2's retry, then pages of 50 and 25);
  - `drop` (offline mid-run);
  - `once`/`after N` counters.

  It logs every request as JSONL, so a scenario can assert, for example, "the second try asked
  `limit=50`". Offline as a whole is the device's own switch (`svc wifi disable`; for the
  simulator, the proxy refuses connections).
- **Changed hashes.** Use the server's own metadata write through its API, as upstream's
  `outdated_copy_holds_changes` does. That covers A5 and X6.
- **Both devices share it.** The AVD reaches the host at `10.0.2.2`; the desktop KOReader and the
  simulator reach `127.0.0.1`. The same seed and the same proxy serve every job.
- **Why not a pure replay.**
  - It is quicker to start (no Postgres), but every behaviour above must be hand-written and
    re-checked at each BookOrbit pin.
  - The weekly `plugin-compat.yml` already follows BookOrbit's plugin; a real server follows its
    API for free.
  - Recorded replies stay the input of host tests, where speed matters.

## 6. Recommendation

### 6.1 Stages

| Stage | What to build | Covers | Effort (AI speed) | CI time per run |
|---|---|---|---|---|
| **0. Server kit** | `tools/e2e/`: compose (BookOrbit 3.9.0 by digest + Postgres), seed adapted from upstream's `seed.py` (~100 generated EPUBs, covers on 9 in 10, two series, a want-to-read shelf), `bofault` proxy with JSONL log | shared by all | 2-3 h | ~1 min start + seed |
| **1. Xteink simulator** | sim envs in the overlay; `tailnet_build.py` sim mode; `orbifyRequest` over host HTTP; scripted heap in `HeapFloor`; `xteink/test/e2e/` runner and 12 scenarios (X1, X2, X5-X9, the X10 check UI), X4 Pro and X4 Classic profiles; screenshots uploaded | X1, X2, X5, X6, X7, X8, X10 (check), X3/X9 (decisions) | 5-7 h | ~3 min build per profile + ~8-12 min scenarios |
| **2. Companion JVM** | Robolectric; `Updater` and `Installers.onSessionStatus` tests for every session state | A7 (sessions), every push | 1-2 h | +1 min to `testDebugUnitTest` |
| **3. Android desktop** | `orbit-e2e.koplugin` driver (scenario script, JSONL, `Screen:shot`); Android preload shim reusing `test_flows.lua`'s fakes; KOReader linux-x86_64 v2026.07.1 + the BookOrbit plugin from the 3.9.0 pin; `xvfb-run`; 10 scenarios | A1-A6, A8 | 4-6 h | ~8-12 min |
| **4. Android AVD** | API 30 x86_64 AVD with a cached snapshot; KOReader x86 APK + debug companion; the same driver plugin; UiAutomator for the system installer; 8 scenarios focused on what only Android shows | A7 (real installer, restarts), A3/A6 with real Wi-Fi and lifecycle, the JNI-child class | 4-6 h | ~20-30 min |
| 5. (optional) QEMU network app | an ESP-IDF app on ESP32-S3 QEMU, openeth: MicroLink + lwIP core-lock asserts + TLS fetch loop | X4 class, TLS heap trend | 4-8 h, spike first | ~5 min |

Order: 0 → 1 and 2 in parallel → 3 → 4. Stage 1 first, because the Xteink list is longer and
its hand test is the slower one. Stage 3 before 4, because it covers most of the Android list at a
third of the CI time. Stage 4 then adds only the Android-only rows. Stage 5 waits until a second
lwIP-class bug shows up.

### 6.2 What still needs a real device

The device test becomes a short checklist that the stage's report prints, each with the serial or
logcat line to look for (the build notes' "Measurements needed on a device" already does this):

- **Xteink:**
  - real heap and fragmentation with Wi-Fi + Tailscale + TLS: X3, X9 numbers; no
    `esp-aes: Failed to allocate memory`;
  - the DNS lock race with real STUN timing (X4);
  - the Wi-Fi tier and download throughput (patch 0030);
  - **OTA flash, boot and rollback** (X10);
  - e-ink refresh, ghosting and touch feel (X7);
  - the power watcher's forced restart on real tasks (X1);
  - battery.
- **Android:**
  - vendor quirks (Meebook M8C launcher, Play Protect delays: A7);
  - e-ink refresh;
  - the real Tailscale app;
  - clicker buttons.

### 6.3 How it slots into releases

One reusable workflow, `.github/workflows/release-tests.yml` (`workflow_call` + `workflow_dispatch`,
input `platform: android | xteink | all`, `ref`, and optional simulator `profiles`):

From 0.12 the [source fingerprint policy](unified-version.md#selective-previews-and-promotion)
selects preview builds and allows matching passing receipts to satisfy this gate.
Component-test evidence alone never replaces the emulated gate. RC/stable always
rebuild with the new version, even when the gate is reused; cheap artifact checks
remain mandatory. Legacy releases and ordinary PR/push builds retain full checks.

- **Android** (`release.yml`): a `release-tests` job runs stages 3 and 4 on the tag, and
  `release` `needs` it.
  - A tag is never moved (AGENTS.md "Releases"), so a red after a tag push costs a version
    number. Therefore the cut runs `release-tests` by dispatch on the release commit first, then
    tags.
  - The gate on the tag stays as the backstop.
  - Stage 2 lives in `android.yml` with the other unit tests (every push), since it is seconds.
- **Xteink** (`xteink.yml`): the manual dispatch is how our own changes ship (README "When a release
  is made"). Add an `e2e` job after `build` that runs stage 1 against the same upstream tag and
  overlay, only when `needs.resolve.outputs.publish == 'true'`; `release` `needs` it.
  - The daily scheduled run publishes only for a new upstream tag. The same gate holds it, so a
    new upstream rc that breaks a scenario is not published.
  - Push and PR runs are unchanged.
- **Artifacts:** `e2e-<platform>-<version>` holds screenshots (PNG; the simulator's BMPs
  converted), the JSONL event and proxy logs, and the device checklist.

## 7. Decisions

| # | Decision | Door | Recommendation |
|---|---|---|---|
| D1 | Xteink emulation: upstream simulator vs QEMU vs host-only | two-way | **Simulator** for flows, **host** for logic and renders, QEMU only as stage 5 |
| D2 | Our scenarios: in our repo vs added to upstream's harness | two-way | **Ours** (`xteink/test/e2e/`), reusing upstream's seed and compose files at the CrossInk pin |
| D3 | Sending simulator, HAL or harness fixes upstream (CrossInk-Bookorbit, crossink-simulator) | **one-way** (public, someone else's repo) | **Never** (the maintainer's rule, AGENTS.md "Upstream projects"): every fix stays in BookSync, as an overlay patch or a build-time edit of the fetched package |
| D4 | Server: real BookOrbit 3.9.0 + fault proxy vs replay | two-way | **Real + proxy**; recorded fixtures stay for host tests |
| D5 | Image pin: `:3.9.0` by digest vs `latest` | two-way | **Digest**, re-pinned with `tools/upstreams pin bookorbit` |
| D6 | Android: desktop vs AVD | two-way | **Both**: desktop first (stage 3), AVD for the Android-only rows (stage 4) |
| D7 | UI driver: in-KOReader plugin vs coordinate taps | two-way | **`orbit-e2e.koplugin`**, never packaged (`package.sh` zips only `orbit.koplugin/`) |
| D8 | Assertions: JSONL events vs screenshot diffs | two-way | **JSONL**; screenshots are review artifacts, never compared. One exception (the catalog stamp fix): `catalog_refresh_stamp` checks that the rectangle the log names for the catalog's final stamp has ink, since the defect was a draw the log said happened. The simulator presents and saves screenshots only from its main loop, which the refresh holds, so "Refreshing…" is judged from the log (drawn before the first request) and the screenshots are taken well after the refresh and before the QUIT. The harness asks SDL for its software renderer (`SDL_RENDER_DRIVER=software`): with the dummy video driver on Linux there is no accelerated one, and the simulator then saved no screenshots, silently |
| D9 | Test-only code in shipped firmware | two-way | Only under `#ifdef SIMULATOR` (compiled out of reader builds, as upstream's scenario hooks are) |
| D10 | Scripted heap under `SIMULATOR` | two-way | **Yes**: tests the decisions; the numbers stay a device check. Built at the HAL (the simulator's `heap_caps_*`), not in `HeapFloor` (§8) |
| D11 | Robolectric in the companion's unit tests | two-way | **Yes** (test-only dependency) |
| D12 | Gate placement: block `release` vs advisory | two-way | **Block**, with a dispatch run before tagging so a red never burns an Android version |
| D13 | Xteink gate on the scheduled run (new upstream tag) | two-way | **Yes**, the same `e2e` job; an upstream rc that fails a scenario isn't published |
| D14 | Stage 5 QEMU app | two-way | **Defer** until a second lwIP-class bug |

No other one-way doors: everything is test-only, behind its own workflow, and removable.

## 8. As built (stages 0-2)

| Stage | Where | Runs | Time (local, Apple silicon) |
|---|---|---|---|
| 0 | `tools/e2e/`: `compose.yml` (BookOrbit 3.9.0 and Postgres, both by digest), `kit.py` (up, seed, rewrite, down), `bofault.py` (delay, status, timeout, drop; `after`/`times`; JSONL log), `test_kit.py`; library and faults in `shared/fixtures/e2e/` | `release-tests.yml` job `kit` | up ~10 s, seed ~2 s, tests ~7 s |
| 1 | sim envs in `overlay/platformio.local.ini`; `tailnet_build.py` sim mode with `tailnet/sim/` (Tailnet stubs, `sim_package.py`); patch `0090-orbify-simulator-build`; `xteink/test/e2e/` (`run.py` scenarios, `sim.py` SD card and simulator driver) | job `xteink`, one per reader | build ~30 s per reader (cached packages), scenarios below |
| 2 | `android/companion/.../UpdaterSessionTest.kt` (Robolectric 4.14.1, test-only) | `android.yml` on every push, and job `android` | ~15 s |

Android also gates releases on `release-tests.yml`'s `reader-startup` job. It runs the
plugin's `startup` flow cases with the pinned KOReader's real `Trapper` module, a yielding
progress GET, and ReaderReady before showing ReaderUI. It asserts that construction completes,
the reader stays on top, and no close or quit is requested; status layout initialization is
checked for both CRE and paged documents. The gate also opens from Home, history and the file
browser during Full refresh with a repair pending, using the pinned `showReaderCoroutine`.
Its zero-timeout opening message must keep a window present until ReaderUI is shown, and no
repair request or result may delay opening. Trapper lifecycle widgets remain present.
This is a coroutine/lifecycle smoke test, without a
rendering engine or Android JNI; stage 3's desktop reader remains planned.

The ordering is from KOReader `9192014d8bd82a91dc1012473be0f238dedfdb54`:
`frontend/apps/reader/readerui.lua:711-738` shows the opening message before scheduling reader
construction; `:517` sends ReaderReady during init and `:791` shows the reader
only after construction; `frontend/ui/trapper.lua:66` treats any running coroutine as wrapped.
BookOrbit `c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7`'s
`koreader-plugin/bookorbit.koplugin/main.lua:276` reuses that coroutine, and
`bookorbit_progress_sync.lua:521` fetches remote progress through it. Orbit must defer its
open-time pull until the next UI tick, so a background GET cannot suspend reader construction
with an empty window stack.

Where it differs from §4-§6:
- **Library.** `kit.py` generates its own EPUBs from `library.json` (three series, eight authors,
  48 standalones, a want-to-read shelf, covers on 9 in 10) rather than adapting upstream's
  `seed.py`, so nothing is copied from upstream and every hash is fixed. A changed hash comes from
  the server's own write-back (`kit.py rewrite <role>`).
- **Scripted heap.** `ORBIFY_SIM_HEAP` caps what the simulator's `heap_caps_get_free_size` and
  `..._largest_free_block` report for internal RAM, so every floor (`HeapFloor`, the TLS floor, the
  cover and Wi-Fi checks) sees it, not only `HeapFloor`. A step written `w<ms>` counts from the
  process's first `WiFi.begin()`: a device's heap once Wi-Fi and Tailscale took their share, which
  the check before starting Wi-Fi must not see. `sim_package.py` edits the fetched simulator
  package at build time.
- **Power watcher.** The firmware's watcher task samples a raw pin the simulator lacks. Under
  `SIMULATOR` (patch 0090) it runs as a host thread whose pin is the input script's `POWER`
  presses, so a press during a request the proxy holds is seen as on a reader (X1). 0090 also
  carries the restart token across the watcher's forced restart, as the device's RTC memory does.
- **X10** (OTA check UI) is not a simulator scenario: upstream's simulator build leaves
  `OtaUpdater.cpp` out. It stays on the device checklist.

The Full refresh network regressions enable `ORBIFY_SIM_SDFAT_MKDIR`: creating
an existing final directory fails, as on the reader's SdFat storage. PR #190's
host stub and simulator both returned success, hiding the marker failure that
was misclassified as a crash. The same assumption also blocked the bulk SD
writer. These tests assert real setup routing for catalog (35), Home refresh
(36), Home settings (37), and sleep sync (33), as well as durable completion;
queueing a request or observing a 0% badge is insufficient. The existing crash
injections still require two genuinely unfinished attempts to quarantine.

Scenarios (`run.py --list --profile P`), covering the sleep-sync and device fixes on main; X3 has no mirror, no
series-card cover fetch and no lent connection, so it runs the three that apply to it:

| Scenario | Rows | Readers |
|---|---|---|
| `sync_through_proxy` | foundation | all |
| `mirror_urls` | X5, flash-safe refresh task stack | X4s |
| `full_refresh_crash_breaker` | two unclean worker boots, durable quarantine, retained books/settings | X4s |
| `full_refresh_sd_card_recovery` | remove the single persisted request, boot without retrying | X4s |
| `full_refresh_early_boot_breaker` | two setup crashes, disable suspect catalog before cache reads | X4s |
| `full_refresh_quarantine_sync_network` | quarantined state → sync tile hold → real Home refresh boot, visible progress and published catalog | X4s |
| `full_refresh_quarantine_catalog_network` | quarantined state → catalog network boot → ⟳ hold, visible progress and published catalog | X4s |
| `full_refresh_quarantine_settings_network` | quarantined state → Home settings network boot → Full refresh row → Home refresh boot | X4s |
| `full_refresh_network_restart_and_sleep` | active worker drained on ordinary restart; request survives a sleep-sync boot and completes | X4s |
| `full_refresh_marker_io_is_not_crash` | repeated marker I/O failures keep the request/catalog; restored storage resumes | X4s |
| `full_refresh_large_catalog` | 3,000-book full catalog with modeled flash-stack constraint | X4 Pro |
| `copy_refresh_sleep_sync` | X6 | all |
| `copy_refresh_tight_heap` | X6, shared-session heap floors | X4s |
| `heap_floor_waits` | X3 | X4s |
| `next_cover_heap_floor` | X9 | X4s |
| `eob_page_finish` | X7, finish queue | all |
| `eob_series_home_swipe` | X7, series card and Home swipe | X4 Pro |
| `sleep_sync_power_wake` | X1 | X4s |
| `sleep_sync_budget` | X2 (~255 s) | X4 Pro |
| `home_tile_refresh` | X8, Home sync tile | X4 Classic |
| `offline_sleep_sync` | offline | X4s |
| `sleep_sync_device_heap` | X3, X6, TLS in PSRAM | X4s |
| `sleep_sync_quick_wake` | X1, wake-press timing | X4s |
| `home_tile_touch` | X8, Home touch target | X4 Pro |
| `catalog_refresh_stamp` | catalog refresh stamp (screenshot) | X4 Pro |
| `catalog_cache_first` | cache-first catalog | X4 Pro |
| `menu_home_swipe` | menu Home swipe | X4 Pro |

### Offline catalog paging regression

`offline_cached_list_no_loading` (X4 Pro) saves 245 synthetic books through an ordinary
Home refresh, using its real 100-row write-through replies, with no bulk generation.
It removes saved Wi-Fi credentials and makes 64 forward/backward swipes through the
saved list with compact rows; `home_refresh_completion_stamp` also checks the default
sectioned layout. Every swipe must complete, including the actual simulator list paint, in
less than 250 ms; no blocking catalog paint, HTTP request or Wi-Fi join is allowed
once the listing opens. The simulator logs blocking paints directly from `render()`,
so a transient Loading screen cannot hide between screenshots.

The session-list cache previously missed these refreshed sources and caused the
browser to paint Loading before the catalog client consulted the write-through cache.
At CrossInk `87e2e1984481e8a3d996f12b34b50a383f9013b8`, the session-only probe is
[`src/activities/browser/BookOrbitCatalogListCache.cpp:223`](https://github.com/agosez/CrossInk-Bookorbit/blob/87e2e1984481e8a3d996f12b34b50a383f9013b8/src/activities/browser/BookOrbitCatalogListCache.cpp#L223)
and the premature Loading call is
[`src/activities/browser/BookOrbitCatalogBrowserActivity.cpp:931`](https://github.com/agosez/CrossInk-Bookorbit/blob/87e2e1984481e8a3d996f12b34b50a383f9013b8/src/activities/browser/BookOrbitCatalogBrowserActivity.cpp#L931).
Patch 0059 makes the list-cache probe use that client's SD adapters with network access
explicitly disabled. The existing two-page row window stays bounded. X4 Classic uses
the same cache path; X3 has no BookSync offline mirror. Hardware SD latency and e-ink
refresh duration still need a real-reader check.

# BookSync on jailbroken Kindle: 0.13 study

**Status: proposed, NEEDS APPROVAL.** Research date: 2026-11-27.
Documentation only: no implementation, mockup approval, device operation, release,
Amazon firmware change or support promise. Merging this study does not move it to building.

## 1. Recommendation and scope

Start with **Paperwhite 3 (2015) and Voyage (2014)**, subject to which readers the
maintainer actually owns. Add Paperwhite 2 as the 256 MiB pressure target; Paperwhite 4
is a useful later hard-float target. If only Keyboard/Kindle 4 readers are available,
re-estimate before promising support: button-only navigation, ARMv6 and RAM change the scope.
Keep current KOReader, its local books, dictionaries, annotations, statistics, settings,
sidecars and reading position. Do not replace the reader engine or Amazon firmware.

Recommend a **KOReader-scoped Linux ARM companion daemon**, reusing the server-neutral
C++ services from booksync-firmware behind a POSIX platform layer. The Lua UI continues
to call only Library. All BookOrbit requests, routes, auth and wire normalization live
in the daemon's server adapter; Grimmory remains a future adapter, never a UI fork.
The daemon is required, with an exact product-version handshake; no heavy Lua fallback.

The Android/X4 Pro/X4/X3 plans continue unchanged. Kindle is a third platform family,
not another Xteink board. This proposal ships nothing, so it does not add a shipped cell
to `shared/features.json` or regenerate FEATURES. Implementation must add a truthful
Kindle capability column while retaining all four existing cells and their reasons.
No child/friend reader data or existing reader feature may be sacrificed to make a port fit.

## 2. Evidence and confidence

Read BookSync `origin/feature/0.12` at `e80a7425` (study baseline), including
[FEATURES](../../FEATURES.md), [Home](../booksync-home/DESIGN.md),
[backend independence](../backend-independence.md), [security](../security.md),
[INTERFACE](../../../android/docs/INTERFACE.md), [firmware plan](../booksync-firmware/PLAN.md)
and [release signing](../release-signing.md). Source references below use that baseline;
implementation must re-audit the final 0.12 state. Some opening paragraphs of INTERFACE
and server-contract describe historical ownership; the current code and later cutover
sections establish companion-owned sync, not a new Lua server client.

Upstream source pins from `tools/upstreams.lock` (not changed by this study):

- KOReader `9192014d8bd82a91dc1012473be0f238dedfdb54` (v2026.07.1), abbreviated K.
- BookOrbit `c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7` (v3.9.0), abbreviated B.
- Legacy CrossInk-Bookorbit `87e2e1984481e8a3d996f12b34b50a383f9013b8`, abbreviated X.

The main repo's firmware gitlink is `83740f9197cf833325fc090b464c274b34b51474`.
It is the foundation, **not all planned services**. Read-only inspection also covered
firmware slice commits `272c6ff3f24d0824d892805f33bdb9f836e684be` (F17) and
`5c5f30ff491b593c984307a87182a7e133ae5ea5` (F15). Those are evidence for reuse,
not authorization to integrate unmerged branches or a claim that 0.12 is complete:

| Evidence | Consequence |
|---|---|
| [F17 `services/SyncOwner.h:19`](https://github.com/Fledgewing/booksync-firmware/blob/272c6ff3f24d0824d892805f33bdb9f836e684be/src/booksync/services/SyncOwner.h#L19), [host CMake:1](https://github.com/Fledgewing/booksync-firmware/blob/272c6ff3f24d0824d892805f33bdb9f836e684be/test/host/sync_owner/CMakeLists.txt#L1) | Worker-only single owner, caller-supplied scratch, step per phase; the actual services compile natively in host tests. This is not a ready Linux daemon. |
| [F17 `storage/FilePublish.h:4`](https://github.com/Fledgewing/booksync-firmware/blob/272c6ff3f24d0824d892805f33bdb9f836e684be/src/booksync/storage/FilePublish.h#L4), [`.cpp:17`](https://github.com/Fledgewing/booksync-firmware/blob/272c6ff3f24d0824d892805f33bdb9f836e684be/src/booksync/storage/FilePublish.cpp#L17) | HAL/FsFile dependency remains; simulator directory fsync is useful evidence, not a production POSIX abstraction. |
| [F15 `services/ReadModel.h:7`](https://github.com/Fledgewing/booksync-firmware/blob/5c5f30ff491b593c984307a87182a7e133ae5ea5/src/booksync/services/ReadModel.h#L7) | Bounded windows and publication epochs are reusable; Linux IPC serialization and Android projection parity still need work. |
| [F15 `server/bookorbit/Auth.h:14`](https://github.com/Fledgewing/booksync-firmware/blob/5c5f30ff491b593c984307a87182a7e133ae5ea5/src/booksync/server/bookorbit/Auth.h#L14) | AuthTransport is an injectable private seam; it does not implement a Kindle HTTP transport/vault. |

External research is read-only. [KOReader's current Kindle installation guide](https://github.com/koreader/koreader/wiki/Installation-on-Kindle-devices)
confirms modern and legacy launcher paths; its general compatibility statement is not
BookSync acceptance. The dated jailbreak matrix below comes from the live
[model database](https://kindlemodding.org/models.json),
[jailbreak rules](https://kindlemodding.org/jailbreaks.json) and
[wizard logic](https://kindlemodding.org/jailbreakFinder.js), retrieved directly over HTTPS.
These are mutable and can disagree with guide prose; verify again for the exact device.
**Unverified** always means no device evidence, not a license to assume success.

## 3. Device matrix

RAM/CPU/storage below are **planning specifications, unverified per physical variant**;
Amazon does not publish a complete CPU/RAM matrix. Do not buy hardware or freeze a
minimum from these values. Screen/input capabilities are corroborated by K
[`frontend/device/kindle/device.lua:916`](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/device/kindle/device.lua#L916)
through the model declarations. Confirm free storage and available RAM separately;
nominal flash includes OS space. All screens here are grayscale E Ink.

| Model / year | CPU class / RAM / nominal storage (planning, unverified) | Screen; input; frontlight | Wi-Fi; firmware / jailbreak eligibility | Proposed tier |
|---|---|---|---|---|
| Kindle 1, 2007 | ARM9 ~400 MHz / 64 MiB / 256 MB | 6 in 600×800; keyboard/wheel; no light | No Wi-Fi; 1.2.1 historical jailbreak | Exclude: no current KOReader model implementation verified and no normal network path |
| Kindle 2 / DX / DX Graphite, 2009–10 | ARM11 ~532 MHz / 128 MiB / 2 or 4 GB | 6 in 600×800 / DX 9.7 in 824×1200; keyboard/buttons; no light | No Wi-Fi; 2.x through 2.5.8, legacy K2/DX installer | KOReader legacy exists; BookSync deferred, no usable built-in Wi-Fi |
| Keyboard / K3, 2010 | ARM11 ~532 MHz / 256 MiB / 4 GB | 6 in 600×800, 167 ppi; keyboard/5-way/page buttons; no light | 2.4 GHz b/g; 3.x through 3.4.3, legacy K3 installer | Later ARMv6/button target |
| Kindle 4 / black Kindle 5 non-touch, 2011–12 | ARMv7 Cortex-A8 ~800 MHz / 256 MiB / 2 GB | 6 in 600×800, 167 ppi; 5-way/page buttons; no light | 2.4 GHz b/g/n; 4.x through 4.1.4, diagnostics K4 jailbreak | Later button target |
| Touch / KT, 2011 | ARMv7 Cortex-A8 ~800 MHz / 256 MiB / 4 GB | 6 in 600×800, 167 ppi; touch/Home key; no light | 2.4 GHz b/g/n; 5.0.x–5.3.7.3, legacy K5 method | Later low-RAM touch target |
| Paperwhite 1 / PW, 2012 | ARMv7 Cortex-A8 ~800 MHz / 256 MiB / 2 GB | 6 in 758×1024, 212 ppi; touch; white light | 2.4 GHz b/g/n; legacy ≤5.4.4.2, or WB/WB2 at 5.6.1.1 | Later; oldest TLS/kernel risk |
| Paperwhite 2, 2013 | ARMv7 Cortex-A9 ~1 GHz / 256 MiB / 2 or 4 GB | 6 in 758×1024, 212 ppi; touch; white light | 2.4 GHz b/g/n; 5.4.x–5.12.2.2; legacy low firmware, WB/WB2 ≥5.6.1.1 | First extension / RAM gate |
| Basic 2014 / KT2 | ARMv7 Cortex-A9 ~1 GHz / 512 MiB / 4 GB | 6 in 600×800, 167 ppi; touch; no light | 2.4 GHz b/g/n; WB/WB2 5.6.1.1–5.12.2.2 | Later small-screen/no-light profile |
| Voyage / KV, 2014 | ARMv7 Cortex-A9 ~1 GHz / 512 MiB / 4 GB | 6 in 1072×1448, 300 ppi; touch + pressure page sensors; white light | 2.4 GHz b/g/n; WB/WB2 5.6.1.1–5.13.6 | First, alongside PW3 |
| Paperwhite 3, 2015 | ARMv7 Cortex-A9 ~1 GHz / 512 MiB / 4 GB (32 GB variant) | 6 in 1072×1448, 300 ppi; touch; white light | 2.4 GHz b/g/n; WB/WB2 5.6.1.1–5.16.2.1.1 | First default |
| Basic 2016 / KT3; Oasis 1, 2016 | ARMv7 Cortex-A9 ~1 GHz / 512 MiB / 4 GB | Basic 6 in 600×800/no light; Oasis 6 in 1072×1448/light; touch, Oasis page buttons | 2.4 GHz b/g/n; WB/WB2 from shipping 5.8.0 / 5.7.1.1 through 5.16.2.1.1 | Later input variants |
| Oasis 2, 2017 | ARMv7 i.MX7 dual-core ~1 GHz / 512 MiB / 8 or 32 GB | 7 in 1264×1680, 300 ppi; touch/page buttons; white light | 2.4 GHz b/g/n; WB/WB2 5.9.0.6–5.16.2.1.1 | Later 7 in/button profile |
| Paperwhite 4, 2018; Basic 2019 / KT4 | ARMv7 ~1 GHz / 512 MiB / PW 8 or 32 GB, Basic 4 or 8 GB | PW 6 in 1072×1448; Basic 6 in 600×800; touch; white light | 2.4 GHz b/g/n; WB/WB2 on older versions; SpiderCat ≥5.16.3–5.19.5 (only versions actually issued for model); see method table | Later hard-float test target |
| Oasis 3, 2019 | ARMv7 i.MX7 dual-core ~1 GHz / 512 MiB / 8 or 32 GB | 7 in 1264×1680; touch/page buttons; warm + white light | 2.4 GHz b/g/n; WB/WB2 older versions; SpiderCat 5.16.3–5.18.2 model ceiling in database | Later warmth/buttons |
| PW5 2021; Basic 2022 / KT5 | ARMv7 ~1 GHz / 512 MiB / PW 8–32 GB, Basic 16 GB | PW 6.8 in 1236×1648 warm light; Basic 6 in 1072×1448 white light; touch | Dual-band Wi-Fi; WB/WB2 on older versions, SpiderCat/Véra on newer; see below | Outside initial old-device scope |

Matrix firmware ceilings are the database snapshot, not a recommendation to update.
A method's numeric envelope does not establish that every intermediate version exists
or that a factory-only build has an exploit offset. Model nicknames are easy to confuse:
Kindle 5 non-touch is K4-family, while KT5 means the 2022 Basic.

### Methods by range, as researched today

| Method | Model/range and constraints | Source / handling |
|---|---|---|
| Legacy K2/DX/K3 installer; K4 diagnostics; K5 Touch | K2/DX 2.x, K3 3.x; K4 4.x; Touch 5.0.x–5.3.7.3. No Amazon registration required in current rules. | [K2/DX/K3 guide](https://kindlemodding.org/jailbreaking/Legacy/K2DXDXGK3-Jailbreak/), [K4 guide](https://kindlemodding.org/jailbreaking/Legacy/K4-Jailbreak/), [K5 guide](https://kindlemodding.org/jailbreaking/Legacy/K5-Jailbreak/) |
| Legacy touch jailbreak | Touch/PW-era ≤5.4.4.2; model-specific packages and bridge. Intermediate pre-5.6.1.1 models require exact legacy guide; not a universal safe downgrade. | [Legacy index](https://www.mobileread.com/forums/showthread.php?t=320564); historical instructions require revalidation |
| WinterBreak (WB) | PW1 and later listed models, 5.6.1.1–5.18.0.2; registered device, Wi-Fi/store access; never ≥5.18.1. | [WB guide](https://kindlemodding.org/jailbreaking/WinterBreak/) |
| WinterBreak2 (WB2) | PW1/PW2/Voyage/KT2/PW3/Oasis1/KT3/Oasis2/PW4/KT4/Oasis3/PW5/KT5/Scribe; 5.6.1.1–5.16.3, explicit 5.16.5 exception in current rules; no registration. | [WB2 guide](https://kindlemodding.org/jailbreaking/WinterBreak2/); exact browser/build must match |
| SpiderCat | PW4/KT4/Oasis3 and newer listed models; hard-float firmware 5.16.3–5.19.5; no registration/ads. Not PW3/Voyage just because their versions look close. | [Maintained exploit source](https://github.com/KindleModding/SpiderCat); entry point patched at 5.19.6 |
| AdBreak | Registered, ad-enabled PW4/KT4 at 5.18.1; Oasis3/PW5/KT5 and listed newer devices 5.18.1–5.18.5.0.1. Ads and exact hardware support are prerequisites. | [AdBreak guide](https://kindlemodding.org/jailbreaking/AdBreak/); prefer current wizard over historical claims of “all Kindles” |
| Sanctuary / Nosebleed / SpringBreak | Alternatives: Sanctuary listed newer models 5.16.4–5.18.3 except 5.16.5; Nosebleed Oasis3/PW5/KT5 5.16.4–5.18.6; SpringBreak PW4/KT4 5.18.1–5.18.1.1.1 and PW5/KT5 5.18.1–5.19.2.0.1 (registration needed). | [Sanctuary](https://kindlemodding.org/jailbreaking/Sanctuary/), [Nosebleed](https://kindlemodding.org/jailbreaking/Nosebleed/), [SpringBreak](https://kindlemodding.org/jailbreaking/SpringBreak/); not initial-device dependencies |
| Véra / Shadow | Véra rules now list PW5/KT5 and newer 5.17.1–5.20.2.0.1; guide prose still discusses ≤5.19.6. **Upper-range applicability unverified** until exact model/build offsets confirmed. Shadow is for newer MTP models, 5.19.4–5.19.6, not old Kindles. | [Véra](https://kindlemodding.org/jailbreaking/Vera/), [Shadow](https://kindlemodding.org/jailbreaking/Shadow/); do not say all ≥5.18.6 are unjailbreakable |

Confirm the exact model and complete firmware string, existing jailbreak/hotfix and
launcher, KOReader version and package family, registration availability and whether
ads are enabled. These are inventory facts, not approval questions. Never ask to post a
serial, Amazon account, credentials, network address or device dump. The maintainer can
use the identification wizard privately and report only its model/method verdict.

### Amazon updates and OTA

Firmware updates patch exploit entry points, can remove custom system files/launchers,
change ABI or power/network behavior, and can strand KOReader even when the bridge
survives. Reset plus update can destroy the jailbreak. Stock reading remains available;
BookSync must never recommend a reset to repair sync. Historical warnings are in the
[legacy index](https://www.mobileread.com/forums/showthread.php?t=320564).

Before jailbreaking, stay offline/airplane mode until following the exact current guide.
The [temporary filling guide](https://kindlemodding.org/jailbreaking/prevent-auto-update/)
is a preparation technique, **not a permanent BookSync storage policy**. Current modern
jailbreaks say OTA blocking is installed automatically; complete the
[post-jailbreak steps](https://kindlemodding.org/jailbreaking/whats-next/) and verify its
status before normal Wi-Fi use. For legacy devices use the matching bridge/hotfix and
maintained OTA blocker for that firmware. A folder named `update.bin.tmp.partial` alone
is not reliable on newer firmware. Router blocking can supplement, not prove, protection.
BookSync will not alter Amazon OTA services, install a jailbreak, downgrade firmware or
bundle a blocker. A changed firmware requires renewed compatibility acceptance.

## 4. What the companion owns, and the Kindle mapping

Paths in this table are under `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/`.
They are source evidence, not Kotlin code to run on Kindle. INTERFACE's Android
ContentProvider, JNI, UID/certificate checks, activities, wake locks and click channel
cannot be transplanted as-is.

| Android jobs / code read | Kindle design |
|---|---|
| `Worker.kt:20`, `LibraryReadModel.kt`, `LibraryFacets.kt`, `server/bookorbit/BookOrbitProjection.kt` | Daemon queue and neutral projections; port filters/counts/grouping/series/search and each operation's semantics, not just the C++ type names. UI gets bounded immutable windows. |
| `SyncOwner.kt:8`, `LifecycleQueue.kt:5` | One process and durable account/adapter-scoped journal owns match → stats → annotations/bookmarks → state → progress, position overrides/declines, unknown outcomes and retirement. Capture locators promptly, acknowledge only after durable commit. Reuse C++ owner/journal where equivalent; Android fixtures define parity. |
| `server/bookorbit/CacheStore.kt`, `server/bookorbit/CopiesLogic.kt`, catalog refresh/copy/finish commands | SQLite companion catalog with sole daemon writer, read-only bounded plugin snapshots; durable ledger/outboxes separated from rebuildable cache. C++ flat index is an internal alternative, not already an Android DB implementation. File identity, finish/Undo, copy replacement and generation recovery must be added to parity audit. |
| `server/bookorbit/AdapterWorker.kt:184` and download jobs exposed by Library | Streaming HTTPS to same-volume partial file, resume only for matching revision, size/digest/free-space admission, atomic rename and cancellation. Never replace an open book. Preserve sidecars and unresolved edition matches. No shell URL interpolation. |
| `server/bookorbit/BookOrbitCovers.kt`, `SleepPoolBuilder.kt`, `StorageLogic.kt` | Daemon ETag/cache/eviction and bounded image conversion; publish local references. Low-res grayscale thumbnails first, one decoder job at a time. Preserve protected books/history; cached-only sleep picture and post-paint cover batches of four. |
| `LibraryAccount.kt`, `AccountVault.kt:23`, `server/bookorbit/ServerCredentials.kt`, `server/bookorbit/BookOrbitAccount.kt:14` | Separate optional account/sync/acquisition slots, provenance and sign-out behavior. Local vault design below replaces Android Keystore. No password/key in snapshots, command line, logs or catalog DB. |
| `PersonalReading.kt`, `DevicePersonalReading.kt`, `ReadingStats.kt`, `StatsStore.kt`, `NextStop.kt`, `LocalDecor.kt` | Daemon reads KOReader statistics/sidecars using stable snapshots, aggregates/deduplicates and labels local/account coverage. Port all retained providers: highlights, anniversaries, vocabulary, buddy, recommendations, daily picks, calendar, progress geometry and battery history. Never scan on paint. |
| `OrbitService.kt`, `Core.kt`, `VpnConnectGate.kt`, `Reading.kt:19`, `Attention.kt` | KOReader owns hardware and foreground events through Library device services; daemon tracks reading/view/account epochs, bounded network leases and deadlines. No independent display, notification or restart path. |
| `Battery.kt`, battery logic and device settings | Sample native battery/charging scalars; daemon computes measured drain and uncertainty. Recalibrate per Kindle battery; do not import Android rate coefficients. Light and warmth only if native capability exists. |
| `Updater.kt`, `AndroidReleaseFeed.kt`, `PatchInstaller.kt` | Signed paired plugin+daemon installation; no APK, PackageManager or Android installer. Stage during idle, activate after KOReader exits; preserve data and rollback binaries as a pair. |
| `CommandProvider.kt`, `CallerTrust.kt`, settings sync, PIN, setup/status/report/diagnostics | Local IPC trust/limits, neutral settings and local diagnostics; UI stays in KOReader. Retain Settings PIN as a convenience gate, not root security. No Android launch intents or shared launcher apps page. |
| Add-on helpers, accessibility clicks, device-admin lock, companion activities/launcher | **Not needed on Kindle.** No Full/Add-on selector. Native keys, navigation and sleep use KOReader. Keep any applicable reader setting and escape route; Android permissions screens are inapplicable, not missing reading features. |

### Credential storage without Android Keystore

A jailbroken Kindle has no equivalent hardware-backed app sandbox. FAT-visible USB
storage cannot enforce Unix permission bits. Proposed vault: encrypted authenticated
records in BookSync-owned storage, key in a private non-exported filesystem directory
with mode 0700 and files 0600, created via a narrowly scoped installer operation.
Verify mount type, permissions and USB invisibility on each accepted firmware; exact
private location is **unverified**. Bind records to slot/origin/account using AAD, use
OS CSPRNG, atomic save and secret redaction. Do not derive a key from a serial or disguise
an adjacent file as secure encryption. Same-device root compromise can recover the key;
state this limitation plainly.

If no private key location can be validated, use memory-only credentials or a
passphrase-unlocked vault; do not silently save plaintext on the USB volume. Passphrase
mode prevents unattended sync after cold boot until unlocked. Export excludes secrets;
sign-out retires credentials, never deletes pending reading events. Account switch
isolates old queues and preserves them for explicit recovery. This threat-model choice
needs approval before any persistent-secret implementation (§10).

## 5. Architecture and lifecycle

| Option | Assessment |
|---|---|
| **A. C++ service port + Linux daemon (recommended)** | Shared firmware policy/journal/read-model work, small native runtime, real process isolation from UI; POSIX port and Lua IPC compatibility cost. GPL C++ code remains GPL; daemon distribution includes corresponding source/build recipe/licenses. AGPL plugin remains AGPL. Do not relabel firmware reuse MIT. |
| B. Companion inside KOReader, Lua + subprocesses | Pure Lua UI/model helpers reuse well. In-process networking, parsing and scans violate the free-UI-thread rule. A long-lived Lua subprocess with its own storage/network worker could satisfy it, but becomes another companion implementation and duplicates firmware policy. One subprocess per query/paint is rejected. |
| C. Portable Kotlin/JVM, Kotlin/Native, or remote helper | JVM brings runtime/RAM/old-ABI cost; Android APIs still need replacement. Kotlin/Native old ARM/kernel support is unverified. An optional BookSync server or LAN gateway can reduce local work, but must keep local capture/offline journals and direct mode; cannot become mandatory without a separate approval. A Rust rewrite offers no demonstrated advantage over existing host-tested C++. |

### Port boundaries

Build services only, not ESP display, FreeRTOS scheduler, Arduino HTTP or native reader.
Introduce POSIX storage handles, directory iteration, atomic publication, locks and
barriers; network TLS/HTTP/streaming with cancellation; monotonic deadlines and wall-clock
capture; worker executor and entropy. Use an actively maintained TLS/HTTP library built
for the actual ABI/kernel with CA verification, bounded redirects and no credential
forwarding across origins. Old system TLS/cert stores are not assumed usable. Never
set insecure TLS as the compatibility solution.

Host stubs prove compilation/testability, not POSIX correctness. Port `FilePublish`'s
failure semantics, fsync files and parent directories, reconcile uncertain publication,
handle short writes/EINTR, no-space/read-only media and mount loss. FAT durability needs
power-cut tests; ext filesystem assumptions must not leak onto the USB-visible volume.
Use a process lock in addition to C++'s process-local single-owner guard.

Native captures preserve KOReader XPointers/page locators and file revisions; do not
convert them to firmware locators. Match/stats/annotation/state/progress adapter services
need an explicit equivalence checklist against Android. C++ numeric identity fields must
not freeze backend-neutral opaque IDs into BookOrbit integer IDs; extend internal mapping
before adding Grimmory. This is a port, not an assertion of current feature completeness.

### IPC behind Library

Replace Android transport under Library with a Unix-domain socket in the private runtime
directory (never a world-writable socket on FAT or network listener). Versioned framed
messages, hard lengths, request IDs, protocol/product versions, capabilities, account epoch,
view ticket, deadlines and idempotency tokens. Owner/path validation rejects symlinks,
traversal, arbitrary writes and commands outside the fixed allowlist. Verify peer credentials
where the kernel supports them; same-root jailbreak apps cannot be isolated by UID alone.

UI invokes only Library; private transport services serialize requests and publish
ready snapshots. Preserve existing budgets: one batch/Home paint, ≤24 displayed catalog
rows, ≤16 KiB/widget, ≤16 requests/128 KiB request batch, four-cover completion windows.
Paint uses ready local data and never waits on daemon work or launches a subprocess.
Use nonblocking socket integration in KOReader's loop; bounded cache reads may be retained
where already permitted. Durable enqueue completion differs from transport acceptance:
reader intent is not acknowledged until persisted, including while reading. A killed daemon
leaves cached reading usable and retries from durable checkpoints; no second sync writer.

### Toolchain and resource gates

[KOReader's koxtoolchain](https://github.com/koreader/koxtoolchain#notes) distinguishes:
`kindle` → kindle-legacy (K2/DX/K3), `kindle5` → kindle (K4/Touch/PW1),
`kindlepw2` → PW2 and later soft-float, `kindlehf` → firmware ≥5.16.3 hard-float.
K `device.lua:593` selects these OTA families. Pin the cross-toolchain/sysroot and libc
symbol floor per family; do not use the desktop Linux or generic modern ARM binary.
Begin with kindlepw2; hard-float and ARMv6 are separate acceptance/build profiles.
Linux CI/container builds and QEMU user-mode loader tests precede physical tests; QEMU
on a modern host does not validate an old Kindle kernel.

**Proposed budgets, not measurements:** daemon stripped ≤12 MiB including private shared
libraries, installation pair ≤30 MiB excluding KOReader/caches; idle RSS ≤8 MiB, active
RSS ≤24 MiB excluding KOReader and any Tailnet process; one network/cover worker at a time.
On 256 MiB devices target active RSS ≤16 MiB or reduce concurrency and re-measure.
Reserve at least two update bundles plus journal growth and download staging before accepting
an install; never evict unacknowledged events to meet a quota. Measure p95/p99 RSS and Home
latency with a large EPUB open, 10k catalog and long history. Initial screen targets inherit
Home <500 ms/widget <50 ms as proposals; do not claim them from host tests. OOM must not
kill KOReader. Tailnet memory is additional and presently unverified.

### Start, stop, suspend and Wi-Fi

Start through a BookSync wrapper around the supported KOReader launcher: KUAL extension
on old devices, current scriptlet/KPM path where supported. Keep the stock KOReader launch
and Amazon reader escape. Daemon runs only for the KOReader session, with supervisor/PID
lock, bounded crash backoff and stale-socket recovery. On normal exit checkpoint, cancel
transfers, release network leases and stop daemon; on crash, lease expiry/orphan detection
must stop work. No boot init scripts or always-on polling in the first version. Always-on
would consume battery and continue after KOReader exits; defer until separately justified.

K [`device.lua:424`](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/device/kindle/device.lua#L424)
binds NetworkMgr's Wi-Fi on/off/reconnect and profile operations. K
[`device.lua:845`](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/device/kindle/device.lua#L845)
handles ReadyToSuspend; K
[`powerd.lua:323`](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/device/kindle/powerd.lua#L323)
emits Suspend/Resume through native device hooks. Use those services, not Android broadcasts
or an independent daemon Wi-Fi controller. Observe actual connected/disconnected state;
Wi-Fi enabled is not a usable route. Preserve manual Wi-Fi ownership and restore only a
lease BookSync acquired.

Capture/journal first; opportunistic sync on open/close/wake, explicit Sync and idle.
At suspend, best-effort bounded drain (10/15/20 s policy), with monotonic deadline and
cancellation; no promise that a Suspend callback can postpone physical sleep for 20 s.
ReadyToSuspend timing, powerd inhibition and hibernation behavior require model tests.
If no safe bounded hold is available, retain pending work for wake rather than defeat sleep.
Never wait synchronously in Lua. Release hold/route on every failure; prevent wake loops.
Sleeping CPUs do not run the daemon, timers or network. Resume revalidates clock, route,
TLS and account epoch. No spontaneous Wi-Fi-on, screensaver change, popup or restart
while foreground reading; retain only the already-approved position prompt exception.
Battery/charging and light scalars use K `powerd.lua:84,137,174,180,198` through Library;
no-light/no-warmth capability returns unavailable, not a dummy slider.

### Tailscale feasibility

[Userspace networking](https://tailscale.com/kb/1112/userspace-networking) removes the TUN
requirement and exposes an application proxy; it does **not** remove Go runtime/kernel
requirements. [Go's Linux support table](https://go.dev/wiki/Linux) requires Linux ≥3.2
for current Go; ARM's old ≥3.1 support ended at Go 1.23.12. Old Kindle kernels may be 2.6.x
or 3.0.x (**actual per-model kernels unverified**). An ARM download or static link therefore
does not prove current tailscaled works. A TUN device/module also cannot repair a syscall
ABI mismatch. Never ship an abandoned Go/Tailscale merely because it starts.

After approval, first test supported userspace tailscaled on the actual accepted kernel.
Adapter HTTP uses an explicit local SOCKS5/HTTP CONNECT proxy, remote DNS resolution,
TLS origin verification and no direct fallback when Tailnet is required. Do not set a
process-wide proxy for Amazon/KOReader traffic. Bind locally, protect control socket and
node keys, redact pairing material; use scoped device access. Revalidate reconnect, DERP,
DNS, time/expiry, sleep and revocation. Do not promise on-device pairing before these pass.

For old kernels the recommended initial fallback is an **existing LAN Tailscale subnet
router/gateway**, so the Kindle uses ordinary Wi-Fi/TLS while the gateway reaches the server.
No public-server exposure or TLS downgrade is required. This changes deployment topology,
not auth rights. Reusing MicroLink would require removing ESP/lwIP/FreeRTOS coupling and
security review; not an already proven POSIX option. Native current Tailscale feasibility,
RSS and old-kernel support remain a release blocker if on-device Tailnet is mandatory.

## 6. Auth verdict and operation coverage

**The premise that BookSync's Android path requires App Attest is not supported by the
pinned code.** BookOrbit's official mobile routes can require it; BookSync never produces
or forges it. Android's `server/bookorbit/BookOrbitAccount.kt:50,86,197` uses native account
login plus a deliberate allowlist, while sync/acquisition credentials stay independent.
See [server-contract: App attestation](../../server-contract.md#app-attestation).

Legacy X authentication sends `x-auth-user` and `x-auth-key` using a **separate KOReader
sync login**, with the legacy MD5-derived password key, not the web-account password.
X [`lib/BookOrbitSync/BookOrbitSyncClient.cpp:473`](https://github.com/agosez/CrossInk-Bookorbit/blob/87e2e1984481e8a3d996f12b34b50a383f9013b8/lib/BookOrbitSync/BookOrbitSyncClient.cpp#L473)
and [`:604`](https://github.com/agosez/CrossInk-Bookorbit/blob/87e2e1984481e8a3d996f12b34b50a383f9013b8/lib/BookOrbitSync/BookOrbitSyncClient.cpp#L604)
show headers and `/users/auth`. F15 `server/bookorbit/Auth.cpp:31` supports either deriving
this key or accepting an already-derived key. The derived value itself is a credential,
not secure password storage. Never log it or substitute the web password automatically.

B [`koreader-auth.guard.ts:22`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader-auth.guard.ts#L22)
checks sync enabled, secret, active account and KOReaderSync permission. Catalog/plugin
controllers apply that guard, not App Attest. Authentication does not waive per-operation
permissions, file visibility, edition compatibility or validation.

| Required operation | Legacy sync login verdict at B | Evidence / gap |
|---|---|---|
| Validate sync login; pull/push position | Covered | [`koreader.controller.ts:55–76`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader.controller.ts#L55); bulk plugin progress also available |
| Match, page stats, annotations/exchange/pending/ack, bookmarks/exchange/ack, book states, progress | Covered by protocol; Kindle transport/locators still need parity tests | [`koreader-plugin.controller.ts:29–92`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader-plugin.controller.ts#L29) |
| Catalog/root/dashboard/sections, books/manifest/detail/series, thumbnails, file download, read status/rating | Covered by protocol, subject to library rights | [`koreader-catalog.controller.ts:24–112`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/koreader/koreader-catalog.controller.ts#L24); bounded local projections replace server Home UI |
| OPDS acquisition and sharp covers | Independent OPDS login/token, **not covered by sync credentials** | [`opds.controller.ts:229`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/opds/opds.controller.ts#L229); sync-auth catalog thumbnails remain available |
| Account-wide days/hours/sessions/finishes/goals; create/provision connector; account session | **Not covered by legacy sync login alone** | Android allowlist in `BookOrbitAccount.kt:86,197`; native bearer login path requires its own port and audit. Manual connector provisioning elsewhere works for initial sync. Local stats stay available and labeled; do not silently promise account parity. |
| Official mobile endpoints, attested journals/notebooks/widgets/preferences/uploads/TTS | Unavailable when guarded; not needed to bypass for core reading | B [`app-attest.guard.ts:26`](https://github.com/bookorbit/bookorbit/blob/c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7/server/src/modules/app-attest/app-attest.guard.ts#L26); preserve unsupported local data for export/future adapters |
| Reading controls, layout, decor, updates, battery, local highlights/stats | Local Library services; no server login needed | Capability gating must preserve signed-out/offline reading |

Thus **yes for core catalog/download/reading lifecycle; no for every Android account
operation with that one login**. Account bearer and OPDS slots can close authorized gaps;
a future BookSync server can aggregate only what its own backend credentials permit.
Neither a gateway nor server mode launders App Attest rights. A 401/403 must leave local
queues intact, disable only the denied capability and never retry via another credential
kind or unofficial mobile identity. Re-run `tools/attest-check` against the release pin;
new server versions can revoke this feasibility result.

## 7. Plugin reuse and approval inventory

The shipping plugin cannot simply be copied: `ko/base.lua:16` explicitly disables it on
non-Android devices; `main.lua:35` loads JNI/companion modules and `ko/library.lua` uses
ContentResolver directly. Split platform composition before lifting that guard.

| Area | Reuse judgment |
|---|---|
| `logic/layout.lua`, widget registry/budgets, editor plans, neutral list/filter/series/presentation helpers | Strong source reuse, subject to module dependency audit and button fixtures. No backend calls added. |
| `ko/home_host.lua`, `home_widgets.lua`, `home_editor.lua`, book lists, series, detail/actions, menus, reader panels, end sheet | Retain UI/data contract and native KOReader widgets; mostly shared presentation is plausible. **Unverified unchanged-module percentage**: no Kindle render or load test has run. |
| Library services, runtime/start/lifecycle, account command/result dispatch, Store/DB, cover references | Retain public semantics; replace JNI paths, Android directories, status/activity/relaunch transport and private file assumptions underneath. |
| Android Home key, launcher, helpers, package/signature checks, click accessibility, screensaver sinks and updates | Platform replacement or inapplicable capability. Kindle uses native key maps, sleep and launcher behavior; do not remove stock reader functions. |

No fixed Android pixel grid. Use KOReader DPI/geometry/font metrics and grayscale refresh;
600×800 at 167 ppi must remain legible alongside 212/300 ppi, landscape and 7 in profiles.
Voyage sensors/Oasis page buttons are not a 5-way controller. Preserve page turns in a book;
UI focus traversal/Select/Back must be explicit on Keyboard/K4, with visible focus and
hardware text input. No drag/long-press-only essential action. Touch editor may share
geometry, while button move/resize/page naming needs approved alternatives. No-light and
no-warmth widgets must accurately report capability without breaking saved layouts.

**Kindle mockups needed before building affected UI** (inventory only, none approved here):

1. Default Home and Stats pages, every retained widget (including empty/offline/unsupported),
   compact 600×800 and PW/Voyage 300 ppi; long titles, large fonts, grayscale covers, portrait/landscape.
2. Home editor: add/remove/move/resize, pages/name/reorder/reset/Done/Cancel; touch and
   5-way/keyboard focus sequence, including a non-drag move mode if button support is chosen.
3. Library/search, source/filter/facet pickers, grouped lists, detail/actions, series,
   download-next/progress/cancel, copy/finish/Undo and end-of-book sheet.
4. Three independent login slots, unavailable account features, private-vault unlock,
   sign-out/origin/queued-data recovery and pairing/gateway status if exposed.
5. Settings/reading presets/Custom/Undo, battery estimates/unknown state, no-light/light/warmth,
   sync/power controls, diagnostics and stock KOReader/Amazon escape.
6. Reader panels, position consent, hardware-key paths, cached sleep screen and wake/error states.
7. Initial setup, missing/wrong companion, signed update deferred/install/recovery/withdrawal,
   storage-full and persistent crash summary, without unsolicited reading interruptions.

Existing Android approval does not approve Kindle-specific flows. Retain widget/data
capability coverage; missing backend features need explicit labels and maintainer-approved
deferral, not disappearance of reading history. Mockups are a later design deliverable.

## 8. Updates, trust and recovery

Extend the [existing Ed25519 root → release-key certificate → artifact signature](../release-signing.md)
chain. Keep its existing domain strings and serial revocation semantics; do not invent an
unsigned Kindle exception. Proposed assets: a Kindle bundle per ABI containing stamped
plugin, daemon, dependency manifest/licenses and compatibility manifest, signed as one
artifact. The manifest binds product version, ABI/firmware family, protocol and hashes;
outer signature binds immutable release tag, exact asset name and digest. Preserve stable,
RC and preview ordering and withdrawal/recovery policy. No tags/releases/workflows are
created by this study; feed path/schema and unified-release integration are future work.

Pin root public key/minimum serial in installer/updater; first installation is a manual
verified bootstrap, not trust-on-first-download. Require signatures from day one on Kindle
even if legacy enforcement defaults are permissive. Verify signed feed **and** artifact,
HTTPS/origin restrictions, length/hash, key certificate/revocation, version and ABI before
unpacking. SHA256SUMS alone is not authenticity. Reject traversal, symlinks, special files,
extra executable paths, decompression bombs and insufficient staging space.

Stage versioned directories with a small installer separate from the daemon being replaced.
While nobody is reading, exit KOReader normally, stop worker, atomically select the complete
pair, restart only through the chosen launcher, then validate handshake/local open/capture.
Keep prior binaries and a durable activation journal. Never mix plugin and daemon versions;
never update KOReader, jailbreak or Amazon firmware as a side effect. Activation cannot
rewrite user data destructively; version storage, preserve unknown records, back up before
migration and support old-binary return or forward recovery without discarding newer queues.
A failed validation restores the pair with compatible data; incompatible downgrade refuses
activation rather than resetting the library. Offline manual recovery must remain possible.

Use existing signing tools and shared version source; build jobs have no signing secrets,
separate publication job signs/verifies completed artifacts. New Kindle tests must join
emulated release gates; maintainer device acceptance precedes any release. This docs PR
publishes nothing and never calls sideload tools.

## 9. Phases, estimates and acceptance

Estimates are **worker-days**, one focused engineer-day, not elapsed time or approved work.
Assume mature merged 0.12 services and two available touch devices; ranges include tests
and review, exclude waiting for approvals/device availability. No code experiments run here.

| Slice | Outcome / dependency | Days |
|---|---|---:|
| K0 | Inventory exact devices/firmware; auth operation/permission audit with synthetic fixtures; choose support floor | 2–3 |
| K1 | Mockup set, source/module portability audit, data/secret threat model approval | 3–5 |
| K2 | Pinned kindlepw2 toolchain/loader/TLS and size/RAM proof; host build only until approval | 3–5 |
| K3 | POSIX storage, fsync/recovery/locks, journal/index and crash/full-disk tests | 4–6 |
| K4 | Daemon supervisor, framed IPC, version/capability handshake and bounded Lua Library transport | 4–6 |
| K5 | KOReader captures, single-owner lifecycle/position policy, five-phase adapter parity and sidecar/stat preservation | 5–8 |
| K6 | Catalog generations/queries/grouping/series/settings/layout, copies and finish/Undo | 4–6 |
| K7 | Downloads/identity/revision/covers/eviction with fault cases | 3–5 |
| K8 | Vault/manual sync + OPDS auth; optional native account allowlist/statistics port | 3–5 |
| K9 | Native Wi-Fi/suspend/reading gate, battery/light and sleep presentation | 3–5 |
| K10 | Touch Home/editor/menus/provider parity and approved compact UI adjustments | 4–6 |
| K11 | Signed paired update/bootstrap/recovery/withdrawal and packaging gates | 3–5 |
| K12 | Maintainer-run PW3/Voyage acceptance, data recovery/export evidence, docs and truthful capability matrix | 3–5 |
| **Initial touch scope total** | **No native Tailnet guarantee; no button-only pledge** | **47–75** |
| K13, optional | Current tailscaled/kernel/RSS spike; stop on unsupported kernel; gateway integration | 2–4 |
| K14, optional | Native Tailnet hardening/pairing/sleep/security acceptance if spike succeeds | 4–8 |
| K15, optional | PW2 low-memory acceptance and mitigation | 2–4 |
| K16, optional | K3/K4 toolchains + button mockups/navigation + old-kernel acceptance | 7–12 |

Approve the study and mockups before K2–K16 building. K0/K1 are further design work,
not implied permission to connect devices. Shared firmware work benefits X4 Pro/X4/X3;
new generic contract/fault cases should also run on Android. Do not charge all pending
0.12 firmware implementation to a supposedly tiny Kindle wrapper; re-estimate if the
service maturity assumption fails. With native Tailnet and PW2, plan **55–91 worker-days**;
button-only scope is additional. Calendar delivery depends on device acceptance.

Acceptance evidence must include:

- Source guards: no UI/private transport/backend dependency leaks; a fake second backend
  proves neutral requests and unsupported/error behavior, including opaque identifiers.
- Protocol and storage fault tests: truncated frames, lost ACK, timeout after server commit,
  duplicate/reordered events, restart in every phase, corrupt journal tail, power loss during
  generation/update, ENOSPC/read-only/USB mount loss, malicious paths and account switches.
- Realistic synthetic library/history: 10k books, large annotations, offline open/turn/close,
  finish/Undo, edition changes, sleep mid-request and wake with expired auth; no double writes,
  no unacknowledged eviction, no stale-view redraw or unexpected reader restarts.
- Preservation comparison before/after: books, sidecars, highlights/bookmarks, dictionaries,
  fonts, native stats, settings, reading position and queued captures. Failed imports retain
  originals and report gaps. Never use a child's/friend's only data copy as a test fixture.
- Maintainer alone runs device checks: launcher/escape, suspend/hibernation, USB ownership,
  light/battery, installed ABI, OOM pressure and measured latency/RSS/idle battery drain.
  Agents never use adb, serial or jailbreak/install/sideload commands.

Principal risks: old-kernel TLS/Go incompatibility; C++ services not yet merged/feature complete;
IPC projection mismatch; FAT/private-key storage assumptions; duplicate native sync writers;
suspend interrupting durability; tiny flash/free space and aged batteries; page-button UI;
firmware updates invalidating launchers/ABI; license obligations and update rollback across
schema versions. Core reading and durable intent take priority over catalog freshness.

## 10. Maintainer decisions and next evidence

Only durable support/security/product commitments need a maintainer decision; socket codecs,
exact filenames and internal timer implementation are reversible engineering choices.

1. **Support promise:** PW3 + Voyage first, PW2 after memory validation; are K3/K4 button-only
   readers required in 0.13? Their inclusion changes ongoing test/toolchain obligations.
2. **Network dependency:** may old-kernel devices use a LAN Tailnet gateway, or must each Kindle
   pair on-device? If on-device is mandatory, unsupported current runtimes can block 0.13.
3. **Secret protection:** accept a root-readable, USB-hidden local key with documented physical/root
   limits, or require a passphrase each cold boot (and lose unattended sync until unlock)?
4. **Account coverage:** permit initial manual sync/OPDS credentials with explicitly labeled local
   stats while full native account parity follows, or require every authorized Android account
   capability before declaring Kindle supported? Never waive data retention or App Attest rules.
5. **Data/compatibility promise:** confirm the backend-independence ledger/export retention and
   paired-update recovery policy before freezing a persistent Kindle format. No automatic
   deletion or lossy migration; preserve unsupported records and original sidecars.

Separately supply inventory facts: model/year/variant, full firmware string, known kernel/ABI
if already recorded, jailbreak/hotfix/launcher and KOReader versions, available storage,
battery condition and whether Wi-Fi/gateway access exists. Do not send serials, secrets,
account identifiers or network details. Exact inventories and maintainer acceptance, not a
paper compatibility table, determine the final supported matrix.

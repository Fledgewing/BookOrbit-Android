# Full refresh crash recovery (0.11)

Bug fix for X4 Pro and X4 Classic on main. Android owns its refresh in the
companion; X3 has no bulk catalog worker or PSRAM, so neither uses this task.

## Cause and evidence

The reported firmware is `xteink-v2.0.0.562+bookorbit.1-rc3`. There is no device
log. We can prove an unsafe call path and its boot-loop mechanism; we cannot
identify the exact instruction that panicked on that reader without its log.

`RefreshRunner.cpp` allocated the `orb_catalog` task's 16 KB stack with
`MALLOC_CAP_SPIRAM`. Its `OrbifyBulk::refresh` network callback reaches the
catalog HTTP transport and Tailnet resolver. `TailnetResolver.cpp` calls
`tailnet_ensure_peer`; `Tailnet.cpp` calls `rememberServer` (changed server) or
`storePin` (unknown peer), which synchronously call NVS writes/commit on the
requesting task. These flash operations require an internal stack. ESP-IDF's
`components/spi_flash/cache_utils.c`, `esp_task_stack_is_sane_cache_disabled`,
asserts that the stack pointer is in internal DRAM before disabling the cache.
Ordinary visible-view Refresh uses the main task and avoids this worker-stack
mistake. Full refresh does not run the copy replacement queue; its only
`CopyRefresh` call reads the small library-version token.

[Espressif's external-RAM constraints](https://docs.espressif.com/projects/esp-idf/en/release-v5.5/esp32s3/api-guides/external-ram.html)
explain why PSRAM is inaccessible with the flash cache disabled. The fix uses
an internal stack with the matching task creation/deletion APIs. JSON and numeric
catalog indexes retain their separate PSRAM allocator. Failure to allocate the
stack retains the request and backs off; it does not fall back to an unsafe stack.

The ordinary SDL simulator omits Tailscale and flash-cache restrictions. A baseline
3,000-book run completed (533 requests, 187,801 bytes peak catalog PSRAM), so it
did not reproduce heap exhaustion. The added simulator model runs the synchronous
resolver flash-write constraint at the bulk transport callback. Restoring the old
external stack makes that run fail with exit 87; the internal stack passes. This
is a modeled hardware constraint, not an ESP32 CPU emulation or proof of the
maintainer's specific panic. The large-catalog emulated regression exercises the
actual worker, HTTP parsing and SD adapter with 3,000 books.

## Persistent state and breaker

`/.crosspoint/orbify/mirror.request` survives resets until Full refresh finishes.
The global worker sees it on every boot, without opening the catalog. Bulk staging
markers under `/.crosspoint/orbify-catalog/bulk/` resume the incomplete generation.
A deterministic panic was therefore retried indefinitely; a cold power cycle did
not clear it. Neither NVS nor a book's `.part` file is needed for this loop.

The generic `ResumedWork` guard writes `refresh.inflight` durably before entering
the job and clears it only on ordinary return (success, offline, low heap or
cancellation). Its temporary marker is also checked after a reset during rename;
malformed markers fail closed. After two runs never return, the next boot blocks
a third. `mirror.request.crashed` blocks automatic incremental work across later
boots too. The request and bulk stage marker (including `.bak`/`.tmp`) are removed.
Published catalog generations, books, reading state and settings remain. Only an
explicit Full refresh or credential change clears the breaker; explicit refresh
starts a fresh staging generation. A storage failure that prevents recording an
attempt prevents starting the job.

A second marker, `refresh-boot.inflight`, brackets setup while refresh state is
pending. After two incomplete setups the recovery hook runs immediately after SD
mount, before settings/catalog/activity restoration. It also quarantines the bulk
`active` pointer as `active.crashed` and removes its backup, preventing the suspect
catalog from being decoded on that boot. The generation bytes remain on SD.

Host tests cover marker writes/renames, cold-boot instances, corrupt markers and
normal pauses. The emulated release scenario injects two abrupt process exits,
boots twice with the same fault still enabled, checks no network job runs and
verifies retained bytes, then retries through the real X4 Pro Home hold gesture.

## Recover the already installed firmware

1. Power the reader off/reset it as needed, then remove the SD card. In a card
   reader, enable showing hidden files. From the **SD root**, delete only
   `/.crosspoint/orbify/mirror.request`.
2. Reinsert the card and restart. This removes the automatic Full refresh request;
   keep using ordinary Refresh and avoid Full refresh until installing a tested fix.
   Do not delete `/.crosspoint`, `bookorbit.json`, `wifi.json`, books or reading
   state, and do not erase NVS. The bulk stage files alone do not schedule work.
   If it still fails while restoring the catalog, rename only the metadata folder
   `/.crosspoint/orbify-catalog` to `/.crosspoint/orbify-catalog.recovery` on the card
   and restart. This hides all bulk pointers/backups together and preserves their
   bytes for inspection. Books and settings live elsewhere and remain intact.
3. Once booting, OTA can install a subsequently published fixed firmware through
   the normal update screen/channel. This change publishes no firmware. A test
   artifact is not offered by OTA; install a matching X4 Pro test image through
   SD firmware update or the maintainer-operated USB sideload workflow.

There is no verified button-only way to cancel the persisted request in .562, and
no guaranteed interval in which Settings/OTA can be reached before the crash.
Booting without the SD card prevents this SD-backed request from running, but is
not a repair of the card and cannot supply the SD staging required for updates.
The existing **Down + Power** power-button-wake chord opens the SD `.bin` firmware
picker, but .562 still calls the global refresh scheduler in that mode. Do not
rely on that chord alone to outrun the worker: remove the request on the card first.
Afterward, a matching `.bin` already on the card can be selected there; USB is not
required when an SD card reader is available.

Upstream recovery evidence at CrossInk commit
`87e2e1984481e8a3d996f12b34b50a383f9013b8`:
`src/main.cpp:1830-1837` selects Down on the S3 readers and requires a power-button
wake; `src/main.cpp:2128-2131` chooses `SdFirmwareUpdateActivity`;
`src/activities/settings/SdFirmwareUpdateActivity.cpp:26-30` opens the root picker
restricted to firmware. BookSync's patch 0053 adds the unconditional global
`OrbifyMirror::service()` call to `loop()`, explaining why recovery mode does not
cancel the request. These line references are for the unpatched pin; the overlay
moves the resulting source lines.

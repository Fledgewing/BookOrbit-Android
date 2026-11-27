# Factory partition layouts

OTA and SD updates replace an application, never the partition table. BookSync's overlay
selects its own CSV in `platformio.local.ini`, through the existing `tailnet/` symlink:

| Build | Devices | app0 offset / size | app1 offset / size | spiffs offset / size | coredump offset / size |
|---|---|---|---|---|---|
| `x4-pro`, `x4-classic` | S3 X4 Pro, X4 Classic | 0x10000 / 0x7e0000 | 0x7f0000 / 0x7e0000 | 0xfd0000 / 0x14000 | 0xfe4000 / 0x1c000 |
| `default` | C3 X4 (smallest supported layout) | 0x10000 / 0x640000 | 0x650000 / 0x640000 | 0xc90000 / 0x360000 | 0xff0000 / 0x10000 |
| `default` (same image) | X3 factory | 0x10000 / 0x770000 | 0x780000 / 0x770000 | 0xef0000 / 0x100000 | 0xff0000 / 0x10000 |

All have nvs at 0x9000 / 0x5000 and otadata at 0xe000 / 0x2000.
The shared C3 image deliberately uses the smaller X4 limit: growing it to the X3 limit
would strand C3 X4 readers, and readers previously installed with the generic USB table.
S3 readers previously repartitioned over USB to smaller slots still require an image that
fits those slots; the sideload tool checks the actual reader, and OTA uses the runtime table.

Evidence:

- The reported X4 Pro USB read on 2026-11-26 matches the S3 row above.
- FreeInk's X4 Classic hardware note at `24003795381a6c23630a26472ae3b06550333e71`,
  [`docs/xteink-x4c-support.md:100-103`](https://github.com/Free-Ink/freeink-sdk/blob/24003795381a6c23630a26472ae3b06550333e71/docs/xteink-x4c-support.md#L100-L103),
  records the same partition boundaries.
- CrossPoint's device flasher at `dff9a07a9b5124ca23e0b2aebd894e3b49d805dc`,
  [`src/lib/flasher.js:235-263`](https://github.com/crosspoint-reader/crosspoint-tools/blob/dff9a07a9b5124ca23e0b2aebd894e3b49d805dc/src/lib/flasher.js#L235-L263),
  records the original X4, X3 and dump-verified Pro layouts separately.

The cause was inheriting the generic upstream table on every reader. At the pinned
CrossInk-Bookorbit `0695f2e1456e2cfcaa7218027f1b3b71050a8f7b`,
[`platformio.ini:28-30,109-111`](https://github.com/agosez/CrossInk-Bookorbit/blob/0695f2e1456e2cfcaa7218027f1b3b71050a8f7b/platformio.ini#L109-L111)
selects [`partitions.csv:1-7`](https://github.com/agosez/CrossInk-Bookorbit/blob/0695f2e1456e2cfcaa7218027f1b3b71050a8f7b/partitions.csv#L1-L7)
and a 6,553,600-byte upload maximum for all three environments.

The S3 factory's 80 KiB spiffs is intentionally too small for the prepared language cache.
The existing fallback remains: at the same pinned commit,
[`lib/HalFlashPartition/HalFlashPartition.cpp:75-85`](https://github.com/agosez/CrossInk-Bookorbit/blob/0695f2e1456e2cfcaa7218027f1b3b71050a8f7b/lib/HalFlashPartition/HalFlashPartition.cpp#L75-L85)
reports the incompatible size, then
[`lib/AssetCacheStorage/AssetCacheStorage.cpp:72-87`](https://github.com/agosez/CrossInk-Bookorbit/blob/0695f2e1456e2cfcaa7218027f1b3b71050a8f7b/lib/AssetCacheStorage/AssetCacheStorage.cpp#L72-L87)
uses the SD cache with PSRAM. Neither path rewrites a partition table.

CI's 99.5% flash budget reads `firmware.bin` and the generated `partitions.bin`, using the
smaller of both OTA slots, and reports actual free bytes and headroom below the gate.
The upload maximum matches the selected CSV as well. USB sideloads require the same
nvs/otadata/app0 offsets (and unchanged nvs/otadata sizes), an image that fits app0, and
non-overlapping, sector-aligned partitions. Differences in app1 or data partitions are
allowed: the script writes only app0 and blanks otadata from the reader's own table.

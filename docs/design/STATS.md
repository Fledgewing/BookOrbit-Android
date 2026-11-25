# Battery summary format: `orbit-battery-stats/1`

This file lets e-readers compare battery use. BookSync Companion (Android) writes it from
Battery › Export and reads it on Battery › Compare. Reader firmware, such as Xteink's, can
write the same format. It is a single UTF-8 JSON object. Producers write it only when the user
asks, and it holds nothing personal: no book titles or file names, no Wi-Fi names, no
accounts and no device IDs.

## Rules (frozen for `/1`)

- `schema` must be `"orbit-battery-stats/1"`. Readers reject other values, including a `/2`
  they don't know yet.
- **Additive only.** New fields may appear in `/1`. Readers ignore fields they don't know, and
  renaming or removing a field needs `/2`.
- **Optional means optional.** Every field marked *opt* may be missing or `null`. Readers
  show "—" or leave that row out.
- **Unknown enum values are kept.** A `content`, `wifi_mode`, `battery_source` or other enum
  value a reader doesn't know is shown as is, never rejected. An unknown `state` is skipped,
  because it can't be compared.
- **Times** are ISO-8601 with an offset, e.g. `2026-11-21T07:42:10-08:00`. A device whose
  clock was never set writes `null` or `""`. Readers then show totals, without per-day
  history, and use `duration_s`.
- **Percent** is the battery level the device reports, 0–100.

## Top level

| Field | Type | Meaning |
|---|---|---|
| `schema` | string | `"orbit-battery-stats/1"` |
| `source` | string | Who wrote it: `"android-companion"`, `"crossink-firmware"`, or another name |
| `source_version` | string, opt | The writer's version |
| `generated` | time, opt | When the file was written |
| `battery_source` | string | How % is measured: `"fuel_gauge"` or `"voltage_estimate"` |
| `device` | object | `manufacturer`, `model` (strings); opt: `android_version`, `capacity_mah` (int), `capacity_source` (`"charge_counter"`, `"power_profile"`, …) |
| `period` | object, opt | `first_day`, `last_day` (`YYYY-MM-DD`, opt), `days` (int) |
| `rates` | array, opt | Fitted rates (below) |
| `per_100` | array, opt | Battery use per 100 pages or full refreshes (below) |
| `daily` | array, opt | Per-day totals (below) |
| `segments` | array, opt | Stretches of one state (below); readers fit rates from these when `rates` is missing |

## States

`state` is one of:
- `"standby"`: the screen is off. For `"crossink-firmware"`, this means asleep.
- `"reading"`: a book is open and in front.
- `"awake"`: the screen is on but no book is known to be open. A firmware that knows only
  awake/asleep reports `"awake"` and `"standby"`; screen-on time then means awake time.
- `"charging"`

Dimensions are optional on a rate or segment:
- `content`: `"text"` (EPUB, FB2, TXT, HTML…), `"comic"` (CBZ/CBR/images), `"webtoon"` (a
  comic read as one continuous strip), `"pdf"` (PDF, DjVu), `"xtc"` (pre-rendered Xteink
  books), or another value.
- `wifi_mode`: Android only: `"always_on"`, `"off_reading"`, `"jit"` (Just in time).
- `radio`: Wi-Fi radio, `"on"`/`"off"`.
- `vpn`: `"on"`/`"off"`.
- `light`: frontlight, `"on"`/`"off"`. Segments may add the optional `light_level`, a number
  on the device's own scale.

## `rates[]`

`{ "state", <at most one dimension>, "pct_per_h", "se" (opt), "hours", "change_pct", "segments" }`

- `pct_per_h` is a positive drain, or a positive rise for `charging`.
- It is the least-squares slope of % against time, pooled over segments, each segment with
  its own intercept. `se` is its standard error.
- `hours` is the data behind it, and `change_pct` the total % change over it.
- Readers show a rate only with ≥ 1 h of data (0.5 h for charging) and > 2% change.

## `per_100[]`

`{ "state": "reading", "content" (opt), "unit": "pages" | "full_refreshes", "pct", "count" }`

- `pct` is the % used per 100 units, computed as rate × hours ÷ count × 100.
- `count` is how many units were seen; written only from 100 units up.

## `daily[]`

`{ "day", "used_pct", "screen_on_min", "standby_min", "charge_min", "pages", "full", "partial", "charges" }`

- `day` (`YYYY-MM-DD`) may be `null` when there is no clock. Readers skip such rows for
  history.
- All other fields are optional. For `"crossink-firmware"`, `screen_on_min` means awake
  minutes.

## `segments[]`

`{ "start", "end", "duration_s", "state", "start_pct", "end_pct", <dimensions>, "pages", "full", "partial" }`

- A segment is a stretch of one state and one set of settings.
- `start`/`end` may be null without a clock. `duration_s` is then required, and it is
  always written by the companion.
- `start_pct`/`end_pct` are needed for a rate.
- Counts (`pages`, `full`, `partial`) are optional.
- The companion writes the last 90 days.

## Minimal firmware example

```json
{ "schema": "orbit-battery-stats/1", "source": "crossink-firmware", "battery_source": "voltage_estimate",
  "device": { "manufacturer": "Xteink", "model": "X4" },
  "segments": [
    { "start": null, "end": null, "duration_s": 36000, "state": "standby", "start_pct": 90, "end_pct": 89 },
    { "start": null, "end": null, "duration_s": 7200, "state": "reading", "content": "xtc",
      "light": "off", "start_pct": 89, "end_pct": 85, "pages": 300, "full": 30 } ] }
```

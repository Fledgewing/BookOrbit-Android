# Battery stats: design (draft for approval)

Goal: measured battery numbers per device, such as hours left, % per hour in standby and
while reading, and the effect of settings and content. Each device keeps its own history,
and devices can be compared through an export. Mockups: [`stats-mockups.html`](stats-mockups.html).

## What is recorded, by whom, how often

**Companion** (in its existing foreground service; no new alarms, polling or wake locks). It
stores one row, a snapshot of the whole state, each time something changes:

| Trigger | Source (no permission needed) |
|---|---|
| Battery % / plugged / temperature changes | dynamic receiver for `ACTION_BATTERY_CHANGED` (the system sends it about once per 1% and on plug changes) |
| Screen on / off | the service's existing screen receiver |
| Wi-Fi radio on / off | the existing `WIFI_STATE_CHANGED` receiver |
| VPN up / down | `ConnectivityManager` callback (already used for Tailscale) |
| NET_UP / NET_DONE / sleep sync | the existing broadcasts from the patch |
| STATS from the patch | new broadcast (below) |

Each row holds the time, the event kind, the level, the plug state, screen, Wi-Fi radio, VPN,
Wi-Fi mode, and the content type and frontlight at that moment.
- **Frontlight** is read when the row is written: `Settings.System screen_brightness` and,
  from the vendor profile, the M8C's `isLightOn`, `haoqing_warm_light`, `key_warm_value`
  and `key_cold_value`. All of these are readable on the device; their meanings are
  unverified. A key that isn't there is stored as null.
- **Capacity:** `BATTERY_PROPERTY_CHARGE_COUNTER` reads 0 on the M8C, so the
  capacity falls back to the power profile (`com.android.internal.os.PowerProfile`, read by
  reflection), and is null if that fails too.

**Patch** (inside KOReader) sends the `STATS` broadcast:
- **Page turns** are counted in its `onPageUpdate`.
- **Screen refreshes** are counted by wrapping `UIManager:_repaint`
  (frontend/ui/uimanager.lua:1298). Before the queue drains it reads `_refresh_stack`: each
  entry is exactly one physical refresh (:1388, dispatched through `refresh_methods` :1142-1152,
  after merging in `_refresh` :1200).
  - *Full* = `full`, `flashui`, `flashpartial`.
  - *Partial* = `partial`, `ui`, `fast`, `a2` and the `[ui]`/`[partial]` variants.
- **Content type** comes from the file extension:
  - *text*: epub, fb2, txt, html, mobi, …
  - *comic*: cbz, cbr, cb7, images
  - *pdf*: pdf, djvu, xps
  - *webtoon*: a comic in KOReader's continuous mode (`ReaderView.page_scroll`,
    frontend/apps/reader/modules/readerview.lua:959/986).

## Cost

- **Companion:** one broadcast delivery and one SQLite insert of about 60 bytes per event,
  roughly 300 rows a day.
- **No new wake-ups:** battery broadcasts come only when the system is already awake to
  update the battery. Screen and Wi-Fi broadcasts arrive anyway.
- **Patch:** two counters in Lua and one broadcast per 5 minutes of reading.
- **Measurement:** after install,
  `adb shell dumpsys batterystats --charged net.fledgewing.orbitcompanion` (wakeups, CPU
  time) before and after a day. Target: no change in wakeups, and less than 1 s of CPU a day.

## Storage and retention

- App-private SQLite (`stats.db`).
- **Raw rows** are kept for 90 days, about 2 MB.
- **Daily rollups** are kept forever:
  - `daily(day, used_pct, screen_on_min, pages, full, partial, charges)`;
  - `daily_cat(day, category, Σ(t−t̄)², Σ(t−t̄)(y−ȳ), points, hours, drop, pages, full, segments)`.
- The rollups are sufficient statistics: every rate below can be recomputed exactly from
  them after the raw rows are gone.
- Days are rolled up when the Battery page opens or the service starts, never on a timer.

## Statistics (exact definitions)

| Statistic | Definition | Shown only when |
|---|---|---|
| **Segment** | A maximal stretch with the same screen, charging, Wi-Fi radio, Wi-Fi mode, and (screen on) content and frontlight on/off. Points: its start, every 1% step, its end. | — |
| **Rate, %/h** for a category (e.g. standby + Just in time) | Pooled least-squares slope with a separate intercept per segment: −Σ(t−t̄ₛ)(y−ȳₛ) / Σ(t−t̄ₛ)², t in hours. The ± is its standard error. | ≥ 1 h of data and > 2% observed drop |
| **Standby** | Screen off, not charging: overall, by Wi-Fi mode, and by Wi-Fi radio on/off | as above |
| **Reading** | Screen on, KOReader in front, not charging: overall, by content, by Wi-Fi mode, by frontlight | as above |
| **Charge rate** | The same slope over charging segments, as a positive number | ≥ 0.5 h and > 2% |
| **Per 100 pages** | rate × hours ÷ pages × 100, within the same category | rate shown, and ≥ 100 pages |
| **Per 100 full refreshes** | rate × hours ÷ full refreshes × 100 | rate shown, and ≥ 100 full refreshes |
| **Estimated time left** | level ÷ (f·R_reading + (1−f)·R_standby), where f = the screen-on share of non-charging time over the last 7 days | both rates shown, and ≥ 24 h of non-charging data in those 7 days |
| **…if reading text non-stop** / **…in standby only** | level ÷ R_reading,text / level ÷ R_standby | that rate shown |
| **Daily** | % used (sum of drops while not charging), screen-on time, pages, full and partial refreshes, charges | always |

Hidden values show "—" and what's missing, e.g. "0.4 h of 1 h needed".

## Patch → companion: `STATS`

The `net.fledgewing.orbitcompanion.action.STATS` broadcast is explicit, like the others
(docs/INTERFACE.md). Every extra is a string.

| Extra | Meaning |
|---|---|
| `seq` | Batch number since KOReader started; the companion drops repeats. |
| `period_s` | Seconds this batch covers. |
| `pages` | Page turns in the batch. |
| `full`, `partial` | Screen refreshes in the batch. |
| `content` | `text`, `comic`, `webtoon`, `pdf` or `none`. |
| `reading_min` | Minutes with a book open and KOReader in front. |
| `wifi_mode` | The current Wi-Fi mode. |
| `reading_schedule` | The current Sync while reading setting. |

**Sending rules:** every 5 minutes while a book is open and something was counted; on
Suspend, before the sleep sync; and on book close. Never per page. A batch lost while
KOReader is killed costs at most 5 minutes of counts.

## Export JSON (`orbit-battery-stats/1`)

The export is aggregate only. Dates are by day.

```json
{ "schema": "orbit-battery-stats/1", "generated": "2026-11-21",
  "device": { "manufacturer": "Haoqing", "model": "M8C", "android": "14",
              "capacity_mah": 3000, "capacity_source": "power_profile" },
  "source": { "app": "orbit-companion", "version": "0.3.0" },
  "period": { "first_day": "2026-10-01", "last_day": "2026-11-21", "days": 52 },
  "rates": [ { "state": "standby", "wifi_mode": "jit", "content": null, "light": null,
               "pct_per_h": 0.19, "se": 0.02, "hours": 180.2, "drop_pct": 34, "segments": 61 } ],
  "per_100": [ { "unit": "pages", "content": "text", "pct": 1.3, "count": 2410 } ],
  "daily": [ { "day": "2026-11-20", "used_pct": 11, "screen_on_min": 95, "pages": 310,
               "full": 41, "partial": 290, "charges": 0 } ] }
```

- **Values:** `state` is `standby`, `reading` or `charging`. `null` means "any". Unknown
  fields are ignored. A firmware such as the Xteink one can emit the same format and leave
  out what it can't measure.
- **Delivery:** export goes through the share sheet or to Downloads. Import goes through
  Android's file picker into app storage.
- **Display:** imported files are only displayed side by side, never merged.

## Deliberately left out

- Per-book or per-title stats and file names.
- Per-app attribution and CPU, or network-byte accounting.
- Live graphs.
- Alerts and notifications.
- Any upload or cloud.
- mAh-based rates (the % is all every device reports).
- Exact timestamps in exports.

## Decisions I made (two-way doors)

- Frontlight on/off splits reading segments: it is probably the biggest single factor.
- Temperature and voltage are stored raw (free in the broadcast) but not shown in v1.
- Webtoon = a comic in continuous mode only; a PDF in scroll mode stays `pdf`, since the
  content differs.
- Rates use a pooled least-squares slope, not endpoints: % is 1-step coarse and segments
  are short.
- The thresholds (1 h, > 2%, 100 pages or refreshes, 24 h for the estimate) are constants
  in one place and easy to tune.
- The 7-day window for the estimate tracks recent habits and is long enough to smooth
  out single days.
- STATS goes every 5 minutes, on Suspend and on close; that is cheap and loses ≤ 5 minutes
  on a kill.
- Rollups are built on page open or service start, so no timer is needed.
- Compare shows imports side by side and never merges them, since different devices'
  numbers aren't additive.
- The pages are paged, not scrolled, with History at 7 days a page, which suits e-ink.
- The companion is the only store; the patch keeps nothing, so there is one source of truth.

## One-way doors for you

1. **What leaves the device** (export contents).
   - Options: aggregates only (recommended); add per-day timestamps of segments; add
     per-book data.
   - Hard to reverse because once files are shared they can't be recalled. Aggregates are
     enough to compare devices and carry no reading history.
2. **The export schema `orbit-battery-stats/1`.**
   - Options: freeze the field names above with "unknown fields ignored" (recommended),
     or keep it unversioned and internal.
   - Hard to reverse because, once other devices or a firmware emit it, renaming breaks
     them; later changes must be additive or go to `/2`.
3. **Raw retention: 90 days, then rollups only.**
   - Options: 30 days, 90 days (recommended), or forever (about 8 MB a year).
   - Hard to reverse because deleted raw rows can't be rebuilt. The rollups keep every
     shown statistic, so only new kinds of analysis on old data are lost.
4. **Permissions.** None new:
   - the broadcasts, `Settings.System` reads and the file picker need no grant;
   - "Save to Downloads" reuses the storage permission granted for the patch install, and
     the share sheet needs none.
5. **Public.** `docs/STATS.md` (the schema) will be public in this repo, like the rest. The
   export file itself is only ever shared by the user.

## Open questions (with my recommendation)

1. **Frontlight levels:** should reading be split by level (low/high) rather than on/off?
   - Recommendation: on/off now, and levels once the vendor keys' meanings are verified.
2. **Battery health trend over months** (charge rate and full-to-empty drift)?
   - Recommendation: later; the rollups already keep what it needs.
3. **Should the patch show a one-line battery estimate in its menu status?**
   - Recommendation: yes, read from the companion's `/status` (a small addition).

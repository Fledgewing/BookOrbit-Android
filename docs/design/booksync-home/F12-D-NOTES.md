# F12-D: Android settings

Approved Android-first build, maintainer ruling 2026-11-25. This implements the
Settings groups from `origin/design/booksync-home`'s prototype and design notes,
including rev 11 §19's single update-channel row. X4 Pro, X4 and X3 follow later.
The design branch is read without merging its unapproved implementation restrictions.

## Reuse and boundaries

- `ko/settings.lua:11` loads the existing shared schema; no second settings store.
- `logic/settings_sync.lua:46` validates wire values. `ko/shared.lua:223` sends
  changes with per-key timestamps; `ko/shared.lua:148` applies existing effects.
- `ko/menu.lua:105` extends the existing menu, PIN handling and About action.
  Settings groups are lazy and use the same native menu navigation.
- `ko/library.lua:16` supplies the caller budget and timing. `ko/store.lua:107`
  reads bounded materialized views via the existing SQLite connection, rather
  than spawning a process. `LibraryReadModel.kt:20` materializes responses on
  the companion worker, in `CacheStore.kt:15`'s existing owned database.
- `logic/caps.lua:29` remains the companion capability resolver. No server-name
  feature gating, backend endpoints or backend JSON were added to settings UI.
- `ko/sleepscreen.lua:70` and its companion operations remain the sleep-setting
  effects. The new Settings group reads shared values only. Saved-list and tag
  choice catalogs stay in the companion; it does not decode scopes/tags JSON or
  scan a catalog on paint. Existing legacy picker tests remain as compatibility
  tests of `Sleep.menuItem`, independently of the new Settings group.

## Behavior

Account & server, Sync, Wi-Fi & power, Library & downloads, Reading, Home, Sleep
screen, Updates and About & help are available from the existing Tools entry.
Unavailable Wi-Fi controls and presets remain visible but disabled with a reason;
mode matching uses the effective device Wi-Fi policy.
Every shared sleep value stays visible, including values owned by the companion.
Source choices use the shared schema; advanced saved lists and exclusions open
its existing sleep page. Device power management remains in the companion/OS.
Home exposes the owned host's shared `home_screen` selector
(`shared/settings/schema.json:95`) and the existing
Home-button policy. Layout editing/reset/renaming and reading presets need their owning slices' APIs;
this change does not add inert controls or a parallel layout store.

Battery saver, Balanced and Always up to date set the six approved sync/power
values together. Balanced matches the schema defaults. An individual change
outside those combinations displays Custom and offers Back to Balanced. The
position rule no longer overrides the visible sleep/wake/cadence settings:
scheduled reading pulls still use the existing furthest-position decision and
behind-hold protection, without an extra automatic pause timer.

Sync now uses `Library.syncNow(reader)`, reusing the snapshot/drain operation
with an explicit stay-awake option on success and failure.
Full refresh uses `Library.fullRefresh()` and the adapter delegates to the
existing `ko/cache.lua:789` command and companion job, preserving explicit
refresh without exposing a backend client to Settings.

The only new read operation is `Library:modeEstimates()` / `mode-estimates`, a
three-row worker snapshot keyed by `saver`, `balanced`, `current`. Each row has
`id`, display `text`, and `measured`. The battery slice can replace the honest
unmeasured placeholder with “≈ … at your usual use”; Lua performs no estimate
calculation. Missing snapshots display Estimate pending. No sample duration is
presented as a real device prediction.

## Performance contract

Maintainer rule 2026-11-25: **every screen and widget declares a strict budget**;
library calls inherit the caller's budget. Group budgets live in
`logic/budgets.lua`, inherit Settings' 32 rows / 32 KiB ceiling, and have an
info-level paint span. Every group checks its row limit. Sync reads three rows
(up to 16 KiB), queues one batched companion request, and logs its library call
and paint. Settings render paths have zero subprocesses and zero server network
calls. Filtering, sorting, counts, search, stats, battery estimates and joins
stay in the companion. Tests use deterministic limits; host timings are not
device performance evidence. Targets remain subject to device confirmation:
Home <500 ms, widget <50 ms, cached window <30 ms, editor move <100 ms.

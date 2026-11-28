# Retained Sync and quick controls

Approved DESIGN §3.1 retains Sync now/result/freshness and Wi-Fi, Night, Rotate
and Sync controls. Two additive editor choices use one-row / 16 KiB
`local.controls` projections in the host's single batch. Existing layouts and
default pages remain. The companion formats only whitelisted cached native
scalars, never exception detail, account credentials or protocol responses.

Sync invokes the existing active reading-sync owner, not catalog Refresh. Its
result explicitly describes the last reading sync check, with age; no saved check
is unknown, and busy work disables duplicate taps. The existing checkpointed
position/outbox flow and consent exception remain. Visible Home refreshes every
five seconds, stopping when closed. This does not promise that a cached catalog
is fresh or that every remote account value has been downloaded.

Wi-Fi requires the existing explicit helper opt-in and advertised capability.
Active sync/download work or a Wi-Fi lease disables the control. The action
rechecks before writing and sends the existing manual companion command; it
never enables a helper or opens a new permission surface. Night invokes native
`DeviceListener:onToggleNightMode` (screen inversion, reader cache/highlight reset,
refresh policy and persistence), not UIManager's refresh-policy-only method.
Rotate hands back to the native reader/browser before invoking its native
90-degree action, so Home's fixed saved grid is not clipped in landscape.

Pinned KOReader `9192014d8bd82a91dc1012473be0f238dedfdb54` evidence:
`frontend/device/devicelistener.lua:14` and `:261`; reader rotation handler
`frontend/apps/reader/modules/readerview.lua:892`; browser handler
`frontend/apps/filemanager/filemanager.lua:71`. New native symbols are in the
compatibility inventory. Native access stays behind Library.

## Verification

Three companion tests cover unknown/future/foreign results, successful/failed
check age, busy sync, missing hardware and work holds. A Lua flow checks native
write rechecks, manual ownership and duplicate-sync suppression. Native acceptance
uses actual Night and Rotate handlers and the existing reading-sync path; disabled
Wi-Fi presentation does not request helper authorization.

The first rotation harness incorrectly required the emulator's reported mode to
change synchronously. Android's native orientation request changes the app viewport
in this fixed-portrait AVD while its display-mode getter remains zero. The corrected
check wraps and forwards the real native setter, verifies the 90-degree request,
Home departure and changed viewport, then restores the native request directly.
This is an emulator limitation, not a physical rotation sign-off. The pinned base
`6e4bc81af4e04f78d81677a323a780a71b29702a`, `ffi/framebuffer_android.lua:65`–`:84`,
[defines the native getter/request split](https://raw.githubusercontent.com/koreader/koreader-base/6e4bc81af4e04f78d81677a323a780a71b29702a/ffi/framebuffer_android.lua).

A controls check after the full review exposed cross-handle cache write contention:
33 fixture projection failures included SQLiteDatabaseLockedException. Cache locking
had been per store instance. A deterministic two-handle JVM test fails on that
implementation and passes with one canonical-database monitor covering initialization,
transactions and close. The fix preserves schema/version and rollback semantics.
The corrected build passes the full 68-screen review followed by the previously
failing controls sequence, with zero fixture publication failures/lock exceptions
in the captured current-process log. This was fixed before accepting the scenario.

Validation: 899 JVM tests (zero failures/errors, four skipped), shared-version check,
debug assembly and lint; 259 Lua logic / 292 flows; server/UI guards 12/6, matrix
four, emulator driver ten and pinned native symbols. Six dedicated native checks
include active Wi-Fi hold rejection and duplicate Sync suppression. Construction
spans: Sync 0–0.2 ms and quick controls 0–0.5 ms (nine samples each; target 50 ms).

Physical acceptance, firmware implementation and publication remain pending.

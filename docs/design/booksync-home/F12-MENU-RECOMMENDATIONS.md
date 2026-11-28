# Android 0.12 menu recommendations

The approved add-on design §5/§9 now uses ten Library-owned descriptors, including
`g.no_flip` and `o.clean_menus`. No additional screen or control was introduced.
The existing native review presents both items, their conflicts and Undo.

The companion evaluates bounded observations; the plugin only observes native
settings, persists the Undo backup and performs compare-before-write operations.
Automatic menu takeover requires the other available settings to remain at their
defaults or BookSync values, with no unresolved customization or previous Keep.
That condition is checked again at the native write boundary. A user can explicitly
choose BookSync's menus while retaining a customized gesture. Undo restores the
exact prior unset, false or true menu value and does not automatically reapply it.
The owned menu setter installs or restores the same per-reader-instance hooks as
[reader navigation](F12-READER-NAVIGATION.md).

The first definition fetch previously left the recommendation pass pending before
recursing. It now clears that fetch state and holds pending during evaluation,
native writes and acknowledgement. Each pass is limited to ten native bindings;
its result and review share the 16 KiB projection budget. No catalog, network,
folder scan or sidecar work runs in the reader's pass or paint.

## Verification

- Companion: 879 tests, zero failures/errors, four skipped; shared-version check,
  debug build and lint pass. Three new tests cover customization/order independence,
  kept/disabled choices and exact unset restoration.
- Lua: 256 logic and 285 flow tests pass. Four added backend flows cover first-fetch
  completion, a customization arriving during worker evaluation, explicit opt-in
  and nil Undo. Server/UI boundary suites: 12/6.
- Native emulator: five menu recommendation checks pass using the real companion
  plan and real KOReader settings, gesture storage, menu hooks and review callbacks.
  The fixture supplies the production descriptor list without real server HTTP;
  unsupported legacy connector bindings remain honestly unavailable. The flow
  restores its synthetic preferences and each saved native binding afterward.
  The full existing native review also passes all 57 screens; the approved add-on
  install/update/helper flow passes three checks. Emulator driver safety: eight tests.

Reproduce after fixture setup:

```
python3 tools/e2e/android/menu_recommendations.py --serial emulator-5580 --out <evidence>
```

The initial native attempt reached the correct Undo dialog but a newly published
setup reminder covered it. The harness now acknowledges only that known checklist
overlay before asserting the recommendation action. The failed evidence is retained;
this was not retried without a harness correction. Physical-reader acceptance and
publication remain separate; no release or device operation is claimed.

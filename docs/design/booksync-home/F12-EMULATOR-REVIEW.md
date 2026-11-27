# Android emulator review

Android-only review of `feature/0.12`; firmware remains deferred under the
maintainer's Android-first authorization. The approved design remains unchanged.
Reproduction and fixture limitations: [native emulator tools](../../../tools/e2e/android/README.md).

Reuse evidence from the reviewed branch:

- `android/koreader/orbit.koplugin/ko/home.lua:256`: existing owned Home entry.
- `android/koreader/orbit.koplugin/ko/store.lua:81`: existing reading/busy/memo gate;
  `:149`: one size-checked published library blob.
- `android/koreader/orbit.koplugin/ko/library.lua:179`: existing per-paint budget;
  `:192`: bounded interface reads. No UI transport was introduced.
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/LibraryReadModel.kt:27`:
  existing companion publisher, owner isolation and row/byte limits.
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/DeviceLibrary.kt:29`:
  existing worker-owned local catalog and sidecar normalization.
- `android/companion/app/src/main/java/net/fledgewing/orbitcompanion/SeriesPresentation.kt:30`:
  existing ordered Series projection; local Series reuses it.

Defects corrected:

1. Full Refresh's job-state string was accepted as account state by generic command
   completion. Only account/login commands may publish an account-state table.
   Catalog ownership and signed-in capabilities now survive refresh completion.
2. Store's memo-only foreground-reading rule prevented cold, explicitly opened
   reader panels from reading newly published snapshots. The library passes a
   narrow explicit-surface read permission. Background reads remain memo-only;
   the reading notification gate is unchanged. SQLite regression tests cover both.
   Home also resumes a pending bounded redraw when a covering dialog is dismissed;
   its paint callback only queues the work and performs no reads.
3. The local adapter had no Series or end-sheet projection. Saved local membership
   now provides bounded ordered members, next-book metadata and View series;
   removal invalidates these snapshots too. Native reader progress takes precedence
   over stale sidecar progress. Non-ASCII labels use the existing literal encoding.
4. The default one-row Library tile used tall-tile caption offsets and painted
   outside its border. Its compact actions share a band and its measured caption
   anchors inside the actual tile height.
5. Stats provenance badges could overlap their titles. Native text measurements
   now determine header clearance and feed the existing pure chart planner. Hero
   covers also clear the measured heading instead of striking through it.
6. A missing startup status could cache a false companion-version mismatch for
   30 seconds. Only the matching version keeps that positive cache; pending/stale
   statuses can become usable immediately, without relaxing the exact-version gate.
7. The direct Updates entry bypassed the owned group renderer and flattened channel
   explanations in a stock single-line menu. It now reuses `SettingsView`, including
   the existing 96-pixel choice rows and multiline TextBox labels. Rapid reader edits
   also receive increasing per-key timestamps, preventing a stale companion echo
   from undoing Preview → Stable within one clock second.

Performance rule inherited from AGENTS.md: every screen/widget and interface call
retains its declared row and decoded-byte budget, zero subprocesses/network on
paint, one batched companion round-trip per Home paint and 16 KiB per snapshot.
The companion owns scans, sorting, grouping and selection; Lua only measures and
draws bounded records. Existing info-level spans remain enabled. Emulator timings
do not establish the physical-reader targets.

Evidence: Android 14 ARM64 tablet AVD, 1200×1600/240 dpi; KOReader v2026.07.1;
57 native screen/action checks, including all 17 registered widgets, editor
move/save/reset and live Custom value edits with native setting assertions. The separate
upgrade run used `main` at `3e2814f1fd2ae69069608172d8e55b70e7568ada`.
PNG evidence stays outside the repo. No physical reader, release or tag was used.
The branch's shared version remains its existing 0.11 identity; the reviewed code
is the unreleased 0.12 implementation.

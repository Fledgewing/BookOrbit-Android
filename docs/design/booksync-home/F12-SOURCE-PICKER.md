# Late ready responses in the Source picker

The approved Book list Source picker remains a six-row, counted, paged control.
A response can arrive after its initial bounded polling window under queued worker
load. Final native year selection exposed a ready second page left on Loading.

The modal now observes the existing neutral Library changes without replacing
Home's subscriber. Callbacks coalesce onto the next UI tick. While covered or
reading they retain one deferred check and perform no reads or focus changes;
when frontmost they repaint the existing bounded picker. Close detaches the
observer and cancels its callback. Weak observer keys cannot retain forgotten
modals. The existing polling bound remains unchanged.

One source window / 16 KiB and one batched round-trip per paint remain. No network,
scan, file parsing or subprocess is added to KOReader. There is no new control or
server request; firmware remains deferred under the Android-first ruling.

The Lua regression fails before the repair. It expires the original poll, publishes
a late ready event, checks that Home keeps its subscriber, covers/reveals the picker,
selects the year and verifies close retirement. Native acceptance exercises the
real cached second source page through the existing year flow.

Physical acceptance and publication remain pending.

The native reply also inherited background-notice scope. The old repaint closed
its dialog before the gate suppressed its replacement. Replacements now stay
inside `Gate.show`: the central gate verifies that the previous owned modal is
frontmost and nobody is reading, then replaces it as one operation. A suppressed
replacement leaves the old dialog intact. The regression executes the ready
callback in background scope and asserts that the actual dialog stays visible.

The native fixture also rebuilt its local catalog for every field and cover lookup.
It now retains one worker-thread snapshot per read batch, as the shipping local
read model does (`DeviceLibrary.kt:27`, `LibraryReadModel.kt:51`). The snapshot is
released between batches so subsequent file changes remain observable.

The fixture previously overwrote mailbox batches and ignored acknowledgements,
leaving 625 synthetic invalidations queued during repeated reviews. It now emits
through the existing bounded EventMailbox and handles its acknowledgements, with
no bespoke batch overwrite. Native tests assert that the explicit picker is in
front before waiting for its cold page.

The initial explicit control was also suppressed while a catalog refresh muted
notices. The editor now supplies its visible origin to the same central gate;
the gate still requires that origin to be frontmost and `reading()` false. The
regression opens the picker with catalog refresh active. The fixture now publishes
the canonical completed catalog-status row, so its completed fake refresh no
longer leaves the client waiting for an unpublished status.

Verification: **914 JVM tests**, zero failures/errors, four skips; shared-version,
debug APK and lint pass. **262 Lua logic / 300 flows**, boundary guards **12/6**,
feature matrix **4**, emulator driver **10**. The real cold-cache year flow passes
all five checks. Eight native Library/source checks also pass, including the actual
editor Configure origin, counted roots, named paging and unknown counts.

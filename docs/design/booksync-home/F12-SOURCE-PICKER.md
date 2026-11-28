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

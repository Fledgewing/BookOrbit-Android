# F42 cached sleep scenes — NEEDS APPROVAL

Proposed 28 November 2026. [Review all device scenes](F42-sleep-mockups.html).
This is a docs-only proposal into `feature/0.12`. It grants no firmware UI
approval and changes no shipped feature cells or firmware pin.

The [sleep design](../lock-screen.md) defines cached cover, optional text and
battery behavior, but its referenced `lockscreen.html` is absent on this branch.
Neither the approved [firmware gallery](mockups.html) nor Home revision 16
illustrates the sleep states below. F42 retains native sleep screens and leaves
these new BookSync presentations off until this proposal is approved.

The supplied 0.11 X4 Home photo is the density reference: compact UI text, thin
rules, small gaps and substantial book artwork, rather than oversized cards or
large instructional headings. The photo is not copied into the repository; it
contains private reader information. All mockup content is synthetic. The
480 × 800 viewport is a design reference; runtime uses oriented renderer bounds.

| Scene | Proposed X4 Pro / Classic | Proposed X3 |
|---|---|---|
| Current cover | Full cached cover, no Home header or action chips | Existing native cover, no added BookSync artwork |
| Recommended cover | Same geometry, cached recommendation, no source label | Off; retain native sleep screen |
| No saved recommendation | Compact “Covers not ready” and next-sync hint; never connect or silently switch to current book | Off; retain native sleep screen |
| Current cover unavailable | Retain native default sleep fallback | Retain native default sleep fallback |
| Bar | Optional text and captured battery in bottom band, 7% height, two-line text can use 10% | Off pending an approved bounded text view |
| Overlay top / bottom / left / right | Single outlined plate per extra, 2% inset, battery moves away from text edge | Off pending approval |
| Long text | At most 60 characters; two horizontal lines or one rotated line, then ellipsis | Off pending approval |
| Offline / bad cached image | Keep usable cached artwork; native fallback if none, no network during paint | Native fallback |

The gallery draws every listed X4 scene twice (Pro and Classic), plus X3's
explicit retained-native state. Sleep has no touch controls, button focus,
unlock prompt, live battery or clock. Waking keeps the retained native reader,
security and power routing. No new setting or picker is approved here.

Capture is local and precedes the drain deadline. Optional delivery must use the
existing single writer, never a new sleep worker. A bounded drain cancels existing
admission and waits for worker/files/display ownership. At its deadline, an
uncooperative worker retains ownership and the sleep attempt is deferred with a
log; never kill it under I/O, draw into a leased framebuffer, or suspend its SD
rail. That exceptional path retains the reader and its saved local progress.
Normal release proceeds to native sleep; reboot starts with no presentation ticket.
The simulator's returning sleep retires the pass explicitly. No sleep screen
fetches, parses or writes, and no background completion can claim wake focus.

Hardware acceptance remains with the maintainer: on Pro, Classic and C3, read,
turn a page, power-sleep, wake and reboot; check the same native position and
screen settings. Repeat with plugins disabled and offline. Check worker teardown
before display/SD shutdown and deadline logs on a deliberately delayed fake
transport. No EPUB cache reset is needed: F42 changes no cache formats or layout.

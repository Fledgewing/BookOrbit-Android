# BookSync F20 finish recovery — NEEDS APPROVAL

Status: **NEEDS APPROVAL**. Docs only. Merging these drawings does not approve
these recovery states or enable firmware UI. F20's service is already separate;
F41 owns later reader presentation.

The [redrawn gallery](f20-finish-recovery.html) shows three states on X4 Pro,
X4 Classic and X3: **nine device views**. It follows the dark device frames,
480 × 800 design viewport, header/footer, compact type, outlined actions and
visible button focus of [the firmware gallery](mockups.html) and
[F36a](f36a-library.html). Spacing and type density were compared with the supplied
0.11 X4 Home photograph. The photograph and its personal content are not included;
all book content in this proposal is invented.

The sheet is anchored over the book page, with a heavy top rule and no dimming.
It occupies 480 design pixels (60% of the screen); the last page stays visible
above. This reuses Android's approved sheet treatment, not a new full-screen
recovery destination. Rating and recommendation actions are omitted from these
recovery details; the approved normal end sheet is unchanged.

Rendered review previews: [result unknown](shots/f20-result-unknown.png),
[Undo pending](shots/f20-undo-pending.png),
[previous value unknown](shots/f20-previous-unknown.png). Each contains all three
device variants; the HTML remains the source for the drawings.

## Wording checked against Android

The approved [end-of-book design, section 4](../end-of-book/DESIGN.md#4-android-a-bottom-sheet-over-the-last-page)
and [Android mockups](../end-of-book/mockups.html) establish these strings.
Current Android production sources confirm them:

| Reused wording | Evidence | Use here |
|---|---|---|
| `✓ Marked as finished` | [DeviceLibrary.kt:104](../../../android/companion/app/src/main/java/net/fledgewing/orbitcompanion/DeviceLibrary.kt#L104), [finish.lua:47](../../../android/koreader/orbit.koplugin/ko/finish.lua#L47) | Local mark only; adjacent copy says it is saved on this reader, not confirmed remotely. X3 omits the decorative checkmark. |
| `Undo` | [endsheet.lua:83](../../../android/koreader/orbit.koplugin/ko/endsheet.lua#L83); design decision G25 | Secondary outlined action. Never “Not finished” or “Mark as reading”. |
| `‹ Back to book` and `Home` | [endsheet.lua:124–125](../../../android/koreader/orbit.koplugin/ko/endsheet.lua#L124) | Sheet footer actions; X3 substitutes action numbering for the back chevron. |

The recovery headings and explanations below have **no approved Android
counterpart** in those sources. They remain proposed copy, not a claim of Android
approval or a change to Android. In particular, the approved success/offline
strings “Finished · sent” and “Finished · will send when online” must not stand
in for an unknown write result. A timeout proves neither success nor failure.

## Proposed states

| State | Proposed recovery wording | Service meaning and actions |
|---|---|---|
| Result unknown | **Checking finish** — Waiting to confirm the server result. Your finish is saved on this reader. | An attempted write may have committed. Retain it and reconcile. Undo stays available as a secondary action; Back to book and Home preserve the saved intent. |
| Undo pending | **Checking earlier finish** — Waiting to confirm the earlier finish before restoring your previous choice. Undo is saved on this reader. | Durable compensation follows the original receipt. The status says “Undo pending”, not that restoration has succeeded. Back to book / Home; no duplicate Undo control. |
| Previous value unknown | **Earlier choice unavailable** — Your earlier choice is not available. Keep reading while the finish result is checked. | No fabricated previous status/rating. Unsafe restoration is refused. Back to book / Home; no guessed value or retry action. |

## Controls and ownership

X4 Pro uses touch actions; tapping the visible page or Back returns to the exact
native reading position. X4 Classic and X3 use Prev/Next, Select and Back, with
initial focus on **Back to book**. X3 has bounded text, numbered actions, no
cover art, rating input or touch affordance. Home preserves the durable intent.
Closing a sheet retires only presentation ownership.

These are user-opened end-of-book details, never an automatic popup while
reading. Paint consumes immutable Library values without I/O. Library owns all
finish and navigation intents; no UI talks to a server adapter. No timer,
spinner, polling or automatic retry is proposed.

A newer local choice invalidates an old Undo. A newer remote choice is preserved
by guarded compensation. Unknown outcomes remain queued. At journal capacity,
refuse a change that cannot be stored; never evict a receipt or pending work.
Existing approved B2 capacity presentation remains the only capacity UI.

This proposal changes no shipped feature cells, reader behavior, firmware pin,
server protocol, device state or release input. Android keeps its approved
presentation and service semantics. Firmware service parity does not approve
these additional device states. Browser layout checks and rendered mockups are
review evidence; native simulator and maintainer hardware acceptance remain
requirements before any later activation.

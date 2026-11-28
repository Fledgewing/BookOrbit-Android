# Retained Achievements card

Approved DESIGN §3.1 retains earned/total, the latest award/date and the next
achievement with progress/threshold. All remain visible in the additive 2×2 editor
choice; wider/taller spans are also supported. Existing defaults and layouts remain.

The adapter normalizes only the authorized cached account summary through the
neutral `account.badges` Library projection, one row / 16 KiB in the host batch.
No route, background request or remote artwork is added. Missing cached data,
unsupported summaries and unavailable/turned-off results stay distinct from a
known zero earned count. The upstream response uses null for both disabled and
unavailable; BookSync does not invent a more precise distinction. Malformed counts,
award dates or progress are unknown, never fabricated zeroes or success.

Pinned BookOrbit `c1dd6b4f1947ff50843a155e12e70f1e7d15f0c7`,
`server/src/modules/koreader/koreader-catalog.service.ts:108`–`:120` defines badge
fields; `:299`–`:329` selects latest and next and returns null when disabled,
unsupported or failed. Protocol names and response normalization stay inside the
adapter. Local-only libraries show an explicit account requirement.

## Verification

Companion tests distinguish unknown/off/unsupported from zero, preserve latest
and next together, handle UTF-8 and reader-zone award dates, and reject malformed
counts/progress. Lua tests render both awards and progress in every immutable
span and verify the neutral request and unavailable presentation. Native review
uses the cached production adapter and all three permitted spans; unavailable
states are separately exercised without adding a setting or permission flow.

Three native checks pass with cached earned/total, latest/date and next/progress
visible in all supported spans. Companion verification: 917 tests, zero failures
and errors, four skipped; Lua: 262 logic and 301 flows passed. The emulator driver
now handles only KOReader’s specific first-run color notice and exercises the new
Achievements choice through editor add/resize/move/save.

Physical acceptance, firmware implementation and publication remain pending.

# BookSync persistent Android crash summary

Status: **proposal — NEEDS APPROVAL**. Android 0.12 parity gap 4.
The mockup below is proposed, not authorised UI. No implementation accompanies it.
X4 Pro/X4 keep existing diagnostics; X3 remains outside this Android outcome.

## Outcome and retention

Keep a small, deduplicated crash summary across process restarts, local only.
Do not automatically upload it, notify, open a sheet, restart KOReader or take focus.
The summary is available only when the user opens Setup → Details. Preserve the
existing Copy for support action; copying is explicit and never transmits anything.

Use an app-private, non-backed-up atomic record, bounded to 8 KiB, at most four
fingerprints. Retain component, BookSync version, exception type, first/last UTC
time, repeat count and up to eight allowlisted application frame symbols. Do not
retain exception messages, stack arguments, book titles/paths, document contents,
URLs, account identities or credentials. Never capture an arbitrary exception
string. Fingerprints use component/version/type/allowlisted frames, excluding time.
Repeated identical crashes update the same count. An unreadable/torn record is
ignored without preventing startup. Bound counters and handle clock rollback.

The companion records uncaught Java/Kotlin exceptions before delegating to its
previous/default handler exactly once, even if saving fails. Capturing native
KOReader failures needs a separate bounded handoff: do not pretend a companion
exception hook captures a native process crash. Do not scan unrestricted logs or
copy native crash dumps. Until that handoff is designed, label the scope precisely
as “Companion crashes”, with no fabricated plugin coverage.

## Proposed Details mockup

Reuse the approved checklist Details typography and Back/Copy for support controls.
This proposed block appears after the existing diagnostics. It adds no Home badge
or setup-attention count. Empty and saved states are shown in the
[review mockups](crash-summary-mockups.html).

```text
Details                                      Back
…existing diagnostics…
Companion crashes
2 matching crashes · BookSync 0.12.0-preview.1
Last seen: 27 Nov 2026, 18:00 UTC
IllegalStateException · Worker.run
Saved on this reader. Never sent automatically.
[Clear crash summaries]

[Copy for support]
```

Empty: “No companion crash summaries saved.” Clear removes only these summaries;
then the same page displays the empty state. No confirmation dialog is proposed
for this bounded local diagnostic. Support text contains only the sanitised fields
above. A failure to load says “Crash summary unavailable”; it never crashes Details.

## Interface and budgets

UI requests a neutral Library diagnostics snapshot, never reads crash storage.
One local row, at most 8 KiB inside the existing Details screen budget; zero network,
subprocess or scan on paint. File IO/aggregation belongs behind the companion's
Library service. Clearing is an explicit Library command. Keep persistence off
KOReader's UI thread and preserve the reading gate.

## Acceptance after approval

Unit tests: duplicate/restart/version separation, torn record, size cap, frame
allowlist, credential/path/message omission, clock rollback, write failure and
exactly-once handler delegation. Library tests: byte/row ceiling and explicit clear.
Emulator: synthetic crash in a disposable process, restart, reopen Details, check
count/dedup, copy sanitised support text, clear and reopen; no popup during reading.
No intentional crash runs against a real reader. Physical acceptance stays separate.

# Local Next stop card

The approved DESIGN §3.1 / §3.4 choice is additive in the Home editor, including
its 2×2 minimum. Existing defaults and saved layouts remain. The reader captures
only cached page/count, cached identity and at most 32 TOC comparisons, returning
before marker projection or annotation anchor lookup. It never loads a TOC or
calls the reader engine during paint. Open Contents once is explicit guidance
when the native cache is absent.

`local.nextstop` is a one-row / 16 KiB Library projection. The worker reads the
borrowed local statistics database read-only, using the current native fraction
and the existing measured fractional-page pace (five sane timed visits). It
shows current/next contents entry, approximate time to next/end and remaining
contents entries. A TOC entry is not assumed to be a semantic chapter. Missing
identity, pace, unresolved TOC markers and closed books stay unknown/unavailable;
reaching the end never creates a completion record. Captured titles are bounded;
no sidecar parse, scan or protocol call runs in the widget renderer.

The visible host refreshes at most once a minute; no hidden timer survives Home.
All requests share its one batch. Native fields and readSetting are already in
the pinned compatibility inventory. The normal forecast payload retains its old
shape; numeric pace is opt-in for this local projection only.

## Verification

Four companion tests cover measured borrowed-SQL pace/current fraction, UTF-8,
invalid identity, missing/unresolved TOC, bad estimates and end-position semantics.
A Lua flow checks the 10,000-entry cached lookup and verifies that no annotation
resolution occurs. Native acceptance uses the actual cached TOC and companion;
rich pace and no-book presentation states use temporary Library doubles.

Physical acceptance, firmware implementation and publication remain pending.

-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Decisions taken on plugin state, kept pure so they can be tested.
Plan = {}

-- Strategy values from bookorbit main.lua:56-60.
Plan.STRATEGY = { PROMPT = 1, SILENT = 2, DISABLE = 3 }

-- While waiting for the plugin's lifecycle outbox after a sleep sync.
--   pending: entries still to send (count - blocked)
--   busy: the plugin's sync coordinator is running or has queued work
--   new_error: the plugin recorded an error since we started
-- Returns "done", "failed", "timeout", "nudge" (ask the plugin to drain again) or "wait".
function Plan.outboxVerdict(o)
    if o.pending == 0 and not o.busy then return "done" end
    if o.elapsed >= o.cap then return "timeout" end
    if not o.busy and o.new_error then return "failed" end
    if not o.busy and o.since_nudge >= 2 then return "nudge" end
    return "wait"
end

-- Sync while reading: what to do once the plugin has refreshed BookOrbit's position
-- (fetchRemoteProgress, which never moves the reader or prompts).
--   has_remote: BookOrbit has a position for this book
--   same_place / remote_newer: the plugin's own isSamePlace / remoteProgressIsNewer
--   forward: the plugin's "BookOrbit is further ahead" strategy
-- Returns "push", "pull" or "none". Never "prompt": a PROMPT strategy waits for the next
-- wake or book open, so nothing interrupts the page.
function Plan.readingAction(o)
    if not o.has_remote then return "push" end
    if o.same_place then return "none" end
    if o.remote_newer then
        if o.forward == Plan.STRATEGY.SILENT then return "pull" end
        return "none"
    end
    return "push"
end

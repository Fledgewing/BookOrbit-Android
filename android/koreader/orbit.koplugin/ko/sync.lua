-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Waiting on the plugin's lifecycle outbox (bookorbit main.lua:374-547)
---------------------------------------------------------------------------------------------

Sync = {}

-- The plugin skips a non-interactive pull within 25 s of the last one
-- (API_CALL_DEBOUNCE_DELAY, bookorbit_progress_sync.lua:26, 384-387). Clear it only when the
-- last pull really was that recent; on a fresh start a pull that already ran stands.
function Sync.clearPullDebounce(p, reason)
    local okc, cleared = pcall(function()
        local last = p.pull_timestamp
        if type(last) ~= "number" or last == 0 then return false end
        if reason == "start" then return false end
        local now = UIManager:getElapsedTimeSinceBoot()
        local window = time.s(25)
        if now - last <= window then p.pull_timestamp = 0; return true end
        return false
    end)
    if okc and cleared then log("pull: cleared the plugin's 25 s debounce for this pull (" .. reason .. ")") end
end

function Sync.waitOutbox(p, cap, cb)
    if not can(p, "outbox") then
        -- Can't see the plugin's outbox: leave it to the plugin's own sync.
        return UIManager:nextTick(function() cb(true, "left to the plugin (compat)", 0) end)
    end
    local t0 = now_s()
    local start_os = os.time()
    local last_nudge = t0
    local function tick()
        local el = now_s() - t0
        local okd, diag = pcall(function() return p:getLifecycleOutbox():diagnostics() end)
        if not okd then
            log("outbox: cannot read:", diag)
            return cb(false, "outbox unreadable", el)
        end
        local coordinator = p:getSyncCoordinator()
        local busy = coordinator:isBusy() or coordinator:queuedCount() > 0
        local err = p.settings.last_error
        local verdict = Plan.outboxVerdict{
            pending = (diag.count or 0) - (diag.blocked or 0),
            busy = busy,
            new_error = err ~= nil and (err.at or 0) >= start_os,
            elapsed = el,
            cap = cap,
            since_nudge = now_s() - last_nudge,
        }
        if verdict == "done" then
            log("outbox: drained after", fmt(el), "(parked:", diag.blocked or 0, ")")
            return cb(true, nil, el)
        elseif verdict == "failed" then
            log("outbox: plugin reported", err.event, err.message, "after", fmt(el))
            return cb(false, err.message or "plugin sync failed", el)
        elseif verdict == "timeout" then
            log("outbox: still", (diag.count or 0) - (diag.blocked or 0), "pending at the", cap .. "s cap")
            return cb(false, "time limit reached", el)
        elseif verdict == "nudge" then
            last_nudge = now_s()
            p:requestLifecycleOutboxDrain("orbit_wait")
        end
        UIManager:scheduleIn(0.5, tick)
    end
    tick()
end

---------------------------------------------------------------------------------------------

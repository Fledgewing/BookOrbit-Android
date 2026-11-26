-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Wake / start
---------------------------------------------------------------------------------------------

function OrbitAndroid:onResume()
    if not stats_acc.at then
        stats_acc.at = now_s()
        if readerContent() ~= "none" then Stats.send("resume") end
    end
    state.paused_for = state.suspended_at and (now_s() - state.suspended_at) or nil
    state.suspended_at = nil
    Wifi.state().foreground = true
    if state.slept then
        state.slept = nil
        pcall(Sleep.woke)
    end
    log("resume", state.paused_for and ("after " .. fmt(state.paused_for) .. " in the background") or "")
    Clicks.install("resume")
    -- Back in front and not in a book (file browser, BookOrbit Home): what waited shows now.
    UIManager:scheduleIn(2, function() Gate.drain("resume") end)
    UIManager:scheduleIn(0.3, function()
        if Library then Library.accountReturned() end
        Shared.refresh("resume")
        Wifi.applySettings("resume")
        self:checkCommand("resume")
        self:maybeRestart("check")
        -- After checkCommand: a Home command moves to BookOrbit home first (finishHome checks too).
        self:maybeSetupPrompt("resume")
        -- Also after "home": the closed book's sync needs the network.
        self:wakeFlow("wake")
    end)
end

function OrbitAndroid:wakeFlow(reason)
    -- OrbiSmart: a short nap rarely follows reading elsewhere; its sleep sync already ran
    -- (docs/design/position-sync.md §3.3, wake check after >= 5 min asleep).
    if OSM and OSM.on() and reason == "wake" and state.paused_for and state.paused_for < OSM.WAKE_MIN_S then
        log("orbismart: woke after " .. fmt(state.paused_for) .. "; no wake check under " .. OSM.WAKE_MIN_S .. " s")
        return
    end
    if not S.sync_on_wake then
        log(reason .. ": sync on wake is off")
        return
    end
    local p = bookorbit(self.ui)
    if not p or not p:isLoggedIn() then
        log(reason .. ": BookOrbit plugin missing or signed out; nothing to do")
        return
    end
    local t0 = now_s()
    local lease = "wake"
    Wifi.acquire(lease)
    Net.up(p, { reason = reason, cap = 20, need_server = true }, function(ok, res)
        if not ok then
            Wifi.release(lease)
            self:showWakeBanner(res)
            return
        end
        -- OrbiSmart: pull and decide first, then the outbox under the behind-hold.
        if OSM and OSM.on() and inBook() and can(p, "reading_sync") then
            log(reason .. ": OrbiSmart pull, then the outbox; network ready in", fmt(now_s() - t0))
            return OSM.pullThenDrain(p, "wake", "orbit_" .. reason, function()
                UIManager:scheduleIn(1, function() Sync.waitOutbox(p, 20, function() Wifi.release(lease) end) end)
            end)
        end
        if can(p, "outbox") then p:requestLifecycleOutboxDrain("orbit_" .. reason) end
        -- Hold Wi-Fi until the plugin's drain and pull are done, then restore.
        UIManager:scheduleIn(1, function()
            Sync.waitOutbox(p, 20, function() Wifi.release(lease) end)
        end)
        if inBook() and can(p, "wake_pull") then
            -- The plugin debounces pulls for 25 s (bookorbit_progress_sync.lua:26, 383-387).
            -- Clear it for this one pull; on a fresh start skip it if a pull already ran.
            Sync.clearPullDebounce(p, reason)
            p:requestProgressPull(false, false, "orbit_" .. reason)
            log(reason .. ": asked plugin to drain outbox and pull, network ready in", fmt(now_s() - t0))
        else
            log(reason .. ": asked plugin to drain outbox (no book open), network ready in", fmt(now_s() - t0))
        end
    end)
end

function OrbitAndroid:showWakeBanner(res)
    local text = _("Can't reach BookOrbit. Reading from this device's place.") .. "\n" .. (res.detail or "")
    local retry = function() self:wakeFlow("retry") end
    local okt, Toast = pcall(require, "bookorbit_toast")
    Gate.show("wake banner: " .. text, function()
        if okt then
            Toast.error(text, retry, { timeout = 6 }) -- gate: Gate.show
        else
            UIManager:show(InfoMessage:new{ text = text, timeout = 6 }) -- gate: Gate.show
        end
    end, 60)
end

---------------------------------------------------------------------------------------------

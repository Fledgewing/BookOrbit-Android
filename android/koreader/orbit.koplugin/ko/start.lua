-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
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
    log("resume", state.paused_for and ("after " .. fmt(state.paused_for) .. " in the background") or "")
    Clicks.install("resume")
    UIManager:scheduleIn(0.3, function()
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
    if not S.sync_on_wake then
        log(reason .. ": sync on wake is off")
        if NetworkMgr:isConnected() then Updater.maybeAuto(reason) end
        return
    end
    local p = bookorbit(self.ui)
    if not p or not p:isLoggedIn() then
        log(reason .. ": BookOrbit plugin missing or signed out; nothing to do")
        if NetworkMgr:isConnected() then Updater.maybeAuto(reason) end
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
        if can(p, "outbox") then p:requestLifecycleOutboxDrain("orbit_" .. reason) end
        Updater.maybeAuto(reason)
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
    if okt then
        Toast.error(text, retry, { timeout = 6 })
    else
        UIManager:show(InfoMessage:new{ text = text, timeout = 6 })
    end
end

---------------------------------------------------------------------------------------------

-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Wake / start
---------------------------------------------------------------------------------------------

function OrbitAndroid:onResume()
    if ReadingSync then ReadingSync.resume(self.ui) end
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
    UIManager:scheduleIn(2, function() Gate.drain("resume") end)
    UIManager:scheduleIn(0.3, function()
        if Library then Library.accountReturned() end
        Shared.refresh("resume")
        Wifi.applySettings("resume")
        self:checkCommand("resume")
        self:maybeRestart("check")
        self:maybeSetupPrompt("resume")
        -- Also after "home": the closed book's sync needs the network.
        self:wakeFlow("wake")
    end)
end

function OrbitAndroid:wakeFlow(reason)
    if ReadingSync.on() and reason=="wake" and state.paused_for and state.paused_for<300 then return end
    if not S.sync_on_wake then return end
    Wifi.acquire("wake")
    Net.up(nil,{reason=reason,cap=20},function(ok,res)
        ReadingSync.run("wake",function(synced,why)
            Wifi.release("wake")
            Library.idle()
            if not ok then self:showWakeBanner(res) end
        end)
    end)
end



---------------------------------------------------------------------------------------------

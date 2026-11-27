-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

OrbitAndroid = WidgetContainer:extend{
    name = "orbit", -- PluginLoader names it after its folder, orbit.koplugin
    fullname = "BookSync",
    is_doc_only = false,
}

function OrbitAndroid:init()
    state.module = self
    Library.backgroundCommand("views.install","init")
    Clicks.install("init")
    keepRotationOnFileBrowser("init")
    if not state.start_patch_checked then
        state.start_patch_checked = true
        pcall(installStartPatch, "init")
    end
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then self.ui.menu:registerToMainMenu(self) end
    local in_reader = self.ui ~= nil and self.ui.document ~= nil
    self.schedule = Schedule.new(S.reading_schedule, now_s())
    -- A Sync while reading change from the companion (Shared.refresh) restarts this counter.
    Shared.onSchedule = function(id)
        self.schedule = Schedule.new(id, now_s())

    end

    ReadingSync.activate()
    if not state.started then
        state.started = true
        log("start: KOReader started (treated as a wake)", in_reader and "in reader" or "in file browser")
        UIManager:scheduleIn(0.8, function()
            Shared.refresh("start")
            Shared.push("start") -- the companion shows the patch's Sync while reading
            Wifi.applySettings("start")
            self:maybeSetupPrompt("start")
        end)
        UIManager:scheduleIn(1, function()
            if Library then Library.accountReturned() end
            local handled = self:checkCommand("start")
            if S.restart_book ~= nil then
                if handled then S.restart_book = nil; saveSettings() else self:reopenAfterRestart("start") end
            end
            self:maybeRestart("check")
        end)
        UIManager:scheduleIn(1.5, function() self:wakeFlow("start") end)
        -- Recommended settings: after the BookOrbit plugin's init (and its next-tick fallback).
        UIManager:scheduleIn(1.2, function() self:recommendedPass("start") end)
        UIManager:scheduleIn(Stats.INTERVAL, statsTick)
    elseif state.pending_home and not in_reader then
        UIManager:scheduleIn(1, function() self:finishHome() end)
    end
end

function OrbitAndroid:onDispatcherRegisterActions()
    Dispatcher:registerAction("orbit_sync_and_sleep",
        { category = "none", event = "OrbitSyncAndSleep", title = _("BookSync: sync and sleep"), general = true })
    Dispatcher:registerAction("orbit_go_home",
        { category = "none", event = "OrbitGoHome", title = _("BookSync: go to library home"), general = true })
    Dispatcher:registerAction("orbit_open_companion",
        { category = "none", event = "OrbitOpenCompanion", title = _("BookSync: open BookSync Companion"), general = true })
    Dispatcher:registerAction("orbit_open_apps",
        { category = "none", event = "OrbitOpenApps", title = _("BookSync Companion: apps"), general = true, separator = true })
end

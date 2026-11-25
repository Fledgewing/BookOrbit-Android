-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

OrbitAndroid = WidgetContainer:extend{
    name = "orbit", -- PluginLoader names it after its folder, orbit.koplugin
    fullname = "Orbit",
    is_doc_only = false,
}

function OrbitAndroid:init()
    state.module = self
    Grouping.install("init")
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
    if in_reader then
        -- The BookOrbit plugin's instance comes first when both sit in one plugins folder
        -- (PluginLoader sorts by path); elsewhere it may come later: hook it once it exists.
        if self.ui.bookorbit then self:hookPluginPagePush()
        else UIManager:nextTick(function() self:hookPluginPagePush() end) end
    end
    -- A Sync while reading change from the companion (Shared.refresh) restarts this counter.
    Shared.onSchedule = function(id)
        self.schedule = Schedule.new(id, now_s())
        if self.ui and self.ui.document then self:hookPluginPagePush() end
    end

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
        { category = "none", event = "OrbitSyncAndSleep", title = _("Orbit: sync and sleep"), general = true })
    Dispatcher:registerAction("orbit_go_home",
        { category = "none", event = "OrbitGoHome", title = _("Orbit: go to BookOrbit home"), general = true })
    Dispatcher:registerAction("orbit_open_companion",
        { category = "none", event = "OrbitOpenCompanion", title = _("Orbit: open Orbit Companion"), general = true })
    Dispatcher:registerAction("orbit_open_apps",
        { category = "none", event = "OrbitOpenApps", title = _("Orbit Companion: apps"), general = true, separator = true })
end

-- "Sync while reading" replaces the plugin's every-few-pages push while it is on.
-- The plugin's every-few-pages push is its user setting "Push while reading"
-- (settings.pages_before_update, bookorbit_settings_page.lua:259-260; read by _onPageUpdate,
-- main.lua:1322-1324; 0 = off). While our Sync while reading is on we set it to 0 and keep the
-- reader's value; when it goes off we put that value back (unless they changed it meanwhile).
function OrbitAndroid:hookPluginPagePush()
    local p = bookorbit(self.ui)
    if not p or type(p.settings) ~= "table" then return end
    local cur = p.settings.pages_before_update
    -- OrbiSmart pushes at a pause instead (docs/design/orbismart.md §3.3).
    if S.reading_schedule ~= "off" or (OSM and OSM.on()) then
        if S.saved_pages_before_update == nil and (cur or 0) > 0 then
            S.saved_pages_before_update = cur
            p.settings.pages_before_update = 0
            saveSettings()
            log("page push: plugin's Push while reading", cur, "-> off while Sync while reading is on")
        end
    elseif S.saved_pages_before_update ~= nil then
        if (cur or 0) == 0 then
            p.settings.pages_before_update = S.saved_pages_before_update
            log("page push: plugin's Push while reading restored to", S.saved_pages_before_update)
        end
        S.saved_pages_before_update = nil
        saveSettings()
    end
end

---------------------------------------------------------------------------------------------

-- SPDX-License-Identifier: AGPL-3.0-or-later
function Library.initializePlugin(self)
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
        UIManager:scheduleIn(1.2, function() self:recommendedPass("start") end)
        UIManager:scheduleIn(Stats.INTERVAL, statsTick)
    elseif state.pending_home and not in_reader then
        UIManager:scheduleIn(1, function() self:finishHome() end)
    end
end


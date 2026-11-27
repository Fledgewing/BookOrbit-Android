-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Sleep (Suspend)
---------------------------------------------------------------------------------------------

function OrbitAndroid:onSuspend()
    ReadingSync.queue("suspend",self.ui)
    -- Screen off or another app in front: KOReader isn't being read until Resume.
    if stats_acc.at then
        Stats.send("suspend", nil, false)
        stats_acc.at = nil
    end
    state.suspended_at = now_s()
    Wifi.state().foreground = false
    -- A real sleep (the screen went off, not an app switch): the wake tells the companion (Sleep.woke).
    if Jni.isInteractive() == false then state.slept = true end
    UIManager:scheduleIn(1, function() if Jni.isInteractive() == false then state.slept = true end end)
    -- A patch update waiting for the book: the device sleeping is the moment (after any sleep sync).
    if patchFileVersion() and RestartPlan.decide(patchFileVersion(), PATCH_VERSION, S.restart_tried, true, "check") == "wait" then
        UIManager:scheduleIn(1.5, function()
            if Jni.isInteractive() ~= false then return end
            if state.sleep_syncing then
                state.restart_after_sync = true
            else
                self:maybeRestart("sleep")
            end
        end)
    end
    -- Another app in front (still there two seconds on; a Home press comes straight back): an
    -- automatic update waiting on disk saves and quits, and loads at the next start.
    if patchFileVersion() then
        UIManager:scheduleIn(2, function()
            if Wifi.state().foreground == false and Jni.isInteractive() == true then
                pcall(self.maybeRestart, self, "background")
            end
        end)
    end
    if not S.sync_on_sleep then return end
    if now_s() - state.sas_done_at < 15 then
        log("suspend: just synced by Sync and sleep; skip")
        return
    end
    local screen_on = Jni.isInteractive()
    if screen_on == true then
        -- Switching apps also sends Suspend. Look again in a moment before giving up.
        UIManager:scheduleIn(1, function()
            if Jni.isInteractive() == true then
                log("suspend: screen still on (app switch); no sleep sync")
            else
                self:sleepSync("sleep")
            end
        end)
        return
    end
    self:sleepSync("sleep")
end

function OrbitAndroid:sleepSync(reason)
    local cap = S.sleep_cap or 20
    local t0 = now_s()
    log(reason .. ": sleep sync start, cap", cap .. "s")
    local held = false
    state.sleep_syncing = true
    local function done(ok, detail)
        state.sleep_syncing = false
        if state.restart_after_sync then
            state.restart_after_sync = false
            UIManager:scheduleIn(1, function() self:maybeRestart("sleep") end)
        end
        local seconds = now_s() - t0
        S.last_sleep_sync = { at = os.time(), ok = ok, seconds = seconds, reason = reason, detail = detail }
        saveSettings()
        local restore = held and Wifi.state().restore_off and Wifi.state().n == 1 and "off" or ""
        log(reason .. ": sleep sync", ok and "done" or "FAILED", "in", fmt(seconds), detail or "",
            restore == "off" and "| Wi-Fi was off before: companion restores off" or "")
        Companion.netDone(reason, ok, seconds, detail, restore)
        if held then Wifi.release("sleep", true) end
    end
    Wifi.acquire("sleep")
    held=true
    Net.up(nil,{reason=reason,cap=cap,wake_lock_s=cap+5},function()
        ReadingSync.run("sleep",done)
    end)
end

---------------------------------------------------------------------------------------------
-- "Sync and sleep"
---------------------------------------------------------------------------------------------

function sleepNow(reason)
    if Companion.has("screen_off") then
        Companion.send(Companion.ACTION.SLEEP_NOW, { reason = reason })
    elseif Companion.installed() then
        log("sleep now: the companion can't turn the screen off here; asking for the power button")
        local text = _("Synced. Press the power button to sleep.")
        if not S.screen_off_hint_shown then
            S.screen_off_hint_shown = true
            saveSettings()
            text = text .. "\n" .. _("BookSync Companion can do this for you: Screen off after Sync and sleep.")
        end
        ServiceNotices.showInfo({ text = text, timeout = 4 }) -- gate: user action (Sync and sleep)
    else
        log("sleep now: no companion; asking the reader to press the power button")
        ServiceNotices.showInfo({ -- gate: user action (Sync and sleep)
            text = _("Synced. Press the power button to sleep.\n(Install BookSync Companion to turn the screen off by itself.)"),
            timeout = 4,
        })
    end
end

function OrbitAndroid:onOrbitSyncAndSleep(stay_awake)
    stay_awake = stay_awake == true -- explicit Sync now; dispatcher events retain Sync and sleep
    local flow = stay_awake and "menu_sync" or "sync_and_sleep"
    if self.sas_running then return true end
    self.sas_running = true
    local cancelled, closing = false, false
    local cap = S.sleep_cap or 20
    local t0 = now_s()
    log("sync and sleep: start")
    local msg = ServiceNotices.progress{
        text = _("Syncing…") .. (stay_awake and "" or ("\n" .. _("Then sleep"))),
        dismiss_callback = function()
            if not closing then
                cancelled = true
                log("sync and sleep: cancelled by tap; screen stays on")
            end
        end,
    }

    local function finish(ok, detail)
        self.sas_running = false
        closing = true
        UIManager:close(msg)
        local seconds = now_s() - t0
        S.last_sleep_sync = { at = os.time(), ok = ok, seconds = seconds, reason = flow, detail = detail }
        saveSettings()
        local restore = self.sas_held and Wifi.state().restore_off and Wifi.state().n == 1 and "off" or ""
        log("sync and sleep:", ok and "synced" or "FAILED", "in", fmt(seconds), detail or "",
            restore == "off" and "| Wi-Fi was off before: companion restores off" or "")
        Companion.netDone(flow, ok, seconds, detail, restore)
        if self.sas_held then
            self.sas_held = false
            Wifi.release("sync_and_sleep", not stay_awake)
        end
        if cancelled then return end
        if stay_awake then
            ServiceNotices.showInfo({ -- gate: user action (Sync now)
                text = ok and _("Synced.") or _("Couldn't reach the server — saved on this device. It sends at the next sync."),
                timeout = 3,
            })
            return
        end
        state.sas_done_at = now_s()
        if ok then
            sleepNow("sync_and_sleep")
        else
            ServiceNotices.showInfo({ -- gate: user action (Sync and sleep)
                text = _("Couldn't reach the server — saved on this device.") .. "\n"
                    .. _("It sends first when you next wake it. Sleeping now…"),
                timeout = 3,
            })
            UIManager:scheduleIn(3, function()
                state.sas_done_at = now_s()
                sleepNow("sync_and_sleep_failed")
            end)
        end
    end

    Wifi.acquire("sync_and_sleep")
    self.sas_held=true
    Net.up(nil,{reason=flow,cap=cap,wake_lock_s=cap+5},function()
        if cancelled then return finish(false,"cancelled") end
        ReadingSync.run(stay_awake and "manual" or "sleep",function(ok,why)
            if cancelled then return finish(false,"cancelled") end
            finish(ok,why)
        end)
    end)
    return true
end

---------------------------------------------------------------------------------------------

-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Sleep (Suspend)
---------------------------------------------------------------------------------------------

function OrbitAndroid:onSuspend()
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
    if not S.sync_on_sleep and not (OSM and OSM.on()) then return end
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

-- BookOrbit snapshots the open book into its outbox on every Suspend (main.lua:1340-1351), and
-- Android sends Suspend on every app switch: each press of the Home key bounces through the
-- companion's launcher and back (logged "home press: START_KOREADER"), so every press synced the
-- book again ("book sync done reason=recovery", the label every outbox drain carries,
-- bookorbit_book_sync.lua:169). With the screen on, a snapshot of a book that hasn't moved since
-- its last one is skipped; a real sleep, a close and Sync and sleep always snapshot.
function snapshotKey(p, ui)
    local okd, digest = pcall(p.getDocumentDigest, p)
    if not okd or not digest then return nil end
    local okp, pct = pcall(p.getLastPercent, p)
    local ann = ui and ui.annotation and ui.annotation.annotations
    local okst, status = pcall(function() return ui.doc_settings:readSetting("summary").status end)
    return table.concat({ tostring(digest), tostring(okp and pct or "?"), tostring(p.last_page or "?"),
        tostring(type(ann) == "table" and #ann or "?"), tostring(okst and status or "?") }, "|")
end

function OrbitAndroid:hookSuspendSnapshot()
    local p = bookorbit(self.ui)
    if not p or type(p._onSuspend) ~= "function" or rawget(p, "_orbit_snapshot_hooked") then return end
    local orig = p._onSuspend
    p._orbit_snapshot_hooked = true
    p._onSuspend = function(plugin, ...)
        local key = snapshotKey(plugin, self.ui)
        if not state.force_snapshot and key and key == state.last_snapshot_key and Jni.isInteractive() == true then
            log("suspend: app switch and the book hasn't moved since its last snapshot; BookOrbit's snapshot skipped")
            return
        end
        state.last_snapshot_key = key
        return orig(plugin, ...)
    end
    if p.onSuspend == orig then p.onSuspend = p._onSuspend end
end

function OrbitAndroid:sleepSync(reason)
    local cap = S.sleep_cap or 20
    local t0 = now_s()
    local p = bookorbit(self.ui)
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
    if not p or not p:isLoggedIn() then
        return done(false, "BookOrbit plugin missing or signed out")
    end
    Wifi.acquire("sleep")
    held = true
    Net.up(p, { reason = reason, cap = cap, need_server = true, wake_lock_s = cap + 5 }, function(ok, res)
        if not ok then return done(false, res.detail) end
        -- OrbiSmart: pull first, so the behind-hold judges the snapshot against the server's place.
        if OSM and OSM.on() and inBook() and can(p, "reading_sync") then
            return OSM.pullThenDrain(p, "sleep", "orbit_" .. reason, function()
                Sync.waitOutbox(p, math.max(1, cap - (now_s() - t0)), function(synced, why) done(synced, why) end)
            end)
        end
        -- The plugin queued its snapshot in its own _onSuspend (main.lua:1340-1351) but drains
        -- only when already connected (main.lua:411-419). Now we are: drain and wait.
        if can(p, "outbox") then p:requestLifecycleOutboxDrain("orbit_" .. reason) end
        Sync.waitOutbox(p, math.max(1, cap - (now_s() - t0)), function(synced, why)
            done(synced, why)
        end)
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
        UIManager:show(InfoMessage:new{ text = text, timeout = 4 }) -- gate: user action (Sync and sleep)
    else
        log("sleep now: no companion; asking the reader to press the power button")
        UIManager:show(InfoMessage:new{ -- gate: user action (Sync and sleep)
            text = _("Synced. Press the power button to sleep.\n(Install BookSync Companion to turn the screen off by itself.)"),
            timeout = 4,
        })
    end
end

function OrbitAndroid:onOrbitSyncAndSleep()
    if self.sas_running then return true end
    self.sas_running = true
    local cancelled, closing = false, false
    local cap = S.sleep_cap or 20
    local t0 = now_s()
    log("sync and sleep: start")
    local msg = InfoMessage:new{
        text = _("Syncing…") .. "\n" .. _("BookOrbit · then sleep"),
        dismiss_callback = function()
            if not closing then
                cancelled = true
                log("sync and sleep: cancelled by tap; screen stays on")
            end
        end,
    }
    UIManager:show(msg) -- gate: user action (Sync and sleep)
    UIManager:forceRePaint()

    local function finish(ok, detail)
        self.sas_running = false
        closing = true
        UIManager:close(msg)
        local seconds = now_s() - t0
        S.last_sleep_sync = { at = os.time(), ok = ok, seconds = seconds, reason = "sync_and_sleep", detail = detail }
        saveSettings()
        local restore = self.sas_held and Wifi.state().restore_off and Wifi.state().n == 1 and "off" or ""
        log("sync and sleep:", ok and "synced" or "FAILED", "in", fmt(seconds), detail or "",
            restore == "off" and "| Wi-Fi was off before: companion restores off" or "")
        Companion.netDone("sync_and_sleep", ok, seconds, detail, restore)
        if self.sas_held then
            self.sas_held = false
            Wifi.release("sync_and_sleep", true)
        end
        if cancelled then return end
        state.sas_done_at = now_s()
        if ok then
            sleepNow("sync_and_sleep")
        else
            UIManager:show(InfoMessage:new{ -- gate: user action (Sync and sleep)
                text = _("Couldn't reach BookOrbit — saved on this device.") .. "\n"
                    .. _("It sends first when you next wake it. Sleeping now…"),
                timeout = 3,
            })
            UIManager:scheduleIn(3, function()
                state.sas_done_at = now_s()
                sleepNow("sync_and_sleep_failed")
            end)
        end
    end

    local p = bookorbit(self.ui)
    if not p or not p:isLoggedIn() then
        finish(false, "BookOrbit plugin missing or signed out")
        return true
    end
    Wifi.acquire("sync_and_sleep")
    self.sas_held = true
    Net.up(p, { reason = "sync_and_sleep", cap = cap, need_server = true, wake_lock_s = cap + 5 }, function(ok, res)
        if cancelled then return finish(false, "cancelled") end
        if not ok then return finish(false, res.detail) end
        if inBook() and can(p, "sleep_snapshot") then
            -- Exactly what the plugin does on sleep: snapshot the open book into its
            -- durable outbox and drain it (main.lua:1340-1351).
            state.force_snapshot = true
            pcall(p._onSuspend, p)
            state.force_snapshot = nil
        elseif can(p, "outbox") then
            p:requestLifecycleOutboxDrain("orbit_sync_and_sleep", true)
        end
        Sync.waitOutbox(p, math.max(1, cap - (now_s() - t0)), function(synced, why)
            if cancelled then return finish(false, "cancelled") end
            finish(synced, why)
        end)
    end)
    return true
end

---------------------------------------------------------------------------------------------

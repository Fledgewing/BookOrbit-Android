-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Wi-Fi modes: when to ask the companion for Wi-Fi on or off (WifiPlan above decides).
-- Every decision is logged with its reason and the mode, so a battery day can be audited:
--   adb logcat | grep -E "OrbitAndroid: wifi|OrbitCompanion: wifi"
---------------------------------------------------------------------------------------------

Wifi = { plan = nil, inflight_http = 0, ticking = false, tx = nil }
TICK_S = 15

function Wifi.state()
    if not Wifi.plan then
        Wifi.plan = WifiPlan.new(Shared.mode(), S.wifi_idle_min, now_s())
        log("wifi: mode", Wifi.plan.mode, "idle", S.wifi_idle_min .. " min")
    end
    return Wifi.plan
end

-- Settings changed (menu or companion): keep the state, swap mode and idle time.
function Wifi.applySettings(why)
    local st = Wifi.state()
    local mode = Shared.mode()
    local idle = (tonumber(S.wifi_idle_min) or 2) * 60
    if st.mode ~= mode or st.idle_s ~= idle then
        log("wifi: mode", st.mode, "->", mode, "idle", math.floor(idle / 60) .. " min (" .. why .. ")")
        st.mode, st.idle_s = mode, idle
        st.last_activity = now_s()
    end
    Wifi.kick()
end

-- The radio state: Jni first (the radio), KOReader's "connected" as a fallback.
function Wifi.radioOn()
    local on = Jni.wifiEnabled()
    if on == nil then on = NetworkMgr:isConnected() end
    return on
end

-- tx_packets of wlan0 when the firmware lets apps read it (NetworkListener reads the same
-- counter for auto_disable_wifi, networklistener.lua:101-113, but only where KOReader knows the
-- interface name, which it doesn't on Android: networklistener.lua:184-185).
function txPackets()
    local f = io.open("/sys/class/net/wlan0/statistics/tx_packets", "rb")
    if not f then return nil end
    local n = f:read("*number")
    f:close()
    return n
end

function Wifi.busy()
    if Wifi.inflight_http > 0 then return true, "download in progress" end
    -- The cache's background checks and the offline mirror run in child processes, which this
    -- process's request counter never sees.
    if OC and OC.busy then
        local okc, why = pcall(OC.busy)
        if okc and why then return true, why end
    end
    local p = bookorbit()
    if p and can(p, "outbox") then
        local okb, busy = pcall(function()
            local c = p:getSyncCoordinator()
            if c:isBusy() or c:queuedCount() > 0 then return true end
            local d = p:getLifecycleOutbox():diagnostics()
            return outboxPending(d) > 0
        end)
        if okb and busy then return true, "BookOrbit plugin syncing" end
    end
    return false
end

function Wifi.activity(what)
    local st = Wifi.state()
    WifiPlan.activity(st, now_s())
    if what then log("wifi: activity", what) end
    Wifi.kick()
end

function Wifi.acquire(name)
    local st = Wifi.state()
    local on = Wifi.radioOn()
    WifiPlan.acquire(st, name, on, now_s())
    log("wifi: hold for", name, "(Wi-Fi was", on == false and "off" or "on", ") mode", st.mode)
    return on
end

-- handled: the companion restores (sleep sync). Returns whether a restore to off is pending.
function Wifi.release(name, handled)
    local st = Wifi.state()
    WifiPlan.release(st, name, now_s(), handled)
    log("wifi: release", name, handled and "(companion restores)" or "", "mode", st.mode)
    Wifi.kick()
    if st.n == 0 and st.release_at then
        UIManager:scheduleIn(WifiPlan.GRACE + 0.1, function() Wifi.evaluate("after " .. name) end)
    end
    return st.restore_off and st.n == 0
end

-- Decide now; ask the companion when the answer is "off".
function Wifi.evaluate(why)
    local st = Wifi.state()
    if not Companion.has("wifi") then return nil, "no Wi-Fi switching" end
    local wifi_on = Wifi.radioOn()
    if wifi_on == false then
        if st.restore_off or st.release_at or st.force_off_once then WifiPlan.wifiOff(st) end
        return nil, "already off"
    end
    local tx = txPackets()
    if tx and Wifi.tx and tx - Wifi.tx > 10 then WifiPlan.activity(st, now_s()) end
    Wifi.tx = tx
    local busy, busy_why = Wifi.busy()
    local screen_off = Jni.isInteractive() == false
    local okb, browsing = pcall(function() return catalogOnTop(bookorbit()) end)
    local action, reason, force = WifiPlan.decide(st, { now = now_s(), wifi_on = wifi_on, busy = busy,
        screen_off = screen_off, browsing = okb and browsing == true })
    if action == "off" then
        log("wifi: OFF decided:", reason, "| mode", st.mode, force and "| forced" or "| only if turned on automatically", "(" .. why .. ")")
        Wifi.off_decided_at = now_s()
        Companion.wifiOff(reason, not force)
        WifiPlan.wifiOff(st)
        -- If the companion keeps it (turned on by hand), wait a full idle period before asking again.
        st.last_activity = now_s()
    elseif busy and st.release_at and now_s() >= st.release_at then
        log("wifi: kept on while", busy_why, "| mode", st.mode)
    end
    return action, reason
end

-- A cheap loop that only runs while Wi-Fi is on or a restore is pending.
function Wifi.kick()
    if Wifi.ticking or not Companion.has("wifi") then return end
    Wifi.ticking = true
    local function tick()
        local st = Wifi.state()
        local action, reason = Wifi.evaluate("timer")
        local pending = st.n > 0 or st.release_at ~= nil or st.force_off_once
        if not pending and (reason == "already off" or st.mode ~= "jit") then
            Wifi.ticking = false
            return
        end
        UIManager:scheduleIn((st.release_at and st.release_at > now_s()) and math.max(0.5, st.release_at - now_s() + 0.1) or TICK_S, tick)
    end
    UIManager:scheduleIn(0.5, tick)
end

-- Every HTTP(S) request KOReader makes counts as network activity, and an in-flight one
-- (a download) blocks Wi-Fi off. Wraps the module tables, so callers that look up
-- http.request at call time (all of KOReader's) are covered.
function pack(...) return { n = select("#", ...), ... } end

function wrapRequests(modname)
    local okm, mod = pcall(require, modname)
    if not okm or type(mod) ~= "table" or type(mod.request) ~= "function" or mod._orbit_wrapped then return end
    local orig = mod.request
    mod._orbit_wrapped = true
    mod.request = function(...)
        Wifi.inflight_http = Wifi.inflight_http + 1
        if Wifi.plan then WifiPlan.activity(Wifi.plan, now_s()) end
        local r = pack(pcall(orig, ...))
        Wifi.inflight_http = Wifi.inflight_http - 1
        if Wifi.plan then WifiPlan.activity(Wifi.plan, now_s()) end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, r.n)
    end
end

---------------------------------------------------------------------------------------------

-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Wi-Fi on/off through the companion (KOReader's Android backend only opens Settings,
-- frontend/device/android/device.lua:316-327)
---------------------------------------------------------------------------------------------

stock_turnOnWifi = NetworkMgr.turnOnWifi
stock_turnOffWifi = NetworkMgr.turnOffWifi

function NetworkMgr:turnOnWifi(complete_callback, interactive)
    if not S.wifi_via_companion then
        return stock_turnOnWifi(self, complete_callback, interactive)
    end
    if Companion.has("wifi") then
        -- interactive: the reader's own Wi-Fi toggle (manager.lua:433 toggleWifiOn), so it is
        -- theirs to turn off. Otherwise beforeWifiAction/runWhenOnline (manager.lua:605-619,
        -- 698-719) needs the network for something: just in time may turn it off again.
        local owner = interactive and "manual" or "auto"
        log("wifi: ON requested by KOReader (" .. owner .. ") | mode", Shared.mode())
        Wifi.activity()
        Companion.netUp("koreader_wifi_on", { owner = owner })
    elseif interactive then
        return stock_turnOnWifi(self, complete_callback, interactive)
    else
        log("wifi on: no companion; waking Tailscale and waiting for Android's Wi-Fi")
        if S.wake_tailscale then tailscaleConnect("koreader_wifi_on") end
    end
    -- KOReader's connectivity check now polls and broadcasts NetworkConnected
    -- (frontend/ui/network/manager.lua:82-133).
    if complete_callback then complete_callback() end
end

function NetworkMgr:turnOffWifi(complete_callback)
    if S.wifi_via_companion and Companion.has("wifi") then
        log("wifi: OFF requested by KOReader's own toggle | mode", Shared.mode())
        Companion.wifiOff("koreader_wifi_off", false)
        if complete_callback then complete_callback() end
        return
    end
    return stock_turnOffWifi(self, complete_callback)
end

-- KOReader's Android backend calls "connected" Wi-Fi on (device.lua:341). With the companion we
-- know the radio itself, so the menu toggle and turnOnWifiAndWaitForConnection
-- (manager.lua:517-567) see real state.
stock_isWifiOn = NetworkMgr.isWifiOn
function NetworkMgr:isWifiOn()
    if S.wifi_via_companion and Companion.has("wifi") then
        local on = Jni.wifiEnabled()
        if on ~= nil then return on end
    end
    return stock_isWifiOn(self)
end

-- Anything that asks for the network through KOReader's framework (the plugin's catalog and
-- downloads, OPDS, updates) counts as activity for just in time.
stock_beforeWifiAction = NetworkMgr.beforeWifiAction
function NetworkMgr:beforeWifiAction(callback)
    Wifi.activity("KOReader needs the network")
    return stock_beforeWifiAction(self, callback)
end

-- No "Turn on Wi-Fi?" prompt, in every Wi-Fi mode, when the companion can switch Wi-Fi:
-- beforeWifiAction then calls turnOnWifiAndWaitForConnection (manager.lua:609-611), whose
-- turnOnWifi goes to the companion. Without a usable companion, KOReader's stock behaviour stays.
-- KOReader's turn_on path shows a centred "Connecting to Wi-Fi…" InfoMessage until the
-- connection is up (frontend/ui/network/manager.lua:539-541, closed at :110-113 or replaced by
-- "Error connecting to the network" at :88-92). It runs for every beforeWifiAction
-- (manager.lua:605-619), e.g. the plugin's resume pull, which asks for the network 1 s after
-- each wake (bookorbit.koplugin main.lua:1329-1337 -> requestProgressPull(true, ...) ->
-- willRerunWhenConnected, bookorbit_progress_sync.lua:389). With Wi-Fi off after a sleep
-- sync or "just in time", that flashed on every wake. With the companion, the same steps run
-- without the message: ask for Wi-Fi (requestToTurnOnWifi, manager.lua:67-78), then the
-- stock connectivity check with no widget (:82-133), which shows nothing on success and
-- nothing on its 45 s give-up; a wake that can't connect still gets the patch's own banner.
stock_turnOnWifiAndWait = NetworkMgr.turnOnWifiAndWaitForConnection
function NetworkMgr:turnOnWifiAndWaitForConnection(callback)
    if not (S.wifi_via_companion and Companion.has("wifi")) or not self.requestToTurnOnWifi
            or not self.scheduleConnectivityCheck then
        return stock_turnOnWifiAndWait(self, callback)
    end
    if self:isWifiOn() and self:isConnected() then
        local fresh = not self.hasLeaseForCurrentNetwork or self:hasLeaseForCurrentNetwork()
        if fresh then
            if callback then callback() end
            return
        end
        if self.releaseIP then self:releaseIP() end
        self.lease_ssid = nil
    end
    log("wifi: KOReader needs the network; bringing it up quietly (no Connecting message) | mode", Shared.mode())
    local status = self:requestToTurnOnWifi(function()
        if self.pending_connectivity_check then self:unscheduleConnectivityCheck() end
        self:scheduleConnectivityCheck(callback)
    end)
    if status == false then
        log("wifi: quiet bring-up failed to start")
        if self._abortWifiConnection then self:_abortWifiConnection() end
        return false
    end
end

-- KOReader's "Action when Wi-Fi is off" → Turn on, through the recommended-settings engine
-- (ko/recommended.lua silentWifiOn): only at KOReader's default, with a backup.
silentWifiOn()

wrapRequests("socket.http")
wrapRequests("ssl.https")

---------------------------------------------------------------------------------------------

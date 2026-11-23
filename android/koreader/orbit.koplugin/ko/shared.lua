-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Settings shared with the companion (Wi-Fi mode, idle minutes, Home button). The companion
-- stores them; the patch reads them from its loopback status and sends changes made in its
-- own menu with a SETTINGS broadcast. Newest change wins (settings_at, ms).
---------------------------------------------------------------------------------------------

Shared = {}
-- The /clicks channel's state (filled in below, "The /clicks channel").
Channel = { up = false, service_on = false, buf = "" }

function Shared.defaultMode()
    return Companion.installed() and "jit" or "always_on"
end

function Shared.mode()
    if not Companion.installed() then return "always_on" end -- nothing can switch Wi-Fi
    return WifiPlan.validMode(S.wifi_mode) and S.wifi_mode or Shared.defaultMode()
end

-- Pull the companion's copy if it is newer. Cheap: loopback, 1 s timeout.
-- "Orbit Companion: 1 setup step needs you", or nil.
function Shared.setupNeededText()
    local n = Shared.setup_needed
    if not n or n < 1 or not Companion.installed() then return nil end
    return string.format(n == 1 and _("Orbit Companion: %d setup step needs you (open the companion)")
        or _("Orbit Companion: %d setup steps need you (open the companion)"), n)
end

function Shared.refresh(why)
    if not Companion.installed() then return false end
    local st = Companion.status(1)
    -- Clicker buttons: the companion's key map (an empty map turns ours off).
    if st then
        local m = Clicks.parse(st.keymap)
        local n = 0
        for _ in pairs(m) do n = n + 1 end
        if n ~= Clicks.count or why == "start" then log("clicker: key map from the companion,", n, "key(s) (" .. why .. ")") end
        Clicks.map, Clicks.count = m, n
        -- One path: the channel (when the companion has it) lets its service drive KOReader.
        if st.clicker_service ~= nil then Shared.clicker_service = st.clicker_service == true end
        if n > 0 and not Channel.up then pcall(Channel.connect, why) end
    end
    -- "Setup needs you": the count in the menu status; setup_prompt for the one-time box.
    Shared.setup_needed = st and tonumber(st.setup_needed) or nil
    Shared.setup_prompt = st and type(st.setup_prompt) == "table" and st.setup_prompt or nil
    -- The companion's "Home opens": koreader, launcher or app (nil: unknown, older companion).
    local so = st and type(st.settings) == "table" and st.settings.home_opens or nil
    Shared.home_opens = (so == "koreader" or so == "launcher" or so == "app") and so or nil
    -- Sync while reading set in the companion: apply and save it here, then tell the companion.
    local req_id, req_at = Schedule.request(st and st.reading_schedule_request, S.reading_schedule_request_at)
    if req_id then
        local was = S.reading_schedule
        S.reading_schedule, S.reading_schedule_request_at = req_id, req_at
        saveSettings()
        log("setting reading_schedule =", req_id, "(from the companion, was " .. tostring(was) .. ", " .. why .. ")")
        if Shared.onSchedule then pcall(Shared.onSchedule, req_id) end
        Shared.push("reading schedule from the companion")
    end
    -- Settings PIN: locked only on the companion's word; no answer = unlocked (MenuLock).
    Shared.pin_locked = MenuLock.locked(st)
    -- The companion's lockdown reading (true/false; nil: unknown or no companion).
    if st then Shared.vpn_lockdown = type(st.vpn_lockdown) == "boolean" and st.vpn_lockdown or nil end
    local remote = st and type(st.settings) == "table" and st.settings or nil
    if not remote then return false end
    local at = tonumber(remote.settings_at) or 0
    if at > (S.shared_settings_at or 0) then
        local changed = {}
        if WifiPlan.validMode(remote.wifi_mode) and remote.wifi_mode ~= S.wifi_mode then
            S.wifi_mode = remote.wifi_mode; table.insert(changed, "wifi_mode=" .. remote.wifi_mode)
        end
        local idle = tonumber(remote.wifi_idle_min)
        if idle and idle ~= S.wifi_idle_min then S.wifi_idle_min = idle; table.insert(changed, "wifi_idle_min=" .. idle) end
        if (remote.home_button == "smart" or remote.home_button == "bookorbit") and remote.home_button ~= S.home_button then
            S.home_button = remote.home_button; table.insert(changed, "home_button=" .. remote.home_button)
        end
        S.shared_settings_at = at
        saveSettings()
        log("settings from companion (" .. why .. "):", #changed > 0 and table.concat(changed, " ") or "no change")
        return #changed > 0
    elseif at < (S.shared_settings_at or 0) then
        Shared.push("companion older (" .. why .. ")")
    end
    return false
end

function Shared.push(why)
    if not Companion.installed() then return end
    Companion.send(Companion.ACTION.SETTINGS, {
        reason = why,
        wifi_mode = S.wifi_mode or Shared.defaultMode(),
        wifi_idle_min = tostring(S.wifi_idle_min or 2),
        home_button = S.home_button or "smart",
        settings_at = string.format("%.0f", S.shared_settings_at or 0),
        -- The patch owns Sync while reading; the companion shows it (and the request it applied).
        reading_schedule = S.reading_schedule or "off",
        reading_schedule_applied_at = string.format("%.0f", S.reading_schedule_request_at or 0),
    })
end

function Shared.set(key, value)
    S[key] = value
    S.shared_settings_at = os.time() * 1000
    saveSettings()
    log("setting", key, "=", tostring(value), "(sent to the companion)")
    Shared.push("patch menu")
end

function tailscaleConnect(reason)
    local ok = Jni.sendBroadcast{ action = TAILSCALE.action, package = TAILSCALE.package, class = TAILSCALE.class }
    log("tailscale CONNECT_VPN", ok and "sent" or "NOT sent", reason or "")
    return ok
end

---------------------------------------------------------------------------------------------

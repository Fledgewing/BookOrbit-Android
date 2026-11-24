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
    return Companion.has("wifi") and "jit" or "always_on"
end

function Shared.mode()
    if not Companion.has("wifi") then return "always_on" end -- nothing can switch Wi-Fi
    return WifiPlan.validMode(S.wifi_mode) and S.wifi_mode or Shared.defaultMode()
end

-- Pull the companion's copy if it is newer. Cheap: loopback, 1 s timeout.
-- "Orbit Companion: 1 setup step needs you", or nil.
function Shared.setupNeededText()
    local n = Shared.setup_needed
    if not n or n < 1 or not Companion.has("setup") then return nil end
    return string.format(n == 1 and _("Orbit Companion: %d setup step needs you (open the companion)")
        or _("Orbit Companion: %d setup steps need you (open the companion)"), n)
end

function Shared.refresh(why)
    if not Companion.installed() then
        Companion.updateCaps(nil, why)
        return false
    end
    local st = Companion.status(1)
    Shared.capsChanged(why, Companion.updateCaps(st, why))
    -- Signed in to BookOrbit changed since the last report (a sign-in on BookOrbit's page).
    if why ~= "start" and Rec then pcall(Rec.report, "refresh " .. why) end
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
    -- With no service (Add-on), the companion's status file carries the same (§4.4).
    local src = st or Companion.file
    Shared.setup_needed = src and tonumber(src.setup_needed) or nil
    Shared.setup_prompt = src and type(src.setup_prompt) == "table" and src.setup_prompt or nil
    -- The companion's "Home opens": koreader, launcher or app (nil: unknown, older companion).
    local so = st and type(st.settings) == "table" and st.settings.home_opens or nil
    Shared.home_opens = (so == "koreader" or so == "launcher" or so == "app") and so or nil
    -- Sync while reading set in the companion: apply and save it here, then tell the companion.
    local req_id, req_at = Schedule.request(st and st.reading_schedule_request, S.reading_schedule_request_at)
    if req_id then
        local was = S.reading_schedule
        S.reading_schedule, S.reading_schedule_request_at = req_id, req_at
        if (S.settings_at.reading_schedule or 0) < req_at then S.settings_at.reading_schedule = req_at end
        saveSettings()
        log("setting reading_schedule =", req_id, "(from the companion, was " .. tostring(was) .. ", " .. why .. ")")
        if Shared.onSchedule then pcall(Shared.onSchedule, req_id) end
        Shared.push("reading schedule from the companion")
    end
    -- Settings PIN: locked only on the companion's word; no answer = unlocked (MenuLock).
    Shared.pin_locked = MenuLock.locked(st)
    -- The companion's lockdown reading (true/false; nil: unknown or no companion).
    if st then Shared.vpn_lockdown = type(st.vpn_lockdown) == "boolean" and st.vpn_lockdown or nil end
    -- How the companion shows the sleep screen ("Orbit screen saver ✓", "Set up ›"), for the menu.
    local sl = (st and type(st.sleep) == "table" and st.sleep) or (Companion.file and type(Companion.file.sleep) == "table" and Companion.file.sleep) or nil
    Shared.sleep_shown_by = sl and type(sl.shown_by) == "string" and sl.shown_by or nil
    -- The companion asks for the sleep screen's lists (its picker is open): answer with choices.json.
    local want = tonumber((st and st.want_choices) or (Companion.file and Companion.file.want_choices)) or 0
    if want > (S.choices_asked_at or 0) and Sleep and Sleep.writeChoices then
        S.choices_asked_at = want
        saveSettings()
        pcall(Sleep.writeChoices, "asked by the companion")
        if Sleep.refreshScopes then pcall(Sleep.refreshScopes, "companion picker") end
    end
    -- The lists for the companion's sleep-screen picker, once per start (and on Home refreshes).
    if why == "start" and Sleep and Sleep.writeChoices then
        UIManager:scheduleIn(20, function() if Sleep.choicesDue() then pcall(Sleep.writeChoices, "start") end end)
    end
    -- The "look now" line needs the channel (docs/design/companion-settings.md §4.5).
    if st and not Channel.up and Companion.has("settings2") then pcall(Channel.connect, why) end
    -- With no service (Add-on), the status file carries the settings.
    local remote = (st and type(st.settings) == "table" and st.settings)
        or (Companion.file and type(Companion.file.settings) == "table" and Companion.file.settings) or nil
    if not remote then return false end
    -- Per-key times (settings v2): the newest change to each key wins.
    if type(remote.values) == "table" then return Shared.mergeValues(remote.values, why) end
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
        local sleep_changed = Shared.applySleep(remote, changed)
        S.shared_settings_at = at
        saveSettings()
        log("settings from companion (" .. why .. "):", #changed > 0 and table.concat(changed, " ") or "no change")
        if sleep_changed and Sleep then pcall(Sleep.changed, "companion settings") end
        return #changed > 0
    elseif at < (S.shared_settings_at or 0) then
        Shared.push("companion older (" .. why .. ")")
    end
    return false
end

-- Settings v2 (docs/design/companion-settings.md §4.4): values = key -> { v = wire, at = ms }.
-- Takes each key the companion changed later than this reader, runs what the change needs, and
-- answers with this reader's values (the echo that ends the companion's "Waiting for KOReader").
function Shared.mergeValues(values, why)
    local now = os.time() * 1000
    local taken = SettingsSync.merge(SCHEMA, S, S.settings_at, values, now, true)
    local changed = {}
    for _i, t in ipairs(taken) do
        local d = SCHEMA.byKey[t.key]
        S[t.key] = t.value
        S.settings_at[t.key] = t.at
        if t.at > (S.shared_settings_at or 0) then S.shared_settings_at = t.at end
        if not t.same then
            table.insert(changed, t.key)
            log("setting", t.key, "=", (tostring(SettingsSync.toWire(d, t.value)):gsub("\n", ",")),
                "(from the companion, was " .. (tostring(SettingsSync.toWire(d, t.was)):gsub("\n", ",")) .. ", " .. why .. ")")
        end
    end
    if #taken > 0 then saveSettings() end
    for _i, k in ipairs(changed) do Shared.onChange(k, why) end
    local behind = #taken > 0
    for k, t in pairs(S.settings_at) do
        local r = values[k]
        if SCHEMA.byKey[k] and t > 1 and (type(r) ~= "table" or (tonumber(r.at) or 0) < t) then behind = true end
    end
    if behind then Shared.push("settings " .. why) end
    return #changed > 0
end

-- What a shared setting needs when the companion changed it (the menu's own callbacks do the same).
function Shared.onChange(key, why)
    local function try(fn, ...) if type(fn) == "function" then local okc, err = pcall(fn, ...); if not okc then log("setting", key, ": follow-up failed:", tostring(err)) end end end
    if key == "wifi_mode" or key == "wifi_idle_min" or key == "wifi_via_companion" then
        try(Wifi and Wifi.applySettings, "companion")
    elseif key == "reading_schedule" then
        try(Shared.onSchedule, S.reading_schedule)
    elseif key == "sleep_mode" or key == "sleep_from" or key == "sleep_leave_out" then
        try(Sleep and Sleep.changed, "companion settings")
    elseif key == "storage_limit_mb" then
        try(OC and OC.storageCount, "limit changed")
    elseif key == "mirror_covers" then
        if S.mirror_covers then try(Mirror and Mirror.coverPass, "turned on") end
    elseif key == "recommended_choice" then
        try(Rec and Rec.applyChoices, why)
    end
end

-- The sleep-screen settings a newer companion sends (an older one sends none: nothing changes).
-- -> true when the mode, the source or the rules changed.
function Shared.applySleep(remote, changed)
    local present = {}
    for _, k in ipairs(SleepPool.KEYS) do if remote[k] ~= nil then present[k] = remote[k] end end
    if next(present) == nil then return false end
    local merged = {}
    for _, k in ipairs(SleepPool.KEYS) do merged[k] = present[k] ~= nil and present[k] or S[k] end
    local n = SleepPool.normalize(merged)
    local was = SleepPool.normalize(S)
    local big = false
    for _, k in ipairs(SleepPool.KEYS) do
        local a, b = n[k], was[k]
        if type(a) == "table" then a, b = table.concat(a, "\n"), table.concat(b, "\n") end
        if a ~= b then
            S[k] = n[k]
            table.insert(changed, k .. "=" .. tostring(a):gsub("\n", ","))
            if k == "sleep_mode" or k == "sleep_from" or k == "sleep_leave_out" then big = true end
        end
    end
    return big
end

-- The companion's caps changed (a mode switch or a helper, docs/design/addon-mode.md §8):
-- recommended items that needed a lost cap are undone; newly available ones get a pass.
function Shared.capsChanged(why, before, after, real)
    if not real then return end
    local lost, gained = Caps.diff(before, after)
    if #lost == 0 and #gained == 0 then return end
    log("companion: caps changed (" .. why .. "): lost", table.concat(lost, ","), "| gained", table.concat(gained, ","))
    if #lost > 0 and Rec then pcall(Rec.capsLost, why) end
    if #gained > 0 and Rec then pcall(Rec.pass, "caps " .. why) end
end

function Shared.push(why)
    if not Companion.installed() then return end
    local extras = {
        reason = why,
        wifi_mode = S.wifi_mode or Shared.defaultMode(),
        wifi_idle_min = tostring(S.wifi_idle_min or 2),
        home_button = S.home_button or "smart",
        settings_at = string.format("%.0f", S.shared_settings_at or 0),
        -- The patch owns Sync while reading; the companion shows it (and the request it applied).
        reading_schedule = S.reading_schedule or "off",
        reading_schedule_applied_at = string.format("%.0f", S.reading_schedule_request_at or 0),
    }
    -- The sleep screen's settings (docs/design/lock-screen.md S1).
    for k, v in pairs(SleepPool.extras(S)) do extras[k] = v end
    -- Settings v2: every shared key with the time it last changed (docs/design/companion-settings.md §4.3).
    extras.settings_v = "2"
    extras.values = SleepPool.json(SettingsSync.encode(SCHEMA, S, S.settings_at))
    Companion.send(Companion.ACTION.SETTINGS, extras)
end

function Shared.set(key, value)
    S[key] = value
    S.shared_settings_at = os.time() * 1000
    if SCHEMA.byKey[key] then S.settings_at[key] = S.shared_settings_at end
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

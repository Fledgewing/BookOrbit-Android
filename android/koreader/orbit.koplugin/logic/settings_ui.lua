-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Presentation policy only. Shared schema owns setting types/defaults and wire IDs.
SettingsUI = {}
SettingsUI.modeKeys = {"wifi_mode", "wifi_idle_min", "reading_schedule", "sync_on_sleep", "sleep_cap", "sync_on_wake"}
SettingsUI.syncKeys = {"wifi_mode", "wifi_idle_min", "reading_schedule", "sync_on_sleep", "sleep_cap", "sync_on_wake",
    "wifi_via_companion", "wake_tailscale", "sync_mode"}
SettingsUI.modes = {
    {id="saver", label="Battery saver", help="Wi-Fi only to sync, off after 1 min. Sends your place at chapter ends and on sleep; no wake check.", values={wifi_mode="jit", wifi_idle_min=1, reading_schedule="ch1", sync_on_sleep=true, sleep_cap=10, sync_on_wake=false}},
    {id="balanced", label="Balanced", help="Recommended. Wi-Fi only to sync. Sends your place on sleep and checks on wake.", values={wifi_mode="jit", wifi_idle_min=2, reading_schedule="off", sync_on_sleep=true, sleep_cap=20, sync_on_wake=true}},
    {id="current", label="Always up to date", help="Wi-Fi stays on. Sends your place every 10 minutes, on sleep and on wake.", values={wifi_mode="always_on", wifi_idle_min=2, reading_schedule="min10", sync_on_sleep=true, sleep_cap=20, sync_on_wake=true}},
}
function SettingsUI.mode(settings, effectiveWifi)
    for _, mode in ipairs(SettingsUI.modes) do
        local match = true
        for _, key in ipairs(SettingsUI.modeKeys) do
            local value = settings[key]
            if key == "wifi_mode" and effectiveWifi ~= nil then value = effectiveWifi end
            if value ~= mode.values[key] then match = false end
        end
        if match then return mode.id end
    end
    return "custom"
end
function SettingsUI.modeLabel(settings, effectiveWifi)
    local id = SettingsUI.mode(settings, effectiveWifi)
    for _, mode in ipairs(SettingsUI.modes) do if mode.id == id then return mode.label end end
    return "Custom"
end
function SettingsUI.words(text, home_screen)
    local words = (text:gsub("Back to my book, then home", "Back to my book, then Server plugin's Home")
        :gsub("Tailscale", "VPN"):gsub("tailnet", "VPN"):gsub(" %(matches Xteink%)", ""))
    if home_screen == "booksync" then words = words:gsub("Server plugin's Home", "BookSync Home") end
    return words
end
function SettingsUI.value(d, value)
    if value == nil then value = d.default end
    if d.type == "rules" then return tostring(type(value) == "table" and #value or 0) .. " rules" end
    if d.type == "source" then return "Choose sources…" end
    for _, v in ipairs(d.values or {}) do
        if tostring(value) == tostring(v.id) then return SettingsUI.words(v.label) end
    end
    return tostring(value or "")
end
function SettingsUI.estimate(snapshot, id)
    for _, item in ipairs(snapshot.items or {}) do
        if item.id == id then return item.text end
    end
    return "Estimate pending"
end

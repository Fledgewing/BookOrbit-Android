-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Settings (G_reader_settings "orbit_android")
---------------------------------------------------------------------------------------------

-- The settings shared with the companion, one definition for both (shared/settings/schema.json;
-- package.sh copies it in as settings_schema.json, a checkout reads it from shared/).
function loadSchema()
    for _i, path in ipairs({ SOURCE_DIR .. "/settings_schema.json", SOURCE_DIR .. "/../../../shared/settings/schema.json" }) do
        local f = io.open(path, "rb")
        if f then
            local text = f:read("*a")
            f:close()
            local v = SettingsSync.decodeJson(text)
            if v then return SettingsSync.index(v) end
        end
    end
    logger.err("Orbit: settings_schema.json is missing or unreadable; shared settings have no defaults")
    return SettingsSync.index(nil)
end
SCHEMA = loadSchema()

-- The plugin's own settings and state. A shared setting's default is the schema's (below), never
-- written here (test_logic.lua "settings defaults").
DEFAULTS = {
    last_sleep_sync = nil, -- { at, ok, seconds, reason }
    shared_settings_at = 0,       -- ms, when the shared settings last changed (either side)
    patch_update_status = nil,    -- { at, text }
    open_book_at_exit = nil,      -- path of the open book; set on ReaderReady, cleared on a close
    restart_screen = nil,         -- "bookorbit" when BookOrbit Home was on top at a restart
    restart_book = nil,           -- the book open when a restart quit; reopened by the next start
    home_book = nil,              -- the book Home closed (fallback path); cleared by a user close or another book
    saved_pages_before_update = nil, -- the plugin's Push while reading value, kept while ours is on
    sleep_current_file = nil,     -- the book whose cover current.png holds
    -- Shared settings (docs/design/companion-settings.md §4): key -> ms of its last change, either side.
    settings_at = nil,
    choices_asked_at = 0,         -- the companion's last want_choices request this plugin answered (ms)
}

-- Shared settings whose default depends on the device, so the plugin keeps nil until one is chosen:
-- wifi_mode is "jit" with a companion that can switch Wi-Fi, else "always_on" (Shared.defaultMode).
DEVICE_DEFAULTS = { wifi_mode = true }

for _i, d in ipairs(SCHEMA.settings) do
    if not DEVICE_DEFAULTS[d.key] then DEFAULTS[d.key] = SettingsSync.fromWire(d, SettingsSync.toWire(d, nil)) end
end

S = G_reader_settings:readSetting("orbit_android") or {}
for k, v in pairs(DEFAULTS) do
    if S[k] == nil then S[k] = v end
end

function saveSettings()
    G_reader_settings:saveSetting("orbit_android", S)
end

if type(S.settings_at) ~= "table" then S.settings_at = {} end
-- First run with per-key times: the old whole-set time for the keys shared before, 1 ms for the rest.
SETTINGS_SEEDED = SettingsSync.seed(SCHEMA, S.settings_at, SettingsSync.LEGACY, S.shared_settings_at)
saveSettings()

-- The book that was open when the previous KOReader process ended without a close (killed,
-- e.g. by a firmware after sleep). Read once per process, before this run's ReaderReady.
killed_with_book = S.open_book_at_exit

---------------------------------------------------------------------------------------------

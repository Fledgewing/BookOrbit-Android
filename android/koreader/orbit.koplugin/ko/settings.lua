-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Settings (G_reader_settings "orbit_android")
---------------------------------------------------------------------------------------------

DEFAULTS = {
    wifi_via_companion = true,
    wake_tailscale = true,
    sync_on_wake = true,
    sync_on_sleep = true,
    reading_schedule = "off",
    sleep_cap = 20,
    last_sleep_sync = nil, -- { at, ok, seconds, reason }
    -- Shared with the companion, which stores them (android/docs/INTERFACE.md "Settings"); these are
    -- the patch's cached copy, refreshed from the companion's loopback status.
    wifi_mode = nil,              -- "always_on" | "off_reading" | "jit"; nil = default for this device
    wifi_idle_min = 2,            -- just in time: minutes of no network activity before Wi-Fi goes off
    home_button = "smart",        -- "smart" | "bookorbit"
    shared_settings_at = 0,       -- ms, when the shared settings last changed (either side)
    auto_update_patch = true,
    patch_update_prerelease = false,
    patch_update_checked_at = 0,  -- os.time() of the last successful check
    patch_update_status = nil,    -- { at, text }
    open_book_at_exit = nil,      -- path of the open book; set on ReaderReady, cleared on a close
    restart_screen = nil,         -- "bookorbit" when BookOrbit Home was on top at a restart
    mirror_ttl_days = 7,          -- the offline mirror's automatic Full refresh after this many days
    mirror_auto = true,
    mirror_covers = false,        -- Full refresh also saves every book's cover (off on every device, v0.11.2)
    storage_limit_mb = 250,       -- one limit on everything Orbit stores; 0 = no limit (v0.11.2, Cache.storagePlan)
    keep_copies_current = true,   -- copies whose library file changed are downloaded again in the background           -- the automatic Full refresh (TTL, library changes) is on
    restart_book = nil,           -- the book open when a restart quit; reopened by the next start
    home_book = nil,              -- the book Home closed (fallback path); cleared by a user close or another book
    saved_pages_before_update = nil, -- the plugin's Push while reading value, kept while ours is on
    key_log = true,               -- log every key KOReader gets (clicker diagnosis; v0.4.2 default on)
    eob_sheet = true,             -- BookOrbit books: Orbit's end-of-book sheet instead of KOReader's end_document_action
    eob_auto = true,              -- reaching the end marks the book finished (docs/design/end-of-book §4)
    offline_cache = true,         -- BookOrbit reads from Orbit's cache, checked in the background (docs/design/write-through-cache.md)
    local_first = true,           -- BookOrbit Home shows this device's reading first (docs/design/local-first)
    -- The sleep screen (docs/design/lock-screen.md), shared with the companion (SETTINGS); off on
    -- every reader, also after an update. Checked by SleepPool.normalize wherever they are read.
    sleep_mode = "off",           -- "off" | "recommended" | "current"
    sleep_from = "up_next",       -- "up_next" | "want_to_read" | "discover" | "scope:<id>" | "collection:<id>"
    sleep_leave_out = {},         -- rules: "tag:<text>", "scope:<id>", "collection:<id>" (replaced, never changed in place)
    sleep_hours = 6,              -- Recommended changes after this many hours (1, 3, 6, 12, 24); 0: every sleep
    sleep_text = "",              -- up to 60 characters
    sleep_battery = false,        -- the battery level at sleep
    sleep_style = "bar",          -- "bar" | "overlay"
    sleep_text_position = "right", -- overlay: "right" | "left" | "top" | "bottom"
    sleep_battery_corner = "bottom_left", -- overlay: "top_left" | "top_right" | "bottom_left" | "bottom_right"
    sleep_current_file = nil,     -- the book whose cover current.png holds
}

S = G_reader_settings:readSetting("orbit_android") or {}
for k, v in pairs(DEFAULTS) do
    if S[k] == nil then S[k] = v end
end

function saveSettings()
    G_reader_settings:saveSetting("orbit_android", S)
end
saveSettings()

-- The book that was open when the previous KOReader process ended without a close (killed,
-- e.g. by a firmware after sleep). Read once per process, before this run's ReaderReady.
killed_with_book = S.open_book_at_exit

---------------------------------------------------------------------------------------------

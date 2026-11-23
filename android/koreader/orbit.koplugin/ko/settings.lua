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
    restart_book = nil,           -- the book open when a restart quit; reopened by the next start
    home_book = nil,              -- the book Home closed (fallback path); cleared by a user close or another book
    saved_pages_before_update = nil, -- the plugin's Push while reading value, kept while ours is on
    key_log = true,               -- log every key KOReader gets (clicker diagnosis; v0.4.2 default on)
    eob_sheet = true,             -- BookOrbit books: Orbit's end-of-book sheet instead of KOReader's end_document_action
    eob_auto = true,              -- reaching the end marks the book finished (docs/design/end-of-book §4)
    local_first = true,           -- BookOrbit Home shows this device's reading first (docs/design/local-first)
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

-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
--[[--
Orbit: a KOReader plugin for Android e-readers (generic Android; vendor quirks live in VENDORS,
ko/jni.lua). It was the user patch 2-orbit-android.lua up to BookSync 0.7.x and behaves the same.

The official BookOrbit plugin (bookorbit.koplugin) does ALL syncing and holds the login.
Orbit never talks to BookOrbit's API. It only:

  * gets the network ready (Wi-Fi through the "Orbit Companion" app, Tailscale wake),
  * checks that the plugin's configured server answers at its base URL (no login),
  * then triggers or waits on the plugin: its public action BookOrbitOpenDashboard and its
    "Push while reading" setting, and, behind a compatibility check with a fallback for each
    (logic/compat.lua; android/koreader/README.md "Plugin hook points"), its internals
    requestLifecycleOutboxDrain, requestProgressPull, requestProgressPush,
    fetchRemoteProgress, _onSuspend, onBookOrbitSyncBook, startSweep.

Layout (docs/design/orbit-plugin.md): FILES below, loaded in that order into one environment
shared by the plugin's files, so each file's top-level names are visible to the others, as
they were in the single patch file. logic/ is pure (no KOReader modules, unit-tested by
android/koreader/test/); ko/ is the KOReader side.

Companion interface: android/docs/INTERFACE.md. Logs: `adb logcat | grep OrbitAndroid`.
]]

-- Stamped by the release workflow (.github/workflows/release.yml) from the tag; a copy from the
-- repo says 0.0.0-dev, which any release replaces. Kept near the top: the restart check and the
-- companion read it from this file's head.
local PATCH_VERSION = "0.0.0-dev"

local LOGIC = {
    "logic/schedule.lua", "logic/plan.lua", "logic/update.lua", "logic/wifi_plan.lua",
    "logic/home_plan.lua", "logic/server/bookorbit/compat.lua", "logic/stats.lua", "logic/clicks.lua",
    "logic/prompts.lua", "logic/server/bookorbit/group.lua", "logic/server/bookorbit/finish.lua", "logic/server/bookorbit/localfirst.lua", "logic/sheet_layout.lua", "logic/cache.lua", "logic/server/bookorbit/cache.lua",
    "logic/server/bookorbit/recommended.lua", "logic/caps.lua", "logic/copies.lua", "logic/sleep_pool.lua", "logic/settings_sync.lua",
    "logic/orbismart.lua", "logic/status_layout.lua",
    "logic/reading_style.lua", "logic/account.lua", "logic/settings_ui.lua", "logic/reader_panel.lua", "logic/budgets.lua", "logic/widget_registry.lua", "logic/layout.lua", "logic/filter_sheet.lua", "logic/reading_stats.lua", "logic/battery_widget.lua", "logic/home_host.lua", "logic/home_editor.lua", "logic/booklist.lua", "logic/series.lua",
}
local KO = {
    "ko/base.lua", "ko/settings.lua", "ko/jni.lua", "ko/companion.lua", "ko/shared.lua",
    "ko/server/bookorbit.lua", "ko/net.lua", "ko/server/bookorbit/sync.lua", "ko/wifi.lua", "ko/updater.lua",
    "ko/background.lua", "ko/runtime.lua", "ko/clicks_channel.lua", "ko/keys.lua",
    "ko/module.lua", "ko/server/bookorbit/lifecycle.lua", "ko/start.lua", "ko/home.lua", "ko/sleep.lua", "ko/server/bookorbit/reading_sync.lua",
    "ko/test_sync_path.lua", "ko/companion_ui.lua", "ko/recommendations.lua", "ko/menu.lua",
    "ko/wifi_backend.lua", "ko/endsheet.lua", "ko/finish.lua",
    "ko/server/bookorbit/localfirst.lua", "ko/db.lua", "ko/store.lua", "ko/badge.lua", "ko/sleepscreen.lua",
    "ko/sqlite_stress.lua", "ko/library.lua", "ko/covers.lua", "ko/account.lua", "ko/reading_style.lua", "ko/custom_reading.lua", "ko/reader_panel.lua", "ko/filter_sheet.lua", "ko/reading_stats.lua", "ko/home_widgets.lua", "ko/clock.lua", "ko/battery.lua", "ko/home_host.lua", "ko/series.lua", "ko/home_editor.lua", "ko/booklist_config.lua", "ko/settings_view.lua",
    "ko/server/bookorbit/orbismart.lua", "ko/status_layout.lua", "ko/notices.lua", "ko/main_loop.lua",
}

-- This plugin's folder: PluginLoader dofile()s <folder>/main.lua (frontend/pluginloader.lua:244).
local DIR = (debug.getinfo(1, "S").source or ""):match("^@(.*)/main%.lua$") or "."

local env = setmetatable({
    PATCH_VERSION = PATCH_VERSION,
    -- The folder the self-update replaces (ko/updater.lua); tests point it elsewhere.
    PLUGIN_DIR = rawget(_G, "ORBIT_ANDROID_PLUGIN_DIR") or DIR,
    -- The folder this code loads from (the shared settings schema sits beside it, ko/settings.lua).
    SOURCE_DIR = DIR,
}, { __index = _G })

local function load(files)
    for _i, name in ipairs(files) do
        local chunk, err = loadfile(DIR .. "/" .. name)
        if not chunk then error("orbit.koplugin: " .. tostring(err), 0) end
        setfenv(chunk, env)
        chunk()
        if env.INACTIVE then return false end
    end
    return true
end

load(LOGIC)

if rawget(_G, "ORBIT_ANDROID_TEST") then
    return { Schedule = env.Schedule, Plan = env.Plan, Update = env.Update, WifiPlan = env.WifiPlan,
        HomePlan = env.HomePlan, disabledText = env.disabledText, Compat = env.Compat, Stats = env.Stats,
        Clicks = env.Clicks, SetupPrompt = env.SetupPrompt, MenuLock = env.MenuLock,
        SeriesPlan = env.SeriesPlan, ReadingStyle = env.ReadingStyle, BookList = env.BookList, HomeEditorPlan = env.HomeEditorPlan, Layout = env.Layout, WidgetRegistry = env.WidgetRegistry, Budgets = env.Budgets, FilterSheet = env.FilterSheet, RestartPlan = env.RestartPlan, Group = env.Group, Finish = env.Finish, LocalFirst = env.LocalFirst, Cache = env.Cache, ServerCache = env.ServerCache, SheetLayout = env.SheetLayout, Recommended = env.Recommended, Caps = env.Caps, CopiesPlan = env.CopiesPlan, SleepPool = env.SleepPool, SettingsSync = env.SettingsSync, OrbiSmart = env.OrbiSmart, StatusLayout = env.StatusLayout, BatteryGlyph = env.BatteryGlyph, PATCH_VERSION = PATCH_VERSION }
end

-- The old user patch still loaded (koreader/patches/2-orbit-android.lua; it hooks PluginLoader at
-- startup, before any plugin loads): it runs, and this plugin stays out, so nothing is hooked
-- twice. The companion and tools/install-usb.sh delete the patch when they install the plugin.
local function oldPatch()
    local okp, PluginLoader = pcall(require, "pluginloader")
    if not okp or type(PluginLoader) ~= "table" then return nil end
    for _i, fn in ipairs({ PluginLoader.loadPlugins, PluginLoader.genPluginManagerSubItem }) do
        local info = type(fn) == "function" and debug.getinfo(fn, "S") or nil
        local src = info and info.source or ""
        if src:find("2-orbit-android.lua", 1, true) then return (src:gsub("^@", "")) end
    end
end

local patch = oldPatch()
if patch then
    local okl, logger = pcall(require, "logger")
    if okl and type(logger) == "table" and type(logger.warn) == "function" then logger.warn("OrbitAndroid: the old patch is loaded (" .. patch .. "); the Orbit plugin stays off") end
    return { disabled = true }
end

if not load(KO) then return { disabled = true } end

env.log("plugin", PATCH_VERSION, "loaded; companion", env.Companion.installed() and "installed" or "not installed",
    "| schedule", env.S.reading_schedule, "| sleep cap", env.S.sleep_cap .. "s")

return env.OrbitAndroid

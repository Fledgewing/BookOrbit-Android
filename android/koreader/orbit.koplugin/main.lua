-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
--[[--
Orbit: a KOReader plugin for Android e-readers (generic Android; vendor quirks live in VENDORS,
ko/jni.lua). It was the user patch 2-orbit-android.lua up to Orbify 0.7.x and behaves the same.

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
    "logic/home_plan.lua", "logic/compat.lua", "logic/stats.lua", "logic/clicks.lua",
    "logic/prompts.lua", "logic/group.lua", "logic/finish.lua", "logic/localfirst.lua",
}
local KO = {
    "ko/base.lua", "ko/settings.lua", "ko/jni.lua", "ko/companion.lua", "ko/shared.lua",
    "ko/bookorbit.lua", "ko/net.lua", "ko/sync.lua", "ko/wifi.lua", "ko/updater.lua",
    "ko/background.lua", "ko/runtime.lua", "ko/clicks_channel.lua", "ko/keys.lua",
    "ko/module.lua", "ko/start.lua", "ko/home.lua", "ko/sleep.lua", "ko/reading_sync.lua",
    "ko/test_sync_path.lua", "ko/companion_ui.lua", "ko/recommended.lua", "ko/menu.lua",
    "ko/wifi_backend.lua", "ko/grouping.lua", "ko/endsheet.lua", "ko/endofbook.lua",
    "ko/localfirst.lua",
}

-- This plugin's folder: PluginLoader dofile()s <folder>/main.lua (frontend/pluginloader.lua:244).
local DIR = (debug.getinfo(1, "S").source or ""):match("^@(.*)/main%.lua$") or "."

local env = setmetatable({
    PATCH_VERSION = PATCH_VERSION,
    -- The folder the self-update replaces (ko/updater.lua); tests point it elsewhere.
    PLUGIN_DIR = rawget(_G, "ORBIT_ANDROID_PLUGIN_DIR") or DIR,
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
        RestartPlan = env.RestartPlan, Group = env.Group, Finish = env.Finish, LocalFirst = env.LocalFirst, PATCH_VERSION = PATCH_VERSION }
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

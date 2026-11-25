-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- KOReader user patch (early, priority 1): KOReader starts in the rotation the device is held in.
-- orbit.koplugin installs and updates it in koreader/patches/ (ko/home.lua installStartPatch).
--
-- On Android, KOReader's activity starts with screenOrientation="nosensor" (android-luajit-launcher
-- app/src/main/AndroidManifest.xml:42), so the display stays as it was held. Then KOReader turns
-- it twice before the plugin loads: Device init to closed_rotation_mode (device.lua:350-355,
-- reader.lua:157), and the first file browser to fm_rotation_mode or upright
-- (filemanager.lua:63-69, from showFiles :1321, reader.lua:250/291). This patch keeps the held
-- rotation through both, for this start only:
--   1. closed_rotation_mode := the held rotation, in the settings reader.lua:39 opens (before
--      Device init; KOReader rewrites it at exit, device.lua:664).
--   2. The first file browser skips its rotation once, set up when the late patches run
--      (reader.lua:190, after UIManager, before showFiles). The plugin keeps it from then on.
-- Nothing with KOReader's "Lock auto rotation" on. ORBIT_START_ROTATION tells the plugin.

local ok_a, android = pcall(require, "android")
if not ok_a or type(android) ~= "table" or type(android.orientation) ~= "table" then return end
if type(android.hasNativeRotation) == "function" then
    local okn, native = pcall(android.hasNativeRotation)
    if not okn or not native then return end
end
-- getScreenOrientation: the display's rotation now, as KOReader's mode 0-3
-- (android-luajit-launcher extensions/ActivityExtensions.kt:295-302).
local ok_g, held = pcall(android.orientation.get)
if not ok_g or type(held) ~= "number" or held < 0 or held > 3 then return end

local ok_s, LuaSettings = pcall(require, "luasettings")
local ok_u, userpatch = pcall(require, "userpatch")
if not ok_s or type(LuaSettings) ~= "table" or not ok_u or type(userpatch) ~= "table" then return end
local open, apply = LuaSettings.open, userpatch.applyPatches
if type(open) ~= "function" or type(apply) ~= "function" then return end

ORBIT_START_ROTATION = held

LuaSettings.open = function(self, path, ...)
    local settings = open(self, path, ...)
    if type(path) == "string" and path:match("/settings%.reader%.lua$") then
        LuaSettings.open = open
        local okl, locked = pcall(settings.isTrue, settings, "lock_rotation")
        if (okl and locked) or not okl then
            ORBIT_START_ROTATION = nil
        else
            settings:saveSetting("closed_rotation_mode", held)
        end
    end
    return settings
end

userpatch.applyPatches = function(priority, ...)
    if priority == userpatch.late then
        userpatch.applyPatches = apply
        local okf, FM = pcall(require, "apps/filemanager/filemanager")
        if ORBIT_START_ROTATION ~= nil and okf and type(FM) == "table" and type(FM.setRotationMode) == "function" then
            local stock = FM.setRotationMode
            local once
            once = function()
                if FM.setRotationMode == once then FM.setRotationMode = stock end
            end
            FM.setRotationMode = once
        end
    end
    return apply(priority, ...)
end

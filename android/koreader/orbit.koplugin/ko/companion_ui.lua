-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Companion activities
---------------------------------------------------------------------------------------------

function openCompanion(action, what)
    if not Companion.installed() then
        UIManager:show(InfoMessage:new{ text = _("Orbit Companion isn't installed."), timeout = 3 })
        log("open", what, ": companion not installed")
        return
    end
    local ok = Jni.startActivity{ action = action, package = Companion.PACKAGE }
    log("open", what, ok and "started" or "FAILED")
end

function OrbitAndroid:onOrbitOpenCompanion()
    openCompanion(Companion.ACTION.SHOW_STATUS, "companion")
    return true
end

-- Home from BookOrbit home: the companion's launcher page (as on a double Home). A companion
-- older than 0.2.1 has no SHOW_LAUNCHER; its apps page stands in.
function OrbitAndroid:openCompanionHome()
    if not Companion.installed() then
        log("home: companion not usable; staying on BookOrbit home")
        return true
    end
    local ok = Jni.startActivity{ action = Companion.ACTION.SHOW_LAUNCHER, package = Companion.PACKAGE }
    if not ok then
        ok = Jni.startActivity{ action = Companion.ACTION.SHOW_APPS, package = Companion.PACKAGE }
        log("home: companion launcher page missing (older companion); apps page", ok and "started" or "FAILED")
    else
        log("home: companion launcher page started")
    end
    return true
end

function OrbitAndroid:onOrbitOpenApps()
    openCompanion(Companion.ACTION.SHOW_APPS, "apps")
    return true
end

---------------------------------------------------------------------------------------------

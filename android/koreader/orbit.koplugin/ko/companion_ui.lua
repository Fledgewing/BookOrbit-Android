-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Companion activities
---------------------------------------------------------------------------------------------

function openCompanion(action, what)
    if not Companion.installed() then
        UIManager:show(InfoMessage:new{ text = _("BookSync Companion isn't installed."), timeout = 3 }) -- gate: user action (menu)
        log("open", what, ": companion not installed")
        return
    end
    local ok = Jni.startActivity{ action = action, package = Companion.PACKAGE } -- gate: user action (menu)
    log("open", what, ok and "started" or "FAILED")
end

function OrbitAndroid:onOrbitOpenCompanion()
    openCompanion(Companion.ACTION.SHOW_STATUS, "companion")
    return true
end

-- Home from BookOrbit home: the companion's launcher page (as on a double Home). A companion
-- older than 0.2.1 has no SHOW_LAUNCHER; its apps page stands in.
function OrbitAndroid:openCompanionHome()
    -- Without the companion as Home (Add-on, plugin only): BookOrbit home is the top; Android's
    -- Home key goes to the reader's own launcher (docs/design/addon-mode.md §6.4).
    if not Companion.has("home") then
        log("home: the companion isn't Home here; staying on library home")
        return true
    end
    local ok = Jni.startActivity{ action = Companion.ACTION.SHOW_LAUNCHER, package = Companion.PACKAGE } -- gate: user action (Home button/menu)
    if not ok then
        ok = Jni.startActivity{ action = Companion.ACTION.SHOW_APPS, package = Companion.PACKAGE } -- gate: user action (Home button/menu)
        log("home: companion launcher page missing (older companion); apps page", ok and "started" or "FAILED")
    else
        log("home: companion launcher page started")
    end
    return true
end

function OrbitAndroid:onOrbitOpenApps()
    if Companion.installed() and not Companion.has("apps") then
        log("open apps: not offered by the companion here")
        UIManager:show(InfoMessage:new{ text = _("Use your reader's Home button for other apps."), timeout = 3 }) -- gate: user action (menu)
        return true
    end
    openCompanion(Companion.ACTION.SHOW_APPS, "apps")
    return true
end

---------------------------------------------------------------------------------------------

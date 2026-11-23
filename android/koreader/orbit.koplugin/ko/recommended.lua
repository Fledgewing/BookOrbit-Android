-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Recommended plugin settings and gestures (only when tapped)
---------------------------------------------------------------------------------------------

function OrbitAndroid:applyRecommendedSettings()
    local p = bookorbit(self.ui)
    if not p then
        UIManager:show(InfoMessage:new{ text = _("The BookOrbit plugin isn't loaded."), timeout = 3 })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("Set these BookOrbit plugin options?\n\n• Auto-sync: on\n• BookOrbit is further ahead: Silent\n• BookOrbit is further behind: Don't sync\n• Make BookOrbit home\n• KOReader: Action when Wi-Fi is off → Turn on"),
        ok_text = _("Apply"),
        ok_callback = function()
            G_reader_settings:saveSetting("wifi_enable_action", "turn_on")
            p.settings.sync_forward = Plan.STRATEGY.SILENT
            p.settings.sync_backward = Plan.STRATEGY.DISABLE
            -- Make BookOrbit home, the way the plugin's own Opening page saves it.
            if Compat.settable(p.settings, "catalog_auto_open", "home") then
                p.settings.catalog_auto_open = "home"
            else
                log("compat: catalog_auto_open is", tostring(p.settings.catalog_auto_open), "- left to the plugin's Opening page")
            end
            if not p.settings.auto_sync and hasHandler(p, "BookOrbitToggleAutoSync") then
                -- The plugin's own toggle also registers its reader events (main.lua:1416-1448).
                pluginEvent(liveUI(), p, "BookOrbitToggleAutoSync", true, true, true)
            end
            G_reader_settings:flush()
            log("applied recommended plugin settings; auto_sync", tostring(p.settings.auto_sync))
            UIManager:show(InfoMessage:new{ text = _("Recommended settings applied."), timeout = 2 })
        end,
    })
end

RECOMMENDED_GESTURES = {
    { id = "hold_top_right_corner", action = "orbit_sync_and_sleep", label = "Hold top-right corner → Sync and sleep" },
    { id = "hold_top_left_corner", action = "bookorbit_sync_now", label = "Hold top-left corner → BookOrbit: sync all books" },
    -- KOReader has no one-finger "swipe up from the bottom"; this bottom-edge swipe is the nearest.
    { id = "one_finger_swipe_bottom_edge_right", action = "bookorbit_this_book", label = "Swipe right along the bottom edge → BookOrbit: this book" },
    -- Not used by the three above. KOReader's default for it in books is "brighter frontlight"
    -- on devices with a frontlight (gestures.koplugin/defaults.lua:129); this replaces that.
    { id = "two_finger_swipe_north", action = "orbit_open_apps", label = "Two-finger swipe up → Orbit Companion: apps (replaces brighter frontlight)" },
}

function OrbitAndroid:applyRecommendedGestures()
    local gestures = self.ui and self.ui.gestures
    if not gestures or type(gestures.data) ~= "table" then
        UIManager:show(InfoMessage:new{ text = _("Turn on KOReader's Gestures plugin first."), timeout = 3 })
        return
    end
    local lines = {}
    for _i, g in ipairs(RECOMMENDED_GESTURES) do table.insert(lines, "• " .. g.label) end
    UIManager:show(ConfirmBox:new{
        text = _("In books, set these gestures? Each replaces what the gesture does now.") .. "\n\n" .. table.concat(lines, "\n"),
        ok_text = _("Apply"),
        ok_callback = function()
            -- The same write path the plugin uses for its shortcut (bookorbit_shortcut.lua:111-117).
            gestures.data.gesture_reader = gestures.data.gesture_reader or {}
            for _i, g in ipairs(RECOMMENDED_GESTURES) do
                gestures.data.gesture_reader[g.id] = { [g.action] = true }
            end
            gestures.updated = true
            if gestures.onFlushSettings then gestures:onFlushSettings() end
            log("applied recommended gestures")
            UIManager:show(InfoMessage:new{ text = _("Gestures set. They work in books."), timeout = 2 })
        end,
    })
end

---------------------------------------------------------------------------------------------

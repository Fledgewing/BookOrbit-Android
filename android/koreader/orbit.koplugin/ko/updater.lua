-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Updates (README "Updates"). The plugin and Orbit Companion always ship together: the companion
-- checks GitHub, installs its own update and then the plugin of its own release (PatchInstaller),
-- and restarts KOReader for it. The plugin downloads nothing; its menu's check asks the companion
-- (UPDATE, android/docs/INTERFACE.md), and a newer plugin file on disk restarts KOReader when
-- reading allows (maybeRestart, home.lua).
---------------------------------------------------------------------------------------------

Updater = {}
-- This plugin's main.lua (PLUGIN_DIR is set by main.lua; it carries PATCH_VERSION).
SELF_PATH = PLUGIN_DIR and (PLUGIN_DIR .. "/main.lua") or nil

function setUpdateStatus(text)
    S.patch_update_status = { at = os.time(), text = text }
    saveSettings()
    log("update:", text)
end

-- Asks the companion to check for an update. Returns the text to show.
function Updater.check(why)
    local problem = Companion.workerProblem(_("to check for updates"))
    if problem then
        setUpdateStatus(problem)
        return problem
    end
    Companion.send(Companion.ACTION.UPDATE, { reason = why })
    local text = _("Orbit Companion is checking for an update. The plugin comes with it.")
    setUpdateStatus("asked Orbit Companion to check (" .. why .. ")")
    return text
end

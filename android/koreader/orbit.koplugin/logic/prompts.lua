-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- "Setup needs you" box (companion 0.4.1+): /status carries setup_prompt = { key, rows } only
-- while rows need the user and they didn't say Later (the companion's snooze). Shown once per
-- key, never with a book on screen: the file browser, BookOrbit home or a menu.
---------------------------------------------------------------------------------------------

SetupPrompt = {}

-- where: "reader" (a book on screen), "browser", "bookorbit" or "menu". Returns show, why.
function SetupPrompt.decide(prompt, where, shown_key)
    if type(prompt) ~= "table" or type(prompt.key) ~= "string" or prompt.key == "" then return false, "nothing needed" end
    if where == "reader" then return false, "in a book" end
    if prompt.key == shown_key then return false, "already shown" end
    return true, where
end

function SetupPrompt.text(prompt)
    local rows = type(prompt.rows) == "table" and prompt.rows or {}
    local n = #rows
    if n == 0 then return "Orbit Companion needs a setup step." end
    if n == 1 then return "Orbit Companion needs 1 setup step: " .. tostring(rows[1]) .. "." end
    local list = {}
    for i, r in ipairs(rows) do list[i] = "• " .. tostring(r) end
    return "Orbit Companion needs " .. n .. " setup steps:\n" .. table.concat(list, "\n")
end

---------------------------------------------------------------------------------------------
-- Settings PIN (companion 0.4.4+): /status carries pin_locked. Locked: the Orbit menu shows
-- only "Enter the PIN" and asks the companion for its keypad (SHOW_PIN). No answer from the
-- companion (not installed, not running, older version): the menu stays usable, so nobody is
-- ever locked out by the patch.
---------------------------------------------------------------------------------------------

MenuLock = {}

-- st: the decoded /status table, or nil when the companion didn't answer.
function MenuLock.locked(st)
    return type(st) == "table" and st.pin_locked == true
end

---------------------------------------------------------------------------------------------
-- One update covers everything: a newer patch file on disk (the companion installed it after
-- its own update, or our updater wrote it) gets loaded by a restart that never interrupts
-- reading: at once with no book open, else right after the book closes or the device sleeps.
-- One try per version: a file that still doesn't load after its restart is left to Setup.
---------------------------------------------------------------------------------------------

RestartPlan = {}

-- The PATCH_VERSION a file's head declares (it sits near the top), or nil.
function RestartPlan.fileVersion(head)
    return (head or ""):match('\nlocal PATCH_VERSION = "([^"\n]+)"')
end

-- want: the file's version; running: PATCH_VERSION; tried: the version a restart was already
-- made for (S.restart_tried); in_book; event: "check" (start, resume, after an update),
-- "close" (a book just closed) or "sleep" (screen off).
-- Returns "none" | "done" (already running it) | "restart" | "wait" | "gave_up".
function RestartPlan.decide(want, running, tried, in_book, event)
    if not want then return "none" end
    if Update.compare(want, running) ~= 1 then return tried and "done" or "none" end
    if tried and Update.compare(tried, want) == 0 then return "gave_up" end
    if not in_book or event == "sleep" or event == "close" then return "restart" end
    return "wait"
end

-- The one status line after a restart made for an update.
function RestartPlan.doneText(version)
    return string.format("Updated to v%s (KOReader restarted)", tostring(version))
end

---------------------------------------------------------------------------------------------

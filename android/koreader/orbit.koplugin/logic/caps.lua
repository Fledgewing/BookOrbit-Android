-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- What the companion offers (docs/design/addon-mode.md §6): its mode and capabilities, from
-- the status call (live, while its service runs) or the status file it writes into
-- koreader/settings/orbit-companion.json (always). The plugin and the companion ship together,
-- so there is no older companion to guess for: nothing known means nothing offered yet.
---------------------------------------------------------------------------------------------

Caps = {}
Caps.ALL = { "install", "setup", "stats", "relaunch", "home", "apps", "wifi", "sleep_sync", "screen_off", "clicker", "pin" }
-- Caps whose actions need the companion's service running (§6.2 step 3).
Caps.SERVICE = { wifi = true, sleep_sync = true, clicker = true, pin = true, home = true }

local function set(list)
    local out = {}
    if type(list) == "table" then
        for _, c in ipairs(list) do if type(c) == "string" then out[c] = true end end
    end
    return out
end

-- state: Companion.state() ("ok" | "frozen" | "untrusted" | "missing"); file: the decoded status
-- file or nil; status: the decoded status or nil (no answer); cached: { mode, caps } last seen or
-- nil. Returns caps (a set), mode ("full" | "addon" | nil), source ("none" | "status" | "file" |
-- "cache").
function Caps.resolve(state, file, status, cached)
    if state ~= "ok" then return {}, nil, "none" end -- a leftover file is ignored
    if type(status) == "table" and type(status.caps) == "table" then
        return set(status.caps), status.mode, "status"
    end
    if type(file) == "table" and type(file.caps) == "table" then
        return set(file.caps), file.mode, "file"
    end
    if type(cached) == "table" and type(cached.caps) == "table" then return set(cached.caps), cached.mode, "cache" end
    return {}, nil, "none"
end

-- Sorted list (for S.companion_caps and the log).
function Caps.list(s)
    local out = {}
    for c in pairs(s or {}) do table.insert(out, c) end
    table.sort(out)
    return out
end

-- Caps present before and gone now / new now.
function Caps.diff(before, after)
    local lost, gained = {}, {}
    for c in pairs(before or {}) do if not after[c] then table.insert(lost, c) end end
    for c in pairs(after or {}) do if not (before or {})[c] then table.insert(gained, c) end end
    table.sort(lost); table.sort(gained)
    return lost, gained
end

---------------------------------------------------------------------------------------------

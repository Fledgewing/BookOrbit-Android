-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- The sleep screen's settings (docs/design/lock-screen.md). Pure: the settings and their checks,
-- the sources (Pick from), the Leave out rules, the pickers' lists and the JSON the companion reads.
-- The pool itself (which books, the shuffle bag, the covers) is Orbit Companion's:
-- SleepPoolLogic.kt and SleepPoolBuilder.kt; it decides at sleep which cover is shown
-- (SleepScreenLogic.kt).
---------------------------------------------------------------------------------------------

-- EVERY_SLEEP: Change cover every's "Every sleep" (the batch and its retiring: SleepPoolLogic.kt).
SleepPool = { TEXT_MAX = 60, EVERY_SLEEP = 0 }

SleepPool.MODES = {
    { id = "off", label = "The reader's own" },
    { id = "recommended", label = "Recommended cover" },
    { id = "current", label = "Current book" },
}
-- Pick from: the dashboard sections (B koreader.ts:443-449), in the order an empty one falls back.
SleepPool.LISTS = {
    { id = "up_next", type = "up-next-in-series", label = "Up next in series" },
    { id = "want_to_read", type = "want-to-read", label = "Want to read" },
    { id = "discover", type = "random", label = "Discover" },
}
-- Change cover every: 0 is "Every sleep" (a random ready cover at each sleep), else hours.
SleepPool.HOURS = { 0, 1, 3, 6, 12, 24 }

function SleepPool.hoursLabel(h)
    if tonumber(h) == SleepPool.EVERY_SLEEP then return "Every sleep" end
    return string.format("%d h", tonumber(h) or 0)
end
SleepPool.STYLES = { { id = "bar", label = "Bar" }, { id = "overlay", label = "Overlay" } }
SleepPool.TEXT_POSITIONS = {
    { id = "right", label = "Right" }, { id = "left", label = "Left" },
    { id = "top", label = "Top" }, { id = "bottom", label = "Bottom" },
}
SleepPool.CORNERS = {
    { id = "top_left", label = "Top left" }, { id = "top_right", label = "Top right" },
    { id = "bottom_left", label = "Bottom left" }, { id = "bottom_right", label = "Bottom right" },
}

-- Off on every reader, also after an update (S6). Turned on: Recommended, Up next, 6 h.
SleepPool.DEFAULTS = {
    sleep_mode = "off", sleep_from = "up_next", sleep_leave_out = {}, sleep_hours = 6, sleep_text = "",
    sleep_battery = false, sleep_style = "bar", sleep_text_position = "right", sleep_battery_corner = "bottom_left",
}
SleepPool.KEYS = { "sleep_mode", "sleep_from", "sleep_leave_out", "sleep_hours", "sleep_text", "sleep_battery",
    "sleep_style", "sleep_text_position", "sleep_battery_corner" }

local function has(list, id)
    for _, o in ipairs(list) do if (type(o) == "table" and o.id == id) or o == id then return true end end
    return false
end

function SleepPool.label(list, id)
    for _, o in ipairs(list) do if o.id == id then return o.label end end
    return tostring(id)
end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- The user's text: one line, at most TEXT_MAX characters (UTF-8 aware).
function SleepPool.cleanText(s)
    s = trim(tostring(s or ""):gsub("[\r\n\t]+", " "))
    local out, n = {}, 0
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        n = n + 1
        if n > SleepPool.TEXT_MAX then break end
        out[n] = ch
    end
    return table.concat(out)
end

-- Pick from: a list id, or "scope:<id>" / "collection:<id>". nil when not valid.
function SleepPool.parseFrom(v)
    if type(v) ~= "string" then return nil end
    for _, l in ipairs(SleepPool.LISTS) do
        if l.id == v then return { kind = "list", id = l.id, type = l.type } end
    end
    local kind, id = v:match("^(%a+):(%d+)$")
    if (kind == "scope" or kind == "collection") and tonumber(id) and tonumber(id) > 0 then
        return { kind = kind, id = tonumber(id) }
    end
    return nil
end

-- A Leave out rule: "tag:<text>", "scope:<id>" or "collection:<id>". nil when not valid.
function SleepPool.parseRule(v)
    if type(v) ~= "string" then return nil end
    local tag = v:match("^tag:(.*)$")
    if tag then
        tag = trim(tag):lower()
        if tag == "" then return nil end
        return { kind = "tag", tag = tag, key = "tag:" .. tag }
    end
    local kind, id = v:match("^(%a+):(%d+)$")
    if (kind == "scope" or kind == "collection") and tonumber(id) > 0 then
        return { kind = kind, id = tonumber(id), key = kind .. ":" .. tonumber(id) }
    end
    return nil
end

-- Rules as the SETTINGS extra carries them: one per line.
function SleepPool.encodeRules(list)
    local out = {}
    for _, r in ipairs(list or {}) do
        local p = SleepPool.parseRule(r)
        if p then table.insert(out, p.key) end
    end
    return table.concat(out, "\n")
end

-- A list of rule strings (unique, valid) from a table or a newline-separated string.
function SleepPool.decodeRules(v)
    local raw = {}
    if type(v) == "table" then raw = v
    elseif type(v) == "string" then for line in (v .. "\n"):gmatch("([^\n]*)\n") do table.insert(raw, line) end end
    local out, seen = {}, {}
    for _, r in ipairs(raw) do
        local p = SleepPool.parseRule(r)
        if p and not seen[p.key] then seen[p.key] = true; table.insert(out, p.key) end
    end
    return out
end

-- Settings checked one by one: a bad or missing value is the default. Returns a new table.
function SleepPool.normalize(s)
    s = s or {}
    local d = SleepPool.DEFAULTS
    local out = {}
    out.sleep_mode = has(SleepPool.MODES, s.sleep_mode) and s.sleep_mode or d.sleep_mode
    out.sleep_from = SleepPool.parseFrom(s.sleep_from) and s.sleep_from or d.sleep_from
    out.sleep_leave_out = SleepPool.decodeRules(s.sleep_leave_out)
    local h = tonumber(s.sleep_hours)
    out.sleep_hours = (h and has(SleepPool.HOURS, h)) and h or d.sleep_hours
    out.sleep_text = SleepPool.cleanText(s.sleep_text)
    out.sleep_battery = s.sleep_battery == true or s.sleep_battery == "1" or s.sleep_battery == "true"
    out.sleep_style = has(SleepPool.STYLES, s.sleep_style) and s.sleep_style or d.sleep_style
    out.sleep_text_position = has(SleepPool.TEXT_POSITIONS, s.sleep_text_position) and s.sleep_text_position or d.sleep_text_position
    out.sleep_battery_corner = has(SleepPool.CORNERS, s.sleep_battery_corner) and s.sleep_battery_corner or d.sleep_battery_corner
    return out
end

-- The SETTINGS extras (android/docs/INTERFACE.md "Settings"), all strings.
function SleepPool.extras(s)
    local n = SleepPool.normalize(s)
    return {
        sleep_mode = n.sleep_mode, sleep_from = n.sleep_from, sleep_leave_out = SleepPool.encodeRules(n.sleep_leave_out),
        sleep_hours = tostring(n.sleep_hours), sleep_text = n.sleep_text, sleep_battery = n.sleep_battery and "1" or "0",
        sleep_style = n.sleep_style, sleep_text_position = n.sleep_text_position, sleep_battery_corner = n.sleep_battery_corner,
    }
end

-- L3b2: text and battery would share a corner -> the battery moves to the opposite side.
function SleepPool.batteryCorner(corner, position)
    local v, h = corner:match("^(%a+)_(%a+)$")
    if position == "top" and v == "top" then v = "bottom"
    elseif position == "bottom" and v == "bottom" then v = "top"
    elseif position == "right" and h == "right" then h = "left"
    elseif position == "left" and h == "left" then h = "right" end
    return v .. "_" .. h
end

---------------------------------------------------------------- replies

-- The entries of a section index (smart scopes, collections): { id, title, count }.
function SleepPool.entries(body)
    local out = {}
    for _, e in ipairs(type(body) == "table" and type(body.items) == "table" and body.items or {}) do
        local id = tonumber(e.id)
        if id and id > 0 then table.insert(out, { id = id, title = tostring(e.title or ""), count = tonumber(e.count) }) end
    end
    return out
end

---------------------------------------------------------------- the files

local function jsonString(s)
    return '"' .. tostring(s):gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" elseif c == "\n" then return "\\n"
        elseif c == "\r" then return "\\r" elseif c == "\t" then return "\\t" end
        return string.format("\\u%04x", c:byte())
    end) .. '"'
end

-- A small JSON writer for the files the companion reads (arrays: tables with [1]; empty: []).
function SleepPool.json(v)
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return string.format("%d", v) end
        return string.format("%.14g", v)
    end
    if t == "string" then return jsonString(v) end
    if t == "table" then
        if next(v) == nil or v[1] ~= nil then
            local parts = {}
            for i = 1, #v do parts[i] = SleepPool.json(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do table.insert(keys, tostring(k)) end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do table.insert(parts, jsonString(k) .. ":" .. SleepPool.json(v[k])) end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

---------------------------------------------------------------------------------------------

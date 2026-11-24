-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout"). Pure: no KOReader modules.

-- Settings shared with the companion, one definition for both (shared/settings/schema.json,
-- docs/design/companion-settings.md §4). Every value carries the time it last changed, per key,
-- and the newest change to a key wins. Wire values are strings: bool 1/0, numbers in decimal,
-- rules one per line.
---------------------------------------------------------------------------------------------

SettingsSync = { FUTURE_MS = 86400000 }

-- schema: the decoded schema.json. -> { settings = {…}, byKey = {…}, sections = {…} }
function SettingsSync.index(schema)
    local out = { settings = {}, byKey = {}, sections = {} }
    if type(schema) ~= "table" then return out end
    for _, s in ipairs(schema.sections or {}) do table.insert(out.sections, s) end
    for _, d in ipairs(schema.settings or {}) do
        if type(d) == "table" and type(d.key) == "string" then
            table.insert(out.settings, d)
            out.byKey[d.key] = d
        end
    end
    return out
end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function utf8cut(s, max)
    local out, n = {}, 0
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        n = n + 1
        if n > max then break end
        out[n] = ch
    end
    return table.concat(out)
end

local function hasValue(d, id)
    for _, v in ipairs(d.values or {}) do if tostring(v.id) == id then return true end end
    return false
end

-- A wire string -> the value the plugin stores, or nil when the schema refuses it.
function SettingsSync.fromWire(d, s)
    if type(d) ~= "table" or s == nil then return nil end
    s = tostring(s)
    local t = d.type
    if t == "bool" then
        if s == "1" or s == "true" then return true end
        if s == "0" or s == "false" then return false end
        return nil
    elseif t == "choice" then
        if not hasValue(d, s) then return nil end
        if d.int then return tonumber(s) end
        return s
    elseif t == "source" then
        -- Pick from, a set (docs/design/lock-screen.md R1c): SleepPool's rule, one item per line.
        return SleepPool.normalizeFrom(s)
    elseif t == "rules" then
        return SleepPool.decodeRules(s)
    elseif t == "text" then
        return utf8cut(trim(s:gsub("[\r\n\t]+", " ")), tonumber(d.max) or 500)
    end
    return nil
end

-- A stored value -> its wire string (nil: nothing to send).
function SettingsSync.toWire(d, v)
    if type(d) ~= "table" then return nil end
    if v == nil then
        if d.default == nil then return nil end
        v = d.default
    end
    local t = d.type
    if t == "bool" then return (v == true or v == "1" or v == "true") and "1" or "0" end
    if t == "rules" then
        if type(v) == "table" then return table.concat(v, "\n") end
        return tostring(v)
    end
    if type(v) == "number" then return string.format("%d", v) end
    return tostring(v)
end

local function same(d, a, b)
    return SettingsSync.toWire(d, a) == SettingsSync.toWire(d, b)
end

--[[
Merges remote values into local ones, key by key.
  idx: SettingsSync.index(schema); vals: key -> stored value; at: key -> ms (absent: never set here);
  remote: key -> { v = wire string, at = ms }; now_ms: the clock;
  remote_wins_tie: true on the plugin (the companion wins a tie), false on the companion.
-> taken: list of { key, value, at, was }, in schema order. vals and at are not changed.
]]
function SettingsSync.merge(idx, vals, at, remote, now_ms, remote_wins_tie)
    local taken = {}
    if type(remote) ~= "table" then return taken end
    for _, d in ipairs(idx.settings) do
        local r = remote[d.key]
        if type(r) == "table" and r.v ~= nil then
            local rat = tonumber(r.at) or 0
            if now_ms and rat > now_ms + SettingsSync.FUTURE_MS then rat = now_ms end
            local v = SettingsSync.fromWire(d, r.v)
            local lat = at[d.key]
            if v ~= nil and rat > 0 then
                local eqv = lat ~= nil and same(d, v, vals[d.key])
                -- Newer wins; a tie goes to the companion. A newer time with the same value is
                -- still taken (same = true): the time moves, so the sender sees its change echoed.
                if lat == nil or rat > lat or (rat == lat and remote_wins_tie and not eqv) then
                    table.insert(taken, { key = d.key, value = v, at = rat, was = vals[d.key], same = eqv })
                end
            end
        end
    end
    return taken
end

-- key -> { v, at } for every key that has a time (the "values" field of the wire).
function SettingsSync.encode(idx, vals, at)
    local out = {}
    for _, d in ipairs(idx.settings) do
        local t = at[d.key]
        if t and t > 0 then out[d.key] = { v = SettingsSync.toWire(d, vals[d.key]), at = t } end
    end
    return out
end

--[[
The first run with per-key times (an older plugin kept one settings_at for the whole set):
keys shared before (legacy) get that time; every other key gets 1 ms, so the companion,
which has never set them, takes this reader's values, and any later change beats them.
Returns how many keys were seeded; changes at in place.
]]
function SettingsSync.seed(idx, at, legacy, legacy_at)
    local n = 0
    for _, d in ipairs(idx.settings) do
        if at[d.key] == nil then
            at[d.key] = (legacy[d.key] and (tonumber(legacy_at) or 0) > 0) and tonumber(legacy_at) or 1
            n = n + 1
        end
    end
    return n
end

-- A row's parent rule: shown only while the parent has (is) or hasn't (not) one of the values,
-- and the parent itself is shown. vals: key -> stored value.
function SettingsSync.visible(idx, key, vals, depth)
    depth = depth or 0
    local d = idx.byKey[key]
    if not d or depth > 8 then return d ~= nil end
    local p = d.parent
    if type(p) ~= "table" or not idx.byKey[p.key] then return true end
    local pv = SettingsSync.toWire(idx.byKey[p.key], vals[p.key])
    local function member(list) for _, x in ipairs(list or {}) do if tostring(x) == pv then return true end end return false end
    if p.is and not member(p.is) then return false end
    if p["not"] and member(p["not"]) then return false end
    return SettingsSync.visible(idx, p.key, vals, depth + 1)
end

-- The keys shared with a whole-set settings_at before per-key times (android/docs/INTERFACE.md).
SettingsSync.LEGACY = {
    wifi_mode = true, wifi_idle_min = true, home_button = true, sleep_mode = true, sleep_from = true,
    sleep_leave_out = true, sleep_hours = true, sleep_text = true, sleep_battery = true, sleep_style = true,
    sleep_text_position = true, sleep_battery_corner = true,
}

-- A small JSON reader for the schema (the plugin's own, so the schema loads the same in KOReader
-- and in the tests). Objects, arrays, strings, numbers, true/false/null. -> value, or nil.
do
    local function skip(s, i) return s:find("[^ \t\r\n]", i) or #s + 1 end
    local function utf8(code)
        if code < 0x80 then return string.char(code) end
        if code < 0x800 then return string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64) end
        return string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
    end
    local value
    local function str(s, i)
        local out, j = {}, i + 1
        while true do
            local c = s:sub(j, j)
            if c == "" then error("unterminated string") end
            if c == '"' then return table.concat(out), j + 1 end
            if c == "\\" then
                local e = s:sub(j + 1, j + 1)
                if e == "u" then
                    out[#out + 1] = utf8(tonumber(s:sub(j + 2, j + 5), 16) or 63)
                    j = j + 6
                else
                    local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
                    out[#out + 1] = map[e] or error("bad escape")
                    j = j + 2
                end
            else
                out[#out + 1] = c
                j = j + 1
            end
        end
    end
    function value(s, i)
        i = skip(s, i)
        local c = s:sub(i, i)
        if c == "{" then
            local obj = {}
            i = skip(s, i + 1)
            if s:sub(i, i) == "}" then return obj, i + 1 end
            while true do
                local k
                k, i = str(s, skip(s, i))
                i = skip(s, i)
                if s:sub(i, i) ~= ":" then error("expected :") end
                obj[k], i = value(s, i + 1)
                i = skip(s, i)
                local d = s:sub(i, i)
                if d == "}" then return obj, i + 1 end
                if d ~= "," then error("expected ,") end
                i = i + 1
            end
        elseif c == "[" then
            local arr = {}
            i = skip(s, i + 1)
            if s:sub(i, i) == "]" then return arr, i + 1 end
            while true do
                arr[#arr + 1], i = value(s, i)
                i = skip(s, i)
                local d = s:sub(i, i)
                if d == "]" then return arr, i + 1 end
                if d ~= "," then error("expected ,") end
                i = i + 1
            end
        elseif c == '"' then return str(s, i)
        elseif s:sub(i, i + 3) == "true" then return true, i + 4
        elseif s:sub(i, i + 4) == "false" then return false, i + 5
        elseif s:sub(i, i + 3) == "null" then return nil, i + 4
        end
        local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
        if not num or num == "" then error("unexpected character") end
        return tonumber(num), i + #num
    end
    function SettingsSync.decodeJson(s)
        if type(s) ~= "string" then return nil end
        local ok, v = pcall(value, s, 1)
        return ok and v or nil
    end
end

-- Recommended settings choices from the companion: "id=ours;id2=mine;all=undo" -> list.
function SettingsSync.choices(s)
    local out = {}
    for part in tostring(s or ""):gmatch("[^;]+") do
        local id, what = part:match("^%s*([%w%._]+)%s*=%s*(%a+)%s*$")
        if id and (what == "ours" or what == "mine" or what == "undo") then table.insert(out, { id = id, what = what }) end
    end
    return out
end

---------------------------------------------------------------------------------------------

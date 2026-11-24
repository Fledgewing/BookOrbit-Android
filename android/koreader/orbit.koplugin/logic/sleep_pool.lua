-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- The sleep screen's pool (docs/design/lock-screen.md). Pure: the settings and their checks,
-- the sources (Pick from), the Leave out rules, the shuffle bag and the files the companion reads.
-- The KOReader side (ko/sleepscreen.lua) fetches and writes; the companion (SleepScreenLogic.kt)
-- decides at sleep which cover of the pool is shown.
---------------------------------------------------------------------------------------------

SleepPool = { TEXT_MAX = 60, LIST_KEEP = 12, BAG_KEEP = 6, BAG_MAX = 2000, LEAVE_OUT_MAX = 4000,
    PAGE_SIZE = 100, DAY_S = 86400, PROBE_MAX = 36 }

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
SleepPool.HOURS = { 1, 3, 6, 12, 24 }
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

-- The books of a dashboard section reply ({ section = { books } }, B koreader.ts:466-470).
function SleepPool.sectionBooks(body)
    local s = type(body) == "table" and body.section
    local books = type(s) == "table" and s.books
    return type(books) == "table" and books or {}
end

-- A books page: items and whether more follow.
function SleepPool.pageItems(body)
    if type(body) ~= "table" then return {}, false end
    return type(body.items) == "table" and body.items or {}, body.hasNext == true
end

-- The entries of a section index (smart scopes, collections): { id, title, count }.
function SleepPool.entries(body)
    local out = {}
    for _, e in ipairs(type(body) == "table" and type(body.items) == "table" and body.items or {}) do
        local id = tonumber(e.id)
        if id and id > 0 then table.insert(out, { id = id, title = tostring(e.title or ""), count = tonumber(e.count) }) end
    end
    return out
end

-- R2: a book can be shown when it has a cover, isn't read and isn't the book open now.
function SleepPool.eligible(b, open_id)
    if type(b) ~= "table" or not tonumber(b.id) then return false, "no id" end
    if b.hasCover == false then return false, "no cover" end
    if b.readStatus == "read" then return false, "read" end
    if open_id and tonumber(b.id) == open_id then return false, "open now" end
    return true
end

---------------------------------------------------------------- Leave out (X1-X7)

function SleepPool.needsTags(rules)
    for _, r in ipairs(rules or {}) do
        local p = SleepPool.parseRule(r)
        if p and p.kind == "tag" then return true end
    end
    return false
end

-- The rules that need member lists (scope, collection), parsed.
function SleepPool.memberRules(rules)
    local out = {}
    for _, r in ipairs(rules or {}) do
        local p = SleepPool.parseRule(r)
        if p and p.kind ~= "tag" then table.insert(out, p) end
    end
    return out
end

-- One book against the rules, OR-ed. members[key] = { [id] = true } once listed (nil: not yet);
-- tags = the book's tags from its detail (nil: not fetched). -> "keep" | "out" | "unknown", why.
-- Unknown is failed closed by the caller (X7).
function SleepPool.check(id, rules, members, tags)
    id = tonumber(id)
    local unknown
    for _, r in ipairs(rules or {}) do
        local p = SleepPool.parseRule(r)
        if p and p.kind == "tag" then
            if type(tags) ~= "table" then
                unknown = unknown or ("no detail for " .. p.key)
            else
                for _, t in ipairs(tags) do
                    if trim(t):lower() == p.tag then return "out", p.key end
                end
            end
        elseif p then
            local set = members and members[p.key]
            if type(set) ~= "table" then
                unknown = unknown or (p.key .. " not listed yet")
            elseif set[id] then
                return "out", p.key
            end
        end
    end
    if unknown then return "unknown", unknown end
    return "keep"
end

-- Tags seen in cached book details, with counts, most used first (X3's picker).
function SleepPool.tagCounts(details)
    local counts, shown = {}, {}
    for _, d in ipairs(details or {}) do
        local seen = {}
        for _, t in ipairs(type(d) == "table" and type(d.tags) == "table" and d.tags or {}) do
            local k = trim(t):lower()
            if k ~= "" and not seen[k] then
                seen[k] = true
                counts[k] = (counts[k] or 0) + 1
                shown[k] = shown[k] or trim(t)
            end
        end
    end
    local out = {}
    for k, n in pairs(counts) do table.insert(out, { tag = k, label = shown[k], count = n }) end
    table.sort(out, function(a, b) if a.count == b.count then return a.tag < b.tag end return a.count > b.count end)
    return out
end

-- A member list is due: never listed, a day old, or the clock went back.
function SleepPool.due(at, now)
    return not at or now < at or now - at >= SleepPool.DAY_S
end

---------------------------------------------------------------- the shuffle bag (R1b)

-- Fisher-Yates with rand(n) -> 1..n. The book just shown never comes first.
function SleepPool.shuffle(ids, rand, avoid_first)
    local out = {}
    for i, v in ipairs(ids or {}) do out[i] = v end
    for i = #out, 2, -1 do
        local j = rand(i)
        out[i], out[j] = out[j], out[i]
    end
    if avoid_first and #out > 1 and out[1] == avoid_first then
        local j = 1 + rand(#out - 1)
        out[1], out[j] = out[j], out[1]
    end
    return out
end

-- bag = { order = { ids }, pos = index of the last shown (0 none), prev = the id shown last }.
-- The companion reports what it showed (state.json); the bag moves to it, never back.
function SleepPool.bagSeek(bag, shown)
    shown = tonumber(shown)
    if not shown or shown == bag.prev then return false end
    for i = (bag.pos or 0) + 1, #bag.order do
        if bag.order[i] == shown then
            bag.pos, bag.prev = i, shown
            return true
        end
    end
    return false
end

-- The members listed again: those that left come out, new ones go in at random places among the
-- books not shown yet, so "no repeat until every book was shown" holds.
function SleepPool.bagSync(bag, members, rand)
    local want, kept, out = {}, {}, {}
    for _, id in ipairs(members) do want[id] = true end
    local pos = bag.pos or 0
    for i, id in ipairs(bag.order or {}) do
        if want[id] and not kept[id] then
            kept[id] = true
            table.insert(out, id)
        elseif i <= pos then
            pos = pos - 1
        end
    end
    for _, id in ipairs(members) do
        if not kept[id] then
            kept[id] = true
            local at = pos + rand(#out - pos + 1)
            table.insert(out, at, id)
        end
    end
    bag.order, bag.pos = out, math.max(0, pos)
    return bag
end

-- The ids not shown yet, in order. A used-up bag is shuffled again first (the last shown never
-- first); returns the ids and whether it was shuffled.
function SleepPool.bagNext(bag, rand)
    local out, shuffled = {}, false
    if #bag.order == 0 then return out, false end
    if (bag.pos or 0) >= #bag.order then
        bag.order = SleepPool.shuffle(bag.order, rand, bag.prev)
        bag.pos, shuffled = 0, true
    end
    for i = bag.pos + 1, #bag.order do table.insert(out, bag.order[i]) end
    return out, shuffled
end

---------------------------------------------------------------- the files

-- pool.json: the covers in the order the companion shows them (android/docs/INTERFACE.md).
-- items: { { id, title, file } } (file relative to the orbit-sleep folder).
-- account: { server, user, storage_limit_mb } or nil. The companion fetches the sharp covers
-- (docs/design/lock-screen.md L7) from this server, signed in with an OPDS login it asks for;
-- never the KOReader key.
function SleepPool.poolDoc(source, items, at_ms, account)
    local doc = { v = 1, at = at_ms, source = source, items = items }
    if type(account) == "table" then
        doc.server = account.server and tostring(account.server) or nil
        doc.user = account.user and tostring(account.user) or nil
        doc.storage_limit_mb = tonumber(account.storage_limit_mb)
    end
    return doc
end

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

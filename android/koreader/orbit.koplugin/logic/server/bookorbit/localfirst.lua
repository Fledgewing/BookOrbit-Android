-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Local-first Home (docs/design/local-first/DESIGN.md, ROADMAP 3): the overlay of this device's
-- reading state on a copy of the dashboard body, the freshness stamp, and the per-tile content
-- keys that decide what a refresh repaints. Pure: no KOReader modules. Table-tested from
-- shared/fixtures/localfirst/ (test_logic.lua). Display only: nothing here writes to the server.
---------------------------------------------------------------------------------------------

LocalFirst = {}

-- "2026-11-20T19:02:11.000Z" -> epoch seconds (UTC), or nil.
function LocalFirst.parseIso(s)
    if type(s) ~= "string" then return nil end
    local y, mo, d, h, mi, se = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):(%d%d)")
    if not y then
        y, mo, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
        if not y then return nil end
        h, mi, se = 0, 0, 0
    end
    y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
    -- Days from civil (H. Hinnant), so no os.time() and no local time zone.
    local yy = mo <= 2 and y - 1 or y
    local era = math.floor(yy / 400)
    local yoe = yy - era * 400
    local mp = (mo + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(se)
end

-- KOReader's summary.status -> the server's readStatus.
LocalFirst.STATUS = { complete = "read", reading = "reading", abandoned = "abandoned" }

-- Book ids reach us as numbers (the server body) or strings (the plugin's state): one key each.
local function idKey(id) return id ~= nil and tostring(id) or nil end

-- "Device wins while newer" (design "Shared concepts"): the device's value is shown when its
-- change is newer than the server's lastReadAt, or still waits to upload.
function LocalFirst.deviceWins(server_book, loc)
    if type(loc) ~= "table" then return false end
    if loc.pending then return true end
    local srv = LocalFirst.parseIso(server_book and server_book.lastReadAt) or 0
    return (loc.changedAt or 0) > srv
end

local function copy(t)
    local o = {}
    for k, v in pairs(t) do o[k] = v end
    return o
end

-- One book, overlaid when the device wins. Returns the copy and whether it changed.
function LocalFirst.overlayBook(book, loc)
    if type(book) ~= "table" or not LocalFirst.deviceWins(book, loc) then return book, false end
    local b = copy(book)
    if type(loc.percent) == "number" then b.progressPercentage = loc.percent end
    local st = LocalFirst.STATUS[loc.status]
    if st then b.readStatus = st end
    b.orbit_local = true
    return b, true
end

local function overlayList(list, by_id)
    if type(list) ~= "table" then return list end
    local out = {}
    for i, b in ipairs(list) do
        out[i] = (type(b) == "table" and b.id ~= nil) and (LocalFirst.overlayBook(b, by_id[b.id])) or b
    end
    return out
end

-- Every saved record of a book in the body (any list), so a book started here that the server's
-- Continue reading lacks can be added without inventing a title or cover.
local function records(body)
    local out = {}
    local function add(list)
        for _, b in ipairs(type(list) == "table" and list or {}) do
            if type(b) == "table" and b.id ~= nil and not out[idKey(b.id)] then out[idKey(b.id)] = b end
        end
    end
    add(body.continueReading); add(body.finishedThisYear); add(body.discover)
    for _, list in pairs(type(body.boardShelves) == "table" and body.boardShelves or {}) do add(list) end
    if type(body.yearAgo) == "table" then add({ body.yearAgo.book }) end
    return out
end

-- The overlaid copy of a dashboard body. state.byBookId: { [bookId] = { percent (0-100),
-- status ("reading"|"complete"|"abandoned"), changedAt (epoch s), pending, blocked, retrying } }.
-- extra: more saved records (list pages) by id. Never modifies body.
-- Shelves that list books being read: a book finished (or put down) here leaves them at once.
LocalFirst.READING_SHELVES = { ["in-progress"] = true, ["pick-back-up"] = true }

local function byKey(by_id)
    local out = setmetatable({}, { __index = function(t, k)
        if type(k) ~= "string" and k ~= nil then return rawget(t, tostring(k)) end
    end })
    for k, v in pairs(by_id or {}) do out[tostring(k)] = v end
    return out
end

function LocalFirst.overlay(body, state, extra)
    if type(body) ~= "table" then return body end
    local by_id = byKey(state and state.byBookId)
    local out = copy(body)
    local known = records(body)
    for id, b in pairs(extra or {}) do if not known[idKey(id)] then known[idKey(id)] = b end end

    -- Continue reading: overlay; a book finished here leaves; one read here more recently than
    -- the head moves to the front; a book started here joins only with a saved record.
    local cr, seen = {}, {}
    for _, b in ipairs(type(body.continueReading) == "table" and body.continueReading or {}) do
        local o = LocalFirst.overlayBook(b, by_id[b.id])
        seen[idKey(b.id)] = true
        if o.readStatus ~= "read" and o.readStatus ~= "abandoned" then table.insert(cr, o) end
    end
    for id, loc in pairs(by_id) do
        if not seen[id] and loc.status == "reading" and known[id] then
            local o = LocalFirst.overlayBook(known[id], loc)
            if o ~= known[id] then table.insert(cr, o) end
        end
    end
    local function recent(b)
        local loc = by_id[b.id]
        local srv = LocalFirst.parseIso(b.lastReadAt) or 0
        if b.orbit_local and loc then return math.max(loc.changedAt or 0, srv) end
        return srv
    end
    local order = {}
    for i, b in ipairs(cr) do order[b] = i end
    table.sort(cr, function(a, b)
        local ra, rb = recent(a), recent(b)
        if a.orbit_local or b.orbit_local then
            if ra ~= rb then return ra > rb end
        end
        return order[a] < order[b]
    end)
    out.continueReading = cr

    -- Finished: pending local finishes join the front and count toward the goal until the
    -- server knows (the Xteink Home's localFinishedAtFetch rule).
    local finished = overlayList(body.finishedThisYear, by_id)
    local in_finished = {}
    for _, b in ipairs(finished or {}) do if type(b) == "table" then in_finished[idKey(b.id)] = true end end
    local added, front = 0, {}
    local ids = {}
    for id in pairs(by_id) do table.insert(ids, id) end
    table.sort(ids, function(a, b) return (by_id[a].changedAt or 0) > (by_id[b].changedAt or 0) end)
    for _, id in ipairs(ids) do
        local loc = by_id[id]
        if loc.status == "complete" and loc.pending and not in_finished[id] then
            local srv = known[id]
            if not (srv and srv.readStatus == "read") then
                added = added + 1
                if srv then table.insert(front, (LocalFirst.overlayBook(srv, loc))) end
            end
        end
    end
    if finished then
        for i = #front, 1, -1 do table.insert(finished, 1, front[i]) end
        out.finishedThisYear = finished
    end
    if added > 0 and type(body.readingGoal) == "table" then
        out.readingGoal = copy(body.readingGoal)
        out.readingGoal.completedBooks = (tonumber(body.readingGoal.completedBooks) or 0) + added
    end

    out.discover = overlayList(body.discover, by_id)
    if type(body.boardShelves) == "table" then
        out.boardShelves = {}
        for k, list in pairs(body.boardShelves) do
            local o = overlayList(list, by_id)
            if LocalFirst.READING_SHELVES[k] and type(o) == "table" then
                local kept = {}
                for _, b in ipairs(o) do
                    if not (type(b) == "table" and b.orbit_local and (b.readStatus == "read" or b.readStatus == "abandoned")) then
                        table.insert(kept, b)
                    end
                end
                o = kept
            end
            out.boardShelves[k] = o
        end
    end
    if type(body.yearAgo) == "table" and type(body.yearAgo.book) == "table" then
        out.yearAgo = copy(body.yearAgo)
        out.yearAgo.book = LocalFirst.overlayBook(body.yearAgo.book, by_id[body.yearAgo.book.id])
    end
    out.orbit_overlay = true
    return out
end

-- The "not synced" mark (lists only): with auto-sync on, only while the upload is blocked or
-- retrying; with it off, whenever the change waits.
function LocalFirst.notSynced(loc, auto_sync)
    if type(loc) ~= "table" then return false end
    if loc.blocked or loc.retrying then return true end
    return (not auto_sync) and loc.pending == true
end

---------------------------------------------------------------- freshness stamp

-- "just now", "12 min ago", "3 h ago", "2 d ago" (ages in min, h and d, as the Xteink Home tile).
function LocalFirst.age(seconds)
    seconds = math.max(0, seconds or 0)
    if seconds < 60 then return "just now" end
    if seconds < 3600 then return string.format("%d min ago", math.floor(seconds / 60)) end
    if seconds < 86400 then return string.format("%d h ago", math.floor(seconds / 3600)) end
    return string.format("%d d ago", math.floor(seconds / 86400))
end

-- s: { online, fetched_at (epoch s or nil), now, failed (the last refresh got no answer) }.
function LocalFirst.stamp(s)
    if not s.fetched_at then
        if not s.online then return "Offline" end
        return s.failed and "Not updated" or nil
    end
    local age = LocalFirst.age((s.now or 0) - s.fetched_at)
    if not s.online then return "Offline, saved " .. age end
    if s.failed then return "Not updated · saved " .. age end
    return "updated " .. age
end

---------------------------------------------------------------- what a refresh repaints

-- A stable string for a Lua value (sorted keys; functions and widgets skipped).
function LocalFirst.serialize(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" or t == "nil" then return tostring(v) end
    if t ~= "table" or depth > 6 then return "?" end
    local keys = {}
    for k in pairs(v) do
        if type(k) ~= "table" and type(v[k]) ~= "function" then table.insert(keys, k) end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
        table.insert(parts, tostring(k) .. "=" .. LocalFirst.serialize(v[k], depth + 1))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function booksKey(list)
    local parts = {}
    for _, b in ipairs(type(list) == "table" and list or {}) do
        local pct = tonumber(b.progressPercentage)
        table.insert(parts, table.concat({ tostring(b.id), pct and tostring(math.floor(pct + 0.5)) or "-",
            tostring(b.readStatus), b.on_device and "d" or "", tostring(b.cover_state) }, ":"))
    end
    return table.concat(parts, ",")
end

-- Tile types that repaint on their own timers: no content key (they never repaint for a refresh).
LocalFirst.TIMER_TILES = { clock = true, light = true, word = true }

-- The content key of one tile: the data that tile draws, from the board data d (overlaid). Any
-- type not listed keys on the whole of d, so a new upstream widget is never left stale.
function LocalFirst.tileKey(kind, d, source)
    if LocalFirst.TIMER_TILES[kind] then return "" end
    if kind == "hero" or kind == "also" or kind == "forecast" then
        return booksKey(d.continue_reading)
    elseif kind == "shelf" then
        return booksKey(d.shelves and d.shelves[source or ""])
    elseif kind == "goalpace" then
        local g = d.goal or {}
        return table.concat({ tostring(g.books), tostring(g.done), tostring(g.year) }, ":")
    elseif kind == "streak" or kind == "week" or kind == "today" or kind == "heatmap" or kind == "calendar" then
        return table.concat({ tostring(d.streak and d.streak.current), tostring(d.week_min), tostring(d.today_min) }, ":")
    elseif kind == "sync" then
        return tostring(d.last_sync_at) .. ":" .. tostring(d.online)
    elseif kind == "link" then
        return LocalFirst.serialize(d.counts)
    elseif kind == "highlight" then
        return LocalFirst.serialize(d.highlight)
    elseif kind == "yearago" then
        return LocalFirst.serialize(d.year_ago)
    elseif kind == "records" or kind == "hours" then
        return LocalFirst.serialize({ d.streak, d.heatmap })
    end
    local stripped = {}
    for k, v in pairs(d) do
        if k ~= "now" and k ~= "clock" and k ~= "fingerprint" and k ~= "greeting" and k ~= "updated" then stripped[k] = v end
    end
    return LocalFirst.serialize(stripped)
end

-- What changed in one tile, for the log: per book "book <id> <field> <old> -> <new>" (percent,
-- status, on device, cover), books added or removed, the order; else "content".
local BOOK_FIELDS = { "id", "percent", "status", "on device", "cover" }
local function split(s, sep)
    local out = {}
    if s == "" then return out end
    for part in (s .. sep):gmatch("(.-)" .. sep) do table.insert(out, part) end
    return out
end
function LocalFirst.tileDiff(kind, old_d, new_d, source)
    local a, b = LocalFirst.tileKey(kind, old_d, source), LocalFirst.tileKey(kind, new_d, source)
    if a == b then return nil end
    if not (kind == "hero" or kind == "also" or kind == "forecast" or kind == "shelf") then return "content" end
    local old_by, old_order, new_order, out = {}, {}, {}, {}
    for _, part in ipairs(split(a, ",")) do
        local f = split(part, ":")
        old_by[f[1]] = f
        table.insert(old_order, f[1])
    end
    local seen = {}
    for _, part in ipairs(split(b, ",")) do
        local f = split(part, ":")
        seen[f[1]] = true
        table.insert(new_order, f[1])
        local o = old_by[f[1]]
        if not o then
            table.insert(out, "book " .. f[1] .. " added")
        else
            for j = 2, #BOOK_FIELDS do
                if o[j] ~= f[j] then
                    local function show(v)
                        if j == 4 then return v == "d" and "yes" or "no" end
                        return (v == nil or v == "") and "-" or v
                    end
                    table.insert(out, string.format("book %s %s %s -> %s", f[1], BOOK_FIELDS[j], show(o[j]), show(f[j])))
                end
            end
        end
    end
    for _, id in ipairs(old_order) do if not seen[id] then table.insert(out, "book " .. id .. " removed") end end
    if #out == 0 and table.concat(old_order, ",") ~= table.concat(new_order, ",") then table.insert(out, "order") end
    return #out > 0 and table.concat(out, "; ") or "content"
end

-- Which tiles changed between two boards. tiles: { { key = id, kind, source } } (the same set on
-- both). Returns the changed ids, or nil when the tile set itself differs (a full repaint).
function LocalFirst.changedTiles(old_tiles, new_tiles, old_d, new_d)
    if #old_tiles ~= #new_tiles then return nil end
    local changed = {}
    for i, t in ipairs(new_tiles) do
        local o = old_tiles[i]
        if o.key ~= t.key or o.kind ~= t.kind or o.source ~= t.source then return nil end
        if LocalFirst.tileKey(t.kind, old_d, t.source) ~= LocalFirst.tileKey(t.kind, new_d, t.source) then
            table.insert(changed, t.key)
        end
    end
    return changed
end

-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- The offline cache's reads (docs/design/sqlite-cache.md "How KOReader reads"): orbit-cache/orbit.db,
-- which only Orbit Companion writes (CacheStore.kt). A list page is one primary-key range of
-- positions joined to the books they name, a detail one row by book id, anything else one row by
-- key, an offline search one scan of the books' short search text. Each read is one read
-- transaction (one snapshot) and decodes only the rows it returns: nothing here reads a whole file.
-- A busy or broken database is a miss, never an error on screen.
---------------------------------------------------------------------------------------------

Store = { VERSION = 1, FILE = "orbit.db" }

function Store.path() return OC.dir() .. "/" .. Store.FILE end

local function txt(v) return Db.value(v) end
local function val(v)
    local s = Db.value(v)
    if type(s) ~= "string" then return nil end
    return Cache.decode(s)
end

-- The connection, when the file is there, of our schema and owned by owner.
function Store.conn(owner)
    local conn, err = Db.conn(Store.path())
    if not conn then return nil, err end
    local okv, v = pcall(conn.rowexec, conn, "PRAGMA user_version")
    if not okv then return nil, v end
    if tonumber(Db.value(v)) ~= Store.VERSION then return nil, "version " .. tostring(Db.value(v)) end
    if owner then
        local oko, o = pcall(Store.meta, conn, "owner")
        if not oko then return nil, o end
        if o ~= owner then return nil, "another owner" end
    end
    return conn
end

-- Runs fn(conn) in one read transaction. -> fn's result, or nil (logged once per kind of failure).
local function within(owner, what, fn)
    local conn, err = Store.conn(owner)
    if not conn then
        if err ~= "missing" and Store.last_err ~= tostring(err) then log("store:", what, "not read:", tostring(err)) end
        Store.last_err = tostring(err)
        return nil
    end
    local okb = pcall(conn.exec, conn, "BEGIN")
    local okf, r1, r2 = pcall(fn, conn)
    if okb then pcall(conn.exec, conn, "COMMIT") end
    if not okf then
        log("store:", what, "failed:", (tostring(r1):gsub("\n.*", "")))
        return nil
    end
    Store.last_err = nil
    return r1, r2
end

-- Rows of a prepared query: { row, ... }, each { col1, col2, ... } as Lua values (blobs as strings).
local function rows(conn, sql, ...)
    local st = conn:prepare(sql)
    if select("#", ...) > 0 then st:bind(...) end
    local out, ncol = {}, st:_ncol()
    while true do
        local r = st:step()
        if not r then break end
        local row = {}
        for i = 1, ncol do row[i] = txt(r[i]) end
        table.insert(out, row)
    end
    st:close()
    return out
end
Store.rows = rows

function Store.meta(conn, k)
    local r = rows(conn, "SELECT v FROM meta WHERE k = ?", k)[1]
    return r and r[1] or nil
end

-- A list window. -> entry { body, validated_at } or nil when a position isn't saved.
local function list(conn, w)
    local l = rows(conn, "SELECT kind, total, head, validated_at FROM lists WHERE identity = ?", w.identity)[1]
    if not l then return nil end
    local total = tonumber(l[2]) or 0
    local start, stop, size = Cache.window(l[1] or w.kind, total, w.page, w.size, w.offset)
    local got = rows(conn, "SELECT li.pos, COALESCE(b.item, li.item) FROM list_items li LEFT JOIN books b ON b.id = li.book_id "
        .. "WHERE li.identity = ? AND li.pos >= ? AND li.pos < ? ORDER BY li.pos", w.identity, start, stop)
    if #got ~= stop - start then return nil end
    local items = {}
    for i, r in ipairs(got) do
        local item = Cache.decode(r[2] or "")
        if type(item) ~= "table" then return nil end
        items[i] = item
    end
    return { body = Cache.assemble(Cache.decode(l[3] or ""), items, total, start, stop, size, w.offset),
        validated_at = tonumber(l[4]) or 0, table = "lists" }
end

-- What the cache holds for a read (OC.lookup): { key, body, validated_at, stale, path } or nil.
-- template: the plugin's detail request with Mirror.SENTINEL for the id (Mirror.detailPath).
function Store.read(owner, key, path, template)
    return within(owner, "read", function(conn)
        local w = Cache.listWindow(path)
        local e
        if w then
            e = list(conn, w)
        else
            local id = Cache.detailId(path, template, Mirror.SENTINEL)
            if id then
                local r = rows(conn, "SELECT detail, detail_at FROM books WHERE id = ? AND detail IS NOT NULL", id)[1]
                local body = r and Cache.decode(r[1] or "")
                if type(body) == "table" then e = { body = body, validated_at = tonumber(r[2]) or 0, table = "books" } end
            else
                local r = rows(conn, "SELECT body, validated_at, stale FROM entries WHERE key = ?", key)[1]
                local body = r and Cache.decode(r[1] or "")
                if type(body) == "table" then e = { body = body, validated_at = tonumber(r[2]) or 0, stale = tonumber(r[3]) == 1 or nil, table = "entries" } end
            end
        end
        if e then e.key, e.path = key, path end
        return e
    end)
end

-- An offline search over the saved books (title, authors, series): the server's list shape.
function Store.search(owner, path)
    local q = Cache.parseQuery((tostring(path):match("%?(.*)$")) or "")
    local words = Cache.searchWords(q.q)
    if #words == 0 then return nil end
    return within(owner, "search", function(conn)
        local where = {}
        for _ in ipairs(words) do table.insert(where, "search LIKE ? ESCAPE '\\'") end
        local cond = "item IS NOT NULL AND " .. table.concat(where, " AND ")
        local total = tonumber(rows(conn, "SELECT count(*) FROM books WHERE " .. cond, unpack(words))[1][1]) or 0
        local start, stop, size = Cache.window("books", total, q.page, q.size, q.offset)
        local args = { unpack(words) }
        table.insert(args, stop - start)
        table.insert(args, start)
        local items = {}
        for _, r in ipairs(rows(conn, "SELECT item FROM books WHERE " .. cond .. " ORDER BY search LIMIT ? OFFSET ?", unpack(args))) do
            local item = Cache.decode(r[1] or "")
            if type(item) == "table" then table.insert(items, item) end
        end
        return Cache.assemble({ query = q.q }, items, total, start, stop, size, q.offset)
    end)
end

-- "Save every cover for offline" keeps this cover file (the plugin's pruner asks per file).
function Store.coverKept(owner, name)
    return within(owner, "cover", function(conn)
        return rows(conn, "SELECT 1 FROM cover_keep WHERE name = ?", name)[1] ~= nil
    end) == true
end

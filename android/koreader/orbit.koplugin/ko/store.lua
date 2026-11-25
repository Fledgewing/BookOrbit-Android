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

Store = { ui_pid = Db.pid(), VERSION = 1, FILE = "orbit.db", memo = {}, memo_order = {} }

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
    local while_reading = Db.pid() == Store.ui_pid and not (OC and OC.child) and reading and reading()
    if while_reading and not OC._dir then return nil end
    local memo_key = Store.path() .. "|" .. tostring(owner) .. "|" .. what
    local function fallback(err)
        if Db.code(err) == "busy" or Db.code(err) == "locked" then
            local m = Store.memo[memo_key]
            if m then return m[1], m[2] end
        end
    end
    -- No SQLite open/stat/PRAGMA/queries on the reading path, even on a miss.
    -- Several short busy waits in one event can still exceed the tap budget.
    -- Only a previously decoded result is safe here; refresh outside reading.
    if while_reading then
        local m = Store.memo[memo_key]
        if m then return m[1], m[2] end
        return nil
    end
    local conn, err = Store.conn(owner)
    if not conn then
        if err ~= "missing" and Store.last_err ~= tostring(err) then log("store:", what, "not read:", tostring(err)) end
        Store.last_err = tostring(err)
        return fallback(err)
    end
    local okb = pcall(conn.exec, conn, "BEGIN")
    local okf, r1, r2 = pcall(fn, conn)
    if okb then pcall(conn.exec, conn, "COMMIT") end
    if not okf then
        log("store:", what, "failed:", (tostring(r1):gsub("\n.*", "")))
        return fallback(r1)
    end
    Store.last_err = nil
    if r1 ~= nil then
        if not Store.memo[memo_key] then
            table.insert(Store.memo_order, memo_key)
            if #Store.memo_order > 64 then Store.memo[table.remove(Store.memo_order, 1)] = nil end
        end
        Store.memo[memo_key] = { r1, r2 }
    else Store.memo[memo_key] = nil end
    return r1, r2
end

-- Rows of a prepared query: { row, ... }, each { col1, col2, ... } as Lua values (blobs as strings).
local function rows(conn, sql, ...)
    local st = conn:prepare(sql)
    local args = { n = select("#", ...), ... }
    local okr, result = pcall(function()
        if args.n > 0 then st:bind(unpack(args, 1, args.n)) end
        local out, ncol = {}, st:_ncol()
        while true do
            local r = st:step()
            if not r then break end
            local row = {}
            for i = 1, ncol do row[i] = txt(r[i]) end
            table.insert(out, row)
        end
        return out
    end)
    st:close()
    if not okr then error(result, 0) end
    return result
end
Store.rows = rows

function Store.meta(conn, k)
    local r = rows(conn, "SELECT v FROM meta WHERE k = ?", k)[1]
    return r and r[1] or nil
end

-- Bulk-generation windows: SQL filters/ranks use bound values and decode only this window.
-- Network, JSON parsing and index construction belong to the companion.
local function bulk_list(conn, w)
    local g = tonumber(Store.meta(conn, "bulk_active"))
    if not g then return nil end
    local q = Cache.parseQuery(w.identity:match("%?(.*)$") or "")
    local statusarg
    local args, from, cond, order, context = {g}, "bulk_books b", {"b.g=?"}, nil, false
    if w.section then
        from, cond, args = "bulk_sections b", {"b.g=?", "b.section=?"}, {g, w.section}
        if q.sort == "name_desc" then from = from .. " JOIN bulk_section_ranks r ON r.g=b.g AND r.section=b.section AND r.id=b.id AND r.direction='name_desc'" end
        if q.filter then
            if q.filter ~= "reading" and q.filter ~= "finished" then return nil end
            table.insert(cond, "b." .. q.filter .. ">0")
        end
        order = q.sort == "books" and "b.n DESC,b.pos" or q.sort == "name_desc" and "r.pos" or "b.pos"
    else
        if q.q and q.q ~= "" then return nil end
        local sort = q.sort or "recently_added"
        local dir = q.order or (sort:match("^recently_") and "desc" or "asc")
        if dir ~= "asc" and dir ~= "desc" then return nil end
        local d = dir:upper()
        local sid = q.seriesId or (q.series and q.series:match("^series:(%d+)$"))
        context = not q.smartScopeId and (sid ~= nil or q.series ~= nil)
        if context then
            from = from .. " JOIN bulk_members s ON s.g=b.g AND s.id=b.id AND s.kind=? AND s.value=?"
            table.insert(args, 1, sid or q.series:match("^%s*(.-)%s*$"):lower())
            table.insert(args, 1, sid and "seriesId" or "series")
        end
        local selectors = q.smartScopeId and {"smartScopeId"} or {"libraryId", "collectionId", "author", "format"}
        for _, k in ipairs(selectors) do
            if q[k] and q[k] ~= "" then
                table.insert(cond, "EXISTS (SELECT 1 FROM bulk_members m WHERE m.g=b.g AND m.id=b.id AND m.kind=? AND m.value=?)")
                table.insert(args, k); table.insert(args, q[k])
            end
        end
        if not q.smartScopeId then
            if q.readStatus then table.insert(cond, "b.status=?"); table.insert(args, q.readStatus); statusarg = #args end
            if q.ids then
                local marks, count = {}, 0
                for id in q.ids:gmatch("[^,]+") do
                    if id:match("^%d+$") and count < 200 then
                        table.insert(marks, "?"); table.insert(args, tonumber(id)); count = count + 1
                    end
                end
                table.insert(cond, #marks == 0 and "0" or "b.id IN (" .. table.concat(marks, ",") .. ")")
            end
        end
        if sort == "title" then
            from = from .. " JOIN bulk_ranks r ON r.g=b.g AND r.id=b.id AND r.kind=? AND r.direction=?"
            local n = context and 3 or 1
            table.insert(args, n, sort); table.insert(args, n + 1, dir)
            if statusarg then statusarg = statusarg + 2 end
            order = "r.pos"
        elseif sort == "series" then
            local p = context and "s" or "b"
            order = (context and "" or "b.series IS NULL,b.series " .. d .. ",")
                .. p .. ".ix1 IS NULL," .. p .. ".ix1 " .. d .. "," .. p .. ".ix2 " .. d .. "," .. p .. ".ix " .. d .. ","
                .. (context and "b.title IS NULL,b.title," or "") .. "b.id"
        elseif sort == "recently_added" or sort == "recently_updated" then
            order = "b." .. (sort == "recently_added" and "added" or "updated") .. " " .. d .. ",b.id"
        elseif sort == "author" or sort == "published" or sort == "recently_read" then
            from = from .. " JOIN bulk_ranks r ON r.g=b.g AND r.id=b.id AND r.kind=? AND r.direction=?"
            local n = context and 3 or 1
            table.insert(args, n, sort); table.insert(args, n + 1, dir)
            if statusarg then statusarg = statusarg + 2 end
            order = "r.pos"
        else return nil end
    end
    from = from .. " WHERE " .. table.concat(cond, " AND ")
    local total = tonumber(rows(conn, "SELECT count(*) FROM " .. from, unpack(args))[1][1]) or 0
    local start, stop, size = Cache.window(w.kind, total, w.page, w.size, w.offset)
    local h = rows(conn, "SELECT head FROM bulk_heads WHERE g=? AND identity=?",g,w.identity)[1]
    local head = h and Cache.decode(h[1] or "") or {}
    if not w.section and q.buckets == "1" and (q.sort == "title" or q.sort == "author") then
        head.buckets = {}
        for _, b in ipairs(rows(conn, "SELECT r.letter,min(r.pos),count(*) FROM " .. from .. " GROUP BY r.letter ORDER BY min(r.pos)", unpack(args))) do
            local a = {unpack(args)}; table.insert(a, tonumber(b[2]))
            local index = tonumber(rows(conn, "SELECT count(*) FROM " .. from .. " AND r.pos<?", unpack(a))[1][1]) or 0
            table.insert(head.buckets, {key=b[1] or "#", index=index, count=tonumber(b[3]) or 0})
        end
    end
    if w.section and (w.section=="authors" or w.section=="series") and q.sort~="books" then
        head.buckets={}
        local pos=q.sort=="name_desc" and "r.pos" or "b.pos"
        for _,b in ipairs(rows(conn,"SELECT b.letter,min(" .. pos .. "),count(*) FROM " .. from .. " GROUP BY b.letter ORDER BY min(" .. pos .. ")",unpack(args))) do
            local a={unpack(args)};table.insert(a,tonumber(b[2]))
            local index=tonumber(rows(conn,"SELECT count(*) FROM " .. from .. " AND " .. pos .. "<?",unpack(a))[1][1]) or 0
            table.insert(head.buckets,{key=b[1] or "#",index=index,count=tonumber(b[3]) or 0})
        end
    end
    if context then
        local a = {unpack(args)}
        local scope = from
        if statusarg then table.remove(a, statusarg); scope = scope:gsub(" AND b.status=%?", "") end
        local counts = {}
        for _, r in ipairs(rows(conn, "SELECT b.status,count(*) FROM " .. scope .. " GROUP BY b.status", unpack(a))) do counts[r[1]] = tonumber(r[2]) end
        head.seriesSummary = {total=total, reading=counts.reading or 0, finished=counts.finished or 0}
    end
    table.insert(args, stop-start); table.insert(args, start)
    local got = rows(conn, "SELECT " .. (w.section and "b.item" or "b.item" .. (context and ",s.context" or ""))
        .. " FROM " .. from .. " ORDER BY " .. order .. " LIMIT ? OFFSET ?", unpack(args))
    local items = {}
    for _, row in ipairs(got) do
        local book = Cache.decode(row[1] or "")
        if type(book) ~= "table" then return nil end
        if context then for k, v in pairs(Cache.decode(row[2] or "") or {}) do book[k] = v end end
        table.insert(items, book)
    end
    return {body=Cache.assemble(head, items, total, start, stop, size, w.offset),
        validated_at=tonumber(Store.meta(conn, "bulk_at")) or 0, table="lists"}
end

-- A list window. -> entry { body, validated_at } or nil when a position isn't saved.
local function list(conn, w)
    if Store.meta(conn, "bulk_active") then return bulk_list(conn, w) end
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
    return within(owner, "read:" .. key, function(conn)
        local w = Cache.listWindow(path)
        local e
        if w then
            e = list(conn, w)
        else
            local id = Cache.detailId(path, template, Mirror.SENTINEL)
            if id then
                local r = rows(conn, "SELECT detail, detail_at FROM books WHERE id = ? AND detail IS NOT NULL", id)[1]
                local body = r and Cache.decode(r[1] or "")
                if type(body) == "table" then e = { body = body, validated_at = tonumber(r[2]) or 0, table = "books" }
                elseif Store.meta(conn, "bulk_active") then
                    local stub = rows(conn, "SELECT item FROM bulk_books WHERE g = ? AND id = ?", tonumber(Store.meta(conn, "bulk_active")), id)[1]
                    local item = stub and Cache.decode(stub[1] or "")
                    if type(item) == "table" then e = {body=item, validated_at=0, stale=true, table="books", partial=true} end
                end
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
    return within(owner, "search:" .. path, function(conn)
        local where = {}
        for _ in ipairs(words) do table.insert(where, "search LIKE ? ESCAPE '\\'") end
        local bulk = tonumber(Store.meta(conn, "bulk_active"))
        local source = bulk and "books b JOIN bulk_books c ON c.id=b.id AND c.g=" .. bulk or "books"
        local item = bulk and "c.item" or "item"
        local cond = item .. " IS NOT NULL AND " .. table.concat(where, " AND ")
        local total = tonumber(rows(conn, "SELECT count(*) FROM " .. source .. " WHERE " .. cond, unpack(words))[1][1]) or 0
        local start, stop, size = Cache.window("books", total, q.page, q.size, q.offset)
        local args = { unpack(words) }
        table.insert(args, stop - start)
        table.insert(args, start)
        local items = {}
        for _, r in ipairs(rows(conn, "SELECT " .. item .. " FROM " .. source .. " WHERE " .. cond .. " ORDER BY search LIMIT ? OFFSET ?", unpack(args))) do
            local item = Cache.decode(r[1] or "")
            if type(item) == "table" then table.insert(items, item) end
        end
        return Cache.assemble({ query = q.q }, items, total, start, stop, size, q.offset)
    end)
end

-- The companion's last storage count: { totals = { used, kept, cache, cover, mirror_cover }, at } or nil.
function Store.storage(owner)
    return within(owner, "storage", function(conn)
        local v = Store.meta(conn, "storage")
        local t = v and Cache.decode(v)
        return type(t) == "table" and t or nil
    end)
end

-- "Save every cover for offline" keeps this cover file (the plugin's pruner asks per file).
function Store.coverKept(owner, name)
    return within(owner, "cover:" .. name, function(conn)
        return rows(conn, "SELECT 1 FROM cover_keep WHERE name = ?", name)[1] ~= nil
    end) == true
end

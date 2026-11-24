-- The companion's side of the offline cache's database (CacheStore.kt), played by the tests: it
-- creates orbit.db from shared/fixtures/cache/schema.sql and saves replies the way
-- CacheStore.save does, so the plugin's reads (ko/store.lua) can be checked against the same
-- shared fixture (shared/fixtures/cache/db.json) CacheStoreTest uses. Test code: nothing ships.
--   local FS = dofile("fake_store.lua")(Cache, SQ3, schema_path)
--   local st = FS.open(path); st:own(owner); st:save(key, path, reply, at, template); st:close()
return function(Cache, SQ3, schema_path)
    local FS = { SENTINEL = "987654321" }
    local PAGING = { items = true, page = true, size = true, offset = true, hasNext = true, hasPrevious = true,
        nextUrl = true, previousUrl = true }

    local function schema()
        local f = assert(io.open(schema_path, "rb"))
        local out = {}
        for line in f:lines() do
            if line ~= "" and not line:match("^%-%-") then table.insert(out, (line:gsub(";%s*$", ""))) end
        end
        f:close()
        return out
    end

    local S = {}
    S.__index = S

    function FS.open(path)
        local conn = SQ3.open(path, "rwc")
        conn:exec("PRAGMA journal_mode=TRUNCATE")
        local v = tonumber(conn:rowexec("PRAGMA user_version")) or 0
        if v == 0 then
            conn:exec("BEGIN")
            for _, stmt in ipairs(schema()) do conn:exec(stmt) end
            conn:exec("COMMIT")
            conn:exec("PRAGMA user_version = 1")
        end
        return setmetatable({ conn = conn, path = path }, S)
    end

    function S:run(sql, ...)
        local st = self.conn:prepare(sql)
        if select("#", ...) > 0 then st:bind(...) end
        local out = {}
        while true do
            local r = st:step()
            if not r then break end
            local row = {}
            for i = 1, st:_ncol() do row[i] = r[i] end
            table.insert(out, row)
        end
        st:close()
        return out
    end

    function S:close() self.conn:close() end
    function S:begin() self.conn:exec("BEGIN IMMEDIATE") end
    function S:commit() self.conn:exec("COMMIT") end

    function S:own(owner)
        self:run("INSERT OR REPLACE INTO meta (k, v) VALUES ('owner', ?)", owner)
    end

    function FS.searchText(b)
        return table.concat({ tostring(b.title or ""), table.concat(type(b.authors) == "table" and b.authors or {}, ", "),
            tostring(b.seriesName or "") }, "\n")
    end

    function S:putItem(item, at)
        local id = tonumber(item.id)
        if not id then return end
        self:run("INSERT OR IGNORE INTO books (id) VALUES (?)", id)
        self:run("UPDATE books SET item = ?, item_at = ?, search = ? WHERE id = ?", Cache.encode(item), at, FS.searchText(item), id)
    end

    function S:putDetail(id, body, at)
        self:run("INSERT OR IGNORE INTO books (id) VALUES (?)", id)
        self:run("UPDATE books SET detail = ?, detail_at = ? WHERE id = ?", Cache.encode(body), at, id)
    end

    function S:putWindow(identity, kind, section, offset, body, at)
        local items = type(body.items) == "table" and body.items or {}
        local total = tonumber(body.total) or (offset + #items)
        local known = self:run("SELECT total FROM lists WHERE identity = ?", identity)[1] ~= nil
        local head
        if offset == 0 then
            head = {}
            for k, v in pairs(body) do if not PAGING[k] then head[k] = v end end
            head = Cache.encode(head)
        end
        if not known then
            self:run("INSERT INTO lists (identity, kind, section, total, head, fetched_at, validated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                identity, kind, section, total, head, at, at)
        else
            self:run("UPDATE lists SET total = ?, fetched_at = ?, validated_at = ? WHERE identity = ?", total, at, at, identity)
            if head then self:run("UPDATE lists SET head = ? WHERE identity = ?", head, identity) end
        end
        self:run("DELETE FROM list_items WHERE identity = ? AND pos >= ?", identity, total)
        for i, item in ipairs(items) do
            local pos = offset + i - 1
            if kind == "books" and tonumber(item.id) then
                self:putItem(item, at)
                self:run("INSERT OR REPLACE INTO list_items (identity, pos, book_id, item) VALUES (?, ?, ?, NULL)", identity, pos, tonumber(item.id))
            else
                self:run("INSERT OR REPLACE INTO list_items (identity, pos, book_id, item) VALUES (?, ?, NULL, ?)", identity, pos, Cache.encode(item))
            end
        end
    end

    -- CacheStore.save: a reply stored where the plugin's read finds it.
    function S:save(key, path, reply, at, template)
        local w = Cache.listWindow(path)
        self:begin()
        if w and type(reply) == "table" then
            local q = Cache.parseQuery((tostring(path):match("%?(.*)$")) or "")
            local size = tonumber(q.size) or (w.kind == "books" and 20 or #(reply.items or {}))
            local offset = tonumber(q.offset) or ((tonumber(q.page) or 1) - 1) * math.max(1, size)
            self:putWindow(w.identity, w.kind, w.section, offset, reply, at)
        else
            local id = Cache.detailId(path, template, FS.SENTINEL)
            if id then self:putDetail(id, reply, at)
            else
                local s = Cache.encode(reply)
                self:run("INSERT OR REPLACE INTO entries (key, path, body, fetched_at, validated_at, home, stale, bytes) VALUES (?, ?, ?, ?, ?, ?, NULL, ?)",
                    key, path, s, at, at, Cache.isHome(path) and 1 or nil, #s)
            end
        end
        self:commit()
    end

    return FS
end

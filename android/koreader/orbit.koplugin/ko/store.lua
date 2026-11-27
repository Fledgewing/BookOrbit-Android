-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
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

local lfs_ok,lfs=pcall(require,"libs/libkoreader-lfs")
function Store.defaultDirectory()
    if Store._dir then return Store._dir end
    local okd, DataStorage = pcall(require, "datastorage")
    local base = okd and DataStorage:getSettingsDir() or "."
    Store._dir = base .. "/orbit-cache"
    if lfs_ok then
        lfs.mkdir(Store._dir)
        lfs.mkdir(Store._dir .. "/events")
    end
    return Store._dir
end

function Store.readFile(path, max)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read(max or "*a")
    f:close()
    return s
end

-- Atomic: a temp file renamed over the target.
function Store.writeFile(path, s)
    local tmp = path .. ".tmp" .. tostring(math.random(1, 1e9))
    local f = io.open(tmp, "wb")
    if not f then return false end
    local okw = f:write(s)
    f:close()
    if not okw then os.remove(tmp); return false end
    if not os.rename(tmp, path) then os.remove(tmp); return false end
    return true
end


Store.directory=Store.defaultDirectory
Store.directoryReady=function() return Store._dir~=nil end
Store.inChild=function() return false end
Store.now=os.time
function Store.dir() return Store.directory() end

function Store.path() return Store.dir() .. "/" .. Store.FILE end

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
local function within(owner, what, fn, user_surface)
    local while_reading = Db.pid() == Store.ui_pid and not Store.inChild() and reading and reading()
        and not (Library and Library.catalog_opening) and not user_surface
    if while_reading and not Store.directoryReady() then return nil end
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
Store.within = within

-- Ready-to-draw 0.12 results: one row, size checked by SQLite before decoding.
-- Reuse the same owner/reading/busy gate as all existing cache reads.
function Store.library(owner, request, user_surface)
    -- Device rows share this DB without claiming or reading the catalog's owner.
    local catalog_owner = owner ~= "device-local" and owner or nil
    return within(catalog_owner, "library:" .. request, function(conn)
        local r = rows(conn, "SELECT body FROM library_views WHERE owner=? AND request=? AND length(body)<=16384",
            owner, request)[1]
        local body = r and r[1]
        if type(body) ~= "string" then return nil end
        return Cache.decode(body), #body
    end,user_surface)
end

function Store.meta(conn, k)
    local r = rows(conn, "SELECT v FROM meta WHERE k = ?", k)[1]
    return r and r[1] or nil
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

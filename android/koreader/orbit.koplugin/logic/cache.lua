-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- The write-through cache's rules (docs/design/write-through-cache.md), pure so that
-- shared/fixtures/cache/cases.json can check them: keys, what is cached, when a read is served
-- and/or fetched, whether a reply changed and what a write sends the companion. Rules only the
-- companion runs (settle, mirror paging and retries, patching, covers, the storage limit) are its
-- own (MirrorLogic, CacheStore, CacheWorker); the fake companion's copies are test/companion_rules.lua.
-- The store, the request wrapper and the views are ko/cache.lua.
---------------------------------------------------------------------------------------------

Cache = {
    FRESH_S = 60,          -- a read within this of the last check is not checked again
    VERSION = 1,
    MIRROR_PAGE = 100,     -- the server's largest page (koreader-catalog-query.dto.ts:87, :284)
    MIRROR_TTL_DAYS = 7,   -- an automatic Full refresh once the mirror is older than this
}

---------------------------------------------------------------- values

-- A canonical Lua literal of v: sorted keys, so equal bodies give equal strings; loadable back
-- with Cache.decode. Functions and userdata are dropped.
function Cache.encode(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "0" end
        if v == math.floor(v) and math.abs(v) < 2^53 then return string.format("%d", v) end
        return string.format("%.17g", v)
    end
    if t == "boolean" then return tostring(v) end
    if t ~= "table" or depth > 40 then return "nil" end
    local n = #v
    local parts = {}
    for i = 1, n do table.insert(parts, Cache.encode(v[i], depth + 1)) end
    local keys = {}
    for k, val in pairs(v) do
        local kt = type(k)
        local vt = type(val)
        if vt ~= "function" and vt ~= "userdata" and vt ~= "thread"
            and not (kt == "number" and k >= 1 and k <= n and k == math.floor(k)) and (kt == "string" or kt == "number") then
            table.insert(keys, k)
        end
    end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return type(a) == "number"
    end)
    for _, k in ipairs(keys) do
        local ks = type(k) == "string" and string.format("[%q]", k) or ("[" .. Cache.encode(k) .. "]")
        table.insert(parts, ks .. "=" .. Cache.encode(v[k], depth + 1))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

function Cache.decode(s)
    if type(s) ~= "string" or s == "" then return nil end
    local fn = loadstring("return " .. s)
    if not fn then return nil end
    setfenv(fn, {})
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

function Cache.copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = Cache.copy(x) end
    return out
end

---------------------------------------------------------------- keys and scope

local function splitPath(path)
    local p, q = tostring(path or ""):match("^([^?]*)%??(.*)$")
    return p, q
end

local function unescape(s)
    return (s:gsub("+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- { name = value } from a query string.
function Cache.parseQuery(q)
    local out = {}
    for pair in tostring(q or ""):gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        if k and k ~= "" then out[unescape(k)] = unescape(v or "") end
    end
    return out
end

local function normQuery(query)
    local keys = {}
    for k, v in pairs(query or {}) do
        if v ~= nil and tostring(v) ~= "" then table.insert(keys, tostring(k)) end
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do table.insert(parts, k .. "=" .. tostring(query[k])) end
    return table.concat(parts, "&")
end

local function escape(v)
    return (tostring(v):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- normQuery, escaped for a request.
local function encQuery(query)
    local keys = {}
    for k, v in pairs(query or {}) do
        if v ~= nil and tostring(v) ~= "" then table.insert(keys, tostring(k)) end
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do table.insert(parts, escape(k) .. "=" .. escape(query[k])) end
    return table.concat(parts, "&")
end

local function normServer(s)
    return (tostring(s or ""):lower():gsub("/+$", ""))
end

-- r: { account, server, method, path, query }. path may carry its own "?query".
-- FNV-1a, 32 bits, as hex: an entry's file name (the companion's MirrorLogic.hash is the same,
-- shared/fixtures/cache/worker.json).
function Cache.hash(s)
    local bit = require("bit")
    local h = 2166136261
    for i = 1, #s do
        h = bit.bxor(h, s:byte(i))
        h = bit.tobit(h * 16777619 % 4294967296)
    end
    return string.format("%08x", h % 4294967296)
end

-- 8551 -> "8,551" (the Full refresh indicator).
function Cache.count(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

function Cache.key(r)
    local path, q = splitPath(r.path)
    local query = Cache.parseQuery(q)
    for k, v in pairs(r.query or {}) do query[k] = v end
    return table.concat({ tostring(r.account or ""), normServer(r.server), tostring(r.method or "GET"):upper(),
        path, normQuery(query) }, "|")
end

-- Catalog reads only; never covers, downloads, auth, version or sync.
function Cache.cacheable(method, path)
    if tostring(method or ""):upper() ~= "GET" then return false end
    local p = splitPath(path)
    if not (p:find("^/koreader/plugin/catalog/") or p:find("^/plugin/catalog/")) then return false end
    if p:find("/thumbnail$") or p:find("/photo$") or p:find("/download") or p:find("/files/") then return false end
    return true
end

---------------------------------------------------------------- reads

-- entry: nil or { validated_at }; mode: "open" | "refresh" | "full". -> serve, fetch.
-- entry.stale: a write since may have changed it (served, checked at once).
function Cache.readPlan(entry, now, mode, offline)
    if mode == "full" then
        if offline then return entry ~= nil, false end
        return false, true
    end
    if not entry then return false, not offline end
    if offline then return true, false end
    if mode == "refresh" or entry.stale then return true, true end
    return true, (now - (entry.validated_at or 0)) >= Cache.FRESH_S
end

-- Fields that differ on every request and say nothing about the data: generatedAt is the
-- server's clock (koreader-catalog.service.ts:279); discover is a fresh random pick each time
-- (:417-433, getRandomBooks), so a check never counts it and the saved pick is kept until a
-- Full refresh.
Cache.VOLATILE = { generatedAt = true }
Cache.KEEP_SAVED = { discover = true }

function Cache.normalize(body)
    if type(body) ~= "table" then return body end
    local out = {}
    for k, v in pairs(body) do
        if not Cache.VOLATILE[k] and not Cache.KEEP_SAVED[k] then out[k] = v end
    end
    return out
end

-- -> changed, stored
function Cache.revalidate(cached, reply, status)
    if type(status) ~= "number" or status < 200 or status >= 300 or reply == nil then return false, false end
    return Cache.encode(Cache.normalize(cached)) ~= Cache.encode(Cache.normalize(reply)), true
end

---------------------------------------------------------------- the offline mirror

-- A list read (a books page or a section page): its identity (the path without page, size and
-- offset) and the window it asks for. nil for anything else (a book, the dashboard, a search).
function Cache.listWindow(path)
    local p, q = splitPath(path)
    local books = p:find("/catalog/books$") ~= nil
    local section = p:match("/catalog/sections/([%w%-]+)$")
    if not books and not section then return nil end
    local query = Cache.parseQuery(q)
    if query.q and query.q ~= "" then return nil end -- search stays online
    local w = { page = tonumber(query.page), size = tonumber(query.size), offset = tonumber(query.offset),
        kind = books and "books" or "section", section = section }
    query.page, query.size, query.offset = nil, nil, nil
    local rest = encQuery(query)
    w.identity = p .. (rest ~= "" and ("?" .. rest) or "")
    return w
end

-- A search: never mirrored; offline it says it needs a connection.
function Cache.isSearch(path)
    local _, q = splitPath(path)
    local query = Cache.parseQuery(q)
    return query.q ~= nil and query.q ~= ""
end

function Cache.pageCount(total, size)
    total = tonumber(total) or 0
    if total <= 0 then return 1 end
    return math.ceil(total / (size or Cache.MIRROR_PAGE))
end

-- One list page answered from the mirror's pages.
--   w: Cache.listWindow; pages: { [n] = body of mirror page n }; -> body, or nil when a page it
--   needs isn't saved.
local PAGING = { items = true, page = true, size = true, offset = true, hasNext = true, hasPrevious = true,
    nextUrl = true, previousUrl = true }
function Cache.slice(w, pages, page_size)
    local per = page_size or Cache.MIRROR_PAGE
    local first = pages[1]
    if type(first) ~= "table" or type(first.items) ~= "table" then return nil end
    local total = tonumber(first.total) or #first.items
    local size = w.size or (w.kind == "books" and 20 or total)
    if size < 1 then size = 1 end
    local start = w.offset or ((w.page or 1) - 1) * size
    local stop = math.min(total, start + size)
    local items = {}
    for i = start + 1, stop do
        local n = math.floor((i - 1) / per) + 1
        local page = pages[n]
        if type(page) ~= "table" or type(page.items) ~= "table" then return nil end
        local item = page.items[i - (n - 1) * per]
        if item == nil then return nil end
        table.insert(items, item)
    end
    local out = {}
    for k, v in pairs(first) do if not PAGING[k] then out[k] = v end end
    out.items, out.total, out.size = items, total, size
    out.page = math.floor(start / size) + 1
    if w.offset then out.offset = w.offset end
    out.hasNext, out.hasPrevious = stop < total, start > 0
    return out
end

-- The positions a list read asks for (docs/design/sqlite-cache.md "How KOReader reads"; the
-- companion's CacheStore.windowOf). kind: "books" | "section"; page, size, offset: the read's own.
-- -> start (0-based), stop (exclusive), size
function Cache.window(kind, total, page, size, offset)
    total = tonumber(total) or 0
    size = tonumber(size) or (kind == "books" and 20 or total)
    if size < 1 then size = 1 end
    local start = tonumber(offset) or ((tonumber(page) or 1) - 1) * size
    return start, math.max(start, math.min(total, start + size)), size
end

-- A list page from its saved head (the first page's other fields) and the items at start..stop-1.
function Cache.assemble(head, items, total, start, stop, size, offset)
    local out = {}
    for k, v in pairs(type(head) == "table" and head or {}) do if not PAGING[k] then out[k] = v end end
    out.items, out.total, out.size = items, total, size
    out.page = math.floor(start / size) + 1
    if offset then out.offset = tonumber(offset) end
    out.hasNext, out.hasPrevious = stop < total, start > 0
    return out
end

-- The book id when path is the detail template (the plugin's detail request with the sentinel id)
-- filled with an id; the companion's CacheStore.detailId.
function Cache.detailId(path, template, sentinel)
    if type(template) ~= "string" or type(path) ~= "string" then return nil end
    local i, j = template:find(sentinel, 1, true)
    if not i then return nil end
    local pre, post = template:sub(1, i - 1), template:sub(j + 1)
    if #path <= #pre + #post or path:sub(1, #pre) ~= pre or (post ~= "" and path:sub(-#post) ~= post) then return nil end
    local mid = path:sub(#pre + 1, #path - #post)
    if not mid:match("^%d+$") or #mid > 12 then return nil end
    return tonumber(mid)
end

-- An offline search's words, each as a LIKE pattern (% and _ escaped with \).
function Cache.searchWords(q)
    local out = {}
    for w in tostring(q or ""):gmatch("%S+") do
        table.insert(out, "%" .. w:gsub("[\\%%_]", "\\%0") .. "%")
    end
    return out
end

-- Whether the mirror needs an automatic Full refresh.
--   m: { at (last complete Full refresh), lib_version }; lib_version: the plugin's current one.
-- -> reason ("never" | "ttl" | "library") or nil
function Cache.mirrorDue(m, now, ttl_days, lib_version)
    if type(m) ~= "table" or not m.at then return "never" end
    if now - m.at >= (ttl_days or Cache.MIRROR_TTL_DAYS) * 86400 then return "ttl" end
    if lib_version and m.lib_version and lib_version ~= m.lib_version then return "library" end
    return nil
end

---------------------------------------------------------------- writes

-- The book id and the fields a write sets, or nil when the write patches nothing.
function Cache.writeEffect(method, path, body)
    if tostring(method or ""):upper() == "GET" then return nil end
    local p = splitPath(path)
    local id, what = p:match("/catalog/books/(%d+)/([%w%-]+)$")
    id = tonumber(id)
    if not id then return { stale_home = p:find("/catalog/") ~= nil or p:find("/sync") ~= nil or p:find("/progress") ~= nil } end
    body = type(body) == "table" and body or {}
    if what == "read-status" then return { id = id, fields = { readStatus = body.status }, stale_home = true } end
    if what == "rating" then
        local r = body.rating
        if type(r) ~= "number" then r = Cache.NULL end
        return { id = id, fields = { rating = r }, stale_home = true }
    end
    return { stale_home = true }
end

Cache.NULL = {} -- a field the write clears

-- The book ids a body lists (for finding the entries a write touches).
function Cache.ids(body, out, depth)
    out = out or {}
    depth = depth or 0
    if type(body) ~= "table" or depth > 30 then return out end
    local id = tonumber(body.id)
    if id then out[id] = true end
    for _, v in pairs(body) do
        if type(v) == "table" then Cache.ids(v, out, depth + 1) end
    end
    return out
end

---------------------------------------------------------------- the storage limit (v0.11.2)

-- One limit on everything Orbit stores (Orbit menu › Storage limit; book files and KOReader's
-- own data do not count); Orbit Companion counts and removes (StorageLogic, CacheWorker).
Cache.STORAGE_LIMITS_MB = { 100, 250, 500, 1024, 0 } -- 0: no limit
Cache.STORAGE_DEFAULT_MB = 250

---------------------------------------------------------------- cover files

-- A cover file's bytes look like an image (JPEG, PNG, WebP or GIF), from its first bytes.
function Cache.imageHeader(head)
    if type(head) ~= "string" or #head < 4 then return false end
    if head:sub(1, 3) == "\255\216\255" then return true end
    if head:sub(1, 4) == "\137PNG" then return true end
    if head:sub(1, 4) == "GIF8" then return true end
    if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then return true end
    return false
end

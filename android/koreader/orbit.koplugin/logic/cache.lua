-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- The write-through cache's rules (docs/design/write-through-cache.md), pure so that
-- shared/fixtures/cache/cases.json can check them: keys, what is cached, when a read is served
-- and/or fetched, whether a reply changed, what a write patches, and what a cover needs.
-- The store, the request wrapper and the views are ko/cache.lua.
---------------------------------------------------------------------------------------------

Cache = {
    FRESH_S = 60,          -- a read within this of the last check is not checked again
    -- Storage is plentiful on Android; the offline mirror is pinned and outside these caps'
    -- LRU, which applies to everything else (design "Size").
    MAX_BYTES = 64 * 1024 * 1024,
    MAX_ENTRIES = 20000,
    VERSION = 1,
    MIRROR_PAGE = 100,     -- the server's largest page (koreader-catalog-query.dto.ts:87, :284)
    MIRROR_SMALL_PAGE = 25, -- a list whose first 100-item page timed out is saved in pages this small
    MIRROR_TRIES = 3,      -- a mirror request that gets no answer: tried this often, then skipped
    MIRROR_RETRY_S = 5,    -- the first retry's wait; it doubles each try
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

-- A book's cover file name in the plugin's thumbnail folder (bookorbit_catalog_thumbnails.lua:61-85
-- coverToken, normalizedBookId, memoKey), or nil. The companion saves covers under the same name
-- (CacheWorker.coverPath; shared/fixtures/cache/worker.json "covers").
function Cache.coverName(book)
    local id = type(book) == "table" and book.id
    if type(id) ~= "number" or id ~= math.floor(id) or id < 1 or id > 2147483647 then return nil end
    local token = book.updatedAt and tostring(book.updatedAt):gsub("%D", "") or "0"
    if #token > 32 then token = token:sub(1, 16) .. token:sub(-16) end
    if token == "" then token = "0" end
    return (book.author_photo and "a" or "") .. string.format("%.0f", id) .. "_" .. token .. ".jpg"
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

function Cache.isHome(path)
    local p = splitPath(path)
    return p:find("/catalog/dashboard") ~= nil
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

-- What a check stores: the reply, with the saved random pick kept (a Full refresh takes the new).
function Cache.settle(cached, reply, mode)
    if type(cached) ~= "table" or type(reply) ~= "table" or mode == "full" then return reply end
    local out = {}
    for k, v in pairs(reply) do out[k] = v end
    for k in pairs(Cache.KEEP_SAVED) do if cached[k] ~= nil then out[k] = cached[k] end end
    return out
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

-- The path of a mirror page of a list identity. size: the list's mirror page size (default 100).
function Cache.mirrorPage(identity, page, size)
    local p, q = splitPath(identity)
    local query = Cache.parseQuery(q)
    query.page, query.size = page, size or Cache.MIRROR_PAGE
    return p .. "?" .. encQuery(query)
end

function Cache.pageCount(total, size)
    total = tonumber(total) or 0
    if total <= 0 then return 1 end
    return math.ceil(total / (size or Cache.MIRROR_PAGE))
end

-- A mirror request that got no answer (a timeout or a network error; one is never "offline").
--   tries: how many times it has failed now; size: the page size it asked for (nil: not a list
--   page); page: its page number. -> { skip = true } after MIRROR_TRIES, else { wait_s, size }:
--   wait 5 s, then 10 s; a list's first page also asks for a smaller page (100 -> 50 -> 25), so a
--   list the server is slow to page by 100 (sections/series) is saved in smaller pages.
function Cache.mirrorRetry(tries, size, page)
    if tries >= Cache.MIRROR_TRIES then return { skip = true } end
    local out = { wait_s = Cache.MIRROR_RETRY_S * 2 ^ (tries - 1), size = size }
    if size and page == 1 and size > Cache.MIRROR_SMALL_PAGE then
        out.size = math.max(Cache.MIRROR_SMALL_PAGE, math.floor(size / 2))
    end
    return out
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

-- A revalidated mirror page whose list total moved: the pages to fetch and to drop.
function Cache.repage(old_total, new_total, size)
    local old_n, new_n = Cache.pageCount(old_total, size), Cache.pageCount(new_total, size)
    local fetch, drop = {}, {}
    for n = 2, new_n do table.insert(fetch, n) end
    for n = new_n + 1, old_n do table.insert(drop, n) end
    return fetch, drop
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

-- Patches every table in body whose id is the book's. Returns the number of tables patched.
function Cache.patch(body, id, fields, depth)
    depth = depth or 0
    if type(body) ~= "table" or depth > 30 then return 0 end
    local n = 0
    if tonumber(body.id) == id then
        for k, v in pairs(fields) do
            if v == Cache.NULL then body[k] = nil else body[k] = v end
        end
        n = 1
    end
    for _, v in pairs(body) do
        if type(v) == "table" then n = n + Cache.patch(v, id, fields, depth + 1) end
    end
    return n
end

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

---------------------------------------------------------------- size

-- index: { [key] = { bytes, used_at, keep } } -> the keys to drop, least recently used first.
-- Kept entries (Home, the offline mirror's lists and book details) are outside the caps: they
-- neither count toward them nor go (design "Size").
function Cache.evict(index, max_bytes, max_entries)
    local list, total = {}, 0
    for k, e in pairs(index) do
        if not e.keep then
            table.insert(list, { k = k, at = e.used_at or 0, bytes = e.bytes or 0 })
            total = total + (e.bytes or 0)
        end
    end
    table.sort(list, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.k < b.k end)
    local drop, count = {}, #list
    for _, e in ipairs(list) do
        if total <= max_bytes and count <= max_entries then break end
        do
            table.insert(drop, e.k)
            total, count = total - e.bytes, count - 1
        end
    end
    return drop
end

---------------------------------------------------------------- the storage limit (v0.11.2)

-- One limit on everything Orbit stores (Orbit menu › Storage limit; book files and KOReader's
-- own data don't count). The 64 MB / 20000-entry cap above stays the browsing cache's share.
Cache.STORAGE_LIMITS_MB = { 100, 250, 500, 1024, 0 } -- 0: no limit
Cache.STORAGE_DEFAULT_MB = 250

-- items: { { k, bytes, at, kind } }, kind: "cache" (a browsing-cache entry), "cover" (a cover the
-- mirror didn't save), "mirror_cover" (saved by "Save every cover for offline") or "kept" (the
-- mirror's lists and book details, Home: never removed). limit: bytes (nil or 0: none).
-- -> { drop = keys in the order they go, used, after }: browsing entries and plain covers first,
-- least recently used first; then the mirror's covers, least recently seen first; never "kept".
function Cache.storagePlan(items, limit)
    local used = 0
    for _, e in ipairs(items or {}) do used = used + (e.bytes or 0) end
    local out = { drop = {}, used = used, after = used }
    if not limit or limit <= 0 or used <= limit then return out end
    for _, tier in ipairs({ { cache = true, cover = true }, { mirror_cover = true } }) do
        local list = {}
        for _, e in ipairs(items) do if tier[e.kind] then table.insert(list, e) end end
        table.sort(list, function(a, b) if (a.at or 0) ~= (b.at or 0) then return (a.at or 0) < (b.at or 0) end return a.k < b.k end)
        for _, e in ipairs(list) do
            if out.after <= limit then return out end
            table.insert(out.drop, e.k)
            out.after = out.after - (e.bytes or 0)
        end
    end
    return out
end

-- Whether the offline mirror may save more under the limit. totals: { kept, mirror_cover } bytes.
-- what: "covers" (the every-cover pass: room only while the mirror's own share is under the
-- limit, so it never pushes out covers it saved) or "lists" (lists and details: they stop only
-- when they alone fill it).
function Cache.storageRoom(totals, limit, what)
    if not limit or limit <= 0 or type(totals) ~= "table" then return true end
    if what == "covers" then return (totals.kept or 0) + (totals.mirror_cover or 0) < limit end
    return (totals.kept or 0) < limit
end

-- "Storage limit reached: 412 of 855 covers saved. Raise the limit in Orbit settings."
function Cache.limitText(what, done, total)
    return string.format("Storage limit reached: %d of %d %s saved. Raise the limit in Orbit settings.",
        done or 0, total or 0, what == "covers" and "covers" or "lists and books")
end

---------------------------------------------------------------- covers

-- What one listed book's cover needs.
--   book: { id, updatedAt, hasCover }; have: nil or { version, file = ok|missing|empty|corrupt, etag };
--   failed: true when it failed this session; mode: refresh | full.
-- -> { fetch, conditional (an ETag to send), remove (the file on disk is bad) }
function Cache.coverNeed(book, have, failed, mode)
    if book.hasCover == false then return { fetch = false } end
    local version = tostring(book.updatedAt or "")
    if not have or have.file == "missing" then return { fetch = true } end
    if have.version ~= version then
        return { fetch = true, conditional = have.file == "ok" and have.etag or nil }
    end
    if failed then return { fetch = true } end
    if mode ~= "full" then return { fetch = false } end
    if have.file ~= "ok" then return { fetch = true, remove = true } end
    if have.etag then return { fetch = true, conditional = have.etag } end
    return { fetch = false }
end

-- A cover file's bytes look like an image (JPEG, PNG, WebP or GIF), from its first bytes.
function Cache.imageHeader(head)
    if type(head) ~= "string" or #head < 4 then return false end
    if head:sub(1, 3) == "\255\216\255" then return true end
    if head:sub(1, 4) == "\137PNG" then return true end
    if head:sub(1, 4) == "GIF8" then return true end
    if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then return true end
    return false
end

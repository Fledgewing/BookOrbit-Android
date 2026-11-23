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
    MAX_BYTES = 8 * 1024 * 1024,
    MAX_ENTRIES = 400,
    VERSION = 1,
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

local function normServer(s)
    return (tostring(s or ""):lower():gsub("/+$", ""))
end

-- r: { account, server, method, path, query }. path may carry its own "?query".
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
function Cache.readPlan(entry, now, mode, offline)
    if mode == "full" then
        if offline then return entry ~= nil, false end
        return false, true
    end
    if not entry then return false, not offline end
    if offline then return true, false end
    if mode == "refresh" then return true, true end
    return true, (now - (entry.validated_at or 0)) >= Cache.FRESH_S
end

-- -> changed, stored
function Cache.revalidate(cached, reply, status)
    if type(status) ~= "number" or status < 200 or status >= 300 or reply == nil then return false, false end
    return Cache.encode(cached) ~= Cache.encode(reply), true
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
function Cache.evict(index, max_bytes, max_entries)
    local list, total = {}, 0
    for k, e in pairs(index) do
        table.insert(list, { k = k, at = e.used_at or 0, bytes = e.bytes or 0, keep = e.keep })
        total = total + (e.bytes or 0)
    end
    table.sort(list, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.k < b.k end)
    local drop, count = {}, #list
    for _, e in ipairs(list) do
        if total <= max_bytes and count <= max_entries then break end
        if not e.keep then
            table.insert(drop, e.k)
            total, count = total - e.bytes, count - 1
        end
    end
    return drop
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

-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Generic literal serialization, hashing, URL utilities, display counts and local quota/image
-- helpers. Legacy server cache policy lives only in logic/server/bookorbit/cache.lua.
---------------------------------------------------------------------------------------------

Cache = {}

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


local function escape(v)
    return (tostring(v):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- A sorted query escaped for a request.
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

---------------------------------------------------------------- the storage limit (v0.11.2)

-- One limit on everything Orbit stores (Orbit menu › Storage limit; book files and KOReader's
-- own data do not count); Orbit Companion counts and removes (StorageLogic, CacheWorker).
Cache.STORAGE_LIMITS_MB = { 100, 250, 500, 1024, 2560, 5120, 10240, 0 } -- 0: no limit
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

-- Generic URL helpers reused by the compatibility adapter.
Cache.splitPath, Cache.encQuery = splitPath, encQuery

-- Consume only one caller-bounded local work window.
function Cache.takeWindow(queue,limit)
    assert(type(limit)=="number" and limit>=1 and limit<=24 and limit==math.floor(limit),"Queue window exceeds budget")
    local rows={}
    while #rows<limit and queue and queue.head<=queue.tail do
        rows[#rows+1]=queue[queue.head]
        queue[queue.head]=nil; queue.head=queue.head+1
    end
    if queue and queue.head>queue.tail then queue.head,queue.tail,queue.seen=1,0,{} end
    return rows
end

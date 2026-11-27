-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Generic literal serialization, hashing, URL utilities, display counts and local quota/image
---------------------------------------------------------------------------------------------

Cache = {}

---------------------------------------------------------------- values

-- A canonical Lua literal of v: sorted keys, so equal bodies give equal strings; loadable back
-- with Cache.decode. Functions and userdata are dropped.
function Cache.encode(...) return UIUtil.encode(...) end

-- Accept the literal format emitted by UIUtil.encode before loading a value.
local function literal(s)
    local i, n = 1, #s
    local function peek()
        while i <= n and s:sub(i,i):match("%s") do i = i + 1 end
        return s:sub(i,i)
    end
    local function take(c)
        if peek() ~= c then error("literal") end
        i = i + 1
    end
    local value
    value = function(depth)
        if depth > 40 then error("literal") end
        local c = peek()
        if c == '"' then
            i = i + 1
            while i <= n do
                c = s:sub(i,i); i = i + 1
                if c == '"' then return end
                if c == "\\" then
                    local e = s:sub(i,i)
                    if e == "" then error("literal") end
                    if e:match("%d") then
                        local digits = s:match("^%d%d?%d?", i)
                        if tonumber(digits) > 255 then error("literal") end
                        i = i + #digits
                    elseif e:match('[abfnrtv\\"\n]') then i = i + 1
                    else error("literal") end
                elseif c:byte() < 32 then error("literal") end
            end
            error("literal")
        elseif c == "{" then
            i = i + 1
            if peek() == "}" then i = i + 1; return end
            while true do
                if peek() == "[" then
                    i = i + 1
                    if peek() == "{" then error("literal") end
                    value(depth + 1); take("]"); take("=")
                else
                    local _, last = s:find("^[%a_][%w_]*%s*=", i)
                    if last then i = last + 1 end
                end
                value(depth + 1)
                c = peek()
                if c == "}" then i = i + 1; return end
                if c ~= "," and c ~= ";" then error("literal") end
                i = i + 1
                if peek() == "}" then i = i + 1; return end
            end
        else
            local token = s:match("^[%w%.%+%-]+", i)
            if not token then error("literal") end
            if token ~= "true" and token ~= "false" and token ~= "nil" and not tonumber(token) then error("literal") end
            i = i + #token
        end
    end
    value(0)
    return peek() == ""
end

function Cache.decode(s)
    if type(s) ~= "string" or s == "" then return nil end
    local valid, complete = pcall(literal, s)
    if not valid or not complete then return nil end
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
function Cache.count(n) return UIUtil.count(n) end

---------------------------------------------------------------- the storage limit (v0.11.2)

-- One limit on everything Orbit stores (Orbit menu › Storage limit; book files and KOReader's
-- own data do not count); Orbit Companion counts and removes (StorageLogic, CacheWorker).
Cache.STORAGE_LIMITS_MB = { 100, 250, 500, 1024, 2560, 5120, 10240, 0 } -- 0: no limit
Cache.STORAGE_DEFAULT_MB = 250

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

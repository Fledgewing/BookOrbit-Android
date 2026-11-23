-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- The write-through cache in front of BookOrbit (docs/design/write-through-cache.md "Android").
-- Rules: logic/cache.lua. This file: the store, the wrappers on the plugin's API client
-- (request, downloadCatalogThumbnail, runInSubprocess) and catalog (switchTo), background
-- checks, the view redraws, Refresh and Full refresh, and cover ETags.
--
-- The catalog runs many requests inside a forked child (plugin Catalog:fetch, catalog.lua:881).
-- A child may serve from the cache (it has the parent's memory and the disk), and writes what it
-- learns as event files (stored / check / write); the parent applies them when the child returns
-- (the runInSubprocess wrapper) and on a timer, so the index is only ever written by the parent.
---------------------------------------------------------------------------------------------

OC = { memo = {}, memo_order = {}, inflight = {}, queue = {}, done = {}, MEMO = 12, MODE_S = 30 }

local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")

OC.now = os.time
local function nowT() return OC.now() end

function OC.on() return S.offline_cache ~= false end

function OC.dir()
    if OC._dir then return OC._dir end
    local okd, DataStorage = pcall(require, "datastorage")
    local base = okd and DataStorage:getSettingsDir() or "."
    OC._dir = base .. "/orbit-cache"
    if lfs_ok then
        lfs.mkdir(OC._dir)
        lfs.mkdir(OC._dir .. "/events")
    end
    return OC._dir
end

local function readFile(path, max)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read(max or "*a")
    f:close()
    return s
end

-- Atomic: a temp file renamed over the target.
local function writeFile(path, s)
    local tmp = path .. ".tmp" .. tostring(math.random(1, 1e9))
    local f = io.open(tmp, "wb")
    if not f then return false end
    local okw = f:write(s)
    f:close()
    if not okw then os.remove(tmp); return false end
    if not os.rename(tmp, path) then os.remove(tmp); return false end
    return true
end

-- FNV-1a, 32 bits, as hex: the entry's file name (the key is stored inside and checked).
function OC.hash(s)
    local bit = require("bit")
    local h = 2166136261
    for i = 1, #s do
        h = bit.bxor(h, s:byte(i))
        h = bit.tobit(h * 16777619 % 4294967296)
    end
    return string.format("%08x", h % 4294967296)
end

-- In a forked child (the plugin's runInSubprocess, catalog.lua:881): never JNI (NetworkMgr on
-- Android is JNI, device/android/device.lua:333; a child that calls it dies and the plugin gets
-- subprocess_no_result), never the UI; the parent's state comes across the fork.
local function inChild(client) return OC.child == true or (client and (client.subprocess_depth or 0) > 0) end

-- Online? In a child: what the parent saw just before it forked.
function OC.online(client)
    if inChild(client) then return OC.parent_online ~= false end
    return NetworkMgr:isConnected()
end

---------------------------------------------------------------- index

function OC.index()
    if OC._index then return OC._index end
    local d = Cache.decode(readFile(OC.dir() .. "/index.lua") or "")
    if type(d) ~= "table" or d.v ~= Cache.VERSION or type(d.entries) ~= "table" then
        d = { v = Cache.VERSION, entries = {} }
    end
    OC._index = d
    return d
end

function OC.saveIndex()
    if OC.child or OC._save_pending then return end
    OC._save_pending = true
    UIManager:scheduleIn(3, function()
        OC._save_pending = nil
        writeFile(OC.dir() .. "/index.lua", Cache.encode(OC.index()))
    end)
end

-- Everything goes: another account or server, the setting turned off, or on request.
function OC.wipe(why)
    log("cache: cleared (" .. tostring(why) .. ")")
    local dir = OC.dir()
    if lfs_ok then
        for name in lfs.dir(dir) do
            if name:match("%.lua$") or name:match("%.tmp") then os.remove(dir .. "/" .. name) end
        end
        for name in lfs.dir(dir .. "/events") do
            if name ~= "." and name ~= ".." then os.remove(dir .. "/events/" .. name) end
        end
    end
    OC._index = { v = Cache.VERSION, entries = {} }
    OC.memo, OC.memo_order = {}, {}
    OC.saveIndex()
end

-- The account and server this cache belongs to; a different one drops it.
function OC.owner(client)
    local owner = tostring(client.username or "") .. "|" .. tostring(client.server_url or ""):lower()
    local idx = OC.index()
    if idx.owner ~= owner and not inChild(client) then
        if idx.owner ~= nil then OC.wipe("account or server changed") end
        OC.index().owner = owner
        OC.saveIndex()
    end
    return owner
end

local function remember(key, entry)
    if not OC.memo[key] then table.insert(OC.memo_order, key) end
    OC.memo[key] = entry
    while #OC.memo_order > OC.MEMO do
        OC.memo[table.remove(OC.memo_order, 1)] = nil
    end
end

function OC.get(key)
    if OC.memo[key] then return OC.memo[key] end
    local meta = OC.index().entries[key]
    local file = OC.dir() .. "/" .. OC.hash(key) .. ".lua"
    local e = Cache.decode(readFile(file) or "")
    if type(e) ~= "table" or e.key ~= key or type(e.body) ~= "table" then
        if meta then OC.index().entries[key] = nil end
        return nil
    end
    if meta and meta.validated_at then e.validated_at = math.max(e.validated_at or 0, meta.validated_at) end
    -- Stale (a write since): checked at once, but its age stays its real age.
    e.stale = meta and meta.stale or nil
    remember(key, e)
    return e
end

-- Stores a server reply. In a child: the file and a "stored" event only.
function OC.put(client, key, body, path)
    local t = nowT()
    local e = { key = key, body = body, fetched_at = t, validated_at = t, path = path }
    local s = Cache.encode(e)
    local file = OC.dir() .. "/" .. OC.hash(key) .. ".lua"
    if not writeFile(file, s) then return end
    remember(key, e)
    if inChild(client) then return OC.event("stored", { key = key }) end
    OC.adopt(key, e, #s)
end

-- The parent's index learns an entry, and the cache stays under its caps.
function OC.adopt(key, e, bytes)
    local idx = OC.index()
    local ids = {}
    for id in pairs(Cache.ids(e.body)) do table.insert(ids, id) end
    local old = idx.entries[key]
    local mirror = (old and old.mirror) or e.mirror or nil
    idx.entries[key] = { bytes = bytes, fetched_at = e.fetched_at, validated_at = e.validated_at, used_at = nowT(),
        ids = ids, home = Cache.isHome(e.path) or nil, keep = (Cache.isHome(e.path) or mirror) and true or nil,
        mirror = mirror, path = e.path }
    OC.done[key] = true
    for _, k in ipairs(Cache.evict(idx.entries, Cache.MAX_BYTES, Cache.MAX_ENTRIES)) do
        idx.entries[k] = nil
        OC.memo[k] = nil
        os.remove(OC.dir() .. "/" .. OC.hash(k) .. ".lua")
    end
    OC.saveIndex()
end

function OC.touch(key, validated)
    if OC.child then return end
    local m = OC.index().entries[key]
    if not m then return end
    m.used_at = nowT()
    if validated then m.validated_at, m.stale = nowT(), nil end
    if OC.memo[key] and validated then OC.memo[key].validated_at, OC.memo[key].stale = nowT(), nil end
    OC.saveIndex()
end

---------------------------------------------------------------- child events

local event_n = 0
function OC.event(kind, data)
    event_n = event_n + 1
    data.kind = kind
    writeFile(string.format("%s/events/%d-%d-%d.lua", OC.dir(), nowT(), math.random(1, 1e6), event_n), Cache.encode(data))
end

function OC.drainEvents()
    if not lfs_ok then return end
    local dir = OC.dir() .. "/events"
    local names = {}
    for name in lfs.dir(dir) do if name:match("%.lua$") then table.insert(names, name) end end
    table.sort(names)
    for _, name in ipairs(names) do
        local ev = Cache.decode(readFile(dir .. "/" .. name) or "")
        os.remove(dir .. "/" .. name)
        if type(ev) == "table" then
            if ev.kind == "stored" and ev.key then
                OC.memo[ev.key] = nil
                local file = OC.dir() .. "/" .. OC.hash(ev.key) .. ".lua"
                local raw = readFile(file)
                local e = Cache.decode(raw or "")
                if type(e) == "table" and e.key == ev.key then OC.adopt(ev.key, e, #raw) end
            elseif ev.kind == "check" and ev.key then
                OC.check(nil, ev.key, ev.method, ev.path, ev.headers)
            elseif ev.kind == "write" then
                OC.afterWrite(ev.method, ev.path, ev.body)
            elseif ev.kind == "read" and ev.key then
                table.insert(OC.pending, ev.key)
                OC.source[ev.key] = ev.source
            elseif ev.kind == "miss" then
                OC.offline_miss = true
            elseif ev.kind == "search" then
                OC.offline_search = true
            elseif ev.kind == "other" then
                OC.offline_other = true
            end
        end
    end
end

---------------------------------------------------------------- reads

-- The active refresh mode: { mode = "refresh" | "full", until_t }.
function OC.mode()
    local m = OC.active
    if m and nowT() <= m.until_t then return m.mode end
    OC.active = nil
    return "open"
end

function OC.begin(mode)
    OC.active = { mode = mode, until_t = nowT() + OC.MODE_S }
    OC.done = {}
end

-- The wrapper's body for a cacheable GET. Returns handled, body, err, errbody.
-- The entry for a read: its own, or a list page cut from the offline mirror's pages.
function OC.lookup(client, key, path)
    local e = OC.get(key)
    if e then return e end
    local w = Cache.listWindow(path)
    if not w then return nil end
    local owner = OC.owner(client)
    local pages, oldest = {}, nil
    local size = Mirror and Mirror.pageSize and Mirror.pageSize(w.identity) or nil
    local first = OC.get(Cache.key({ account = owner, server = client.server_url, method = "GET", path = Cache.mirrorPage(w.identity, 1, size) }))
    if not first then return nil end
    pages[1] = first.body
    oldest = first.validated_at or 0
    local n = Cache.pageCount(type(first.body) == "table" and first.body.total, size)
    for i = 2, n do
        local pe = OC.get(Cache.key({ account = owner, server = client.server_url, method = "GET", path = Cache.mirrorPage(w.identity, i, size) }))
        if pe then pages[i] = pe.body; oldest = math.min(oldest, pe.validated_at or 0) end
    end
    local b = Cache.slice(w, pages, size)
    if not b then return nil end
    return { key = key, body = b, validated_at = oldest, path = path, from_mirror = true }
end

function OC.read(client, stock, method, path, body, headers)
    local owner = OC.owner(client)
    local key = Cache.key({ account = owner, server = client.server_url, method = method, path = path })
    local entry = OC.lookup(client, key, path)
    local mode = OC.mode()
    -- Within one refresh each key is fetched or checked once; later reads are plain opens.
    if mode ~= "open" and OC.done[key] then mode = "open" end
    local offline = not OC.online(client)
    local serve, fetch = Cache.readPlan(entry, nowT(), mode, offline)
    if OC.cache_only then fetch = false end
    local variant = tostring(path):match("/catalog/books/%d+%?.*variant=([%w_]+)")
    if variant and not inChild(client) and OC.index().detail_variant ~= variant then
        OC.index().detail_variant = variant
        OC.saveIndex()
    end
    local short = tostring(path):gsub("^/koreader/plugin/catalog", "")
    if serve and entry.from_mirror then short = short .. " (offline mirror)" end
    if not serve and OC.cache_only then return true, nil, "cancelled" end
    if not offline and not OC.cache_only and not inChild(client) then pcall(OC.mirrorTick, "read") end
    if serve then
        OC.saw(client, key, "cache")
        OC.touch(key)
        if fetch then
            OC.done[key] = true
            if inChild(client) then OC.event("check", { key = key, method = method, path = path, headers = headers })
            else OC.check(nil, key, method, path, headers, client) end
            log("cache:", short, "from the cache, age", (nowT() - (entry.validated_at or 0)) .. "s"
                .. (entry.stale and ", changed here since" or "") .. "; checking (" .. mode .. ")")
        else
            log("cache:", short, "from the cache, age", (nowT() - (entry.validated_at or 0)) .. "s" .. (offline and ", offline" or ""))
        end
        return true, Cache.copy(entry.body)
    end
    if offline and OC.offline_pass then
        -- Offline, not saved: quiet ("cancelled" is the plugin's no-error path) and the
        -- runConnected wrapper asks to connect; a search only says it needs a connection.
        if Cache.isSearch(path) then
            if inChild(client) then OC.event("search", {}) else OC.offline_search = true end
            log("cache:", short, "is a search; it needs a connection (offline)")
            return true, nil, "cancelled"
        end
        OC.missed(client)
        log("cache:", short, "isn't saved on this reader (offline)")
        return true, nil, "cancelled"
    end
    local b, e, eb = stock(client, method, path, body, headers)
    if b ~= nil then
        OC.saw(client, key, "server")
        OC.put(client, key, Cache.copy(b), path)
        log("cache:", short, "from the server (" .. mode .. ")")
        return true, b, e, eb
    end
    if entry then
        OC.saw(client, key, "cache")
        log("cache:", short, "server failed (" .. tostring(e) .. "); the cached copy instead")
        OC.failed[key] = true
        return true, Cache.copy(entry.body)
    end
    return true, b, e, eb
end
OC.pending, OC.source, OC.failed = {}, {}, {}

-- A view read key (for redraws and the paint log); from a child, through an event.
function OC.saw(client, key, source)
    if inChild(client) then return OC.event("read", { key = key, source = source }) end
    table.insert(OC.pending, key)
    OC.source[key] = source
end

function OC.missed(client)
    if inChild(client) then return OC.event("miss", {}) end
    OC.offline_miss = true
end

---------------------------------------------------------------- background checks

-- Queues a check of key against the server; one request at a time, one per key.
function OC.check(_, key, method, path, headers, client)
    if OC.inflight[key] then return end
    OC.inflight[key] = true
    table.insert(OC.queue, { key = key, method = method, path = path, headers = headers, client = client, mode = OC.mode() })
    OC.pump()
end

function OC.client()
    local p = bookorbit(liveUI())
    if not p then return nil end
    if p.catalog_browser and p.catalog_browser.client then return p.catalog_browser.client end
    if Compat.callable(p.newClient) then
        local okc, c = pcall(p.newClient, p)
        if okc then return c end
    end
    return nil
end

function OC.pump()
    if OC.running then return end
    local job = table.remove(OC.queue, 1)
    if not job then return end
    local client = job.client or OC.client()
    if not client or not NetworkMgr:isConnected() then
        OC.inflight[job.key] = nil
        return OC.pump()
    end
    OC.running = true
    Background.run("cache check", function()
        local b, e = client:requestBlocking(job.method, job.path, nil, job.headers)
        return Cache.encode({ body = b, err = e and tostring(e) or nil })
    end, 60, function(out)
        OC.running = nil
        OC.inflight[job.key] = nil
        local r = Cache.decode(out or "")
        OC.landed(client, job, r)
        OC.pump()
    end)
end

function OC.landed(client, job, r)
    local short = tostring(job.path):gsub("^/koreader/plugin/catalog", "")
    if type(r) ~= "table" or type(r.body) ~= "table" then
        OC.failed[job.key] = true
        log("cache:", short, "check failed (network:", tostring(type(r) == "table" and r.err or "no answer") .. "); the saved copy stays")
        return
    end
    OC.failed[job.key] = nil
    local entry = OC.lookup(client, job.key, job.path)
    local changed = Cache.revalidate(entry and entry.body, r.body, 200)
    if job.mirror then pcall(OC.mirrorChecked, client, job, entry, r.body, changed) end
    if not changed then
        if entry and not entry.from_mirror then OC.touch(job.key, true) end
        log("cache:", short, "checked: unchanged")
        return
    end
    OC.put(client, job.key, Cache.settle(entry and entry.body, r.body, job.mode), job.path)
    if OC.onScreen(job.key) then
        log("cache:", short, "checked: changed; redrawing once the checks are done")
        OC.redraw_soon(job.key)
    else
        log("cache:", short, "checked: changed; saved (not on screen)")
    end
end

function OC.onScreen(key)
    local p = bookorbit(liveUI())
    local cat = p and p.catalog_browser
    return cat ~= nil and not cat.catalog_closed and cat._orbit_view_keys ~= nil and cat._orbit_view_keys[key] == true
end

-- One redraw after the running checks land, however many of the view's keys changed.
function OC.redraw_soon(key)
    OC.redraw_key = key
    if OC.redraw_scheduled then return end
    OC.redraw_scheduled = true
    local function flush()
        if OC.running or #OC.queue > 0 then return UIManager:scheduleIn(0.5, flush) end
        OC.redraw_scheduled = nil
        local k = OC.redraw_key
        OC.redraw_key = nil
        if k then OC.redraw(k) end
    end
    UIManager:scheduleIn(0.3, flush)
end

-- What keeps Wi-Fi on (Wifi.busy): checks in flight or the offline mirror saving.
function OC.busy()
    if OC.running or #OC.queue > 0 then return "the Orbit cache checking BookOrbit" end
    if Mirror and Mirror.active then return "saving BookOrbit for offline" end
    return nil
end

-- A changed entry that is on screen: the view reloads from the cache (no request, no spinner).
function OC.redraw(key)
    local p = bookorbit(liveUI())
    local cat = p and p.catalog_browser
    if not cat or cat.catalog_closed or not cat._orbit_view_keys or not cat._orbit_view_keys[key] then return end
    local ctx = cat.current_context or {}
    if ctx.kind == "dashboard" and Compat.callable(cat.loadDashboardRoot) then
        cat:loadDashboardRoot(true, { invisible = true })
        return true
    end
    if Compat.callable(cat.refreshCurrent) then LF.refreshKeepingCovers(cat); return true end
end

---------------------------------------------------------------- writes

function OC.afterWrite(method, path, body)
    local eff = Cache.writeEffect(method, path, body)
    if not eff then return end
    local idx = OC.index()
    local patched = 0
    for key, m in pairs(idx.entries) do
        local has = false
        for _, id in ipairs(m.ids or {}) do if id == eff.id then has = true break end end
        if eff.id and has then
            local e = OC.get(key)
            if e and Cache.patch(e.body, eff.id, eff.fields) > 0 then
                local s = Cache.encode(e)
                writeFile(OC.dir() .. "/" .. OC.hash(key) .. ".lua", s)
                m.bytes = #s
                patched = patched + 1
            end
        end
        if eff.stale_home and m.home then
            m.stale = true
            if OC.memo[key] then OC.memo[key].stale = true end
        end
    end
    -- A progress write names the book by document digest; the local overlay already shows this
    -- device's position, and Home is checked against the server on its next read.
    if patched > 0 then
        log("cache: a write to", (tostring(path):gsub("^/koreader/plugin/catalog", "")), "patched", patched, "entr(y/ies)")
    end
    if patched > 0 or eff.stale_home then OC.saveIndex() end
end

---------------------------------------------------------------- covers (ETag)

-- The book's other cover files in dir: "<id>_<version>.jpg" with an ETag next to it.
function OC.olderCover(dir, name, id)
    if not lfs_ok then return nil end
    local best, best_t
    local prefix = "^" .. id .. "_%d+%.jpg$"
    for n in lfs.dir(dir) do
        if n ~= name and n:match(prefix) then
            local p = dir .. "/" .. n
            if readFile(p .. ".etag", 200) then
                local t = lfs.attributes(p, "modification") or 0
                if not best_t or t > best_t then best, best_t = p, t end
            end
        end
    end
    return best
end

-- One conditional GET of a cover into temp, under the worker's size cap.
-- -> code, etag (or nil, err). 3xx and proxies are the plugin's (code "fallback").
function OC.httpCover(client, path, temp, max_bytes, etag)
    local url = tostring(client.server_url) .. path
    if Compat.callable(client.getProxy) and client:getProxy(url) then return "fallback" end
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local out = io.open(temp, "wb")
    if not out then return nil, "open_error" end
    local received, too_large = 0, false
    local file_sink = ltn12.sink.file(out)
    local sink = function(chunk, err)
        if chunk and chunk ~= "" then
            received = received + #chunk
            if received > max_bytes then too_large = true; return nil, "response_too_large" end
        end
        return file_sink(chunk, err)
    end
    local headers = { ["accept"] = "image/jpeg,image/*", ["Accept-Encoding"] = "identity",
        ["x-auth-user"] = client.username, ["x-auth-key"] = client.userkey }
    if etag then headers["If-None-Match"] = etag end
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, rh = socket.skip(1, http.request({ url = url, method = "GET", sink = sink, redirect = false, headers = headers }))
    socketutil:reset_timeout()
    pcall(function() out:close() end)
    if too_large then os.remove(temp); return nil, "response_too_large" end
    if type(code) ~= "number" then os.remove(temp); return nil, tostring(code or "network_error") end
    if code >= 300 and code < 400 and code ~= 304 then os.remove(temp); return "fallback" end
    if code == 304 then os.remove(temp); return 304 end
    if code ~= 200 or received == 0 then os.remove(temp); return nil, code end
    local ct = rh and (rh["content-type"] or rh["Content-Type"])
    if not (ct and tostring(ct):lower():find("^%s*image/")) then os.remove(temp); return nil, "unexpected_content_type" end
    local len = rh and tonumber(rh["content-length"] or rh["Content-Length"])
    if len and len ~= received then os.remove(temp); return nil, "size_mismatch" end
    return 200, rh and (rh.etag or rh.ETag or rh["Etag"])
end

local function clock()
    local oks, socket = pcall(require, "socket")
    if oks and type(socket) == "table" and socket.gettime then return socket.gettime() end
    return os.time()
end

-- A copy of src at dst, published by rename (never a half-written cover).
local function copyFile(src, dst)
    local data = readFile(src)
    if not data then return false end
    local tmp = dst .. ".copy"
    if not writeFile(tmp, data) then return false end
    if not os.rename(tmp, dst) then os.remove(tmp); return false end
    return true
end
OC.copyFile = copyFile

-- The plugin's downloadCatalogThumbnail, with ETags: a moved version asks If-None-Match and a
-- 304 copies the file it has to the new version's name. The older file stays where it is: a view
-- painted from an older body (the plugin's saved Home) still finds its cover. Falls back to the
-- plugin's download on anything unexpected. Runs in the thumbnail worker's child process: no
-- JNI, no events, and only true / (true, "not_modified") / (nil, err) back, as the worker wants.
function OC.coverDownload(client, stock, book_id, local_path, opts)
    opts = opts or {}
    local t0 = clock()
    local function done(how, ok, detail, bytes)
        log(string.format("cover: %s %s%s in %d ms", tostring(book_id), how,
            bytes and (", " .. bytes .. " B") or "", math.floor((clock() - t0) * 1000 + 0.5)) .. (detail and (" (" .. tostring(detail) .. ")") or ""))
        return ok, detail
    end
    local dir, name = tostring(local_path):match("^(.*)/([^/]+)$")
    if not dir then
        local ok, err = stock(client, book_id, local_path, opts)
        return done(ok and "200 (plugin)" or "error (plugin)", ok, err)
    end
    local old = OC.olderCover(dir, name, tostring(book_id))
    -- Full refresh re-asks a good file with its own ETag.
    local same = (opts.orbit_recheck and readFile(local_path .. ".etag", 200)) and local_path or nil
    local have = same or old
    local etag = have and readFile(have .. ".etag", 200)
    local temp = opts.temp_path or (local_path .. ".part")
    local code, got = OC.httpCover(client, "/koreader/plugin/catalog/books/" .. tostring(book_id) .. "/thumbnail",
        temp, opts.max_bytes or 4 * 1024 * 1024, etag)
    if code == "fallback" then
        local ok, err = stock(client, book_id, local_path, opts)
        return done(ok and "200 (plugin download: proxy or redirect)" or "error (plugin download)", ok, err)
    end
    if code == 304 and have then
        if have ~= local_path then
            if not copyFile(have, local_path) then
                local ok, err = stock(client, book_id, local_path, opts)
                return done(ok and "200 (copy failed; downloaded)" or "error", ok, err)
            end
            copyFile(have .. ".etag", local_path .. ".etag")
        end
        if lfs_ok then lfs.touch(local_path) end
        local _, d = done("304", true, have ~= local_path and "copied from the older version" or nil)
        return true, "not_modified"
    end
    if code ~= 200 then return done("error", nil, got) end
    if not os.rename(temp, local_path) then os.remove(temp); return done("error", nil, "publish_failed") end
    if got then writeFile(local_path .. ".etag", tostring(got)) else os.remove(local_path .. ".etag") end
    local size = lfs_ok and lfs.attributes(local_path, "size") or nil
    return done("200", true, nil, size)
end

-- ETags whose cover is gone (the plugin's pruner removes only *.jpg).
function OC.cleanEtags(dir)
    if not lfs_ok or not dir or lfs.attributes(dir, "mode") ~= "directory" then return 0 end
    local n = 0
    for name in lfs.dir(dir) do
        if name:match("%.jpg%.etag$") and not lfs.attributes(dir .. "/" .. name:gsub("%.etag$", ""), "mode") then
            os.remove(dir .. "/" .. name)
            n = n + 1
        end
    end
    return n
end

-- A cover file that is there and looks like an image.
function OC.coverOk(path)
    local head = readFile(path, 16)
    return head ~= nil and Cache.imageHeader(head)
end

---------------------------------------------------------------- Refresh and Full refresh

function OC.visibleBooks(cat)
    local ctx = cat.current_context or {}
    if ctx.kind == "dashboard" and Compat.callable(cat.dashboardBooks) then return cat.dashboardBooks(ctx.dashboard) end
    if ctx.kind == "books" then return ctx.books or {} end
    if ctx.kind == "detail" and Compat.callable(cat.detailThumbnailBooks) then return cat:detailThumbnailBooks(ctx.detail) end
    return {}
end

-- A short note on screen (the plugin's toast; its absence is no error).
function OC.note(text, timeout)
    log("cache: note:", text)
    pcall(function() require("bookorbit_toast").show(text, { timeout = timeout or 2 }) end) -- gate: bookorbit_toast is gated (Gate.installToast)
end

-- Full refresh is done when its view has painted and its covers are re-asked.
function OC.fullStep(what, n)
    local f = OC.full
    if not f then return end
    if what == "painted" then f.painted = true end
    if what == "covers" then f.covers_done, f.replaced = true, n or 0 end
    if f.painted and f.covers_done then
        OC.full = nil
        OC.note(string.format(_("This page is refreshed · %d covers checked"), f.covers)
            .. ((f.replaced or 0) > 0 and string.format(_(", %d replaced"), f.replaced) or "")
            .. (Mirror and _(" · saving the rest for offline…") or ""), 3)
    end
end

-- Tap ⟳ / background checks: revalidate this view, never evict, retry failed covers.
-- Offline, a refresh first asks for the network (KOReader's own path, which the Orbit Wi-Fi
-- switching answers quietly) and runs once connected: it never repaints from a saved body.
local function whenOnline(what, fn)
    if NetworkMgr:isConnected() then return false end
    log("cache:", what, "while offline: connecting first")
    if Compat.callable(NetworkMgr.runWhenConnected) then
        NetworkMgr:runWhenConnected(fn)
    else
        OC.note(_("Connect to refresh"), 3)
    end
    return true
end

function OC.refresh(cat)
    if whenOnline("Refresh", function() OC.refresh(cat) end) then return end
    log("cache: Refresh")
    if not S.refresh_tip_shown then
        S.refresh_tip_shown = true
        pcall(saveSettings)
        OC.note(_("Refreshing… Tip: hold ⟳ for a full refresh"), 4)
    else
        OC.note(_("Refreshing…"), 2)
    end
    OC.begin("refresh")
    if type(cat.thumbnail_failures) == "table" then cat.thumbnail_failures = {} end
    local r = LF.refreshKeepingCovers(cat)
    -- The delta for the offline mirror: every saved page, in the background.
    if Mirror then pcall(Mirror.revalidate, "Refresh") end
    return r
end

-- Hold ⟳ / the menu: this view (and Home) from the server; bad cover files replaced, good ones
-- asked If-None-Match.
function OC.fullRefresh(cat)
    -- A second press while one is saving keeps that run and shows its progress (v0.11.1 on the
    -- M8C: four presses restarted it four times).
    if Mirror and Mirror.fullRunning() then return Mirror.showProgress("pressed again") end
    if whenOnline("Full refresh", function() OC.fullRefresh(cat) end) then return end
    log("cache: Full refresh")
    -- Copies whose library file changed are looked for now (and again once the details are saved).
    if Copies and Copies.tick then UIManager:scheduleIn(2, function() pcall(Copies.tick, "full refresh") end) end
    OC.note(_("Full refresh: reloading everything from BookOrbit…"), 3)
    OC.begin("full")
    if type(cat.thumbnail_failures) == "table" then cat.thumbnail_failures = {} end
    local books, bad, recheck = OC.visibleBooks(cat), 0, {}
    for _, b in ipairs(books) do
        local path = Compat.callable(cat.thumbnailPath) and cat:thumbnailPath(b)
        if path and b.hasCover ~= false then
            if lfs_ok and lfs.attributes(path, "mode") and not OC.coverOk(path) then
                os.remove(path); os.remove(path .. ".etag")
                if Compat.callable(cat.invalidateThumbnail) then cat:invalidateThumbnail(b, false) end
                bad = bad + 1
            elseif OC.coverOk(path) and readFile(path .. ".etag", 200) then
                table.insert(recheck, { book = b, path = path })
            end
        end
    end
    log("cache: Full refresh:", #books, "covers on screen,", bad, "broken (replaced),", #recheck, "re-asked")
    OC.full = { covers = #books }
    if #recheck > 0 then OC.recheckCovers(cat, recheck) else OC.fullStep("covers", bad) end
    -- Home's sections are fetched with the view when on Home; elsewhere, Home is marked stale.
    for k, m in pairs(OC.index().entries) do
        if m.home then m.stale = true; if OC.memo[k] then OC.memo[k].stale = true end end
    end
    local r = LF.refreshKeepingCovers(cat)
    -- Then everything reachable from Home, for offline (ko/mirror.lua).
    if Mirror then
        Mirror.cat = cat
        UIManager:scheduleIn(1, function() pcall(Mirror.start, "Full refresh", true) end)
    end
    return r
end

function OC.recheckCovers(cat, jobs)
    local client = cat.client
    if not client or not NetworkMgr:isConnected() then return OC.fullStep("covers", 0) end
    Background.run("cover recheck", function()
        local changed = {}
        for _, j in ipairs(jobs) do
            local api = package.loaded["bookorbit_api"]
            local ok, how = OC.coverDownload(client, api.__orbit_stock and api.__orbit_stock["cache:downloadCatalogThumbnail"] or api.downloadCatalogThumbnail,
                j.book.id, j.path, { temp_path = j.path .. ".part", orbit_recheck = true })
            if ok and how ~= "not_modified" then table.insert(changed, j.book.id) end
        end
        return Cache.encode(changed)
    end, 120, function(out)
        local changed = Cache.decode(out or "") or {}
        log("cache: covers re-asked:", #jobs, "checked,", #changed, "replaced")
        OC.fullStep("covers", #changed)
        if #changed > 0 and not cat.catalog_closed then
            if Compat.callable(cat.resetThumbnailMemo) then cat:resetThumbnailMemo() end
            if Compat.callable(cat.updateItems) then cat:updateItems(nil, true) end
        end
    end)
end

-- Refresh or Full refresh from the menu: the open catalog's view, else Home next time it opens.
function OC.menuFullRefresh()
    local p = bookorbit(liveUI())
    local cat = p and p.catalog_browser
    if cat and not cat.catalog_closed then return OC.fullRefresh(cat) end
    OC.begin("full")
    OC.active.until_t = nowT() + 600
    pcall(function() require("bookorbit_toast").show(_("Full refresh when BookOrbit opens next"), { timeout = 3 }) end) -- gate: bookorbit_toast is gated (Gate.installToast)
end

-- One line per paint: covers the view needs, how many are on disk, how many are queued.
function OC.coverSummary(cat)
    local books = OC.visibleBooks(cat)
    local need, have = 0, 0
    for _, b in ipairs(books) do
        if type(b) == "table" and b.hasCover then
            need = need + 1
            if Compat.callable(cat.cachedThumbnailPath) and cat:cachedThumbnailPath(b) then have = have + 1 end
        end
    end
    local q = cat.thumbnail_queue
    local queued = type(q) == "table" and q.tail and q.head and (q.tail - q.head + 1) or 0
    if need > 0 then log("covers:", need, "needed,", have, "on disk,", queued, "queued") end
end

---------------------------------------------------------------- install

OC.API = { request = "function", requestBlocking = "function", runInSubprocess = "function", downloadCatalogThumbnail = "function" }

function OC.install(why)
    if OC.installed then return true end
    if not OC.on() then return false end
    local Api = package.loaded["bookorbit_api"]
    local Catalog = package.loaded["bookorbit_catalog"]
    if type(Api) ~= "table" or type(Catalog) ~= "table" then return false end
    local missing = Compat.missingOn(Api, OC.API)
    if #missing > 0 then
        log("compat: offline cache off (plugin changed): missing " .. table.concat(missing, ", "))
        return false
    end
    wrap(Api, "request", function(stock) return function(self, method, path, body, headers)
        if OC.on() and Cache.cacheable(method, path) then
            local okr, handled, b, e, eb = pcall(OC.read, self, stock, method, path, body, headers)
            if okr and handled then return b, e, eb end
            if not okr then log("cache: read failed, straight to the server:", handled) end
            return stock(self, method, path, body, headers)
        end
        if OC.offline_pass and OC.on() then
            -- A write or other call in an offline view load: stop here quietly and connect.
            if inChild(self) then pcall(OC.event, "other", {}) else OC.offline_other = true end
            return nil, "cancelled"
        end
        local b, e, eb = stock(self, method, path, body, headers)
        if b ~= nil and tostring(method):upper() ~= "GET" and OC.on() then
            if inChild(self) then pcall(OC.event, "write", { method = method, path = path, body = body })
            else pcall(OC.afterWrite, method, path, body) end
        end
        return b, e, eb
    end end, "cache")
    wrap(Api, "runInSubprocess", function(stock) return function(self, fn, ...)
        if inChild(self) then return stock(self, fn, ...) end
        local okn, on = pcall(NetworkMgr.isConnected, NetworkMgr)
        OC.parent_online = not okn or on == true
        local a, b = stock(self, function(...)
            OC.child = true -- this copy of the process is the child
            local okf, r1, r2, r3 = pcall(fn, ...)
            OC.child = nil
            if not okf then error(r1, 0) end
            return r1, r2, r3
        end, ...)
        pcall(OC.drainEvents)
        return a, b
    end end, "cache")
    -- Offline: run the view's load from the cache, no connection asked. A page that isn't saved
    -- answers "cancelled" (quiet) and then asks "Connect and load more" (local-first design,
    -- "Paging past the saved pages"); a write or download just connects as before.
    if Compat.callable(Catalog.runConnected) then
        wrap(Catalog, "runConnected", function(stock) return function(self, fn)
            if not OC.on() or OC.offline_pass or NetworkMgr:isConnected() then return stock(self, fn) end
            OC.offline_pass, OC.offline_miss, OC.offline_other, OC.offline_search = true, false, false, false
            local okr, err = pcall(function()
                local Trapper = require("ui/trapper")
                Trapper:wrap(function()
                    local okf, ferr = pcall(fn)
                    OC.offline_pass = nil
                    pcall(OC.drainEvents)
                    if not okf then log("cache: offline view failed:", ferr) end
                    if OC.offline_other then return stock(self, fn) end
                    if OC.offline_search and not OC.offline_miss then
                        OC.note(_("Search needs a connection"), 3)
                        return
                    end
                    if OC.offline_miss then
                        log("cache: offline; asking to connect for a page that isn't saved")
                        UIManager:show(require("ui/widget/confirmbox"):new{ -- gate: user action (paging a list offline)
                            text = _("This page isn't saved on this reader."),
                            ok_text = _("Connect and load more"),
                            ok_callback = function() stock(self, fn) end,
                        })
                    end
                end)
            end)
            if not okr then OC.offline_pass = nil; log("cache: offline pass failed:", err); return stock(self, fn) end
        end end, "cache")
    end
    if Compat.callable(Api.download) then
        wrap(Api, "download", function(stock) return function(self, ...)
            if OC.offline_pass and OC.on() then
                if inChild(self) then pcall(OC.event, "other", {}) else OC.offline_other = true end
                return nil, "cancelled"
            end
            return stock(self, ...)
        end end, "cache")
    end
    wrap(Api, "downloadCatalogThumbnail", function(stock) return function(self, book_id, local_path, opts)
        if not OC.on() then return stock(self, book_id, local_path, opts) end
        local okd, r1, r2 = pcall(OC.coverDownload, self, stock, book_id, local_path, opts)
        if okd then return r1, r2 end
        return stock(self, book_id, local_path, opts)
    end end, "cache")
    -- The keys a view was built from, for redrawing it when one of them changes; a log line per
    -- paint naming where its data came from.
    wrap(Catalog, "switchTo", function(stock) return function(self, title, item_table, context, push)
        if #OC.pending > 0 then
            local keys, from = {}, {}
            for _, k in ipairs(OC.pending) do keys[k] = true; from[OC.source[k] or "?"] = true end
            self._orbit_view_keys = keys
            local src = {}
            for s in pairs(from) do table.insert(src, s) end
            table.sort(src)
            self._orbit_paint_source = table.concat(src, "+")
            OC.pending = {}
        end
        local r = stock(self, title, item_table, context, push)
        if OC.full then OC.fullStep("painted") end
        pcall(OC.coverSummary, self)
        return r
    end end, "cache")
    -- Home's first paint from this cache (the dashboard and its sections, assembled by the
    -- plugin's own dashboardRootFetch, nothing asked of the network) instead of the plugin's saved
    -- body; the local overlay goes on top in BoardData.build. Anything not saved -> the plugin's.
    if Compat.callable(Catalog.initialDashboardContext) and Compat.callable(Catalog.dashboardRootFetch) then
        wrap(Catalog, "initialDashboardContext", function(stock) return function(self, ...)
            -- The first paint shows which books are on the reader (Resume, never Download first).
            if LF and LF.primeOnDevice then pcall(LF.primeOnDevice, self) end
            if not OC.on() then return stock(self, ...) end
            OC.cache_only = true
            local prefer = self.prefer_cached_dashboard
            self.prefer_cached_dashboard = nil -- offline too: this cache, not the saved body
            local okf, items, context = pcall(self.dashboardRootFetch, self, { invisible = true })
            self.prefer_cached_dashboard = prefer
            OC.cache_only = nil
            OC.pending = {}
            if okf and type(context) == "table" and type(context.dashboard) == "table" and not context.unavailable then
                context.stale, context.orbit_first = true, true
                self._orbit_paint_source = "cache"
                log("cache: Home's first paint from the cache")
                return items, context
            end
            return stock(self, ...)
        end end, "cache")
    end
    -- Cover jobs dropped by a new view (the plugin's switchTo), for the log.
    if Compat.callable(Catalog.cancelThumbnailJobs) then
        wrap(Catalog, "cancelThumbnailJobs", function(stock) return function(self, ...)
            local q = self.thumbnail_queue
            local n = type(q) == "table" and q.tail and q.head and (q.tail - q.head + 1) or 0
            if n > 0 then log("covers:", n, "queued cover job(s) cancelled by a new view") end
            return stock(self, ...)
        end end, "cache")
    end
    if Compat.callable(Catalog.downloadThumbnailBatch) then
        wrap(Catalog, "downloadThumbnailBatch", function(stock) return function(self, batch, generation)
            local results = stock(self, batch, generation)
            local okn, bad = 0, 0
            for _, v in pairs(type(results) == "table" and results or {}) do if v then okn = okn + 1 else bad = bad + 1 end end
            log("covers: batch of", #(batch or {}), "->", results == nil and "interrupted" or (okn .. " saved, " .. bad .. " failed"),
                generation ~= self.thumbnail_generation and "(view changed; not drawn)" or "")
            return results
        end end, "cache")
    end
    pcall(Mirror.guardPrune, Catalog)
    OC.installed = true
    log("cache: installed (" .. tostring(why) .. ")")
    UIManager:scheduleIn(5, function()
        pcall(function() OC.cleanEtags(require("datastorage"):getDataDir() .. "/cache/bookorbit") end)
        pcall(OC.drainEvents)
    end)
    return true
end

do
    local base_init = OrbitAndroid.init
    function OrbitAndroid:init(...)
        local r = base_init(self, ...)
        if OC.on() then pcall(OC.install, "init") end
        return r
    end
end

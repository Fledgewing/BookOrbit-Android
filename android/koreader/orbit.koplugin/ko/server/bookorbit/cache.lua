-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- The write-through cache in front of BookOrbit (docs/design/write-through-cache.md "Android").
-- Rules: logic/server/bookorbit/cache.lua. This file: the wrappers on the plugin's API client (request,
-- downloadCatalogThumbnail, runInSubprocess) and catalog (switchTo), background checks, the view
-- redraws, Refresh and Full refresh, and cover ETags. What is saved lives in one SQLite file
-- that only Orbit Companion writes (docs/design/sqlite-cache.md); the plugin reads it (ko/store.lua)
-- and sends the companion what to save (a reply it fetched: CHECK mode "store") or patch (PATCH).
--
-- The catalog runs many requests inside a forked child (plugin Catalog:fetch, catalog.lua:881).
-- A child may serve from the database (its own connection, ko/db.lua) and returns what it learns
-- as metadata (check / write / read); the parent applies it in the runInSubprocess wrapper.
-- Companion replies arrive through a bounded mailbox at a fixed path.
---------------------------------------------------------------------------------------------

OC = { inflight = {}, done = {}, MODE_S = 30 }

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

OC.readFile, OC.writeFile = readFile, writeFile

-- The entry's file name (Cache.hash; the key is stored inside and checked).
function OC.hash(s) return Cache.hash(s) end

-- In a forked child (the plugin's runInSubprocess, catalog.lua:881): never JNI (NetworkMgr on
-- Android is JNI, device/android/device.lua:333; a child that calls it dies and the plugin gets
-- subprocess_no_result), never the UI; the parent's state comes across the fork.
local function inChild(client) return OC.child == true or (client and (client.subprocess_depth or 0) > 0) end

-- Online? In a child: what the parent saw just before it forked.
function OC.online(client)
    if inChild(client) then return OC.parent_online ~= false end
    return NetworkMgr:isConnected()
end

---------------------------------------------------------------- the plugin's own state

-- What the plugin keeps between starts besides the database: the detail variant it reads (for
-- the companion's detail template) and the copies queue. A few lines, written in place.
function OC.state()
    if OC._state then return OC._state end
    local d = Cache.decode(readFile(OC.dir() .. "/plugin-state.lua") or "")
    OC._state = type(d) == "table" and d or {}
    return OC._state
end

function OC.saveState()
    if OC.child then return end
    if Companion.workerProblem() then return end
    Companion.send(Companion.ACTION.PATCH, { reason = "plugin state", plugin_state = Cache.encode(OC.state()) })
end

-- Everything goes: the setting turned off, or on request (another account or server: the
-- companion clears the database itself when it next saves for another owner).
function OC.wipe(why)
    log("cache: cleared (" .. tostring(why) .. ")")
    OC._state = {}
    OC.saveState()
    OC.storage = nil
    if not Companion.workerProblem() then Companion.send(Companion.ACTION.PATCH, { reason = tostring(why), wipe = "1" }) end
    UIManager:scheduleIn(5, function() pcall(OC.storageCount, "cleared") end)
end

-- The account and server this cache belongs to (the database's owner; another one is a miss).
function OC.owner(client)
    return tostring(client.username or "") .. "|" .. tostring(client.server_url or ""):lower()
end

-- The plugin's detail request with Mirror.SENTINEL for the id (how the database names details).
function OC.detailTemplate(client)
    local okp, p = pcall(Mirror.detailPath, client, Mirror.SENTINEL)
    return okp and p or nil
end

---------------------------------------------------------------- child events

-- Child metadata travels in the subprocess result, never through a scanned directory.
function OC.event(kind, data)
    data.kind = kind
    OC.child_events = OC.child_events or {}
    table.insert(OC.child_events, data)
end

-- A single poll chain, shared by startup, reads and all job watchers. A lost ack is
-- retried with backoff; reading the same durable batch never creates another timer.
OC.EVENT_POLL_S, OC.EVENT_RETRY_S = 0.5, 10
function OC.drainEvents()
    if OC.child then return end
    UIManager:unschedule(OC.drainEvents)
    UIManager:scheduleIn(OC.EVENT_POLL_S, OC.drainEvents)
    if Companion.workerProblem() then return end
    local t = now_s()
    if OC.events_read_at and t - OC.events_read_at < OC.EVENT_POLL_S then return end
    OC.events_read_at = t
    local batch = Cache.decode(readFile(OC.dir() .. "/events-batch.lua", 65536) or "")
    if type(batch) ~= "table" or not batch.id then return end
    if batch.id ~= OC.events_ack then
        -- Record before dispatch: an event may synchronously call a watcher again.
        OC.events_ack, OC.events_sent_at = batch.id, nil
        OC.applyEvents(batch.events or {})
    end
    if not OC.events_sent_at or t - OC.events_sent_at >= OC.EVENT_RETRY_S then
        OC.events_sent_at = t
        Companion.send(Companion.ACTION.PATCH, { reason = "events", drain_events = "1", events_ack = batch.id })
    end
end

function OC.applyEvents(events)
    for _, ev in ipairs(events) do
        if type(ev) == "table" then
            if LibraryAdapter and (ev.kind == "checked" or ev.kind == "copies") then LibraryAdapter.changed(ev) end
            if ev.kind == "library" or ev.kind == "library_source" then
                LibraryAdapter.changed(ev)
            elseif ev.kind == "stored" then
                -- (0.11.x) nothing: the companion saves now.
            elseif ev.kind == "board_year" and LF then
                LF.yearLanded(ev)
            elseif ev.kind == "native_footer_repair" then
                -- G_reader_settings is already loaded. Correct its matching scalar
                -- too, or KOReader's next native flush would undo the disk repair.
                -- This does not touch an open ReaderFooter or reflow the document.
                if type(ev.token) == "string" and S.native_footer_repair ~= ev.token then
                    local function scalar(text)
                        if text == "nil" then return nil, true end
                        local n = tonumber(text)
                        return n, n ~= nil and n == n and n ~= math.huge and n ~= -math.huge
                    end
                    local before, valid_before = scalar(ev.before)
                    local after, valid_after = scalar(ev.after)
                    if valid_before and valid_after then
                        if G_reader_settings:readSetting("reader_footer_mode") == before then
                            G_reader_settings:saveSetting("reader_footer_mode", after)
                            log("status repair: native global footer mode " .. tostring(before) .. "->" .. tostring(after))
                        end
                        S.native_footer_repair = ev.token
                        saveSettings()
                    end
                end
            elseif ev.kind == "storage" then
                OC.storageCounted(ev)
            elseif ev.kind == "covers_rechecked" then
                OC.rechecked(ev)
            elseif ev.kind == "sleep_pool" and Sleep then
                Sleep.landed(ev)
            elseif ev.kind == "copy_prepared" and Copies then
                Copies.prepared(ev)
            elseif ev.kind == "copies" and Copies then
                Copies.found(ev)
            elseif ev.kind == "checked" and ev.key then
                local job = OC.inflight[ev.key]
                OC.inflight[ev.key] = nil
                if job then OC.landed(nil, job, ev) end
            elseif ev.kind == "check" and ev.key then
                OC.check(nil, ev.key, ev.method, ev.path, ev.headers, nil, ev.mode)
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

-- The entry for a read: the database's answer (a list window, a detail, any other reply), or nil.
function OC.lookup(client, key, path)
    return Store.read(OC.owner(client), key, path, OC.detailTemplate(client))
end

-- The wrapper's body for a cacheable GET. Returns handled, body, err, errbody.
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
    if variant and not inChild(client) and OC.state().detail_variant ~= variant then
        OC.state().detail_variant = variant
        OC.saveState()
    end
    local short = tostring(path):gsub("^/koreader/plugin/catalog", "")
    if not serve and OC.cache_only then return true, nil, "cancelled" end
    if not offline and not OC.cache_only and not inChild(client) then pcall(OC.mirrorTick, "read") end
    if serve then
        OC.saw(client, key, "cache")
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
            -- Offline search: over the saved books (title, authors, series).
            local found = Store.search(OC.owner(client), path)
            if found and (found.total or 0) > 0 then
                OC.saw(client, key, "cache")
                log("cache:", short, "searched the saved books (offline):", found.total)
                return true, found
            end
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
        OC.store(client, key, method, path, headers)
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

-- A reply read from the server: the companion asks again and saves it (CHECK mode "store"), so
-- KOReader never encodes or writes a reply. A search isn't saved (offline search reads the books).
function OC.store(client, key, method, path, headers)
    if Cache.isSearch(path) then return end
    if inChild(client) then return OC.event("check", { key = key, method = method, path = path, headers = headers, mode = "store" }) end
    OC.check(nil, key, method, path, headers, client, "store")
end

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

-- Asks the companion to check key against the server (docs/design/companion-worker.md): it
-- asks, compares with what the plugin would serve (its entry, else the mirror's pages), saves a
-- changed reply under the key and answers with a "checked" event (OC.drainEvents). KOReader only
-- sends the job and reads the small answer: it never handles the reply's body (decoding and
-- encoding it froze the UI on the M8C). One per key; none without the companion.
function OC.check(_, key, method, path, headers, client, mode)
    if OC.inflight[key] or method ~= "GET" then return end
    client = client or OC.client()
    if not client or not NetworkMgr:isConnected() then return end
    local problem = Companion.workerProblem()
    if problem then
        if OC.check_blocked ~= problem then log("cache: background checks off:", problem) end
        OC.check_blocked = problem
        return
    end
    OC.check_blocked = nil
    OC.inflight[key] = { key = key, path = path, at = nowT() }
    Companion.send(Companion.ACTION.CHECK, { reason = "check", cache_key = key, path = path, mode = mode or OC.mode(),
        owner = OC.owner(client), server = client.server_url, user = client.username, userkey = client.userkey,
        template = OC.detailTemplate(client) or "" })
    OC.watchChecks()
end

-- While checks are out: their answers are read every second; one with no answer in CHECK_S fails.
OC.CHECK_S = 60
function OC.watchChecks()
    if OC.watching then return end
    OC.watching = true
    local function tick()
        pcall(OC.drainEvents)
        local t = nowT()
        for key, job in pairs(OC.inflight) do
            if t - job.at >= OC.CHECK_S then
                OC.inflight[key] = nil
                OC.landed(nil, job, { err = "the companion didn't answer" })
            end
        end
        if OC.storage_asked and t - OC.storage_asked >= OC.STORAGE_WAIT_S then
            log("storage: the companion didn't answer the count")
            OC.storage_asked = nil
        end
        if Copies and Copies.asked and t - Copies.asked >= Copies.WAIT_S then
            log("copies: the companion didn't answer the check")
            Copies.asked = nil
        end
        if LF and LF.year_waiting and os.time() - LF.year_waiting > 60 then LF.year_waiting = nil end
        local sleep_waits = Sleep and Sleep.waited(t)
        if OC.recheck and t - OC.recheck.at >= OC.RECHECK_WAIT_S then
            log("cache: the companion didn't answer the cover recheck")
            OC.rechecked({ err = "no answer" })
        end
        if Copies and Copies.prepare_at and t - Copies.prepare_at >= Copies.WAIT_S then
            Copies.preparing, Copies.prepare_at, Copies.busy = nil, nil, nil
            Copies.stop("companion preparation timed out")
        end
        if not (LibraryAdapter and LibraryAdapter.watching) and next(OC.inflight) == nil and not OC.storage_asked and not (Copies and (Copies.asked or Copies.prepare_at)) and not sleep_waits and not OC.recheck and not (LF and LF.year_waiting) then OC.watching = nil; return end
        UIManager:scheduleIn(1, tick)
    end
    UIManager:scheduleIn(1, tick)
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

function OC.landed(client, job, r)
    local short = tostring(job.path):gsub("^/koreader/plugin/catalog", "")
    if type(r) ~= "table" or not (r.changed or r.unchanged) then
        OC.failed[job.key] = true
        log("cache:", short, "check failed (network:", tostring(type(r) == "table" and r.err or "no answer") .. "); the saved copy stays")
        return
    end
    OC.failed[job.key] = nil
    if r.unchanged then
        log("cache:", short, "checked: unchanged")
        return
    end
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
        if next(OC.inflight) ~= nil then return UIManager:scheduleIn(0.5, flush) end
        OC.redraw_scheduled = nil
        local k = OC.redraw_key
        OC.redraw_key = nil
        if k then OC.redraw(k) end
    end
    UIManager:scheduleIn(0.3, flush)
end

-- What keeps Wi-Fi on (Wifi.busy): checks in flight or the offline mirror saving.
function OC.busy()
    if next(OC.inflight) ~= nil then return "the BookSync cache checking BookOrbit" end
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
    -- The companion patches the saved book (and the lists that name it) and marks Home stale.
    -- A progress write names the book by document digest; the local overlay already shows this
    -- device's position, and Home is checked against the server on its next read.
    if Companion.workerProblem() then return end
    Companion.send(Companion.ACTION.PATCH, { reason = "write", id = eff.id and tostring(eff.id) or "",
        fields = eff.fields and Cache.encode(eff.fields) or "", stale_home = eff.stale_home and "1" or "0" })
    log("cache: a write to", (tostring(path):gsub("^/koreader/plugin/catalog", "")), "sent to the companion to patch")
end

---------------------------------------------------------------- covers (ETag)

OC.olderCover = CoverChild.olderCover

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
    local have = old
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

-- ETags whose cover is gone are removed by CacheWorker.storageItems, alongside its count.
function OC.cleanEtags()
    return OC.storageCount("orphan ETags")
end

---------------------------------------------------------------- the storage limit (v0.11.2)

-- Everything Orbit stores counts (Orbit menu › Storage limit, S.storage_limit_mb): the database
-- (browsing replies, the lists and books saved for offline) and the covers in the plugin's cover
-- directory, saved for offline or not. Book files and KOReader's own data don't. Orbit Companion
-- counts and, over the limit, removes the oldest browsing replies and covers itself (STORAGE,
-- docs/design/companion-worker.md); the plugin keeps the totals it answers with.
local MB = 1048576
OC.STORAGE_WAIT_S = 60

function OC.limitBytes()
    local mb = tonumber(S.storage_limit_mb) or Cache.STORAGE_DEFAULT_MB
    return mb > 0 and mb * MB or nil
end

function OC.coverDir()
    if OC.cover_dir then return OC.cover_dir end
    local okd, DataStorage = pcall(require, "datastorage")
    local okp, d = pcall(function() return DataStorage:getDataDir() end)
    return okd and okp and d and (d .. "/cache/bookorbit") or nil
end

-- Asks the companion to count (and, over the limit, remove). One ask at a time; one asked
-- meanwhile follows it.
function OC.storageCount(why)
    if OC.child then return end
    if why == "over the limit" and OC.storage_last and nowT() - OC.storage_last < 60 then return end
    if OC.storage_asked and nowT() - OC.storage_asked < OC.STORAGE_WAIT_S then OC.storage_again = why; return end
    local problem = Companion.workerProblem()
    if problem then
        if OC.storage_problem ~= problem then OC.storage_problem = problem; log("storage: not counted:", problem) end
        return
    end
    OC.storage_problem = nil
    OC.storage_asked, OC.storage_again, OC.storage_last = nowT(), nil, nowT()
    local limit = OC.limitBytes()
    Companion.send(Companion.ACTION.STORAGE, { reason = tostring(why), limit = limit and tostring(limit) or "",
        cover_dir = OC.coverDir() or "", mirror_covers = S.mirror_covers and "1" or "0" })
    OC.watchChecks()
end

-- The companion's count: dropped browsing entries leave the index (unless used since), totals kept.
function OC.storageCounted(ev)
    OC.storage_asked = nil
    local rm0 = type(ev.removed) == "table" and ev.removed or {}
    local dropped = rm0.cache or 0
    if type(ev.totals) == "table" then OC.storage = ev.totals end
    local st, limit, rm = OC.storage or {}, OC.limitBytes(), type(ev.removed) == "table" and ev.removed or {}
    if (ev.used or 0) ~= (ev.after or 0) then
        log(string.format("storage: %.1f MB of %d MB (%s); removed %d browsing entries, %d covers, %d saved-for-offline covers -> %.1f MB",
            (ev.used or 0) / MB, math.floor((limit or 0) / MB), tostring(ev.why), dropped, rm.cover or 0, rm.mirror_cover or 0, (ev.after or 0) / MB))
    elseif ev.why == "start" then
        log(string.format("storage: using %.1f MB of %s (lists and books saved for offline %.1f MB, covers %.1f MB, of them saved for offline %.1f MB)",
            (st.used or 0) / MB, limit and (math.floor(limit / MB) .. " MB") or "no limit", (st.kept or 0) / MB,
            ((st.cover or 0) + (st.mirror_cover or 0)) / MB, (st.mirror_cover or 0) / MB))
    end
    local again = OC.storage_again
    OC.storage_again = nil
    if again and again ~= "over the limit" then OC.storageCount(again) end
end

-- What Orbit stores now ({ used, kept, cache, cover, mirror_cover } bytes): the last count (the
-- worker's last answer), or nil before the first.
function OC.storageTotals()
    return OC.storage
end

-- A write of delta bytes of a kind: over the limit, the companion counts and removes.
function OC.storageAdd(delta, kind)
    local st = OC.storage
    if OC.child or not st or delta == 0 then return end
    st.used = (st.used or 0) + delta
    st[kind] = (st[kind] or 0) + delta
    local limit = OC.limitBytes()
    if limit and st.used > limit then OC.storageCount("over the limit") end
end

-- "Using 58 MB" (the setting's line).
function OC.storageText()
    local st = OC.storageTotals()
    local mb = (st and st.used or 0) / MB
    return string.format(mb < 10 and _("Using %.1f MB") or _("Using %d MB"), mb < 10 and mb or math.floor(mb + 0.5))
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
        -- Logged only: during a Full refresh the badge is the one thing on screen.
        OC.full = nil
        log(string.format("cache: Full refresh: this page is refreshed, %d covers checked, %d replaced", f.covers or 0, f.replaced or 0))
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
    if Mirror and Mirror.fullRunning() then return Mirror.showProgress("Refresh tapped") end
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
    local problem = Companion.workerProblem()
    if problem then return OC.note(problem, 4) end
    -- Start the bulk job before any view work. The companion owns validation,
    -- hashing, cover checks and the manifest. No synchronous Home refresh here.
    Mirror.cat, Mirror.notices = cat, true
    log("cache: Full refresh: starting companion bulk catalog")
    local started = Mirror.start("Full refresh", true)
    if started then
        local jobs = {}
        for _, book in ipairs(OC.visibleBooks(cat)) do
            if book.hasCover ~= false and Compat.callable(cat.thumbnailPath) then
                local path = cat:thumbnailPath(book)
                if path then jobs[#jobs + 1] = { book = book, path = path } end
            end
        end
        if #jobs > 0 then OC.recheckCovers(cat, jobs) end
    end
    return started
end

-- Orbit Companion asks them again If-None-Match (CacheWorker.recheckCovers) and answers with a
-- covers_rechecked event; the view redraws if one changed. Ids and paths travel in the broadcast.
OC.RECHECK_WAIT_S = 120
function OC.recheckCovers(cat, jobs)
    local client = cat.client
    if not client or not NetworkMgr:isConnected() or Companion.workerProblem() then return OC.fullStep("covers", 0) end
    local ids, paths = {}, {}
    for _, j in ipairs(jobs) do table.insert(ids, tostring(j.book.id)); table.insert(paths, j.path) end
    OC.recheck = { at = nowT(), cat = cat, n = #jobs }
    Companion.send(Companion.ACTION.RECHECK, { reason = "full refresh", ids = table.concat(ids, "\n"), paths = table.concat(paths, "\n"),
        server = client.server_url, user = client.username, userkey = client.userkey })
    OC.watchChecks()
end

function OC.rechecked(ev)
    local r = OC.recheck
    OC.recheck = nil
    if not r then return end
    if ev.err then log("cache: covers not re-asked:", tostring(ev.err)) end
    local changed = type(ev.changed) == "table" and ev.changed or {}
    log("cache: covers re-asked:", tonumber(ev.checked) or 0, "checked,", #changed, "replaced")
    OC.fullStep("covers", #changed)
    local cat = r.cat
    if #changed > 0 and cat and not cat.catalog_closed then
        if Compat.callable(cat.resetThumbnailMemo) then cat:resetThumbnailMemo() end
        if Compat.callable(cat.updateItems) then cat:updateItems(nil, true) end
    end
end

-- Refresh or Full refresh from the menu: the open catalog's view, else Home next time it opens.
function OC.menuFullRefresh()
    local p = bookorbit(liveUI())
    local cat = p and p.catalog_browser
    if not cat and p and EOB then cat = EOB.headlessCatalog(p) end
    if cat then return OC.fullRefresh(cat) end
    OC.note(_("Open BookOrbit and sign in to refresh the catalog."), 4)
end

-- One line per paint: covers the view needs, how many are on disk, how many are queued.
function OC.coverSummary(cat)
    local books = OC.visibleBooks(cat)
    local need, have, shown = 0, 0, {}
    for _, b in ipairs(books) do
        if type(b) == "table" and b.hasCover then
            need = need + 1
            local path = Compat.callable(cat.cachedThumbnailPath) and cat:cachedThumbnailPath(b)
            if path then have = have + 1; table.insert(shown, path) end
        end
    end
    if #shown > 0 and not Companion.workerProblem() then
        Companion.send(Companion.ACTION.STORAGE, { shown = table.concat(shown, "\n") })
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
            OC.child_events = {}
            local okf, r1, r2, r3 = pcall(fn, ...)
            OC.child = nil
            if not okf then error(r1, 0) end
            return { orbit_result = { body = r1, err = r2, errbody = r3 }, orbit_events = OC.child_events }
        end, ...)
        if a and type(b) == "table" and type(b.body) == "table" and b.body.orbit_result then
            local envelope = b.body
            b = envelope.orbit_result
            OC.applyEvents(envelope.orbit_events or {})
        end
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
            -- Written in the child: counted at about 100 KB each; over the limit, counted for real.
            if okn > 0 then pcall(OC.storageAdd, okn * 100 * 1024, "cover") end
            return results
        end end, "cache")
    end
    pcall(Mirror.guardPrune, Catalog)
    OC.installed = true
    log("cache: installed (" .. tostring(why) .. ")")
    -- The storage limit, counted on start.
    UIManager:scheduleIn(8, function()
        local okc, err = pcall(OC.storageCount, "start")
        if not okc then log("storage: count failed:", tostring(err)) end
    end)
    UIManager:scheduleIn(5, function()
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

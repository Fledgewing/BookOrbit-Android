-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- The offline mirror (docs/design/write-through-cache.md "Offline mirror"): a Full refresh saves
-- everything reachable from Home without typing, one request at a time in the background, in
-- 100-book pages that answer any page size the plugin asks for (Cache.slice). A Refresh rechecks
-- every saved page; a list whose total moved is re-paged. The queue is in the cache index, so a
-- run picks up where it stopped after sleep or going offline.
---------------------------------------------------------------------------------------------

Mirror = { NOTE_EVERY_S = 10, COVER_BATCH = 20 }
local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")

-- Section indexes Full refresh saves, in order; each entry's book list follows its index.
Mirror.SECTIONS = { "collections", "smart-scopes", "libraries", "series", "authors" }

local function nowT() return OC.now() end

function Mirror.state()
    local idx = OC.index()
    idx.mirror = idx.mirror or { lists = {}, queue = {} }
    local m = idx.mirror
    m.lists, m.queue = m.lists or {}, m.queue or {}
    return m
end

-- The catalog whose methods build the plugin's own requests (paramsForEntry, effectiveOrder,
-- listDecorateBookQuery, listSectionParams): the open one, else the last one seen.
function Mirror.catalog()
    local p = bookorbit(liveUI())
    local cat = p and p.catalog_browser
    if cat and cat.client then Mirror.cat = cat end
    return Mirror.cat
end

local function libraryVersion()
    local sm = package.loaded["bookorbit_state_manager"]
    if type(sm) ~= "table" or type(sm.state) ~= "function" then return nil end
    local okv, v = pcall(function() local st = sm.state(); return st and st.global and st.global.libraryVersion end)
    return okv and v or nil
end
Mirror.libraryVersion = libraryVersion

---------------------------------------------------------------- what to save

local function push(m, job, front)
    m.seen = m.seen or {}
    local id = job.k .. "|" .. tostring(job.identity or job.path or job.batch or "") .. "|" .. tostring(job.page or "")
    if m.seen[id] then return end
    m.seen[id] = true
    if front then table.insert(m.queue, 1, job) else table.insert(m.queue, job) end
    m.total = (m.total or 0) + 1
end

function Mirror.addList(m, path, front)
    local w = Cache.listWindow(path)
    if not w then return end
    push(m, { k = "page", identity = w.identity, page = 1, kind = w.kind, section = w.section }, front)
end

-- A book list the plugin would open for a section entry (bookorbit_catalog.lua:1111
-- paramsForEntry, :1135 fetchBookPage's sort, order and decoration).
function Mirror.entryPath(cat, section, entry)
    if not (cat and Compat.callable(cat.paramsForEntry)) then return nil end
    local q = cat:paramsForEntry(section, entry)
    q.sort = q.sort or cat.default_sort or "recently_added"
    if Compat.callable(cat.effectiveOrder) then q.order = cat:effectiveOrder(q) end
    if Compat.callable(cat.listDecorateBookQuery) then pcall(cat.listDecorateBookQuery, cat, q) end
    return cat.client:query("/koreader/plugin/catalog/books", q)
end

-- A section index as the plugin asks for it (bookorbit_catalog_lists.lua:246).
function Mirror.sectionPath(cat, section)
    local params = {}
    if cat and Compat.callable(cat.listSectionParams) then
        local okp, p = pcall(cat.listSectionParams, cat, section, {})
        if okp and type(p) == "table" then params = p end
    end
    return cat.client:query("/koreader/plugin/catalog/sections/" .. section, params)
end

-- The On device list (bookorbit_catalog.lua:1187 loadOnDevice).
function Mirror.onDevicePath(cat)
    if not (cat and type(cat.on_device) == "table") then return nil end
    local ids = {}
    for id in pairs(cat.on_device) do table.insert(ids, tonumber(id)) end
    if #ids == 0 then return nil end
    table.sort(ids)
    local capped = {}
    for i = 1, math.min(#ids, 200) do capped[i] = ids[i] end
    local q = { ids = table.concat(capped, ","), sort = "title" }
    if Compat.callable(cat.effectiveOrder) then q.order = cat:effectiveOrder(q) end
    if Compat.callable(cat.listDecorateBookQuery) then pcall(cat.listDecorateBookQuery, cat, q) end
    return cat.client:query("/koreader/plugin/catalog/books", q)
end

function Mirror.detailPath(client, id)
    local variant = OC.index().detail_variant
    return client:query("/koreader/plugin/catalog/books/" .. tostring(id), { deviceId = client.device_id, variant = variant })
end

local function addDetail(m, client, id)
    if not id then return end
    push(m, { k = "detail", path = Mirror.detailPath(client, id), id = tonumber(id) })
end

-- Book ids in a dashboard-like body: Continue reading and every shelf.
local function homeIds(body, out)
    if type(body) ~= "table" then return out end
    for _, b in ipairs(type(body.continueReading) == "table" and body.continueReading or {}) do out[tonumber(b.id) or 0] = true end
    for _, b in ipairs(type(body.items) == "table" and body.items or {}) do out[tonumber(b.id) or 0] = true end
    for _, b in ipairs(type(body.books) == "table" and body.books or {}) do out[tonumber(b.id) or 0] = true end
    out[0] = nil
    return out
end

-- Seeds a run: every list the plugin has read (Home's shelves among them), the section indexes,
-- On device, and the details of books on the reader, Continue reading and Up next in series.
function Mirror.seed(m, cat)
    local client = cat.client
    for _, meta in pairs(OC.index().entries) do
        if meta.path and not meta.mirror then Mirror.addList(m, meta.path) end
    end
    local od = Mirror.onDevicePath(cat)
    if od then Mirror.addList(m, od, true) end
    for _, s in ipairs(Mirror.SECTIONS) do Mirror.addList(m, Mirror.sectionPath(cat, s)) end
    local ids = {}
    for id in pairs(type(cat.on_device) == "table" and cat.on_device or {}) do ids[tonumber(id) or 0] = true end
    for key, meta in pairs(OC.index().entries) do
        if meta.home then
            local e = OC.get(key)
            if e then homeIds(e.body, ids) end
        end
    end
    ids[0] = nil
    local sorted = {}
    for id in pairs(ids) do table.insert(sorted, id) end
    table.sort(sorted)
    for _, id in ipairs(sorted) do addDetail(m, client, id) end
end

---------------------------------------------------------------- running

function Mirror.start(reason, manual)
    local cat = Mirror.catalog()
    if not (cat and cat.client) then
        log("mirror: no BookOrbit catalog yet; the Full refresh waits until BookOrbit opens")
        return false
    end
    local m = Mirror.state()
    m.queue, m.seen, m.done, m.total, m.bytes, m.requests = {}, {}, 0, 0, 0, 0
    m.covers = { ok = 0, not_modified = 0, failed = 0, bytes = 0 }
    m.started_at, m.reason, m.revalidating = nowT(), reason, nil
    m.next_lists = {}
    Mirror.seed(m, cat)
    Mirror.manual = manual
    log("mirror: Full refresh (" .. tostring(reason) .. "):", #m.queue, "lists and books to save; cache limit",
        math.floor(Cache.MAX_BYTES / 1048576) .. " MB / " .. Cache.MAX_ENTRIES .. " entries outside the mirror")
    OC.saveIndex()
    Mirror.pump()
    return true
end

-- Refresh's delta: every saved page of every mirrored list, compared with what is saved.
function Mirror.revalidate(reason)
    local m = Mirror.state()
    if not m.at or (m.queue and #m.queue > 0) then return false end
    m.seen, m.done, m.total, m.bytes, m.requests = {}, 0, 0, 0, 0
    m.covers = { ok = 0, not_modified = 0, failed = 0, bytes = 0 }
    m.revalidating, m.started_at = true, nowT()
    local identities = {}
    for identity in pairs(m.lists) do table.insert(identities, identity) end
    table.sort(identities)
    for _, identity in ipairs(identities) do
        local l = m.lists[identity]
        for n = 1, Cache.pageCount(l.total) do
            push(m, { k = "page", identity = identity, page = n, kind = l.kind, section = l.section, check = true })
        end
    end
    log("mirror: Refresh rechecks", m.total, "saved pages (" .. tostring(reason) .. ")")
    Mirror.pump()
    return true
end

function Mirror.running() return Mirror.active == true end

function Mirror.stop(why)
    if not Mirror.active then return end
    Mirror.active = nil
    Mirror.cat_wait = nil
    log("mirror: paused (" .. why .. "),", #Mirror.state().queue, "left; it resumes when online")
    Wifi.release("mirror")
end

function Mirror.note(text)
    if not Mirror.manual then return end
    local t = nowT()
    if Mirror.noted_at and t - Mirror.noted_at < Mirror.NOTE_EVERY_S then return end
    Mirror.noted_at = t
    OC.note(text, 2)
end

-- One job at a time, in a child process; nothing redraws but the progress note.
function Mirror.pump()
    if Mirror.busy then return end
    local m = Mirror.state()
    local job = m.queue[1]
    if not job then return Mirror.finish() end
    local cat = Mirror.catalog()
    local client = cat and cat.client
    if not client then return Mirror.stop("no BookOrbit catalog") end
    if not NetworkMgr:isConnected() then return Mirror.stop("offline") end
    if not Mirror.active then
        Mirror.active = true
        Wifi.acquire("mirror")
        log("mirror: running;", #m.queue, "to go; Wi-Fi held until it ends")
    end
    Mirror.busy = true
    local path = job.k == "page" and Cache.mirrorPage(job.identity, job.page) or job.path
    local function done(out)
        Mirror.busy = nil
        table.remove(m.queue, 1)
        m.done = (m.done or 0) + 1
        local okl, err = pcall(Mirror.landed, cat, client, job, path, out)
        if not okl then log("mirror: step failed:", tostring(err)) end
        Mirror.note(string.format(_("Full refresh · saving for offline %d/%d"), m.done, m.total or m.done))
        OC.saveIndex()
        UIManager:scheduleIn(0.05, Mirror.pump)
    end
    if job.k == "covers" then
        return Background.run("mirror covers", function() return Cache.encode(Mirror.coverBatch(client, job.batch)) end, 300, done)
    end
    Background.run("mirror", function()
        local b, e = client:requestBlocking("GET", path)
        return Cache.encode({ body = b, err = e and tostring(e) or nil })
    end, 60, done)
end

-- In the child: each cover by ETag (a file with an ETag asks If-None-Match; a missing one is
-- downloaded; a file the plugin saved without an ETag is left alone).
function Mirror.coverBatch(client, batch)
    local api = package.loaded["bookorbit_api"]
    local stock = api and api.__orbit_stock and api.__orbit_stock["cache:downloadCatalogThumbnail"] or (api and api.downloadCatalogThumbnail)
    local r = { ok = 0, not_modified = 0, failed = 0, bytes = 0, written = {} }
    for _, c in ipairs(batch or {}) do
        local exists = lfs_ok and lfs.attributes(c.path, "mode") == "file"
        local has_etag = exists and io.open(c.path .. ".etag", "rb")
        if has_etag then has_etag:close() end
        if not exists or has_etag then
            local okd, ok, how = pcall(OC.coverDownload, client, stock, c.id, c.path,
                { temp_path = c.path .. ".part", max_bytes = 4 * 1024 * 1024, orbit_recheck = has_etag and true or nil })
            if okd and ok and how == "not_modified" then r.not_modified = r.not_modified + 1
            elseif okd and ok then
                r.ok = r.ok + 1
                r.bytes = r.bytes + (lfs_ok and lfs.attributes(c.path, "size") or 0)
                table.insert(r.written, c.id)
            else r.failed = r.failed + 1 end
        end
    end
    return r
end

local function coversFor(m, cat, items)
    if not (cat and Compat.callable(cat.thumbnailPath)) then return end
    local batch = {}
    local function flush()
        if #batch == 0 then return end
        m.cover_batch = (m.cover_batch or 0) + 1
        push(m, { k = "covers", batch = batch, path = "covers#" .. m.cover_batch })
        batch = {}
    end
    for _, b in ipairs(items or {}) do
        if type(b) == "table" and b.id and b.hasCover then
            local okp, path = pcall(cat.thumbnailPath, cat, b)
            if okp and path then table.insert(batch, { id = b.id, path = path, updatedAt = b.updatedAt }) end
            if #batch >= Mirror.COVER_BATCH then flush() end
        end
    end
    flush()
end

function Mirror.landed(cat, client, job, path, out)
    local m = Mirror.state()
    local r = Cache.decode(out or "")
    if job.k == "covers" then
        if type(r) ~= "table" then m.covers.failed = m.covers.failed + #job.batch; return end
        for _, k in ipairs({ "ok", "not_modified", "failed", "bytes" }) do m.covers[k] = (m.covers[k] or 0) + (r[k] or 0) end
        for _, id in ipairs(r.written or {}) do
            for _, c in ipairs(job.batch) do
                if c.id == id and cat and Compat.callable(cat.invalidateThumbnail) then
                    pcall(cat.invalidateThumbnail, cat, { id = c.id, updatedAt = c.updatedAt, hasCover = true }, true)
                end
            end
        end
        return
    end
    if type(r) ~= "table" or type(r.body) ~= "table" then
        log("mirror:", (tostring(path):gsub("^/koreader/plugin/catalog", "")), "failed:", tostring(type(r) == "table" and r.err or "no answer"))
        return
    end
    local body = r.body
    m.requests = (m.requests or 0) + 1
    local key = Cache.key({ account = OC.owner(client), server = client.server_url, method = "GET", path = path })
    local old = OC.get(key)
    local changed = not old or Cache.revalidate(old.body, body, 200)
    if changed then
        OC.put(client, key, body, path)
    else
        OC.touch(key, true)
    end
    local meta = OC.index().entries[key]
    if meta then
        meta.mirror, meta.keep = true, true
        m.bytes = (m.bytes or 0) + (meta.bytes or 0)
    end
    if job.k == "detail" then
        -- The next book in each series the reader is in.
        if not job.next_of and type(body.seriesMembers) == "table" then
            for _, s in ipairs(body.seriesMembers) do
                if tonumber(s.id) ~= job.id and s.readStatus ~= "read" and (s.seriesIndex or 0) > (body.seriesIndex or 0) then
                    push(m, { k = "detail", path = Mirror.detailPath(client, s.id), id = tonumber(s.id), next_of = job.id })
                    break
                end
            end
        end
        coversFor(m, cat, { body })
        return
    end
    -- A list page.
    local l = m.lists[job.identity]
    local total = tonumber(body.total) or #(body.items or {})
    if job.page == 1 then
        local old_total = l and l.total
        m.lists[job.identity] = { total = total, kind = job.kind, section = job.section }
        if not job.check or old_total ~= total then
            local fetch, drop = Cache.repage(job.check and old_total or 0, total)
            for _, n in ipairs(fetch) do
                push(m, { k = "page", identity = job.identity, page = n, kind = job.kind, section = job.section, check = job.check })
            end
            for _, n in ipairs(drop) do
                local dk = Cache.key({ account = OC.owner(client), server = client.server_url, method = "GET", path = Cache.mirrorPage(job.identity, n) })
                OC.index().entries[dk] = nil
                OC.memo[dk] = nil
            end
            if job.check and old_total ~= total then
                log("mirror:", (job.identity:gsub("^/koreader/plugin/catalog", "")), "total", tostring(old_total), "->", total, "; re-paged")
            end
        end
    end
    -- A section's entries open book lists; a books page's covers.
    if job.kind == "section" and cat then
        for _, entry in ipairs(body.items or {}) do
            local okp, p = pcall(Mirror.entryPath, cat, job.section, entry)
            if okp and p then Mirror.addList(m, p) end
        end
    elseif job.kind == "books" and not job.check then
        coversFor(m, cat, body.items)
    end
    if job.check and changed and old then Mirror.changedOnScreen(job.identity) end
end

-- A mirror page changed under a list on screen: that view reloads from the cache.
function Mirror.changedOnScreen(identity)
    local p = bookorbit(liveUI())
    local cat = p and p.catalog_browser
    if not cat or cat.catalog_closed or not cat._orbit_view_keys then return end
    local want = Cache.key({ path = identity })
    for k in pairs(cat._orbit_view_keys) do
        local path, q = k:match("|GET|([^|]*)|(.*)$")
        local w = path and Cache.listWindow(path .. (q ~= "" and ("?" .. q) or ""))
        if w and Cache.key({ path = w.identity }) == want then
            OC.redraw_soon(k)
            return
        end
    end
end

function Mirror.finish()
    local m = Mirror.state()
    local was = Mirror.active
    Mirror.active = nil
    if not was then return end
    local secs = nowT() - (m.started_at or nowT())
    local c = m.covers or {}
    if m.revalidating then
        log(string.format("mirror: Refresh rechecked %d pages in %ds, %d requests, %.1f MB", m.done or 0, secs, m.requests or 0, (m.bytes or 0) / 1048576))
        m.revalidating = nil
    else
        m.at, m.lib_version = nowT(), libraryVersion()
        local lists, pages = 0, 0
        for _, l in pairs(m.lists) do lists = lists + 1; pages = pages + Cache.pageCount(l.total) end
        log(string.format("mirror: Full refresh saved for offline in %ds: %d lists (%d pages), %d requests, %.1f MB of lists and books; covers %d new, %d unchanged (304), %d failed, %.1f MB",
            secs, lists, pages, m.requests or 0, (m.bytes or 0) / 1048576, c.ok or 0, c.not_modified or 0, c.failed or 0, (c.bytes or 0) / 1048576))
        if Mirror.manual then OC.note(Mirror.savedText(), 3) end
    end
    m.seen = nil
    Mirror.manual = nil
    OC.saveIndex()
    Wifi.release("mirror")
    -- The saved details now carry every book's file hash: copies that changed are replaced next.
    UIManager:scheduleIn(1, function() if Copies and Copies.tick then pcall(Copies.tick, "full refresh") end end)
end

-- "Saved for offline · <time>" (the last complete Full refresh).
function Mirror.savedText()
    local m = Mirror.state()
    if not m.at then return _("Not saved for offline yet (hold ⟳ for a Full refresh)") end
    return _("Saved for offline · ") .. os.date("%a %H:%M", m.at)
end

-- Online: a run left over resumes; an automatic Full refresh starts when the mirror is older
-- than its TTL or the library changed.
function Mirror.tick(why)
    if Mirror.busy or Mirror.active then return end
    local m = Mirror.state()
    if #m.queue > 0 then
        if not NetworkMgr:isConnected() then return end
        log("mirror: resuming (" .. tostring(why) .. ")")
        return Mirror.pump()
    end
    if Copies and Copies.tick then pcall(Copies.tick, why) end
    if S.mirror_auto == false then return end
    local t = nowT()
    if Mirror.ticked_at and t - Mirror.ticked_at < 60 then return end
    Mirror.ticked_at = t
    local due = Cache.mirrorDue(m, t, S.mirror_ttl_days or Cache.MIRROR_TTL_DAYS, libraryVersion())
    if due and due ~= "never" and NetworkMgr:isConnected() then
        log("mirror: automatic Full refresh:", due == "ttl" and "older than " .. tostring(S.mirror_ttl_days or Cache.MIRROR_TTL_DAYS) .. " days" or "the library changed")
        Mirror.start("auto: " .. due, false)
    end
end

OC.mirrorTick = function(why) return Mirror.tick(why) end

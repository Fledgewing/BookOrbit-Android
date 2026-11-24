-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- The offline mirror (docs/design/write-through-cache.md "Offline mirror"): a Full refresh saves
-- everything reachable from Home without typing, in 100-book pages that answer any page size the
-- plugin asks for (Cache.slice). A Refresh rechecks every saved page; a list whose total moved is
-- re-paged. Every book a saved list names gets its details saved too (so details open offline);
-- covers only for the books on the reader and their neighbours, or for every book with "Save
-- every cover for offline" on (S.mirror_covers).
--
-- Off KOReader's UI thread (docs/design/companion-worker.md, v0.11.3): the whole run happens in a
-- worker, never on the UI thread. The worker owns <orbit-cache>/mirror/: the saved pages and
-- details (<hash>.lua, the cache's entry format, which OC.get reads), its queue (state.lua) and a
-- small status (status.lua) the UI thread reads for the menu line and the progress note. The UI
-- thread only starts a worker run, reads its short summary and holds Wi-Fi. The worker is a forked
-- child (Background.run, at most RUN_JOBS jobs or RUN_S seconds a run; the next run resumes from
-- state.lua), so nothing of the mirror is in the cache's index and nothing the UI thread does
-- grows with the library. v0.11.3 on the M8C froze KOReader ("isn't responding"): the queue
-- (5262 jobs) lived in the index, which the UI thread re-encoded after every saved item.
--
-- The queue: the books on the reader first (seed), then every list page (lists), then every
-- book's details (details), then covers. The total grows only while lists are still being found;
-- once they are all saved it holds still and counts down.
---------------------------------------------------------------------------------------------

Mirror = { NOTE_EVERY_S = 10, COVER_BATCH = 20, RUN_JOBS = 400, RUN_S = 120, STATUS_EVERY_S = 5, STATE_EVERY_S = 30,
    POLL_S = 5, CHANGED_MAX = 50, WRITTEN_MAX = 100 }
local real_remove = os.remove
local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")

-- Section indexes Full refresh saves, in order; each entry's book list follows its index.
Mirror.SECTIONS = { "collections", "smart-scopes", "libraries", "series", "authors" }
Mirror.QUEUES = { "seed", "lists", "details", "covers" }

local function nowT() return OC.now() end
local function clock()
    local oks, socket = pcall(require, "socket")
    if oks and type(socket) == "table" and socket.gettime then return socket.gettime() end
    return os.time()
end

---------------------------------------------------------------- files

function Mirror.dir()
    local d = OC.dir() .. "/mirror"
    if Mirror._made ~= d then
        if lfs_ok then lfs.mkdir(d) end
        Mirror._made = d
    end
    return d
end

function Mirror.file(key) return Mirror.dir() .. "/" .. OC.hash(key) .. ".lua" end

local function load(name)
    local v = Cache.decode(OC.readFile(Mirror.dir() .. "/" .. name) or "")
    return type(v) == "table" and v or nil
end

-- The worker's status as the UI thread sees it: { at, lib_version, op, done, total, left,
-- covers, cover_total, limit_note, revalidating, bytes, cover_keep_n }. Read once, then kept up
-- to date from each run's summary and the progress poll.
function Mirror.status()
    local d = Mirror.dir()
    if not Mirror._status or Mirror._status_dir ~= d then
        Mirror._status = load("status.lua") or {}
        Mirror._status_dir = d
        local legacy = Mirror.legacy()
        if legacy and not Mirror._status.v then
            -- Saved by v0.11.2 or earlier in the cache's index: moved by the first worker run.
            Mirror._status = { at = legacy.at, lib_version = legacy.lib_version, done = legacy.done, total = legacy.total,
                left = #(legacy.queue or {}), limit_note = legacy.limit_note, revalidating = legacy.revalidating }
        end
    end
    return Mirror._status
end

-- In the worker: its live state; on the UI thread: the status.
function Mirror.state()
    if OC.child and Mirror.run_st then return Mirror.run_st end
    return Mirror.status()
end

function Mirror.stopFile() return Mirror.dir() .. "/stop" end

-- The mirror v0.11.2 kept in the index (idx.mirror and entries marked mirror), if any.
function Mirror.legacy()
    local idx = OC.index()
    return type(idx.mirror) == "table" and idx.mirror or nil
end

-- The covers saved by "Save every cover for offline" (cover file names), for the plugin's pruner
-- and the storage count; read when the worker says it changed.
function Mirror.coverKeep()
    local s = Mirror.status()
    local n = s.cover_keep_n or 0
    if Mirror._keep and Mirror._keep_n == n and Mirror._keep_dir == Mirror.dir() then return Mirror._keep end
    Mirror._keep = (n > 0 and load("cover_keep.lua")) or (Mirror.legacy() and Mirror.legacy().cover_keep) or {}
    Mirror._keep_n, Mirror._keep_dir = n, Mirror.dir()
    return Mirror._keep
end

-- The page size a list is mirrored in (nil: Cache.MIRROR_PAGE): the size its first page is saved in.
Mirror.SIZES = { false, 50, 25 }
function Mirror.pageSize(identity, owner, server)
    for _, size in ipairs(Mirror.SIZES) do
        local key = Cache.key({ account = owner, server = server, method = "GET", path = Cache.mirrorPage(identity, 1, size or nil) })
        local f = io.open(Mirror.file(key), "rb")
        if f then f:close(); return size or nil end
    end
    return nil
end

-- A book's saved details (Copies.details), or nil.
function Mirror.detailEntry(client, id)
    local key = Cache.key({ account = OC.owner(client), server = client.server_url, method = "GET", path = Mirror.detailPath(client, id) })
    local e = Cache.decode(OC.readFile(Mirror.file(key)) or "")
    if type(e) == "table" and e.key == key and type(e.body) == "table" then return e end
    return nil
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

---------------------------------------------------------------- requests

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

---------------------------------------------------------------- the worker's queue

function Mirror.newState(req)
    local st = { v = 2, queues = {}, heads = {}, seen = {}, lists = {}, sizes = {}, done = 0, total = 0, bytes = 0,
        requests = 0, skipped = 0, cover_total = 0, cover_keep = {}, covers = { ok = 0, not_modified = 0, failed = 0, bytes = 0 } }
    for _, q in ipairs(Mirror.QUEUES) do st.queues[q], st.heads[q] = {}, 1 end
    st.op, st.reason, st.started_at = req and req.op, req and req.reason, nowT()
    return st
end

local function queueOf(job)
    if job.k == "covers" then return "covers" end
    if job.seed then return "seed" end
    if job.k == "detail" then return "details" end
    return "lists"
end

function Mirror.push(st, job)
    local id = job.k .. "|" .. tostring(job.identity or job.path or job.batch or "") .. "|" .. tostring(job.page or "")
    if st.seen[id] then return false end
    st.seen[id] = true
    table.insert(st.queues[queueOf(job)], job)
    st.total = (st.total or 0) + 1
    return true
end

function Mirror.left(st)
    local n = 0
    for _, q in ipairs(Mirror.QUEUES) do n = n + #st.queues[q] - st.heads[q] + 1 end
    return n
end

function Mirror.peek(st)
    for _, q in ipairs(Mirror.QUEUES) do
        local job = st.queues[q][st.heads[q]]
        if job then return q, job end
    end
end

function Mirror.pop(st, q)
    st.queues[q][st.heads[q]] = false
    st.heads[q] = st.heads[q] + 1
end

-- Drops the jobs done (heads back to 1), before the state is written.
local function compact(st)
    for _, q in ipairs(Mirror.QUEUES) do
        local h = st.heads[q]
        if h > 1 then
            local rest = {}
            for i = h, #st.queues[q] do rest[#rest + 1] = st.queues[q][i] end
            st.queues[q], st.heads[q] = rest, 1
        end
    end
end

function Mirror.addList(st, path, seed)
    local w = Cache.listWindow(path)
    if not w then return end
    Mirror.push(st, { k = "page", identity = w.identity, page = 1, kind = w.kind, section = w.section, seed = seed })
end

-- seed: one of the books whose covers are always saved (on the reader, Continue reading, Up next).
local function addDetail(st, client, id, seed)
    if not id then return end
    Mirror.push(st, { k = "detail", path = Mirror.detailPath(client, id), id = tonumber(id), seed = seed })
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
function Mirror.seed(st, cat)
    local client = cat.client
    local od = Mirror.onDevicePath(cat)
    if od then Mirror.addList(st, od, true) end
    local paths = {}
    for _, meta in pairs(OC.index().entries) do
        if meta.path and not meta.mirror then table.insert(paths, meta.path) end
    end
    table.sort(paths)
    for _, p in ipairs(paths) do Mirror.addList(st, p) end
    for _, s in ipairs(Mirror.SECTIONS) do Mirror.addList(st, Mirror.sectionPath(cat, s)) end
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
    for _, id in ipairs(sorted) do addDetail(st, client, id, true) end
end

-- Refresh's delta: every saved page of every mirrored list, compared with what is saved.
function Mirror.recheck(st)
    st.seen, st.done, st.total, st.requests, st.skipped, st.cover_total = {}, 0, 0, 0, 0, 0
    st.covers = { ok = 0, not_modified = 0, failed = 0, bytes = 0 }
    st.revalidating, st.started_at, st.op = true, nowT(), "revalidate"
    local identities = {}
    for identity in pairs(st.lists) do table.insert(identities, identity) end
    table.sort(identities)
    for _, identity in ipairs(identities) do
        local l = st.lists[identity]
        for n = 1, Cache.pageCount(l.total, l.size) do
            Mirror.push(st, { k = "page", identity = identity, page = n, kind = l.kind, section = l.section, check = true, size = l.size })
        end
    end
    log("mirror: Refresh rechecks", st.total, "saved pages")
end

-- v0.11.2's mirror, kept in the cache's index: its state and its files move to the worker's.
function Mirror.fromLegacy(m, keys)
    local st = Mirror.newState({ op = m.revalidating and "revalidate" or "full", reason = m.reason })
    st.at, st.lib_version, st.done, st.total = m.at, m.lib_version, m.done or 0, 0
    st.revalidating, st.limit_note, st.skipped, st.requests = m.revalidating, m.limit_note, m.skipped or 0, m.requests or 0
    st.cover_keep = m.cover_keep or {}
    for identity, l in pairs(m.lists or {}) do st.lists[identity] = l end
    for k in pairs(m.seen or {}) do st.seen[k] = true end
    for _, job in ipairs(m.queue or {}) do
        job.tries = nil
        table.insert(st.queues[queueOf(job)], job)
    end
    st.total = st.done + Mirror.left(st)
    local moved = 0
    for _, h in ipairs(keys or {}) do
        local from = OC.dir() .. "/" .. h .. ".lua"
        local s = OC.readFile(from)
        if s and os.rename(from, Mirror.dir() .. "/" .. h .. ".lua") then
            st.sizes[h] = #s
            st.bytes = st.bytes + #s
            moved = moved + 1
        end
    end
    log("mirror: moved v0.11.2's offline mirror out of the cache's index:", moved, "saved pages and details,", Mirror.left(st), "left to save")
    return st
end

---------------------------------------------------------------- the worker

-- The progress line in the log, every NOTE_EVERY_S.
function Mirror.progress(st)
    local t = nowT()
    if Mirror.logged_at and t - Mirror.logged_at < Mirror.NOTE_EVERY_S and Mirror.left(st) > 0 then return end
    Mirror.logged_at = t
    local c = st.covers or {}
    log(string.format("mirror: %d/%d saved%s", st.done or 0, st.total or 0, (st.cover_total or 0) > 0
        and string.format(", covers %d/%d", (c.ok or 0) + (c.not_modified or 0) + (c.failed or 0), st.cover_total) or ""))
end

local function shortPath(path) return (tostring(path):gsub("^/koreader/plugin/catalog", "")) end

local function statusOf(st, running)
    return { v = 2, running = running or nil, op = st.op, at = st.at, lib_version = st.lib_version, done = st.done,
        total = st.total, left = Mirror.left(st), skipped = st.skipped, covers = st.covers, cover_total = st.cover_total,
        limit_note = st.limit_note, revalidating = st.revalidating, bytes = st.bytes, cover_keep_n = st.cover_keep_n,
        started_at = st.started_at }
end

function Mirror.writeStatus(st, running)
    OC.writeFile(Mirror.dir() .. "/status.lua", Cache.encode(statusOf(st, running)))
end

function Mirror.saveState(st)
    compact(st)
    OC.writeFile(Mirror.dir() .. "/state.lua", Cache.encode(st))
    if st.keep_dirty then
        local n = 0
        for _ in pairs(st.cover_keep) do n = n + 1 end
        OC.writeFile(Mirror.dir() .. "/cover_keep.lua", Cache.encode(st.cover_keep))
        st.cover_keep_n, st.keep_dirty = (st.cover_keep_n or 0) + 1, nil
    end
end

function Mirror.loadState()
    local st = load("state.lua")
    if not st or st.v ~= 2 then return nil end
    for _, q in ipairs(Mirror.QUEUES) do
        st.queues[q] = st.queues[q] or {}
        st.heads[q] = st.heads[q] or 1
    end
    st.seen, st.lists, st.sizes, st.cover_keep = st.seen or {}, st.lists or {}, st.sizes or {}, st.cover_keep or {}
    st.covers = st.covers or { ok = 0, not_modified = 0, failed = 0, bytes = 0 }
    return st
end

-- Saves an entry in the cache's format (OC.get reads it). -> changed
local function store(st, key, path, body)
    local file = Mirror.file(key)
    local old = Cache.decode(OC.readFile(file) or "")
    local valid = type(old) == "table" and old.key == key and type(old.body) == "table"
    local changed = not valid or Cache.revalidate(old.body, body, 200)
    local t = nowT()
    local e = { key = key, body = body, fetched_at = (valid and not changed) and old.fetched_at or t, validated_at = t, path = path }
    local s = Cache.encode(e)
    if OC.writeFile(file, s) then
        local h = OC.hash(key)
        st.bytes = (st.bytes or 0) - (st.sizes[h] or 0) + #s
        st.sizes[h] = #s
    end
    return changed, valid and old or nil
end

local function drop(st, key)
    local h = OC.hash(key)
    real_remove(Mirror.dir() .. "/" .. h .. ".lua")
    st.bytes = (st.bytes or 0) - (st.sizes[h] or 0)
    st.sizes[h] = nil
end

-- The covers the mirror saves: the seed books' always; every book's only with S.mirror_covers.
local function coversFor(st, cat, items, all)
    if not (cat and Compat.callable(cat.thumbnailPath)) then return end
    local batch = {}
    local function flush()
        if #batch == 0 then return end
        st.cover_batch = (st.cover_batch or 0) + 1
        Mirror.push(st, { k = "covers", batch = batch, path = "covers#" .. st.cover_batch })
        batch = {}
    end
    for _, b in ipairs(items or {}) do
        if type(b) == "table" and b.id and b.hasCover then
            local okp, path = pcall(cat.thumbnailPath, cat, b)
            if okp and path then
                table.insert(batch, { id = b.id, path = path, updatedAt = b.updatedAt })
                st.cover_total = (st.cover_total or 0) + 1
                if all then st.cover_keep[path:match("([^/]+)$") or path] = true; st.keep_dirty = true end
            end
            if #batch >= Mirror.COVER_BATCH then flush() end
        end
    end
    flush()
end

-- In the worker: each cover by ETag (a file with an ETag asks If-None-Match; a missing one is
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
                r.bytes = r.bytes + (lfs_ok and tonumber(lfs.attributes(c.path, "size")) or 0)
                table.insert(r.written, { id = c.id, updatedAt = c.updatedAt })
            else r.failed = r.failed + 1 end
        end
    end
    return r
end

-- The storage limit (Cache.storageRoom): the every-cover pass stops when the mirror's own share
-- (lists, details, its covers) reaches the limit, so it never pushes out covers it saved; the run
-- stops when its lists and details alone fill it. -> true when the job was dropped.
function Mirror.limited(st, q, job, req)
    local limit = req.limit
    if not limit then return false end
    local covers = job.k == "covers"
    if covers and not req.covers_on then return false end -- covers under the normal limit
    local okt, totals = pcall(OC.storageTotals)
    totals = okt and type(totals) == "table" and totals or {}
    totals = { used = totals.used, kept = (totals.kept or 0) + (st.bytes or 0) - (req.bytes0 or 0),
        mirror_cover = (totals.mirror_cover or 0) + ((st.covers.bytes or 0) - (req.cover_bytes0 or 0)) }
    if Cache.storageRoom(totals, limit, covers and "covers" or "lists") then return false end
    local text
    if covers then
        local c = st.covers
        local n = #st.queues.covers - st.heads.covers + 1
        st.queues.covers, st.heads.covers = {}, 1
        st.total = st.total - n
        text = Cache.limitText("covers", (c.ok or 0) + (c.not_modified or 0), st.cover_total)
    else
        text = Cache.limitText("lists", st.done, st.total)
        for _, name in ipairs(Mirror.QUEUES) do st.queues[name], st.heads[name] = {}, 1 end
        st.total = st.done
    end
    st.limit_note = { text = text, at = nowT(), limit = limit }
    log("mirror: " .. text, string.format("(saved for offline %.1f MB)", ((totals.kept or 0) + (totals.mirror_cover or 0)) / 1048576))
    return true
end

-- One saved list page or detail: what it names joins the queue.
function Mirror.landed(st, cat, client, job, path, body, req, out)
    st.requests = (st.requests or 0) + 1
    local key = Cache.key({ account = req.owner, server = client.server_url, method = "GET", path = path })
    local changed, old = store(st, key, path, body)
    if job.k == "detail" then
        -- The next book in each series the reader is in.
        if not job.next_of and type(body.seriesMembers) == "table" then
            for _, s in ipairs(body.seriesMembers) do
                if tonumber(s.id) ~= job.id and s.readStatus ~= "read" and (s.seriesIndex or 0) > (body.seriesIndex or 0) then
                    Mirror.push(st, { k = "detail", path = Mirror.detailPath(client, s.id), id = tonumber(s.id), next_of = job.id, seed = job.seed })
                    break
                end
            end
        end
        if job.seed or req.covers_on then coversFor(st, cat, { body }, req.covers_on) end
        return
    end
    -- A list page.
    local l = st.lists[job.identity]
    local total = tonumber(body.total) or #(body.items or {})
    if job.page == 1 then
        local old_total = l and l.total
        local function dropPage(n, size)
            drop(st, Cache.key({ account = req.owner, server = client.server_url, method = "GET", path = Cache.mirrorPage(job.identity, n, size) }))
        end
        -- Saved before in another page size: those pages go (this list is now paged in job.size).
        if l and l.size ~= job.size then
            for n = 2, Cache.pageCount(l.total, l.size) do dropPage(n, l.size) end
            dropPage(1, l.size)
            old_total = nil
        end
        st.lists[job.identity] = { total = total, kind = job.kind, section = job.section, size = job.size }
        if not job.check or old_total ~= total then
            local fetch, gone = Cache.repage(job.check and old_total or 0, total, job.size)
            for _, n in ipairs(fetch) do
                Mirror.push(st, { k = "page", identity = job.identity, page = n, kind = job.kind, section = job.section, check = job.check, size = job.size, seed = job.seed })
            end
            for _, n in ipairs(gone) do dropPage(n, job.size) end
            if job.check and old_total ~= total then
                log("mirror:", (job.identity:gsub("^/koreader/plugin/catalog", "")), "total", tostring(old_total), "->", total, "; re-paged")
            end
        end
    end
    -- A section's entries open book lists; a books page's covers.
    if job.kind == "section" and cat then
        for _, entry in ipairs(body.items or {}) do
            local okp, p = pcall(Mirror.entryPath, cat, job.section, entry)
            if okp and p then Mirror.addList(st, p) end
        end
    elseif job.kind == "books" and not job.check then
        -- Every book's details (they open offline); covers only with "Save every cover".
        for _, b in ipairs(body.items or {}) do
            if type(b) == "table" and b.id then addDetail(st, client, b.id) end
        end
        if req.covers_on then coversFor(st, cat, body.items, true) end
    end
    if job.check and changed and old and #out.changed < Mirror.CHANGED_MAX then table.insert(out.changed, job.identity) end
end

-- One job, retried in place: 5 s, 10 s, a list's first page in smaller pages, then skipped. The
-- server's own answer (a 404, a 403) is final. -> "transport" when it was skipped for no answer.
function Mirror.doJob(st, q, job, cat, client, req, out)
    if job.k == "covers" then
        local r = Mirror.coverBatch(client, job.batch)
        Mirror.pop(st, q)
        st.done = st.done + 1
        for _, k in ipairs({ "ok", "not_modified", "failed", "bytes" }) do st.covers[k] = (st.covers[k] or 0) + (r[k] or 0) end
        for _, w in ipairs(r.written) do
            if #out.written < Mirror.WRITTEN_MAX then table.insert(out.written, w) else out.written_more = true end
        end
        return
    end
    while true do
        local path = job.k == "page" and Cache.mirrorPage(job.identity, job.page, job.size) or job.path
        local b, e = client:requestBlocking("GET", path)
        if type(b) == "table" then
            Mirror.pop(st, q)
            st.done = st.done + 1
            local okl, err = pcall(Mirror.landed, st, cat, client, job, path, b, req, out)
            if not okl then log("mirror: step failed:", tostring(err)) end
            return
        end
        local why = tostring(e or "no answer")
        job.tries = (job.tries or 0) + 1
        local status = tonumber(e)
        local plan = (status and status < 500) and { skip = true }
            or Cache.mirrorRetry(job.tries, job.k == "page" and (job.size or Cache.MIRROR_PAGE) or nil, job.page)
        if plan.skip then
            log("mirror:", shortPath(path), "skipped after", job.tries, "tries (" .. why .. "); the rest continues")
            st.skipped = (st.skipped or 0) + 1
            Mirror.pop(st, q)
            st.done = st.done + 1
            return not status and "transport" or nil
        end
        local smaller = plan.size and plan.size ~= (job.size or Cache.MIRROR_PAGE)
        if smaller then job.size = plan.size end
        log(string.format("mirror: %s failed (%s), try %d of %d; again in %ds%s", shortPath(path), why, job.tries,
            Cache.MIRROR_TRIES, plan.wait_s, smaller and (", in pages of " .. plan.size) or ""))
        Mirror.sleep(plan.wait_s)
    end
end

function Mirror.sleep(s)
    local oks, socket = pcall(require, "socket")
    if oks and type(socket) == "table" and socket.sleep then socket.sleep(s) end
end

-- The worker's run: in a forked child (never the UI thread). req: { op = "full" | "resume" |
-- "revalidate" | "covers", reason, owner, lib_version, covers_on, limit, legacy, legacy_keys,
-- bytes0, cover_bytes0 }. Returns its summary (Cache.encode) for the UI thread.
function Mirror.work(cat, req)
    local client = cat.client
    local out = { changed = {}, written = {} }
    local st
    if req.legacy then
        st = Mirror.fromLegacy(req.legacy, req.legacy_keys)
        out.migrated = true
    else
        st = Mirror.loadState()
    end
    if req.op == "full" then
        local prev = st
        st = Mirror.newState(req)
        if prev then
            st.at, st.lib_version, st.lists, st.sizes, st.bytes = prev.at, prev.lib_version, prev.lists, prev.sizes, prev.bytes
            st.cover_keep, st.cover_keep_n = prev.cover_keep, prev.cover_keep_n
        end
        Mirror.seed(st, cat)
        log("mirror: Full refresh (" .. tostring(req.reason) .. "):", Mirror.left(st), "lists and books to save first; cache limit",
            math.floor(Cache.MAX_BYTES / 1048576) .. " MB / " .. Cache.MAX_ENTRIES .. " entries outside the mirror")
    elseif not st then
        -- No saved state (a resume or a cover pass before any Full refresh): nothing is marked saved.
        st = Mirror.newState(req)
        st.fresh = true
    end
    if req.op == "revalidate" then
        if Mirror.left(st) > 0 or not st.at then
            out.why = "busy"
            Mirror.run_st = st
            Mirror.writeStatus(st)
            out.status = statusOf(st)
            return Cache.encode(out)
        end
        Mirror.recheck(st)
    elseif req.op == "covers" then
        local n0 = Mirror.left(st)
        for identity, l in pairs(st.lists) do
            if l.kind == "books" then
                for n = 1, Cache.pageCount(l.total, l.size) do
                    local e = Cache.decode(OC.readFile(Mirror.file(Cache.key({ account = req.owner, server = client.server_url, method = "GET",
                        path = Cache.mirrorPage(identity, n, l.size) }))) or "")
                    if type(e) == "table" and type(e.body) == "table" then coversFor(st, cat, e.body.items, true) end
                end
            end
        end
        log("mirror: every cover for offline (" .. tostring(req.reason) .. "):", Mirror.left(st) - n0, "batch(es) queued")
    end
    Mirror.run_st = st
    req.bytes0, req.cover_bytes0 = st.bytes or 0, st.covers.bytes or 0
    local t0, jobs, status_at, state_at, transport = clock(), 0, clock(), clock(), 0
    local why = "budget"
    Mirror.writeStatus(st, true)
    while true do
        local q, job = Mirror.peek(st)
        if not job then why = "finished"; break end
        local f = io.open(Mirror.stopFile(), "rb")
        if f then f:close(); why = "stopped"; break end
        if jobs >= Mirror.RUN_JOBS or clock() - t0 >= Mirror.RUN_S then break end
        jobs = jobs + 1
        if not Mirror.limited(st, q, job, req) then
            if Mirror.doJob(st, q, job, cat, client, req, out) == "transport" then
                transport = transport + 1
                -- Two lists or books in a row with no answer at all: the network, most likely.
                if transport >= 2 then why = "no answer"; break end
            else
                transport = 0
            end
            Mirror.progress(st)
        end
        if clock() - status_at >= Mirror.STATUS_EVERY_S then Mirror.writeStatus(st, true); status_at = clock() end
        if clock() - state_at >= Mirror.STATE_EVERY_S then Mirror.saveState(st); state_at = clock() end
    end
    if why == "finished" then
        local secs = nowT() - (st.started_at or nowT())
        local c = st.covers or {}
        if st.revalidating then
            log(string.format("mirror: Refresh rechecked %d pages in %ds, %d requests, %.1f MB", st.done or 0, secs, st.requests or 0, (st.bytes or 0) / 1048576))
            st.revalidating = nil
            out.revalidated = true
        elseif not st.fresh then
            st.at, st.lib_version = nowT(), req.lib_version
            local lists, pages = 0, 0
            for _, l in pairs(st.lists) do lists = lists + 1; pages = pages + Cache.pageCount(l.total, l.size) end
            log(string.format("mirror: Full refresh saved for offline in %ds: %d lists (%d pages), %d requests, %d skipped, %.1f MB of lists and books; covers %d new, %d unchanged (304), %d failed, %.1f MB",
                secs, lists, pages, st.requests or 0, st.skipped or 0, (st.bytes or 0) / 1048576, c.ok or 0, c.not_modified or 0, c.failed or 0, (c.bytes or 0) / 1048576))
            out.saved = true
        end
        st.seen, st.fresh = {}, nil
    end
    Mirror.saveState(st)
    Mirror.writeStatus(st)
    out.why, out.jobs = why, jobs
    out.status = statusOf(st)
    out.bytes_delta = (st.bytes or 0) - req.bytes0
    out.cover_bytes_delta = (st.covers.bytes or 0) - req.cover_bytes0
    return Cache.encode(out)
end

---------------------------------------------------------------- the UI thread

-- A Full refresh saving now (not a Refresh's recheck): a second press keeps it.
function Mirror.fullRunning()
    local s = Mirror.status()
    return (Mirror.active == true or Mirror.busy == true) and not s.revalidating and (s.left or 0) > 0
end

function Mirror.progressText()
    local s = Mirror.status()
    local t = string.format(_("Full refresh · saving for offline %d/%d"), s.done or 0, s.total or s.done or 0)
    if (s.cover_total or 0) > 0 then
        local c = s.covers or {}
        t = t .. string.format(_(" · covers %d/%d"), (c.ok or 0) + (c.not_modified or 0) + (c.failed or 0), s.cover_total)
    end
    return t
end

-- A Full refresh pressed while one is saving: keep that run and show where it is.
function Mirror.showProgress(why)
    local s = Mirror.status()
    Mirror.manual = true
    Mirror.noted_at = nil
    log("mirror: Full refresh already running (" .. tostring(why) .. "); kept,", s.done or 0, "of", s.total or 0, "saved")
    Mirror.note(Mirror.progressText())
end

function Mirror.note(text)
    if not Mirror.manual then return end
    local t = nowT()
    if Mirror.noted_at and t - Mirror.noted_at < Mirror.NOTE_EVERY_S then return end
    Mirror.noted_at = t
    OC.note(text, 2)
end

-- While a run is on: the progress note from the worker's status file, and a network that went.
function Mirror.poll()
    if Mirror.polling then return end
    Mirror.polling = true
    local function tick()
        if not Mirror.active then Mirror.polling = nil; return end
        if not NetworkMgr:isConnected() then
            Mirror.polling = nil
            return Mirror.stop("offline")
        end
        local s = load("status.lua")
        if s and s.running then Mirror._status = s end
        Mirror.note(Mirror.progressText())
        UIManager:scheduleIn(Mirror.POLL_S, tick)
    end
    UIManager:scheduleIn(Mirror.POLL_S, tick)
end

-- Starts a worker run (op: "full", "resume", "revalidate", "covers"); one at a time.
function Mirror.launch(op, reason)
    if Mirror.busy then
        if op ~= "resume" then Mirror.next = { op = op, reason = reason } end
        return true
    end
    local cat = Mirror.catalog()
    local client = cat and cat.client
    if not client then Mirror.stop("no BookOrbit catalog"); return false end
    if not NetworkMgr:isConnected() then Mirror.stop("offline"); return false end
    local s = Mirror.status()
    if not Mirror.active then
        Mirror.active = true
        Wifi.acquire("mirror")
        log("mirror: running;", op == "resume" and ((s.left or 0) .. " to go") or op, "; Wi-Fi held until it ends")
    end
    if op == "full" then
        Mirror._status = { v = 2, op = "full", at = s.at, lib_version = s.lib_version, done = 0, total = 0, left = 1,
            bytes = s.bytes, cover_keep_n = s.cover_keep_n }
    end
    Mirror.busy = true
    real_remove(Mirror.stopFile())
    local req = { op = op, reason = reason, owner = OC.owner(client), lib_version = libraryVersion(),
        covers_on = S.mirror_covers == true, limit = OC.limitBytes() }
    local legacy = Mirror.legacy()
    if legacy then
        req.legacy, req.legacy_keys = legacy, {}
        for key, meta in pairs(OC.index().entries) do
            if meta.mirror then table.insert(req.legacy_keys, OC.hash(key)) end
        end
    end
    Mirror.poll()
    Background.run("mirror", function()
        OC.child = true
        local okw, r = pcall(Mirror.work, cat, req)
        OC.child, Mirror.run_st = nil, nil
        if not okw then error(r, 0) end
        return r
    -- RUN_S, then the job in hand: up to 3 tries of a request (socketutil LARGE_TOTAL_TIMEOUT) and
    -- the 5 s and 10 s waits.
    end, Mirror.RUN_S + 3 * 60 + 15 + 60, function(out, berr) Mirror.ran(cat, req, out, berr) end)
    return true
end

-- A worker run's summary, on the UI thread.
function Mirror.ran(cat, req, out, berr)
    Mirror.busy = nil
    local r = Cache.decode(out or "")
    if type(r) ~= "table" or type(r.status) ~= "table" then
        log("mirror: the run failed:", tostring(berr or out))
        Mirror._status = nil
        -- The worker saves its place every STATE_EVERY_S: a run that died resumes from there.
        Mirror.stop("the run failed")
        UIManager:scheduleIn(60, function() Mirror.tick("retry") end)
        return
    end
    Mirror._status = r.status
    if r.migrated then
        -- v0.11.2's mirror is out of the index now: the UI thread's index saves shrink with it.
        local idx = OC.index()
        idx.mirror = nil
        for key, meta in pairs(idx.entries) do
            if meta.mirror then idx.entries[key] = nil; OC.memo[key] = nil end
        end
        OC.storage = nil
        OC.saveIndex()
    end
    if (r.bytes_delta or 0) ~= 0 then pcall(OC.storageAdd, r.bytes_delta, "kept") end
    if (r.cover_bytes_delta or 0) ~= 0 then pcall(OC.storageAdd, r.cover_bytes_delta, S.mirror_covers and "mirror_cover" or "cover") end
    if #(r.written or {}) > 0 and cat then
        if r.written_more and Compat.callable(cat.resetThumbnailMemo) then pcall(cat.resetThumbnailMemo, cat)
        elseif Compat.callable(cat.invalidateThumbnail) then
            for _, w in ipairs(r.written) do pcall(cat.invalidateThumbnail, cat, { id = w.id, updatedAt = w.updatedAt, hasCover = true }, true) end
        end
    end
    for _, identity in ipairs(r.changed or {}) do Mirror.changedOnScreen(identity) end
    local s = r.status
    if r.why ~= "busy" then
        log(string.format("mirror: run done (%s): %d jobs; %d/%d saved, %d left", r.why, r.jobs or 0, s.done or 0, s.total or 0, s.left or 0))
    end
    Mirror.note(Mirror.progressText())
    if s.limit_note and Mirror.manual and s.limit_note.at and nowT() - s.limit_note.at < 60 then
        Mirror.noted_at = nil
        OC.note(s.limit_note.text, 5)
        Mirror.noted_at = nowT() + 5 -- the stop note stays up past the next progress note
    end
    local nxt = Mirror.next
    Mirror.next = nil
    if nxt then return Mirror.launch(nxt.op, nxt.reason) end
    if r.why == "finished" or r.why == "busy" then return Mirror.finish(r) end
    if r.why == "stopped" then return end
    if not NetworkMgr:isConnected() then return Mirror.stop("offline") end
    if r.why == "no answer" then
        -- Connected, but nothing answers: try again in a minute (the paused run keeps its place).
        Mirror.stop("no answer")
        UIManager:scheduleIn(60, function() Mirror.tick("retry") end)
        return
    end
    UIManager:scheduleIn(0.5, function() if Mirror.active and not Mirror.busy then Mirror.launch("resume") end end)
end

function Mirror.running() return Mirror.active == true end

function Mirror.stop(why)
    if Mirror.busy then OC.writeFile(Mirror.stopFile(), "stop") end
    if not Mirror.active then return end
    Mirror.active = nil
    log("mirror: paused (" .. why .. "),", Mirror.status().left or 0, "left; it resumes at the next network up, wake or Home")
    Wifi.release("mirror")
end

function Mirror.finish(r)
    local was = Mirror.active
    Mirror.active = nil
    if not was then return end
    if r and r.saved and Mirror.manual and not Mirror.status().limit_note then OC.note(Mirror.savedText(), 3) end
    Mirror.manual = nil
    Wifi.release("mirror")
    -- The saved details now carry every book's file hash: copies that changed are replaced next.
    if r and r.saved then
        UIManager:scheduleIn(1, function() if Copies and Copies.tick then pcall(Copies.tick, "full refresh") end end)
    end
end

function Mirror.start(reason, manual)
    local cat = Mirror.catalog()
    if not (cat and cat.client) then
        log("mirror: no BookOrbit catalog yet; the Full refresh waits until BookOrbit opens")
        return false
    end
    if Mirror.fullRunning() then
        if manual then Mirror.showProgress(reason) end
        return true
    end
    Mirror.manual = manual
    if Mirror.busy then real_remove(Mirror.stopFile()); OC.writeFile(Mirror.stopFile(), "stop") end
    return Mirror.launch("full", reason)
end

-- Refresh's delta: every saved page of every mirrored list, in the worker.
function Mirror.revalidate(reason)
    local s = Mirror.status()
    if not s.at or (s.left or 0) > 0 or Mirror.busy then return false end
    return Mirror.launch("revalidate", reason)
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

-- "Saved for offline · <time>" (the last complete Full refresh).
function Mirror.savedText()
    local s = Mirror.status()
    if not s.at then return _("Not saved for offline yet (hold ⟳ for a Full refresh)") end
    return _("Saved for offline · ") .. os.date("%a %H:%M", s.at) .. (s.limit_note and _(" · storage limit reached") or "")
end

-- Online: a run left over resumes; an automatic Full refresh starts when the mirror is older
-- than its TTL or the library changed; with nothing to save, changed copies are replaced.
function Mirror.tick(why)
    if Mirror.busy or Mirror.active then return end
    local s = Mirror.status()
    if (s.left or 0) > 0 then
        if not NetworkMgr:isConnected() then return end
        log("mirror: resuming (" .. tostring(why) .. "),", s.left, "left")
        return Mirror.launch("resume", why)
    end
    if Copies and Copies.tick then pcall(Copies.tick, why) end
    if S.mirror_auto == false then return end
    local t = nowT()
    if Mirror.ticked_at and t - Mirror.ticked_at < 60 then return end
    Mirror.ticked_at = t
    local due = Cache.mirrorDue(s, t, S.mirror_ttl_days or Cache.MIRROR_TTL_DAYS, libraryVersion())
    -- Stopped by the storage limit: no automatic run again until the limit changes.
    if due and s.limit_note and s.limit_note.limit == OC.limitBytes() and due ~= "library" then due = nil end
    -- A new automatic run never starts in a book (it would hold Wi-Fi while reading); a paused one
    -- resumes above.
    if due and due ~= "never" and NetworkMgr:isConnected() and not reading() then
        log("mirror: automatic Full refresh:", due == "ttl" and "older than " .. tostring(S.mirror_ttl_days or Cache.MIRROR_TTL_DAYS) .. " days" or "the library changed")
        Mirror.start("auto: " .. due, false)
    end
end

OC.mirrorTick = function(why) return Mirror.tick(why) end

-- The moments a paused run resumes and changed copies are looked for: the network coming up, a
-- wake, BookOrbit Home opening. (Catalog reads mostly run in the plugin's child process, where
-- nothing may start, so reads alone never resumed it: v0.11.1 on the M8C.)
function Mirror.kick(why)
    -- The sleep screen's pool refreshes at the same moments (docs/design/lock-screen.md R3).
    if Sleep and Sleep.kick then Sleep.kick(why) end
    UIManager:scheduleIn(1, function()
        local okt, err = pcall(Mirror.tick, why)
        if not okt then log("mirror: tick failed:", tostring(err)) end
    end)
end

-- "Save every cover for offline" turned on: the covers of every list the mirror saved, queued by
-- the worker.
function Mirror.coverPass(why)
    if not Mirror.catalog() then return 0 end
    log("mirror: every cover for offline (" .. tostring(why) .. "): queued in the worker")
    Mirror.launch("covers", why)
    return 1
end

-- The plugin keeps its newest 600 cover files (bookorbit_catalog_thumbnails.lua:480-555
-- pruneThumbnailCache). With "Save every cover for offline" on, the mirror's covers are outside
-- that cap: its pruner's removals of them are skipped (it counts them removed and goes on). Off,
-- nothing is skipped, so they go back under the cap; nothing is deleted when it is turned off.
function Mirror.guardPrune(Catalog)
    if not Compat.callable(Catalog.pruneThumbnailCache) then return end
    wrap(Catalog, "pruneThumbnailCache", function(stock) return function(self, ...)
        local keep = S.mirror_covers and Mirror.coverKeep()
        if not keep then return stock(self, ...) end
        os.remove = function(path)
            local name = tostring(path):match("([^/]+)$")
            if name and keep[name] then return true end
            return real_remove(path)
        end
        local okp, err = pcall(stock, self, ...)
        os.remove = real_remove
        if not okp then error(err, 0) end
    end end, "cache")
end

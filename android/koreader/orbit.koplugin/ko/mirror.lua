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
-- The Orbit Companion does the run (docs/design/companion-worker.md): its cache worker
-- (CacheWorker.kt) asks BookOrbit, saves the pages, details and covers into <orbit-cache>/mirror/
-- and writes a small status. This file only decides when a run starts, writes its plan
-- (mirror/plan.lua: what to save; no login in it), sends the MIRROR broadcast with the login,
-- shows the run's state from mirror/status.lua and applies its summary (mirror/summary.lua). No
-- request, parse of a reply or entry write of the mirror happens in KOReader: v0.11.3 on the M8C
-- froze ("isn't responding") with the run on KOReader's side. The companion is required and ships
-- with the plugin: no run without it (Companion.workerProblem), and no fallback.
---------------------------------------------------------------------------------------------

Mirror = { POLL_S = 3, DEAD_S = 90, SENTINEL = "987654321" }
local real_remove = os.remove
local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")

-- Section indexes Full refresh saves, in order; each entry's book list follows its index.
Mirror.SECTIONS = { "collections", "smart-scopes", "libraries", "series", "authors" }

local function nowT() return OC.now() end

---------------------------------------------------------------- files

function Mirror.dir()
    local d = OC.dir() .. "/mirror"
    if Mirror._made ~= d then
        if lfs_ok then lfs.mkdir(d) end
        Mirror._made = d
    end
    return d
end

local function load(name)
    local v = Cache.decode(OC.readFile(Mirror.dir() .. "/" .. name) or "")
    return type(v) == "table" and v or nil
end

-- The run's state as the companion wrote it: { at, lib_version, op, done, total, left, covers,
-- cover_total, limit_note, revalidating, bytes, cover_keep_n, running, run, beat }. Read once,
-- then kept up to date by the poll and each run's summary.
function Mirror.status()
    local d = Mirror.dir()
    if not Mirror._status or Mirror._status_dir ~= d then
        Mirror._status = load("status.lua") or {}
        Mirror._status_dir = d
    end
    return Mirror._status
end

function Mirror.stopFile() return Mirror.dir() .. "/stop" end

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

local function libraryVersion()
    local sm = package.loaded["bookorbit_state_manager"]
    if type(sm) ~= "table" or type(sm.state) ~= "function" then return nil end
    local okv, v = pcall(function() local st = sm.state(); return st and st.global and st.global.libraryVersion end)
    return okv and v or nil
end
Mirror.libraryVersion = libraryVersion

---------------------------------------------------------------- the plan

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
    local variant = OC.state().detail_variant
    return client:query("/koreader/plugin/catalog/books/" .. tostring(id), { deviceId = client.device_id, variant = variant })
end

-- The plan the companion runs (CacheWorker.Plan): the plugin's own requests as templates (the
-- sentinel id stands for each entry's id), so the companion builds the same paths and keys the
-- plugin reads. Small: the lists the plugin has browsed are in the database, which the companion
-- reads itself. all_books: the library's every book, whose total fixes the Full refresh's work.
function Mirror.plan(cat, op, reason)
    local client = cat.client
    local SENT = Mirror.SENTINEL
    local templates = {}
    for _, section in ipairs(Mirror.SECTIONS) do
        local t = {}
        local okp, p = pcall(Mirror.entryPath, cat, section, section == "series" and { seriesId = tonumber(SENT), id = "x" } or { id = SENT })
        if okp and p then t.path = p end
        if section == "series" then
            local okn, pn = pcall(Mirror.entryPath, cat, section, { id = SENT })
            if okn and pn then t.series_name_path = pn end
        end
        templates[section] = t
    end
    local sections = {}
    for _, s in ipairs(Mirror.SECTIONS) do
        local okp, p = pcall(Mirror.sectionPath, cat, s)
        if okp and p then table.insert(sections, p) end
    end
    local seed_details = {}
    for id in pairs(type(cat.on_device) == "table" and cat.on_device or {}) do
        if tonumber(id) then table.insert(seed_details, tonumber(id)) end
    end
    table.sort(seed_details)
    local cover_dir
    if Compat.callable(cat.thumbnailPath) then
        local okc, p = pcall(cat.thumbnailPath, cat, { id = 1, updatedAt = "1", hasCover = true })
        cover_dir = okc and type(p) == "string" and p:match("^(.*)/[^/]+$") or nil
    end
    local cols, rows = 3, 3
    if Compat.callable(cat.effectiveGridDimensions) then
        local okg, c, r = pcall(cat.effectiveGridDimensions, cat)
        if okg then cols, rows = tonumber(c) or cols, tonumber(r) or rows end
    end
    local okd, device = pcall(require, "device")
    local screen = okd and device.screen
    local width = screen and screen:getWidth() or 1080
    local height = screen and screen:getHeight() or 1440
    Mirror.seq = (Mirror.seq or 0) + 1
    local plan = { run = string.format("%d-%d", nowT(), Mirror.seq), op = op, reason = reason, owner = OC.owner(client),
        manual = Mirror.manual == true, lib_version = libraryVersion(), sentinel = SENT, templates = templates, detail_template = Mirror.detailPath(client, SENT),
        sections = sections, seed_lists = { Mirror.onDevicePath(cat) }, seed_details = seed_details,
        all_books = client:query("/koreader/plugin/catalog/books", { sort = "title", order = "asc" }),
        cover_width = math.floor(width / math.max(1, cols)), cover_height = math.floor(height / math.max(1, rows)),
        cover_dir = cover_dir, covers_on = S.mirror_covers == true, limit = OC.limitBytes() }
    return plan
end

---------------------------------------------------------------- the run

-- A Full refresh saving now (not a Refresh's recheck): a second press keeps it.
function Mirror.fullRunning()
    local s = Mirror.status()
    return Mirror.active == true and Mirror.busy == true
        and (Mirror.op == "full" or Mirror.op == "resume" and s.op == "full")
end

-- A Full refresh pressed while one is saving: keep that run and show where it is.
function Mirror.showProgress(why)
    local s = Mirror.status()
    Mirror.manual = true
    log("mirror: Full refresh already running (" .. tostring(why) .. "); kept,", s.done or 0, "of", s.total or 0, "saved")
    if not Badge.running then Badge.start(false, s) end
    Badge.expand()
end

-- While a run is on: its status, the indicator, a network that went, a companion that went.
function Mirror.poll()
    if Mirror.polling then return end
    Mirror.polling = true
    local function tick()
        if not Mirror.busy then Mirror.polling = nil; return end
        local sum = load("summary.lua")
        if sum and sum.run == Mirror.run_id then
            Mirror.polling = nil
            return Mirror.ran(sum)
        end
        if not NetworkMgr:isConnected() then OC.writeFile(Mirror.stopFile(), "stop") end
        local s = load("status.lua")
        if s and s.run == Mirror.run_id then
            Mirror._status = s
            Mirror.seen_beat = nowT()
        elseif nowT() - (Mirror.sent_at or 0) >= Mirror.DEAD_S then
            Mirror.polling = nil
            return Mirror.ran(nil)
        end
        if s and s.run == Mirror.run_id and nowT() - (s.beat or 0) >= Mirror.DEAD_S and nowT() - (Mirror.seen_beat or 0) < Mirror.DEAD_S then
            -- The status stopped moving: the companion was stopped mid-run.
            Mirror.polling = nil
            return Mirror.ran(nil)
        end
        Badge.update(Mirror._status)
        UIManager:scheduleIn(Mirror.POLL_S, tick)
    end
    UIManager:scheduleIn(Mirror.POLL_S, tick)
end

-- Starts a companion run (op: "full", "resume", "revalidate", "covers"); one at a time.
function Mirror.launch(op, reason)
    if Mirror.busy then
        if op ~= "resume" then Mirror.next = { op = op, reason = reason } end
        return true
    end
    local problem = Companion.workerProblem()
    if problem then
        if Mirror.blocked ~= problem then log("mirror: not started:", problem) end
        Mirror.blocked = problem
        Mirror.notices = nil
        if Mirror.manual then OC.note(problem, 4) end
        Mirror.manual = nil
        return false
    end
    Mirror.blocked = nil
    Mirror.op = op
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
        Mirror.ticked_at = nowT()
        Mirror._status = { v = 4, op = "full", at = s.at, lib_version = s.lib_version, done = 0, total = 0, left = 1, pct = 0 }
    end
    local plan = Mirror.plan(cat, op, reason)
    real_remove(Mirror.stopFile())
    if not OC.writeFile(Mirror.dir() .. "/plan.lua", Cache.encode(plan)) then
        Mirror.stop("the plan could not be written")
        return false
    end
    Mirror.busy, Mirror.run_id, Mirror.sent_at, Mirror.seen_beat = true, plan.run, nowT(), nil
    -- The login goes in the caller-checked call only (to the verified companion): never in a file or the log.
    Companion.send(Companion.ACTION.MIRROR, { reason = op .. ": " .. tostring(reason), server = client.server_url,
        user = client.username, userkey = client.userkey })
    -- The progress: a Full refresh (or its run resumed) shows the badge; a Refresh's recheck doesn't.
    if Mirror.manual and op == "full" then Badge.start(true, Mirror._status)
    elseif Mirror.manual and op == "resume" and Mirror.status().op == "full" and not Badge.running then Badge.start(false, Mirror.status()) end
    Mirror.poll()
    return true
end

-- A run's summary (nil: the companion stopped answering).
function Mirror.ran(r)
    Mirror.busy, Mirror.run_id = nil, nil
    if type(r) ~= "table" or type(r.status) ~= "table" then
        log("mirror: the companion's run stopped without a summary")
        Mirror._status = nil
        Mirror.stop("the run stopped")
        UIManager:scheduleIn(60, function() Mirror.tick("retry") end)
        return
    end
    Mirror._status = r.status
    -- Replacements and lazy shrinkage are not additive bytes. Ask the worker for live totals.
    pcall(OC.storageCount, "after refresh")
    local cat = Mirror.catalog()
    if #(r.written or {}) > 0 and cat then
        if r.written_more and Compat.callable(cat.resetThumbnailMemo) then pcall(cat.resetThumbnailMemo, cat)
        elseif Compat.callable(cat.invalidateThumbnail) then
            for _, w in ipairs(r.written) do pcall(cat.invalidateThumbnail, cat, { id = w.id, updatedAt = w.updatedAt, hasCover = true }, true) end
        end
    end
    for _, identity in ipairs(r.changed or {}) do Mirror.changedOnScreen(identity) end
    local s = r.status
    if r.why ~= "busy" then
        log(string.format("mirror: run done (%s): %d jobs; %d/%d saved, %d left", tostring(r.why), r.jobs or 0, s.done or 0, s.total or 0, s.left or 0))
    end
    local nxt = Mirror.next
    Mirror.next = nil
    if nxt then return Mirror.launch(nxt.op, nxt.reason) end
    if s.limit_note and s.limit_note.at and nowT() - s.limit_note.at < 60 then
        -- The storage limit stopped it: the badge says so (no other note).
        Badge.finish(s.limit_note.text, s)
        Mirror.manual = nil
    end
    if r.why == "finished" or r.why == "busy" then return Mirror.finish(r) end
    if r.why == "stopped" then
        if not NetworkMgr:isConnected() then return Mirror.stop("offline") end
        return Mirror.stop("stopped")
    end
    if not NetworkMgr:isConnected() then return Mirror.stop("offline") end
    -- Connected, but nothing answers: try again in a minute (the paused run keeps its place).
    Mirror.stop(tostring(r.why))
    UIManager:scheduleIn(60, function() Mirror.tick("retry") end)
end

function Mirror.running() return Mirror.active == true end

function Mirror.stop(why)
    Mirror.notices = nil
    if Mirror.busy then OC.writeFile(Mirror.stopFile(), "stop") end
    Badge.finish(_("Paused · it goes on when BookOrbit answers"))
    if not Mirror.active then return end
    Mirror.active = nil
    log("mirror: paused (" .. why .. "),", Mirror.status().left or 0, "left; it resumes at the next network up, wake or Home")
    Wifi.release("mirror")
end

function Mirror.finish(r)
    local was = Mirror.active
    Mirror.active = nil
    if r and r.why == "finished" then Badge.finish(nil, r.status)
    elseif Badge.running then Badge.running = nil; Badge.close() end
    if not was then return end
    Mirror.manual = nil
    Mirror.notices = nil
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
    if Mirror.busy then OC.writeFile(Mirror.stopFile(), "stop") end
    return Mirror.launch("full", reason)
end

-- Refresh's delta: every saved page of every mirrored list, rechecked by the companion.
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

-- "Saved for offline · <time>" (the last complete Full refresh), or why none can run.
function Mirror.savedText()
    local problem = Companion.workerProblem()
    if problem then return problem end
    local s = Mirror.status()
    if not s.at then return _("Not saved for offline yet (hold ⟳ for a Full refresh)") end
    return _("Saved for offline · ") .. os.date("%a %H:%M", s.at) .. (s.limit_note and _(" · storage limit reached") or "")
end

-- Online: a run left over resumes; otherwise a silent incremental probe checks changed books.
-- Full refresh is manual only and cached rows never expire.
function Mirror.tick(why)
    if Mirror.busy or Mirror.active then return end
    local s = Mirror.status()
    if (s.left or 0) > 0 then
        if not NetworkMgr:isConnected() then return end
        log("mirror: resuming (" .. tostring(why) .. "),", s.left, "left")
        return Mirror.launch("resume", why)
    end
    if Copies and Copies.tick then pcall(Copies.tick, why) end
    -- Cache rows never expire. Only an explicit action starts a Full refresh.
    -- Opportunistic checks use an already connected network and never acquire it.
    if why == "read" or not s.at or not NetworkMgr:isConnected() or reading() then return end
    local t = nowT()
    if Mirror.ticked_at and t - Mirror.ticked_at < 900 then return end
    Mirror.ticked_at = t
    Mirror.launch("incremental", why)
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
-- the companion.
function Mirror.coverPass(why)
    if not Mirror.catalog() then return 0 end
    log("mirror: every cover for offline (" .. tostring(why) .. "): queued in the companion")
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
        local client = S.mirror_covers and OC.client()
        if not client then return stock(self, ...) end
        local owner = OC.owner(client)
        os.remove = function(path)
            local name = tostring(path):match("([^/]+)$")
            if name and Store.coverKept(owner, name) then return true end
            return real_remove(path)
        end
        local okp, err = pcall(stock, self, ...)
        os.remove = real_remove
        if not okp then error(err, 0) end
    end end, "cache")
end

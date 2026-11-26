-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
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

Mirror = { POLL_S = 3, SENTINEL = "987654321" }
local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")

-- Section indexes Full refresh saves, in order; each entry's book list follows its index.
local function catalogInventory()
    for _, path in ipairs({ SOURCE_DIR .. "/catalog_sections.json", SOURCE_DIR .. "/../../../shared/fixtures/catalog/sections.json" }) do
        local f = io.open(path, "rb")
        if f then
            local text = f:read("*a"); f:close()
            local value = SettingsSync.decodeJson(text)
            if value then return value end
        end
    end
    error("BookSync catalog_sections.json missing or unreadable")
end
Mirror.INVENTORY = catalogInventory()
Mirror.SECTIONS = Mirror.INVENTORY.sections

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
        if next(Mirror._status) and Mirror._status.engine ~= "bulk" then
            -- Crawl-era progress is neither resumable bulk work nor live storage.
            os.remove(d .. "/status.lua")
            os.remove(d .. "/summary.lua")
            Mirror._status = {}
            log("mirror: retired legacy crawl progress")
        end
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
function Mirror.plan(cat, op, reason, step)
    step = step or function() end
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
        step()
    end
    local sections = {}
    for _, s in ipairs(Mirror.SECTIONS) do
        local okp, p = pcall(Mirror.sectionPath, cat, s)
        if okp and p then table.insert(sections, p) end
        step()
    end
    local seed_details = {}
    for id in pairs(type(cat.on_device) == "table" and cat.on_device or {}) do
        if tonumber(id) then table.insert(seed_details, tonumber(id)) end
        if #seed_details % 50 == 0 then step() end
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
        catalog = Mirror.INVENTORY,
        all_books = client:query("/koreader/plugin/catalog/books", { sort = "title", order = "asc" }),
        cover_width = math.floor(width / math.max(1, cols)), cover_height = math.floor(height / math.max(1, rows)),
        cover_dir = cover_dir, covers_on = S.mirror_covers == true, limit = OC.limitBytes() }
    plan.dynamic_lists, plan.browse_lists = {}, {}
    local sources = {}
    for _, rows in ipairs({ Mirror.INVENTORY.home_books, Mirror.INVENTORY.root_books }) do
        for _, params in pairs(rows) do table.insert(sources, params) end
    end
    local seen = {}
    for _, params in ipairs(sources) do
        local q = {}
        for k, v in pairs(params) do q[k] = v end
        q.order = Compat.callable(cat.effectiveOrder) and cat:effectiveOrder(q) or q.order
        if Compat.callable(cat.listDecorateBookQuery) then cat:listDecorateBookQuery(q) end
        local path = client:query("/koreader/plugin/catalog/books", q)
        if not seen[path] then
            seen[path] = true
            table.insert(plan.browse_lists, path)
            if q.readStatus or q.sort == "recently_added" or q.sort == "recently_read" then
                table.insert(plan.dynamic_lists, path)
            end
        end
    end
    step()
    plan.entries = {}
    for _, path in ipairs(Mirror.INVENTORY.entries) do
        table.insert(plan.entries, "/koreader/plugin/catalog/" .. path)
    end
    for _, kind in ipairs(Mirror.INVENTORY.dashboard_sections) do
        table.insert(plan.entries, "/koreader/plugin/catalog/dashboard/sections/" .. kind)
    end
    return plan
end

---------------------------------------------------------------- the run

-- A Full refresh saving now (not a Refresh's recheck): a second press keeps it.
function Mirror.fullRunning()
    local s = Mirror.status()
    return Mirror.active == true and Mirror.busy == true
        and (Mirror.op == "full" or Mirror.op == "resume" and s.op == "full" and s.engine == "bulk"
            or Mirror.manual and s.engine == "bulk")
end

-- A Full refresh pressed while one is saving: keep that run and show where it is.
function Mirror.showProgress(why)
    local s = Mirror.status()
    Mirror.manual = true
    Mirror.no_ack, Mirror.sent_at, Mirror.queried_at = nil, nowT(), nil
    log("mirror: Full refresh already running (" .. tostring(why) .. "); kept,", s.done or 0, "of", s.total or 0, "saved")
    if not Badge.running then Badge.start(true, s) else Badge.update(s) end
    Badge.expand()
end

-- While a run is on: its status, the indicator, a network that went, a companion that went.
function Mirror.poll()
    if Mirror.polling then return end
    Mirror.polling = true
    local run_id = Mirror.run_id
    local function tick()
        if Mirror.run_id ~= run_id then return end
        if not Mirror.busy then Mirror.polling = nil; return end
        local sum = load("summary.lua")
        if sum and sum.run == Mirror.run_id then
            Mirror.polling = nil
            return Mirror.ran(sum)
        end
        if not NetworkMgr:isConnected() then OC.writeFile(Mirror.stopFile(), "stop") end
        local state = load("run.lua")
        -- Admission can attach us to a run already queued by an earlier plugin process.
        if state and state.query_for == Mirror.run_id and state.state ~= "stopped" then
            Mirror.run_id, run_id = state.run, state.run
        end
        local s = load("status.lua")
        if s and s.run == Mirror.run_id then Mirror._status = s end
        if state and state.run == Mirror.run_id then
            Mirror.acknowledged = true
            if state.state == "stopped" then
                -- The summary can arrive between our reads above; check once more.
                local ended = load("summary.lua")
                Mirror.polling = nil
                return Mirror.ran(ended and ended.run == Mirror.run_id and ended or nil)
            end
            if state.state == "queued" or state.state == "started" then
                local current = {}
                for k, v in pairs(Mirror._status or {}) do current[k] = v end
                for k, v in pairs(state) do current[k] = v end
                Mirror._status = current
            end
        end
        if not Mirror.acknowledged and not Mirror.no_ack and nowT() - (Mirror.sent_at or nowT()) >= 6 then
            Mirror.no_ack = true
            if Mirror.manual then orbitNote(_("BookSync's companion isn't responding · Retry"), 6, true) end
        end
        -- Back off unanswered liveness queries; local status still polls every three seconds.
        if not Mirror.queried_at or nowT() - Mirror.queried_at >= (Mirror.query_wait or Mirror.POLL_S) then
            Mirror.queried_at = nowT()
            Mirror.query_wait = math.min(60, (Mirror.query_wait or Mirror.POLL_S) * 2)
            Companion.send(Companion.ACTION.MIRROR, { query_run = Mirror.run_id })
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
        Mirror._status = { v = 4, engine = "bulk", op = "full", done = 0, total = 100, left = 100, pct = 0, beat = nowT() }
    end
    Mirror.busy = true
    local prepare = {}
    Mirror.preparing = prepare
    local co = coroutine.create(function()
        return Mirror.plan(cat, op, reason, function()
            local before = now_s()
            coroutine.yield()
            if MainLoop then
                local co = coroutine.running()
                MainLoop.paused[co] = (MainLoop.paused[co] or 0) + now_s() - before
                MainLoop.turns[co] = (MainLoop.turns[co] or 0) + 1
            end
        end)
    end)
    local function advance()
        if Mirror.preparing ~= prepare then return end
        local okp, plan = coroutine.resume(co)
        if not okp then
            Mirror.preparing, Mirror.busy = nil, nil
            log("mirror: plan failed:", tostring(plan)); Mirror.stop("plan failed"); return
        end
        if coroutine.status(co) ~= "dead" then return UIManager:scheduleIn(0.01, advance) end
        Mirror.preparing = nil
        Mirror.run_id, Mirror.queried_at = plan.run, nil
        Mirror.sent_at, Mirror.acknowledged, Mirror.no_ack, Mirror.query_wait = nowT(), nil, nil, nil
        if op == "full" then
            Mirror._status.run = plan.run
            OC.writeFile(Mirror.dir() .. "/status.lua", Cache.encode(Mirror._status))
        end
        Companion.send(Companion.ACTION.MIRROR, { reason = op .. ": " .. tostring(reason), server = client.server_url,
            user = client.username, userkey = client.userkey, plan = Cache.encode(plan),
            run = plan.run, op = op == "resume" and (Mirror.status().op or "full") or op, done = tostring(Mirror._status.done or 0), total = tostring(Mirror._status.total or 100) })
        Mirror.poll()
    end
    UIManager:nextTick(advance)
    -- The progress: a Full refresh (or its run resumed) shows the badge; a Refresh's recheck doesn't.
    if Mirror.manual and op == "full" then Badge.start(true, Mirror._status)
    elseif Mirror.manual and op == "resume" and Mirror.status().op == "full" and not Badge.running then Badge.start(true, Mirror.status()) end
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
    if r.why == "storage limit" then
        Mirror.active, Mirror.manual, Mirror.notices = nil, nil, nil
        Wifi.release("mirror")
        return -- wait for a changed limit or an explicit request; never retry pressure
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
    if Mirror.preparing then Mirror.preparing, Mirror.busy = nil, nil end
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
    -- Repaint the visible view from the completed cache, inside the catalog's
    -- asynchronous fetch context. Opening a book meanwhile cancels this paint.
    local cat = Mirror.catalog()
    if r and r.saved and cat and not cat.catalog_closed and not reading() then
        UIManager:nextTick(function()
            if cat.catalog_closed or reading() then return end
            require("ui/trapper"):wrap(function() LF.refreshKeepingCovers(cat) end)
        end)
    end
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
    if Mirror.busy and not Mirror.preparing and Mirror.status().engine == "bulk" then
        -- The companion's bulk catalog already saves the whole catalog. Join its
        -- admission instead of waiting silently for a queued incremental run to stop.
        if manual then Mirror.showProgress(reason) end
        return true
    end
    if manual and Mirror.preparing then
        -- No companion job exists yet: discard the obsolete resume plan now.
        Mirror.preparing, Mirror.busy = nil, nil
    end
    if Mirror.busy then
        OC.writeFile(Mirror.stopFile(), "stop")
        -- A manual bulk run replaces an obsolete crawl immediately. Do not wait
        -- for its summary (which may belong to an already dead process).
        Mirror.busy, Mirror.run_id, Mirror.polling = nil, nil, nil
        Mirror.next = nil
    end
    local s = Mirror.status()
    -- A failed/paused bulk Full refresh still owns its durable pages and cursor.
    -- Pressing again resumes it just like network up or wake.
    local resume = s.engine == "bulk" and s.op == "full" and (s.left or 0) > 0
    return Mirror.launch(resume and "resume" or "full", reason)
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
        local blocked = s.limit_note and tonumber(s.limit_note.limit)
        local limit = OC.limitBytes()
        if blocked and limit and limit <= blocked then return end
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

-- Upstream cover pruning/legacy cleanup must not enumerate files on KOReader's UI loop.
-- The companion enforces BookSync's storage limit and cover priorities instead.
function Mirror.guardPrune(Catalog)
    for _, method in ipairs({ "pruneThumbnailCache", "cleanLegacyThumbnails" }) do
        if Compat.callable(Catalog[method]) then
            wrap(Catalog, method, function() return function()
                -- One storage policy and one worker own cover deletion, including ETags.
                OC.storageCount("cover maintenance")
            end end, "cache")
        end
    end
end

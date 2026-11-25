-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Local-first Home on Android (docs/design/local-first/DESIGN.md "Item 3"; ROADMAP 3).
-- BookOrbit Home paints once, from data on the device that already shows what this device
-- knows; a refresh then repaints only the header stamp and the tiles that changed.
--   * LocalState (settings/orbit_local_state.lua, disposable): per book, this device's percent
--     and status, when it changed, and whether the upload still waits. Fed by the plugin's
--     close/suspend snapshot (BookOrbit:enqueueLifecycleSnapshot, main.lua:394, hooked in
--     endofbook.lua), our own finish marks, the outbox (bookorbit_lifecycle_outbox.lua :225
--     listMetadata, :247 isBlocked) and changed sidecars (bookorbit_sidecar.lua :87 sidecarMtime).
--   * Hooks on the catalog class and the board modules (bookorbit_board_data.lua :628 build;
--     bookorbit_catalog_dashboard.lua :113 dashboardRootFetch; bookorbit_catalog.lua :847
--     switchTo, :592 refreshOnDevice, :2056 updateItems, :475 refreshCurrent;
--     bookorbit_catalog_board.lua :151 boardHeader (its statusCluster upvalue, :149), :882
--     boardRun, :811 boardRefreshTile, :846 boardRefreshClock; bookorbit_catalog_lists.lua :739
--     listRun, :1155 listHeader; bookorbit_list_view.lua :162 header (its region upvalue, :93)).
--     If any is missing, nothing installs and the board is stock (one log line).
-- The server body upstream saves (settings.catalog_dashboard_cache) is never modified: the
-- overlay works on a copy.
---------------------------------------------------------------------------------------------

LocalState = { data = nil, gen = 0, failed = false }
LocalState.FILE = "orbit_local_state.lua"
LocalState.VERSION = 1
LocalState.MAX = 200

local function lsStore()
    local okd, DataStorage = pcall(require, "datastorage")
    local dir = okd and DataStorage:getSettingsDir() or "."
    return require("luasettings"):open(dir .. "/" .. LocalState.FILE)
end

function LocalState.load()
    if LocalState.data then return LocalState.data end
    local okl, d = pcall(function() return lsStore():readSetting("state") end)
    if not okl or type(d) ~= "table" or d.v ~= LocalState.VERSION then
        d = { v = LocalState.VERSION, books = {}, fetchedAt = {} } -- missing, corrupt or old: rebuilt
    end
    d.books, d.fetchedAt = d.books or {}, d.fetchedAt or {}
    LocalState.data = d
    return d
end

function LocalState.save()
    local d = LocalState.load()
    -- At most MAX books: the oldest change goes first.
    local list = {}
    for k, v in pairs(d.books) do table.insert(list, { k = k, at = v.changedAt or 0 }) end
    if #list > LocalState.MAX then
        table.sort(list, function(a, b) return a.at > b.at end)
        for i = LocalState.MAX + 1, #list do d.books[list[i].k] = nil end
    end
    pcall(function()
        local st = lsStore()
        st:saveSetting("state", d)
        st:flush()
    end)
end

function LocalState.bump()
    LocalState.gen = LocalState.gen + 1
end

local function bookIdOf(digest)
    local sm = package.loaded["bookorbit_state_manager"]
    if type(sm) ~= "table" or type(sm.getBook) ~= "function" then return nil end
    local okb, book = pcall(sm.getBook, digest)
    return okb and type(book) == "table" and book.bookId or nil
end

function LocalState.put(digest, fields)
    if type(digest) ~= "string" then return end
    local d = LocalState.load()
    local e = d.books[digest] or {}
    for k, v in pairs(fields) do e[k] = v end
    e.bookId = e.bookId or bookIdOf(digest)
    e.changedAt = fields.changedAt or os.time()
    d.books[digest] = e
    LocalState.bump()
    LocalState.save()
end

-- The plugin's close/suspend snapshot (percentage 0-1, KOReader's summary.status).
function LocalState.noteSnapshot(snap)
    local fields = { pending = true }
    if type(snap.percentage) == "number" then fields.percent = math.floor(snap.percentage * 1000 + 0.5) / 10 end
    if type(snap.status) == "string" then fields.status = snap.status end
    LocalState.put(snap.digest, fields)
end

-- A finish mark (or unmark) on this device, before any snapshot.
function LocalState.noteMark(b, status)
    LocalState.put(b.digest, { status = status, bookId = b.book_id, pending = true,
        percent = status == "complete" and 100 or nil })
end

function LocalState.noteSent(digest)
    local e = LocalState.load().books[digest]
    if e then e.finish_sent = true; LocalState.save() end
end

-- The outbox decides "pending": an entry still waiting for a book keeps it; once gone (acknowledged)
-- pending clears, unless a finish waits in our own queue. Blocked or retrying -> not synced.
function LocalState.fromOutbox(p)
    local okm, list, outbox = pcall(function()
        local o = p:getLifecycleOutbox()
        return o:listMetadata(), o
    end)
    if not okm or type(list) ~= "table" then return end
    local waiting = {}
    local now = os.time()
    for _, e in ipairs(list) do
        if type(e) == "table" and e.digest then
            local okb, blocked = pcall(outbox.isBlocked, outbox, e)
            waiting[e.digest] = { blocked = okb and blocked or false,
                retrying = e.next_attempt_at ~= nil and e.next_attempt_at > now }
        end
    end
    local changed = false
    for digest, e in pairs(LocalState.load().books) do
        local w = waiting[digest]
        local finish_waits = EOB and EOB.jobs and EOB.jobs[digest] ~= nil
        local pending = w ~= nil or finish_waits or false
        local blocked = w and w.blocked or false
        local retrying = w and w.retrying or false
        if e.pending ~= pending or (e.blocked or false) ~= blocked or (e.retrying or false) ~= retrying then
            e.pending, e.blocked, e.retrying = pending, blocked, retrying
            changed = true
        end
    end
    if changed then LocalState.bump(); LocalState.save() end
end

-- Sidecars of the board's books on this device, only those whose mtime moved (read in another app
-- or with auto-sync off). Up to 5 now; the rest in later steps, each followed by a quiet update.
function LocalState.scanSidecars(cat, ids)
    local sc = package.loaded["bookorbit_sidecar"]
    local sm = package.loaded["bookorbit_state_manager"]
    if type(sc) ~= "table" or type(sc.sidecarMtime) ~= "function" or type(sm) ~= "table" then return end
    local okm, maps = pcall(sm.onDeviceMaps)
    if not okm or type(maps) ~= "table" or type(maps.byBookId) ~= "table" then return end
    local todo = {}
    local by_id = {}
    for digest, e in pairs(LocalState.load().books) do if e.bookId then by_id[e.bookId] = { digest = digest, e = e } end end
    for _, id in ipairs(ids) do
        local rec = maps.byBookId[id]
        local file = type(rec) == "table" and (rec.file or rec.path) or (type(rec) == "string" and rec) or nil
        if file then
            local okt, mtime = pcall(sc.sidecarMtime, file)
            local known = by_id[id]
            if okt and mtime and (not known or known.e.sidecarMtime ~= mtime) then
                table.insert(todo, { id = id, file = file, mtime = mtime, digest = known and known.digest })
            end
        end
    end
    local function readOne(t)
        local okr, err = pcall(function()
            local ds = require("docsettings"):open(t.file)
            local pct = ds:readSetting("percent_finished")
            local summary = ds:readSetting("summary") or {}
            local digest = t.digest or ds:readSetting("partial_md5_checksum")
            if type(digest) ~= "string" then return end
            LocalState.put(digest, { bookId = t.id, sidecarMtime = t.mtime,
                percent = type(pct) == "number" and math.floor(pct * 1000 + 0.5) / 10 or nil,
                status = summary.status, changedAt = t.mtime })
        end)
        if not okr and not LocalState.sidecar_logged then
            LocalState.sidecar_logged = true
            log("local-first: a sidecar read failed (that book keeps the server's value):", err)
        end
    end
    for i = 1, math.min(5, #todo) do readOne(todo[i]) end
    local i = 6
    local function step()
        if not todo[i] then return end
        readOne(todo[i]); i = i + 1
        if cat then LF.quiet(cat) end
        UIManager:scheduleIn(0.2, step)
    end
    if todo[i] then UIManager:scheduleIn(0.2, step) end
end

-- { byBookId = { [id] = entry } } for the overlay.
function LocalState.view()
    local by = {}
    for _, e in pairs(LocalState.load().books) do
        if e.bookId then
            local cur = by[e.bookId]
            if not cur or (e.changedAt or 0) > (cur.changedAt or 0) then by[e.bookId] = e end
        end
    end
    return { byBookId = by }
end

---------------------------------------------------------------- hooks

LF = { installed = false, memo = setmetatable({}, { __mode = "k" }) }
LF.BOARD_DATA = { build = "function" }
LF.CATALOG = { switchTo = "function", refreshOnDevice = "function", updateItems = "function",
    refreshCurrent = "function", dashboardRootFetch = "function", boardHeader = "function",
    boardRun = "function", boardRefreshTile = "function", boardRefreshClock = "function",
    listRun = "function", listHeader = "function" }
LF.LIST_VIEW = { header = "function" }
LF.BOARD_UI = { statusCluster = "function", hit = "function", icon = "function", hstack = "function" }

local function upvalue(fn, name)
    for i = 1, 200 do
        local n, v = debug.getupvalue(fn, i)
        if n == nil then return nil end
        if n == name then return v, i end
    end
end

-- The overlaid body for a dashboard context, memoised on (body, local-state generation), so
-- the minute clock's rebuilds get the same table back.
function LF.overlaid(body)
    if type(body) ~= "table" then return body end
    local m = LF.memo[body]
    if m and m.gen == LocalState.gen then return m.out end
    local out = LocalFirst.overlay(body, LocalState.view())
    LF.memo[body] = { gen = LocalState.gen, out = out }
    return out
end

function LF.stampText(view, online)
    local d = LocalState.load()
    return LocalFirst.stamp({ online = online, fetched_at = d.fetchedAt[view], now = os.time(),
        failed = LF.failed and LF.failed[view] })
end

-- Quiet update of the open board after local state changed (sidecar steps, a sync).
function LF.quiet(cat)
    if not (cat and cat._board_ctx and cat._board_tiles and cat.current_context
        and cat.current_context.kind == "dashboard") or cat.catalog_closed then return 0 end
    local BoardData = package.loaded["bookorbit_board_data"]
    local old_d = cat._board_ctx.d
    local new_d = BoardData.build(cat, cat.current_context, os.time())
    local tiles = LF.tilesOf(cat)
    local changed = LocalFirst.changedTiles(tiles, tiles, old_d, new_d) or {}
    LF.logChanged(tiles, changed, old_d, new_d)
    cat._board_ctx.d = new_d
    LF.paintTiles(cat, changed)
    return #changed
end

-- Each tile gets its own turn; abandon stale repaints when the view changes.
function LF.paintTiles(cat, changed)
    cat._orbit_paint_pending = cat._orbit_paint_pending or {}
    for _i, index in ipairs(changed) do cat._orbit_paint_pending[index] = cat.current_context end
    if cat._orbit_painting then return end
    cat._orbit_painting = true
    local function paint()
        local index, context = next(cat._orbit_paint_pending)
        if not index then cat._orbit_painting = nil; return end
        cat._orbit_paint_pending[index] = nil
        if not reading() and not cat.catalog_closed and cat.current_context == context then
            local tile = cat._board_tiles and cat._board_tiles[index]
            if tile then pcall(cat.boardRefreshTile, cat, tile) end
        end
        UIManager:scheduleIn(0.01, paint)
    end
    UIManager:scheduleIn(0.01, paint)
end

-- One small answer replaces a 364-day date/SQLite pass on every board rebuild.
LF.year = { values = {}, start = 0, today = 0 }
function LF.yearMinutes(now, year)
    if LF.year.today == 0 then
        -- A correctly dated empty calendar while the first worker snapshot is in flight.
        local day = os.date("*t", now); day.hour, day.min, day.sec = 0, 0, 0
        local today = os.time(day)
        local dow = tonumber(os.date("%w", now))
        local values = {}; for i=1,364-(6-dow) do values[i]=0 end
        LF.year = { values = values, start = today + (6-dow-363)*86400 + 43200, today = today }
    end
    local key = tostring(year) .. ":" .. os.date("%Y-%m-%d", now) .. ":" .. tostring(math.floor(now / 120))
    if LF.year_key ~= key and not Companion.workerProblem() then
        LF.year_key = key
        Companion.send(Companion.ACTION.PATCH, { reason = "Home calendar", board_year = Cache.encode(year or {}),
            board_key = key, board_now = tostring(now) })
        LF.year_waiting = os.time()
        OC.watchChecks()
    end
    return LF.year.values, LF.year.start, LF.year.today
end
function LF.yearLanded(ev)
    if ev.key ~= LF.year_key or type(ev.data) ~= "table" then return end
    LF.year_waiting = nil
    LF.year = ev.data
    local cat = Mirror.catalog()
    if cat then
        if not reading() then LF.quiet(cat) end
    end
end

-- One line per changed tile: which one and what in it changed (why a quiet repaint happened).
function LF.logChanged(tiles, changed, old_d, new_d)
    for _, i in ipairs(changed or {}) do
        local t = tiles[i] or {}
        local okd, what = pcall(LocalFirst.tileDiff, t.kind, old_d, new_d, t.source)
        log("local-first: tile", tostring(i), tostring(t.kind) .. (t.source and ("/" .. tostring(t.source)) or ""),
            "changed:", okd and tostring(what) or ("? " .. tostring(what)))
    end
end

-- The on-device marks for Home's first paint. The catalog is built with none
-- (bookorbit_catalog.lua:322 on_device = {}) and paints Home (initialDashboardContext, :332)
-- before it reads them (:353 hydrateOnDeviceMaps, next tick): every book on the reader drew
-- "Download", then "Resume" once the refresh landed (v0.11.1 on the M8C, every Home open). The
-- plugin's maps when it has them (BookOrbitStateManager.onDeviceMaps, what refreshOnDevice
-- :592-611 adopts), else the ones kept from the last start.
function LF.primeOnDevice(cat)
    if type(cat) ~= "table" then return 0 end
    if type(cat.on_device) == "table" and next(cat.on_device) ~= nil then return 0 end
    local sm = package.loaded["bookorbit_state_manager"]
    if type(sm) == "table" and Compat.callable(sm.hasOnDeviceMaps) and Compat.callable(sm.onDeviceMaps) then
        local okh, has = pcall(sm.hasOnDeviceMaps)
        local okm, maps = false, nil
        if okh and has then okm, maps = pcall(sm.onDeviceMaps) end
        if okm and type(maps) == "table" and type(maps.byBookId) == "table" then
            cat.on_device, cat.on_device_files = maps.byBookId, maps.byFileId or cat.on_device_files
            cat.on_device_generation = maps.generation
            local n = 0
            for _ in pairs(maps.byBookId) do n = n + 1 end
            log("local-first: first paint with BookOrbit's on-device marks for", n, "book(s)")
            return n
        end
    end
    return LF.seedOnDevice(cat)
end

function LF.tilesOf(cat)
    local out = {}
    for i, e in ipairs(cat._board_tiles or {}) do
        local item = e.item or {}
        table.insert(out, { key = i, kind = item.type, source = item.source or (item.props and item.props.source) })
    end
    return out
end

local function boardBookIds(body)
    local ids, seen = {}, {}
    local function add(list)
        for _, b in ipairs(type(list) == "table" and list or {}) do
            if type(b) == "table" and b.id and not seen[b.id] then seen[b.id] = true; table.insert(ids, b.id) end
        end
    end
    if type(body) == "table" then
        add(body.continueReading); add(body.finishedThisYear)
        for _, l in pairs(type(body.boardShelves) == "table" and body.boardShelves or {}) do add(l) end
    end
    return ids
end

function LF.install(why)
    if LF.installed then return true end
    local Catalog = package.loaded["bookorbit_catalog"]
    local BoardData = package.loaded["bookorbit_board_data"]
    local ListView = package.loaded["bookorbit_list_view"]
    local BoardUI = package.loaded["bookorbit_board_ui"]
    if type(Catalog) ~= "table" or type(BoardData) ~= "table" or type(ListView) ~= "table" or type(BoardUI) ~= "table" then
        return false
    end
    local missing = {}
    for _, m in ipairs(Compat.missingOn(Catalog, LF.CATALOG)) do table.insert(missing, m) end
    for _, m in ipairs(Compat.missingOn(BoardData, LF.BOARD_DATA)) do table.insert(missing, "BoardData." .. m) end
    for _, m in ipairs(Compat.missingOn(ListView, LF.LIST_VIEW)) do table.insert(missing, "ListView." .. m) end
    for _, m in ipairs(Compat.missingOn(BoardUI, LF.BOARD_UI)) do table.insert(missing, "BoardUI." .. m) end
    local board_status = type(Catalog.boardHeader) == "function" and select(2, upvalue(Catalog.boardHeader, "statusCluster"))
    local list_region = type(ListView.header) == "function" and upvalue(ListView.header, "region")
    if not board_status then table.insert(missing, "boardHeader.statusCluster") end
    if type(list_region) ~= "function" then table.insert(missing, "ListView.header.region") end
    if #missing > 0 then
        if not compat_logged.local_first then
            compat_logged.local_first = true
            log("compat: local-first Home off (plugin changed): missing " .. table.concat(missing, ", "))
        end
        return false
    end
    if type(BoardData.yearMinutes) == "function" then BoardData.yearMinutes = LF.yearMinutes end
    LF.installed = true
    LF.failed = {}
    log("local-first: installed (" .. tostring(why) .. ")")

    -- The overlay: every board build sees an overlaid copy of the body.
    wrap(BoardData, "build", function(stock) return function(catalog, context, now)
        if type(context) == "table" and type(context.dashboard) == "table" then
            local c = {}
            for k, v in pairs(context) do c[k] = v end
            c.dashboard = LF.overlaid(context.dashboard)
            local d = stock(catalog, c, now)
            if type(d) == "table" then d.orbit_board = true end
            return d
        end
        return stock(catalog, context, now)
    end end, "lf")

    -- The header ⟳ (left of the device status) and the freshness stamp.
    local function refreshIcon(d)
        local okm, px = pcall(function() return require("bookorbit_board_metrics").px end)
        local size = okm and type(px) == "function" and px(18) or 18
        return BoardUI.icon("refresh-cw", size, { sw = 2 })
    end
    local function withRefresh(stock_cluster, d, make)
        local cluster = stock_cluster(d)
        local okw, w = pcall(function()
            return BoardUI.hstack({ gap = 8 }, { make(refreshIcon(d)), cluster })
        end)
        return okw and w or cluster
    end
    local stock_cluster = BoardUI.statusCluster
    debug.setupvalue(Catalog.boardHeader, board_status, function(d)
        if type(d) == "table" and d.orbit_board then
            return withRefresh(stock_cluster, d, function(icon) return BoardUI.hit(LF.holdable(icon), { kind = "orbit-refresh" }) end)
        end
        return stock_cluster(d)
    end)
    wrap(BoardUI, "statusCluster", function(stock) return function(d)
        if LF.list_header then
            return withRefresh(stock, d, function(icon)
                return list_region(icon, { kind = "orbit-refresh" }, "header", "orbit-refresh")
            end)
        end
        return stock(d)
    end end, "lf")
    wrap(ListView, "header", function(stock) return function(w, o)
        if type(o) ~= "table" or not o.orbit_refresh then return stock(w, o) end
        LF.list_header = true
        local okh, r1, r2, r3 = pcall(stock, w, o)
        LF.list_header = nil
        if not okh then error(r1, 0) end
        return r1, r2, r3
    end end, "lf")
    wrap(Catalog, "boardHeader", function(stock) return function(self, d, w, mode, page_name)
        if type(d) == "table" and d.orbit_board and mode ~= "edit" and not (not d.online and d.stale) then
            local stamp = LF.stampText("dashboard", d.online)
            if stamp then
                local c = {}
                for k, v in pairs(d) do c[k] = v end
                c.date_long = (d.date_long or "") .. " · " .. stamp
                return stock(self, c, w, mode, page_name)
            end
        end
        return stock(self, d, w, mode, page_name)
    end end, "lf")
    wrap(Catalog, "listHeader", function(stock) return function(self, kind, context)
        local h = stock(self, kind, context)
        if type(h) == "table" and not h.select then
            h.orbit_refresh = true
            local key = LF.viewKey(context)
            local stamp = key and LF.stampText(key, require("ui/network/manager"):isConnected())
            if stamp and type(h.sub) == "string" then h.sub = h.sub .. " · " .. stamp
            elseif stamp and h.sub == nil then h.sub = stamp end
        end
        return h
    end end, "lf")
    wrap(Catalog, "boardRun", function(stock) return function(self, action, tile)
        if type(action) == "table" and action.kind == "orbit-refresh" then
            log("local-first: ⟳ on Home")
            return LF.refreshTap(self)
        end
        return stock(self, action, tile)
    end end, "lf")
    wrap(Catalog, "listRun", function(stock) return function(self, action, region, hold)
        if type(action) == "table" and action.kind == "orbit-refresh" then
            log("local-first: ⟳ on a list" .. (hold and " (held)" or ""))
            if hold then return LF.refreshHold(self) end
            return LF.refreshTap(self)
        end
        return stock(self, action, region, hold)
    end end, "lf")

    -- Covers are keyed by book id + cover version (plugin thumbnailPath), so a changed cover
    -- arrives under a new name: our refresh never deletes them (plugin refreshCurrent,
    -- bookorbit_catalog.lua:475-490, evicts every cover on screen). Failed ones retry.
    if Compat.callable(Catalog.evictCachedCovers) then
        wrap(Catalog, "evictCachedCovers", function(stock) return function(self, books)
            if not self._orbit_keep_covers then return stock(self, books) end
            if type(self.thumbnail_failures) == "table" then self.thumbnail_failures = {} end
        end end, "lf")
    end

    -- A server refresh: tag it and stamp it; a failure marks "Not updated".
    wrap(Catalog, "dashboardRootFetch", function(stock) return function(self, opts)
        local items, context = stock(self, opts)
        if type(context) == "table" and type(context.dashboard) == "table" and not context.stale
            and not (OC and OC.cache_only) then
            context.orbit_refresh = true
            LocalState.load().fetchedAt.dashboard = os.time()
            LF.failed.dashboard = nil
            LocalState.save()
        elseif type(context) == "table" and context.unavailable and require("ui/network/manager"):isConnected() then
            LF.failed.dashboard = true
        end
        return items, context
    end end, "lf")

    -- One paint, then quiet updates (design "One paint, then quiet updates").
    wrap(Catalog, "switchTo", function(stock) return function(self, title, item_table, context, push)
        if type(context) == "table" and context.kind == "books" then
            LocalState.load().fetchedAt[LF.viewKey(context) or "books"] = os.time()
        end
        local function full(why)
            if type(context) == "table" then
                log("paint:", tostring(context.kind), "full (" .. why .. ") from", tostring(self._orbit_paint_source or "the plugin")
                    .. (context.stale and (context.orbit_first and ", first paint" or ", saved body") or ""))
            end
            return stock(self, title, item_table, context, push)
        end
        local old = self.current_context
        -- A saved body coming back over the Home on screen (a refresh that couldn't reach the
        -- server) only updates what differs; it never repaints every tile.
        local saved_over_home = type(context) == "table" and context.kind == "dashboard" and context.stale
            and old and old.kind == "dashboard" and self._board_ctx ~= nil
        if push or type(context) ~= "table" or context.kind ~= "dashboard" or not (context.orbit_refresh or saved_over_home) then
            return full(push and "opened" or "new view")
        end
        if not (old and old.kind == "dashboard" and self._board_ctx and self._board_tiles) or self.board_edit then
            return full("first paint")
        end
        local okq, done = pcall(LF.quietSwitch, self, old, item_table, context)
        log("paint: Home", (okq and done) and "quiet (changed tiles only)" or "full", "from", tostring(self._orbit_paint_source or "the plugin"))
        if okq and done then
            -- The stock switchTo would cancel the cover jobs and queue this body's covers; the
            -- quiet path keeps the jobs running and queues the covers it doesn't have yet.
            if Compat.callable(self.scheduleThumbnailDownloads) and Compat.callable(self.dashboardBooks) then
                pcall(self.scheduleThumbnailDownloads, self, self.dashboardBooks(context.dashboard))
            end
            return
        end
        if not okq then log("local-first: quiet update failed, full repaint:", done) end
        return stock(self, title, item_table, context, push)
    end end, "lf")

    -- Hydration: when the on-device marks didn't change, the repaint after it is skipped.
    -- Every change to the plugin's state file drops its on-device maps (bookorbit_state_manager
    -- .lua:107-111 publish), and a new catalog starts with none (bookorbit_catalog.lua:322):
    -- until the child process rebuilds them (:612), every book would draw "Download". The last
    -- maps seen are kept here and stand in meanwhile, so a book on the reader shows "Resume"
    -- on the first paint.
    if Compat.callable(Catalog.hydrateOnDeviceMaps) then
        wrap(Catalog, "hydrateOnDeviceMaps", function(stock) return function(self, ...)
            pcall(LF.seedOnDevice, self)
            return stock(self, ...)
        end end, "lf")
    end
    wrap(Catalog, "refreshOnDevice", function(stock) return function(self, ...)
        local before = LF.onDeviceKey(self)
        local r = stock(self, ...)
        if r then pcall(LF.keepOnDevice, self) else pcall(LF.seedOnDevice, self) end
        if self.current_context and self.current_context.kind == "dashboard" and before ~= nil
            and before == LF.onDeviceKey(self) then
            self._orbit_skip_repaint = true
            UIManager:nextTick(function() self._orbit_skip_repaint = nil end)
        end
        return r
    end end, "lf")
    wrap(Catalog, "updateItems", function(stock) return function(self, ...)
        if self._orbit_skip_repaint and self.current_context and self.current_context.kind == "dashboard" then
            self._orbit_skip_repaint = nil
            -- Skipped as a full repaint, but whatever did change (a cover that just landed)
            -- still repaints its own tile.
            local okq, n = pcall(LF.quiet, self)
            if okq and (n or 0) > 0 then log("covers: late cover(s) landed;", n, "tile(s) redrawn") end
            return
        end
        return stock(self, ...)
    end end, "lf")
    return true
end

local function deviceOwner(cat)
    local c = cat and cat.client
    return c and (tostring(c.server_url) .. "|" .. tostring(c.username)) or nil
end

-- The plugin's current on-device map, kept for the next start (only when it changed).
function LF.keepOnDevice(cat)
    if type(cat.on_device) ~= "table" then return end
    local map, n = {}, 0
    for id, path in pairs(cat.on_device) do
        if type(path) == "string" then map[tostring(id)] = path; n = n + 1 end
    end
    local saved = S.orbit_on_device
    local sig = Cache.encode(map)
    if saved and saved.owner == deviceOwner(cat) and saved.sig == sig then return end
    S.orbit_on_device = { owner = deviceOwner(cat), map = map, sig = sig }
    saveSettings()
end

-- A book this reader has open is on it, whatever the maps say (noted on the way to Home).
function LF.noteOnDevice(book_id, path)
    if not (book_id and type(path) == "string") then return end
    local saved = S.orbit_on_device
    if not saved then return end
    if saved.map[tostring(book_id)] == path then return end
    saved.map[tostring(book_id)] = path
    saved.sig = nil
    saveSettings()
end

-- While the plugin's maps are missing: the kept ones, for files that are still there.
function LF.seedOnDevice(cat)
    local saved = S.orbit_on_device
    if not (saved and saved.owner == deviceOwner(cat) and type(saved.map) == "table") then return 0 end
    cat.on_device = type(cat.on_device) == "table" and cat.on_device or {}
    local n = 0
    for id, path in pairs(saved.map) do
        local nid = tonumber(id)
        if nid and cat.on_device[nid] == nil and require("libs/libkoreader-lfs").attributes(path, "mode") == "file" then
            cat.on_device[nid] = path
            n = n + 1
        end
    end
    if n > 0 then log("local-first: on-device marks from the last start for", n, "book(s) while BookOrbit rebuilds its own") end
    return n
end

-- The board's ⟳ with its own hold: a hold on it is a Full refresh, not the tile's board editing
-- (the tile's HoldSelect, bookorbit_catalog_board.lua:75, sees it only if this one doesn't).
function LF.holdable(icon)
    local okw, wdg = pcall(function()
        local InputContainer = require("ui/widget/container/inputcontainer")
        local GestureRange = require("ui/gesturerange")
        local area = InputContainer:new{ icon }
        area.ges_events = { OrbitHold = { GestureRange:new{ ges = "hold", range = function() return area.dimen end } } }
        area.onOrbitHold = function()
            local p = bookorbit(liveUI())
            local cat = p and p.catalog_browser
            if cat then log("local-first: ⟳ on Home (held)"); LF.refreshHold(cat) end
            return true
        end
        return area
    end)
    return okw and wdg or icon
end

-- Tap ⟳ = Refresh, hold ⟳ = Full refresh (docs/design/write-through-cache.md); without the
-- cache, both are the plugin's refresh with the covers kept.
function LF.refreshTap(cat)
    if OC and OC.installed then return OC.refresh(cat) end
    return LF.refreshKeepingCovers(cat)
end

function LF.refreshHold(cat)
    if OC and OC.installed then return OC.fullRefresh(cat) end
    return LF.refreshKeepingCovers(cat)
end

-- ⟳: the plugin's refresh of the current view, keeping the covers on disk.
function LF.refreshKeepingCovers(cat)
    cat._orbit_keep_covers = true
    local okr, r = pcall(cat.refreshCurrent, cat)
    cat._orbit_keep_covers = nil
    if not okr then error(r, 0) end
    return r
end

-- The view key for list stamps: the list's kind and its main filter.
function LF.viewKey(context)
    if type(context) ~= "table" then return nil end
    local p = context.params or {}
    return table.concat({ tostring(context.kind), tostring(context.section or ""), tostring(p.libraryId or p.collectionId
        or p.smartScopeId or p.author or p.seriesId or ""), tostring(p.sort or "") }, "|")
end

function LF.onDeviceKey(cat)
    local body = cat.current_context and cat.current_context.dashboard
    if type(body) ~= "table" or type(cat.on_device) ~= "table" then return nil end
    local parts = {}
    for _, id in ipairs(boardBookIds(body)) do table.insert(parts, cat.on_device[id] and "1" or "0") end
    return table.concat(parts)
end

-- A refreshed dashboard replacing the one on screen: adopt it, repaint the header (stamp) and
-- the tiles whose content changed; a different tile set or page set -> false (full repaint).
function LF.quietSwitch(cat, old, item_table, context)
    local BoardData = package.loaded["bookorbit_board_data"]
    local ob, nb = old.dashboard or {}, context.dashboard or {}
    if LocalFirst.serialize(ob.boardNames) ~= LocalFirst.serialize(nb.boardNames) then return false end
    local ok_keys, nk_keys = {}, {}
    for k in pairs(type(ob.boardShelves) == "table" and ob.boardShelves or {}) do table.insert(ok_keys, k) end
    for k in pairs(type(nb.boardShelves) == "table" and nb.boardShelves or {}) do table.insert(nk_keys, k) end
    table.sort(ok_keys); table.sort(nk_keys)
    if table.concat(ok_keys, ",") ~= table.concat(nk_keys, ",") then return false end
    context.board_page = context.board_page or old.board_page
    local old_d = cat._board_ctx.d
    cat.current_context = context
    cat.item_table = item_table
    local new_d = BoardData.build(cat, context, os.time())
    local tiles = LF.tilesOf(cat)
    local changed = LocalFirst.changedTiles(tiles, tiles, old_d, new_d)
    if not changed then return false end
    LF.logChanged(tiles, changed, old_d, new_d)
    cat._board_ctx.d = new_d
    cat:boardRefreshClock() -- the header: "updated just now"
    LF.paintTiles(cat, changed)
    log("local-first: refresh landed;", #changed, "tile(s) changed")
    LocalState.scanSidecars(cat, boardBookIds(nb))
    return true
end

-- Wiring: install with grouping at init; outbox state and sidecars on open and resume.
do
    local base_init = OrbitAndroid.init
    function OrbitAndroid:init(...)
        local r = base_init(self, ...)
        if S.local_first ~= false then pcall(LF.install, "init") end
        pcall(LF.installRemove)
        pcall(Gate.installToast)
        local p = bookorbit(self.ui)
        if p then
            pcall(LocalState.fromOutbox, p)
            pcall(EOB.installPluginHooks, p)
        end
        return r
    end
    local base_resume = OrbitAndroid.onResume
    function OrbitAndroid:onResume(...)
        local p = bookorbit(self.ui)
        if p then pcall(LocalState.fromOutbox, p) end
        local cat = p and p.catalog_browser
        if cat and cat.current_context and cat.current_context.kind == "dashboard" then
            pcall(LocalState.scanSidecars, cat, boardBookIds(cat.current_context.dashboard))
            pcall(LF.quiet, cat)
        end
        if base_resume then return base_resume(self, ...) end
    end
end

---------------------------------------------------------------- remove from this reader

-- BookOrbit removes a book's file through the file browser's delete (which asks first and
-- clears the sidecar, history and collections: filemanager.lua:1120-1191), and without a file
-- browser it only says "Open the file browser to remove this book." (bookorbit_catalog_board.lua
-- :955-966, bookorbit_catalog_detail.lua:764-776, bookorbit_book_peek.lua:155-167). With a book
-- open there is no file browser: Home opens over the book. The same delete runs from KOReader's
-- FileManager class (its file delete uses no file-browser state), with the same confirmation.
-- The book that is open stays: removing it under the reader would break its sidecar.
function LF.withFileManager(path, run)
    local okf, FM = pcall(require, "apps/filemanager/filemanager")
    if not okf or type(FM) ~= "table" or FM.instance or type(FM.showDeleteFileDialog) ~= "function" then return run() end
    local okr, RUI = pcall(require, "apps/reader/readerui")
    local open = okr and type(RUI) == "table" and RUI.instance and RUI.instance.document and RUI.instance.document.file
    if open and path and open == path then
        log("remove: the book is open; not removed")
        pcall(function() require("bookorbit_toast").error(_("This book is open. Close it, then remove it.")) end) -- gate: user action (Remove)
        return
    end
    log("remove: no file browser open; KOReader's delete (it asks first)")
    FM.instance = setmetatable({}, { __index = FM })
    local okc, err = pcall(run)
    FM.instance = nil
    if not okc then error(err, 0) end
end

function LF.installRemove()
    local Catalog = package.loaded["bookorbit_catalog"]
    if type(Catalog) == "table" and Compat.callable(Catalog.boardDustRemove) then
        wrap(Catalog, "boardDustRemove", function(stock) return function(self, book)
            local path = book and Compat.callable(self.onDeviceBookPath) and self:onDeviceBookPath(book)
            return LF.withFileManager(path, function() return stock(self, book) end)
        end end, "remove")
    end
    if type(Catalog) == "table" and Compat.callable(Catalog.detailRemoveFromDevice) then
        wrap(Catalog, "detailRemoveFromDevice", function(stock) return function(self, d)
            return LF.withFileManager(d and d.read_path, function() return stock(self, d) end)
        end end, "remove")
    end
    local okp, Peek = pcall(require, "bookorbit_book_peek")
    if okp and type(Peek) == "table" and Compat.callable(Peek.remove) then
        wrap(Peek, "remove", function(stock) return function(catalog, path)
            return LF.withFileManager(path, function() return stock(catalog, path) end)
        end end, "remove")
    end
end

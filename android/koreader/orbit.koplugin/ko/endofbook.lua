-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- End of book on Android (docs/design/end-of-book/DESIGN.md §3, §4, §7; ROADMAP 1 and 2).
--   * Turning past the last page of a BookOrbit book marks it finished (KOReader's markBook) and
--     opens the Orbit sheet over the last page: Undo, stars, the next book in the series, one
--     suggestion, the author's page, Back to book / Home.
--   * Every "finished" (the sheet, or KOReader's own Mark as finished) is a FinishJob in
--     settings/orbit-finish-queue.lua. Leaving the book makes it ready; the next network-up sends
--     it after the plugin's outbox (Sync.waitOutbox): guard read, read-status, rating, then the
--     server's state written back so the plugin's next pull doesn't revert it (server S7).
--   * A finished book's progress push 10+ points below the end is held (§7, server S3/S4).
-- Hooks, each behind EOB.compat: KOReader's ReaderStatus (readerstatus.lua :38 onEndOfBook,
-- :212 markBook); the plugin's BookOrbit:enqueueLifecycleSnapshot (main.lua:394),
-- :updateProgress and :pushProgressAfterBookSync (live pushes, bookorbit_progress_sync.lua :295,
-- :284, mixed in at main.lua:99), :newClient (:272); bookorbit_api.lua :737 catalogBook,
-- :705 catalogSetReadStatus, :709 catalogSetRating; bookorbit_state_manager.lua :253 getBook,
-- :307 mutate, :348 onDeviceMaps; bookorbit_sidecar.lua :276 rememberServerState,
-- :401 applyServerStateLive, :411 applyServerStateSidecar; the catalog class's download
-- (bookorbit_catalog_download.lua :166 downloadDefaultFile, :213 downloadFile) and author page
-- (bookorbit_catalog.lua :1181 loadBooks).
---------------------------------------------------------------------------------------------

EOB = { page_digests = setmetatable({}, { __mode = "k" }), jobs = nil, details = nil, session = {}, sheet = nil, wants_download = nil }
EOB.QUEUE_FILE = "orbit-finish-queue.lua"
EOB.CACHE_FILE = "orbit-detail-cache.lua"
EOB.CACHE_MAX = 32
EOB.COMPAT = {
    plugin = { newClient = "function", getDocumentDigest = "function" },
    api = { catalogBook = "function", catalogSetReadStatus = "function", catalogSetRating = "function" },
    state = { getBook = "function", mutate = "function", onDeviceMaps = "function" },
    sidecar = { rememberServerState = "function", applyServerStateLive = "function", applyServerStateSidecar = "function" },
}
EOB.CATALOG = { downloadDefaultFile = "function", downloadFile = "function", loadBooks = "function" }
-- Used when present (the detail page's path): fetchDeliveryBook, supportedFiles.

local function settingsDir()
    local okd, DataStorage = pcall(require, "datastorage")
    return okd and DataStorage:getSettingsDir() or "."
end

local function store(name)
    local LuaSettings = require("luasettings")
    return LuaSettings:open(settingsDir() .. "/" .. name)
end

-- The plugin's modules this feature calls; nil and one log line when the plugin changed.
function EOB.mods()
    local m = {
        api = package.loaded["bookorbit_api"],
        state = package.loaded["bookorbit_state_manager"],
        sidecar = package.loaded["bookorbit_sidecar"],
    }
    local missing = {}
    for k, needs in pairs(EOB.COMPAT) do
        if k ~= "plugin" then
            if type(m[k]) ~= "table" then table.insert(missing, k)
            else for _, n in ipairs(Compat.missingOn(m[k], needs)) do table.insert(missing, k .. "." .. n) end end
        end
    end
    if #missing > 0 then
        if not compat_logged.end_of_book then
            compat_logged.end_of_book = true
            table.sort(missing)
            log("compat: end of book off (plugin changed): missing " .. table.concat(missing, ", "))
        end
        return nil
    end
    return m
end

function EOB.usable(p)
    return p ~= nil and #Compat.missingOn(p, EOB.COMPAT.plugin) == 0 and EOB.mods() ~= nil
end

---------------------------------------------------------------- the queue and the detail cache

function EOB.queue()
    if not EOB.jobs then
        local okq, q = pcall(function() return store(EOB.QUEUE_FILE):readSetting("jobs") end)
        EOB.jobs = (okq and type(q) == "table") and q or {}
    end
    return EOB.jobs
end

function EOB.save()
    local oks, err = pcall(function()
        local st = store(EOB.QUEUE_FILE)
        st:saveSetting("jobs", EOB.queue())
        st:saveSetting("downloads", EOB.wants_download or {})
        st:flush()
    end)
    if not oks then log("end of book: can't save the queue:", err) end
end

function EOB.downloads()
    if not EOB.wants_download then
        local okq, q = pcall(function() return store(EOB.QUEUE_FILE):readSetting("downloads") end)
        EOB.wants_download = (okq and type(q) == "table") and q or {}
    end
    return EOB.wants_download
end

function EOB.cache()
    if not EOB.details then
        local okc, c = pcall(function() return store(EOB.CACHE_FILE):readSetting("books") end)
        EOB.details = (okc and type(c) == "table") and c or {}
    end
    return EOB.details
end

-- Keeps what the sheet draws from a book detail (server S13), newest EOB.CACHE_MAX books.
function EOB.remember(detail)
    if type(detail) ~= "table" or detail.id == nil then return end
    local keep = { id = detail.id, title = detail.title, authors = detail.authors, seriesId = detail.seriesId,
        seriesName = detail.seriesName, seriesIndex = detail.seriesIndex, readStatus = detail.readStatus,
        rating = detail.rating, files = detail.files, seriesMembers = detail.seriesMembers,
        relatedSections = detail.relatedSections, saved_at = os.time() }
    local c = EOB.cache()
    c[tostring(detail.id)] = keep
    local ids = {}
    for k, v in pairs(c) do table.insert(ids, { k = k, at = v.saved_at or 0 }) end
    table.sort(ids, function(a, b) return a.at > b.at end)
    for i = EOB.CACHE_MAX + 1, #ids do c[ids[i].k] = nil end
    pcall(function()
        local st = store(EOB.CACHE_FILE)
        st:saveSetting("books", c)
        st:flush()
    end)
end

-- The open book: { digest, file, book_id, summary, doc_settings } or nil when it isn't a
-- BookOrbit book (no server id: the end screen stays KOReader's).
function EOB.bookOf(ui)
    local p = ui and ui.bookorbit
    local m = EOB.mods()
    if not (p and m and ui.document and ui.doc_settings) or not EOB.usable(p) then return nil end
    local okd, digest = pcall(p.getDocumentDigest, p)
    if not okd or type(digest) ~= "string" then return nil end
    EOB.page_digests[ui] = { file = ui.document.file, digest = digest }
    local okb, book = pcall(m.state.getBook, digest)
    local id = okb and type(book) == "table" and book.bookId or nil
    return { digest = digest, file = ui.document.file, book_id = id, summary = ui.doc_settings:readSetting("summary") or {},
        doc_settings = ui.doc_settings, plugin = p }
end

-- Is this book on the device? Its path, from the plugin's map (byBookId: id -> file record).
function EOB.onDevice(book_id)
    local m = EOB.mods()
    if not m or book_id == nil then return nil end
    local okm, maps = pcall(m.state.onDeviceMaps)
    local rec = okm and type(maps) == "table" and maps.byBookId and maps.byBookId[book_id] or nil
    if type(rec) == "table" then return rec.file or rec.path end
    if type(rec) == "string" then return rec end
    return nil
end

---------------------------------------------------------------- marking (§3, §4 hooks)

-- KOReader's markBook ran (any route: the sheet, the end dialog, the menus). complete -> a job
-- (unsent until the book is left); anything else -> the unsent job is gone.
function EOB.onMarked(ui)
    local b = EOB.bookOf(ui)
    if not b then return end
    local q = EOB.queue()
    if b.summary.status == "complete" then
        local pct = nil
        pcall(function() pct = ui.bookorbit:getLastPercent() end)
        local job = Finish.put(q, Finish.newJob({ hash = b.digest, book_id = b.book_id, file = b.file,
            finished_on = Finish.day(os.time()), final_pos = { percentage = pct },
            status_seen = EOB.cache()[tostring(b.book_id)] and EOB.cache()[tostring(b.book_id)].readStatus or nil,
            now = os.time() }))
        job.ready = false
        EOB.session[b.digest] = { forward = 0, released = false }
        log("end of book: marked finished", b.book_id or "(no id)", "| sends after the book is left")
    else
        if Finish.cancel(q, b.digest) then log("end of book: unmarked; nothing will be sent") end
        if EOB.session[b.digest] then EOB.session[b.digest].released = true end
    end
    EOB.save()
    if LocalState then LocalState.noteMark(b, b.summary.status) end
end

-- Leaving the book (close, suspend, Home, another book): its job is ready to send.
function EOB.onLeave(ui)
    local b = EOB.bookOf(ui)
    -- Home is painted over the open book, which has sent nothing yet: its position and status
    -- go into the local overlay first, so the first paint already shows them (item 4).
    if b and LocalState then
        local okp, pct = pcall(b.plugin.getLastPercent, b.plugin)
        local fields = { pending = true, bookId = b.book_id }
        if okp and type(pct) == "number" then fields.percent = math.floor(pct * 1000 + 0.5) / 10 end
        if type(b.summary.status) == "string" then fields.status = b.summary.status end
        pcall(LocalState.put, b.digest, fields)
        pcall(LF.noteOnDevice, b.book_id, ui and ui.document and ui.document.file)
        log("home: noted the open book for Home:", tostring(fields.percent) .. "%", tostring(fields.status))
    end
    local job = b and EOB.queue()[b.digest]
    if job and not job.ready then
        job.ready = true
        EOB.save()
        log("end of book: left the book; the finish goes with the next sync")
    end
end

function EOB.installReaderHooks()
    local okr, ReaderStatus = pcall(require, "apps/reader/modules/readerstatus")
    if not okr or type(ReaderStatus) ~= "table" then return false end
    if #Compat.missingOn(ReaderStatus, { onEndOfBook = "function", markBook = "function" }) > 0 then
        log("compat: end of book off: KOReader's ReaderStatus changed")
        return false
    end
    wrap(ReaderStatus, "markBook", function(stock) return function(self, mark_read)
        local r = stock(self, mark_read)
        local okm, err = pcall(EOB.onMarked, self.ui)
        if not okm then log("end of book: mark hook failed:", err) end
        return r
    end end, "eob")
    wrap(ReaderStatus, "onEndOfBook", function(stock) return function(self, ...)
        if S.eob_sheet == false then return stock(self, ...) end
        local b = EOB.bookOf(self.ui)
        if not b or not b.book_id then return stock(self, ...) end
        if (b.summary.status ~= "complete") and S.eob_auto ~= false then self:markBook(true) end
        local oks, err = pcall(EOB.showSheet, self.ui, b)
        if not oks then
            log("end of book: sheet failed, KOReader's own end screen instead:", err)
            return stock(self, ...)
        end
        return true
    end end, "eob")
    return true
end

---------------------------------------------------------------- the sheet (§4)

-- What the sheet shows, from the cached detail: { title, author, stars, next = card,
-- suggestion = { line, title, book_id, action }, status }.
function EOB.model(b)
    local d = EOB.cache()[tostring(b.book_id)] or { id = b.book_id }
    local job = EOB.queue()[b.digest]
    local n = Finish.next(d)
    local card = n and Finish.nextCard(n, n.book and EOB.onDevice(n.book.id) ~= nil) or nil
    local sugg = Finish.suggestions(d, Finish.SUGGEST_ANDROID, n and n.book and n.book.id)[1]
    local s = nil
    if sugg then
        local author = Finish.author(d)
        s = { line = sugg.source == "author" and author and ("Also by " .. author) or "You might like",
            title = sugg.book.title, book_id = sugg.book.id, action = EOB.onDevice(sugg.book.id) and "open" or "download" }
    end
    local rating = job and job.rating
    if rating == "clear" then rating = nil elseif rating == nil then rating = tonumber(b.summary.rating) end
    return {
        status = job and "✓ Marked as finished" or "Not marked as finished",
        undo = job ~= nil,
        can_mark = job == nil,
        title = d.title or (b.file and b.file:match("([^/]+)$")) or "",
        author = Finish.author(d),
        stars = rating,
        next = card,
        suggestion = s,
    }
end

-- Actions behind the sheet's taps (the widget calls these; the tests call them directly).
EOB.actions = {}

function EOB.actions.undo(ui, b)
    ui.status:markBook(false) -- "Mark as reading": KOReader's own route; our hook drops the job
    EOB.closeSheet()
    UIManager:show(require("ui/widget/infomessage"):new{ text = "Not marked as finished", timeout = 2 }) -- gate: exception (end-of-book sheet)
end

function EOB.actions.mark(ui, b)
    ui.status:markBook(true)
    EOB.refreshSheet(ui, b)
end

function EOB.actions.star(ui, b, n)
    local job = EOB.queue()[b.digest]
    local cur = job and job.rating or tonumber(b.summary.rating)
    if cur == "clear" then cur = nil end
    local summary = b.doc_settings:readSetting("summary") or {}
    if cur == n then summary.rating = nil else summary.rating = n end
    b.doc_settings:saveSetting("summary", summary)
    if job then Finish.setRating(job, n, cur); EOB.save() end
    EOB.refreshSheet(ui, b)
end

function EOB.actions.review(ui)
    EOB.closeSheet()
    if ui.status and ui.status.onShowBookStatus then ui.status:onShowBookStatus() end
end

function EOB.actions.author(ui, b, name)
    EOB.closeSheet()
    EOB.withCatalog(ui, function(cat) cat:loadBooks({ author = name, sort = "series" }, name, true) end)
end

function EOB.actions.back() EOB.closeSheet() end

function EOB.actions.home(ui)
    EOB.leaveForHome(ui)
    if state.module then state.module:onOrbitGoHome() end
end

-- Any Home while the book stays open underneath (BookOrbit home opens over the reader): the
-- sheet closes first, and Home counts as leaving the book, so the finish is sent now rather
-- than whenever the book is finally closed.
function EOB.leaveForHome(ui)
    local had_sheet = EOB.sheet ~= nil
    EOB.closeSheet()
    ui = ui or liveUI()
    if not (ui and ui.document) then return had_sheet end
    local b = EOB.bookOf(ui)
    -- Home is painted over the open book, which has sent nothing yet: its position and status
    -- go into the local overlay first, so the first paint already shows them (item 4).
    if b and LocalState then
        local okp, pct = pcall(b.plugin.getLastPercent, b.plugin)
        local fields = { pending = true, bookId = b.book_id }
        if okp and type(pct) == "number" then fields.percent = math.floor(pct * 1000 + 0.5) / 10 end
        if type(b.summary.status) == "string" then fields.status = b.summary.status end
        pcall(LocalState.put, b.digest, fields)
        pcall(LF.noteOnDevice, b.book_id, ui and ui.document and ui.document.file)
        log("home: noted the open book for Home:", tostring(fields.percent) .. "%", tostring(fields.status))
    end
    local job = b and EOB.queue()[b.digest]
    if job and not job.ready then
        job.ready = true
        EOB.save()
        log("end of book: Home counts as leaving the book; sending the finish now")
        EOB.sendSoon(b.plugin)
    end
    return had_sheet
end

-- Network up, then the plugin's outbox, then our drain (the Sync.waitOutbox hook below).
function EOB.sendSoon(p)
    if not p then return end
    Wifi.acquire("eob_send")
    Net.up(p, { reason = "eob_send", cap = 20, need_server = true }, function(ok)
        if not ok then
            Wifi.release("eob_send")
            log("end of book: no network; the finish goes with the next sync")
            return
        end
        Sync.waitOutbox(p, 20, function() Wifi.release("eob_send") end)
    end)
end

-- Open or download-and-open a book from the sheet (§4 "Download & open").
function EOB.actions.book(ui, b, book_id, title)
    local path = EOB.onDevice(book_id)
    if path then
        EOB.closeSheet()
        return EOB.openBook(ui, path)
    end
    EOB.downloadAndOpen(ui, b, book_id, title)
end

function EOB.openBook(ui, path)
    EOB.onLeave(ui)
    UIManager:nextTick(function() require("apps/reader/readerui"):showReader(path) end)
end

-- The plugin's catalog class with what its download and list code need, without opening the
-- catalog screen: its own download (progress through our reporter), match-check and link.
function EOB.headlessCatalog(p)
    local Catalog = package.loaded["bookorbit_catalog"]
    if type(Catalog) ~= "table" or #Compat.missingOn(Catalog, EOB.CATALOG) > 0 then return nil end
    local cat = setmetatable({ client = p:newClient(), settings = p.settings, plugin = p, ui = p.ui,
        catalog_closed = true, stack = {}, item_table = {} }, { __index = Catalog })
    cat.refreshOnDevice = function() end
    -- false, not nil: the download checks each with "self.x and self:x()" (bookorbit_catalog_download.lua
    -- :291-300), and nil would fall through to the class.
    cat.updateItems, cat.markStackDirty, cat.bookMode, cat.dashboardMode, cat.detailMode = false, false, false, false, false
    cat.detailShowDownloadProgress = false
    return cat
end

-- The catalog screen for the author page: the plugin's own catalog (opened if needed).
function EOB.withCatalog(ui, fn)
    local p = bookorbit(ui)
    if not p then return end
    local cat = p.catalog_browser
    if cat then return fn(cat) end
    pluginEvent(ui, p, "BookOrbitOpenDashboard")
    UIManager:scheduleIn(0.3, function()
        if p.catalog_browser then fn(p.catalog_browser) end
    end)
end

function EOB.downloadAndOpen(ui, b, book_id, title)
    local p = b.plugin
    EOB.setCard(ui, b, book_id, "Connecting…")
    Wifi.acquire("eob_download")
    Net.up(p, { reason = "eob_download", cap = 20, need_server = true }, function(ok)
        if not ok then
            Wifi.release("eob_download")
            return EOB.setCard(ui, b, book_id, nil, "failed")
        end
        -- The finish goes first on this connection (§3: final position -> status).
        EOB.onLeave(ui)
        EOB.drain(p, false, function()
            EOB.download(p, book_id, function(dl_ok, path_or_err)
                Wifi.release("eob_download")
                if not dl_ok then return EOB.setCard(ui, b, book_id, nil, "error", path_or_err) end
                EOB.closeSheet()
                EOB.openBook(ui, path_or_err)
            end, function(text) EOB.setCard(ui, b, book_id, text) end)
        end)
    end)
end

-- Downloads a book through the plugin (detail, then its default file). done(ok, path | err);
-- progress(text) while it runs.
function EOB.download(p, book_id, done, progress)
    local cat = EOB.headlessCatalog(p)
    if not cat then return done(false, "the BookOrbit plugin changed") end
    -- The detail page's Download button's own path: the detail with this reader's delivery variant
    -- (bookorbit_catalog_download.lua:92 fetchDeliveryBook), whose files carry the selection and
    -- the hash of what the server actually streams (server enrichDeliveryFiles). Without the
    -- variant the hash is the source file's and an audio-free rebuild fails it (hash_mismatch).
    local detail, err
    if Compat.callable(cat.fetchDeliveryBook) then detail, err = cat:fetchDeliveryBook(book_id)
    else detail, err = cat.client:catalogBook(book_id) end
    if type(detail) ~= "table" then return done(false, err) end
    -- A file this reader opens (detail supportedFiles :382), the primary one first.
    local files = Compat.callable(cat.supportedFiles) and cat:supportedFiles(detail) or detail.files or {}
    local file
    for _, f in ipairs(files) do if f.role == "primary" then file = f break end end
    file = file or files[1]
    if not file then return done(false, "no file this reader can open") end
    local target
    -- downloadDefaultFile names the file the plugin's way, then hands over to checkDownloadFile.
    cat.checkDownloadFile = function(_self, local_path) target = local_path end
    cat:downloadDefaultFile(detail, file)
    if not target then return done(false, "no download path") end
    local okl, lfs = pcall(require, "libs/libkoreader-lfs")
    if okl and lfs.attributes(target, "mode") == "file" then return done(true, target) end
    local reporter = {
        progress = function(received, total)
            if progress then
                local mb = function(n) return string.format("%.1f", (n or 0) / 1048576) end
                local pct = total and total > 0 and math.floor(100 * (received or 0) / total) or 0
                progress(string.format("Downloading %d%% · %s of %s MB", pct, mb(received), mb(total)))
            end
        end,
        finished = function(ok, ferr, path) done(ok, ok and (path or target) or ferr) end,
    }
    cat:downloadFile(target, detail, file, reporter)
end

-- The card's state while downloading: text (progress), or a failure: "failed" (couldn't connect:
-- Try again / Get it at the next sync), "error" (the server said no: Try again).
function EOB.setCard(ui, b, book_id, text, failure, err)
    EOB.card_state = { book_id = book_id, text = text, failure = failure, err = err }
    if failure then log("end of book: download", failure, tostring(err or "")) end
    EOB.refreshSheet(ui, b)
end

function EOB.actions.retry(ui, b, book_id, title) EOB.downloadAndOpen(ui, b, book_id, title) end

function EOB.actions.later(ui, b, book_id, title)
    EOB.downloads()[tostring(book_id)] = { book_id = book_id, title = title, at = os.time() }
    EOB.save()
    EOB.card_state = nil
    EOB.closeSheet()
    UIManager:show(require("ui/widget/infomessage"):new{ text = "It downloads at the next sync", timeout = 2 }) -- gate: exception (end-of-book sheet)
end

function EOB.showSheet(ui, b)
    EOB.closeSheet()
    EOB.card_state = nil
    EOB.sheet = EndSheet:new{ ui = ui, book = b, model = EOB.model(b) }
    UIManager:show(EOB.sheet) -- gate: exception (the reader reached the end)
    log("end of book: sheet shown for", b.book_id)
end

function EOB.refreshSheet(ui, b)
    if not EOB.sheet then return end
    EOB.sheet:update(EOB.model(b), EOB.card_state)
end

function EOB.closeSheet()
    if EOB.sheet then
        local s = EOB.sheet
        EOB.sheet = nil
        UIManager:close(s)
    end
end

---------------------------------------------------------------- sending (§3)

-- After the plugin's outbox: every ready job, then wanted downloads, then the open book's detail
-- for the sheet. Runs only with the network up (Sync.waitOutbox's callers bring it up).
function EOB.drain(p, manual, done)
    done = done or function() end
    -- Outbox waits also complete during reading. These finish/detail operations
    -- include synchronous catalog calls and file writes: wait for the next lifecycle
    -- sync outside reading, rather than running them on a page's input loop.
    if reading() then return done() end
    if not EOB.usable(p) then return done() end
    local m = EOB.mods()
    local client = p:newClient()
    local now = os.time()
    local sent = 0
    for _, job in ipairs(Finish.due(EOB.queue(), now, manual)) do
        if job.ready then
            local r = EOB.sendJob(p, m, client, job, now)
            if r == "sent" or r == "drop" then EOB.queue()[job.hash] = nil; sent = sent + 1 end
            if r == "auth" then
                UIManager:show(require("ui/widget/infomessage"):new{ text = "Sign in to BookOrbit to send", timeout = 3 }) -- gate: exception (end-of-book sheet)
                break
            end
        end
    end
    EOB.save()
    if sent > 0 and EOB.sheet then
        UIManager:show(require("ui/widget/infomessage"):new{ text = "Finished · sent", timeout = 2 }) -- gate: exception (end-of-book sheet)
    end
    EOB.refreshOpenDetail(p, client)
    EOB.pendingDownloads(p, done)
end

-- One job: guard read -> read-status -> rating -> write back. "sent" | "retry" | "auth" | "drop".
function EOB.sendJob(p, m, client, job, now)
    local function fail(code, step)
        local what = Finish.onError(job, code, now)
        log("end of book:", step, "failed (" .. tostring(code) .. ") ->", what, job.parked and "(parked)" or "")
        return what
    end
    if not job.book_id then
        -- No server id: the plugin's book-states from the summary carry it (§3 "No book_id").
        log("end of book: no book id; the plugin's own state sync carries the finish")
        return "sent"
    end
    local detail, err = client:catalogBook(job.book_id)
    if type(detail) ~= "table" then return fail(err, "guard read") end
    EOB.remember(detail)
    local plan = Finish.plan(job, detail.readStatus)
    if plan.read_status then
        local okr, rerr = client:catalogSetReadStatus(job.book_id, "read")
        if not okr then return fail(rerr, "read-status") end
    else
        log("end of book: read-status skipped:", plan.reason)
    end
    if plan.rating ~= nil then
        local okt, terr = client:catalogSetRating(job.book_id, plan.rating ~= "clear" and plan.rating or nil)
        if not okt then return fail(terr, "rating") end
    end
    EOB.writeBack(p, m, job, plan)
    log("end of book: sent", job.book_id, plan.read_status and "read" or "(status kept)",
        plan.rating ~= nil and ("rating " .. tostring(plan.rating)) or "")
    if LocalState then LocalState.noteSent(job.hash) end
    return "sent"
end

-- Step 6: the server's new state into KOReader's summary and the plugin's synced state, so the
-- plugin's next state pull keeps it (server S7).
function EOB.writeBack(p, m, job, plan)
    local st = { status_known = plan.read_status, status = plan.read_status and "complete" or nil,
        status_modified = job.finished_on or os.date("%Y-%m-%d"),
        rating_known = plan.rating ~= nil, rating = (plan.rating ~= "clear") and plan.rating or nil }
    pcall(function()
        local ui = p.ui
        if ui and ui.document and ui.document.file == job.file then
            m.sidecar.applyServerStateLive(ui, st)
        elseif job.file then
            m.sidecar.applyServerStateSidecar(job.file, st)
        end
    end)
    local okw, werr = pcall(m.state.mutate, function(session)
        local book = session:getBook(job.hash)
        if book then m.sidecar.rememberServerState(book, st) end
    end)
    if not okw then log("end of book: write back failed:", werr) end
end

-- The open book's detail for the sheet (written when online, so the sheet never waits).
function EOB.refreshOpenDetail(p, client)
    local b = EOB.bookOf(liveUI())
    if not b or not b.book_id then return end
    local cached = EOB.cache()[tostring(b.book_id)]
    if cached and os.time() - (cached.saved_at or 0) < 600 then return end
    local detail = client:catalogBook(b.book_id)
    if type(detail) == "table" then EOB.remember(detail) end
end

-- "Get it at the next sync": downloads asked for while out of range, announced by a toast.
function EOB.pendingDownloads(p, done)
    local list = {}
    for k, v in pairs(EOB.downloads()) do table.insert(list, { k = k, v = v }) end
    local function nextOne(i)
        local it = list[i]
        if not it then return done() end
        EOB.download(p, it.v.book_id, function(ok, res)
            if ok then
                EOB.downloads()[it.k] = nil
                EOB.save()
                local title = tostring(it.v.title or "")
                Gate.show("downloaded " .. title, function() -- gate: Gate.show
                    UIManager:show(require("ui/widget/infomessage"):new{ text = "Downloaded: " .. title, timeout = 3 })
                end)
            else
                log("end of book: next-sync download failed:", tostring(res))
            end
            nextOne(i + 1)
        end)
    end
    nextOne(1)
end

---------------------------------------------------------------- stale-push hold (§7)

-- A push of this book's position should wait: finished here, and 10+ points below the end
-- with fewer than 10 page turns forward this session.
function EOB.hold(digest, fraction, summary_status)
    if summary_status ~= "complete" or type(fraction) ~= "number" then return false end
    local job = EOB.queue()[digest]
    local final = job and job.final_pos and tonumber(job.final_pos.percentage) or 1
    local s = EOB.session[digest] or {}
    return Finish.holdPush(final * 100, fraction * 100, s.forward, s.released)
end

function EOB.installPluginHooks(p)
    if EOB.plugin_hooked or not EOB.usable(p) then return end
    local Cls = getmetatable(p) and getmetatable(p).__index
    if type(Cls) ~= "table" or #Compat.missingOn(Cls, { enqueueLifecycleSnapshot = "function", updateProgress = "function" }) > 0 then
        return
    end
    EOB.plugin_hooked = true
    wrap(Cls, "enqueueLifecycleSnapshot", function(stock) return function(self, snap, reason)
        if type(snap) == "table" and EOB.hold(snap.digest, snap.percentage, snap.status) then
            log("end of book: holding a stale position for a finished book (" .. tostring(reason) .. ")")
            snap.percentage, snap.progress = nil, nil
        end
        if LocalState and type(snap) == "table" then pcall(LocalState.noteSnapshot, snap) end
        return stock(self, snap, reason)
    end end, "eob")
    local function liveHold(self)
        local b = EOB.bookOf(self.ui)
        if not b then return false end
        local okp, pct = pcall(self.getLastPercent, self)
        if okp and EOB.hold(b.digest, pct, b.summary.status) then
            log("end of book: holding a stale live push for a finished book")
            return true
        end
        return false
    end
    for _, name in ipairs({ "updateProgress", "pushProgressAfterBookSync" }) do
        if Compat.callable(Cls[name]) then
            wrap(Cls, name, function(stock) return function(self, ...)
                if liveHold(self) then return end
                return stock(self, ...)
            end end, "eob")
        end
    end
end

-- Page turns forward this session release the hold (§7).
function EOB.onPage(ui, page)
    local b = ui and EOB.page_digests[ui]
    if not b or not ui.document or b.file ~= ui.document.file then return end
    local s = EOB.session[b.digest] or { forward = 0 }
    EOB.session[b.digest] = s
    if s.last and page > s.last then s.forward = (s.forward or 0) + 1 end
    s.last = page
end

---------------------------------------------------------------- wiring

-- The finish drain follows every outbox wait that went well (wake, open, reading, sleep).
do
    local stockWait = Sync.waitOutbox
    function Sync.waitOutbox(p, cap, cb)
        return stockWait(p, cap, function(ok, why, el)
            if not ok then return cb(ok, why, el) end
            local okd, err = pcall(EOB.drain, p, false, function() cb(ok, why, el) end)
            if not okd then log("end of book: drain failed:", err); cb(ok, why, el) end
        end)
    end
end

do
    local base_close = OrbitAndroid.onCloseWidget
    function OrbitAndroid:onCloseWidget(...)
        if self.ui and self.ui.document then pcall(EOB.onLeave, self.ui) end
        EOB.closeSheet()
        return base_close(self, ...)
    end
    local base_suspend = OrbitAndroid.onSuspend
    function OrbitAndroid:onSuspend(...)
        if self.ui and self.ui.document then pcall(EOB.onLeave, self.ui) end
        return base_suspend(self, ...)
    end
    local base_page = OrbitAndroid.onPageUpdate
    function OrbitAndroid:onPageUpdate(page, ...)
        if type(page) == "number" then pcall(EOB.onPage, self.ui, page) end
        return base_page(self, page, ...)
    end
    local base_ready = OrbitAndroid.onReaderReady
    function OrbitAndroid:onReaderReady(...)
        local p = bookorbit(self.ui)
        if p then pcall(EOB.installPluginHooks, p) end
        pcall(EOB.bookOf, self.ui) -- prime the digest once; page turns never read plugin state
        return base_ready(self, ...)
    end
end
EOB.installReaderHooks()

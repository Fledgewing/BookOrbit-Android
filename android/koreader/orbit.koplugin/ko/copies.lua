-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Keep book copies current (v0.11.1, docs/design/keep-copies-current.md). A copy whose library
-- file changed on the server (BookOrbit writes metadata into the file, so its hash moves) is
-- downloaded again in the background, through the plugin's own Download path (delivery variant,
-- hash checked, atomic rename), to the same path. Its KOReader sidecar stays: the path is the
-- same, the text unchanged, so positions, highlights and bookmarks still fit. What KOReader and
-- BookOrbit key by the file's hash moves to the new hash. Only online, never while reading, one
-- book at a time, from a queue kept on disk.

Copies = {}

local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")

local function index()
    local st = OC.state()
    st.copies = st.copies or { queue = {} }
    st.copies.queue = st.copies.queue or {}
    return st.copies
end
Copies.state = index

Copies.WAIT_S = 60
-- Replacements are numbered, so an answer to an ask made before one doesn't queue it again.
Copies.seq, Copies.done_seq = 0, {}

local function stateManager()
    local sm = package.loaded["bookorbit_state_manager"]
    if type(sm) == "table" and type(sm.state) == "function" then return sm end
end

local function openFile()
    local ui = liveUI()
    return ui and ui.document and ui.document.file or nil
end

-- The companion writes copies/ask.lua; KOReader sends only in-memory state.
-- Asks Orbit Companion which copies changed (COPIES, docs/design/companion-worker.md). The ask
-- is small and comes from memory: BookOrbit's state books, the end-of-book cache's file lists,
-- and how the mirror names a book's detail; the companion reads the saved details (the cache's
-- and the mirror's), compares the hashes and checks the files are on the reader. Returns true
-- when asked.
function Copies.ask(why)
    if S.keep_copies_current == false then return false end
    if Copies.asked and OC.now() - Copies.asked < Copies.WAIT_S then return false end
    local problem = Companion.workerProblem(_("to keep copies current"))
    if problem then
        if Copies.problem ~= problem then Copies.problem = problem; log("copies: not checked:", problem) end
        return false
    end
    Copies.problem = nil
    local sm = stateManager()
    if not sm then return false end
    local okb, books = pcall(function() local st = sm.state(); return st and st.books end)
    if not okb or type(books) ~= "table" then return false end
    local list, want = {}, {}
    for md5, b in pairs(books) do
        if type(b) == "table" and type(b.file) == "string" and b.bookId ~= nil then
            table.insert(list, { md5 = md5, path = b.file, book_id = b.bookId, file_id = b.fileId, incompatible = b.positionIncompatible == true })
            want[tostring(b.bookId)] = true
        end
    end
    local eob = {}
    local okc, c = pcall(EOB.cache)
    for id, v in pairs(okc and type(c) == "table" and c or {}) do
        if want[tostring(id)] and type(v) == "table" and type(v.files) == "table" then eob[tostring(id)] = { files = v.files, saved_at = v.saved_at } end
    end
    local ask = { books = list, eob = eob, sentinel = Mirror.SENTINEL }
    local client = OC.client()
    -- How the mirror names a book's detail (its saved details count too).
    local okp, path = pcall(function() return client and Mirror.detailPath(client, Mirror.SENTINEL) end)
    if okp and path then ask.owner, ask.server, ask.detail_template = OC.owner(client), client.server_url, path end
    Copies.asked, Copies.asked_seq = OC.now(), Copies.seq
    Companion.send(Companion.ACTION.COPIES, { reason = tostring(why), ask = Cache.encode(ask) })
    OC.watchChecks()
    return true
end

-- The companion's answer: the changed copies join the queue, which then runs when it may.
function Copies.found(ev)
    local asked = Copies.asked_seq or 0
    Copies.asked = nil
    if ev.err then return log("copies: not checked:", tostring(ev.err)) end
    local c = index()
    -- A copy replaced while the companion looked was looked up with its old hash.
    local fresh = {}
    for _, f in ipairs(type(ev.found) == "table" and ev.found or {}) do
        if (Copies.done_seq[f.path] or 0) <= asked then table.insert(fresh, f) end
    end
    local added = CopiesPlan.enqueue(c.queue, fresh)
    local n = ev.checked or 0
    if added > 0 then
        log(string.format("copies: checked %d copies (%s); %d changed; replacing", n, tostring(ev.why), #c.queue))
        OC.saveState()
    elseif #c.queue == 0 then
        log(string.format("copies: checked %d copies (%s); %s", n, tostring(ev.why),
            (ev.gone or 0) == 0 and "all match the library" or "the changed ones are gone from the reader"))
    end
    if #c.queue > 0 and not Copies.busy and not Copies.active then Copies.pump() end
end

function Copies.stop(why)
    if Copies.active then
        log("copies: paused (" .. why .. "),", #index().queue, "left; it resumes later")
        Wifi.release("copies")
    end
    Copies.active = nil
end

local function finish()
    if Copies.active then
        log("copies: done;", Copies.replaced or 0, "replaced,", Copies.failed or 0, "failed")
        Wifi.release("copies")
    end
    Copies.active, Copies.replaced, Copies.failed = nil, nil, nil
end

-- After the new file is in place: the sidecar's stored hash, KOReader's hash-keyed folder and
-- statistics, and BookOrbit's state (repairFileIdentity: the plugin's own path for a file whose
-- bytes changed, bookorbit_state_manager.lua:453).
function Copies.carry(path, old, new)
    if not Companion.workerProblem() then
        Companion.send(Companion.ACTION.PATCH, { reason = "copy identity", old_hash = old, new_hash = new, copy_path = path })
    end
    local sm = stateManager()
    if sm and type(sm.repairFileIdentity) == "function" then
        local okr, err = pcall(sm.repairFileIdentity, path, old, new)
        if not okr then log("copies: state repair failed:", tostring(err)) end
    end
end

local function nextJob(c, outcome, job, detail)
    table.remove(c.queue, 1)
    OC.saveState()
    log("copies:", outcome, tostring(job.path), detail or "")
    UIManager:scheduleIn(1, Copies.pump)
end

function Copies.pump()
    if Copies.busy then return end
    local c = index()
    local job = c.queue[1]
    if not job then return finish() end
    if S.keep_copies_current == false then return Copies.stop("turned off") end
    if reading() then return Copies.stop("reading") end
    if not NetworkMgr:isConnected() then return Copies.stop("offline") end
    if openFile() == job.path then
        -- The open book is never replaced under the reader: it goes last, and waits for its close.
        if #c.queue == 1 then return Copies.stop("the book is open") end
        table.remove(c.queue, 1); table.insert(c.queue, job)
        return UIManager:nextTick(Copies.pump)
    end
    local p = bookorbit(liveUI())
    local cat = p and EOB.headlessCatalog(p)
    if not cat then return Copies.stop("no BookOrbit plugin") end
    if not Copies.active then
        Copies.active = true
        Wifi.acquire("copies")
        log("copies: running;", #c.queue, "to go; Wi-Fi held until it ends")
    end
    Copies.busy = true
    local client = cat.client
    local Delivery = require("bookorbit_delivery")
    local template = client:query("/koreader/plugin/catalog/books/" .. Mirror.SENTINEL,
        { deviceId = client.device_id, variant = Delivery.preference(cat.settings or {}, client) })
    Copies.preparing, Copies.prepare_at = job, OC.now()
    Companion.send(Companion.ACTION.COPIES, { reason = "prepare replacement", prepare = Cache.encode(job),
        template = template, server = client.server_url, user = client.username, userkey = client.userkey })
    OC.watchChecks()
end

function Copies.prepared(ev)
    local job = Copies.preparing
    if not job or ev.path ~= job.path then return end
    Copies.preparing, Copies.prepare_at = nil, nil
    local c = index()
    if c.queue[1] ~= job then Copies.busy = nil; return end
    local p = bookorbit(liveUI())
    local cat = p and EOB.headlessCatalog(p)
    local detail = ev.detail
    if not cat or reading() or openFile() == job.path then
        Copies.busy = nil
        return Copies.stop("reading or catalog closed")
    end
    if type(detail) ~= "table" then
        Copies.busy = nil
        Copies.failed = (Copies.failed or 0) + 1
        return nextJob(c, "could not prepare the book;", job, tostring(ev.err))
    end
    local files = Compat.callable(cat.supportedFiles) and cat:supportedFiles(detail) or detail.files or {}
    local file = CopiesPlan.pick(files, job.file_id)
    local old = ev.md5 or job.md5
    local act = CopiesPlan.decide(old, file)
    if act ~= "replace" then
        Copies.busy = nil
        return nextJob(c, act == "same" and "already current:" or "no hash to check against; left as is:", job)
    end
    local t0 = now_s()
    cat:downloadFile(job.path, detail, file, {
        progress = function() end,
        finished = function(ok, ferr)
            Copies.busy = nil
            if not ok then
                Copies.failed = (Copies.failed or 0) + 1
                return nextJob(c, "replace failed (" .. tostring(ferr) .. "); the old copy stays:", job)
            end
            local new = file.fileHash -- downloadFile already verifies the delivered artifact hash
            Copies.carry(job.path, old, new)
            Copies.replaced = (Copies.replaced or 0) + 1
            Copies.seq = Copies.seq + 1
            Copies.done_seq[job.path] = Copies.seq
            nextJob(c, "replaced", job, string.format("(%s -> %s, %ds; sidecar kept)", tostring(old), tostring(new), now_s() - t0))
        end,
    })
end

-- Online and not reading: find changed copies (at most every 10 min) and work the queue.
function Copies.tick(why)
    if S.keep_copies_current == false or Copies.busy or Copies.active then return end
    if reading() or not NetworkMgr:isConnected() then
        if why == "full refresh" then log("copies: check waits (" .. (reading() and "reading" or "offline") .. ")") end
        return
    end
    local t = now_s()
    if not Copies.scanned_at or t - Copies.scanned_at > 600 or why == "full refresh" then
        if Copies.ask(why) then Copies.scanned_at = t end
    end
    if #index().queue > 0 then Copies.pump() end
end

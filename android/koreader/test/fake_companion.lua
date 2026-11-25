-- The Orbit Companion's cache worker, played by the flow tests (the real one is
-- android/companion/.../CacheWorker.kt, tested in CacheWorkerTest against the same rules and
-- shared/fixtures/cache/). It answers the plugin's MIRROR, CHECK, PATCH, STORAGE and COPIES
-- broadcasts the way the companion does: what it saves goes into orbit.db (through fake_store.lua,
-- the same saves as CacheStore), its progress into mirror/status.lua and summary.lua, its answers
-- into events/<n>.lua. A Full refresh is a set of jobs, each book's detail and cover once,
-- `rate` jobs a second on the tests' fake clock, so a test sees a run that spans many of the
-- plugin's polls. It is test code: nothing of it ships.

local F = { rate = 1000, step_s = 1, PAGE = 100 }

local E, W, fetch, UIManager
local here = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".")
local function C() return E.Cache end
-- The companion's own rules (the plugin no longer has them).
local makeRules, rules, rulesFor = dofile(here .. "/companion_rules.lua"), nil, nil
local function R()
    if rulesFor ~= C() then rules, rulesFor = makeRules(C()), C() end
    return rules
end
local function dir() return E.OC.dir() end
local function mdir() return dir() .. "/mirror" end
local function readFile(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function writeFile(p, s) local f = io.open(p, "wb"); if not f then return false end f:write(s); f:close(); return true end
local function load(p) local v = C().decode(readFile(p) or ""); return type(v) == "table" and v or nil end
local function now() return math.floor(W.clock) end

function F.install(env, world, fetcher, ui)
    E, W, fetch, UIManager = env, world, fetcher, ui
    F.rate, F.runs, F.calls, F.checks, F.creds, F.running, F.cover_bytes = 1000, 0, {}, 0, {}, nil, nil
    F.closeDb()
    F.run = nil
end

---------------------------------------------------------------- the database (CacheStore)

function F.dbPath() return dir() .. "/orbit.db" end

-- The companion's connection, opened (and the schema made) on first use, again for another file.
function F.db()
    local p = F.dbPath()
    if F._st and F._st_path == p and readFile(p) then return F._st end
    F.closeDb()
    if not F.FakeStore then
        F.FakeStore = dofile(here .. "/fake_store.lua")(C(), require("lua-ljsqlite3/init"), here .. "/../../../shared/fixtures/cache/schema.sql")
    end
    require("libs/libkoreader-lfs").mkdir(dir())
    F._st, F._st_path = F.FakeStore.open(p), p
    return F._st
end

function F.closeDb()
    if F._st then pcall(F._st.close, F._st) end
    F._st, F._st_path = nil, nil
end

local function rows(sql, ...) return F.db():run(sql, ...) end
local function one(sql, ...) local r = rows(sql, ...)[1]; return r and r[1] end
local function val(v) return E.Db.value(v) end

function F.meta(k) return val(one("SELECT v FROM meta WHERE k = ?", k)) end
function F.setMeta(k, v)
    if v == nil then rows("DELETE FROM meta WHERE k = ?", k) else rows("INSERT OR REPLACE INTO meta (k, v) VALUES (?, ?)", k, v) end
end

local TABLES = { "meta", "books", "lists", "list_items", "entries", "cover_keep", "tags", "scopes", "leave_out", "jobs" }
function F.wipe()
    local st = F.db()
    st:begin()
    for _, t in ipairs(TABLES) do rows("DELETE FROM " .. t) end
    st:commit()
    F.run = nil
end

-- CacheStore.own: another owner clears everything first.
function F.own(owner)
    local was = F.meta("owner")
    if was == owner then return end
    if was ~= nil then F.wipe() end
    F.setMeta("owner", owner)
end

local function decodeRow(v) local s = val(v); return type(s) == "string" and C().decode(s) or nil end
function F.bookItem(id) return decodeRow(one("SELECT item FROM books WHERE id = ?", id)) end
function F.detail(id)
    local r = rows("SELECT detail, detail_at FROM books WHERE id = ? AND detail IS NOT NULL", id)[1]
    return r and decodeRow(r[1]), r and tonumber(val(r[2]))
end
function F.count(sql, ...) return tonumber(val(one(sql, ...))) or 0 end

-- A saved window's items (the change check of a recheck), as stored.
local function windowDigest(identity, start, stop)
    local out = {}
    for _, r in ipairs(rows("SELECT li.pos, COALESCE(b.item, li.item) FROM list_items li LEFT JOIN books b ON b.id = li.book_id WHERE li.identity = ? AND li.pos >= ? AND li.pos < ? ORDER BY li.pos", identity, start, stop)) do
        table.insert(out, tostring(val(r[1])) .. "=" .. tostring(val(r[2])))
    end
    return table.concat(out, "\n")
end

---------------------------------------------------------------- the run (CacheWorker.run)

local ORDER = { page = 0, recheck = 1, detail = 2, cover = 3 }
local function jobId(j) return j.kind .. "|" .. (j.id and tostring(j.id) or (j.page .. "|" .. j.size .. "|" .. j.identity)) end

local function addJob(run, j)
    local id = jobId(j)
    if run.seen[id] then return end
    run.seen[id] = true
    j.state, j.tries, j.n = 0, 0, run.n
    run.n = run.n + 1
    table.insert(run.jobs, j)
end
local function pageJob(kind, identity, page, size) return { kind = kind, identity = identity, page = page, size = size or F.PAGE } end
local function addList(run, path, kind)
    local w = path and C().listWindow(path)
    if w then addJob(run, pageJob(kind or "page", w.identity, 1)) end
end

local function nextJob(run)
    local best
    for _, j in ipairs(run.jobs) do
        if j.state == 0 and (not best or ORDER[j.kind] < ORDER[best.kind] or (ORDER[j.kind] == ORDER[best.kind] and j.n < best.n)) then best = j end
    end
    return best
end

local function fill(t, sentinel, value)
    local v = tostring(value):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end)
    return (t:gsub(sentinel, (v:gsub("%%", "%%%%"))))
end

local function seed(run, plan)
    addList(run, plan.all_books)
    for _, p in ipairs(plan.seed_lists or {}) do addList(run, p) end
    for _, p in ipairs(plan.sections or {}) do addList(run, p) end
    local ids = {}
    for _, r in ipairs(rows("SELECT identity FROM lists ORDER BY identity")) do addList(run, val(r[1])) end
    for _, id in ipairs(plan.seed_details or {}) do ids[tonumber(id)] = true end
    for _, r in ipairs(rows("SELECT body FROM entries WHERE home = 1")) do
        local body = decodeRow(r[1]) or {}
        for _, f in ipairs({ "continueReading", "items", "books" }) do
            for _, b in ipairs(type(body[f]) == "table" and body[f] or {}) do if tonumber(b.id) then ids[tonumber(b.id)] = true end end
        end
    end
    local sorted = {}
    for id in pairs(ids) do table.insert(sorted, id) end
    table.sort(sorted)
    for _, id in ipairs(sorted) do
        addJob(run, { kind = "detail", id = id })
        if plan.covers_on then addJob(run, { kind = "cover", id = id }) end
    end
end

local function listTotal(identity) local t = one("SELECT total FROM lists WHERE identity = ?", identity); return t and tonumber(val(t)) end

local function estimate(run, plan)
    local w = plan.all_books and C().listWindow(plan.all_books)
    local books = w and listTotal(w.identity)
    if not books then return 0 end
    local est = C().pageCount(books) + books + (plan.covers_on and books or 0)
    for _, s in ipairs(plan.sections or {}) do
        local sw = C().listWindow(s)
        local n = sw and listTotal(sw.identity)
        if not n then return 0 end
        est = est + C().pageCount(n) + n
    end
    return est
end

local function recount(run, plan, finished)
    local total, done, covers = 0, 0, 0
    for _, j in ipairs(run.jobs) do
        total = total + 1
        if j.state ~= 0 then done = done + 1 end
        if j.kind == "cover" then covers = covers + 1 end
    end
    run.total, run.done, run.cover_total = total, done, covers
    if (run.estimate or 0) == 0 and run.op == "full" then run.estimate = estimate(run, plan) end
    local t = math.max(total, run.estimate or 0)
    local pct = finished and 100 or (t == 0 and 0 or math.min(99, math.floor(done * 100 / t)))
    run.pct = math.max(run.pct or 0, pct)
end

local function coverPath(plan, book)
    if not plan.cover_dir or type(book) ~= "table" or book.hasCover ~= true then return nil end
    local name = R().coverName(book)
    return name and (plan.cover_dir .. "/" .. name), name
end

local function doCover(run, plan, j, out)
    local book = F.bookItem(j.id)
    local path, name = coverPath(plan, book)
    if not path then return end
    local exists = readFile(path) ~= nil
    local etag = readFile(path .. ".etag")
    if exists and not etag then return "kept", name end
    table.insert(F.calls, "COVER " .. j.id)
    local r = F.cover and F.cover({ id = j.id, path = path, updatedAt = book.updatedAt }, etag) or (etag and 304 or 200)
    if r == 304 and exists then run.covers.not_modified = run.covers.not_modified + 1; return "not_modified", name end
    if r == 200 then
        writeFile(path, "\255\216\255\224fakejpeg"); writeFile(path .. ".etag", '"e"')
        run.covers.ok, run.covers.bytes = run.covers.ok + 1, run.covers.bytes + (F.cover_bytes or 12)
        table.insert(out.written, { id = j.id, updatedAt = book.updatedAt })
        return "ok", name
    end
    run.covers.failed = run.covers.failed + 1
end

local function landPage(run, plan, j, body, out)
    local t = now()
    run.requests = run.requests + 1
    local st = F.db()
    if j.kind == "detail" then
        st:putDetail(j.id, body, t)
        local mine = tonumber(body.seriesIndex) or 0
        for _, m in ipairs(type(body.seriesMembers) == "table" and body.seriesMembers or {}) do
            local id = tonumber(m.id)
            if id and id ~= j.id and m.readStatus ~= "read" and (tonumber(m.seriesIndex) or 0) > mine then
                addJob(run, { kind = "detail", id = id }); break
            end
        end
        return
    end
    local w = C().listWindow(j.identity)
    local recheck = j.kind == "recheck"
    local old_total = j.page == 1 and listTotal(w.identity) or nil
    local start = (j.page - 1) * j.size
    local before = recheck and windowDigest(w.identity, start, start + j.size)
    st:putWindow(w.identity, w.kind, w.section, start, body, t)
    local changed = recheck and before ~= windowDigest(w.identity, start, start + j.size)
    local total = tonumber(body.total) or 0
    if j.page == 1 and (not recheck or old_total ~= total) then
        for n = 2, C().pageCount(total, j.size) do addJob(run, pageJob(j.kind, w.identity, n, j.size)) end
    end
    if w.kind == "section" then
        local tm = (plan.templates or {})[w.section] or {}
        for _, e in ipairs(body.items or {}) do
            local p
            if w.section == "series" and e.seriesId and tm.path then p = fill(tm.path, plan.sentinel, e.seriesId)
            elseif w.section == "series" and tm.series_name_path then p = fill(tm.series_name_path, plan.sentinel, e.id)
            elseif tm.path and e.id ~= nil then p = fill(tm.path, plan.sentinel, e.id) end
            addList(run, p, j.kind)
        end
    elseif not recheck or changed then
        for _, b in ipairs(body.items or {}) do
            local id = type(b) == "table" and tonumber(b.id)
            if id then
                if not recheck or not F.detail(id) then addJob(run, { kind = "detail", id = id }) end
                if plan.covers_on then addJob(run, { kind = "cover", id = id }) end
            end
        end
    end
    if changed and #out.changed < 50 then table.insert(out.changed, w.identity) end
end

local function storageUsed(plan)
    local n = 0
    for _, e in ipairs(F.storageItems(plan.cover_dir, plan.covers_on)) do n = n + e.bytes end
    return n
end

-- CacheWorker.limited: over the limit, the covers stop, then the run.
local function limited(run, plan, j)
    local limit = plan.limit
    if not limit or limit <= 0 then return false end
    local covers = j.kind == "cover"
    if covers and not plan.covers_on then return false end
    -- What was stored at the run's start, plus the covers it saved since (CacheWorker.limited).
    if (run.base or 0) + run.covers.bytes < limit then return false end
    if run.limit_note and not covers then return true end
    local text
    if covers then
        for _, x in ipairs(run.jobs) do if x.kind == "cover" and x.state == 0 then x.state = 2; run.skipped = run.skipped + 1 end end
        text = R().limitText("covers", run.covers.ok + run.covers.not_modified, run.cover_total)
    else
        for _, x in ipairs(run.jobs) do if x.state == 0 then x.state = 2 end end
        text = R().limitText("lists", run.done, run.total)
    end
    run.limit_note = { text = text, at = now(), limit = limit }
    return true
end

-- One job, retried like CacheWorker (no waits on the fake clock). -> true: no answer.
local function doJob(run, plan, j, out)
    if j.kind == "cover" then
        local outcome, name = doCover(run, plan, j, out)
        if plan.covers_on and name and outcome then rows("INSERT OR IGNORE INTO cover_keep (name) VALUES (?)", name) end
        j.state = 1
        return false
    end
    while true do
        local path = (j.kind == "detail") and fill(plan.detail_template, plan.sentinel, j.id) or R().mirrorPage(j.identity, j.page, j.size ~= F.PAGE and j.size or nil)
        table.insert(F.calls, "GET " .. path)
        local b, e = fetch(path)
        if type(b) == "table" then
            j.state = 1
            landPage(run, plan, j, b, out)
            return false
        end
        j.tries = j.tries + 1
        local status = tonumber(e)
        local r = (status and status < 500) and { skip = true } or R().mirrorRetry(j.tries, j.kind ~= "detail" and j.size or nil, j.page)
        if r.skip then
            run.skipped = run.skipped + 1; j.state = 2
            return not status
        end
        if r.size and j.kind ~= "detail" and r.size ~= j.size then
            j.state = 2
            local s = pageJob(j.kind, j.identity, 1, r.size)
            addJob(run, s)
            s.tries = j.tries
            j = s
        end
    end
end

local function status(run, plan, running, why)
    local left = math.max(0, (run.total or 0) - (run.done or 0))
    return { v = 4, runner = "fake companion", run = plan.run, running = running or nil, beat = now(), op = run.op,
        at = tonumber(F.meta("full_at")), lib_version = F.meta("lib_version"), done = run.done, total = run.total, left = left,
        pct = run.pct, skipped = run.skipped, errors = 0, covers = run.covers, cover_total = run.cover_total,
        limit_note = run.limit_note, revalidating = (run.op == "revalidate" and running) or nil,
        started_at = run.started_at, why = why }
end

local function summary(plan, why, run, out, jobs)
    writeFile(mdir() .. "/summary.lua", C().encode({ run = plan.run, why = why, jobs = jobs, status = status(run, plan, false, why),
        changed = out.changed, written = out.written, saved = out.saved, revalidated = out.revalidated,
        cover_bytes_delta = run.covers.bytes }))
end

local function newRun(op)
    return { op = op, jobs = {}, seen = {}, n = 0, done = 0, total = 0, skipped = 0, requests = 0, cover_total = 0, pct = 0,
        covers = { ok = 0, not_modified = 0, failed = 0, bytes = 0 }, started_at = now() }
end

local function pending(run)
    for _, j in ipairs(run.jobs) do if j.state == 0 then return true end end
    return false
end

-- The run as the companion keeps it (its jobs table): read by tests.
function F.state() return F.run end

function F.mirror(extras)
    local plan = load(mdir() .. "/plan.lua")
    assert(plan, "fake companion: no plan")
    F.runs, F.server, F.plan = F.runs + 1, extras.server, plan
    F.creds = { server = extras.server, user = extras.user, userkey = extras.userkey }
    local st = F.db()
    F.own(plan.owner)
    if plan.detail_template then F.setMeta("detail_template", plan.detail_template) end
    local run = F.run
    if plan.op == "full" then
        run = newRun("full")
        seed(run, plan)
    elseif plan.op == "incremental" then
        run = newRun("incremental") -- incremental request/selection is covered by CacheWorkerTest
    elseif plan.op == "revalidate" then
        if not F.meta("full_at") or (run and pending(run)) then
            local r = run or newRun("revalidate")
            writeFile(mdir() .. "/status.lua", C().encode(status(r, plan)))
            summary(plan, "busy", r, { changed = {}, written = {} }, 0)
            return
        end
        run = newRun("revalidate")
        for _, r in ipairs(rows("SELECT identity, total FROM lists ORDER BY identity")) do
            for n = 1, C().pageCount(tonumber(val(r[2])) or 0) do addJob(run, pageJob("recheck", val(r[1]), n)) end
        end
    elseif plan.op == "covers" then
        if not (run and pending(run)) then run = newRun("covers") end
        for _, r in ipairs(rows("SELECT id FROM books WHERE item IS NOT NULL ORDER BY id")) do addJob(run, { kind = "cover", id = tonumber(val(r[1])) }) end
    else
        run = run or newRun("resume")
    end
    F.run = run
    run.covers.bytes = 0
    run.base = plan.limit and storageUsed(plan) or 0
    run.limit_note = nil
    local out, jobs = { changed = {}, written = {} }, 0
    F.running, F.transport, F.trace = plan.run, 0, {}
    recount(run, plan, false)
    writeFile(mdir() .. "/status.lua", C().encode(status(run, plan, true)))
    local function step()
        W.in_companion = true
        local okr, err = pcall(F.step, run, plan, out, function() return jobs end, function(n) jobs = n end, step)
        W.in_companion = nil
        if not okr then error(err, 0) end
    end
    UIManager:scheduleIn(F.step_s, step)
end

-- One second of the companion's run: `rate` jobs, written in one transaction.
function F.step(run, plan, out, getJobs, setJobs, again)
    local jobs = getJobs()
    local transport = F.transport or 0
    if F.running ~= plan.run then return end -- the companion was stopped (F.kill)
    local st = F.db()
    local why
    st:begin()
    for _ = 1, F.rate do
        local j = nextJob(run)
        if not j then why = "finished"; break end
        if readFile(mdir() .. "/stop") then why = "stopped"; break end
        jobs = jobs + 1
        setJobs(jobs)
        if not limited(run, plan, j) then
            if doJob(run, plan, j, out) then
                transport = transport + 1
                if transport >= 4 then why = "no answer"; break end
            else transport = 0 end
            recount(run, plan, false)
            table.insert(F.trace, { k = j.kind, total = math.max(run.total, run.estimate or 0), pct = run.pct })
        end
    end
    F.transport = transport
    if why == "finished" then
        if run.op == "revalidate" then out.revalidated = true
        elseif run.op == "full" then F.setMeta("full_at", now()); F.setMeta("lib_version", plan.lib_version); out.saved = true end
    end
    st:commit()
    recount(run, plan, why == "finished")
    if not why then
        writeFile(mdir() .. "/status.lua", C().encode(status(run, plan, true)))
        return UIManager:scheduleIn(F.step_s, again)
    end
    if why == "finished" then F.run = nil end
    F.running = nil
    writeFile(mdir() .. "/status.lua", C().encode(status(run, plan, false, why)))
    summary(plan, why, run, out, jobs)
end

---------------------------------------------------------------- checks and stores (CacheWorker.check)

function F.check(extras)
    F.checks = F.checks + 1
    UIManager:scheduleIn(0.2, function()
        W.in_companion = true
        local okc, err = pcall(F.checkNow, extras)
        W.in_companion = nil
        if not okc then error(err, 0) end
    end)
end

local function event(ev)
    require("libs/libkoreader-lfs").mkdir(dir() .. "/events")
    F.seq = (F.seq or 0) + 1
    writeFile(string.format("%s/events/%d-0-c%d.lua", dir(), now(), F.seq), C().encode(ev))
end
F.event = event

function F.checkNow(extras)
    local k, path = extras.cache_key, extras.path
    table.insert(F.calls, (extras.mode == "store" and "STORE " or "CHECK ") .. path)
    local ev = { kind = "checked", key = k }
    local b, e = fetch(path)
    if type(b) ~= "table" then ev.err = tostring(e or "no answer"); return event(ev) end
    local st = F.db()
    F.own(extras.owner)
    local template = extras.template ~= "" and extras.template or F.meta("detail_template")
    if extras.template and extras.template ~= "" then F.setMeta("detail_template", extras.template) end
    E.Db.close(F.dbPath())
    local saved = E.Store.read(extras.owner, k, path, template)
    E.Db.close(F.dbPath())
    if saved and not C().revalidate(saved.body, b, 200) then
        ev.unchanged, ev.saved = true, true
        local t = now()
        if saved.table == "lists" then rows("UPDATE lists SET validated_at = ? WHERE identity = ?", t, C().listWindow(path).identity)
        elseif saved.table == "books" then rows("UPDATE books SET detail_at = ? WHERE id = ?", t, C().detailId(path, template, F.FakeStore.SENTINEL))
        else rows("UPDATE entries SET validated_at = ?, stale = NULL WHERE key = ?", t, k) end
        return event(ev)
    end
    st:save(k, path, R().settle(saved and saved.body, b, extras.mode), now(), template)
    ev.changed, ev.at = true, now()
    event(ev)
end

---------------------------------------------------------------- writes (CacheStore.patch)

function F.patch(extras)
    UIManager:scheduleIn(0.1, function()
        W.in_companion = true
        local okc, err = pcall(F.patchNow, extras)
        W.in_companion = nil
        if not okc then error(err, 0) end
    end)
end

function F.patchNow(extras)
    F.patches = (F.patches or 0) + 1
    if extras.wipe == "1" then return F.wipe() end
    local st = F.db()
    local id = tonumber(extras.id)
    local fields = extras.fields ~= "" and C().decode(extras.fields or "") or nil
    st:begin()
    local n = 0
    if id and type(fields) == "table" then
        local r = rows("SELECT item, detail FROM books WHERE id = ?", id)[1]
        if r then
            for i, col in ipairs({ "item", "detail" }) do
                local body = decodeRow(r[i])
                if type(body) == "table" and R().patch(body, id, fields) > 0 then
                    rows("UPDATE books SET " .. col .. " = ? WHERE id = ?", C().encode(body), id); n = n + 1
                end
            end
        end
        for _, row in ipairs(rows("SELECT key, body FROM entries")) do
            local body = decodeRow(row[2])
            if type(body) == "table" and R().patch(body, id, fields) > 0 then
                rows("UPDATE entries SET body = ? WHERE key = ?", C().encode(body), val(row[1])); n = n + 1
            end
        end
        for _, row in ipairs(rows("SELECT identity, pos, item FROM list_items WHERE item IS NOT NULL")) do
            local body = decodeRow(row[3])
            if type(body) == "table" and R().patch(body, id, fields) > 0 then
                rows("UPDATE list_items SET item = ? WHERE identity = ? AND pos = ?", C().encode(body), val(row[1]), val(row[2])); n = n + 1
            end
        end
    end
    if extras.stale_home == "1" then rows("UPDATE entries SET stale = 1 WHERE home = 1") end
    st:commit()
    F.patched = (F.patched or 0) + n
end

---------------------------------------------------------------- the storage limit (CacheWorker.storage)

-- StorageLogic.plan: browsing entries and plain covers first, least recently used first; then the
-- covers saved for offline; never "kept".
function F.storagePlan(items, limit)
    local used = 0
    for _, e in ipairs(items) do used = used + (e.bytes or 0) end
    local out = { drop = {}, used = used, after = used }
    if not limit or limit <= 0 or used <= limit then return out end
    for _, tier in ipairs({ { cover = true, mirror_cover = true }, { cache = true } }) do
        local list = {}
        for _, e in ipairs(items) do if tier[e.kind] then table.insert(list, e) end end
        table.sort(list, function(a, b) if (a.at or 0) ~= (b.at or 0) then return (a.at or 0) < (b.at or 0) end return a.k < b.k end)
        for _, e in ipairs(list) do
            if out.after <= limit then return out end
            table.insert(out.drop, e.k)
            out.after = out.after - (e.bytes or 0)
        end
    end
    return out
end

local function fsize(p) local f = io.open(p, "rb"); if not f then return 0 end local n = f:seek("end"); f:close(); return n or 0 end

-- The database (its browsing entries apart) and the cover folder, as CacheWorker.storageItems.
function F.storageItems(cover_dir, mirror_covers)
    local items, eb = {}, 0
    for _, r in ipairs(rows("SELECT key, bytes, fetched_at, home FROM entries")) do
        local b = tonumber(val(r[2])) or 0
        eb = eb + b
        table.insert(items, { k = "e:" .. val(r[1]), bytes = b, at = tonumber(val(r[3])) or 0, kind = tonumber(val(r[4])) == 1 and "kept" or "cache" })
    end
    table.insert(items, { k = "db", bytes = math.max(0, fsize(F.dbPath()) + fsize(F.dbPath() .. "-journal") - eb), at = 0, kind = "kept" })
    if cover_dir and cover_dir ~= "" then
        local keep = {}
        if mirror_covers then for _, r in ipairs(rows("SELECT name FROM cover_keep")) do keep[val(r[1])] = true end end
        local lfs = require("libs/libkoreader-lfs")
        local okd, it = pcall(lfs.dir, cover_dir)
        for name in (okd and it or function() end) do
            if name:match("%.jpg$") and readFile(cover_dir .. "/" .. name) then
                local a = lfs.attributes(cover_dir .. "/" .. name)
                local size = tonumber(lfs.attributes(cover_dir .. "/" .. name, "size")) or fsize(cover_dir .. "/" .. name)
                table.insert(items, { k = "c:" .. name, bytes = size + fsize(cover_dir .. "/" .. name .. ".etag"),
                    at = type(a) == "table" and a.modification or 0, kind = keep[name] and "mirror_cover" or "cover" })
            end
        end
    end
    return items
end

F.storage_asks = 0
function F.storageNow(extras)
    F.storage_asks = F.storage_asks + 1
    local st = F.db()
    local limit = tonumber(extras.limit)
    local cover_dir = extras.cover_dir ~= "" and extras.cover_dir or nil
    local items = F.storageItems(cover_dir, extras.mirror_covers == "1")
    local plan = F.storagePlan(items, limit)
    local by = {}
    for _, e in ipairs(items) do by[e.k] = e end
    local removed = { cache = 0, cover = 0, mirror_cover = 0 }
    st:begin()
    for _, k in ipairs(plan.drop) do
        local e = by[k]
        if k:match("^e:") then rows("DELETE FROM entries WHERE key = ?", k:sub(3))
        elseif cover_dir then os.remove(cover_dir .. "/" .. k:sub(3)); os.remove(cover_dir .. "/" .. k:sub(3) .. ".etag") end
        removed[e.kind] = removed[e.kind] + 1
    end
    local gone, totals = {}, { used = 0, kept = 0, cache = 0, cover = 0, mirror_cover = 0 }
    for _, k in ipairs(plan.drop) do gone[k] = true end
    for _, e in ipairs(items) do
        if not gone[e.k] then totals.used = totals.used + e.bytes; totals[e.kind] = totals[e.kind] + e.bytes end
    end
    F.setMeta("storage", C().encode({ totals = totals, at = now() }))
    st:commit()
    event({ kind = "storage", why = extras.reason, totals = totals, removed = removed, used = plan.used, after = plan.after, limit = limit })
end

function F.storage(extras)
    UIManager:scheduleIn(0.2, function()
        W.in_companion = true
        local okc, err = pcall(F.storageNow, extras)
        W.in_companion = nil
        if not okc then error(err, 0) end
    end)
end

---------------------------------------------------------------- copies (CacheWorker.copies)

-- Seam: whether a copy's file is on the reader.
function F.exists(path) local f = io.open(path, "rb"); if f then f:close() end return f ~= nil end

function F.copiesNow(extras)
    F.copies_asks = (F.copies_asks or 0) + 1
    local ask = load(dir() .. "/copies/ask.lua")
    local ev = { kind = "copies", why = extras.reason }
    if not ask then ev.err = "no ask" else
        local want, details = {}, {}
        for _, b in ipairs(ask.books or {}) do want[tostring(b.book_id)] = true end
        for id, d in pairs(ask.eob or {}) do details[tostring(id)] = { files = d.files, at = d.saved_at or 0 } end
        for id in pairs(want) do
            local body, at = F.detail(tonumber(id))
            if type(body) == "table" and type(body.files) == "table" and (not details[id] or (at or 0) >= details[id].at) then
                details[id] = { files = body.files, at = at or 0 }
            end
        end
        local found, gone = {}, 0
        for _, b in ipairs(ask.books or {}) do
            local why = b.incompatible and "incompatible" or nil
            local d = details[tostring(b.book_id)]
            if not why and d then
                for _, f in ipairs(d.files) do
                    if f.id == b.file_id and type(f.fileHash) == "string" and f.fileHash ~= b.md5 then why = "hash" end
                end
            end
            if why then
                if F.exists(b.path) then table.insert(found, { md5 = b.md5, path = b.path, book_id = b.book_id, file_id = b.file_id, why = why })
                else gone = gone + 1 end
            end
        end
        table.sort(found, function(x, y) return x.path < y.path end)
        ev.checked, ev.found, ev.gone = #(ask.books or {}), found, gone
    end
    event(ev)
end

function F.copies(extras)
    UIManager:scheduleIn(0.2, function()
        W.in_companion = true
        local okc, err = pcall(F.copiesNow, extras)
        W.in_companion = nil
        if not okc then error(err, 0) end
    end)
end

---------------------------------------------------------------- the sleep screen's pool (SleepPoolBuilder)

-- The plugin's Sleep.build as it was, now the companion's (SleepPoolBuilder.kt, SleepPoolLogic.kt;
-- tested in SleepPoolTest): the tests' server answers through OC.client()'s requestBlocking.
local SP = setmetatable({ BATCH = 24, BAG_MAX = 2000, LEAVE_OUT_MAX = 4000, PAGE_SIZE = 100, DAY_S = 86400,
    PROBE_MAX = 48, SHOWS_MAX = 3 }, { __index = function(_, k) return E.SleepPool[k] end })
local FS = { SCOPE_PAGES = 20 }
F.SP = SP
local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
local function exists(p) return lfs_ok and lfs.attributes(p, "mode") == "file" end
local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function sdir() return F.sleep_dir or E.Sleep.dir() end
local function swrite(p, s)
    local tmp = p .. ".orbit-new"
    if not writeFile(tmp, s) then return false end
    return os.rename(tmp, p) and true or false
end
function FS.save(name, v) return swrite(sdir() .. "/" .. name, C().encode(v)) end
local function sload(name) return load(sdir() .. "/" .. name) end
local JSON = dofile((debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/json_mini.lua")
local function sjson(name)
    local body = readFile(sdir() .. "/" .. name)
    local okd, v = pcall(JSON.decode, body)
    return body and okd and type(v) == "table" and v or nil
end

-- The books of a dashboard section reply ({ section = { books } }, B koreader.ts:466-470).
function SP.sectionBooks(body)
    local s = type(body) == "table" and body.section
    local books = type(s) == "table" and s.books
    return type(books) == "table" and books or {}
end

-- A books page: items and whether more follow.
function SP.pageItems(body)
    if type(body) ~= "table" then return {}, false end
    return type(body.items) == "table" and body.items or {}, body.hasNext == true
end

-- R2: a book can be shown when it has a cover, isn't read and isn't the book open now.
function SP.eligible(b, open_id)
    if type(b) ~= "table" or not tonumber(b.id) then return false, "no id" end
    if b.hasCover == false then return false, "no cover" end
    if b.readStatus == "read" then return false, "read" end
    if open_id and tonumber(b.id) == open_id then return false, "open now" end
    return true
end

function SP.needsTags(rules)
    for _, r in ipairs(rules or {}) do
        local p = SP.parseRule(r)
        if p and p.kind == "tag" then return true end
    end
    return false
end

-- The rules that need member lists (scope, collection), parsed.
function SP.memberRules(rules)
    local out = {}
    for _, r in ipairs(rules or {}) do
        local p = SP.parseRule(r)
        if p and p.kind ~= "tag" then table.insert(out, p) end
    end
    return out
end

-- One book against the rules, OR-ed. members[key] = { [id] = true } once listed (nil: not yet);
-- tags = the book's tags from its detail (nil: not fetched). -> "keep" | "out" | "unknown", why.
-- Unknown is failed closed by the caller (X7).
function SP.check(id, rules, members, tags)
    id = tonumber(id)
    local unknown
    for _, r in ipairs(rules or {}) do
        local p = SP.parseRule(r)
        if p and p.kind == "tag" then
            if type(tags) ~= "table" then
                unknown = unknown or ("no detail for " .. p.key)
            else
                for _, t in ipairs(tags) do
                    if trim(t):lower() == p.tag then return "out", p.key end
                end
            end
        elseif p then
            local set = members and members[p.key]
            if type(set) ~= "table" then
                unknown = unknown or (p.key .. " not listed yet")
            elseif set[id] then
                return "out", p.key
            end
        end
    end
    if unknown then return "unknown", unknown end
    return "keep"
end

-- A member list is due: never listed, a day old, or the clock went back.
function SP.due(at, now)
    return not at or now < at or now - at >= SP.DAY_S
end

-- Fisher-Yates with rand(n) -> 1..n. The book just shown never comes first.
function SP.shuffle(ids, rand, avoid_first)
    local out = {}
    for i, v in ipairs(ids or {}) do out[i] = v end
    for i = #out, 2, -1 do
        local j = rand(i)
        out[i], out[j] = out[j], out[i]
    end
    if avoid_first and #out > 1 and out[1] == avoid_first then
        local j = 1 + rand(#out - 1)
        out[1], out[j] = out[j], out[1]
    end
    return out
end

-- bag = { order = { ids }, pos = index of the last shown (0 none), prev = the id shown last }.
-- The companion reports what it showed (state.json); the bag moves to it, never back.
function SP.bagSeek(bag, shown)
    shown = tonumber(shown)
    if not shown or shown == bag.prev then return false end
    for i = (bag.pos or 0) + 1, #bag.order do
        if bag.order[i] == shown then
            bag.pos, bag.prev = i, shown
            return true
        end
    end
    return false
end

-- The members listed again: those that left come out, new ones go in at random places among the
-- books not shown yet, so "no repeat until every book was shown" holds.
function SP.bagSync(bag, members, rand)
    local want, kept, out = {}, {}, {}
    for _, id in ipairs(members) do want[id] = true end
    local pos = bag.pos or 0
    for i, id in ipairs(bag.order or {}) do
        if want[id] and not kept[id] then
            kept[id] = true
            table.insert(out, id)
        elseif i <= pos then
            pos = pos - 1
        end
    end
    for _, id in ipairs(members) do
        if not kept[id] then
            kept[id] = true
            local at = pos + rand(#out - pos + 1)
            table.insert(out, at, id)
        end
    end
    bag.order, bag.pos = out, math.max(0, pos)
    return bag
end

-- The ids not shown yet, in order. A used-up bag is shuffled again first (the last shown never
-- first); returns the ids and whether it was shuffled.
function SP.bagNext(bag, rand)
    local out, shuffled = {}, false
    if #bag.order == 0 then return out, false end
    if (bag.pos or 0) >= #bag.order then
        bag.order = SP.shuffle(bag.order, rand, bag.prev)
        bag.pos, shuffled = 0, true
    end
    for i = bag.pos + 1, #bag.order do table.insert(out, bag.order[i]) end
    return out, shuffled
end

-- Every sleep (R4b): the ready covers carried into the next batch, in order, and the retired ones
-- (shown SHOWS_MAX times, by the companion's state.json "shows"). prev_ids: pool.json's ids.
function SP.carry(prev_ids, shows, max_shows)
    local carry, retired, seen = {}, {}, {}
    for _, id in ipairs(prev_ids or {}) do
        id = tonumber(id)
        if id and not seen[id] then
            seen[id] = true
            local n = tonumber(type(shows) == "table" and (shows[id] or shows[tostring(id)]) or 0) or 0
            if n >= (max_shows or SP.SHOWS_MAX) then retired[id] = true else table.insert(carry, id) end
        end
    end
    return carry, retired
end

-- Every sleep with a bag: the books taken into the batch count as shown, so the next top-up
-- continues the no-repeat order. taken: a set of ids.
function SP.bagTake(bag, taken)
    local pos = bag.pos or 0
    for i = pos + 1, #(bag.order or {}) do
        if taken[bag.order[i]] then pos = i end
    end
    if pos ~= (bag.pos or 0) then bag.pos, bag.prev = pos, nil end
    return bag
end

-- pool.json: the covers in the order the companion shows them (android/docs/INTERFACE.md).
-- items: { { id, title, file } } (file relative to the orbit-sleep folder).
-- account: { server, user, storage_limit_mb } or nil. The companion fetches the sharp covers
-- (docs/design/lock-screen.md L7) from this server, signed in with an OPDS login it asks for;
-- never the KOReader key.
function SP.poolDoc(source, items, at_ms, account)
    local doc = { v = 1, at = at_ms, source = source, items = items }
    if type(account) == "table" then
        doc.server = account.server and tostring(account.server) or nil
        doc.user = account.user and tostring(account.user) or nil
        doc.storage_limit_mb = tonumber(account.storage_limit_mb)
    end
    return doc
end

-- Every page of a smart scope's or collection's books, up to max ids (R1b, X5).
-- -> ids, books (id -> list item), or nil, err.
function FS.listMembers(client, rule, max)
    local ids, books = {}, {}
    local q = { size = SP.PAGE_SIZE, sort = "recently_added", order = "desc" }
    if rule.kind == "scope" then q.smartScopeId = rule.id else q.collectionId = rule.id end
    for page = 1, math.ceil(max / SP.PAGE_SIZE) do
        q.page = page
        local body, err = client:requestBlocking("GET", client:query("/koreader/plugin/catalog/books", q))
        if type(body) ~= "table" then return nil, tostring(err or "no answer") end
        local items, more = SP.pageItems(body)
        for _, b in ipairs(items) do
            local id = tonumber(b.id)
            if id and not books[id] and #ids < max then table.insert(ids, id); books[id] = b end
        end
        if not more or #ids >= max then break end
    end
    return ids, books
end

function FS.detail(client, id)
    local body = client:requestBlocking("GET", "/koreader/plugin/catalog/books/" .. tostring(id))
    return type(body) == "table" and body or nil
end

-- The cover, by its ETag (OC.coverDownload); tests replace it.
function FS.download(client, id, path)
    if F.sleepDownload then return F.sleepDownload(client, id, path) end
    local api = package.loaded["bookorbit_api"]
    local stock = api and (api.__orbit_stock and api.__orbit_stock["cache:downloadCatalogThumbnail"] or api.downloadCatalogThumbnail)
    if not stock then stock = function() return nil, "no plugin download" end end
    local okd, ok = pcall(E.OC.coverDownload, client, stock, id, path, { temp_path = path .. ".part", max_bytes = 4 * 1024 * 1024 })
    return okd and ok and true or false
end

-- In the background process: lists what is due, picks and checks the books, fetches their covers
-- and writes the files. Returns a short summary for the log.
function FS.build(client, plan, rand)
    local d = plan.dir
    local now = plan.now
    local sum = { kept = 0, probed = 0, left_out = 0, unknown = 0, skipped = 0, listed = {} }
    -- Leave out's member lists, once a day (X5).
    local lo = plan.leave_out
    for _, p in ipairs(SP.memberRules(plan.rules)) do
        local e = lo[p.key]
        if not e or SP.due(e.at, now) then
            local ids, err = FS.listMembers(client, p, SP.LEAVE_OUT_MAX)
            if ids then
                lo[p.key] = { at = now, ids = ids }
                table.insert(sum.listed, p.key .. "=" .. #ids)
            else
                table.insert(sum.listed, p.key .. " failed (" .. err .. ")")
            end
        end
    end
    -- Keep only the rules still set.
    local members = {}
    for _, p in ipairs(SP.memberRules(plan.rules)) do
        if lo[p.key] then
            local set = {}
            for _, id in ipairs(lo[p.key].ids or {}) do set[id] = true end
            members[p.key] = set
        end
    end
    local keep_lo = {}
    for _, p in ipairs(SP.memberRules(plan.rules)) do keep_lo[p.key] = lo[p.key] end
    FS.save("leave_out.lua", keep_lo)

    -- The candidates, in the order they would be shown.
    local candidates, known, source = {}, {}, plan.from_key
    -- Plays one source (the first picked); the multi-source order is SleepPoolBuilder's (cases.json sources).
    local from = SP.parseFrom(SP.sources(plan.from_key)[1])
    local bag
    if from.kind == "list" then
        local order = { from.type }
        for _, l in ipairs(SP.LISTS) do if l.type ~= from.type then table.insert(order, l.type) end end
        for _, t in ipairs(order) do
            local body = client:requestBlocking("GET", "/koreader/plugin/catalog/dashboard/sections/" .. t)
            local books = SP.sectionBooks(body)
            if #books > 0 then
                for _, b in ipairs(books) do
                    local id = tonumber(b.id)
                    if id then table.insert(candidates, id); known[id] = b end
                end
                if t ~= from.type then sum.fallback = t end
                break
            end
        end
    else
        bag = plan.bag
        if bag.source ~= plan.from_key then bag = { source = plan.from_key, order = {}, pos = 0 } end
        if not bag.at or SP.due(bag.at, now) then
            local ids, err = FS.listMembers(client, from, SP.BAG_MAX)
            if ids then
                SP.bagSync(bag, ids, rand)
                bag.at = now
                table.insert(sum.listed, plan.from_key .. "=" .. #ids)
            else
                table.insert(sum.listed, plan.from_key .. " failed (" .. err .. ")")
            end
        end
        if not plan.every then SP.bagSeek(bag, plan.shown) end
        candidates = SP.bagNext(bag, rand)
    end

    -- Checked one by one, covers fetched for the ones kept: BATCH of them (R3).
    local keep = SP.BATCH
    local items = {}
    local wanted = {}
    local taken = {}
    -- Every sleep: the ready covers not yet shown SHOWS_MAX times stay; retired ones make room.
    local carry, retired = {}, {}
    if plan.every then carry, retired = SP.carry(plan.prev_ids, plan.shows, SP.SHOWS_MAX) end
    local function try(id)
        if taken[id] then return end
        taken[id] = true
        sum.probed = sum.probed + 1
        local b = known[id]
        local detail
        if not b or SP.needsTags(plan.rules) then
            detail = FS.detail(client, id)
            b = b or detail
        end
        local okb = SP.eligible(b, plan.open_id)
        if not okb then sum.skipped = sum.skipped + 1; return end
        local verdict = SP.check(id, plan.rules, members, detail and detail.tags or nil)
        if verdict == "out" then sum.left_out = sum.left_out + 1; return end
        if verdict == "unknown" then sum.unknown = sum.unknown + 1; return end -- fail closed (X7)
        local rel = "covers/" .. id .. ".jpg"
        if FS.download(client, id, d .. "/" .. rel) and exists(d .. "/" .. rel) then
            table.insert(items, { id = id, title = tostring(b.title or ""), file = rel })
            wanted[rel] = true
        else
            sum.skipped = sum.skipped + 1
        end
    end
    -- The bag's last shown book stays first, so the companion's "next" is the bag's next.
    if bag and not plan.every and bag.prev and exists(d .. "/covers/" .. bag.prev .. ".jpg") then
        if SP.check(bag.prev, plan.rules, members, nil) == "keep" then
            table.insert(items, { id = bag.prev, title = "", file = "covers/" .. bag.prev .. ".jpg" })
            wanted["covers/" .. bag.prev .. ".jpg"] = true
        end
    end
    local first = #items
    for _, id in ipairs(carry) do
        if #items - first >= keep or sum.probed >= SP.PROBE_MAX then break end
        try(id)
    end
    sum.carried = #items - first
    local fresh = {}
    for _, id in ipairs(candidates) do
        if #items - first >= keep or sum.probed >= SP.PROBE_MAX then break end
        if not retired[id] and not taken[id] then
            local before = #items
            try(id)
            if #items > before then fresh[id] = true end
        end
    end
    -- A bag whose rest is all left out or read: shuffled again, once.
    if bag and #items - first == 0 and #bag.order > 0 and sum.probed < SP.PROBE_MAX then
        bag.pos = #bag.order
        for _, id in ipairs((SP.bagNext(bag, rand))) do
            if #items - first >= keep or sum.probed >= SP.PROBE_MAX then break end
            try(id)
        end
    end
    -- Every retired one and nothing new (a one-book list, offline): they stay, and the companion
    -- keeps cycling them rather than showing nothing.
    if #items - first == 0 and next(retired) then
        for _, id in ipairs(plan.prev_ids or {}) do
            if retired[tonumber(id)] then taken[tonumber(id)] = nil; try(tonumber(id)) end
            if #items - first >= keep then break end
        end
    end
    if bag and plan.every then SP.bagTake(bag, fresh) end
    if bag then FS.save("bag.lua", bag) end
    sum.kept = #items - first
    sum.retired = 0
    for _ in pairs(retired) do sum.retired = sum.retired + 1 end
    -- Covers no longer in the pool go.
    if lfs_ok and lfs.attributes(d .. "/covers", "mode") == "directory" then
        for name in lfs.dir(d .. "/covers") do
            local rel = "covers/" .. name
            if name:match("^%d+%.jpg$") and not wanted[rel] then
                os.remove(d .. "/" .. rel)
                os.remove(d .. "/" .. rel .. ".etag")
            end
        end
    end
    swrite(d .. "/pool.json", SP.json(SP.poolDoc(source, items, now * 1000,
        { server = client.server_url, user = client.username, storage_limit_mb = plan.storage_limit_mb })))
    sum.items = #items
    return sum
end

-- Every page of one section list (child-safe: no UI). -> entries, or nil, err.
function FS.listSection(client, section)
    local out, seen = {}, {}
    for page = 1, FS.SCOPE_PAGES do
        local body, err = client:requestBlocking("GET",
            client:query("/koreader/plugin/catalog/sections/" .. section, { page = page, size = SP.PAGE_SIZE }))
        if type(body) ~= "table" then
            if page == 1 then return nil, tostring(err or "no answer") end
            break
        end
        local new = 0
        for _i, e in ipairs(SP.entries(body)) do
            if not seen[e.id] then seen[e.id] = true; table.insert(out, e); new = new + 1 end
        end
        -- Collections and smart scopes come whole today (no hasNext); a paged reply is followed.
        if body.hasNext ~= true or new == 0 then break end
    end
    return out
end

-- Both lists (child-safe). -> { scopes, collections, at }, or nil, err.
function FS.fetchScopes(client)
    local scopes, e1 = FS.listSection(client, "smart-scopes")
    local collections, e2 = FS.listSection(client, "collections")
    if not (scopes and collections) then return nil, e1 or e2 end
    return { v = 1, at = os.time(), scopes = scopes, collections = collections }
end

-- Seam: the tests replace the cover download (FS.download fetches by ETag through the plugin's).
F.sleepDownload = nil

-- Leave out's tag picker (CacheWorker.detailTags, SleepPoolLogic.tagCounts): the saved details'
-- tags, counted, in tags.json.
function FS.tags()
    local details = {}
    local function add(path, body)
        path = tostring(path or "")
        if not (path:match("/catalog/books/%d+$") or path:match("/catalog/books/%d+%?")) then return end
        if type(body) == "table" and type(body.tags) == "table" then table.insert(details, body.tags) end
    end
    if F._st or io.open(F.dbPath(), "rb") then
        for _, r in ipairs(rows("SELECT detail FROM books WHERE detail IS NOT NULL ORDER BY id")) do
            local body = decodeRow(r[1])
            if type(body) == "table" and type(body.tags) == "table" then table.insert(details, body.tags) end
        end
    end
    local counts, shown = {}, {}
    for _, tags in ipairs(details) do
        local seen = {}
        for _, t in ipairs(tags) do
            local k = trim(t):lower()
            if k ~= "" and not seen[k] then seen[k] = true; counts[k] = (counts[k] or 0) + 1; shown[k] = shown[k] or trim(t) end
        end
    end
    local out = {}
    for k, n in pairs(counts) do table.insert(out, { tag = k, label = shown[k], count = n }) end
    table.sort(out, function(a, b) if a.count == b.count then return a.tag < b.tag end return a.count > b.count end)
    swrite(sdir() .. "/tags.json", SP.json({ v = 1, at = os.time(), details = #details, tags = out }))
    return #out
end

function F.sleepNow(extras)
    F.sleep_asks = (F.sleep_asks or 0) + 1
    F.sleep_last = extras
    local client = E.OC.client()
    local ev = { kind = "sleep_pool", why = extras.reason }
    lfs.mkdir(mdir())
    ev.tags = FS.tags()
    if extras.scopes_only == "1" then
        ev.scopes_only = true
        local v, err = FS.fetchScopes(client)
        if v then swrite(sdir() .. "/scopes.json", SP.json(v)) else ev.err = tostring(err) end
    else
        local st = sjson("state.json") or {}
        local prev = {}
        for _, it in ipairs((sjson("pool.json") or {}).items or {}) do if tonumber(it.id) then table.insert(prev, tonumber(it.id)) end end
        local plan = { dir = sdir(), now = os.time(), from_key = extras.from, rules = SP.decodeRules(extras.rules),
            leave_out = sload("leave_out.lua") or {}, bag = sload("bag.lua") or { order = {}, pos = 0 },
            shown = tonumber(st.shown), open_id = tonumber(extras.open_id), storage_limit_mb = tonumber(extras.storage_limit_mb),
            every = extras.every == "1", prev_ids = prev, shows = st.shows }
        math.randomseed(os.time())
        local sum = FS.build(client, plan, function(n) return math.random(n) end)
        for k, v in pairs(sum) do ev[k] = v end
        ev.every = plan.every
        local v = FS.fetchScopes(client)
        if v then swrite(sdir() .. "/scopes.json", SP.json(v)); ev.scopes = true end
    end
    lfs.mkdir(dir() .. "/events")
    F.seq = (F.seq or 0) + 1
    writeFile(string.format("%s/events/%d-0-c%d.lua", dir(), now(), F.seq), C().encode(ev))
end

function F.sleep(extras)
    UIManager:scheduleIn(0.2, function()
        W.in_companion = true
        local okc, err = pcall(F.sleepNow, extras)
        W.in_companion = nil
        if not okc then error(err, 0) end
    end)
end

---------------------------------------------------------------- cover recheck (CacheWorker.recheckCovers)

function F.recheckNow(extras)
    local ids, paths, changed, checked = {}, {}, {}, 0
    for v in ((extras.ids or "") .. "\n"):gmatch("([^\n]*)\n") do table.insert(ids, tonumber(v)) end
    for v in ((extras.paths or "") .. "\n"):gmatch("([^\n]*)\n") do table.insert(paths, v) end
    for i, id in ipairs(ids) do
        local p = paths[i]
        local etag = p and readFile(p .. ".etag")
        if p and readFile(p) and etag then
            checked = checked + 1
            table.insert(F.calls, "RECHECK " .. id)
            local r = F.cover and F.cover({ id = id, path = p }, etag) or 304
            if r == 200 then writeFile(p, "\255\216\255\224fakejpeg2"); writeFile(p .. ".etag", '"e2"'); table.insert(changed, id) end
        end
    end
    lfs.mkdir(dir() .. "/events")
    F.seq = (F.seq or 0) + 1
    writeFile(string.format("%s/events/%d-0-c%d.lua", dir(), now(), F.seq), C().encode({ kind = "covers_rechecked", why = extras.reason, checked = checked, changed = changed }))
end

function F.recheck(extras)
    UIManager:scheduleIn(0.2, function()
        W.in_companion = true
        local okc, err = pcall(F.recheckNow, extras)
        W.in_companion = nil
        if not okc then error(err, 0) end
    end)
end

function F.receive(intent)
    if not (W.companion and intent.package == "net.fledgewing.orbitcompanion") then return end
    if intent.action:match("%.MIRROR$") then F.mirror(intent.extras)
    elseif intent.action:match("%.CHECK$") then F.check(intent.extras)
    elseif intent.action:match("%.STORAGE$") then F.storage(intent.extras)
    elseif intent.action:match("%.COPIES$") then F.copies(intent.extras)
    elseif intent.action:match("%.SLEEP_REFRESH$") then F.sleep(intent.extras)
    elseif intent.action:match("%.RECHECK$") then F.recheck(intent.extras)
    elseif intent.action:match("%.PATCH$") then F.patch(intent.extras) end
end

-- The companion was stopped mid-run (its status stops moving).
function F.kill() F.running = nil end

return F

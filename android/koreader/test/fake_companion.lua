-- The Orbit Companion's cache worker, played by the flow tests (the real one is
-- android/companion/.../CacheWorker.kt, tested in CacheWorkerTest against the same rules and
-- shared/fixtures/cache/worker.json). It answers the plugin's MIRROR and CHECK broadcasts through
-- the same files: mirror/plan.lua in; mirror/<hash>.lua, status.lua, summary.lua, cover_keep.lua
-- and events/<n>.lua out. It runs on the tests' fake clock, `rate` jobs a second, so a test sees a
-- run that spans many of the plugin's polls. It is test code: nothing of it ships.

local F = { rate = 1000, step_s = 1, PAGE = 100, COVER_BATCH = 20 }

local E, W, fetch, UIManager
local function C() return E.Cache end
local function dir() return E.OC.dir() end
local function mdir() return dir() .. "/mirror" end
local function readFile(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function writeFile(p, s) local f = io.open(p, "wb"); if not f then return false end f:write(s); f:close(); return true end
local function load(p) local v = C().decode(readFile(p) or ""); return type(v) == "table" and v or nil end
local function now() return math.floor(W.clock) end

function F.install(env, world, fetcher, ui)
    E, W, fetch, UIManager = env, world, fetcher, ui
    F.rate, F.runs, F.calls, F.checks, F.creds, F.running, F.cover_bytes = 1000, 0, {}, 0, {}, nil, nil
end

local function fill(t, sentinel, value)
    local v = tostring(value):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end)
    return (t:gsub(sentinel, (v:gsub("%%", "%%%%"))))
end

local function push(st, job)
    local id = job.k .. "|" .. tostring(job.identity or job.path or "") .. "|" .. (job.k == "page" and tostring(job.page) or "")
    if st.seen[id] then return end
    st.seen[id] = true
    local q = job.k == "covers" and "covers" or job.seed and "seed" or job.k == "detail" and "details" or "lists"
    table.insert(st.queues[q], job)
    st.total = st.total + 1
end
local QUEUES = { "seed", "lists", "details", "covers" }
local function left(st) local n = 0; for _, q in ipairs(QUEUES) do n = n + #st.queues[q] end return n end
local function peek(st) for _, q in ipairs(QUEUES) do if st.queues[q][1] then return q, st.queues[q][1] end end end

local function newState()
    return { v = 3, queues = { seed = {}, lists = {}, details = {}, covers = {} }, seen = {}, lists = {}, sizes = {}, digests = {},
        cover_keep = {}, done = 0, total = 0, skipped = 0, requests = 0, bytes = 0, cover_total = 0, cover_batch = 0, keep_n = 0,
        covers = { ok = 0, not_modified = 0, failed = 0, bytes = 0 } }
end

local function key(plan, path) return C().key({ account = plan.owner, server = F.server, method = "GET", path = path }) end
local function addList(st, path, seed)
    local w = path and C().listWindow(path)
    if w then push(st, { k = "page", identity = w.identity, page = 1, kind = w.kind, section = w.section, seed = seed }) end
end
local function addDetail(st, plan, id, seed, next_of)
    push(st, { k = "detail", path = fill(plan.detail_template, plan.sentinel, id), id = id, seed = seed, next_of = next_of })
end

local function coversFor(st, plan, items, all)
    if not plan.cover_dir then return end
    local batch = {}
    local function flush()
        if #batch == 0 then return end
        st.cover_batch = st.cover_batch + 1
        push(st, { k = "covers", path = "covers#" .. st.cover_batch, batch = batch })
        batch = {}
    end
    for _, b in ipairs(items or {}) do
        local name = type(b) == "table" and b.hasCover and C().coverName(b)
        if name then
            table.insert(batch, { id = b.id, path = plan.cover_dir .. "/" .. name, updatedAt = b.updatedAt })
            st.cover_total = st.cover_total + 1
            if all then st.cover_keep[name] = true; st.keep_dirty = true end
            if #batch >= F.COVER_BATCH then flush() end
        end
    end
    flush()
end

local function store(st, k, path, body)
    local h = E.OC.hash(k)
    local digest = C().encode(C().normalize and C().normalize(body) or body)
    local changed = st.digests[h] ~= nil and st.digests[h] ~= digest
    local s = C().encode({ key = k, body = body, fetched_at = now(), validated_at = now(), path = path })
    if writeFile(mdir() .. "/" .. h .. ".lua", s) then
        st.bytes = st.bytes - (st.sizes[h] or 0) + #s
        st.sizes[h], st.digests[h] = #s, digest
    end
    return changed
end

local function drop(st, k)
    local h = E.OC.hash(k)
    os.remove(mdir() .. "/" .. h .. ".lua")
    st.bytes = st.bytes - (st.sizes[h] or 0)
    st.sizes[h], st.digests[h] = nil, nil
end

local function landed(st, plan, job, path, body, out)
    st.requests = st.requests + 1
    local changed = store(st, key(plan, path), path, body)
    if job.k == "detail" then
        if not job.next_of and type(body.seriesMembers) == "table" then
            for _, s in ipairs(body.seriesMembers) do
                if tonumber(s.id) ~= job.id and s.readStatus ~= "read" and (s.seriesIndex or 0) > (body.seriesIndex or 0) then
                    addDetail(st, plan, tonumber(s.id), job.seed, job.id); break
                end
            end
        end
        if job.seed or plan.covers_on then coversFor(st, plan, { body }, plan.covers_on) end
        return
    end
    local total = tonumber(body.total) or #(body.items or {})
    if job.page == 1 then
        local l = st.lists[job.identity]
        local old_total = l and l.total
        local function dropPage(n, size) drop(st, key(plan, C().mirrorPage(job.identity, n, size))) end
        if l and l.size ~= job.size then
            for n = 2, C().pageCount(l.total, l.size) do dropPage(n, l.size) end
            dropPage(1, l.size); old_total = nil
        end
        st.lists[job.identity] = { total = total, kind = job.kind, section = job.section, size = job.size }
        if not job.check or old_total ~= total then
            local fetchp, gone = C().repage(job.check and old_total or 0, total, job.size)
            for _, n in ipairs(fetchp) do
                push(st, { k = "page", identity = job.identity, page = n, kind = job.kind, section = job.section, check = job.check, size = job.size, seed = job.seed })
            end
            for _, n in ipairs(gone) do dropPage(n, job.size) end
        end
    end
    if job.kind == "section" then
        local t = (plan.templates or {})[job.section] or {}
        for _, e in ipairs(body.items or {}) do
            local p
            if job.section == "series" and e.seriesId and t.path then p = fill(t.path, plan.sentinel, e.seriesId)
            elseif job.section == "series" and t.series_name_path then p = fill(t.series_name_path, plan.sentinel, e.id)
            elseif t.path and e.id ~= nil then p = fill(t.path, plan.sentinel, e.id) end
            addList(st, p)
        end
    elseif job.kind == "books" and (not job.check or changed) then
        for _, b in ipairs(body.items or {}) do
            if type(b) == "table" and tonumber(b.id) then
                local known = job.check and readFile(mdir() .. "/" .. E.OC.hash(key(plan, fill(plan.detail_template, plan.sentinel, b.id))) .. ".lua")
                if not known then addDetail(st, plan, tonumber(b.id)) end
            end
        end
        if plan.covers_on then coversFor(st, plan, body.items, true) end
    end
    if job.check and changed and #out.changed < 50 then table.insert(out.changed, job.identity) end
end

local function coverBatch(st, job, out)
    for _, c in ipairs(job.batch) do
        local exists = readFile(c.path) ~= nil
        local etag = readFile(c.path .. ".etag")
        if not exists or etag then
            table.insert(F.calls, "COVER " .. c.id)
            local r = F.cover and F.cover(c, etag) or (etag and 304 or 200)
            if r == 304 and exists then st.covers.not_modified = st.covers.not_modified + 1
            elseif r == 200 then
                writeFile(c.path, "\255\216\255\224fakejpeg"); writeFile(c.path .. ".etag", '"e"')
                st.covers.ok, st.covers.bytes = st.covers.ok + 1, st.covers.bytes + (F.cover_bytes or 12)
                table.insert(out.written, { id = c.id, updatedAt = c.updatedAt })
            else st.covers.failed = st.covers.failed + 1 end
        end
    end
end

local function limited(st, plan, job)
    local limit = plan.limit
    if not limit or limit <= 0 then return false end
    local covers = job.k == "covers"
    if covers and not plan.covers_on then return false end
    local kept = (st.base_other or 0) + st.bytes
    local room = covers and (kept + (st.base_mirror_cover or 0) + st.covers.bytes - st.run_cover0 < limit) or (not covers and kept < limit)
    if room then return false end
    local text
    if covers then
        st.total = st.total - #st.queues.covers
        st.queues.covers = {}
        text = C().limitText("covers", st.covers.ok + st.covers.not_modified, st.cover_total)
    else
        text = C().limitText("lists", st.done, st.total)
        for _, q in ipairs(QUEUES) do st.queues[q] = {} end
        st.total = st.done
    end
    st.limit_note = { text = text, at = now(), limit = limit }
    return true
end

-- One job, retried like CacheWorker.doJob (no waits on the fake clock). -> true: no answer.
local function doJob(st, plan, q, job, out)
    if job.k == "covers" then
        coverBatch(st, job, out); table.remove(st.queues[q], 1); st.done = st.done + 1
        return false
    end
    while true do
        local path = job.k == "page" and C().mirrorPage(job.identity, job.page, job.size) or job.path
        table.insert(F.calls, "GET " .. path)
        local b, e = fetch(path)
        if type(b) == "table" then
            table.remove(st.queues[q], 1); st.done = st.done + 1
            landed(st, plan, job, path, b, out)
            return false
        end
        job.tries = (job.tries or 0) + 1
        local status = tonumber(e)
        local r = (status and status < 500) and { skip = true } or C().mirrorRetry(job.tries, job.k == "page" and (job.size or F.PAGE) or nil, job.page)
        if r.skip then
            st.skipped = st.skipped + 1; table.remove(st.queues[q], 1); st.done = st.done + 1
            return not status
        end
        if r.size and r.size ~= (job.size or F.PAGE) then job.size = r.size end
    end
end

local function status(st, plan, running)
    return { v = 3, runner = "fake companion", run = plan.run, running = running or nil, beat = now(), op = st.op, at = st.at,
        lib_version = st.lib_version, done = st.done, total = st.total, left = left(st), skipped = st.skipped, covers = st.covers,
        cover_total = st.cover_total, limit_note = st.limit_note, revalidating = st.revalidating, bytes = st.bytes,
        cover_keep_n = st.keep_n, started_at = st.started_at }
end

local function persist(st)
    if st.keep_dirty then
        st.keep_n, st.keep_dirty = st.keep_n + 1, nil
        writeFile(mdir() .. "/cover_keep.lua", C().encode(st.cover_keep))
    end
    writeFile(mdir() .. "/worker-state.lua", C().encode(st))
end

function F.state() return load(mdir() .. "/worker-state.lua") end

local function begin(plan)
    local st = F.state()
    if st and st.v ~= 3 then st = nil end
    if plan.op == "full" then
        local prev = st
        st = newState()
        if prev then
            st.at, st.lib_version, st.lists, st.sizes, st.digests, st.bytes = prev.at, prev.lib_version, prev.lists, prev.sizes, prev.digests, prev.bytes
            st.cover_keep, st.keep_n = prev.cover_keep, prev.keep_n
        end
        st.op, st.reason, st.started_at = "full", plan.reason, now()
        for _, h in ipairs(plan.legacy or {}) do
            local s = readFile(dir() .. "/" .. h .. ".lua")
            if s and os.rename(dir() .. "/" .. h .. ".lua", mdir() .. "/" .. h .. ".lua") then st.sizes[h] = #s; st.bytes = st.bytes + #s end
        end
        for _, p in ipairs(plan.seed_lists or {}) do addList(st, p, true) end
        for _, p in ipairs(plan.legacy_lists or {}) do addList(st, p) end
        for _, p in ipairs(plan.sections or {}) do addList(st, p) end
        local idx = load(dir() .. "/index.lua") or {}
        local paths, ids = {}, {}
        for _, id in ipairs(plan.seed_details or {}) do ids[id] = true end
        for k, meta in pairs(idx.entries or {}) do
            if not meta.mirror and meta.path then table.insert(paths, meta.path) end
            if meta.home then
                local e = load(dir() .. "/" .. E.OC.hash(k) .. ".lua")
                local body = e and e.key == k and e.body or {}
                for _, f in ipairs({ "continueReading", "items", "books" }) do
                    for _, b in ipairs(type(body[f]) == "table" and body[f] or {}) do if tonumber(b.id) then ids[tonumber(b.id)] = true end end
                end
            end
        end
        table.sort(paths)
        for _, p in ipairs(paths) do addList(st, p) end
        local sorted = {}
        for id in pairs(ids) do table.insert(sorted, id) end
        table.sort(sorted)
        for _, id in ipairs(sorted) do addDetail(st, plan, id, true) end
    elseif plan.op == "revalidate" then
        if not st or not st.at or left(st) > 0 then return nil end
        st.seen, st.done, st.total, st.requests, st.skipped, st.cover_total = {}, 0, 0, 0, 0, 0
        st.covers = { ok = 0, not_modified = 0, failed = 0, bytes = 0 }
        st.revalidating, st.op, st.started_at = true, "revalidate", now()
        local ids = {}
        for identity in pairs(st.lists) do table.insert(ids, identity) end
        table.sort(ids)
        for _, identity in ipairs(ids) do
            local l = st.lists[identity]
            for n = 1, C().pageCount(l.total, l.size) do
                push(st, { k = "page", identity = identity, page = n, kind = l.kind, section = l.section, check = true, size = l.size })
            end
        end
    elseif plan.op == "covers" then
        st = st or newState()
        for identity, l in pairs(st.lists) do
            if l.kind == "books" then
                for n = 1, C().pageCount(l.total, l.size) do
                    local k = key(plan, C().mirrorPage(identity, n, l.size))
                    local e = load(mdir() .. "/" .. E.OC.hash(k) .. ".lua")
                    if e and e.key == k then coversFor(st, plan, e.body.items, true) end
                end
            end
        end
    else
        st = st or newState()
    end
    return st
end

local function summary(plan, why, st, out, jobs)
    writeFile(mdir() .. "/summary.lua", C().encode({ run = plan.run, why = why, jobs = jobs, status = status(st, plan),
        changed = out.changed, written = out.written, saved = out.saved, revalidated = out.revalidated,
        bytes_delta = st.bytes - st.run_bytes0, cover_bytes_delta = st.covers.bytes - st.run_cover0 }))
end

function F.mirror(extras)
    local plan = load(mdir() .. "/plan.lua")
    assert(plan, "fake companion: no plan")
    F.runs, F.server, F.plan = F.runs + 1, extras.server, plan
    F.creds = { server = extras.server, user = extras.user, userkey = extras.userkey }
    local st = begin(plan)
    if not st then
        local s = F.state() or newState()
        s.run_bytes0, s.run_cover0 = s.bytes, s.covers.bytes
        writeFile(mdir() .. "/status.lua", C().encode(status(s, plan)))
        summary(plan, "busy", s, { changed = {}, written = {} }, 0)
        return
    end
    st.run_bytes0, st.run_cover0 = st.bytes, st.covers.bytes
    st.base_other, st.base_mirror_cover = 0, 0
    if plan.limit then
        -- Everything else that counts toward the limit, as it stands now (CacheWorker.run).
        for _, e in ipairs(F.storageItems(plan.cover_dir, plan.covers_on, 0)) do
            if e.kind == "kept" then st.base_other = st.base_other + e.bytes
            elseif e.kind == "mirror_cover" then st.base_mirror_cover = st.base_mirror_cover + e.bytes end
        end
    end
    local out, jobs = { changed = {}, written = {} }, 0
    F.running, F.transport, F.trace = plan.run, 0, {}
    writeFile(mdir() .. "/status.lua", C().encode(status(st, plan, true)))
    local function step()
        W.in_companion = true
        local okr, err = pcall(F.step, st, plan, out, function() return jobs end, function(n) jobs = n end, step)
        W.in_companion = nil
        if not okr then error(err, 0) end
    end
    F.steps = F.steps or {}
    UIManager:scheduleIn(F.step_s, step)
end

-- One second of the companion's run.
function F.step(st, plan, out, getJobs, setJobs, again)
    local jobs = getJobs()
    local transport = F.transport or 0
    do
        if F.running ~= plan.run then return end -- the companion was stopped (F.kill)
        local why
        for _ = 1, F.rate do
            local q, job = peek(st)
            if not job then why = "finished"; break end
            if readFile(mdir() .. "/stop") then why = "stopped"; break end
            jobs = jobs + 1
            setJobs(jobs)
            if not limited(st, plan, job) then
                if doJob(st, plan, q, job, out) then
                    transport = transport + 1
                    if transport >= 2 then why = "no answer"; break end
                else transport = 0 end
                table.insert(F.trace, { k = job.k, total = st.total })
            end
        end
        F.transport = transport
        if not why then
            writeFile(mdir() .. "/status.lua", C().encode(status(st, plan, true)))
            persist(st)
            return UIManager:scheduleIn(F.step_s, again)
        end
        if why == "finished" then
            if st.revalidating then st.revalidating, out.revalidated = nil, true
            elseif st.op == "full" then st.at, st.lib_version, out.saved = now(), plan.lib_version, true end
            st.seen = {}
        end
        F.running = nil
        persist(st)
        writeFile(mdir() .. "/status.lua", C().encode(status(st, plan)))
        summary(plan, why, st, out, jobs)
    end
end

-- A cache check, as CacheWorker.check: answered with a "checked" event.
function F.check(extras)
    F.checks = F.checks + 1
    UIManager:scheduleIn(0.2, function()
        W.in_companion = true
        local okc, err = pcall(F.checkNow, extras)
        W.in_companion = nil
        if not okc then error(err, 0) end
    end)
end

function F.checkNow(extras)
    do
        local k, path = extras.cache_key, extras.path
        table.insert(F.calls, "CHECK " .. path)
        local ev = { kind = "checked", key = k }
        local b, e = fetch(path)
        if type(b) ~= "table" then ev.err = tostring(e or "no answer")
        else
            local own = load(dir() .. "/" .. E.OC.hash(k) .. ".lua")
            own = own and own.key == k and type(own.body) == "table" and own or nil
            local saved = own and own.body
            if not saved then
                -- The mirror's pages, as OC.lookup cuts them.
                local w = C().listWindow(path)
                if w then
                    for _, size in ipairs({ false, 50, 25 }) do
                        local fk = C().key({ account = extras.owner, server = extras.server, method = "GET", path = C().mirrorPage(w.identity, 1, size or nil) })
                        local first = load(mdir() .. "/" .. E.OC.hash(fk) .. ".lua")
                        if first and first.key == fk then
                            local pages = { first.body }
                            for n = 2, C().pageCount(first.body.total, size or nil) do
                                local pk = C().key({ account = extras.owner, server = extras.server, method = "GET", path = C().mirrorPage(w.identity, n, size or nil) })
                                local pe = load(mdir() .. "/" .. E.OC.hash(pk) .. ".lua")
                                pages[n] = pe and pe.body
                            end
                            saved = C().slice(w, pages, size or nil)
                            break
                        end
                    end
                end
            end
            if not C().revalidate(saved, b, 200) then
                ev.unchanged, ev.saved = true, own and true or nil
            else
                local body = C().settle(saved, b, extras.mode)
                local s = C().encode({ key = k, body = body, fetched_at = now(), validated_at = now(), path = path })
                writeFile(dir() .. "/" .. E.OC.hash(k) .. ".lua", s)
                local ids = {}
                for id in pairs(C().ids(body)) do table.insert(ids, id) end
                ev.changed, ev.bytes, ev.ids, ev.at = true, #s, ids, now()
            end
        end
        F.seq = (F.seq or 0) + 1
        writeFile(string.format("%s/events/%d-0-c%d.lua", dir(), now(), F.seq), C().encode(ev))
    end
end

---------------------------------------------------------------- the storage limit (CacheWorker.storage)

-- StorageLogic.plan: browsing entries and plain covers first, least recently used first; then the
-- covers saved for offline; never "kept".
function F.storagePlan(items, limit)
    local used = 0
    for _, e in ipairs(items) do used = used + (e.bytes or 0) end
    local out = { drop = {}, used = used, after = used }
    if not limit or limit <= 0 or used <= limit then return out end
    for _, tier in ipairs({ { cache = true, cover = true }, { mirror_cover = true } }) do
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

local function fsize(p) return tonumber(require("libs/libkoreader-lfs").attributes(p, "size")) or 0 end

function F.storageItems(cover_dir, mirror_covers, mirror_bytes)
    local items = {}
    local idx = load(dir() .. "/index.lua") or { entries = {} }
    for k, e in pairs(idx.entries or {}) do
        table.insert(items, { k = "e:" .. k, bytes = e.bytes or 0, at = e.used_at or 0, kind = e.keep and "kept" or "cache" })
    end
    table.insert(items, { k = "index", bytes = fsize(dir() .. "/index.lua"), at = 0, kind = "kept" })
    table.insert(items, { k = "mirror", bytes = mirror_bytes or 0, at = 0, kind = "kept" })
    if cover_dir and cover_dir ~= "" then
        local keep = mirror_covers and load(mdir() .. "/cover_keep.lua") or {}
        local lfs = require("libs/libkoreader-lfs")
        local okd, it = pcall(lfs.dir, cover_dir)
        for name in (okd and it or function() end) do
            local a = name:match("%.jpg$") and lfs.attributes(cover_dir .. "/" .. name)
            if type(a) == "table" and a.mode == "file" then
                table.insert(items, { k = "c:" .. name, bytes = (a.size or 0) + fsize(cover_dir .. "/" .. name .. ".etag"),
                    at = a.modification or 0, kind = keep[name] and "mirror_cover" or "cover" })
            end
        end
    end
    return items
end

F.storage_asks = 0
function F.storageNow(extras)
    F.storage_asks = F.storage_asks + 1
    local st = F.state()
    local limit = tonumber(extras.limit)
    local cover_dir = extras.cover_dir ~= "" and extras.cover_dir or nil
    local items = F.storageItems(cover_dir, extras.mirror_covers == "1", st and st.bytes or 0)
    local plan = F.storagePlan(items, limit)
    local by = {}
    for _, e in ipairs(items) do by[e.k] = e end
    local drop, removed = {}, { cache = 0, cover = 0, mirror_cover = 0 }
    for _, k in ipairs(plan.drop) do
        local e = by[k]
        if k:match("^e:") then table.insert(drop, { key = k:sub(3), used_at = e.at })
        elseif cover_dir then os.remove(cover_dir .. "/" .. k:sub(3)); os.remove(cover_dir .. "/" .. k:sub(3) .. ".etag") end
        removed[e.kind] = removed[e.kind] + 1
    end
    local gone, totals = {}, { used = 0, kept = 0, cache = 0, cover = 0, mirror_cover = 0 }
    for _, k in ipairs(plan.drop) do gone[k] = true end
    for _, e in ipairs(items) do
        if not gone[e.k] then totals.used = totals.used + e.bytes; totals[e.kind] = totals[e.kind] + e.bytes end
    end
    writeFile(dir() .. "/storage.lua", C().encode({ totals = totals, at = now() }))
    F.seq = (F.seq or 0) + 1
    writeFile(string.format("%s/events/%d-0-c%d.lua", dir(), now(), F.seq), C().encode({ kind = "storage", why = extras.reason,
        drop = drop, totals = totals, removed = removed, used = plan.used, after = plan.after, limit = limit }))
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
        local idx = load(dir() .. "/index.lua") or { entries = {} }
        for key, meta in pairs(idx.entries or {}) do
            local path = tostring(meta.path or "")
            local id = path:match("/catalog/books/(%d+)$") or path:match("/catalog/books/(%d+)%?")
            if id and want[id] and (not details[id] or (meta.validated_at or 0) >= details[id].at) then
                local e = load(dir() .. "/" .. E.OC.hash(key) .. ".lua")
                if e and e.key == key and type(e.body) == "table" and type(e.body.files) == "table" then details[id] = { files = e.body.files, at = meta.validated_at or 0 } end
            end
        end
        if ask.owner and ask.server and ask.detail_template then
            for id in pairs(want) do
                local k = C().key({ account = ask.owner, server = ask.server, method = "GET", path = fill(ask.detail_template, ask.sentinel, id) })
                local e = load(mdir() .. "/" .. E.OC.hash(k) .. ".lua")
                if e and e.key == k and type(e.body) == "table" and type(e.body.files) == "table"
                    and (not details[id] or (e.validated_at or 0) >= details[id].at) then
                    details[id] = { files = e.body.files, at = e.validated_at or 0 }
                end
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
    F.seq = (F.seq or 0) + 1
    writeFile(string.format("%s/events/%d-0-c%d.lua", dir(), now(), F.seq), C().encode(ev))
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
    local from = SP.parseFrom(plan.from_key)
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
    local idx = load(dir() .. "/index.lua") or { entries = {} }
    for key, meta in pairs(idx.entries or {}) do
        local e = load(dir() .. "/" .. E.OC.hash(key) .. ".lua")
        if e and e.key == key then add(meta.path, e.body) end
    end
    for name in lfs.dir(mdir()) do
        if name:match("^%x+%.lua$") and #name == 12 then local e = load(mdir() .. "/" .. name); if e then add(e.path, e.body) end end
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
    elseif intent.action:match("%.RECHECK$") then F.recheck(intent.extras) end
end

-- The companion was stopped mid-run (its status stops moving).
function F.kill() F.running = nil end

return F

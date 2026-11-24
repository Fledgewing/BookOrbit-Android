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
    local kept = (plan.base_kept or 0) + st.bytes - st.run_bytes0
    local room = covers and (kept + (plan.base_mirror_cover or 0) + st.covers.bytes - st.run_cover0 < limit) or (not covers and kept < limit)
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

function F.receive(intent)
    if not (W.companion and intent.package == "net.fledgewing.orbitcompanion") then return end
    if intent.action:match("%.MIRROR$") then F.mirror(intent.extras)
    elseif intent.action:match("%.CHECK$") then F.check(intent.extras) end
end

-- The companion was stopped mid-run (its status stops moving).
function F.kill() F.running = nil end

return F

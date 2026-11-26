-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- The shared-storage SQLite stress test (docs/design/sqlite-cache.md "Stress test"), a debug item
-- under Orbit › Updates and details. Orbit Companion writes orbit-cache/stress.db nonstop
-- (SQLITE_STRESS, SqliteStress.kt): one page of 100 rows per transaction, every row carrying the
-- page's generation, and a head row with that generation and the rows' length sum. KOReader reads
-- the same file nonstop for as long, in a forked child (never on the UI thread), the way the cache
-- reads: read-only, through lua-ljsqlite3. Every read checks that it saw one whole page; busy
-- waits are counted and timed. The verdict goes to the log and on screen:
--   sqlite-stress: N writes, M reads, 0 errors, max busy wait X ms
---------------------------------------------------------------------------------------------

SqliteStress = { SECONDS = 120, PAGES = 50, ROWS = 100, BUSY_GIVE_UP_S = 10, RESULT_WAIT_S = 30 }

local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then pcall(ffi.cdef, "int usleep(unsigned int);") end

local function clock()
    local oks, socket = pcall(require, "socket")
    if oks and type(socket) == "table" and socket.gettime then return socket.gettime() end
    return os.time()
end
SqliteStress.clock = clock

local function nap()
    if ffi_ok then pcall(function() ffi.C.usleep(1000) end) end
end

function SqliteStress.file() return Store.dir() .. "/stress.db" end

-- The writer's row text length for (gen, pos) (SqliteStress.value in the companion).
function SqliteStress.len(gen, pos) return 40 + (gen * 7 + pos * 13) % 160 end

-- One page, in one read transaction. -> "ok" | "empty" (not written yet), or nil, why.
function SqliteStress.readPage(conn, page)
    conn:exec("BEGIN")
    local okr, res, why = pcall(function()
        local head = conn:exec("SELECT gen, sum FROM head WHERE page = " .. math.floor(page))
        if not head then return "empty" end
        local gen, sum = Db.value(head[1][1]), Db.value(head[2][1])
        local rows = conn:exec("SELECT pos, gen, val FROM rows WHERE page = " .. math.floor(page) .. " ORDER BY pos")
        local n = rows and #rows[1] or 0
        if n ~= SqliteStress.ROWS then return nil, "torn page: " .. n .. " rows" end
        local total = 0
        for i = 1, n do
            local g, v = Db.value(rows[2][i]), Db.value(rows[3][i])
            if g ~= gen then return nil, string.format("torn page: row %d of generation %s, head %s", i, tostring(g), tostring(gen)) end
            total = total + #tostring(v)
        end
        if total ~= sum then return nil, "checksum: " .. total .. " ~= " .. tostring(sum) end
        return "ok"
    end)
    pcall(conn.exec, conn, "COMMIT")
    if not okr then error(res, 0) end
    return res, why
end

-- Reads for seconds; busy answers are retried every millisecond (up to BUSY_GIVE_UP_S) and timed.
-- -> { reads, errors, busy, max_busy_ms, first_error }
function SqliteStress.read(path, seconds, now)
    now = now or clock
    local r = { reads = 0, errors = 0, busy = 0, max_busy_ms = 0 }
    local function fail(why)
        r.errors = r.errors + 1
        r.first_error = r.first_error or tostring(why):gsub("\n.*", "")
    end
    local conn
    local t_end = now() + seconds
    local seq = 0
    while now() < t_end do
        if not conn then
            local c, err = Db.connect(path, "ro", 0)
            if c then conn = c else nap() ; if Db.code(err) ~= "cantopen" and err ~= "missing" then fail(err) end end
        end
        if conn then
            seq = seq + 1
            local page = (seq * 7919) % SqliteStress.PAGES
            local t0, waited = now(), false
            while true do
                local okr, res, why = pcall(SqliteStress.readPage, conn, page)
                if okr then
                    if res == "ok" then r.reads = r.reads + 1 elseif res == nil then fail(why) end
                    break
                end
                if Db.code(res) == "busy" or Db.code(res) == "locked" then
                    waited = true
                    if now() - t0 > SqliteStress.BUSY_GIVE_UP_S then fail("busy for " .. SqliteStress.BUSY_GIVE_UP_S .. " s") ; break end
                    nap()
                else
                    fail(res)
                    break
                end
            end
            if waited then
                r.busy = r.busy + 1
                r.max_busy_ms = math.max(r.max_busy_ms, math.floor((now() - t0) * 1000 + 0.5))
            end
        end
    end
    if conn then pcall(conn.close, conn) end
    return r
end

-- The one-line verdict. w: the companion's stress-writer.lua (nil: it never answered).
function SqliteStress.verdict(r, w)
    local errors = (r.errors or 0) + (w and (w.errors or 0) or 1)
    local wait = math.max(r.max_busy_ms or 0, w and (w.max_wait_ms or 0) or 0)
    local line = string.format("sqlite-stress: %d writes, %d reads, %d errors, max busy wait %d ms",
        w and (w.writes or 0) or 0, r.reads or 0, errors, wait)
    local notes = {}
    if not w then table.insert(notes, "the companion's writer didn't answer") end
    if r.first_error then table.insert(notes, "reader: " .. r.first_error) end
    if w and w.first_error then table.insert(notes, "writer: " .. tostring(w.first_error)) end
    if w and w.integrity and w.integrity ~= "ok" then table.insert(notes, "integrity: " .. tostring(w.integrity)) end
    if (r.busy or 0) > 0 then table.insert(notes, r.busy .. " reads waited") end
    return line, notes
end

-- The menu item: the companion writes, a child of KOReader reads, then the verdict.
function SqliteStress.start(seconds)
    seconds = seconds or SqliteStress.SECONDS
    if SqliteStress.running then return orbitNote(_("SQLite stress test already running"), 3) end
    local problem = Companion.workerProblem()
    if problem then return orbitNote(problem, 4) end
    SqliteStress.running = true
    local result = Store.dir() .. "/stress-writer.lua"
    os.remove(result)
    Companion.send(Companion.ACTION.SQLITE_STRESS, { reason = "stress test", seconds = tostring(seconds) })
    log("sqlite-stress: started for", seconds, "s")
    orbitNote(string.format(_("SQLite stress test: %d s. Keep KOReader open."), seconds), 4) -- user action (menu)
    local path = SqliteStress.file()
    UIManager:scheduleIn(2, function()
        Background.run("sqlite-stress", function()
            return Cache.encode(SqliteStress.read(path, seconds))
        end, seconds + 60, function(out, err)
            local r = Cache.decode(out or "") or { errors = 1, first_error = tostring(err or "the reader stopped") }
            local waited = 0
            local function finish()
                local w = Cache.decode(Store.readFile(result) or "")
                if type(w) ~= "table" and waited < SqliteStress.RESULT_WAIT_S then
                    waited = waited + 1
                    return UIManager:scheduleIn(1, finish)
                end
                SqliteStress.running = nil
                local line, notes = SqliteStress.verdict(r, type(w) == "table" and w or nil)
                log(line)
                for _, n in ipairs(notes) do log("sqlite-stress:", n) end
                UIManager:show(InfoMessage:new{ text = line .. (#notes > 0 and ("\n\n" .. table.concat(notes, "\n")) or "") }) -- gate: user action (menu: SQLite stress test)
            end
            finish()
        end)
    end)
end

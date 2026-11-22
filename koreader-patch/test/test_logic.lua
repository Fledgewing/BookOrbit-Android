-- Pure-Lua tests for the patch's scheduling and decision logic.
-- Run from anywhere: luajit koreader-patch/test/test_logic.lua  (or lua 5.1-5.4)
local here = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
ORBIT_ANDROID_TEST = true
local M = dofile(here .. "/../2-orbit-android.lua")
local Schedule, Plan = M.Schedule, M.Plan

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, what)
    if a ~= b then error((what or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

-- Turns `n` pages, all in chapter `key` (nil: no table of contents).
local function turn(s, n, key, t)
    for _ = 1, n do Schedule.onPage(s, key, t) end
end

test("off never fires", function()
    local s = Schedule.new("off", 0)
    turn(s, 500, 1, 0)
    eq(Schedule.isDue(s, 1e6), false)
end)

test("unknown id falls back to off", function()
    eq(Schedule.new("bogus", 0).kind, "off")
end)

test("every option parses", function()
    for _, o in ipairs(Schedule.OPTIONS) do
        local s = Schedule.new(o.id, 0)
        eq(s.id, o.id, "id")
        eq(s.n, o.n, "n for " .. o.id)
    end
    eq(#Schedule.OPTIONS, 10, "option count")
end)

for _, n in ipairs({ 10, 15, 30, 60 }) do
    test("minutes " .. n .. ": due only after the interval and with reading", function()
        local s = Schedule.new("min" .. n, 100)
        eq(Schedule.isDue(s, 100 + n * 60), false, "idle book")
        turn(s, 1, nil, 120)
        eq(Schedule.isDue(s, 100 + n * 60 - 1), false, "just before")
        eq(Schedule.isDue(s, 100 + n * 60), true, "at interval")
        Schedule.markSynced(s, 100 + n * 60)
        eq(Schedule.isDue(s, 100 + n * 60 * 3), false, "idle after sync")
    end)
end

for _, n in ipairs({ 25, 50, 100 }) do
    test("pages " .. n, function()
        local s = Schedule.new("pg" .. n, 0)
        turn(s, n - 1, 1, 0)
        eq(Schedule.isDue(s, 0), false, "one short")
        turn(s, 1, 1, 0)
        eq(Schedule.isDue(s, 0), true, "at n")
        Schedule.markSynced(s, 0)
        eq(Schedule.isDue(s, 0), false, "reset")
        turn(s, n, 1, 0)
        eq(Schedule.isDue(s, 0), true, "again")
    end)
end

test("every chapter: forward chapter change", function()
    local s = Schedule.new("ch1", 0)
    turn(s, 5, 1, 0)
    eq(Schedule.isDue(s, 0), false, "same chapter")
    turn(s, 1, 12, 0)
    eq(Schedule.isDue(s, 0), true, "next chapter")
    Schedule.markSynced(s, 0)
    turn(s, 3, 12, 0)
    eq(Schedule.isDue(s, 0), false, "still chapter 2")
end)

test("every chapter: going back does not count", function()
    local s = Schedule.new("ch1", 0)
    turn(s, 1, 30, 0)
    turn(s, 1, 12, 0)
    eq(Schedule.isDue(s, 0), false, "backwards")
    turn(s, 1, 30, 0)
    eq(Schedule.isDue(s, 0), true, "forward again")
end)

test("every 2 chapters", function()
    local s = Schedule.new("ch2", 0)
    turn(s, 1, 1, 0)
    turn(s, 1, 10, 0)
    eq(Schedule.isDue(s, 0), false, "one chapter")
    turn(s, 1, 20, 0)
    eq(Schedule.isDue(s, 0), true, "two chapters")
end)

test("first page seen does not count as a chapter change", function()
    local s = Schedule.new("ch1", 0)
    turn(s, 1, 40, 0)
    eq(Schedule.isDue(s, 0), false)
end)

test("chapters: book without a toc never fires", function()
    local s = Schedule.new("ch1", 0)
    turn(s, 300, nil, 0)
    eq(Schedule.isDue(s, 0), false)
end)

-- Plan.outboxVerdict
local function v(o)
    o.pending = o.pending or 0; o.elapsed = o.elapsed or 0; o.cap = o.cap or 20; o.since_nudge = o.since_nudge or 0
    return Plan.outboxVerdict(o)
end
test("outbox: empty and idle is done", function() eq(v{ pending = 0, busy = false }, "done") end)
test("outbox: empty but busy waits", function() eq(v{ pending = 0, busy = true }, "wait") end)
test("outbox: pending and busy waits", function() eq(v{ pending = 1, busy = true }, "wait") end)
test("outbox: idle with a new error fails", function() eq(v{ pending = 1, busy = false, new_error = true }, "failed") end)
test("outbox: idle with no error nudges after 2 s", function()
    eq(v{ pending = 1, busy = false, since_nudge = 1 }, "wait")
    eq(v{ pending = 1, busy = false, since_nudge = 2 }, "nudge")
end)
test("outbox: cap reached times out", function() eq(v{ pending = 1, busy = true, elapsed = 20 }, "timeout") end)
test("outbox: done beats the cap", function() eq(v{ pending = 0, busy = false, elapsed = 25 }, "done") end)

-- Plan.readingAction
local P = Plan.STRATEGY
test("reading: no remote position pushes", function() eq(Plan.readingAction{ has_remote = false }, "push") end)
test("reading: same place does nothing", function() eq(Plan.readingAction{ has_remote = true, same_place = true }, "none") end)
test("reading: device ahead pushes", function()
    eq(Plan.readingAction{ has_remote = true, remote_newer = false, forward = P.PROMPT }, "push")
end)
test("reading: server ahead + Silent pulls", function()
    eq(Plan.readingAction{ has_remote = true, remote_newer = true, forward = P.SILENT }, "pull")
end)
test("reading: server ahead + Ask never prompts mid-book", function()
    eq(Plan.readingAction{ has_remote = true, remote_newer = true, forward = P.PROMPT }, "none")
end)
test("reading: server ahead + Don't sync keeps both", function()
    eq(Plan.readingAction{ has_remote = true, remote_newer = true, forward = P.DISABLE }, "none")
end)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end

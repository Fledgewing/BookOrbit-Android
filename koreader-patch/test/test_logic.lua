-- Pure-Lua tests for the patch's scheduling and decision logic.
-- Run from anywhere: luajit koreader-patch/test/test_logic.lua  (or lua 5.1-5.4)
local here = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
ORBIT_ANDROID_TEST = true
local M = dofile(here .. "/../2-orbit-android.lua")
local Schedule, Plan, Update, WifiPlan, HomePlan = M.Schedule, M.Plan, M.Update, M.WifiPlan, M.HomePlan

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function ok(v, what) if not v then error(what or "expected true", 2) end end
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

-- Update: version comparison
local cmp = Update.compare
test("version: parses tags, rejects junk", function()
    local v = Update.parseVersion("v1.2.3-rc.1")
    eq(v[1], 1); eq(v[2], 2); eq(v[3], 3); eq(v.pre, "rc.1")
    eq(Update.parseVersion("1.2.3+build.5").pre, nil)
    eq(Update.parseVersion("1.2"), nil)
    eq(Update.parseVersion("latest"), nil)
    eq(Update.parseVersion("1.2.3-"), nil)
    eq(Update.parseVersion(nil), nil)
end)
test("version: numeric, not text, order", function()
    eq(cmp("0.10.0", "0.9.9"), 1)
    eq(cmp("1.0.0", "0.99.99"), 1)
    eq(cmp("v0.1.0", "0.1.0"), 0)
    eq(cmp("0.1.0", "0.1.1"), -1)
end)
test("version: pre-releases sort before the release", function()
    eq(cmp("0.2.0-rc.1", "0.2.0"), -1)
    eq(cmp("0.2.0", "0.2.0-rc.1"), 1)
    eq(cmp("0.2.0-rc.2", "0.2.0-rc.1"), 1)
    eq(cmp("0.2.0-rc.10", "0.2.0-rc.9"), 1)
    eq(cmp("0.2.0-beta", "0.2.0-rc"), -1)
    eq(cmp("0.2.0-rc", "0.2.0-rc.1"), -1)
    eq(cmp("0.0.0-dev", "0.1.0"), -1)
end)
test("version: unparsable compares as nil", function() eq(cmp("x", "0.1.0"), nil) end)
test("version: the repo copy is a dev version", function() eq(cmp(M.PATCH_VERSION, "0.0.1"), -1) end)

-- Update: release choice
local rels = {
    { tag_name = "v0.3.0-rc.1", prerelease = true },
    { tag_name = "v0.4.0", draft = true },
    { tag_name = "v0.2.0", assets = { { name = "2-orbit-android.lua", browser_download_url = "https://x/lua" } } },
    { tag_name = "nightly" },
    { tag_name = "v0.1.0" },
}
test("pick: newest stable by default", function() eq(Update.pick(rels, false).tag_name, "v0.2.0") end)
test("pick: pre-releases when asked", function() eq(Update.pick(rels, true).tag_name, "v0.3.0-rc.1") end)
test("pick: nothing usable", function() eq(Update.pick({ { tag_name = "v1.0.0-rc.1", prerelease = true } }, false), nil) end)
test("pick: asset url", function()
    eq(Update.assetUrl(Update.pick(rels, false), "2-orbit-android.lua"), "https://x/lua")
    eq(Update.assetUrl(Update.pick(rels, false), "SHA256SUMS"), nil)
end)

-- Update: checksum lines
local A, B = string.rep("a", 64), string.rep("0123456789ABCDEF", 4)
test("sums: sha256sum text and binary lines", function()
    local s = Update.parseSums(A .. "  2-orbit-android.lua\n" .. B .. " *orbit-companion-0.1.0.apk\r\n")
    eq(s["2-orbit-android.lua"], A)
    eq(s["orbit-companion-0.1.0.apk"], B:lower())
end)
test("sums: bad lines are skipped", function()
    local s = Update.parseSums("# c\n\nabc  short.lua\n" .. A .. "x  long.lua\n" .. A .. "  ok.lua\n")
    local n = 0
    for _ in pairs(s) do n = n + 1 end
    eq(n, 1, "count"); eq(s["ok.lua"], A)
end)
test("sums: empty or nil text", function() eq(next(Update.parseSums(nil)), nil); eq(next(Update.parseSums("")), nil) end)

test("stamp: reads the declared version", function()
    eq(Update.stampedVersion('-- x\nlocal PATCH_VERSION = "0.1.0"\n'), "0.1.0")
    eq(Update.stampedVersion("-- nothing here"), nil)
end)

test("due: at most once a day", function()
    eq(Update.isDue(nil, 1000), true)
    eq(Update.isDue(1000, 1000 + 86399), false)
    eq(Update.isDue(1000, 1000 + 86400), true)
    eq(Update.isDue(5000, 1000), true, "clock went back")
end)

-- WifiPlan: restore previous state, idle timer, never off while busy
local function ctx(now, t) t = t or {}; t.now = now; if t.wifi_on == nil then t.wifi_on = true end; return t end
local function act(st, c) local a, why, force = WifiPlan.decide(st, c); return a, why, force end

test("wifi: a flow that turned Wi-Fi on puts it back off, in every mode", function()
    for _, mode in ipairs({ "always_on", "off_reading", "jit" }) do
        local st = WifiPlan.new(mode, 10, 0)
        WifiPlan.acquire(st, "wake", false, 0)
        eq(act(st, ctx(5)), nil, mode .. ": held")
        WifiPlan.release(st, "wake", 10)
        eq(act(st, ctx(11)), nil, mode .. ": grace")
        local a, why = act(st, ctx(13))
        eq(a, "off", mode .. ": restored")
        ok(why:find("restore", 1, true), "reason names the restore")
    end
end)

test("wifi: a flow that found Wi-Fi on leaves it on (always on, not in a book)", function()
    local st = WifiPlan.new("always_on", 2, 0)
    WifiPlan.acquire(st, "wake", true, 0)
    WifiPlan.release(st, "wake", 1)
    eq(act(st, ctx(1000)), nil)
end)

test("wifi: overlapping flows restore once, after the last", function()
    local st = WifiPlan.new("always_on", 2, 0)
    WifiPlan.acquire(st, "wake", false, 0)
    WifiPlan.acquire(st, "reading", true, 1) -- on by now, but the first lease decided
    WifiPlan.release(st, "wake", 2)
    eq(act(st, ctx(10)), nil, "reading still holds it")
    WifiPlan.release(st, "reading", 12)
    eq(act(st, ctx(16)), "off")
end)

test("wifi: never off while busy, a flow holds it, or another app is in front", function()
    local st = WifiPlan.new("jit", 1, 0)
    eq(act(st, ctx(100, { busy = true })), nil, "busy")
    st.foreground = false
    eq(act(st, ctx(100)), nil, "other app")
    eq(act(st, ctx(100, { screen_off = true })), "off", "screen off counts as ours")
    st.foreground = true
    WifiPlan.acquire(st, "test", true, 100)
    eq(act(st, ctx(1000)), nil, "lease")
end)

test("wifi: just in time turns off after the idle time, measured from the last activity", function()
    local st = WifiPlan.new("jit", 2, 0)
    eq(act(st, ctx(119)), nil, "not yet")
    WifiPlan.activity(st, 100)
    eq(act(st, ctx(219)), nil, "activity restarts the timer")
    local a, why = act(st, ctx(220))
    eq(a, "off"); ok(why:find("idle 2 min", 1, true), why)
    eq(act(st, ctx(220, { wifi_on = false })), nil, "already off")
end)

test("wifi: always on and off while reading have no idle timer", function()
    eq(act(WifiPlan.new("always_on", 1, 0), ctx(1e6)), nil)
    eq(act(WifiPlan.new("off_reading", 1, 0), ctx(1e6)), nil)
end)

test("wifi: just in time in a book turns off when the open-time pull is done", function()
    local st = WifiPlan.new("jit", 10, 0)
    WifiPlan.bookOpened(st, true)
    WifiPlan.acquire(st, "open", true, 0)
    eq(act(st, ctx(2)), nil, "pulling")
    WifiPlan.release(st, "open", 4)
    eq(act(st, ctx(7)), "off")
end)

test("wifi: off while reading turns Wi-Fi off at open and back on at close", function()
    local st = WifiPlan.new("off_reading", 2, 0)
    WifiPlan.bookOpened(st, true)
    WifiPlan.acquire(st, "open", true, 0)
    eq(act(st, ctx(1)), nil, "pull first")
    WifiPlan.release(st, "open", 2)
    local a, _why, force = act(st, ctx(5))
    eq(a, "off"); eq(force, true, "applies to Wi-Fi on by hand too")
    WifiPlan.wifiOff(st)
    eq(act(st, ctx(6, { wifi_on = false })), nil)
    eq(WifiPlan.bookClosed(st), "on", "restored")
    WifiPlan.bookOpened(st, false)
    eq(WifiPlan.bookClosed(st), nil, "was off: stays off")
end)

test("wifi: sleep sync hands the restore to the companion", function()
    local st = WifiPlan.new("always_on", 2, 0)
    WifiPlan.acquire(st, "sleep", false, 0)
    WifiPlan.release(st, "sleep", 5, true)
    eq(act(st, ctx(100)), nil)
end)

test("wifi: unknown mode falls back to just in time", function()
    eq(WifiPlan.new("bogus", 2, 0).mode, "jit")
    eq(WifiPlan.validMode("off_reading"), true)
end)

-- HomePlan: the Smart Home decision table
local H = HomePlan.decide
test("home: in a book, pressed in KOReader -> BookOrbit home", function()
    eq(H{ mode = "smart", in_reader = true, covered = false, from_other = false }, "dashboard")
end)
test("home: pressed on BookOrbit home -> the companion, in both modes", function()
    eq(H{ mode = "smart", on_dashboard = true, from_other = false }, "companion")
    eq(H{ mode = "bookorbit", on_dashboard = true, from_other = false }, "companion")
    eq(H{ mode = "smart", in_reader = true, covered = true, on_dashboard = true, from_other = false }, "companion",
        "dashboard over an open book")
end)
test("home: elsewhere with a book open -> the book", function()
    eq(H{ mode = "smart", in_reader = true, covered = false, from_other = true }, "book", "another app in front")
    eq(H{ mode = "smart", in_reader = true, covered = true, from_other = false }, "book", "a menu or BookOrbit view")
    eq(H{ mode = "smart", in_reader = true, covered = true, on_dashboard = true, from_other = true }, "book",
        "from the companion with BookOrbit home over the book: no loop")
end)
test("home: elsewhere with no book open -> BookOrbit home (history is not reopened)", function()
    eq(H{ mode = "smart", in_reader = false, from_other = false }, "dashboard", "file browser")
    eq(H{ mode = "smart", in_reader = false, from_other = true }, "dashboard", "another app")
    eq(H{ mode = "smart", in_reader = false, covered = true, from_other = false }, "dashboard", "other BookOrbit view")
    eq(H{ mode = "smart", on_dashboard = true, from_other = true }, "dashboard", "from the companion, no book")
end)
test("home: cold start after KOReader was killed with a book open -> that book", function()
    eq(H{ mode = "smart", in_reader = false, from_other = true, reopen = true }, "book")
end)
test("home: BookOrbit home mode -> BookOrbit home, except from the dashboard", function()
    eq(H{ mode = "bookorbit", in_reader = true, from_other = true }, "dashboard")
    eq(H{ mode = "bookorbit", in_reader = false, reopen = true }, "dashboard")
    eq(H{ mode = "bookorbit", on_dashboard = true, from_other = true }, "dashboard")
end)
test("wifi_on setting -> radio state", function()
    eq(Plan.wifiOnSetting(1), true); eq(Plan.wifiOnSetting(2), true)
    eq(Plan.wifiOnSetting(0), false); eq(Plan.wifiOnSetting(3), false)
    eq(Plan.wifiOnSetting(-1), nil)
end)
test("update errors: EACCES or a failure with the VPN up -> internet blocked", function()
    local E = Update.errorText
    eq(E("network: permission denied", true, true, true), Update.BLOCKED)
    eq(E("network: connect failed: EACCES", true, true, false), Update.BLOCKED)
    eq(E("network: timeout", true, true, true), Update.BLOCKED)
    eq(E("network: timeout", true, true, false), "no internet (GitHub unreachable: timeout)")
    eq(E("network: timeout", false, false, true), "no internet: Wi-Fi is off")
    eq(E("HTTP 500", true, true, false), "check failed: HTTP 500")
end)
test("home: where Home came from", function()
    eq(HomePlan.cameFromOtherApp("other_app", 0.1), true)
    eq(HomePlan.cameFromOtherApp(nil, 0.8), false, "quick pause: pressed in KOReader")
    eq(HomePlan.cameFromOtherApp(nil, 40), true, "long pause: another app")
    eq(HomePlan.cameFromOtherApp(nil, nil), true, "fresh start")
    eq(HomePlan.cameFromOtherApp("koreader", 40), false)
end)

test("disabled text names the disabler at run time, or stays neutral", function()
    eq(M.disabledText("Orbit Companion", "Meebook Launcher", "Freeze management"),
        "Orbit Companion is disabled by Meebook Launcher: re-enable it in Meebook Launcher › Freeze management.")
    eq(M.disabledText("Orbit Companion", nil, nil), "Orbit Companion is disabled by the system: re-enable it in Settings › Apps.")
end)

test("compat: missing or mistyped plugin symbols turn off only their feature", function()
    local C = M.Compat
    local full = { settings = {} }
    for _, f in ipairs(C.FEATURES) do
        for name, kind in pairs(f.needs) do
            if kind == "function" then full[name] = function() end end
        end
    end
    eq(next(C.check(full)), nil, "complete plugin")
    full._onSuspend = nil
    full.fetchRemoteProgress = "not a function"
    local m = C.check(full)
    eq(m.sleep_snapshot[1], "_onSuspend")
    eq(m.reading_sync[1], "fetchRemoteProgress")
    eq(m.outbox, nil, "others unaffected")
    local lines = C.lines(m, "2.4.0")
    eq(#lines, 2)
    eq(lines[1], "BookOrbit 2.4.0 changed: Sync while reading is off")
end)
test("update: a check failure maps GitHub's EACCES too", function()
    eq(Update.errorText("network: Permission denied", true, true, false), Update.BLOCKED)
end)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
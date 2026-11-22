-- Pure-Lua tests for the patch's scheduling and decision logic.
-- Run from anywhere: luajit android/koreader-patch/test/test_logic.lua  (or lua 5.1-5.4)
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

test("reading schedule request from the companion: valid, newer, applied once", function()
    eq(Schedule.request({ id = "pg50", at = 2000 }, 1000), "pg50")
    eq(select(2, Schedule.request({ id = "pg50", at = 2000 }, nil)), 2000)
    eq(Schedule.request({ id = "pg50", at = 2000 }, 2000), nil, "already applied")
    eq(Schedule.request({ id = "pg50", at = 1500 }, 2000), nil, "older")
    eq(Schedule.request({ id = "bogus", at = 3000 }, 0), nil, "unknown id")
    eq(Schedule.request(nil, 0), nil)
    eq(Schedule.request({ id = "off", at = "4000" }, 0), "off")
end)

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
-- shared/fixtures/github/orbify-releases.json: Android and firmware releases in one list.
local JSON = dofile(here .. "/json_mini.lua")
local orbify = JSON.fixture(here, "github/orbify-releases.json")
test("pick: only Android tags from the shared release list", function()
    eq(Update.pick(orbify, false).tag_name, "android-v0.7.1")
    eq(Update.pick(orbify, true).tag_name, "android-v0.7.2-rc.1")
    eq(Update.parseVersion("xteink-v1.6.1.101+bookorbit.8"), nil)
    eq(Update.compare("android-v0.7.0", "v0.7.0"), 0)
    eq(Update.assetUrl(Update.pick(orbify, false), "2-orbit-android.lua"),
        "https://github.com/Fledgewing/Orbify/releases/download/android-v0.7.1/2-orbit-android.lua")
end)
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
    eq(H{ mode = "smart", in_reader = true, covered = true, from_other = false }, "book", "KOReader's menu")
    eq(H{ mode = "smart", in_reader = true, covered = true, on_dashboard = true, from_other = true }, "book",
        "from the companion with BookOrbit home over the book: no loop")
end)
test("home: elsewhere with no book open -> BookOrbit home (history is not reopened)", function()
    eq(H{ mode = "smart", in_reader = false, from_other = false }, "dashboard", "file browser")
    eq(H{ mode = "smart", in_reader = false, from_other = true }, "dashboard", "another app")
    eq(H{ mode = "smart", in_reader = false, covered = true, from_other = false }, "dashboard", "other BookOrbit view")
    eq(H{ mode = "smart", on_dashboard = true, from_other = true }, "dashboard", "from the companion, no book")
end)
test("home: any BookOrbit screen but its main page -> the main page, in both modes", function()
    eq(H{ mode = "smart", in_reader = true, covered = true, bookorbit_sub = true, from_other = false }, "bookorbit_main")
    eq(H{ mode = "smart", in_reader = false, covered = true, bookorbit_sub = true, from_other = true }, "bookorbit_main")
    eq(H{ mode = "bookorbit", bookorbit_sub = true }, "bookorbit_main")
end)
test("home: a BookOrbit page past the first -> page 1 first (M8C 11-22)", function()
    eq(H{ mode = "smart", on_dashboard = true, page_above_1 = true, from_other = false }, "first_page", "dashboard page 2")
    eq(H{ mode = "bookorbit", on_dashboard = true, page_above_1 = true, from_other = false }, "first_page")
    eq(H{ mode = "smart", bookorbit_sub = true, page_above_1 = true, from_other = false }, "first_page", "a list's page 3")
    eq(H{ mode = "smart", on_dashboard = true, page_above_1 = false, from_other = false }, "companion", "page 1 leaves")
    eq(H{ mode = "smart", on_dashboard = true, page_above_1 = true, from_other = true }, "dashboard",
        "from another app: the usual rule")
end)
test("compat: missingOn names what an object lacks", function()
    local Compat = M.Compat
    eq(#Compat.missingOn({ boardPage = function() end, boardFlip = function() end, listMode = function() end,
        listPaging = function() end, listGoPage = function() end }, Compat.PAGING), 0)
    eq(table.concat(Compat.missingOn({ boardPage = function() end }, Compat.PAGING), ","),
        "boardFlip,listGoPage,listMode,listPaging")
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
test("update errors: VPN lockdown blamed only when the companion reads it on", function()
    local E = Update.errorText
    local up = { wifi_on = true, connected = true }
    eq(E("network: permission denied", { wifi_on = true, connected = true, lockdown = true }), Update.BLOCKED)
    eq(E("network: connect failed: EACCES", up), "no internet: Android refused the connection (connect failed: EACCES)")
    eq(E("network: timeout", { wifi_on = true, connected = true, lockdown = true }), Update.BLOCKED)
    eq(E("network: timeout", up), Update.NO_ANSWER)
    eq(E("network: timeout", { wifi_on = true, connected = true, lockdown = nil }), Update.NO_ANSWER, "unknown is not true")
    eq(E("network: timeout", { wifi_on = true, connected = true, lockdown = false }), Update.NO_ANSWER, "lockdown 0")
    eq(E("network: timeout", { wifi_on = false, connected = false }), "no internet: Wi-Fi is off")
    -- 11-21 Boox: a timeout right after just-in-time Wi-Fi off, no lockdown.
    eq(E("network: timeout", { wifi_on = true, connected = true, lockdown = false, went_down = true }), Update.WENT_DOWN)
    eq(E("HTTP 500", up), "check failed: HTTP 500")
end)
test("update: automatic check gate (backoff, book, Wi-Fi going off, network)", function()
    local G = function(t)
        local c = { enabled = true, now = 100000, checked_at = 0, failed_at = nil, connected = true, in_book = false, off_decided = false }
        for k, v in pairs(t) do c[k] = v end
        return (Update.autoGate(c))
    end
    eq(G{}, true)
    eq(G{ enabled = false }, false)
    eq(G{ checked_at = 100000 - 3600 }, false, "checked today")
    eq(G{ failed_at = 100000 - 3599 }, false, "backoff after a failure")
    eq(G{ failed_at = 100000 - 3600 }, true, "an hour later")
    eq(G{ in_book = true }, false, "never in a book")
    eq(G{ off_decided = true }, false, "never after a Wi-Fi off decision")
    eq(G{ connected = false }, false, "only with the network up")
    local ok2, k, t = Update.decode(Update.encode(false, nil, "network: timeout"))
    eq(ok2, false); eq(k, "net"); eq(t, "network: timeout")
    ok2, k, t = Update.decode(Update.encode(true, "up to date (0.4.3)"))
    eq(ok2, true); eq(k, "msg"); eq(t, "up to date (0.4.3)")
    eq((Update.decode("")), false, "a dead child")
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

test("compat: KOReader 2025.10+ HandlerSandbox (a callable table) counts as a function", function()
    local C = M.Compat
    local sandbox = setmetatable({}, { __call = function(_, module, ...) return true end })
    eq(C.callable(function() end), true)
    eq(C.callable(sandbox), true, "callable table")
    eq(C.callable({}), false, "plain table")
    eq(C.callable("x"), false)
    eq(C.callable(nil), false)
    local p = { settings = {} }
    for _, f in ipairs(C.FEATURES) do
        for name, kind in pairs(f.needs) do
            if kind == "function" then p[name] = name:sub(1, 2) == "on" and sandbox or function() end end
        end
    end
    eq(next(C.check(p)), nil, "2.3.0 on KOReader 2026.07.1: nothing missing")
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
test("update: a connect timeout or reset is retried twice, after 3 s and 10 s", function()
    local tries, slept = 0, {}
    local function sleep(s) table.insert(slept, s) end
    -- Fails twice, then answers: the check succeeds.
    local body = Update.withRetry(function()
        tries = tries + 1
        if tries < 3 then return nil, "network: timeout" end
        return "ok"
    end, sleep)
    eq(body, "ok"); eq(tries, 3); eq(table.concat(slept, ","), "3,10")
    -- Always times out: 3 tries, then the error.
    tries, slept = 0, {}
    local b2, e2 = Update.withRetry(function() tries = tries + 1; return nil, "network: connection reset by peer" end, sleep)
    eq(b2, nil); eq(e2, "network: connection reset by peer"); eq(tries, 3); eq(table.concat(slept, ","), "3,10")
    -- Not transient (EACCES, HTTP 404): no retry.
    for _, e in ipairs({ "network: Permission denied", "HTTP 404", "network: host or service not provided, or not known" }) do
        tries, slept = 0, {}
        Update.withRetry(function() tries = tries + 1; return nil, e end, sleep)
        eq(tries, 1, e); eq(#slept, 0, e)
    end
    ok(Update.TRY_TIMEOUT_S <= 8, "shorter per-try timeout")
end)

test("update: a check failure maps GitHub's EACCES too", function()
    eq(Update.errorText("network: Permission denied", { wifi_on = true, connected = true, lockdown = true }), Update.BLOCKED)
end)

local Stats = M.Stats

test("stats: content type from the file and the view", function()
    eq(Stats.contentOf("/b/x.epub"), "text")
    eq(Stats.contentOf("/b/X.FB2.ZIP"), "text")
    eq(Stats.contentOf("/b/manga.cbz", false), "comic")
    eq(Stats.contentOf("/b/manga.cbz", true), "webtoon", "a comic in continuous mode")
    eq(Stats.contentOf("/b/paper.pdf", true), "pdf", "a PDF in scroll mode stays pdf")
    eq(Stats.contentOf("/b/a.djvu"), "pdf")
    eq(Stats.contentOf("/b/odd.xyz", false, true), "pdf", "unknown, paged engine")
    eq(Stats.contentOf("/b/odd.xyz", false, false), "text", "unknown, flowing engine")
    eq(Stats.contentOf(nil), "none")
end)

test("stats: refreshes split into full and partial", function()
    local a = Stats.new(0)
    for _, m in ipairs({ "full", "flashui", "flashpartial", "partial", "ui", "fast", "a2", "[ui]", "[partial]" }) do
        Stats.refresh(a, m)
    end
    eq(a.full, 3, "full")
    eq(a.partial, 6, "partial")
end)

test("stats: batches every 5 minutes with a book open, never per page", function()
    local a = Stats.new(0)
    for _ = 1, 40 do Stats.page(a); Stats.refresh(a, "partial") end
    eq(Stats.isDue(a, 299, true), false, "not before 5 min")
    eq(Stats.isDue(a, 300, true), true, "due at 5 min")
    local b = Stats.take(a, 300, "text", true, { wifi_mode = "jit" })
    eq(b.pages, "40"); eq(b.partial, "40"); eq(b.full, "0")
    eq(b.period_s, "300"); eq(b.reading_min, "5.0"); eq(b.content, "text"); eq(b.open, "1")
    eq(b.seq, "1"); eq(b.wifi_mode, "jit")
    eq(a.pages, 0, "reset after a batch")
    eq(Stats.isDue(a, 500, true), false)
    eq(Stats.take(a, 600, "text", true).seq, "2", "sequence counts up")
end)

test("stats: nothing to send without a book and counts, or while paused", function()
    local a = Stats.new(0)
    eq(Stats.isDue(a, 1000, false), false, "file browser, nothing counted")
    eq(Stats.take(a, 1000, "none", false), nil)
    Stats.refresh(a, "ui")
    eq(Stats.isDue(a, 1400, false), true, "file browser refreshes still go out")
    eq(Stats.take(a, 1400, "none", false).reading_min, "0.0")
    a.at = nil
    Stats.page(a)
    eq(Stats.isDue(a, 9999, true), false, "paused by a suspend")
    eq(Stats.take(a, 9999, "text", false), nil)
end)

local Clicks = M.Clicks

test("clicks: the key map keeps known actions only, keyed by keycode", function()
    local m = Clicks.parse({ ["87"] = { press = "next", hold = "nuke" }, ["66"] = { press = "nothing" }, x = { press = "next" } })
    eq(m[87].press, "next")
    eq(m[87].hold, nil, "unknown action dropped")
    eq(m[66], nil, "nothing: not ours")
    eq(next(Clicks.parse(nil)), nil)
end)

test("clicks: plain press fires on key down, no delay", function()
    local st, a = {}, { press = "next" }
    eq(Clicks.down(st, 0, a), "press")
    eq(Clicks.down(st, 0.05, a), nil, "repeat while down")
    eq(Clicks.up(st, 0.1, a), nil)
    eq(Clicks.nextDue(st, a), nil)
end)

test("clicks: hold at 0.6 s while down, else a press on release", function()
    local st, a = {}, { press = "next", hold = "sync_sleep" }
    eq(Clicks.down(st, 10, a), nil)
    eq(Clicks.nextDue(st, a), 10.6)
    eq(Clicks.tick(st, 10.59, a), nil)
    eq(Clicks.tick(st, 10.6, a), "hold")
    eq(Clicks.up(st, 11, a), nil)
    eq(Clicks.down(st, 20, a), nil)
    eq(Clicks.up(st, 20.2, a), "press")
end)

test("clicks: double within 0.35 s, else the single after the window", function()
    local st, a = {}, { press = "light", double = "home" }
    Clicks.down(st, 0, a); eq(Clicks.up(st, 0.1, a), nil)
    eq(Clicks.down(st, 0.3, a), "double")
    eq(Clicks.up(st, 0.35, a), nil)
    eq(Clicks.tick(st, 5, a), nil)
    Clicks.down(st, 10, a); Clicks.up(st, 10.1, a)
    eq(Clicks.tick(st, 10.44, a), nil)
    eq(Clicks.tick(st, 10.45, a), "press")
end)

test("clicker: one path; the patch's own keys only when the service can't", function()
    eq(Clicks.ownPath(false, false), true)
    eq(Clicks.ownPath(true, false), true, "service off")
    eq(Clicks.ownPath(false, true), true, "no channel")
    eq(Clicks.ownPath(true, true), false, "service handles them: never two page turns")
    local k, v = Clicks.parseLine("CLICK next 3")
    eq(k, "click"); eq(v, "next")
    k, v = Clicks.parseLine("CLICK nuke 4")
    eq(k, "click"); eq(v, nil)
    k, v = Clicks.parseLine("SERVICE off")
    eq(k, "service"); eq(v, false)
    eq(Clicks.parseLine("HTTP/1.1 200 OK"), nil)
end)

-- SetupPrompt: the one-time setup box, never in a book
local SetupPrompt = M.SetupPrompt
test("setup box: only off a book, once per key, never when snoozed", function()
    local pr = { key = "clicker", rows = { "Clicker buttons (accessibility)" } }
    eq(SetupPrompt.decide(pr, "reader", nil), false, "never in a book")
    eq(SetupPrompt.decide(pr, "browser", nil), true)
    eq(SetupPrompt.decide(pr, "bookorbit", nil), true)
    eq(SetupPrompt.decide(pr, "menu", nil), true)
    eq(SetupPrompt.decide(pr, "browser", "clicker"), false, "already shown")
    eq(SetupPrompt.decide({ key = "clicker,keyboard" }, "browser", "clicker"), true, "a new row shows again")
    eq(SetupPrompt.decide(nil, "browser", nil), false, "snoozed or nothing: the companion sends none")
    eq(SetupPrompt.decide({ key = "" }, "browser", nil), false)
    eq(SetupPrompt.text(pr), "Orbit Companion needs 1 setup step: Clicker buttons (accessibility).")
    ok(SetupPrompt.text({ key = "a,b", rows = { "A", "B" } }):find("2 setup steps:\n• A\n• B", 1, true))
end)

test("menu lock: only on the companion's pin_locked = true; no answer stays usable", function()
    local L = M.MenuLock
    eq(L.locked({ pin_locked = true }), true, "locked")
    eq(L.locked({ pin_locked = false }), false, "unlocked")
    eq(L.locked({}), false, "older companion without the field")
    eq(L.locked(nil), false, "companion unreachable")
    eq(L.locked({ pin_locked = "true" }), false, "only a real boolean locks")
end)

test("restart plan: a newer file loads now, or after the book; one try per version", function()
    local R = M.RestartPlan
    eq(R.fileVersion('\n-- x\nlocal PATCH_VERSION = "0.5.0"\n'), "0.5.0")
    eq(R.fileVersion("-- no version"), nil)
    eq(R.decide(nil, "0.4.9", nil, false, "check"), "none", "no file")
    eq(R.decide("0.4.9", "0.4.9", nil, false, "check"), "none", "already running it")
    eq(R.decide("0.4.8", "0.4.9", nil, false, "check"), "none", "older file never restarts")
    eq(R.decide("0.5.0", "0.4.9", nil, false, "check"), "restart", "no book: at once")
    eq(R.decide("0.5.0", "0.4.9", nil, true, "check"), "wait", "a book open: never interrupts reading")
    eq(R.decide("0.5.0", "0.4.9", nil, true, "sleep"), "restart", "the device sleeping")
    eq(R.decide("0.5.0", "0.4.9", "0.5.0", false, "check"), "gave_up", "restarted for it and still old")
    eq(R.decide("0.5.1", "0.4.9", "0.5.0", false, "check"), "restart", "a newer file gets its own try")
    eq(R.decide("0.5.0", "0.5.0", "0.5.0", false, "check"), "done", "loaded after its restart")
    eq(R.decide("0.0.0-dev", "0.0.0-dev", nil, false, "check"), "none", "dev build")
    eq(R.doneText("0.5.0"), "Updated to v0.5.0 (KOReader restarted)")
end)

test("compat: Make BookOrbit home is written only where the plugin knows the setting", function()
    local C = M.Compat
    eq(C.settable({}, "catalog_auto_open", "home"), true, "unset (the plugin's default, off)")
    eq(C.settable({ catalog_auto_open = "filemanager" }, "catalog_auto_open", "home"), true, "a known mode")
    eq(C.settable({ catalog_auto_open = "always" }, "catalog_auto_open", "home"), false, "a mode we don't know")
    eq(C.settable({ catalog_auto_open = 3 }, "catalog_auto_open", "home"), false, "not a string")
    eq(C.settable(nil, "catalog_auto_open", "home"), false, "no settings table")
    eq(C.settable({}, "catalog_auto_open", "bogus"), false, "a value the plugin doesn't take")
end)

-- Lists by series and by author (Group)
local G = M.Group
local function bk(id, t)
    t.id = id
    t.title = t.title or ("Book " .. id)
    t.authors = t.authors or { "Rick Riordan" }
    return t
end
-- A shelf: Percy Jackson (ids, one missing from the shelf), Skyward by name only (an older
-- server), two standalones, one book by two authors.
local shelf = {
    bk(1, { seriesId = 7, seriesName = "Percy Jackson", seriesIndex = "2", readStatus = "read" }),
    bk(2, { seriesId = 7, seriesName = "Percy Jackson", seriesIndex = "1", readStatus = "read" }),
    bk(3, { seriesId = 7, seriesName = "Percy Jackson", seriesIndex = "5", readStatus = "reading", lastReadAt = "2026-11-20" }),
    bk(4, { seriesId = 7, seriesName = "Percy Jackson", seriesIndex = "5.5" }),
    bk(5, { seriesName = "Skyward", seriesIndex = "1", authors = { "Brandon Sanderson" }, readStatus = "rereading" }),
    bk(6, { seriesName = "skyward", seriesIndex = "2", authors = { "Brandon Sanderson" } }),
    bk(7, { authors = { "Brandon Sanderson" }, title = "Tress", addedAt = "2026-01-02" }),
    bk(8, { authors = { "Nnedi Okorafor", "Brandon Sanderson" }, title = "Akata Witch", readStatus = "skimmed" }),
    bk(9, { seriesId = 9, seriesName = "Émile's Tales", seriesIndex = "1", authors = { "Émile Zola" } }),
}

test("lists: series rows from the list's books, in the plugin's section shape", function()
    local rows = G.series(shelf)
    eq(#rows, 3, "Percy, Skyward (by name), Émile")
    local pj = rows[1]
    eq(pj.title, "Percy Jackson"); eq(pj.id, "series:7"); eq(pj.seriesId, 7); eq(pj.count, 4)
    eq(pj.readingCount, 1); eq(pj.finishedCount, 2); eq(pj.letter, "P")
    eq(table.concat(pj.memberStates, ","), "finished,finished,reading,unread", "series order")
    eq(pj.previewBooks[1].id, 2, "first by series index"); eq(#pj.previewBooks, 3)
    eq(table.concat(pj.authorNames, ","), "Rick Riordan")
    local sky = rows[2]
    eq(sky.seriesId, nil, "no seriesId: grouped by name"); eq(sky.count, 2, "names fold case"); eq(sky.id, "Skyward")
    eq(sky.readingCount, 1, "rereading counts as reading")
    eq(rows[3].letter, "E", "accents fold for the letter")
    eq(G.bucket("on_hold"), "reading"); eq(G.bucket("abandoned"), "finished"); eq(G.bucket("want_to_read"), "unread"); eq(G.bucket(nil), "unread")
end)

test("lists: author rows count a book for each of its authors", function()
    local rows = G.sectionBody(G.authors(shelf), "authors", {}).items
    eq(#rows, 4)
    local bs = rows[1]
    eq(bs.title, "Brandon Sanderson"); eq(bs.id, "Brandon Sanderson"); eq(bs.count, 4)
    eq(bs.readingCount, 1); eq(bs.finishedCount, 1); eq(bs.seriesName, "Skyward", "their series with the most books")
    eq(bs.previewBooks[1].id, 5, "reading first"); eq(bs.previewBooks[2].id, 8, "then finished")
    eq(rows[2].title, "Émile Zola", "A-Z with accents folded")
end)

test("lists: sort, filter, q, buckets and offset slicing copy the server", function()
    local rows = G.series(shelf)
    local b = G.sectionBody(rows, "series", {})
    eq(b.total, 3); eq(b.items[1].title, "Émile's Tales"); eq(b.items[3].title, "Skyward")
    eq(b.buckets[1].key, "E"); eq(b.buckets[1].index, 0); eq(b.buckets[3].key, "S"); eq(b.buckets[3].index, 2)
    b = G.sectionBody(rows, "series", { sort = "name_desc" })
    eq(b.items[1].title, "Skyward")
    b = G.sectionBody(rows, "series", { sort = "books" })
    eq(b.items[1].title, "Percy Jackson"); eq(b.buckets, nil, "no buckets by most books")
    eq(G.sectionBody(rows, "series", { filter = "reading" }).total, 2, "under way: Percy (reading) and Skyward (rereading)")
    eq(G.sectionBody(rows, "series", { filter = "finished" }).total, 0, "all finished")
    local done = G.series({ bk(20, { seriesId = 1, seriesName = "Done", readStatus = "read" }), bk(21, { seriesId = 1, seriesName = "Done", readStatus = "read" }),
        bk(22, { seriesId = 2, seriesName = "Half", readStatus = "read" }), bk(23, { seriesId = 2, seriesName = "Half" }) })
    eq(G.sectionBody(done, "series", { filter = "finished" }).items[1].title, "Done")
    eq(G.sectionBody(done, "series", { filter = "reading" }).items[1].title, "Half", "some but not all finished is under way")
    local authors = G.authors(shelf)
    eq(G.sectionBody(authors, "authors", { filter = "finished" }).total, 3, "an author with one book finished")
    eq(G.sectionBody(rows, "series", { q = "emile" }).items[1].title, "Émile's Tales", "q folds accents")
    eq(G.sectionBody(rows, "series", { q = "JACK" }).total, 1)
    local p2 = G.sectionBody(rows, "series", { size = 2, offset = 2 })
    eq(#p2.items, 1); eq(p2.items[1].title, "Skyward"); eq(p2.page, 2); eq(p2.offset, 2); eq(p2.hasNext, false); eq(p2.hasPrevious, true)
    local pg = G.sectionBody(rows, "series", { size = 2, page = 1 })
    eq(#pg.items, 2); eq(pg.hasNext, true); eq(pg.offset, nil)
end)

test("lists: an author's books by series, with Not in a series last", function()
    local mine = G.select(shelf, "Brandon Sanderson", nil)
    eq(#mine, 4)
    local b = G.sectionBody(G.series(mine), "series", { sort = "books" }, G.standalone(mine))
    eq(b.total, 2); eq(b.items[1].title, "Skyward"); eq(b.items[2].title, "Not in a series"); eq(b.items[2].count, 2)
    eq(b.items[2].id, G.STANDALONE)
    eq(G.sectionBody(G.series(mine), "series", { q = "sky" }, G.standalone(mine)).total, 1, "a name filter leaves it out")
    eq(#G.select(shelf, "Brandon Sanderson", G.STANDALONE), 2, "its books")
    eq(#G.select(shelf, "Brandon Sanderson", "name:skyward"), 2)
end)

test("lists: which list a book list is, and the request that reads it all", function()
    eq(G.listOf({ collectionId = 4, libraryId = 2 }).section, "collections")
    eq(G.listOf({ smartScopeId = "3" }).id, 3)
    eq(G.listOf({ libraryId = 2 }).section, "libraries")
    eq(G.listOf({ sort = "title" }), nil, "All books")
    local q = G.fetchParams({ collectionId = 4, readStatus = "unread", sort = "author", page = 3, size = 12, offset = 24, on_device_filter = true, orbitGroup = "g1" }, 2)
    eq(q.collectionId, 4); eq(q.readStatus, "unread", "the shelf's filters"); eq(q.size, 100); eq(q.page, 2); eq(q.sort, "title")
    eq(q.offset, nil); eq(q.on_device_filter, nil); eq(q.orbitGroup, nil)
end)

test("lists: drill-down params per list kind", function()
    local some = { shelf[1], shelf[2] }
    local p, how = G.drill({ section = "libraries", id = 2 }, { libraryId = 2, readStatus = "unread", sort = "title" }, some,
        { sort = "series", seriesId = 7 }, { orbitGroup = "g1" })
    eq(how, "server"); eq(p.libraryId, 2); eq(p.seriesId, 7); eq(p.readStatus, "unread"); eq(p.sort, "series"); eq(p.ids, nil); eq(p.orbitGroup, "g1")
    p = G.drill({ section = "collections", id = 4 }, { collectionId = 4 }, some, { series = "Skyward", author = "B" }, {})
    eq(p.collectionId, 4); eq(p.series, "Skyward"); eq(p.author, "B")
    p, how = G.drill({ section = "smart-scopes", id = 3 }, { smartScopeId = 3 }, some, { sort = "series", seriesId = 7 }, {})
    eq(how, "ids"); eq(p.ids, "1,2"); eq(p.smartScopeId, nil, "the server would drop the other filters"); eq(p.seriesId, 7)
    local many = {}
    for i = 1, 201 do many[i] = { id = i } end
    p, how = G.drill({ section = "smart-scopes", id = 3 }, { smartScopeId = 3 }, many, { sort = "title" }, { orbitGroup = "g1" })
    eq(how, "held", "past the ids cap: the books held here"); eq(p.ids, nil); eq(p.orbitLocal, "1")
    p, how = G.drill({ section = "collections", id = 4 }, { collectionId = 4 }, some, { sort = "title" }, {}, true)
    eq(how, "ids", "flat: by id in any list"); eq(p.collectionId, nil)
end)

test("lists: held books answer a request the way the server pages it", function()
    local token = G.remember({ list = { section = "smart-scopes", id = 3 }, params = {}, title = "Unread fantasy", books = shelf })
    local params = { orbitGroup = token, orbitLocal = "1", orbitAuthor = "Rick Riordan", orbitSeries = "id:7", sort = "series", size = 2, page = 2 }
    local books = G.localBooks(params)
    eq(#books, 4)
    local b = G.booksBody(books, params)
    eq(b.total, 4); eq(#b.items, 2); eq(b.items[1].id, 3, "series order, page 2"); eq(b.page, 2); eq(b.hasNext, false)
    eq(G.booksBody(books, { readStatus = "finished", sort = "title" }).total, 2)
    eq(G.booksBody(G.localBooks({ orbitGroup = token }), { sort = "recently_added", size = 1 }).items[1].id, 7, "newest first")
    eq(G.localBooks({ orbitGroup = "gone" }), nil)
    local s = G.strip({ orbitGroup = token, orbitLocal = "1", ids = "1,2", sort = "title" })
    eq(s.orbitGroup, nil); eq(s.orbitLocal, nil); eq(s.ids, "1,2")
    local plain = { sort = "title" }
    eq(G.strip(plain), plain, "nothing to strip: the same table")
    for _ = 1, G.SNAPSHOTS do G.remember({ books = {} }) end
    eq(G.held[token], nil, "the oldest held list goes")
end)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
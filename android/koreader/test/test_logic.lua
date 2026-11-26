-- @fixture orbismart/cases.json
-- Pure-Lua tests for the patch's scheduling and decision logic.
-- Run from anywhere: luajit android/koreader/test/test_logic.lua  (or lua 5.1-5.4)
local here = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
ORBIT_ANDROID_TEST = true
local M = dofile(here .. "/../orbit.koplugin/main.lua")
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
test("version: preview, candidate, stable and an installed rc.17", function()
    local sequence = { "0.11.3-rc.17", "0.11.4-preview.1", "0.11.4-preview.2", "0.11.4-rc.1", "0.11.4" }
    for i = 2, #sequence do
        eq(cmp(sequence[i - 1], sequence[i]), -1)
        eq(cmp(sequence[i], sequence[i - 1]), 1)
    end
    eq(cmp("0.11.4-preview.10", "0.11.4-preview.2"), 1)
    eq(cmp("v0.11.4-preview.1", "0.11.3-rc.17"), 1)
end)

test("version: the repo copy is a dev version", function() eq(cmp(M.PATCH_VERSION, "0.0.1"), -1) end)

test("version: a test build sorts before the next release", function()
    local t = "0.11.3-0.test.42"
    eq(cmp("0.11.2", t), -1)
    eq(cmp("0.11.3", t), 1)
    eq(cmp("0.11.3-rc.1", t), 1)
    eq(cmp("0.11.3-alpha", t), 1)
    eq(Update.parseVersion("xteink-v1.6.1.101+bookorbit.8"), nil)
    eq(cmp("android-v0.7.0", "v0.7.0"), 0)
end)
local JSON = dofile(here .. "/json_mini.lua")

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
test("home: where Home came from", function()
    eq(HomePlan.cameFromOtherApp("other_app", 0.1), true)
    eq(HomePlan.cameFromOtherApp(nil, 0.8), false, "quick pause: pressed in KOReader")
    eq(HomePlan.cameFromOtherApp(nil, 40), true, "long pause: another app")
    eq(HomePlan.cameFromOtherApp(nil, nil), true, "fresh start")
    eq(HomePlan.cameFromOtherApp("koreader", 40), false)
end)

test("home: BookOrbit Home keeps the rotation the device is held in", function()
    local R = HomePlan.rotation
    -- The reported case: held upside down (left-handed) in another app; KOReader's file browser
    -- had forced upright; Home opens BookOrbit Home -> turn back to the held rotation.
    eq(R{ action = "dashboard", held = "reverse_portrait", current = 0 }, 2)
    eq(R{ action = "bookorbit_main", held = "landscape", current = 0 }, 1)
    eq(R{ action = "first_page", held = "reverse_landscape", current = 2 }, 3)
    eq(R{ action = "dashboard", held = "portrait", current = 2 }, 0, "held upright, KOReader upside down")
    eq(R{ action = "dashboard", held = "reverse_portrait", current = 2 }, nil, "already right")
    eq(R{ action = "book", held = "reverse_portrait", current = 0 }, nil, "a book applies its own rotation")
    eq(R{ action = "dashboard", held = "reverse_portrait", current = 0, in_reader = true }, nil,
        "over an open book: the book's rotation, never saved into it")
    eq(R{ action = "companion", held = "reverse_portrait", current = 0 }, nil, "the companion follows the system")
    eq(R{ action = "dashboard", held = "reverse_portrait", current = 0, locked = true }, nil, "Lock auto rotation")
    eq(R{ action = "dashboard", held = nil, current = 0 }, nil, "older companion: no extra")
    eq(R{ action = "dashboard", held = "sideways", current = 0 }, nil, "unknown value")
end)

-- The early user patch (patches/1-orbit-start-rotation.lua) with KOReader's start stubbed:
-- reader.lua runs it (:26-27), opens the settings (:39), inits the Device (:157), runs the late
-- patches (:190), then shows the file browser (:291).
local function startWithPatch(o)
    local names = { "android", "luasettings", "userpatch", "apps/filemanager/filemanager" }
    local saved = {}
    for _, n in ipairs(names) do saved[n] = package.loaded[n] end
    local r = { fm_turns = 0, applied = {} }
    package.loaded.android = { orientation = { get = function() return o.display end },
        hasNativeRotation = function() return o.native ~= false end }
    local LuaSettings = {}
    function LuaSettings:open(path)
        local data = { lock_rotation = o.locked, closed_rotation_mode = o.closed }
        return { path = path, data = data,
            isTrue = function(_, k) return data[k] == true end,
            saveSetting = function(_, k, v) data[k] = v end }
    end
    local userpatch = { early = "1", late = "2" }
    function userpatch.applyPatches(p) table.insert(r.applied, p) end
    local FM = {}
    function FM.setRotationMode() r.fm_turns = r.fm_turns + 1 end
    package.loaded.luasettings, package.loaded.userpatch = LuaSettings, userpatch
    package.loaded["apps/filemanager/filemanager"] = FM
    ORBIT_START_ROTATION = nil
    local okp, err = pcall(dofile, here .. "/../orbit.koplugin/patches/1-orbit-start-rotation.lua")
    if okp then
        r.settings = LuaSettings:open("/sdcard/koreader/settings.reader.lua")
        r.other = LuaSettings:open("/sdcard/koreader/settings/x.lua")
        userpatch.applyPatches(userpatch.late)
        FM:setRotationMode() -- the first showFiles
        FM:setRotationMode() -- a later file browser
    end
    r.start_rotation = ORBIT_START_ROTATION
    ORBIT_START_ROTATION = nil
    for _, n in ipairs(names) do package.loaded[n] = saved[n] end
    if not okp then error(err) end
    return r
end

test("start patch: KOReader starts in the held rotation, no turn", function()
    -- Held upside down; KOReader closed upright last time; the file browser's default is upright.
    local r = startWithPatch{ display = 2, closed = 0 }
    eq(r.settings.data.closed_rotation_mode, 2, "Device init keeps the held rotation")
    eq(r.other.data.closed_rotation_mode, 0, "only settings.reader.lua")
    eq(r.fm_turns, 1, "the first file browser skips its rotation; later ones are KOReader's again")
    eq(r.applied[1], "2", "the late patches still run")
    eq(r.start_rotation, 2, "the plugin is told")
end)

test("start patch: Lock auto rotation, or no native rotation: KOReader as it is", function()
    local r = startWithPatch{ display = 2, closed = 0, locked = true }
    eq(r.settings.data.closed_rotation_mode, 0)
    eq(r.fm_turns, 2)
    eq(r.start_rotation, nil)
    r = startWithPatch{ display = 2, closed = 0, native = false }
    eq(r.settings.data.closed_rotation_mode, 0, "the patch did nothing")
    eq(r.fm_turns, 2)
    eq(r.start_rotation, nil)
    r = startWithPatch{ display = 7, closed = 0 }
    eq(r.start_rotation, nil, "an unknown rotation")
end)

test("disabled text names the disabler at run time, or stays neutral", function()
    eq(M.disabledText("BookSync Companion", "Meebook Launcher", "Freeze management"),
        "BookSync Companion is disabled by Meebook Launcher: re-enable it in Meebook Launcher › Freeze management.")
    eq(M.disabledText("BookSync Companion", nil, nil), "BookSync Companion is disabled by the system: re-enable it in Settings › Apps.")
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
    eq(SetupPrompt.text(pr), "BookSync Companion needs 1 setup step: Clicker buttons (accessibility).")
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
    eq(R.decide("0.5.0", "0.4.9", nil, false, "check"), "wait", "automatic, in front (no book, Home, a list): waits")
    eq(R.decide("0.5.0", "0.4.9", nil, true, "check"), "wait", "a book open: never interrupts reading")
    eq(R.decide("0.5.0", "0.4.9", nil, false, "close"), "wait", "a book closed: still in KOReader, waits")
    eq(R.decide("0.5.0", "0.4.9", nil, true, "background"), "quit", "another app in front: save and quit")
    eq(R.decide("0.5.0", "0.4.9", nil, true, "sleep"), "restart", "the device sleeping")
    eq(R.decide("0.5.0", "0.4.9", "0.5.0", false, "check"), "gave_up", "restarted for it and still old")
    eq(R.decide("0.5.1", "0.4.9", "0.5.0", false, "sleep"), "restart", "a newer file gets its own try")
    eq(R.decide("0.5.0", "0.5.0", "0.5.0", false, "check"), "done", "loaded after its restart")
    eq(R.decide("0.0.0-dev", "0.0.0-dev", nil, false, "check"), "none", "dev build")
    eq(R.decide("0.5.0", "0.4.9", nil, true, "manual"), "restart", "an update the reader asked for: at once, book or not")
    eq(R.decide("0.5.0", "0.4.9", nil, true, "check_asleep"), "wait", "screen off, nobody to relaunch: waits")
    eq(R.doneText("0.5.0"), "Updated to v0.5.0")
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
    -- v0.11.2: the whole library's lists group too (All books, Recently updated); a search, a
    -- series or author page and a list by id don't.
    eq(G.listOf({ sort = "title" }).section, "all", "All books")
    eq(G.listOf({ sort = "recently_updated", order = "desc" }).section, "all", "Recently updated")
    eq(G.listOf({ sort = "title", q = "dune" }), nil, "a search")
    eq(G.listOf({ seriesId = 7, sort = "series" }), nil, "a series page")
    eq(G.listOf({ author = "A", sort = "series" }), nil, "an author page")
    eq(G.listOf({ ids = "1,2", sort = "title" }), nil, "a list by id")
    local all = G.fetchParams({ sort = "recently_updated", order = "desc", readStatus = "unread", page = 4, size = 12 }, 1)
    eq(all.readStatus, "unread", "its filter"); eq(all.sort, "title"); eq(all.order, nil); eq(all.size, 100)
    local dp, dhow = G.drill({ section = "all" }, { readStatus = "unread", sort = "title" }, { { id = 1 } }, { seriesId = 4 }, {})
    eq(dhow, "server", "a row of All books: the server's series page"); eq(dp.seriesId, 4); eq(dp.readStatus, "unread")
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

---------------------------------------------------------------- end of book (Finish)
local F = M.Finish
local FC = JSON.fixture(here, "bookorbit/finish-cases.json")

test("end of book: next in series, suggestions and author from the shared fixtures", function()
    -- @fixture bookorbit/finish-cases.json#picker @fixture bookorbit/catalog-book.no-author.json @fixture bookorbit/catalog-book.no-series.json @fixture bookorbit/catalog-book.series-fractional.json @fixture bookorbit/catalog-book.series-gap.json @fixture bookorbit/catalog-book.series-last-all-read.json @fixture bookorbit/catalog-book.series-last-unread-earlier.json @fixture bookorbit/catalog-book.series-middle.json
    for _, c in ipairs(FC.picker) do
        local d = JSON.fixture(here, "bookorbit/" .. c.fixture)
        local n = F.next(d)
        if c.next == nil then eq(n, nil, c.fixture .. " no next card")
        else
            eq(n.kind, c.next.kind, c.fixture)
            if c.next.id then eq(n.book.id, c.next.id, c.fixture .. " book") end
            if c.next.number then eq(n.number, c.next.number, c.fixture .. " number") end
            if c.next.read ~= nil then eq(n.read, c.next.read, c.fixture .. " read") end
        end
        local nid = n and n.book and n.book.id
        for limit, want in pairs({ [1] = c.suggest1, [2] = c.suggest2 }) do
            local got = F.suggestions(d, limit, nid)
            eq(#got, #want, c.fixture .. " suggestions " .. limit)
            for i, id in ipairs(want) do eq(got[i].book.id, id, c.fixture .. " suggestion " .. i) end
        end
        eq(F.author(d), c.author, c.fixture .. " author")
    end
end)

test("end of book: the card's words", function()
    local d = JSON.fixture(here, "bookorbit/catalog-book.series-gap.json")
    eq(F.nextCard(F.next(d)).line, "Book 3 isn't in your library")
    local m = F.nextCard(F.next(JSON.fixture(here, "bookorbit/catalog-book.series-middle.json")), true)
    eq(m.line, "Next in series · Book 3"); eq(m.title, "Wayfarer Three"); eq(m.action, "open")
    local f = F.nextCard(F.next(JSON.fixture(here, "bookorbit/catalog-book.series-fractional.json")), false)
    eq(f.line, "Next in series · Book 2.5 · Read"); eq(f.action, "download")
    eq(F.nextCard(F.next(JSON.fixture(here, "bookorbit/catalog-book.series-last-all-read.json"))).line, "You've finished the series")
    eq(F.nextCard(F.next(JSON.fixture(here, "bookorbit/catalog-book.series-last-unread-earlier.json"))).line,
        "Last book · not read yet: Book 2")
end)

test("end of book: drain plan, errors and the stale-push hold from the shared table", function()
    -- @fixture bookorbit/finish-cases.json#drain
    for _, c in ipairs(FC.drain) do
        local p = F.plan(F.newJob({ hash = "h", rating = c.job.rating, status_seen = c.job.status_seen }), c.server)
        eq(p.read_status, c.expect.read_status, c.name)
        eq(p.rating, c.expect.rating, c.name .. " rating")
    end
    -- @fixture bookorbit/finish-cases.json#errors
    for _, c in ipairs(FC.errors) do
        local job = F.newJob({ hash = "h" }); job.attempts = c.attempts_before
        eq(F.onError(job, c.code, 1000), c.expect, tostring(c.code))
        if c.next_try_in then eq(job.next_try_at, 1000 + c.next_try_in, tostring(c.code) .. " backoff"); eq(job.parked, c.parked) end
    end
    -- @fixture bookorbit/finish-cases.json#hold
    for i, c in ipairs(FC.hold) do eq(F.holdPush(c.final, c.push, c.forward, c.released), c.expect, "hold " .. i) end
end)

test("end of book: one job per book; Undo deletes it; ratings toggle", function()
    local q = {}
    local a = F.put(q, F.newJob({ hash = "x", now = 5, finished_on = "2026-11-22" }))
    F.setRating(a, 4, nil); eq(a.rating, 4)
    F.setRating(a, 4, 4); eq(a.rating, "clear", "the same star again clears")
    F.setRating(a, 3, nil)
    local b = F.put(q, F.newJob({ hash = "x", now = 9 }))
    eq(b.rating, 3, "the newer job keeps the rating"); eq(q.x, b)
    F.put(q, F.newJob({ hash = "y", now = 7 }))
    local due = F.due(q, 100)
    eq(#due, 2); eq(due[1].hash, "y", "oldest first")
    q.y.parked = true
    eq(#F.due(q, 100), 1, "parked waits"); eq(#F.due(q, 100, true), 2, "a manual sync retries it")
    q.x.next_try_at = 200
    eq(#F.due(q, 100), 0, "backing off")
    ok(F.cancel(q, "x")); eq(q.x, nil); ok(not F.cancel(q, "x"))
    eq(F.day(0), nil, "an unset clock gives no day"); eq(F.day(1795000000, function() return "2026-11-18" end), "2026-11-18")
end)

---------------------------------------------------------------- local-first Home (LocalFirst)
local LF = M.LocalFirst

local function localState(t, keys)
    local by = {}
    for k, v in pairs(t or {}) do by[keys == "string" and tostring(k) or tonumber(k)] = v end
    return { byBookId = by }
end

test("local-first: overlay cases from the shared fixture", function()
    -- @fixture localfirst/overlay-cases.json
    for _, c in ipairs(JSON.fixture(here, "localfirst/overlay-cases.json").cases) do
        local body = c.body
        local before = LF.serialize(body)
        local out = LF.overlay(body, localState(c["local"], c.localKeys))
        eq(LF.serialize(body), before, c.name .. ": the server body is never modified")
        for list, want in pairs(c.expect) do
            if list == "goalDone" then
                eq(out.readingGoal.completedBooks, want, c.name .. " goal")
            else
                local shelf = list:match("^shelf:(.+)$")
                local got = (shelf and (out.boardShelves or {})[shelf] or out[list]) or {}
                eq(#got, #want, c.name .. " " .. list .. " length")
                for i, w in ipairs(want) do
                    for k, v in pairs(w) do eq(got[i][k], v, c.name .. " " .. list .. "[" .. i .. "]." .. k) end
                end
            end
        end
        for id, want in pairs(c.notSynced or {}) do
            eq(LF.notSynced(localState(c["local"]).byBookId[tonumber(id)], c.autoSync), want, c.name .. " not synced")
        end
    end
end)

test("local-first: freshness stamp cases from the shared fixture", function()
    -- @fixture localfirst/stamp-cases.json
    for i, c in ipairs(JSON.fixture(here, "localfirst/stamp-cases.json").cases) do
        eq(LF.stamp(c), c.expect, "stamp " .. i)
    end
end)

test("local-first: ISO times, content keys and changed tiles", function()
    eq(LF.parseIso("1970-01-02T00:00:00.000Z"), 86400)
    eq(LF.parseIso("2026-11-22T10:00:00Z") - LF.parseIso("2026-11-22"), 36000)
    eq(LF.parseIso(nil), nil)
    local d1 = { continue_reading = { { id = 1, progressPercentage = 40.2, readStatus = "reading" } }, shelves = { a = {} },
        goal = { books = 24, done = 6, year = 2026 }, streak = { current = 3 }, week_min = 90, today_min = 10, now = 1 }
    local d2 = { continue_reading = { { id = 1, progressPercentage = 39.8, readStatus = "reading" } }, shelves = { a = {} },
        goal = { books = 24, done = 7, year = 2026 }, streak = { current = 3 }, week_min = 90, today_min = 10, now = 2 }
    local tiles = { { key = "t1", kind = "hero" }, { key = "t2", kind = "goalpace" }, { key = "t3", kind = "clock" },
        { key = "t4", kind = "shelf", source = "a" } }
    local ch = LF.changedTiles(tiles, tiles, d1, d2)
    eq(#ch, 1, "rounded % unchanged; only the goal"); eq(ch[1], "t2")
    eq(#LF.changedTiles(tiles, tiles, d1, d1), 0, "an identical refresh changes no tile")
    eq(LF.changedTiles(tiles, { tiles[1] }, d1, d2), nil, "a different tile set: full repaint")
    ok(LF.tileKey("newwidget", d1) ~= LF.tileKey("newwidget", d2), "unknown types key on all of d")
    eq(LF.tileKey("newwidget", d1), LF.tileKey("newwidget", (function() local c = {} for k, v in pairs(d1) do c[k] = v end c.now = 99 return c end)()),
        "the clock alone changes nothing")
end)

---------------------------------------------------------------- write-through cache (shared cases)
local C = M.Cache
-- The companion's rules as the fake companion plays them (test/companion_rules.lua): checked here
-- against the tables the companion's tests read, so the fake cannot drift from the real worker.
local CR = dofile(here .. "/companion_rules.lua")(C)
local CC = JSON.fixture(here, "cache/cases.json")
local function set(list) local t = {} for _, v in ipairs(list or {}) do t[tostring(v)] = true end return t end
local function sameSet(a, b, what)
    local sa, sb = set(a), set(b)
    for k in pairs(sa) do ok(sb[k], what .. ": unexpected " .. k) end
    for k in pairs(sb) do ok(sa[k], what .. ": missing " .. k) end
end

test("cache: keys (shared cases)", function()
    -- @fixture cache/cases.json#keys
    for _, c in ipairs(CC.keys) do eq(C.key(c.a) == C.key(c.b), c.same, c.name) end
end)

test("cache: what is cached (shared cases)", function()
    -- @fixture cache/cases.json#cacheable
    for _, c in ipairs(CC.cacheable) do eq(C.cacheable(c.method, c.path), c.cached, c.method .. " " .. c.path) end
end)

test("cache: reads (shared cases)", function()
    -- @fixture cache/cases.json#reads
    for _, c in ipairs(CC.reads) do
        local serve, fetch = C.readPlan(c.entry, c.now, c.mode, c.offline)
        eq(serve, c.serve, c.name .. " serve"); eq(fetch, c.fetch, c.name .. " fetch")
    end
end)

test("cache: revalidation (shared cases)", function()
    -- @fixture cache/cases.json#revalidate
    for _, c in ipairs(CC.revalidate) do
        local changed, stored = C.revalidate(c.cached, c.reply, c.status)
        eq(changed, c.changed, c.name .. " changed"); eq(stored, c.stored, c.name .. " stored")
    end
end)

test("cache: writes patch what they change (shared cases)", function()
    -- @fixture cache/cases.json#writes
    for _, c in ipairs(CC.writes) do
        local entries = C.copy(c.entries)
        local stale = {}
        if c.write.status >= 200 and c.write.status < 300 then
            local eff = C.writeEffect(c.write.method, c.write.path, c.write.body)
            -- What the companion is sent (CacheStore.patched applies it; CacheStoreTest reads the same cases).
            eq(eff.id, c.effect.id, c.name .. " effect id"); eq(eff.stale_home, c.effect.stale_home, c.name .. " effect stale_home")
            for k, v in pairs(c.effect.fields) do eq(C.encode(eff.fields[k]), C.encode(v), c.name .. " effect " .. k) end
            for k, v in pairs(eff.fields) do ok(c.effect.fields[k] ~= nil or v == C.NULL, c.name .. " effect sets " .. k) end
            for _, body in pairs(entries) do if eff.id then CR.patch(body, eff.id, eff.fields) end end
            if eff.stale_home then stale = { "dashboard" } end
        else
            eq(c.effect, nil, c.name .. ": a failed write sends nothing")
        end
        for k, want in pairs(c.expect) do eq(C.encode(entries[k]), C.encode(want), c.name .. " " .. k) end
        sameSet(stale, c.stale, c.name .. " stale")
    end
end)

test("companion rules: a check keeps the saved random pick; a Full refresh takes the new one (shared cases)", function()
    -- @fixture cache/cases.json#settle
    for _, c in ipairs(CC.settle) do eq(C.encode(CR.settle(c.cached, c.reply, c.mode)), C.encode(c.expect), c.name) end
end)

test("cache: the offline mirror's list identities, pages, re-paging and TTL (shared cases)", function()
    -- @fixture cache/cases.json#mirror.windows
    for _, c in ipairs(CC.mirror.windows) do
        local w = C.listWindow(c.path)
        if c.list == false then
            eq(w, nil, c.path .. " is not a mirrored list")
        else
            local o = C.listWindow(c.identity_of)
            eq(C.key({ path = w.identity }) == C.key({ path = o.identity }), c.same, c.path)
            eq(C.listWindow(CR.mirrorPage(w.identity, 2)).identity, w.identity, "a mirror page keeps the identity")
        end
    end
    -- @fixture cache/cases.json#mirror.slices
    for _, c in ipairs(CC.mirror.slices) do
        local pages = {}
        for _, n in ipairs(c.saved_pages) do
            local items = {}
            for i = (n - 1) * C.MIRROR_PAGE + 1, math.min(c.total, n * C.MIRROR_PAGE) do table.insert(items, { id = i }) end
            pages[n] = { items = items, total = c.total, page = n, size = C.MIRROR_PAGE, seriesSummary = { total = c.total } }
        end
        local b = C.slice(c.window, pages)
        if c.items == nil then
            eq(b, nil, c.name)
        else
            ok(b, c.name .. ": answered")
            eq(b.items[1].id, c.items[1], c.name .. " first"); eq(b.items[#b.items].id, c.items[2], c.name .. " last")
            eq(b.total, c.total, c.name .. " total"); eq(b.hasNext, c.hasNext, c.name .. " hasNext"); eq(b.hasPrevious, c.hasPrevious, c.name .. " hasPrevious")
            eq(b.seriesSummary.total, c.total, c.name .. " keeps the list's other fields")
        end
    end
    -- @fixture cache/cases.json#mirror.due
    for _, c in ipairs(CC.mirror.due) do eq(C.mirrorDue(c.mirror, c.now, c.ttl_days, c.lib_version), c.due, c.name) end
    ok(C.isSearch("/koreader/plugin/catalog/books?q=dune") and not C.isSearch("/koreader/plugin/catalog/books?page=1"), "search")
end)

test("lists: On device groups by series and author, its rows by id", function()
    local G = M.Group
    local list = G.listOf({ ids = "3,5,9", sort = "title", on_device_filter = true })
    ok(list and list.section == "on-device", "On device is a list")
    eq(G.listOf({ ids = "3,5" }), nil, "ids alone (a grouped row) is not")
    local q = G.fetchParams({ ids = "3,5,9", sort = "title", on_device_filter = true, page = 2 }, 1)
    eq(q.ids, "3,5,9", "reads by its ids"); eq(q.on_device_filter, nil, "never sends the plugin's mark")
    local p, how = G.drill(list, { ids = "3,5,9" }, { { id = 9 }, { id = 3 } }, { seriesId = 4 }, {})
    eq(how, "ids", "a row drills by id"); eq(p.ids, "3,9", "its books")
end)

test("cache: encode is canonical and round-trips", function()
    local v = { b = { 1, 2, { z = "x\n" } }, a = 1.5, c = true, [10] = "ten" }
    eq(C.encode(C.decode(C.encode(v))), C.encode(v))
    eq(C.encode({ a = 1, b = 2 }), C.encode({ b = 2, a = 1 }))
    ok(C.imageHeader("\255\216\255\224xxxx") and C.imageHeader("\137PNG\r\n") and not C.imageHeader("<html>"), "headers")
end)

test("companion rules: the mirror's stop note (shared cases; the eviction order is StorageLogic's)", function()
    -- @fixture cache/cases.json#storage.notes
    for _, c in ipairs(CC.storage.notes) do eq(CR.limitText(c.what, c.done, c.total), c.text, c.text) end
    eq(C.STORAGE_DEFAULT_MB, 250, "250 MB by default")
end)

test("cache: a mirror request with no answer is retried, smaller pages, then skipped (shared cases)", function()
    -- @fixture cache/cases.json#mirror.retry
    for _, c in ipairs(CC.mirror.retry) do
        local r = CR.mirrorRetry(c.tries, c.size, c.page)
        eq(r.skip == true, c.skip == true, c.name .. " skip")
        if not c.skip then eq(r.wait_s, c.wait_s, c.name .. " wait"); eq(r.size, c.size_next, c.name .. " size") end
    end
    -- @fixture cache/cases.json#mirror.small_pages
    for _, c in ipairs(CC.mirror.small_pages) do
        local pages = {}
        for _, n in ipairs(c.saved_pages) do
            local items = {}
            for i = (n - 1) * c.page_size + 1, math.min(c.total, n * c.page_size) do table.insert(items, { id = i }) end
            pages[n] = { items = items, total = c.total, page = n, size = c.page_size }
        end
        eq(C.pageCount(c.total, c.page_size), c.pages, c.name .. " pages")
        local w = C.listWindow(CR.mirrorPage("/koreader/plugin/catalog/sections/series", 3, c.page_size))
        eq(w.size, c.page_size, c.name .. " asks that size")
        local b = C.slice(c.window, pages, c.page_size)
        if c.items == nil then eq(b, nil, c.name) else
            eq(b.items[1].id, c.items[1], c.name .. " first"); eq(b.items[#b.items].id, c.items[2], c.name .. " last")
            eq(b.hasNext, c.hasNext, c.name .. " hasNext")
        end
    end
end)

---------------------------------------------------------------- end-of-book sheet layout
local SL = M.SheetLayout
-- KOReader's Screen:scaleBySize (koreader-base ffi/framebuffer.lua fb:scaleBySize, no DPI override).
local function scaler(w, h) return function(px) return math.ceil(px * (math.min(w, h) / 600)) end end
local function sheetRows(kind)
    local r = { { kind = "status", text = "✓ Marked as finished", label = "Undo" }, { kind = "title", text = "The Lighthouse Keepers" },
        { kind = "author", text = "by Mara Quill ›" }, { kind = "series", text = "Harbour Lights · Book 2 of 4" } }
    for n = 1, 5 do table.insert(r, { kind = "star", n = n }) end
    table.insert(r, { kind = "hint", text = "Tap a star · tap it again to clear" })
    table.insert(r, { kind = "review", text = "Review ›" })
    table.insert(r, { kind = "label", text = "Next in series · Book 3" })
    if kind == "failed" then
        table.insert(r, { kind = "notice", text = "Couldn't connect" })
        table.insert(r, { kind = "button", text = "Try again" })
        table.insert(r, { kind = "button", text = "Get it at the next sync" })
    else
        table.insert(r, { kind = "card", text = "The Storm Signal", sub = "Book 3 · on this reader" })
    end
    table.insert(r, { kind = "label", text = "Also by Mara Quill" })
    table.insert(r, { kind = "card", text = "Fog Days", sub = "on BookOrbit" })
    table.insert(r, { kind = "footer", text = "‹ Back to book" }); table.insert(r, { kind = "footer", text = "Home" })
    return r
end

test("end-of-book sheet: rows never overlap, widths are symmetric, rows fit their text (1404x1872 and others)", function()
    for _, screen in ipairs({ { 1404, 1872 }, { 1072, 1448 }, { 758, 1024 } }) do
        local w, h = screen[1], screen[2]
        local scale = scaler(w, h)
        local m = SL.metrics(w, scale)
        for _, variant in ipairs({ "ok", "failed" }) do
            local blocks = SL.blocks(sheetRows(variant))
            local plan = SL.plan(blocks, m)
            local where = w .. "x" .. h .. " " .. variant
            eq(plan.items[1].kind, "status", where)
            local stars, footer
            for i, it in ipairs(plan.items) do
                eq(it.x, m.pad, where .. " left pad " .. it.kind)
                eq(w - (it.x + it.w), m.pad, where .. " right pad " .. it.kind)
                if i > 1 then
                    local prev = plan.items[i - 1]
                    ok(it.y >= prev.y + prev.h + m.gap_small, where .. ": " .. it.kind .. " overlaps " .. prev.kind)
                end
                if it.kind == "stars" then stars = it end
                if it.kind == "footer" then footer = it end
            end
            ok(plan.h <= h * 0.9, where .. " fits: " .. plan.h)
            -- Each row is at least as tall as its text in KOReader's scaled font.
            local function line(size) return math.ceil(scale(size) * SL.LINE) end
            local F = SL.FONTS
            for _, it in ipairs(plan.items) do
                local need = ({ status = line(F.status), title = line(F.title), author = line(F.author), series = line(F.series),
                    label = line(F.label), hint = line(F.hint), stars = line(F.star), notice = line(F.notice),
                    card = line(F.card_title) + line(F.card_sub) })[it.kind]
                if need then ok(it.h >= need, where .. ": " .. it.kind .. " " .. it.h .. " < " .. need) end
            end
            -- Stars: five equal targets centred as a group; footer: equal halves.
            local cells = SL.centred(stars.w, 5, m.star * 2)
            eq(cells[1].x, stars.w - (cells[5].x + cells[5].w) + ((stars.w - cells[1].w * 5) % 2), where .. " stars centred")
            for _, c in ipairs(cells) do eq(c.w, cells[1].w); ok(c.w >= m.star, "star target") end
            ok(#footer.block.items == 2, "two footer buttons")
            local halves = SL.split(footer.w, 2)
            eq(halves[1].w, halves[2].w, "equal footer buttons")
            -- A widget that came out taller grows its row and pushes the rest down.
            m.measured = { [plan.items[2].block] = plan.items[2].h + 30 }
            local grown = SL.plan(blocks, m)
            eq(grown.items[3].y, plan.items[3].y + 30, where .. " a taller row pushes the next")
            m.measured = nil
        end
    end
end)

---------------------------------------------------------------- recommended settings (addon-mode §5)
local R = M.Recommended
-- A fake KOReader: values by item id, defaults by item id, unavailable ids.
local function world(cur, opts)
    opts = opts or {}
    return function(it)
        if opts.missing and opts.missing[it.id] then return { available = false, reason = "missing" } end
        local defaults = opts.defaults or {}
        local d = defaults[it.id]
        if d == nil and it.kind == "gesture" then d = nil end
        return { available = true, current = cur[it.id], default = d }
    end
end
local BO_DEFAULTS = { ["bo.auto_sync"] = false, ["bo.sync_forward"] = 1, ["bo.home"] = "off" }
local function fresh()
    return { ["bo.auto_sync"] = false, ["bo.sync_forward"] = 1, ["bo.home"] = "off" }
end
local function states(plan)
    local out = {}
    for _, d in ipairs(plan.decisions) do out[d.item.id] = d.state end
    return out
end

test("recommended: an item's state (BookOrbit key, gesture table, KOReader global)", function()
    local bo = R.item("bo.sync_forward")
    eq(R.classify(bo, { current = 2, default = 1 }), "already")
    eq(R.classify(bo, { current = 1, default = 1 }), "at_default")
    eq(R.classify(bo, { current = 3, default = 1 }), "conflict")
    local g = R.item("g.apps")
    eq(R.classify(g, { current = { increase_frontlight = 0 }, default = { increase_frontlight = 0 } }), "at_default", "table equal by value")
    eq(R.classify(g, { current = nil, default = nil }), "at_default", "no light: nothing is the default")
    eq(R.classify(g, { current = { orbit_open_apps = true }, default = nil }), "already")
    eq(R.classify(g, { current = { toc = true }, default = { increase_frontlight = 0 } }), "conflict")
    local ko = R.item("ko.wifi_on")
    eq(R.classify(ko, { current = nil }), "at_default", "unset is the default")
    eq(R.classify(ko, { current = "prompt" }), "at_default", "KOReader's own default value")
    eq(R.classify(ko, { current = "ignore" }), "conflict")
    eq(R.classify(ko, { current = "turn_on" }), "already")
end)

test("recommended: a fresh KOReader gets every available item, and one line saying how many", function()
    local plan = R.plan(R.ITEMS, nil, world(fresh(), { defaults = BO_DEFAULTS }))
    eq(plan.applied, #R.ITEMS, "all applied")
    eq(plan.conflicts, 0)
    local rec, n = R.record(nil, plan, 100)
    eq(n, 8)
    eq(R.lineText(n, plan.conflicts), "Applied 8 recommended settings · Review")
    eq(R.reportState(rec), "applied")
    eq(rec.unseen, 8)
end)

test("recommended: a customised KOReader keeps every changed value; those are listed for review", function()
    local cur = fresh()
    cur["bo.sync_forward"] = 3            -- the user picked Don't sync
    cur["g.sync_all"] = { toc = true }     -- the user's own gesture
    local plan = R.plan(R.ITEMS, nil, world(cur, { defaults = BO_DEFAULTS }))
    local st = states(plan)
    eq(st["bo.sync_forward"], "conflict")
    eq(st["g.sync_all"], "conflict")
    eq(st["bo.auto_sync"], "at_default")
    eq(plan.applied, 6); eq(plan.conflicts, 2)
    eq(R.lineText(plan.applied, plan.conflicts), "Applied 6 · 2 to review")
    local rec = R.record(nil, plan, 1)
    eq(rec.items["bo.sync_forward"], "conflict")
    eq(R.reportState(rec), "partial")
    eq(R.lineText(0, 2), "Review 2 recommended settings")
    eq(R.lineText(0, 0), nil, "silent when nothing changed")
end)

test("recommended: an untouched-only item is at default only when nothing was changed", function()
    local items = { { id = "o.x", kind = "orbit", ours = true, untouched_only = true }, R.item("bo.sync_forward") }
    local w = function(cur) return function(it) return { available = true, current = cur[it.id], default = it.id == "bo.sync_forward" and 1 or nil } end end
    eq(states(R.plan(items, nil, w({ ["bo.sync_forward"] = 1 })))["o.x"], "at_default", "untouched")
    eq(states(R.plan(items, nil, w({ ["bo.sync_forward"] = 3 })))["o.x"], "conflict", "customised")
    eq(states(R.plan(items, { items = { ["bo.sync_forward"] = "kept" } }, w({})))["o.x"], "conflict", "kept earlier counts")
end)

test("recommended: a later release adds an id: only that one is evaluated; kept and applied stay", function()
    local rec = { items = { ["bo.auto_sync"] = "applied", ["bo.sync_forward"] = "kept", ["bo.home"] = "already",
        ["ko.wifi_on"] = "applied", ["g.sync_sleep"] = "applied", ["g.sync_all"] = "conflict", ["g.this_book"] = "applied" } }
    local looked = {}
    local plan = R.plan(R.ITEMS, rec, function(it) looked[it.id] = true; return { available = true, current = nil, default = nil } end)
    eq(#plan.decisions, 1, "one item")
    ok(looked["g.apps"] and not looked["bo.sync_forward"], "only the new id")
    eq(R.candidates(R.ITEMS, rec, nil)[1].id, "g.apps")
end)

test("recommended: a capability appears: only the unblocked items are evaluated", function()
    local plan = R.plan(R.ITEMS, nil, world(fresh(), { defaults = BO_DEFAULTS, missing = { ["ko.wifi_on"] = true, ["g.apps"] = true } }))
    eq(plan.unavailable, 2)
    local rec = R.record(nil, plan, 1)
    eq(rec.items["g.apps"], "unavailable")
    eq(R.reportState(rec), "applied", "unavailable items don't hold the row")
    local plan2 = R.plan(R.ITEMS, rec, world({}, {}))
    eq(#plan2.decisions, 2, "only the two that were unavailable")
    eq(plan2.applied, 2)
    rec = R.record(rec, plan2, 2)
    eq(rec.items["g.apps"], "applied")
    eq(rec.unseen, 8)
end)

test("recommended: a failed apply stays unavailable, and isn't counted", function()
    local plan = R.plan({ R.item("bo.home") }, nil, world(fresh(), { defaults = BO_DEFAULTS }))
    local rec, n = R.record(nil, plan, 1, { ["bo.home"] = false })
    eq(n, 0); eq(rec.items["bo.home"], "unavailable")
end)

test("recommended: backup and undo round trip; undo leaves a value the user changed since", function()
    local it = R.item("g.apps")
    local prior = { increase_frontlight = 0 }
    local b = R.backup({ current = prior }, it, 5)
    ok(b.had and R.equal(b.prior, prior) and b.prior ~= prior, "a copy of the prior value")
    ok(R.undoable(b, { orbit_open_apps = true }), "still ours: undo")
    ok(not R.undoable(b, { toc = true }), "changed since: left as is")
    local b2 = R.backup({ current = nil }, R.item("ko.wifi_on"), 5)
    ok(not b2.had and b2.prior == nil, "unset before")
end)

test("recommended: the same results with mode full, addon and no companion (the mode is not an input)", function()
    local cur = fresh(); cur["bo.home"] = "filemanager"
    local a = states(R.plan(R.ITEMS, nil, world(cur, { defaults = BO_DEFAULTS })))
    for _, mode in ipairs({ "full", "addon", "none" }) do
        local b = states(R.plan(R.ITEMS, nil, world(cur, { defaults = BO_DEFAULTS })))
        for id, s in pairs(a) do eq(b[id], s, mode .. " " .. id) end
    end
end)

test("recommended: lost capabilities undo only BookSync's applied items that need them", function()
    local rec = { items = { ["ko.wifi_on"] = "applied", ["g.apps"] = "already", ["g.sync_all"] = "applied" } }
    local lost = R.lostCaps(rec, function(cap) return cap ~= "wifi" and cap ~= "apps" end)
    eq(#lost, 1); eq(lost[1].id, "ko.wifi_on")
end)

test("recommended: values in plain words", function()
    eq(R.valueLabel(R.item("bo.sync_forward"), 1), "Ask")
    eq(R.valueLabel(R.item("ko.wifi_on"), nil), "Ask")
    eq(R.valueLabel(R.item("g.apps"), nil), "Nothing")
    eq(R.valueLabel(R.item("g.apps"), { orbit_open_apps = true }), "BookSync: other apps")
    eq(R.reportState(nil), "none")
    eq(R.reportState({ items = { a = "kept", b = "applied" } }), "reviewed")
end)

---------------------------------------------------------------- companion caps (addon-mode §6)
local Caps = M.Caps
test("caps: from the file only, the status only, both (the status wins), none", function()
    local file = { mode = "addon", caps = { "install", "setup", "stats", "relaunch" } }
    local status = { mode = "full", caps = { "install", "home", "wifi" } }
    local c, mode, src = Caps.resolve("ok", file, nil, nil)
    ok(c.install and not c.wifi and mode == "addon" and src == "file", "file")
    c, mode, src = Caps.resolve("ok", nil, status, nil)
    ok(c.home and c.wifi and mode == "full" and src == "status", "status")
    c, mode, src = Caps.resolve("ok", file, status, nil)
    ok(c.wifi and src == "status", "/status wins")
    c, mode, src = Caps.resolve("ok", nil, { version = "0.10.0" }, nil)
    ok(next(c) == nil and src == "none", "a status without caps offers nothing")
    c, mode, src = Caps.resolve("missing", file, nil, nil)
    ok(next(c) == nil and src == "none", "a leftover file is ignored")
    c, mode, src = Caps.resolve("frozen", file, status, nil)
    ok(next(c) == nil, "frozen: nothing")
    c, mode, src = Caps.resolve("ok", nil, nil, { mode = "addon", caps = { "install" } })
    ok(c.install and not c.wifi and src == "cache", "the caps seen last time")
    c, mode, src = Caps.resolve("ok", nil, nil, nil)
    ok(next(c) == nil and src == "none", "nothing known yet: nothing offered")
end)

test("caps: diff names what was lost and gained", function()
    local lost, gained = Caps.diff({ wifi = true, home = true, install = true }, { install = true, pin = true })
    eq(table.concat(lost, ","), "home,wifi"); eq(table.concat(gained, ","), "pin")
end)

test("copies: the replacement file, the decision, the sidecar folder, the queue (the lookup is CopiesLogic's)", function()
    local P = M.CopiesPlan
    local c = { { path = "/b/a.epub" }, { path = "/b/b.epub" } }
    local files = { { id = 9, role = "alternate" }, { id = 10, fileHash = "x" }, { id = 11, role = "primary" } }
    eq(P.pick(files, 10).id, 10, "the same library file")
    eq(P.pick(files, 99).id, 11, "else the primary")
    eq(P.decide("x", { fileHash = "x" }), "same")
    eq(P.decide("y", { fileHash = "x" }), "replace")
    eq(P.decide("y", { }), "unknown", "never replaced blind")
    eq(P.hashSidecar("/s/hashdocsettings", "b3fb8f4f"), "/s/hashdocsettings/b3/b3fb8f4f.sdr")
    local q = { { path = "/b/a.epub" } }
    eq(P.enqueue(q, c), 1, "a once")
    eq(#q, 2)
end)

---------------------------------------------------------------- sleep screen pool (lock-screen.md)
local SP = M.SleepPool
local function seq(list) local i = 0 return function(n) i = i % #list + 1; return math.min(n, list[i]) end end

test("sleep screen settings: off by default, bad values fall back, text cut at 60", function()
    local n = SP.normalize({})
    eq(n.sleep_mode, "off"); eq(n.sleep_from, "up_next"); eq(n.sleep_hours, 6); eq(n.sleep_style, "bar")
    eq(n.sleep_text_position, "right"); eq(n.sleep_battery_corner, "bottom_left"); eq(n.sleep_battery, false)
    n = SP.normalize({ sleep_mode = "bogus", sleep_hours = 5, sleep_from = "scope:x", sleep_style = "halo",
        sleep_text_position = "middle", sleep_battery_corner = "centre", sleep_battery = "1" })
    eq(n.sleep_mode, "off"); eq(n.sleep_hours, 6); eq(n.sleep_from, "up_next"); eq(n.sleep_style, "bar")
    eq(n.sleep_text_position, "right"); eq(n.sleep_battery_corner, "bottom_left"); eq(n.sleep_battery, true)
    eq(SP.normalize({ sleep_hours = "12" }).sleep_hours, 12)
    eq(SP.normalize({ sleep_from = "collection:4" }).sleep_from, "collection:4")
    local long = string.rep("é", 70)
    eq(#SP.cleanText(long), 120, "60 two-byte characters")
    eq(SP.cleanText("  Bedtime\n8 pm  "), "Bedtime 8 pm")
end)

test("sleep screen: the SETTINGS extras are strings, rules one per line", function()
    local x = SP.extras({ sleep_mode = "recommended", sleep_leave_out = { "tag:Age:18", "scope:3", "bogus", "scope:3" },
        sleep_battery = true, sleep_hours = 3 })
    eq(x.sleep_mode, "recommended"); eq(x.sleep_hours, "3"); eq(x.sleep_battery, "1")
    eq(x.sleep_leave_out, "tag:age:18\nscope:3")
    local back = SP.decodeRules(x.sleep_leave_out)
    eq(#back, 2); eq(back[1], "tag:age:18"); eq(back[2], "scope:3")
    eq(SP.parseRule("tag:   "), nil); eq(SP.parseRule("scope:0"), nil); eq(SP.parseRule("field:3"), nil)
    eq(SP.parseFrom("discover").type, "random"); eq(SP.parseFrom("up_next").type, "up-next-in-series")
end)

test("sleep screen: Pick from and Leave out as sets, Library (shared/fixtures/sleep/cases.json sources)", function()
    -- @fixture sleep/cases.json#sources
    local src = JSON.fixture(here, "sleep/cases.json").sources
    ok(#src.from >= 5 and #src.leave_out >= 3, "the shared cases")
    for _, c in ipairs(src.from) do eq(SP.normalizeFrom(c.wire), c.expect, c.name) end
    for _, c in ipairs(src.leave_out) do eq(SP.encodeRules(SP.decodeRules(c.wire)), c.expect, c.name) end
    eq(SP.normalize({ sleep_from = "discover\nscope:3" }).sleep_from, "discover\nscope:3")
    eq(SP.extras({ sleep_from = "library\nup_next" }).sleep_from, "library")
end)

test("sleep screen: text and battery never share a corner (L3b2)", function()
    eq(SP.batteryCorner("bottom_left", "bottom"), "top_left")
    eq(SP.batteryCorner("top_right", "top"), "bottom_right")
    eq(SP.batteryCorner("bottom_right", "right"), "bottom_left")
    eq(SP.batteryCorner("top_left", "left"), "top_right")
    eq(SP.batteryCorner("bottom_left", "right"), "bottom_left", "default: apart already")
    eq(SP.batteryCorner("top_left", "bottom"), "top_left")
end)

-- Which books count (R2), Leave out (X1-X7), the shuffle bag (R1b) and Every sleep's batch (R4b):
-- Orbit Companion's (SleepPoolTest.kt).
test("sleep screen: the pickers' section entries", function()
    local e = SP.entries({ items = { { id = "12", title = "Romance", count = 40 }, { id = "x", title = "bad" } } })
    eq(#e, 1); eq(e[1].id, 12); eq(e[1].count, 40)
end)

test("sleep screen: the JSON the companion reads (scopes.json, current.json) is valid", function()
    local doc = { v = 1, at = 1700000000000, items = { { id = 5, title = 'Quote " and \\ slash', file = "covers/5.jpg" } } }
    local back = JSON.decode(SP.json(doc))
    eq(back.v, 1); eq(back.at, 1700000000000)
    eq(back.items[1].id, 5); eq(back.items[1].title, 'Quote " and \\ slash'); eq(back.items[1].file, "covers/5.jpg")
    eq(SP.json({ items = {} }), '{"items":[]}')
end)

-- Nothing interrupts reading (docs/design/reading-gate.md): every place in the plugin that shows
-- something, takes focus or restarts says how the reading gate covers it ("-- gate: <why>" on its
-- line or the line before). A new path without it fails here.
test("reading gate: every show, toast, activity start and restart names its gate", function()
    local dir = here .. "/../orbit.koplugin/ko/"
    local pat = { "UIManager:show%(", "bookorbit_toast\"%)%.show", "bookorbit_toast\"%)%.error", "Toast%.show%(",
        "Toast%.error%(", "Jni%.startActivity{", "restartKOReader%(%)", "UIManager:quit%(%)" }
    local missing = {}
    local p = io.popen('ls "' .. dir .. '"')
    for name in p:lines() do
        if name:match("%.lua$") and name ~= "jni.lua" then
            local prev = ""
            local n = 0
            for line in io.lines(dir .. name) do
                n = n + 1
                local code = line:gsub("%-%-.*$", function(c) return c:find("gate:", 1, true) and c or "" end)
                for _, q in ipairs(pat) do
                    if code:find(q) and not code:match("^%s*%-%-") and not line:find("-- gate:", 1, true)
                        and not prev:find("-- gate:", 1, true) then
                        table.insert(missing, name .. ":" .. n)
                    end
                end
                prev = line
            end
        end
    end
    p:close()
    eq(table.concat(missing, " "), "", "ungated show paths")
end)

-- shared/fixtures/cache/worker.json: the cache's keys, file names, list pages, cover names and
-- entry format, which the companion's cache worker must match byte for byte (CacheWorkerTest
-- reads the same file). Regenerate only when the plugin's rules change, then fix the companion.
test("cache worker fixture: the plugin's keys, hashes, pages, cover names and entry format", function()
    local Cache = M.Cache
    -- @fixture cache/worker.json
    local fx = JSON.fixture(here, "cache/worker.json")
    for _, k in ipairs(fx.keys) do
        local key = Cache.key({ account = k.account, server = k.server, method = "GET", path = k.path })
        eq((key:gsub(".", function(c) return string.format("%02x", c:byte()) end)), k.key_hex, "key of " .. k.path)
        eq(Cache.hash(key), k.hash, "hash of " .. k.path)
    end
    for _, w in ipairs(fx.windows) do
        local got = Cache.listWindow(w.path)
        eq(got and got.identity, w.identity, "identity of " .. w.path)
        if got then
            eq(got.kind, w.kind, "kind"); eq(got.section, w.section, "section")
            eq(CR.mirrorPage(got.identity, 2, nil), w.page2, "page 2"); eq(CR.mirrorPage(got.identity, 1, 50), w.page1_50, "page 1 of 50")
        end
    end
    for _, c in ipairs(fx.covers) do
        eq(CR.coverName({ id = c.id, updatedAt = c.updatedAt, author_photo = c.author_photo or nil }), c.name, "cover of " .. c.id)
    end
    local e = fx.entry
    local body = JSON.decode(e.body_json)
    eq(Cache.encode({ key = e.key, body = body, fetched_at = e.fetched_at, validated_at = e.validated_at, path = e.path }), e.lua, "entry")
end)

test("sleep screen, Every sleep: a setting value", function()
    eq(SP.normalize({ sleep_hours = 0 }).sleep_hours, 0, "Every sleep is a value")
    eq(SP.normalize({ sleep_hours = "0" }).sleep_hours, 0)
    eq(SP.extras({ sleep_hours = 0 }).sleep_hours, "0")
    eq(SP.hoursLabel(0), "Every sleep"); eq(SP.hoursLabel(12), "12 h")
end)


-- Shared settings (docs/design/companion-settings.md §4): one schema, per-key newest-wins merge.
local SettingsSync = M.SettingsSync
local function readFile(path) local f = assert(io.open(path, "rb")); local t = f:read("*a"); f:close(); return t end
local schemaText = readFile(here .. "/../../../shared/settings/schema.json")
local SIDX = SettingsSync.index(SettingsSync.decodeJson(schemaText))

test("settings schema: the plugin's own JSON reader loads it", function()
    ok(#SIDX.settings >= 30, "settings: " .. #SIDX.settings)
    eq(#SIDX.sections, 8, "sections")
    for _, d in ipairs(SIDX.settings) do
        ok(d.label and d.label ~= "", d.key .. " label")
        ok(d.line and d.line ~= "", d.key .. " line")
        local known = false
        for _, s in ipairs(SIDX.sections) do if s.id == d.section then known = true end end
        ok(known, d.key .. " section")
        if d.parent then ok(SIDX.byKey[d.parent.key] ~= nil, d.key .. " parent") end
        ok(SettingsSync.fromWire(d, SettingsSync.toWire(d, nil)) ~= nil, d.key .. " default round-trips")
    end
end)

test("settings schema: storage choices match the plugin, including fractional GB", function()
    local d = SIDX.byKey.storage_limit_mb
    eq(d.default, 250)
    eq(#d.values, #M.Cache.STORAGE_LIMITS_MB)
    local labels = { "100 MB", "250 MB", "500 MB", "1 GB", "2.5 GB", "5 GB", "10 GB", "No limit" }
    for i, v in ipairs(d.values) do
        eq(tonumber(v.id), M.Cache.STORAGE_LIMITS_MB[i])
        eq(v.label, labels[i])
        eq(SettingsSync.fromWire(d, v.id), tonumber(v.id))
    end
end)

test("settings schema: every plugin setting is in it, or listed as state", function()
    local STATE = { last_sleep_sync = 1, shared_settings_at = 1, settings_at = 1, patch_update_checked_at = 1,
        patch_update_status = 1, open_book_at_exit = 1, restart_screen = 1, restart_book = 1, home_book = 1,
        saved_pages_before_update = 1, sleep_current_file = 1, choices_asked_at = 1 }
    local src = readFile(here .. "/../orbit.koplugin/ko/settings.lua")
    local body = src:match("DEFAULTS = (%b{})")
    local missing, shared = {}, {}
    for key in body:gmatch("\n%s+([%a_]+)%s*=") do
        if SIDX.byKey[key] then table.insert(shared, key)
        elseif not STATE[key] then table.insert(missing, key) end
    end
    eq(table.concat(missing, " "), "", "plugin settings missing from shared/settings/schema.json")
    -- A shared setting's default is the schema's (ko/settings.lua fills DEFAULTS from it; test_flows checks the result).
    eq(table.concat(shared, " "), "", "shared settings with a default in ko/settings.lua, not the schema")
end)

-- @fixture wifi/policy.json#connect
test("Wi-Fi network-up decisions shared with X4", function()
    for _, c in ipairs(JSON.fixture(here, "wifi/policy.json").connect) do
        eq(WifiPlan.shouldConnect(c.mode, c.reason, c.saved), c.connect, c.mode .. "/" .. c.reason)
    end
end)

-- @fixture settings/merge.json
local MERGE = JSON.fixture(here, "settings/merge.json")
for _, c in ipairs(MERGE.cases) do
    test("settings merge: " .. c.name, function()
        local vals, at, remote = {}, {}, {}
        for k, e in pairs(c["local"]) do vals[k] = SettingsSync.fromWire(SIDX.byKey[k], e.v); at[k] = e.at end
        for k, e in pairs(c.remote) do remote[k] = { v = e.v, at = e.at } end
        local taken = SettingsSync.merge(SIDX, vals, at, remote, c.now, c.remote_wins_tie)
        local keys = {}
        for _, t in ipairs(taken) do table.insert(keys, t.key); vals[t.key] = t.value; at[t.key] = t.at end
        eq(table.concat(keys, ","), table.concat(c.taken, ","), "taken")
        for k, v in pairs(c.expect) do eq(SettingsSync.toWire(SIDX.byKey[k], vals[k]), v, k) end
    end)
end

test("settings seed: legacy keys keep the old time, the rest get 1 ms", function()
    local at = { key_log = 77 }
    local n = SettingsSync.seed(SIDX, at, SettingsSync.LEGACY, 5000)
    eq(at.wifi_mode, 5000); eq(at.sync_on_sleep, 1); eq(at.key_log, 77)
    eq(n, #SIDX.settings - 1)
    local at2 = {}
    SettingsSync.seed(SIDX, at2, SettingsSync.LEGACY, 0)
    eq(at2.wifi_mode, 1, "never shared before")
end)

test("settings encode: only keys with a time, as wire strings", function()
    local out = SettingsSync.encode(SIDX, { sync_on_sleep = false, sleep_leave_out = { "tag:x", "scope:3" } },
        { sync_on_sleep = 9, sleep_leave_out = 4 })
    eq(out.sync_on_sleep.v, "0"); eq(out.sync_on_sleep.at, 9)
    eq(out.sleep_leave_out.v, "tag:x\nscope:3")
    eq(out.wifi_mode, nil)
end)

test("settings visible: rows show only while their parent has the value", function()
    local v = { sleep_mode = "off", sleep_style = "overlay", sync_on_sleep = true, wifi_mode = "jit", sync_mode = "custom" }
    eq(SettingsSync.visible(SIDX, "sleep_text", v), false)
    eq(SettingsSync.visible(SIDX, "sleep_text_position", v), false, "grandparent off")
    v.sleep_mode = "current"
    eq(SettingsSync.visible(SIDX, "sleep_text_position", v), true)
    eq(SettingsSync.visible(SIDX, "sleep_from", v), false, "Recommended only")
    eq(SettingsSync.visible(SIDX, "sleep_cap", v), true)
    v.sync_on_sleep = false
    eq(SettingsSync.visible(SIDX, "sleep_cap", v), false)
    eq(SettingsSync.visible(SIDX, "wifi_idle_min", v), true)
    -- OrbiSmart sets the sync rows and hides them (docs/design/position-sync.md §6); Custom shows them.
    v.sync_on_sleep = true
    for _, k in ipairs({ "sync_on_sleep", "sleep_cap", "sync_on_wake", "reading_schedule" }) do
        eq(SettingsSync.visible(SIDX, k, v), true, k .. " under Custom")
    end
    v.sync_mode = "orbismart"
    for _, k in ipairs({ "sync_on_sleep", "sleep_cap", "sync_on_wake", "reading_schedule" }) do
        eq(SettingsSync.visible(SIDX, k, v), false, k .. " under OrbiSmart")
    end
    eq(SettingsSync.visible(SIDX, "wake_tailscale", v), true)
    eq(SettingsSync.visible(SIDX, "wifi_mode", v), true, "Wi-Fi mode untouched")
end)

test("settings schema: Sync (OrbiSmart / Custom) is the sync section's first row", function()
    local first
    for _, d in ipairs(SIDX.settings) do if d.section == "sync" then first = d; break end end
    eq(first.key, "sync_mode")
    eq(first.default, "orbismart")
    eq(first.label, "Reading position")
    eq(first.values[1].label, "Furthest page wins")
    eq(first.line, "BookSync keeps the furthest place you've read on any device, and asks before jumping.")
end)

test("settings schema: every key KOReader reads has a row in its menu", function()
    local menu = readFile(here .. "/../orbit.koplugin/logic/settings_ui.lua") .. readFile(here .. "/../orbit.koplugin/ko/menu.lua") .. readFile(here .. "/../orbit.koplugin/ko/sleepscreen.lua")
    local missing = {}
    for _, d in ipairs(SIDX.settings) do
        -- Keys KOReader reads need a row; the companion's own (the clearing flash, its updates) may not.
        local plugin = false
        for _, r in ipairs(d.reader or {}) do if r == "plugin" then plugin = true end end
        if plugin and not d.hidden and not menu:find('"' .. d.key .. '"', 1, true) then table.insert(missing, d.key) end
    end
    eq(table.concat(missing, " "), "", "keys with no menu row")
end)


test("sleep screen: Every sleep (sleep_hours 0) is a valid choice, listed first", function()
    local SP = M.SleepPool
    eq(SP.HOURS[1], 0)
    eq(SP.normalize({ sleep_hours = 0 }).sleep_hours, 0, "kept, not the default")
    eq(SIDX.byKey.sleep_hours.values[1].label, "Every sleep")
    eq(SettingsSync.fromWire(SIDX.byKey.sleep_hours, "0"), 0)
end)

test("recommended choices from the companion", function()
    local c = SettingsSync.choices("bo.auto_sync=ours; g.apps=mine;x=bogus;all=undo")
    eq(#c, 3); eq(c[1].id, "bo.auto_sync"); eq(c[2].what, "mine"); eq(c[3].id, "all")
end)

-- OrbiSmart sync (docs/design/position-sync.md §3): every case of the shared table, which the Xteink's
-- xteink/test/orbismart_test.cpp reads too.
local OrbiSmart = M.OrbiSmart
local OSM = JSON.fixture(here, "orbismart/cases.json")
test("orbismart: every decide case", function()
    local n = 0
    for _, c in ipairs(OSM.decide) do
        local out = OrbiSmart.decide(c["in"])
        eq(out.decision, c.want.decision, c.name .. " decision")
        eq(out.rule, c.want.rule, c.name .. " rule")
        eq(out.dropped, c.want.dropped == true, c.name .. " dropped")
        ok(OrbiSmart.DECISIONS[out.decision], c.name .. ": known decision")
        if c.line then eq(OrbiSmart.line(c["in"], out, c.moment), c.line, c.name .. " line") end
        n = n + 1
    end
    ok(n >= 30, "cases: " .. n)
end)
test("orbismart: every apply case", function()
    for _, c in ipairs(OSM.apply) do
        eq(OrbiSmart.apply(c.decision, c.moment), c.applied, c.decision .. " at " .. c.moment)
    end
end)
test("orbismart: every behind-hold case", function()
    for _, c in ipairs(OSM.push) do
        eq(OrbiSmart.mayPush(c.place, c.server, c.tolerance, c.exempt), c.allowed, c.name)
    end
end)
test("orbismart: the table covers every decision and rule", function()
    local seen = {}
    for _, c in ipairs(OSM.decide) do seen[c.want.decision] = true; seen[c.want.rule] = true end
    for _, k in ipairs({ "same", "take", "follow", "push", "hold", "stay", "override", "rule1", "rule2", "rule3",
        "rule4", "rule5", "rule6", "rule7", "declined", "override", "percent", "no-server" }) do
        ok(seen[k], "no case for " .. k)
    end
    eq(OrbiSmart.SKEW_S, OSM.skew_s, "skew margin")
end)
test("orbismart: the popup's question", function()
    eq(OrbiSmart.question("Boox", 214, "take"), "Continue from Boox, p. 214?")
    eq(OrbiSmart.question("X4 Pro", 12, "follow"), "Continue from X4 Pro, p. 12 (moved back there)?")
end)

test("main loop: directory iterators are confined to the guarded thumbnail child", function()
    local main = readFile(here .. "/../orbit.koplugin/main.lua")
    for module in main:gmatch('"(ko/[^"%s]+%.lua)"') do
        local source = readFile(here .. "/../orbit.koplugin/" .. module)
        if module == "ko/cover_child.lua" then
            ok(source:find("Db.pid() ~= Store.ui_pid",1,true), "child PID guard")
            ok(source:find("if not lfs_ok or not (OC.child",1,true), "guard precedes iterator")
        else
            ok(not source:find("lfs.dir",1,true), module .. " must not enumerate a directory")
            ok(not source:find("lfs%.attributes[^\n]*for "), module .. " file scans belong to companion")
        end
    end
end)

test("status layout: default off, sizes, compact strips and proportional battery", function()
    local schema = M.SettingsSync.decodeJson(readFile(here .. "/../../../shared/settings/schema.json"))
    local indexed = M.SettingsSync.index(schema)
    eq(indexed.byKey.status_orbit_layout.default, false)
    eq(indexed.byKey.status_orbit_size.default, "small")
    local L = M.StatusLayout
    eq(L.fontSize("small"), 14); eq(L.fontSize("medium"), 18); eq(L.fontSize("large"), 22)
    eq(L.fontSize("unknown"), 14)
    for _, h in ipairs({12, 16, 24, 40}) do eq(L.stripHeight(h, 1), h+2) end
    eq(indexed.byKey.status_orbit_add_space, nil)
    local program=M.SettingsSync.decodeJson(readFile(here.."/../../../shared/ui/battery.json"))
    for _, charge in ipairs({0, 1, 25, 50, 98, 100}) do
        local rectangles={}
        M.BatteryGlyph.draw(program,20,charge,function(x,y,w,h,color) rectangles[#rectangles+1]={x,y,w,h,color} end)
        eq(#rectangles,4); ok(math.abs(rectangles[4][3]-21.6*charge/100)<0.00001)
    end
    local measure=function(size) return size-2 end
    for margin=0,30 do
        local fit=L.fit(margin,22,1,measure,false)
        eq(fit.extra,0); ok(fit.height<=margin)
        local added=L.fit(margin,22,1,measure,true)
        eq(added.extra,0); eq(added.height,fit.height)
    end
end)

-- @fixture status/format.json
test("status layout: shared progress and clock formats", function()
    local f = M.SettingsSync.decodeJson(readFile(here .. "/../../../shared/fixtures/status/format.json"))
    for _, v in ipairs(f.progress) do eq(M.StatusLayout.progress(v.page,v.total,v.fraction), v.text) end
    for _, v in ipairs(f.clock) do eq(M.StatusLayout.clock(v.hour,v.minute,v.twelve), v.text) end
    eq(M.StatusLayout.progress(1,nil,0), "")
    eq(M.StatusLayout.progress(1,0,0), "")
    eq(M.StatusLayout.progress(1,10,-0.2), "1 / 10 · 0%")
    eq(M.StatusLayout.progress(10,10,1.2), "10 / 10 · 100%")
    eq(M.StatusLayout.progress(1,200), "1 / 200 · 1%")
end)
test("status layout: unequal sides retain physical centre, Unicode ellipsis and narrow fallback", function()
    local L = M.StatusLayout
    local function measure(s) local n=0; for _ in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do n=n+1 end; return n end
    eq(L.truncate("日本語の章",4,measure), "日本語…")
    eq(L.truncate("章",0,measure), "")
    eq(L.truncate("",100,measure), "")
    local a=L.layout(60,2,2,"battery","b","A very long chapter title", "12 / 340 · 4%",measure)
    eq(a.cx+measure(a.chapter)/2,30)
    ok(a.cx >= a.lx+measure(a.left)+2)
    ok(a.cx+measure(a.chapter)+2 <= a.rx)
    local b=L.layout(25,2,2,"battery percentage","b","chapter", "12 / 340 · 4%",measure)
    eq(b.chapter, ""); eq(b.left,"b")
    local c=L.layout(15,2,2,"battery percentage","b","chapter", "12 / 340 · 4%",measure)
    eq(c.chapter, ""); eq(c.left, "")
end)

test("status layout: inset full battery group has priority over page text", function()
    local L=M.StatusLayout
    local measure=function(t) return #t end
    local layout=L.layout(35,4,4,"100% + charge","icon","Chapter", "123 / 1234 · 100%",measure,true)
    eq(layout.left,"100% + charge"); eq(layout.lx,4)
    ok(layout.lx+measure(layout.left)+4<=layout.rx)
    ok(layout.rx+measure(layout.right)<=31)
    local hidden=L.layout(12,4,4,"100% + charge","icon","Chapter","1 / 2",measure,true)
    eq(hidden.left,"")
    local rectangles={}
    eq(L.chargingMark(18,function(x,y,w,h,color)
        eq(color,1); ok(x>=0 and x+w<=14 and y>=0 and y+h<=18)
        rectangles[#rectangles+1]={x,y,w,h}
    end),14)
    eq(#rectangles,9)
end)

-- shared/fixtures/REGISTRY.json: every rule table has a row, and this suite reads what it names (test_registry.lua).
test("fixture registry: the plugin reads every table it is named for, and every table has a row", function()
    local problems = dofile(here .. "/test_registry.lua")(here)
    eq(table.concat(problems, "\n"), "", "REGISTRY.json")
end)

dofile(here .. "/layout_tests.lua")(M, test, ok, eq, JSON)

test("settings modes: approved presets use shared wire values and Balanced matches defaults", function()
    local e = setmetatable({}, {__index=_G}); setfenv(assert(loadfile(here .. "/../orbit.koplugin/logic/settings_ui.lua")), e)()
    local UI = e.SettingsUI
    local balanced = UI.modes[2].values
    for _, key in ipairs(UI.modeKeys) do
        eq(balanced[key], SIDX.byKey[key].default, key)
    end
    for _, mode in ipairs(UI.modes) do
        for _, key in ipairs(UI.modeKeys) do
            local d = SIDX.byKey[key]
            eq(SettingsSync.fromWire(d, SettingsSync.toWire(d, mode.values[key])), mode.values[key])
        end
        eq(UI.mode(mode.values), mode.id)
    end
    local unset = {}
    for _, key in ipairs(UI.modeKeys) do if key ~= "wifi_mode" then unset[key] = balanced[key] end end
    eq(UI.mode(unset, "jit"), "balanced", "effective device Wi-Fi default")
    eq(UI.mode(balanced, "always_on"), "custom", "effective capability policy beats stored Wi-Fi preference")
    eq(UI.words("BookOrbit home"), "Server plugin's Home")
    eq(UI.words("Wake Tailscale for syncs"), "Wake VPN for syncs")
end)

dofile(here .. "/test_library.lua")(test, eq, ok, here, M.Cache)

dofile(here .. "/test_reading_stats.lua")(test, eq, ok, here, M.Cache)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
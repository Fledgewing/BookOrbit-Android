-- Loads the whole patch against small stand-ins for KOReader, the JNI bridge and the
-- BookOrbit plugin, then drives the flows on a fake clock. It catches wiring mistakes
-- (typos, nil calls, wrong order) that the pure tests can't; it proves nothing about
-- the device. Needs LuaJIT (the patch uses ffi): luajit android/koreader/test/test_flows.lua
local here = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."

---------------------------------------------------------------- fake world
local W = {
    clock = 1000, queue = {}, seq = 0, shown = {}, logs = {},
    wifi = true, vpn = true, screen_on = false, companion = true, server_code = 200,
    broadcasts = {}, activities = {}, intent_extras = {},
    fetched = {}, web = {}, json = {}, files = {}, children = {},
}
function W.fake_sha(s) return string.format("%064x", #s) end
local SELF = os.tmpname()
-- The plugin folder the self-update replaces (the code itself loads from orbit.koplugin/).
ORBIT_ANDROID_PLUGIN_DIR = SELF .. ".koplugin"
local SELF_PATH = ORBIT_ANDROID_PLUGIN_DIR .. "/main.lua"
local function sh(cmd, path) os.execute(cmd .. " '" .. path:gsub("'", "") .. "'") end

local function schedule(delay, fn, ...)
    W.seq = W.seq + 1
    local args = { ... }
    table.insert(W.queue, { at = W.clock + delay, seq = W.seq, fn = fn, args = args })
end

local UIManager = {
    scheduleIn = function(_, d, fn, ...) schedule(d, fn, ...) end,
    nextTick = function(_, fn, ...) schedule(0, fn, ...) end,
    unschedule = function(_, fn)
        for i = #W.queue, 1, -1 do if W.queue[i].fn == fn then table.remove(W.queue, i) end end
    end,
    show = function(_, w) table.insert(W.shown, w) end,
    getElapsedTimeSinceBoot = function() return W.clock * 1e6 end,
    getTopmostVisibleWidget = function() return W.shown[#W.shown] end,
    close = function(_, w)
        for i = #W.shown, 1, -1 do if W.shown[i] == w then table.remove(W.shown, i) end end
        if w and w.dismiss_callback then w.dismiss_callback() end
    end,
    forceRePaint = function() end,
    setDirty = function() end,
    -- Android: Device:canRestart is no, so a restart is quit + the companion's RELAUNCH.
    quit = function() W.quits = (W.quits or 0) + 1 end,
    _refresh_stack = {},
    -- Like uimanager.lua _repaint: drain the queue, then replace it.
    _repaint = function(self) self._refresh_stack = {} end,
}
-- UIManager._window_stack (uimanager.lua): W.shown, bottom to top.
setmetatable(UIManager, { __index = function(_, k)
    if k == "_window_stack" then
        local t = {}
        for i, w in ipairs(W.shown) do t[i] = { widget = w } end
        return t
    end
end })

-- At most this many scheduled steps per run(): a task that keeps rescheduling itself with no
-- delay never moves the fake clock past the limit, so it would spin forever.
local RUN_MAX_STEPS = 20000
local function run(limit)
    limit = limit or 120
    local stop = W.clock + limit
    local steps = 0
    while #W.queue > 0 do
        steps = steps + 1
        if steps > RUN_MAX_STEPS then
            error("run(): " .. RUN_MAX_STEPS .. " steps without the fake clock passing +" .. limit .. " s (a task rescheduling itself with no delay?)", 2)
        end
        table.sort(W.queue, function(a, b) if a.at == b.at then return a.seq < b.seq end return a.at < b.at end)
        local t = table.remove(W.queue, 1)
        if t.at > stop then table.insert(W.queue, t) break end
        W.clock = math.max(W.clock, t.at)
        t.fn(unpack(t.args))
    end
end

local function class(base)
    local c = base or {}
    c.__index = c
    c.extend = function(self, o) o = o or {}; o.__index = o; return setmetatable(o, self) end
    c.new = function(self, o) o = setmetatable(o or {}, self); if o.init then o:init() end; return o end
    return c
end
local Widget = class()
Widget.__index = Widget

-- A tiny JNI: objects are Lua tables, method ids are names.
local env_fns = {
    ExceptionCheck = function() return W.exception and 1 or 0 end,
    ExceptionClear = function() W.exception = false end,
    DeleteLocalRef = function() end,
    GetObjectClass = function(_, obj) return { cls = obj } end,
    GetStaticMethodID = function(_, _, name) return name end,
    -- Settings.Global.getInt(cr, "wifi_on", -1): the radio (W.radio, else W.wifi).
    CallStaticIntMethod = function(_, cls, m, cr, key, def)
        if m == "getInt" and key.str == "wifi_on" then
            if W.wifi_on_unreadable then return tonumber(def) end
            local on = W.radio
            if on == nil then on = W.wifi end
            return on and 1 or 0
        end
        return tonumber(def)
    end,
    GetMethodID = function(_, _, name) return name end,
    FindClass = function(_, name) return { name = name } end,
    NewStringUTF = function(_, s) return { str = s } end,
    NewObject = function(_, _, _, action) return { kind = "intent", action = action.str, extras = {} } end,
    GetArrayLength = function(_, arr) return #arr end,
    GetObjectArrayElement = function(_, arr, i) return arr[i + 1] end,
    CallObjectMethod = function(_, obj, m, a, b)
        if m == "setPackage" then obj.package = a.str
        elseif m == "setClassName" then obj.package, obj.class = a.str, b.str
        elseif m == "putExtra" then obj.extras[a.str] = b.str
        elseif m == "addFlags" then obj.flags = a
        elseif m == "getSystemService" then return { service = a.str }
        elseif m == "getAllNetworks" then return { { net = 1 } }
        elseif m == "getNetworkCapabilities" then return { caps = true }
        elseif m == "getIntent" then return { kind = "launch" }
        elseif m == "getStringExtra" then
            local v = W.intent_extras[a.str]
            return v and { str = v } or nil
        end
        return obj
    end,
    CallVoidMethod = function(_, obj, m, a)
        if m == "sendBroadcast" then
            a.at = W.clock; table.insert(W.broadcasts, a)
            -- Optionally play the companion: switch the fake radio.
            if W.simulate_companion and a.action:match("%.WIFI_OFF$") then
                if a.extras.auto ~= "1" or W.owner ~= "manual" then W.radio, W.wifi = false, false end
            elseif W.simulate_companion and a.action:match("%.NET_UP$") then
                if not W.radio then W.owner = a.extras.owner end
                W.radio, W.wifi = true, true
            end
        elseif m == "startActivity" then table.insert(W.activities, a)
        elseif m == "removeExtra" then W.intent_extras[a.str] = nil end
    end,
    -- getApplicationEnabledSetting: 2 (disabled) when frozen, else a missing package throws.
    CallIntMethod = function(_, obj, m)
        if m == "getApplicationEnabledSetting" then
            if W.companion_frozen then return 2 end
            W.exception = true
        end
        return 0
    end,
    CallBooleanMethod = function(_, obj, m)
        if m == "isInteractive" then return W.screen_on and 1 or 0 end
        if m == "hasTransport" then return W.vpn and 1 or 0 end
        -- KOReader has no ACCESS_WIFI_STATE: WifiManager.isWifiEnabled throws SecurityException.
        if m == "isWifiEnabled" then W.exception = true; W.wifi_manager_called = true; return 0 end
        return 0
    end,
}
local env = { [0] = env_fns }
local jni = { env = env, to_string = function(_, j) return j.str end,
    context = function(self, _, fn) return fn(self) end }

local NetworkMgr = { isConnected = function() return W.wifi end }
function NetworkMgr:turnOnWifi(cb) W.settings_opened = true; if cb then cb() end end
function NetworkMgr:turnOffWifi(cb) W.settings_opened = true; if cb then cb() end end
-- Stock beforeWifiAction turn_on path: a centred "Connecting to Wi-Fi…" message (manager.lua:539).
function NetworkMgr:turnOnWifiAndWaitForConnection(cb)
    if self:isConnected() then if cb then cb() end return end
    table.insert(W.shown, { text = "Connecting to Wi-Fi…" })
    self:requestToTurnOnWifi(function() self:scheduleConnectivityCheck(cb) end)
end
function NetworkMgr:requestToTurnOnWifi(cb) return self:turnOnWifi(cb) end
function NetworkMgr:beforeWifiAction(cb) return self:turnOnWifiAndWaitForConnection(cb) end -- turn_on
function NetworkMgr:scheduleConnectivityCheck(cb, widget)
    W.connectivity_widget = widget
    local function poll(i)
        if W.wifi then if cb then cb() end return end
        if i < 180 then UIManager:scheduleIn(0.25, function() poll(i + 1) end) end
    end
    UIManager:scheduleIn(0.25, function() poll(1) end)
end
function NetworkMgr:unscheduleConnectivityCheck() end

local store = {}
G_reader_settings = {
    readSetting = function(_, k) return store[k] end,
    saveSetting = function(_, k, v) store[k] = v end,
    flush = function() end,
}

local PluginLoader = {}
function PluginLoader:loadPlugins() return { { name = "bookorbit" } }, {} end
function PluginLoader:genPluginManagerSubItem() return self:loadPlugins() end
function PluginLoader:getPluginInstance() return nil end

local ReaderUI, FileManager = {}, {}
function ReaderUI:showReader(file) W.opened = file end
local actions = {}

local preload = {
    device = { isAndroid = function() return true end },
    -- KOReader's Input: the stock key handler counts what reaches KOReader itself.
    ["device/input"] = { handleKeyBoardEv = function(_, ev) W.stock_keys = (W.stock_keys or 0) + 1 return "key" .. ev.code end },
    logger = { info = function(...) table.insert(W.logs, table.concat({ ... }, " ")) end },
    ffi = require("ffi"),
    ["ui/widget/confirmbox"] = class({}),
    dispatcher = { registerAction = function(_, name, v) actions[name] = v end },
    ["ui/widget/infomessage"] = Widget:extend{},
    ["ui/network/manager"] = NetworkMgr,
    pluginloader = PluginLoader,
    ["ui/widget/textviewer"] = Widget:extend{},
    ["ui/uimanager"] = UIManager,
    ["ui/widget/container/widgetcontainer"] = Widget,
    ["ui/time"] = { now = function() return W.clock * 1e6 end, to_s = function(t) return t / 1e6 end,
        s = function(n) return n * 1e6 end },
    ["ui/event"] = { new = function(_, name, ...) return { name = name, args = { ... } } end },
    gettext = function(s) return s end,
    -- looper/lib: the /clicks channel adds its socket to KOReader's ALooper.
    android = { app = { activity = { vm = {}, clazz = { activity = true } }, looper = {} }, jni = jni,
        lib = { ALooper_addFd = function(_, fd, ident) W.looper_fd = { fd = fd, ident = ident } return 1 end,
            ALooper_removeFd = function(_, fd) W.looper_removed = fd return 1 end },
        isPackageEnabled = function() return W.companion end },
    ["apps/reader/readerui"] = ReaderUI,
    ["apps/filemanager/filemanager"] = FileManager,
    ["socket.http"] = { request = function(t)
        if t.method == "HEAD" then
            W.probed = t.url
            if W.server_code then return 1, W.server_code end
            return nil, "timeout"
        end
        -- GET: the self-update (W.web: url -> body) or the companion status.
        table.insert(W.fetched, t.url)
        W.last_url = t.url
        local body = W.web[t.url] or W.web[(t.url:gsub("%?.*$", ""))]
        if body == nil then
            if t.url:find("127.0.0.1", 1, true) and W.server_code then return 1, W.server_code, {} end
            return 1, 404, {}
        end
        if t.sink then t.sink(body) end
        return 1, 200, {}
    end },
    socket = { skip = function(n, ...) return select(n + 1, ...) end,
        sleep = function(sec) W.slept = W.slept or {}; table.insert(W.slept, sec) end },
    socketutil = { set_timeout = function() end, reset_timeout = function() end },
    ltn12 = { sink = { null = function() end, table = function(t) return function(chunk) if chunk then table.insert(t, chunk) end return 1 end end } },
    -- koreader-base ffi/util subprocesses: the "child" runs as its own scheduled step (or by
    -- hand with W.hold_child), so the UI-thread path can be checked for blocking calls.
    ["ffi/util"] = {
        runInSubProcess = function(fn)
            local child = { done = false }
            child.run = function() fn(#W.children, child); child.done = true end
            table.insert(W.children, child)
            if not W.hold_child then schedule(0.1, child.run) end
            return #W.children, child
        end,
        writeToFD = function(child, data) child.out = data return true end,
        isSubProcessDone = function(pid) return W.children[pid].done end,
        readAllFromFD = function(child) return child.out or "" end,
        terminateSubProcess = function(pid) W.children[pid].killed = true; W.children[pid].done = true end,
        purgeDir = function(dir) sh("rm -rf", dir) end,
    },
    -- koreader-base ffi/archiver Reader over a fake zip: W.zips[<file content>] = { [path] = data }.
    ["ffi/archiver"] = { Reader = { new = function()
        local r = {}
        function r:open(path)
            local f = io.open(path, "rb"); if not f then return false end
            self.files = W.zips[f:read("*a")]; f:close()
            return self.files ~= nil
        end
        function r:iterate()
            local list = {}
            for k in pairs(self.files) do table.insert(list, k) end
            table.sort(list)
            local i = 0
            return function() i = i + 1; if list[i] then return { path = list[i], mode = "file" } end end
        end
        function r:extractToMemory(path) return self.files[path] end
        function r:close() end
        return r
    end } },
    -- KOReader's Android input module: waitForEvent returns what the test queues (default: EINTR).
    ["ffi/input_android"] = { waitForEvent = function() return false, 4 end },
    ["libs/libkoreader-lfs"] = { attributes = function(f, k) return W.files[f] and "file" or nil end,
        mkdir = function(dir) sh("mkdir -p", dir) return true end },
    json = { decode = function(s) if W.json[s] then return W.json[s] end return { version = "1" } end },
    -- Stand-in hash: "sha:<length>" padded, enough to check the wiring (the real one is ffi/sha2).
    ["ffi/sha2"] = { sha256 = function(s) return W.fake_sha(s) end },
}
for k, v in pairs(preload) do package.preload[k] = function() return v end end

-- KOReader's settings files (luasettings.lua), kept in W.lua_files by path.
W.lua_files = {}
package.preload["luasettings"] = function()
    local LS = {}
    LS.__index = LS
    function LS:open(path)
        W.lua_files[path] = W.lua_files[path] or {}
        return setmetatable({ path = path }, LS)
    end
    function LS:readSetting(k) return W.lua_files[self.path][k] end
    function LS:saveSetting(k, v) W.lua_files[self.path][k] = v end
    function LS:flush() end
    return LS
end
-- KOReader's ReaderStatus (readerstatus.lua:38, :212), cut to what end of book hooks.
W.ReaderStatus = {}
W.ReaderStatus.__index = W.ReaderStatus
function W.ReaderStatus:onEndOfBook() W.stock_end = (W.stock_end or 0) + 1 end
function W.ReaderStatus:markBook(mark_read)
    local summary = self.ui.doc_settings:readSetting("summary")
    summary.status = (not mark_read and summary.status == "complete") and "reading" or "complete"
end
function W.ReaderStatus:onShowBookStatus() W.book_status = true end
package.preload["apps/reader/modules/readerstatus"] = function() return W.ReaderStatus end
package.preload["datastorage"] = function() return { getSettingsDir = function() return "/settings" end } end
-- The rest of KOReader's widgets and ui helpers the sheets build with: stand-ins that keep their
-- arguments (no layout, no drawing).
local function plain(_, o) return o or {} end
preload.device.screen = { getWidth = function() return 600 end, getHeight = function() return 800 end }
package.preload["ui/geometry"] = function() return { new = plain } end
package.preload["ui/gesturerange"] = function() return { new = plain } end
package.preload["ui/font"] = function() return { getFace = function() return {} end } end
package.preload["ui/size"] = function() return { padding = { large = 10 }, radius = { button = 0 }, line = { thick = 3 } } end
package.preload["ffi/blitbuffer"] = function() return { COLOR_BLACK = 0, COLOR_WHITE = 1 } end
table.insert(package.loaders, 2, function(name)
    if type(name) == "string" and name:match("^ui/widget/") and not package.preload[name] then
        return function() return Widget:extend{} end
    end
end)

-- The BookOrbit plugin, reduced to the calls the patch makes.
local function newPlugin()
    local p = {
        settings = { server_url = "https://books.example.test", sync_forward = 1, sync_backward = 3, auto_sync = true },
        calls = {}, pending = 0, pull_timestamp = 0, push_timestamp = 0,
        page_update_counter = 0,
    }
    local function rec(name) table.insert(p.calls, name) end
    function p:isLoggedIn() return true end
    function p:requestLifecycleOutboxDrain(src) rec("drain:" .. src); UIManager:scheduleIn(1, function() p.pending = 0 end) end
    function p:getLifecycleOutbox() return { diagnostics = function() return { count = p.pending, blocked = 0 } end } end
    function p:getSyncCoordinator() return { isBusy = function() return false end, queuedCount = function() return 0 end } end
    function p:requestProgressPull(_, _, src) rec("pull:" .. src .. ":" .. p.pull_timestamp) end
    function p:requestProgressPush(_, _, src) rec("push:" .. src) end
    function p:_onSuspend() rec("onSuspend"); p.pending = 1; p:requestLifecycleOutboxDrain("suspend") end
    function p:getDocumentDigest() return "d1" end
    function p:fetchRemoteProgress(d, cb) rec("fetch"); p.last_remote_progress = p.remote; UIManager:nextTick(function() cb(true) end) end
    function p:getLastPercent() return 0.5 end
    function p:getLastProgress() return "x" end
    function p:isSamePlace(b, pct) return b.percentage == pct end
    function p:remoteProgressIsNewer(b, pct) return b.percentage > pct end
    function p:schedulePeriodicPush() rec("plugin_page_push") end
    -- Like the plugin: a catalog widget shown on top (main.lua:1206-1230), on its dashboard.
    function p:onBookOrbitOpenDashboard()
        rec("dashboard")
        if p.catalog_browser then
            -- Like the plugin (main.lua:1381-1385): already open and on top -> its menu sheet.
            if UIManager:getTopmostVisibleWidget() == p.catalog_browser then
                rec("menu_sheet")
                UIManager:show({ name = "bookorbit_menu_sheet" })
            end
            return true
        end
        local cb = { dashboardMode = function() return true end }
        cb.close_callback = function() UIManager:close(cb); p.catalog_browser = nil end
        p.catalog_browser = cb
        UIManager:show(cb)
        return true
    end
    function p:onBookOrbitSyncBook(o) rec("syncbook"); o.on_done(nil) end
    function p:startSweep(o) rec("sweep"); o.on_done(nil) end
    function p:errorLabel(e) return tostring(e) end
    function p:onBookOrbitToggleAutoSync(v) rec("toggle:" .. tostring(v)) end
    return p
end

local function has(list, item)
    for _, v in ipairs(list) do if v == item then return true end end
    return false
end
local function count(list, pred)
    local n = 0
    for _, v in ipairs(list) do if pred(v) then n = n + 1 end end
    return n
end
local function lastBroadcast(suffix)
    for i = #W.broadcasts, 1, -1 do
        local b = W.broadcasts[i]
        if b.action:sub(-#suffix) == suffix then return b end
    end
end

-- Wall-clock seconds (gettimeofday): os.clock counts only this process's CPU, and a test stuck
-- in a subprocess or a blocked call uses none.
do
    local ffi = require("ffi")
    pcall(ffi.cdef, "typedef struct { long tv_sec; int tv_usec; } orbit_timeval; int gettimeofday(orbit_timeval *tv, void *tz);")
    local tv = ffi.new("orbit_timeval")
    function W.wall() ffi.C.gettimeofday(tv, nil); return tonumber(tv.tv_sec) + tonumber(tv.tv_usec) / 1e6 end
end
local passed, failed = 0, 0
-- Each test gets TEST_LIMIT_S seconds (CPU or wall clock); past that it fails with a traceback
-- instead of hanging the suite. The hook runs every 10000 VM instructions; LuaJIT skips hooks in
-- compiled traces, so the JIT is off here (the suite is small; it runs in about a second).
local TEST_LIMIT_S = tonumber(os.getenv("ORBIT_TEST_LIMIT_S") or "") or 10
if jit then jit.off() end
local function withLimit(name, fn, limit)
    local TEST_LIMIT_S = limit or TEST_LIMIT_S
    local cpu0, wall0 = os.clock(), W.wall()
    debug.sethook(function()
        if os.clock() - cpu0 > TEST_LIMIT_S or W.wall() - wall0 > TEST_LIMIT_S then
            debug.sethook()
            error(debug.traceback("test timed out after " .. TEST_LIMIT_S .. " s: " .. name, 2), 0)
        end
    end, "", 10000)
    local ok, err = pcall(fn)
    debug.sethook()
    return ok, err
end
local function test(name, fn)
    local t0 = W.wall()
    local ok, err = withLimit(name, fn)
    if os.getenv("ORBIT_TEST_TIMES") then print(string.format("%6.2f  %s", W.wall() - t0, name)) end
    if ok then passed = passed + 1 else
        failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err))
        if os.getenv("ORBIT_TEST_LOGS") then
            for i = math.max(1, #W.logs - 25), #W.logs do print("   | " .. W.logs[i]) end
        end
    end
end
local function ok(v, what) if not v then error(what or "expected true", 2) end end

-- The guards themselves: a hang fails its test fast, by name, with a traceback.
test("harness: a test that never returns fails after its time limit", function()
    local done, err = withLimit("spin", function() local n = 0 while true do n = n + 1 end end, 0.3)
    ok(not done and tostring(err):find("timed out after 0.3 s: spin", 1, true), tostring(err))
    ok(tostring(err):find("stack traceback", 1, true), "with a traceback")
end)
test("harness: run() stops a task that reschedules itself with no delay", function()
    local function again() UIManager:nextTick(again) end
    again()
    local done, err = pcall(run, 5)
    W.queue = {}
    ok(not done and tostring(err):find("steps without the fake clock passing", 1, true), tostring(err))
end)

---------------------------------------------------------------- load
-- The previous KOReader process was killed with this book open (Smart Home cold start).
store.orbit_android = store.orbit_android or {}
store.orbit_android.open_book_at_exit = "/books/killed.epub"
local PLUGIN_MAIN = here .. "/../orbit.koplugin/main.lua"
local Orbit = dofile(PLUGIN_MAIN)

local function newUI(in_book)
    local menu = { registered = {} }
    function menu:registerToMainMenu(w) table.insert(self.registered, w) end
    local ui = { menu = menu, bookorbit = newPlugin(), document = in_book and { file = "/b.epub" } or nil,
        toc = { isChapterStart = function(_, pg) return pg % 10 == 1 end,
                getPreviousChapter = function(_, pg) return pg - ((pg - 1) % 10) end },
        gestures = { data = {}, onFlushSettings = function(g) g.flushed = true end } }
    function ui:onHome() W.home_called = true; ReaderUI.instance = nil end
    function ui:handleEvent(ev)
        local h = self.bookorbit and self.bookorbit["on" .. ev.name]
        if h then return h(self.bookorbit, table.unpack and table.unpack(ev.args) or unpack(ev.args)) end
    end
    if in_book then ReaderUI.instance = ui; FileManager.instance = nil
    else FileManager.instance = ui; ReaderUI.instance = nil end
    local m = Orbit:new{ ui = ui }
    return ui, m
end

test("plugin: main.lua returns the module; it leaves KOReader's plugin list alone", function()
    ok(Orbit.name == "orbit", "name")
    ok(type(Orbit.init) == "function" and type(Orbit.onSuspend) == "function", "module")
    ok(#PluginLoader:genPluginManagerSubItem() == 1, "plugin manager list untouched")
end)

test("plugin: stays off while the old patch is loaded (nothing hooked twice)", function()
    local stock = PluginLoader.loadPlugins
    -- What the patch leaves behind: PluginLoader.loadPlugins defined in koreader/patches/.
    PluginLoader.loadPlugins = load("return function(self, ...) return stock(self, ...) end",
        "@/sdcard/koreader/patches/2-orbit-android.lua")()
    local wifi = NetworkMgr.turnOnWifi
    local again = dofile(PLUGIN_MAIN)
    PluginLoader.loadPlugins = stock
    ok(type(again) == "table" and again.disabled == true, "disabled")
    ok(NetworkMgr.turnOnWifi == wifi, "no second hook")
end)

test("dispatcher actions are registered", function()
    newUI(false)
    for _, a in ipairs({ "orbit_sync_and_sleep", "orbit_go_home", "orbit_open_companion", "orbit_open_apps" }) do
        ok(actions[a], a)
    end
end)

test("start: network up, then drain and pull with the debounce cleared", function()
    W.broadcasts = {}
    local ui = newUI(true)
    run(30)
    local p = ui.bookorbit
    ok(lastBroadcast(".NET_UP"), "NET_UP sent")
    ok(lastBroadcast(".NET_UP").extras.reason == "start", "reason start")
    ok(has(p.calls, "drain:orbit_start"), "drain")
    ok(has(p.calls, "pull:orbit_start:0"), "pull")
    ok(W.probed == "https://books.example.test", "probed server")
end)

test("plugin's Push while reading is off while Sync while reading is on, then restored", function()
    local ui, m = newUI(true)
    local p = ui.bookorbit
    p.settings.pages_before_update = 7
    store.orbit_android.reading_schedule = "pg25"
    m:hookPluginPagePush()
    ok(p.settings.pages_before_update == 0, "off while ours is on")
    ok(store.orbit_android.saved_pages_before_update == 7, "kept the reader's value")
    m:hookPluginPagePush() -- again (another UI): still kept
    ok(store.orbit_android.saved_pages_before_update == 7, "not overwritten by 0")
    store.orbit_android.reading_schedule = "off"
    m:hookPluginPagePush()
    ok(p.settings.pages_before_update == 7, "restored")
    ok(store.orbit_android.saved_pages_before_update == nil, "forgotten")
    p.settings.pages_before_update = nil
end)

test("suspend with the screen off: plugin drain, wait, NET_DONE ok", function()
    W.broadcasts = {}
    W.screen_on = false
    local ui, m = newUI(true)
    run(5)
    local p = ui.bookorbit
    p.calls = {}
    p.pending = 1
    m:onSuspend()
    run(30)
    ok(has(p.calls, "drain:orbit_sleep"), "drain")
    local done = lastBroadcast(".NET_DONE")
    ok(done and done.extras.ok == "1", "NET_DONE ok")
    ok(store.orbit_android.last_sleep_sync.ok == true, "recorded")
end)

test("suspend with the screen on (app switch): no sleep sync", function()
    W.broadcasts = {}
    W.screen_on = true
    local ui, m = newUI(true)
    run(5)
    W.broadcasts = {}
    m:onSuspend()
    run(10)
    ok(not lastBroadcast(".NET_DONE"), "no NET_DONE")
    W.screen_on = false
end)

test("suspend: server never answers -> NET_DONE not ok at the cap", function()
    W.broadcasts = {}
    W.server_code = nil
    local ui, m = newUI(true)
    run(30)
    W.broadcasts = {}
    local t0 = W.clock
    m:onSuspend()
    run(60)
    local done = lastBroadcast(".NET_DONE")
    ok(done and done.extras.ok == "0", "NET_DONE failed")
    ok(done.at - t0 <= 22, "within the cap, took " .. (done.at - t0))
    W.server_code = 200
end)

test("sync and sleep: plugin snapshot, then SLEEP_NOW, and the following Suspend is skipped", function()
    W.broadcasts = {}
    local ui, m = newUI(true)
    run(30)
    W.broadcasts = {}
    m:onOrbitSyncAndSleep()
    run(5) -- (the Wi-Fi timer keeps the fake clock running; the skip window is 15 s)
    ok(has(ui.bookorbit.calls, "onSuspend"), "plugin _onSuspend")
    ok(lastBroadcast(".SLEEP_NOW"), "SLEEP_NOW")
    local n = #W.broadcasts
    m:onSuspend()
    run(10)
    ok(#W.broadcasts == n, "suspend after sync-and-sleep skipped")
end)

test("sync and sleep failure: message, then sleep anyway", function()
    W.server_code = nil
    local ui, m = newUI(true)
    run(30)
    W.broadcasts = {}
    m:onOrbitSyncAndSleep()
    run(40)
    ok(lastBroadcast(".SLEEP_NOW"), "SLEEP_NOW after failure")
    ok(lastBroadcast(".SLEEP_NOW").extras.reason == "sync_and_sleep_failed", "reason")
    W.server_code = 200
end)

test("no companion: Tailscale CONNECT_VPN goes to IPNReceiver; no SLEEP_NOW", function()
    W.companion = false
    W.broadcasts = {}
    W.clock = W.clock + 100 -- let the installed cache expire
    local ui, m = newUI(true)
    m:onResume()
    run(30)
    local ts = lastBroadcast("CONNECT_VPN")
    ok(ts and ts.class == "com.tailscale.ipn.IPNReceiver", "tailscale broadcast")
    ok(not lastBroadcast(".NET_UP"), "no companion broadcasts")
    m:onOrbitSyncAndSleep()
    run(30)
    ok(not lastBroadcast(".SLEEP_NOW"), "no SLEEP_NOW without companion")
    W.companion = true
    W.clock = W.clock + 100
end)

test("wifi turn-on goes to the companion, not Android settings", function()
    W.settings_opened = false
    W.broadcasts = {}
    local called = false
    NetworkMgr:turnOnWifi(function() called = true end)
    ok(called, "callback")
    ok(lastBroadcast(".NET_UP"), "NET_UP")
    ok(not W.settings_opened, "settings not opened")
end)

test("sync while reading, every 25 pages: push when this device is ahead", function()
    store.orbit_android.reading_schedule = "pg25"
    local ui, m = newUI(true)
    run(30)
    local p = ui.bookorbit
    p.calls = {}
    p.remote = { digest = "d1", percentage = 0.4 }
    for pg = 1, 25 do m:onPageUpdate(pg) end
    run(30)
    ok(has(p.calls, "fetch"), "fetched")
    ok(has(p.calls, "push:orbit_reading"), "pushed")
    store.orbit_android.reading_schedule = "off"
end)

test("sync while reading, every chapter: Ask + server ahead never pulls or prompts", function()
    store.orbit_android.reading_schedule = "ch1"
    local ui, m = newUI(true)
    run(30)
    local p = ui.bookorbit
    p.calls = {}
    p.remote = { digest = "d1", percentage = 0.9 }
    for pg = 5, 12 do m:onPageUpdate(pg) end
    run(30)
    ok(has(p.calls, "fetch"), "fetched")
    ok(count(p.calls, function(c) return c:match("^pull") or c:match("^push") end) == 0, "no pull/push")
    store.orbit_android.reading_schedule = "off"
end)

test("home from the companion: BookOrbit home opens over the book, which stays open", function()
    local ui = newUI(true)
    run(30)
    W.home_called = false
    W.shown = {}
    W.intent_extras["net.fledgewing.orbitcompanion.extra.COMMAND"] = "home"
    ui.menu.registered[1]:onResume()
    run(1)
    ok(not W.home_called, "reader not closed")
    ok(has(ui.bookorbit.calls, "dashboard"), "dashboard opened")
    ok(W.shown[#W.shown] == ui.bookorbit.catalog_browser, "dashboard on top")
    ui.bookorbit.catalog_browser.close_callback()
    ok(W.intent_extras["net.fledgewing.orbitcompanion.extra.COMMAND"] == nil, "extra consumed")
end)

test("menu is its own Tools entry, not inside the plugin's menu, and builds", function()
    local ui, m = newUI(true)
    local items = { bookorbit = { sub_item_table = {} } }
    m:addToMainMenu(items)
    ok(#items.bookorbit.sub_item_table == 0, "plugin menu untouched")
    local entry = items.orbit_android
    ok(entry and entry.text == "Android sync" and entry.sorting_hint == "tools", "Tools entry")
    local sub = entry.sub_item_table_func()
    ok(#sub >= 13, "items " .. #sub)
end)

test("pull debounce: cleared only when the last pull was within 25 s", function()
    local ui, m = newUI(true)
    run(30)
    local p = ui.bookorbit
    p.pull_timestamp = W.clock * 1e6 - 5e6 -- 5 s ago
    p.calls = {}
    m:wakeFlow("wake")
    run(5)
    ok(has(p.calls, "pull:orbit_wake:0"), "recent pull: debounce cleared")
    p.pull_timestamp = W.clock * 1e6 - 100e6 -- 100 s ago
    local before = p.pull_timestamp
    p.calls = {}
    m:wakeFlow("wake")
    run(5)
    ok(has(p.calls, "pull:orbit_wake:" .. before), "old pull: left alone")
    p.pull_timestamp = 0
end)

test("test sync path reports five steps", function()
    local ui, m = newUI(false)
    run(30)
    W.shown = {}
    m:testSyncPath()
    run(30)
    local viewer = W.shown[#W.shown]
    ok(viewer and viewer.text and viewer.text:match("5%. BookOrbit plugin synced ✓"), viewer and viewer.text or "no viewer")
end)

---------------------------------------------------------------- Wi-Fi modes (v0.2)
local function wifiOffs()
    local out = {}
    for _, b in ipairs(W.broadcasts) do if b.action:match("%.WIFI_OFF$") then table.insert(out, b) end end
    return out
end
local function fresh(mode, idle)
    store.orbit_android.wifi_mode = mode
    store.orbit_android.wifi_idle_min = idle or 2
    W.broadcasts = {}
    W.simulate_companion = true
end
local function done() W.simulate_companion = false; W.radio, W.wifi, W.owner = nil, true, nil end

test("wifi: KOReader asks for Wi-Fi silently (turn_on), in every mode", function()
    ok(store.wifi_enable_action == "turn_on", "wifi_enable_action")
end)

test("wifi: wake with Wi-Fi off brings it up, then restores it off after the pull", function()
    fresh("always_on")
    W.radio, W.wifi = false, false
    local ui, m = newUI(false)
    m:onResume()
    run(1)
    m:wakeFlow("wake")
    run(20)
    ok(lastBroadcast(".NET_UP"), "NET_UP")
    local offs = wifiOffs()
    ok(#offs >= 1 and offs[#offs].extras.auto == "1", "auto WIFI_OFF")
    ok(offs[#offs].extras.reason:find("restore", 1, true), "reason " .. tostring(offs[#offs] and offs[#offs].extras.reason))
    ok(W.radio == false, "radio back off")
    done()
end)

test("wifi: just in time turns Wi-Fi off after the idle time, and not while a download runs", function()
    fresh("jit", 1)
    local ui, m = newUI(false)
    m:onResume()
    run(30)
    W.broadcasts = {}
    -- A download that blocks for a while: activity, so the timer restarts.
    require("socket.http").request({ url = "https://dl.test/none", method = "GET" })
    run(50)
    ok(#wifiOffs() == 0, "not idle yet")
    run(40)
    local offs = wifiOffs()
    ok(#offs == 1 and offs[1].extras.reason:find("idle 1 min", 1, true), "idle off")
    done()
end)

test("wifi: just in time leaves Wi-Fi the reader turned on by hand", function()
    fresh("jit", 1)
    W.radio, W.wifi = false, false
    NetworkMgr:turnOnWifi(nil, true) -- KOReader's own toggle
    ok(lastBroadcast(".NET_UP").extras.owner == "manual", "owner manual")
    local ui, m = newUI(false)
    run(200)
    ok(#wifiOffs() >= 1, "asked")
    ok(W.radio == true, "the companion kept it on")
    done()
end)

test("wifi: never switches while another app is in front", function()
    fresh("jit", 1)
    W.screen_on = true
    local ui, m = newUI(false)
    run(5)
    m:onSuspend() -- app switch: the screen stays on
    W.broadcasts = {}
    run(200)
    ok(#wifiOffs() == 0, "no off while in the background")
    m:onResume()
    W.screen_on = false
    done()
end)

test("wifi: off while reading turns Wi-Fi off once the book's pull is done, back on at close", function()
    fresh("off_reading")
    local ui, m = newUI(true)
    m:onResume() -- picks up the mode
    run(1)
    m:onReaderReady()
    run(10)
    local offs = wifiOffs()
    ok(#offs >= 1 and offs[#offs].extras.auto == "0", "forced off at open")
    W.broadcasts = {}
    m:onCloseWidget()
    local up = lastBroadcast(".NET_UP")
    ok(up and up.extras.reason == "book_closed", "restored on")
    done()
end)

test("wifi: test sync path turns Wi-Fi on for the test and back off, and says so", function()
    fresh("always_on")
    W.radio, W.wifi = false, false
    local ui, m = newUI(false)
    W.shown = {}
    m:testSyncPath()
    run(10)
    local viewer
    for _, w in ipairs(W.shown) do if w.title == "Test sync path" then viewer = w end end
    ok(viewer, "result shown")
    ok(viewer.text:find("Wi-Fi was off: turning it on", 1, true), "on step")
    ok(viewer.text:find("Wi-Fi turned back off (it was off) ✓", 1, true), "restore step:\n" .. viewer.text)
    done()
end)

test("frozen companion: says so, and a wake with Wi-Fi off gives up at once", function()
    W.companion, W.companion_frozen = false, true
    W.clock = W.clock + 100
    W.radio, W.wifi = false, false
    local ui, m = newUI(false)
    local t0 = W.clock
    local before = #W.logs
    m:wakeFlow("wake")
    run(25)
    local skipped
    for i = before + 1, #W.logs do
        if W.logs[i]:find("disabled by", 1, true) and W.logs[i]:find("network up: FAILED", 1, true) then skipped = true end
    end
    ok(skipped, "failed fast with the frozen reason")
    ok(m:statusText():find("Orbit Companion is disabled by", 1, true), "menu status: " .. m:statusText())
    W.companion, W.companion_frozen = true, false
    W.clock = W.clock + 100
    done()
end)

test("wifi: KOReader's own Wi-Fi requests (plugin resume pull) show no Connecting message", function()
    run(60) -- let earlier tests' holds (e.g. the update check's) finish and restore first
    W.simulate_companion = true
    W.radio, W.wifi = false, false
    W.shown, W.broadcasts = {}, {}
    local ran = false
    NetworkMgr:beforeWifiAction(function() ran = true end)
    for _, w in ipairs(W.shown) do
        ok(not (w.text or ""):find("Connecting", 1, true), "no Connecting message")
    end
    ok(lastBroadcast(".NET_UP"), "asked the companion")
    ok(W.connectivity_widget == nil, "connectivity check without a widget")
    run(2)
    ok(ran, "the action ran once connected")
    W.simulate_companion = false
    W.radio, W.wifi = nil, true
end)

test("wifi: without the companion, KOReader's stock path (and message) is kept", function()
    W.companion = false
    W.clock = W.clock + 100 -- companion state cache
    W.wifi = false
    W.shown = {}
    NetworkMgr:turnOnWifiAndWaitForConnection(function() end)
    ok(W.shown[1] and W.shown[1].text == "Connecting to Wi-Fi…", "stock message")
    W.companion, W.wifi = true, true
    W.clock = W.clock + 100
    run(1)
end)

test("setup needs you: the companion's count shows in the menu status, no pop-up in a book", function()
    local url = "http://127.0.0.1:47913/status"
    W.web[url] = "STATUS"
    W.json.STATUS = { version = "0.2.4", setup_needed = 2 }
    local ui, m = newUI(true)
    W.shown = {}
    m:onResume()
    run(2)
    ok(#W.shown == 0, "no pop-up")
    ok(m:statusText():find("Orbit Companion: 2 setup steps need you", 1, true), "status: " .. m:statusText())
    W.json.STATUS = { version = "0.2.4", setup_needed = 0 }
    m:onResume()
    run(2)
    ok(not m:statusText():find("setup step", 1, true), "gone when done")
    W.web[url], W.json.STATUS = nil, nil
end)

test("setup box: once off a book, never in one; Fix opens the companion, Later snoozes there", function()
    local url = "http://127.0.0.1:47913/status"
    W.web[url] = "STATUS"
    W.json.STATUS = { version = "0.4.1", setup_needed = 1,
        setup_prompt = { key = "clicker", rows = { "Clicker buttons (accessibility)" } } }
    local function boxes()
        local n, last = 0, nil
        for _, w in ipairs(W.shown) do if w.ok_text == "Fix now" then n = n + 1; last = w end end
        return n, last
    end
    local ui, m = newUI(true)
    W.shown = {}
    m:onResume()
    run(3)
    ok(boxes() == 0, "never with a book on screen")
    ui, m = newUI(false)
    W.shown, W.activities, W.broadcasts = {}, {}, {}
    m:onResume()
    run(3)
    local n, box = boxes()
    ok(n == 1, "shown in the file browser")
    ok(box.text == "Orbit Companion needs 1 setup step: Clicker buttons (accessibility).", box.text)
    box.ok_callback()
    ok(W.activities[#W.activities].action:match("SHOW_SETUP$"), "Fix opens the companion's prompt")
    box.cancel_callback()
    ok(W.broadcasts[#W.broadcasts].action:match("SETUP_LATER$"), "Later snoozes in the companion")
    W.shown = {}
    m:onResume()
    run(3)
    ok(boxes() == 0, "once per set of steps")
    -- Snoozed in the companion: it sends no setup_prompt, only the count.
    W.json.STATUS = { version = "0.4.1", setup_needed = 2 }
    m:onResume()
    run(3)
    ok(boxes() == 0, "Later respected")
    W.web[url], W.json.STATUS = nil, nil
end)

test("stats: page turns and refreshes go to the companion in batches, and on suspend", function()
    W.broadcasts = {}
    local ui, m = newUI(true)
    run(5)
    m:onReaderReady()
    run(5)
    local open = lastBroadcast(".STATS")
    ok(open and open.extras.content == "text" and open.extras.open == "1", "announced on open")
    local n = #W.broadcasts
    for i = 1, 30 do
        m:onPageUpdate(i)
        table.insert(UIManager._refresh_stack, { mode = i % 10 == 0 and "full" or "partial" })
        UIManager:_repaint()
    end
    run(5)
    local sent = 0
    for i = n + 1, #W.broadcasts do if W.broadcasts[i].action:match("STATS$") then sent = sent + 1 end end
    ok(sent == 0, "never per page")
    run(310)
    local b = lastBroadcast(".STATS")
    ok(b.extras.reason == "interval", "interval batch: " .. tostring(b.extras.reason))
    ok(b.extras.pages == "30" and b.extras.full == "3" and b.extras.partial == "27", "counts " .. b.extras.pages .. "/" .. b.extras.full .. "/" .. b.extras.partial)
    m:onPageUpdate(31)
    m:onSuspend()
    b = lastBroadcast(".STATS")
    ok(b.extras.reason == "suspend" and b.extras.pages == "1" and b.extras.open == "0", "suspend batch")
    m:onResume()
    b = lastBroadcast(".STATS")
    ok(b.extras.reason == "resume" and b.extras.open == "1", "resume announces the book")
    run(5)
end)

test("restart command: save, ask the companion to relaunch, then quit (Android can't restart itself)", function()
    W.broadcasts = {}
    local ui, m = newUI(true)
    run(5)
    local saved, quit = false, nil
    ui.saveSettings = function() saved = true end
    UIManager.quit = function(_, code) quit = code or 0 end
    W.intent_extras["net.fledgewing.orbitcompanion.extra.COMMAND"] = "restart"
    ok(m:checkCommand("resume") == true, "command handled")
    ok(saved, "book settings saved first")
    ok(lastBroadcast(".RELAUNCH") and lastBroadcast(".RELAUNCH").extras.reason == "restart", "RELAUNCH sent")
    ok(quit == nil, "quits only after the broadcast went out")
    run(1)
    ok(quit == 0, "quit (Device canRestart is no on Android)")
    UIManager.quit = function() W.quits = (W.quits or 0) + 1 end
    run(10)
end)

test("restart with a book open (an update you started): the next start reopens that book", function()
    W.broadcasts = {}
    W.clock = W.clock + 10 -- past the last restart's once-guard
    W.files["/b.epub"] = true
    local ui, m = newUI(true)
    run(5)
    local saved = false
    ui.saveSettings = function() saved = true end
    UIManager.quit = function() W.quits = (W.quits or 0) + 1 end
    W.intent_extras["net.fledgewing.orbitcompanion.extra.COMMAND"] = "restart"
    m:checkCommand("resume")
    ok(saved, "the book's place saved before the quit")
    m:onCloseWidget() -- the quit closes the reader
    ok(store.orbit_android.restart_book == "/b.epub", "the book kept for the next start")
    run(2)
    -- The next process: KOReader starts in the file browser, BookOrbit home opened over it.
    W.opened = nil
    local ui2, m2 = newUI(false)
    local cb = {}
    cb.close_callback = function() ui2.bookorbit.catalog_browser = nil; W.catalog_closed = true end
    ui2.bookorbit.catalog_browser = cb
    W.catalog_closed = false
    m2:reopenAfterRestart("start") -- what init schedules 1 s after a start with restart_book set
    run(1)
    ok(W.opened == "/b.epub", "the book reopened: " .. tostring(W.opened))
    ok(W.catalog_closed, "BookOrbit home closed so the book is on top")
    ok(store.orbit_android.restart_book == nil, "used once")
    W.opened = nil
    m2:reopenAfterRestart("start")
    run(1)
    ok(W.opened == nil, "not reopened twice")
end)

test("restart by an older patch: COMMAND=reopen_book opens KOReader's last book", function()
    store.lastfile = "/books/last.epub"
    W.files["/books/last.epub"] = true
    W.opened = nil
    local ui, m = newUI(false)
    W.intent_extras["net.fledgewing.orbitcompanion.extra.COMMAND"] = "reopen_book"
    ok(m:checkCommand("start") == true, "command handled")
    run(1)
    ok(W.opened == "/books/last.epub", "reopened")
    -- Already in a book: nothing.
    W.opened = nil
    local ui2, m2 = newUI(true)
    W.intent_extras["net.fledgewing.orbitcompanion.extra.COMMAND"] = "reopen_book"
    m2:checkCommand("resume")
    run(1)
    ok(W.opened == nil, "a book already open stays")
end)

test("apply recommended settings: Make BookOrbit home, saved like the plugin's Opening page", function()
    local ui, m = newUI(false)
    ui.bookorbit.settings.catalog_auto_open = nil
    local flushed = 0
    local was = G_reader_settings.flush
    G_reader_settings.flush = function() flushed = flushed + 1 end
    W.shown = {}
    m:applyRecommendedSettings()
    local box
    for _, w in ipairs(W.shown) do if w.ok_callback then box = w end end
    ok(box and tostring(box.text):find("Make BookOrbit home", 1, true), "listed in the confirm")
    box.ok_callback()
    G_reader_settings.flush = was
    ok(ui.bookorbit.settings.catalog_auto_open == "home", "open mode " .. tostring(ui.bookorbit.settings.catalog_auto_open))
    ok(flushed >= 1, "flushed like the plugin's save")
    -- A mode the patch doesn't know is left alone.
    ui.bookorbit.settings.catalog_auto_open = "always"
    W.shown = {}
    m:applyRecommendedSettings()
    for _, w in ipairs(W.shown) do if w.ok_callback then w.ok_callback() end end
    ok(ui.bookorbit.settings.catalog_auto_open == "always", "unknown mode kept")
    run(3)
end)

test("the status ping says whether a book is open (the companion's restart waits for it)", function()
    local _, m = newUI(true)
    W.last_url = nil
    m:onResume()
    run(2)
    ok(W.last_url and W.last_url:find("&book=1", 1, true), "in a book: " .. tostring(W.last_url))
    local _, m2 = newUI(false)
    W.last_url = nil
    m2:onResume()
    run(2)
    ok(W.last_url and W.last_url:find("&book=0", 1, true), "file browser: " .. tostring(W.last_url))
end)

test("the status ping tells the companion which patch is running", function()
    local _, m = newUI(false)
    W.last_url = nil
    m:onResume()
    run(2)
    ok(W.last_url and W.last_url:find("/status?patch_version=", 1, true), "url " .. tostring(W.last_url))
end)

test("clicker: mapped keys turn pages inside KOReader; others reach KOReader untouched", function()
    local url = "http://127.0.0.1:47913/status"
    W.web[url] = "STATUS"
    W.json.STATUS = { version = "0.4.0", keymap = { ["87"] = { press = "next" }, ["88"] = { press = "prev", hold = "light" }, ["66"] = { press = "nothing" } } }
    local ui, m = newUI(true)
    m:onResume()
    run(2)
    local events = {}
    ui.handleEvent = function(_, ev) table.insert(events, ev.name .. ":" .. tostring(ev.args[1])) end
    local Input = require("device/input")
    W.stock_keys = 0
    ok(Input:handleKeyBoardEv({ code = 87, value = 1 }) == nil, "mapped key dropped")
    ok(events[1] == "GotoViewRel:1", "next page at key down: " .. tostring(events[1]))
    Input:handleKeyBoardEv({ code = 87, value = 0 })
    ok(#events == 1, "release does nothing more")
    ok(Input:handleKeyBoardEv({ code = 66, value = 1 }) == "key66", "'nothing' goes to KOReader")
    ok(Input:handleKeyBoardEv({ code = 24, value = 1 }) == "key24", "unmapped key goes to KOReader")
    ok(W.stock_keys == 2, "stock handler saw only the unmapped keys")
    -- Hold on a key with a hold action: fires after 0.6 s while still down.
    Input:handleKeyBoardEv({ code = 88, value = 1 })
    ok(#events == 1, "waits: the key has a hold")
    run(1)
    ok(events[2] == "ToggleFrontlight:nil", "hold -> frontlight: " .. tostring(events[2]))
    Input:handleKeyBoardEv({ code = 88, value = 0 })
    ok(#events == 2, "no press after the hold")
    Input:handleKeyBoardEv({ code = 88, value = 1 })
    W.clock = W.clock + 0.2
    Input:handleKeyBoardEv({ code = 88, value = 0 })
    ok(events[3] == "GotoViewRel:-1", "short press -> previous page")
    -- An empty map from the companion turns it all off.
    W.json.STATUS = { version = "0.4.0" }
    m:onResume()
    run(2)
    ok(Input:handleKeyBoardEv({ code = 87, value = 1 }) == "key87", "map cleared")
    W.web[url], W.json.STATUS = nil, nil
end)

test("clicker: letters, gamepad buttons, DPAD and volume reach the action through the live Device.input", function()
    local url = "http://127.0.0.1:47913/status"
    W.web[url] = "STATUS"
    W.json.STATUS = { version = "0.4.2", keymap = { ["38"] = { press = "prev" }, ["36"] = { press = "next" },
        ["96"] = { press = "next" }, ["22"] = { press = "next" }, ["25"] = { press = "next" } } }
    local Input = require("device/input")
    local Device = require("device")
    -- As after inhibitInput (input.lua:1859-1905): a stock handler copied onto the instance,
    -- shadowing the class (the 0.4.1 hook sat on the class only).
    local stock_inst = function(_, ev) W.inst_stock = (W.inst_stock or 0) + 1 return "inst" .. ev.code end
    Device.input = setmetatable({ event_map = { [38] = "J", [36] = "H", [22] = "Right", [25] = "LPgFwd" },
        handleKeyBoardEv = stock_inst }, { __index = Input })
    local ui, m = newUI(true)
    m:onResume()
    run(2)
    local events = {}
    ui.handleEvent = function(_, ev) table.insert(events, ev.name .. ":" .. tostring(ev.args[1])) end
    W.inst_stock, W.logs = 0, {}
    for _, code in ipairs({ 38, 36, 96, 22, 25 }) do
        ok(Device.input:handleKeyBoardEv({ code = code, value = 1 }) == nil, "mapped key " .. code .. " dropped")
        Device.input:handleKeyBoardEv({ code = code, value = 0 })
    end
    ok(table.concat(events, ",") == "GotoViewRel:-1,GotoViewRel:1,GotoViewRel:1,GotoViewRel:1,GotoViewRel:1", table.concat(events, ","))
    ok(Device.input:handleKeyBoardEv({ code = 37, value = 1 }) == "inst37", "unmapped letter reaches KOReader")
    ok(W.inst_stock == 1, "only the unmapped key reached the stock handler")
    local logged = table.concat(W.logs, "\n")
    ok(logged:find("key 38 J down -> mapped (own path)", 1, true), "every key is logged: " .. logged)
    ok(logged:find("key 37 ? down -> pass", 1, true), "unmapped logged too")
    Device.input = nil
    W.web[url], W.json.STATUS = nil, nil
end)

test("clicker: one path; the service's clicks arrive over /clicks, no double page turn, fallback when it's off", function()
    local url = "http://127.0.0.1:47913/status"
    W.web[url] = "STATUS"
    W.json.STATUS = { version = "0.4.2", clicker_service = true, keymap = { ["38"] = { press = "prev" } } }
    local socket = require("socket")
    local inbox, sent, closed = {}, {}, false
    socket.tcp = function()
        return {
            settimeout = function() end,
            connect = function(_, host, port) W.connected = host .. ":" .. port return 1 end,
            getfd = function() return 42 end,
            send = function(_, d) table.insert(sent, d) return #d end,
            receive = function()
                if #inbox > 0 then return nil, "timeout", table.remove(inbox, 1) end
                if closed then return nil, "closed", "" end
                return nil, "timeout", ""
            end,
            close = function() end,
        }
    end
    local ui, m = newUI(true)
    m:onResume()
    run(2)
    ok(W.connected == "127.0.0.1:47913", "channel connected")
    ok(sent[1] and sent[1]:find("^GET /clicks%?patch_version="), "asked for /clicks: " .. tostring(sent[1]))
    ok(W.looper_fd and W.looper_fd.fd == 42, "socket watched in KOReader's looper")
    local events = {}
    ui.handleEvent = function(_, ev) table.insert(events, ev.name .. ":" .. tostring(ev.args[1])) end
    local wait = require("ffi/input_android").waitForEvent
    table.insert(inbox, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nSERVICE on\n")
    local okw = wait()
    ok(okw == false, "no click yet: the stock result")
    -- The service is on: a key that still reaches KOReader is not turned into a second page turn.
    local Input = require("device/input")
    W.stock_keys = 0
    ok(Input:handleKeyBoardEv({ code = 38, value = 1 }) == "key38", "own path off while the service handles keys")
    ok(#events == 0, "no double page turn")
    table.insert(inbox, "CLICK prev 1\n")
    local okc, evs = wait()
    ok(okc == true and type(evs) == "table" and #evs == 0, "a click wakes UIManager")
    run(1)
    ok(events[1] == "GotoViewRel:-1", "the click turned the page: " .. tostring(events[1]))
    ok(table.concat(W.logs, "\n"):find("CLICK prev done", 1, true), "logged")
    -- Service off: the patch's own key path is back.
    table.insert(inbox, "SERVICE off\n")
    wait()
    ok(Input:handleKeyBoardEv({ code = 38, value = 1 }) == nil, "own path again")
    Input:handleKeyBoardEv({ code = 38, value = 0 })
    ok(events[2] == "GotoViewRel:-1", "fallback turned the page")
    -- The companion goes away: the channel closes, the own path stays on.
    table.insert(inbox, "SERVICE on\n")
    wait()
    closed = true
    wait()
    ok(W.looper_removed == 42, "fd removed from the looper")
    ok(Input:handleKeyBoardEv({ code = 38, value = 1 }) == nil, "own path after the channel closed")
    ok(#events == 3, "one turn per press")
    socket.tcp = nil
    W.web[url], W.json.STATUS = nil, nil
end)

test("broadcasts carry the patch version (for the companion's setup row)", function()
    W.broadcasts = {}
    local ui, m = newUI(false)
    m:wakeFlow("wake")
    run(5)
    local up = lastBroadcast(".NET_UP")
    ok(up and up.extras.patch_version ~= nil, "patch_version extra")
end)

test("wifi state: read from Settings.Global, never WifiManager (no ACCESS_WIFI_STATE)", function()
    W.wifi_manager_called = false
    local before = #W.logs
    W.radio = false
    local ui, m = newUI(false)
    m:onResume()
    run(20)
    ok(not W.wifi_manager_called, "isWifiEnabled not called")
    for i = before + 1, #W.logs do
        ok(not W.logs[i]:find("failed: java exception", 1, true), "no JNI failure: " .. W.logs[i])
    end
    W.radio = nil
end)

---------------------------------------------------------------- Smart Home (v0.2)
local function command(m, cmd, from)
    W.intent_extras["net.fledgewing.orbitcompanion.extra.COMMAND"] = cmd
    W.intent_extras["net.fledgewing.orbitcompanion.extra.FROM"] = from
end

test("smart home: pressed in a book -> BookOrbit home", function()
    local ui, m = newUI(true)
    run(5)
    W.home_called = false
    m:onSuspend(); W.clock = W.clock + 0.5
    command(m, "home_smart")
    m:onResume()
    run(1)
    ok(has(ui.bookorbit.calls, "dashboard") and not W.home_called, "BookOrbit home over the book")
    ui.bookorbit.catalog_browser.close_callback()
end)

test("smart home: from another app with a book open -> stay in the book", function()
    local ui, m = newUI(true)
    run(5)
    W.home_called = false
    m:onSuspend(); W.clock = W.clock + 60
    command(m, "home_smart")
    m:onResume()
    run(1)
    ok(not W.home_called, "stayed in the book")
end)

test("smart home: cold start after KOReader was killed with a book open -> that book", function()
    W.files["/books/killed.epub"] = true
    W.opened = nil
    local ui, m = newUI(false)
    command(nil, "home_smart", "other_app")
    m:checkCommand("start") -- what init schedules 1 s after a cold start
    run(5)
    ok(W.opened == "/books/killed.epub", "reopened the book it was killed with")
end)

test("smart home: from the file browser with no book open -> BookOrbit home, not history", function()
    store.lastfile = "/books/last.epub"
    W.files["/books/last.epub"] = true
    W.opened = nil
    local ui, m = newUI(false)
    run(5)
    m:onSuspend(); W.clock = W.clock + 0.5
    command(m, "home_smart")
    m:onResume()
    run(1)
    ok(W.opened == nil, "no book reopened from history")
    ok(has(ui.bookorbit.calls, "dashboard"), "BookOrbit home")
end)

test("smart home: book -> BookOrbit home -> companion -> back to the book", function()
    local ui, m = newUI(true)
    run(5)
    W.shown, W.activities, W.home_called = {}, {}, false
    local function press(from, pause)
        m:onSuspend(); W.clock = W.clock + (pause or 0.5)
        command(m, "home_smart", from)
        m:onResume()
        run(1)
    end
    press()
    ok(ui.bookorbit.catalog_browser ~= nil and W.shown[#W.shown] == ui.bookorbit.catalog_browser, "1: BookOrbit home")
    press()
    local a = W.activities[#W.activities]
    ok(a and a.action:match("%.SHOW_LAUNCHER$"), "2: companion")
    press("other_app", 30)
    ok(ui.bookorbit.catalog_browser == nil and #W.shown == 0, "3: dashboard closed, back in the book")
    ok(not W.home_called, "the book was never closed")
end)

test("smart home: fallback close by Home keeps the book current; elsewhere goes back to it", function()
    store.orbit_android.home_book = nil
    W.files["/b.epub"] = true
    local ui, m = newUI(true)
    m:onReaderReady()
    run(5)
    -- A plugin without the dashboard action (compat fallback): Home closes the book instead.
    local q = newPlugin(); q.onBookOrbitOpenDashboard = nil
    ui.bookorbit = q
    local before = #W.logs
    m:onOrbitGoHome()
    run(1)
    ok(W.home_called, "closed by Home")
    local logged = false
    for i = before + 1, #W.logs do
        if W.logs[i]:find("compat: dashboard unavailable (plugin", 1, true) then logged = true end
    end
    ok(logged, "compat logged")
    m:onCloseWidget()
    ok(store.orbit_android.home_book == "/b.epub", "still the current book")
    local fm, m2 = newUI(false)
    run(5)
    W.opened = nil
    command(m2, "home_smart", "other_app")
    m2:onResume()
    run(1)
    ok(W.opened == "/b.epub", "back to the book Home closed")
    -- A user close clears it.
    local ui3, m3 = newUI(true)
    m3:onReaderReady()
    m3:onCloseWidget()
    ok(store.orbit_android.home_book == nil, "user close clears it")
end)

-- Like KOReader 2025.10+ (frontend/pluginloader.lua v2026.07.1:117-164): on* handlers become
-- callable tables.
local function sandboxed(p)
    for k, v in pairs(p) do
        if type(k) == "string" and k:sub(1, 2) == "on" and type(v) == "function" then
            p[k] = setmetatable({ f = v }, { __call = function(t, module, ...) return t.f(module, ...) end })
        end
    end
    return p
end

test("home: plugin handlers wrapped by KOReader 2026.07 -> Home on the file browser opens BookOrbit home", function()
    store.lastfile = nil
    local ui, m = newUI(false)
    sandboxed(ui.bookorbit)
    run(5)
    W.shown, W.activities = { { name = "filemanager" } }, {}
    command(m, "home_smart", "other_app")
    m:onResume()
    run(2)
    ok(has(ui.bookorbit.calls, "dashboard"), "dashboard handler ran")
    ok(W.shown[#W.shown] == ui.bookorbit.catalog_browser, "BookOrbit home on top")
    ok(#W.activities == 0, "no companion page")
    ui.bookorbit.catalog_browser = nil
    W.shown = {}
end)

test("home: the instance shows no handler but the UI routes the event -> BookOrbit home opens", function()
    store.lastfile = nil
    local ui, m = newUI(false)
    local real = ui.bookorbit
    local seen = newPlugin()
    seen.onBookOrbitOpenDashboard = nil -- what the patch sees; the UI still has the real module
    ui.bookorbit = seen
    function ui:handleEvent(ev)
        local h = real["on" .. ev.name]
        if h then return h(real, unpack(ev.args)) end
    end
    run(5)
    W.shown, W.activities = { { name = "filemanager" } }, {}
    command(m, "home_smart", "other_app")
    m:onResume()
    run(2)
    ok(has(real.calls, "dashboard"), "event reached the plugin")
    ok(W.shown[#W.shown] == real.catalog_browser, "BookOrbit home on top")
    W.shown = {}
end)

local function scheduleMenu(m)
    for _, it in ipairs(m:menuItems()) do
        local sub = it.sub_item_table
        if type(sub) == "table" and sub[1] and sub[1].text == "Off" and sub[1].checked_func then return sub end
    end
end

test("sync while reading: set in the companion, applied and saved by the patch, shown in its menu, acked", function()
    local url = "http://127.0.0.1:47913/status"
    store.orbit_android.reading_schedule = "off"
    store.orbit_android.reading_schedule_request_at = nil
    -- KOReader wasn't running when the user chose it: the companion's /status still carries it.
    W.web[url] = "STATUS"
    W.json.STATUS = { version = "0.4.8", reading_schedule_request = { id = "pg50", at = 5000 } }
    W.broadcasts = {}
    local ui, m = newUI(true)
    m:onResume()
    run(2)
    ok(store.orbit_android.reading_schedule == "pg50", "applied: " .. tostring(store.orbit_android.reading_schedule))
    ok(store.orbit_android.reading_schedule_request_at == 5000, "remembered which request")
    local sub = scheduleMenu(m)
    for _, it in ipairs(sub) do
        ok(it.checked_func() == (it.text == "Every 50 pages"), "menu shows it: " .. it.text)
    end
    local ack = lastBroadcast(".SETTINGS")
    ok(ack and ack.extras.reading_schedule == "pg50" and ack.extras.reading_schedule_applied_at == "5000", "companion told")
    -- The user changes it in KOReader's menu: the old request is never applied again.
    for _, it in ipairs(sub) do if it.text == "Every chapter" then it.callback() end end
    ok(lastBroadcast(".SETTINGS").extras.reading_schedule == "ch1", "menu change sent to the companion")
    m:onResume()
    run(2)
    ok(store.orbit_android.reading_schedule == "ch1", "stale request not re-applied")
    -- A newer one from the companion wins.
    W.json.STATUS = { version = "0.4.8", reading_schedule_request = { id = "min15", at = 9000 } }
    m:onResume()
    run(2)
    ok(store.orbit_android.reading_schedule == "min15", "newer request applied")
    W.web[url], W.json.STATUS = nil, nil
    store.orbit_android.reading_schedule = "off"
end)

test("home button menu says it is about KOReader, and notes the companion's Home opens", function()
    local url = "http://127.0.0.1:47913/status"
    W.web[url] = "STATUS"
    local ui, m = newUI(false)
    local function homeText()
        for _, it in ipairs(m:menuItems()) do
            if it.text_func then
                local t = it.text_func()
                if t:find("In KOReader, Home goes to", 1, true) then return t end
            end
        end
    end
    W.json.STATUS = { version = "0.4.8", settings = { settings_at = 0, home_opens = "koreader" } }
    m:onResume(); run(1)
    ok(homeText() == "In KOReader, Home goes to: Back to my book, then BookOrbit home", tostring(homeText()))
    W.json.STATUS = { version = "0.4.8", settings = { settings_at = 0, home_opens = "launcher" } }
    m:onResume(); run(1)
    ok(homeText():find("(Home opens the Orbit launcher page)", 1, true), homeText())
    W.web[url], W.json.STATUS = nil, nil
    m:onResume(); run(1)
    ok(not homeText():find("(", 1, true), "no companion: no note")
end)

test("compat: a check that found something missing early doesn't stick", function()
    local ui, m = newUI(true)
    local q = newPlugin()
    local drain, outbox = q.requestLifecycleOutboxDrain, q.getLifecycleOutbox
    q.getLifecycleOutbox, q.requestLifecycleOutboxDrain, q.PLUGIN_VERSION = nil, nil, "9.9.8"
    ui.bookorbit = q
    ok(m:statusText():find("BookOrbit 9.9.8 changed", 1, true), "missing at first")
    q.getLifecycleOutbox, q.requestLifecycleOutboxDrain = outbox, drain -- the plugin finished init
    ok(not m:statusText():find("BookOrbit 9.9.8 changed", 1, true), "re-checked: " .. m:statusText())
end)

test("compat: a plugin without its outbox API -> sleep sync leaves it to the plugin, no error", function()
    local ui, m = newUI(true)
    local q = newPlugin()
    q.getLifecycleOutbox, q.requestLifecycleOutboxDrain, q.PLUGIN_VERSION = nil, nil, "9.9.9"
    ui.bookorbit = q
    W.broadcasts = {}
    m:sleepSync("sleep")
    run(30)
    local done = lastBroadcast(".NET_DONE")
    ok(done and done.extras.ok == "1", "NET_DONE ok")
    ok(m:statusText():find("BookOrbit 9.9.9 changed: wake and sleep syncs use the plugin's own sync", 1, true),
        "menu status: " .. m:statusText())
end)

test("compat: a plugin without fetchRemoteProgress -> Sync while reading does nothing", function()
    local ui, m = newUI(true)
    local q = newPlugin(); q.fetchRemoteProgress = nil
    ui.bookorbit = q
    m:readingSync()
    run(30)
    ok(not has(q.calls, "fetch"), "no fetch")
    ok(m:statusText():find("Sync while reading is off", 1, true), "status says so")
end)

test("compat: a catalog without dashboardMode -> not treated as BookOrbit home", function()
    local ui, m = newUI(true)
    run(5)
    local cb = {}
    cb.close_callback = function() UIManager:close(cb); ui.bookorbit.catalog_browser = nil end
    ui.bookorbit.catalog_browser = cb
    W.shown, W.activities = { cb }, {}
    m:onSuspend(); W.clock = W.clock + 0.5
    command(m, "home_smart")
    m:onResume()
    run(1)
    ok(#W.activities == 0, "no companion page")
    ok(ui.bookorbit.catalog_browser == nil, "back to the book")
end)

test("open book at exit: set when a book opens, cleared when it is closed", function()
    local ui, m = newUI(true)
    m:onReaderReady()
    run(5)
    ok(store.orbit_android.open_book_at_exit == "/b.epub", "set")
    m:onCloseWidget()
    ok(store.orbit_android.open_book_at_exit == nil, "cleared")
end)

test("smart home: no last book -> BookOrbit home", function()
    store.lastfile = nil
    local ui, m = newUI(false)
    run(5)
    command(m, "home_smart", "other_app")
    m:onResume()
    run(5)
    ok(has(ui.bookorbit.calls, "dashboard"), "dashboard")
end)

local function dashboardOnTop(ui, kind)
    local cb = { dashboardMode = function() return kind == "dashboard" end }
    ui.bookorbit.catalog_browser = cb
    W.shown = { cb }
end

for _, cmd in ipairs({ "home_smart", "home" }) do
    test("home (" .. cmd .. "): pressed on BookOrbit home -> the companion's launcher page", function()
        store.lastfile = "/books/last.epub"
        W.files["/books/last.epub"] = true
        local ui, m = newUI(false)
        run(5)
        dashboardOnTop(ui, "dashboard")
        W.activities, W.opened = {}, nil
        m:onSuspend(); W.clock = W.clock + 0.5
        command(m, cmd)
        m:onResume()
        run(1)
        local a = W.activities[#W.activities]
        ok(a and a.action:match("%.SHOW_LAUNCHER$"), "launcher page started")
        ok(W.opened == nil, "no book opened")
        ui.bookorbit.catalog_browser = nil
        W.shown = {}
    end)
end

test("home: from the companion page while BookOrbit home is on top, no book -> BookOrbit home", function()
    store.lastfile = "/books/last.epub"
    W.files["/books/last.epub"] = true
    local ui, m = newUI(false)
    run(5)
    dashboardOnTop(ui, "dashboard")
    W.activities, W.opened = {}, nil
    command(m, "home_smart", "other_app")
    m:onResume()
    run(1)
    ok(#W.activities == 0, "no companion page")
    ok(W.opened == nil, "no book reopened")
    ui.bookorbit.catalog_browser = nil
    W.shown = {}
end)

test("home: file browser on top of a stale BookOrbit home -> BookOrbit home brought to the top", function()
    store.lastfile = nil
    local ui, m = newUI(false)
    run(5)
    local stale = { dashboardMode = function() return true end }
    stale.close_callback = function() UIManager:close(stale); ui.bookorbit.catalog_browser = nil end
    ui.bookorbit.catalog_browser = stale
    local browser = { name = "filemanager" }
    W.shown = { stale, browser }
    W.activities, W.opened = {}, nil
    command(m, "home_smart", "other_app")
    m:onResume()
    run(2)
    local top = W.shown[#W.shown]
    ok(#W.activities == 0, "no companion page")
    ok(ui.bookorbit.catalog_browser ~= nil and ui.bookorbit.catalog_browser ~= stale, "reopened")
    ok(top == ui.bookorbit.catalog_browser, "BookOrbit home is on top")
    ok(m:whereNow() == "bookorbit", "where: bookorbit")
    ui.bookorbit.catalog_browser = nil
    W.shown = {}
end)

-- A catalog like plugin 2.3.0's: modes switched in place, goDashboard back to the main page.
local function catalogIn(ui, kind)
    local p = ui.bookorbit
    local cb = { current_context = { kind = kind } }
    function cb:dashboardMode() return self.current_context.kind == "dashboard" end
    function cb:goDashboard() self.current_context = { kind = "dashboard" }; W.went_dashboard = true end
    cb.close_callback = function() UIManager:close(cb); p.catalog_browser = nil end
    p.catalog_browser = cb
    W.shown = { cb }
    return cb
end

local function homePress(m)
    W.activities, W.opened, W.home_called, W.went_dashboard = {}, nil, false, false
    m:onSuspend(); W.clock = W.clock + 0.5
    command(m, "home_smart")
    m:onResume()
    run(2)
end

test("home: BookOrbit detail view over an open book -> BookOrbit main page, book stays", function()
    store.lastfile = "/books/last.epub"
    W.files["/books/last.epub"] = true
    local ui, m = newUI(true)
    run(5)
    local cb = catalogIn(ui, "detail")
    homePress(m)
    ok(#W.activities == 0, "no companion page")
    ok(not W.home_called, "the book stays open")
    ok(W.went_dashboard and cb:dashboardMode(), "catalog back to its main page")
    ok(W.shown[#W.shown] == cb, "same catalog on top")
    ui.bookorbit.catalog_browser = nil
    W.shown = {}
end)

test("home: a sheet over BookOrbit's main page -> the sheet closed, main page", function()
    store.lastfile = nil
    local ui, m = newUI(false)
    run(5)
    local cb = catalogIn(ui, "dashboard")
    local closed = false
    local sheet = { name = "bookorbit_menu_sheet", onCloseWidget = function() closed = true end }
    sheet.dismiss_callback = function() closed = true end
    table.insert(W.shown, sheet)
    homePress(m)
    ok(#W.activities == 0, "no companion page")
    ok(closed and W.shown[#W.shown] == cb, "sheet closed, catalog on top")
    ok(cb:dashboardMode(), "main page")
    ui.bookorbit.catalog_browser = nil
    W.shown = {}
end)

-- Plugin 2.3.0's paging: the dashboard's board_page (boardPage/boardFlip), a list's page
-- (listMode/listPaging/listGoPage).
local function withPaging(cb, page)
    cb.current_context.board_page = page
    cb.list_page = page
    function cb:boardPage() return self.current_context.board_page end
    function cb:boardFlip(d) self.current_context.board_page = self.current_context.board_page + d end
    function cb:listMode() return self.current_context.kind == "books" end
    function cb:listPaging() return { page = self.list_page } end
    function cb:listGoPage(n) self.list_page = n; W.list_went = n end
    return cb
end

test("home: BookOrbit home on page 2 -> page 1, not the companion", function()
    store.lastfile = nil
    local ui, m = newUI(false)
    run(5)
    local cb = withPaging(catalogIn(ui, "dashboard"), 2)
    homePress(m)
    ok(#W.activities == 0, "no companion page")
    ok(cb:boardPage() == 1, "page 1")
    ok(W.shown[#W.shown] == cb and cb:dashboardMode(), "same catalog, main page")
    homePress(m)
    local a = W.activities[#W.activities]
    ok(a and a.action:match("%.SHOW_LAUNCHER$"), "page 1: the launcher page")
    ui.bookorbit.catalog_browser = nil
    W.shown = {}
end)

test("home: a BookOrbit list on page 3 -> its page 1, then the main page", function()
    store.lastfile = nil
    local ui, m = newUI(false)
    run(5)
    local cb = withPaging(catalogIn(ui, "books"), 3)
    W.list_went = nil
    homePress(m)
    ok(W.list_went == 1, "list page 1")
    ok(not W.went_dashboard and #W.activities == 0, "stayed on the list")
    homePress(m)
    ok(W.went_dashboard and cb:dashboardMode(), "then the main page")
    ui.bookorbit.catalog_browser = nil
    W.shown = {}
end)

test("home: catalog in a list mode, plugin without goDashboard -> reopened on its main page", function()
    store.lastfile = nil
    local ui, m = newUI(false)
    run(5)
    local cb = catalogIn(ui, "books")
    cb.goDashboard = nil
    homePress(m)
    local now = ui.bookorbit.catalog_browser
    ok(now ~= nil and now ~= cb, "a fresh catalog")
    ok(W.shown[#W.shown] == now and now:dashboardMode(), "on its main page")
    ok(#W.shown == 1, "the old one closed: " .. #W.shown)
    ok(#W.activities == 0, "no companion page")
    ui.bookorbit.catalog_browser = nil
    W.shown = {}
end)

test("home: BookOrbit's true main page -> the companion's launcher page", function()
    local ui, m = newUI(false)
    run(5)
    catalogIn(ui, "dashboard")
    homePress(m)
    local a = W.activities[#W.activities]
    ok(a and a.action:match("%.SHOW_LAUNCHER$"), "launcher page")
    ok(not W.went_dashboard, "no reset")
    ui.bookorbit.catalog_browser = nil
    W.shown = {}
end)

test("apps gesture: registered and in the recommended set", function()
    ok(actions.orbit_open_apps and actions.orbit_open_apps.title == "Orbit Companion: apps", "action title")
    local ui, m = newUI(true)
    W.shown = {}
    m:applyRecommendedGestures()
    local box = W.shown[#W.shown]
    box.ok_callback()
    ok(ui.gestures.data.gesture_reader.two_finger_swipe_north.orbit_open_apps, "two-finger swipe up")
end)

---------------------------------------------------------------- self-update
local API = "https://api.github.com/repos/Fledgewing/Orbify/releases/latest"
local ZIP_URL, SUMS_URL = "https://dl.test/orbit.koplugin.zip", "https://dl.test/SHA256SUMS"
local NEW = '-- new\nlocal PATCH_VERSION = "0.2.0"\nreturn\n'
local ZIP = "PK fake orbit.koplugin 0.2.0"
W.zips = W.zips or {}
W.zips[ZIP] = { ["orbit.koplugin/main.lua"] = NEW, ["orbit.koplugin/ko/x.lua"] = "-- x\n" }
local function serveRelease(sha)
    W.web = { [API] = "LATEST", [ZIP_URL] = ZIP, [SUMS_URL] = (sha or W.fake_sha(ZIP)) .. "  orbit.koplugin.zip\n" }
    W.json = { LATEST = { tag_name = "v0.2.0", assets = {
        { name = "orbit.koplugin.zip", browser_download_url = ZIP_URL },
        { name = "SHA256SUMS", browser_download_url = SUMS_URL },
    } } }
end
local function selfText()
    local f = io.open(SELF_PATH, "rb")
    if not f then return nil end
    local t = f:read("*a"); f:close(); return t
end
local function resetSelf()
    sh("rm -rf", ORBIT_ANDROID_PLUGIN_DIR); sh("mkdir -p", ORBIT_ANDROID_PLUGIN_DIR)
    local f = io.open(SELF_PATH, "wb"); f:write("-- old\n"); f:close()
end

test("update: menu check installs a verified newer plugin over its own folder", function()
    resetSelf(); serveRelease()
    local _ui, orbit = newUI(false)
    orbit:checkPatchUpdate()
    run(5)
    ok(selfText() == NEW, "folder replaced")
    ok(io.open(ORBIT_ANDROID_PLUGIN_DIR .. "/ko/x.lua") ~= nil, "every file unpacked")
    for _, rest in ipairs({ ".new/main.lua", ".old/main.lua", ".zip.new" }) do
        ok(io.open(ORBIT_ANDROID_PLUGIN_DIR .. rest) == nil, "temp " .. rest .. " gone")
    end
    ok(store.orbit_android.patch_update_status.text:find("updated to 0.2.0", 1, true), "status")
end)

test("update: checksum mismatch leaves the file alone", function()
    resetSelf(); serveRelease(string.rep("b", 64))
    local _ui, orbit = newUI(false)
    orbit:checkPatchUpdate()
    run(5)
    ok(selfText() == "-- old\n", "unchanged")
    ok(store.orbit_android.patch_update_status.text:find("checksum", 1, true), "status says checksum")
end)

test("update: a zip with a file outside orbit.koplugin/ is refused, the plugin left alone", function()
    resetSelf(); serveRelease()
    local evil = "PK fake evil"
    W.zips[evil] = { ["orbit.koplugin/main.lua"] = NEW, ["orbit.koplugin/../x.lua"] = "-- x\n" }
    W.web[ZIP_URL] = evil
    W.web[SUMS_URL] = W.fake_sha(evil) .. "  orbit.koplugin.zip\n"
    local _ui, orbit = newUI(false)
    orbit:checkPatchUpdate()
    run(5)
    ok(selfText() == "-- old\n", "unchanged")
    ok(io.open(ORBIT_ANDROID_PLUGIN_DIR .. ".new/main.lua") == nil, "nothing staged")
    ok(store.orbit_android.patch_update_status.text:find("unexpected file", 1, true), "status says why")
end)

test("update: a zip whose main.lua declares another version is refused", function()
    resetSelf(); serveRelease()
    local other = "PK fake other"
    W.zips[other] = { ["orbit.koplugin/main.lua"] = '-- x\nlocal PATCH_VERSION = "0.1.9"\n' }
    W.web[ZIP_URL] = other
    W.web[SUMS_URL] = W.fake_sha(other) .. "  orbit.koplugin.zip\n"
    local _ui, orbit = newUI(false)
    orbit:checkPatchUpdate()
    run(5)
    ok(selfText() == "-- old\n", "unchanged")
    ok(io.open(ORBIT_ANDROID_PLUGIN_DIR .. ".new/main.lua") == nil, "staging removed")
    ok(store.orbit_android.patch_update_status.text:find("declares 0.1.9", 1, true), "status says why")
end)

test("update: automatic check at most once a day, and only when connected", function()
    resetSelf(); serveRelease()
    W.json.LATEST.tag_name = "v0.0.0-dev" -- nothing newer: just count checks
    store.orbit_android.patch_update_checked_at = 0
    store.orbit_android.patch_update_failed_at = nil -- the checksum test above failed a check
    local _ui, orbit = newUI(false)
    W.fetched = {}
    W.wifi = false
    orbit:wakeFlow("wake")
    run(40)
    ok(not has(W.fetched, API), "no check without network")
    W.wifi = true
    orbit:wakeFlow("wake")
    run(40)
    ok(count(W.fetched, function(u) return u == API end) == 1, "one check")
    orbit:wakeFlow("wake")
    run(40)
    ok(count(W.fetched, function(u) return u == API end) == 1, "still one check the same day")
    store.orbit_android.auto_update_patch = false
    store.orbit_android.patch_update_checked_at = 0
    orbit:wakeFlow("wake")
    run(40)
    ok(count(W.fetched, function(u) return u == API end) == 1, "off means off")
    store.orbit_android.auto_update_patch = true
end)
test("update: a failed automatic check backs off 1 h, then is tried again", function()
    resetSelf(); serveRelease()
    W.json.LATEST.tag_name = "v0.0.0-dev"
    store.orbit_android.patch_update_checked_at = 0
    store.orbit_android.patch_update_failed_at = nil
    W.wifi = true
    local _ui, orbit = newUI(false)
    local saved = W.web[API]
    W.web[API] = nil -- GitHub unreachable (404 here; EACCES on the device)
    W.fetched = {}
    orbit:wakeFlow("wake")
    run(40)
    ok(count(W.fetched, function(u) return u == API end) == 1, "first check ran")
    ok(store.orbit_android.patch_update_checked_at == 0, "a failure doesn't start the 24 h wait")
    ok((store.orbit_android.patch_update_failed_at or 0) > 0, "the failure is recorded")
    W.web[API] = saved
    orbit:wakeFlow("wake")
    run(40)
    ok(count(W.fetched, function(u) return u == API end) == 1, "no retry within the hour")
    store.orbit_android.patch_update_failed_at = os.time() - 3601
    orbit:wakeFlow("wake")
    run(40)
    ok(count(W.fetched, function(u) return u == API end) == 2, "retried after the hour")
    ok(store.orbit_android.patch_update_checked_at > 0, "success starts the wait")
end)

test("update: a timeout right after Wi-Fi comes up is retried, and the check then succeeds", function()
    resetSelf(); serveRelease()
    W.json.LATEST.tag_name = "v0.0.0-dev"
    store.orbit_android.patch_update_checked_at = 0
    store.orbit_android.patch_update_failed_at = nil
    W.wifi = true
    local http = require("socket.http")
    local fast = http.request
    local fails = 2
    http.request = function(t)
        if t.url == API and fails > 0 then fails = fails - 1; return nil, "timeout" end
        return fast(t)
    end
    W.slept = {}
    local _ui, orbit = newUI(false)
    orbit:wakeFlow("wake")
    run(40)
    http.request = fast
    ok(table.concat(W.slept, ",") == "3,10", "waited 3 s then 10 s: " .. table.concat(W.slept, ","))
    ok(store.orbit_android.patch_update_checked_at > 0, "succeeded on the third try")
    ok(not store.orbit_android.patch_update_failed_at, "no failure recorded")
end)

test("update: the check never blocks KOReader's UI thread, and holds Wi-Fi while it runs", function()
    resetSelf(); serveRelease()
    W.json.LATEST.tag_name = "v0.0.0-dev"
    store.orbit_android.patch_update_checked_at = 0
    store.orbit_android.patch_update_failed_at = nil
    W.wifi = true
    -- A slow network: each GitHub request takes 30 s of the caller's time.
    local http = require("socket.http")
    local fast = http.request
    http.request = function(t)
        if t.url:find("github", 1, true) then W.clock = W.clock + 30 end
        return fast(t)
    end
    W.hold_child, W.fetched, W.logs = true, {}, {}
    local _ui, orbit = newUI(false)
    orbit:wakeFlow("wake")
    local before = W.clock
    run(20)
    ok(#W.children > 0, "the check went to a background process")
    ok(not has(W.fetched, API), "no GitHub request on the UI thread")
    ok(W.clock - before <= 20.5, "the scheduler kept time: " .. (W.clock - before))
    local logs = table.concat(W.logs, "\n")
    ok(logs:find("wifi: hold for update", 1, true), "Wi-Fi held for the check")
    ok(not logs:find("wifi: release update", 1, true), "still held while it runs")
    W.children[#W.children].run()
    run(2)
    ok(has(W.fetched, API), "the background process did the request")
    ok(table.concat(W.logs, "\n"):find("wifi: release update", 1, true), "released when it ended")
    ok(store.orbit_android.patch_update_checked_at > 0, "result reached the UI side")
    http.request, W.hold_child = fast, nil
end)

test("update: never with a book open; deferred to the file browser", function()
    resetSelf(); serveRelease()
    W.json.LATEST.tag_name = "v0.0.0-dev"
    store.orbit_android.patch_update_checked_at = 0
    store.orbit_android.patch_update_failed_at = nil
    W.wifi, W.fetched = true, {}
    local _ui, orbit = newUI(true)
    orbit:wakeFlow("wake")
    run(40)
    ok(not has(W.fetched, API), "no check in a book")
    newUI(false)
    run(40)
    ok(count(W.fetched, function(u) return u == API end) == 1, "ran on reaching the file browser")
end)
---------------------------------------------------------------- one update covers everything
local function stampSelf(v)
    sh("mkdir -p", ORBIT_ANDROID_PLUGIN_DIR)
    local f = io.open(SELF_PATH, "wb")
    f:write('-- BookOrbit-Android patch\nlocal PATCH_VERSION = "' .. v .. '"\nreturn\n'); f:close()
end
local function relaunches() return count(W.broadcasts, function(b) return b.action:sub(-9) == ".RELAUNCH" end) end
local function restartReset() run(10); W.clock = W.clock + 10; store.orbit_android.restart_tried = nil; W.broadcasts = {} end

test("one update: our own update with no book open restarts KOReader at once", function()
    restartReset(); resetSelf(); serveRelease()
    local _ui, orbit = newUI(false)
    orbit:checkPatchUpdate()
    run(5)
    ok(selfText() == NEW, "file replaced")
    ok(relaunches() == 1, "restarted once: " .. relaunches())
    ok(store.orbit_android.restart_tried == "0.2.0", "one try recorded for 0.2.0")
    restartReset()
end)

test("one update: a new file with no book open restarts on resume (the companion installed it)", function()
    restartReset(); stampSelf("0.3.0")
    local _ui, m = newUI(false)
    m:onResume()
    run(3)
    ok(relaunches() == 1, "restarted: " .. relaunches())
    restartReset()
end)

test("one update: a book open waits, then restarts once the book is closed", function()
    restartReset(); stampSelf("0.3.0")
    W.screen_on = true
    local _ui, m = newUI(true)
    m:onResume()
    run(5)
    ok(relaunches() == 0, "never interrupts reading")
    m:onCloseWidget()
    newUI(false)
    run(3)
    ok(relaunches() == 1, "restarted after the close: " .. relaunches())
    restartReset()
end)

test("one update: closing one book to open another doesn't restart", function()
    restartReset(); stampSelf("0.3.0")
    W.screen_on = true
    local _ui, m = newUI(true)
    m:onResume()
    run(2)
    m:onCloseWidget()
    newUI(true)
    run(3)
    ok(relaunches() == 0, "still reading")
    restartReset()
end)

test("one update: a book open restarts when the device sleeps, after the sleep sync", function()
    restartReset(); stampSelf("0.3.0")
    W.screen_on = true
    local _ui, m = newUI(true)
    m:onResume()
    run(5)
    W.screen_on = false
    m:onSuspend()
    run(40)
    local done_i, relaunch_i
    for i, b in ipairs(W.broadcasts) do
        if b.action:sub(-9) == ".NET_DONE" then done_i = done_i or i end
        if b.action:sub(-9) == ".RELAUNCH" then relaunch_i = relaunch_i or i end
    end
    ok(relaunch_i, "restarted on sleep")
    ok(done_i and done_i < relaunch_i, "after the sleep sync finished")
    restartReset()
end)

test("one update: an app switch (screen on) in a book doesn't restart", function()
    restartReset(); stampSelf("0.3.0")
    W.screen_on = true
    local _ui, m = newUI(true)
    m:onSuspend()
    run(10)
    ok(relaunches() == 0, "screen on: not asleep")
    restartReset()
end)

test("one update: after its restart the new patch shows one status line", function()
    restartReset(); stampSelf("0.0.0-dev")
    store.orbit_android.restart_tried = "0.0.0-dev"
    W.shown = {}
    local _ui, m = newUI(false)
    m:onResume()
    run(3)
    local found = false
    for _, w in ipairs(W.shown) do if tostring(w.text):find("Updated to v0.0.0-dev (KOReader restarted)", 1, true) then found = true end end
    ok(found, "status line shown")
    ok(store.orbit_android.restart_tried == nil, "try cleared")
    ok(store.orbit_android.patch_update_status.text:find("KOReader restarted", 1, true), "update status")
    restartReset()
end)

test("one update: a file that still didn't load after its restart is left to Setup (no loop)", function()
    restartReset(); stampSelf("0.3.0")
    store.orbit_android.restart_tried = "0.3.0"
    local _ui, m = newUI(false)
    m:onResume()
    run(3)
    ok(relaunches() == 0, "no second restart")
    ok(store.orbit_android.patch_update_status.text:find("didn't load", 1, true), "says so")
    restartReset()
end)
W.screen_on = false
sh("rm -rf", ORBIT_ANDROID_PLUGIN_DIR)
os.remove(SELF)

test("settings PIN: a locked companion locks the Orbit menu and opens its keypad; unreachable stays usable", function()
    local url = "http://127.0.0.1:47913/status"
    local ui, m = newUI(true)
    local items = {}
    m:addToMainMenu(items)
    W.web[url] = "STATUS"
    W.json.STATUS = { version = "0.4.4", pin_locked = true }
    W.activities = {}
    local sub = items.orbit_android.sub_item_table_func()
    ok(#sub == 2 and sub[1].text:find("PIN", 1, true), "locked menu " .. #sub)
    run(1)
    ok(W.activities[#W.activities] and W.activities[#W.activities].action:match("SHOW_PIN$"), "keypad asked for")
    W.activities = {}
    sub[1].callback()
    ok(W.activities[1] and W.activities[1].action:match("SHOW_PIN$"), "tap opens the keypad again")
    W.json.STATUS = { version = "0.4.4", pin_locked = false }
    ok(#items.orbit_android.sub_item_table_func() >= 13, "unlocked: full menu")
    W.web[url], W.json.STATUS = nil, nil
    W.activities = {}
    ok(#items.orbit_android.sub_item_table_func() >= 13, "companion unreachable: full menu")
    run(1)
    for _, a in ipairs(W.activities) do ok(not a.action:match("SHOW_PIN$"), "no keypad without the companion") end
end)

---------------------------------------------------------------- lists by series and by author
-- A catalog class like plugin 2.3.0's (bookorbit_catalog.lua with CatalogLists mixed in), cut
-- to what the wrappers touch, and its API class answering from a fake server.
local function fakeCatalogClass(server)
    local Cat = {}
    Cat.__index = Cat
    function Cat:listKind(ctx)
        ctx = ctx or self.current_context or {}
        if ctx.kind == "section" then return ctx.section end
        if ctx.kind == "books" then
            local p = ctx.params or {}
            if p.seriesId or p.series then return "seriespage" end
            if p.author then return "authorpage" end
            return "books"
        end
    end
    function Cat:runConnected(fn) fn() end
    function Cat:fetch(text, fn) table.insert(self.labels, text); return fn() end
    function Cat:showRetry(err) self.retry = err end
    function Cat:paramsForEntry(section, e)
        local p = { sort = section == "series" and "series" or "title" }
        if e.seriesId then p.seriesId = e.seriesId else p.series = e.id end
        return p
    end
    function Cat:loadBooks(params, title, push) self.loaded = { params = params, title = title, push = push } end
    function Cat:switchTo(title, items, context, push) self.current_context = context; self.pushed = push end
    function Cat:listSectionParams(section, opts)
        return { q = opts.q, sort = opts.sort, filter = opts.filter, size = 2, offset = opts.offset, page = opts.page }
    end
    -- bookorbit_catalog.lua:974-1045, cut down.
    function Cat:loadSection(section, opts)
        opts = opts or {}
        self:runConnected(function()
            local params = self:listSectionParams(section, opts)
            local body = self:fetch("Opening", function() return self.client:catalogSection(section, params) end)
            self:switchTo(section, {}, { kind = "section", section = section, entries = body.items, total = body.total,
                buckets = body.buckets, sort = body.sort, filter = body.filter, page = body.page, offset = body.offset }, not opts.replace)
        end)
    end
    function Cat:listSortSheetModel() return { title = "Sort and filter", rows = { { key = "device" } } } end
    function Cat:listRun(action) self.stock_run = action.kind end
    function Cat:listHeader() return { title = "Series", sub = "3 series · A–Z" } end
    function Cat:listToolbar() return { { key = "tb-sort" } } end
    function Cat:listSortLabel() return "Title A–Z" end
    local Api = {}
    Api.__index = Api
    function Api:query(path, params)
        local keys = {}
        for k, v in pairs(params or {}) do table.insert(keys, k .. "=" .. tostring(v)) end
        table.sort(keys)
        return path .. "?" .. table.concat(keys, "&")
    end
    -- Two books a page whatever the size asked, so reading the list takes several requests.
    function Api:catalogBooks(params)
        table.insert(server.urls, self:query("/books", params))
        local page = tonumber(params.page) or 1
        local items = {}
        for i = (page - 1) * 2 + 1, math.min(#server.books, page * 2) do table.insert(items, server.books[i]) end
        return { items = items, total = #server.books, page = page, hasNext = page * 2 < #server.books }
    end
    function Api:catalogSection(section) server.sections = (server.sections or 0) + 1; return { items = {}, total = 0 } end
    function Api:catalogManifest(params) server.manifest = self:query("/manifest", params); return {} end
    return Cat, Api
end

local function newCatalog(Cat, Api, context)
    local cat = setmetatable({ labels = {}, client = setmetatable({}, Api) }, Cat)
    cat.current_context = context
    return cat
end

local lists_server = { urls = {}, books = {
    { id = 1, title = "Lightning Thief", authors = { "Rick Riordan" }, seriesId = 7, seriesName = "Percy Jackson", seriesIndex = "1", readStatus = "read" },
    { id = 2, title = "Sea of Monsters", authors = { "Rick Riordan" }, seriesId = 7, seriesName = "Percy Jackson", seriesIndex = "2" },
    { id = 3, title = "Skyward", authors = { "Brandon Sanderson" }, seriesName = "Skyward", seriesIndex = "1", readStatus = "reading" },
    { id = 4, title = "Tress", authors = { "Brandon Sanderson" } },
    { id = 5, title = "Akata Witch", authors = { "Nnedi Okorafor" }, seriesId = 9, seriesName = "Nsibidi", seriesIndex = "1" },
} }
local LCat, LApi = fakeCatalogClass(lists_server)
local stock_listRun, stock_fetch = LCat.listRun, LCat.fetch

test("lists: a plugin without a hook -> the feature stays off, the plugin unchanged", function()
    local header = LCat.listHeader
    LCat.listHeader = nil
    package.loaded["bookorbit_catalog"], package.loaded["bookorbit_api"] = LCat, LApi
    newUI(false)
    ok(LCat.listRun == stock_listRun and LCat.fetch == stock_fetch, "nothing wrapped")
    ok(rawget(LCat, "__orbit_stock") == nil, "no marks")
    LCat.listHeader = header
end)

test("lists: By series on a collection reads its books once and opens the plugin's Series view", function()
    newUI(false) -- installs now that every hook is there
    ok(LCat.listRun ~= stock_listRun, "wrapped")
    local cat = newCatalog(LCat, LApi, { kind = "books", title = "Kids shelf", params = { collectionId = 4, readStatus = "unread", sort = "author", page = 2 } })
    local m = cat:listSortSheetModel({})
    ok(m.rows[1].key == "orbit-series" and m.rows[2].key == "orbit-authors" and m.rows[3].key == "device", "rows at the top")
    cat:listRun({ kind = "orbit-group", section = "series" })
    run(1)
    ok(#lists_server.urls == 3, "three pages of two: " .. #lists_server.urls)
    for _, u in ipairs(lists_server.urls) do
        ok(u:find("collectionId=4", 1, true) and u:find("readStatus=unread", 1, true) and u:find("size=100", 1, true), "the list's filters: " .. u)
        ok(not u:find("orbit", 1, true), "no marks sent")
    end
    ok(cat.labels[2] == "Reading 2 of 5 books…", "progress: " .. tostring(cat.labels[2]))
    local ctx = cat.current_context
    ok(ctx.kind == "section" and ctx.section == "series" and ctx.orbit_group, "the Series view, tagged")
    ok(lists_server.sections == nil, "the sections endpoint never asked")
    ok(ctx.total == 3 and #ctx.entries == 2, "a screen of 2 of 3 series")
    ok(ctx.entries[1].title == "Nsibidi" and ctx.buckets[1].key == "N", "A-Z with buckets")
    ok(cat:listHeader("series", ctx).title == "Series in Kids shelf", "header")
    -- Paging (listGoPage -> reloadSection -> loadSection replace) stays in the list.
    cat:loadSection("series", { replace = true, offset = 2 })
    ok(cat.current_context.orbit_group and cat.current_context.entries[1].title == "Skyward", "page 2 from the held books")
    ok(#lists_server.urls == 3, "no new reads")
    -- A row: the server's series page with the collection ANDed in.
    cat:listRun({ kind = "open-series", entry = cat.current_context.entries[1] })
    local p = cat.loaded.params
    ok(p.collectionId == 4 and p.series == "Skyward" and p.readStatus == "unread" and p.ids == nil, "collection + series")
    ok(p.orbitGroup == ctx.orbit_group.token, "marked")
    -- That page's header and its Whole series chip.
    local page = { kind = "books", title = "Skyward", params = p, total = 1, books = { lists_server.books[3] } }
    cat.current_context = page
    ok(cat:listHeader("seriespage", page).sub == "Brandon Sanderson · 1 book in Kids shelf", "sub: " .. tostring(cat:listHeader("seriespage", page).sub))
    local tb = cat:listToolbar("seriespage", page)
    ok(tb[1].key == "tb-sort" and tb[2].key == "orbit-whole-series", "Whole series chip")
    cat:listRun(tb[2].action)
    ok(cat.loaded.params.series == "Skyward" and cat.loaded.params.collectionId == nil and cat.loaded.params.orbitGroup == nil, "the whole series")
    -- Back on the list, By series again: no new reads.
    cat.current_context = { kind = "books", title = "Kids shelf", params = { collectionId = 4 }, orbit_snapshot = ctx.orbit_group.token }
    cat:listRun({ kind = "orbit-group", section = "series" })
    ok(#lists_server.urls == 3 and cat.current_context.orbit_group, "instant the second time")
end)

test("lists: By author on a smart scope; an author by series; Not in a series; the chips", function()
    lists_server.urls = {}
    local cat = newCatalog(LCat, LApi, { kind = "books", title = "Unread fantasy", params = { smartScopeId = 3 } })
    cat:listRun({ kind = "orbit-group", section = "authors" })
    run(1)
    local ctx = cat.current_context
    ok(ctx.section == "authors" and ctx.total == 3, "3 authors")
    ok(cat:listHeader("authors", ctx).title == "Authors in Unread fantasy", "header")
    local bs = ctx.entries[1]
    ok(bs.title == "Brandon Sanderson" and bs.count == 2, "Brandon first A-Z")
    cat:listRun({ kind = "open-author", entry = bs })
    local by = cat.current_context
    ok(by.section == "series" and by.orbit_group.author == "Brandon Sanderson", "the author's books by series")
    ok(cat.pushed == true, "pushed: Back returns to the authors")
    ok(by.total == 2 and by.entries[1].title == "Skyward" and by.entries[2].title == "Not in a series", "series, then Not in a series")
    local h = cat:listHeader("series", by)
    ok(h.title == "Brandon Sanderson" and h.sub == "2 books in Unread fantasy · by series", "header: " .. tostring(h.sub))
    local chips = cat:listToolbar("series", by)
    ok(#chips == 3 and chips[1].on and chips[1].label == "By series" and chips[3].label == "All by author", "chips")
    -- A smart scope's series: by id (the server ignores other filters with smartScopeId).
    cat:listRun({ kind = "open-series", entry = by.entries[1] })
    local p = cat.loaded.params
    ok(p.ids == "3" and p.smartScopeId == nil and p.series == "Skyward" and p.author == "Brandon Sanderson", "ids + series + author")
    cat:listRun({ kind = "open-series", entry = by.entries[2] })
    ok(cat.loaded.params.ids == "4" and cat.loaded.params.series == nil and cat.loaded.title == "Not in a series", "standalones, flat")
    cat:listRun(chips[2].action)
    ok(cat.loaded.params.ids == "3,4" and cat.loaded.push == false, "All books: flat, in place")
    cat:listRun(chips[3].action)
    ok(cat.loaded.params.author == "Brandon Sanderson" and cat.loaded.params.ids == nil and cat.loaded.params.orbitGroup == nil, "All by author: no list filter")
    ok(#lists_server.urls == 3, "read once")
end)

test("lists: a smart-scope series past 200 books comes from the books held here", function()
    lists_server.urls = {}
    local saved = lists_server.books
    lists_server.books = {}
    for i = 1, 201 do lists_server.books[i] = { id = i, title = "Vol " .. i, authors = { "A" }, seriesId = 1, seriesName = "Long", seriesIndex = tostring(i) } end
    local cat = newCatalog(LCat, LApi, { kind = "books", title = "Big", params = { smartScopeId = 5 } })
    cat:listRun({ kind = "orbit-group", section = "series" })
    run(1)
    cat:listRun({ kind = "open-series", entry = cat.current_context.entries[1] })
    local p = cat.loaded.params
    ok(p.orbitLocal == "1" and p.ids == nil, "held")
    local before = #lists_server.urls
    local body = cat.client:catalogBooks({ orbitGroup = p.orbitGroup, orbitLocal = "1", orbitSeries = p.orbitSeries, seriesId = 1, sort = "series", size = 100, page = 3 })
    ok(#lists_server.urls == before, "answered here")
    ok(body.total == 201 and #body.items == 1 and body.items[1].id == 201, "page 3 of the held books")
    cat.client:catalogManifest({ orbitGroup = p.orbitGroup, orbitLocal = "1", orbitSeries = p.orbitSeries })
    ok(lists_server.manifest:find("ids=1,2,3", 1, true) and not lists_server.manifest:find("orbit", 1, true), "Download all goes by id")
    lists_server.books = saved
end)

test("lists: pass-through when nothing is marked", function()
    lists_server.urls = {}
    local cat = newCatalog(LCat, LApi, { kind = "books", title = "All books", params = { sort = "title" } })
    ok(#cat:listSortSheetModel({}).rows == 1, "no list: no rows")
    cat:listRun({ kind = "back" })
    ok(cat.stock_run == "back", "other actions: the plugin's")
    cat.current_context = { kind = "section", section = "series" }
    cat:listRun({ kind = "open-series", entry = { title = "X" } })
    ok(cat.stock_run == "open-series", "the server-wide Series view: the plugin's")
    cat:loadSection("series", { replace = true })
    ok(lists_server.sections == 1 and cat.current_context.orbit_group == nil, "the server answers")
    ok(cat:listHeader("series", cat.current_context).title == "Series", "header unchanged")
    ok(cat:listToolbar("series", cat.current_context)[1].key == "tb-sort", "toolbar unchanged")
    ok(cat.client:query("/books", { sort = "title" }) == "/books?sort=title", "query unchanged")
    cat.client:catalogBooks({ sort = "title", page = 1 })
    ok(#lists_server.urls == 1, "books from the server")
    package.loaded["bookorbit_catalog"], package.loaded["bookorbit_api"] = nil, nil
end)


---------------------------------------------------------------- end of book (ROADMAP 1, 2)
local E = getfenv(Orbit.onSuspend)
local eob = { calls = {} }
local EApi = {}
EApi.__index = EApi
function EApi:catalogBook(id)
    table.insert(eob.calls, "book:" .. id)
    if eob.fail then return nil, eob.fail end
    return eob.details[id]
end
function EApi:catalogSetReadStatus(id, st) table.insert(eob.calls, "status:" .. id .. ":" .. st); return {} end
function EApi:catalogSetRating(id, r) table.insert(eob.calls, "rating:" .. id .. ":" .. tostring(r)); return {} end
local function eobModules()
    package.loaded["bookorbit_api"] = EApi
    package.loaded["bookorbit_state_manager"] = {
        getBook = function(d) return d == "d1" and { bookId = 42 } or nil end,
        mutate = function(fn) fn({ getBook = function(_, h) eob.state = eob.state or { hash = h }; return eob.state end }) end,
        onDeviceMaps = function() return { byBookId = eob.on_device or {} } end,
    }
    package.loaded["bookorbit_sidecar"] = {
        rememberServerState = function(book, st) book.server = st end,
        applyServerStateLive = function(_, st) eob.live = st end,
        applyServerStateSidecar = function(f, st) eob.sidecar = { f, st } end,
    }
end
local function bookUI(summary)
    local ui, m = newUI(true)
    ui.bookorbit.newClient = function() return setmetatable({}, EApi) end
    ui.doc_settings = { data = { summary = summary or { status = "reading" } } }
    function ui.doc_settings:readSetting(k) return self.data[k] end
    function ui.doc_settings:saveSetting(k, v) self.data[k] = v end
    ui.status = setmetatable({ ui = ui, document = ui.document }, W.ReaderStatus)
    return ui, m
end
local function sheetRow(kind, text)
    for _, r in ipairs(E.EOB.sheet and E.EOB.sheet:rows() or {}) do
        if r.kind == kind and (not text or tostring(r.text):find(text, 1, true)) then return r end
    end
end
local series_detail = { id = 42, title = "Sea of Monsters", authors = { "Rick Riordan" }, seriesId = 7,
    seriesName = "Percy Jackson", seriesIndex = 2, readStatus = "reading",
    seriesMembers = { { id = 41, title = "Lightning Thief", seriesIndex = 1, readStatus = "read" },
        { id = 42, title = "Sea of Monsters", seriesIndex = 2, readStatus = "reading" },
        { id = 43, title = "Titan's Curse", seriesIndex = 3 } },
    relatedSections = {} }
eob.details = { [42] = series_detail, [43] = { id = 43, title = "Titan's Curse", files = { { id = 9, format = "epub" } } } }

test("end of book: a plugin without a module -> KOReader's own end screen", function()
    package.loaded["bookorbit_state_manager"] = nil
    local ui = bookUI()
    W.stock_end = 0
    ui.status:onEndOfBook()
    ok(W.stock_end == 1 and E.EOB.sheet == nil, "stock end screen")
    ok(ui.doc_settings.data.summary.status == "reading", "nothing marked")
end)

test("end of book: the last page marks it finished, opens the sheet; Undo takes it back", function()
    eobModules()
    E.EOB.remember(series_detail)
    local ui = bookUI()
    W.stock_end = 0
    ui.status:onEndOfBook()
    ok(W.stock_end == 0, "the Orbit sheet instead of KOReader's")
    ok(ui.doc_settings.data.summary.status == "complete", "marked finished")
    local job = E.EOB.queue()["d1"]
    ok(job and job.book_id == 42 and job.ready == false, "a job, not sent while the book is open")
    ok(sheetRow("status", "Marked as finished") and sheetRow("author", "Rick Riordan"), "status and author")
    ok(sheetRow("label", "Next in series · Book 3"), "next card: " .. tostring((sheetRow("label") or {}).text))
    ok(sheetRow("card", "Titan's Curse"), "download and open the next book")
    sheetRow("status").action()
    ok(ui.doc_settings.data.summary.status == "reading" and E.EOB.queue()["d1"] == nil, "Undo: reading, no job")
    ok(E.EOB.sheet == nil, "sheet closed")
    -- Auto-mark off: the sheet offers the mark instead.
    E.S.eob_auto = false
    ui.status:onEndOfBook()
    ok(ui.doc_settings.data.summary.status == "reading" and sheetRow("status", "Not marked"), "not marked")
    sheetRow("status").action()
    ok(E.EOB.queue()["d1"] and sheetRow("status", "Marked as finished"), "marked from the sheet")
    E.S.eob_auto = true
    sheetRow("status").action()
end)

test("end of book: stars, leave, sync -> guard read, read-status, rating, written back", function()
    eobModules()
    local ui, m = bookUI()
    ui.status:onEndOfBook()
    sheetRow("star", nil) -- first star row
    local stars = {}
    for _, r in ipairs(E.EOB.sheet:rows()) do if r.kind == "star" then table.insert(stars, r) end end
    stars[4].action()
    ok(E.EOB.queue()["d1"].rating == 4 and ui.doc_settings.data.summary.rating == 4, "4 stars kept")
    E.EOB.actions.back()
    eob.calls = {}
    E.Sync.waitOutbox(ui.bookorbit, 10, function() end)
    run(5)
    ok(#eob.calls == 0 or not table.concat(eob.calls, ","):find("status:", 1, true), "nothing sent with the book open")
    m:onCloseWidget()
    ok(E.EOB.queue()["d1"].ready, "ready once the book is left")
    E.Sync.waitOutbox(ui.bookorbit, 10, function() W.waited = true end)
    run(5)
    local c = table.concat(eob.calls, ",")
    ok(c:find("book:42,status:42:read,rating:42:4", 1, true), "in order: " .. c)
    ok(E.EOB.queue()["d1"] == nil and W.waited, "sent, then the caller goes on")
    ok(eob.state and eob.state.server and eob.state.server.status == "complete" and eob.state.server.rating == 4, "written back")
end)

test("end of book: a server error retries later; 404 drops", function()
    eobModules()
    local ui, m = bookUI()
    ui.status:markBook(true)
    m:onCloseWidget()
    eob.fail, eob.calls = 503, {}
    E.EOB.drain(ui.bookorbit, false)
    local job = E.EOB.queue()["d1"]
    ok(job and job.attempts == 1 and job.next_try_at and job.next_try_at > os.time(), "kept with a backoff")
    eob.fail = 404
    E.EOB.drain(ui.bookorbit, true)
    ok(E.EOB.queue()["d1"] == nil, "dropped on 404")
    eob.fail = nil
end)

test("end of book: Download and open, offline -> Couldn't connect, Get it at the next sync", function()
    eobModules()
    local ui = bookUI()
    ui.status:onEndOfBook()
    W.wifi, W.vpn = false, false
    W.companion = false
    sheetRow("card", "Titan's Curse").action()
    run(60)
    ok(sheetRow("notice", "Couldn't connect"), "the card says so")
    sheetRow("button", "Get it at the next sync").action()
    ok(E.EOB.downloads()["43"], "remembered for the next sync")
    W.wifi, W.vpn, W.companion = true, true, true
    E.EOB.wants_download = {}
    E.EOB.save()
end)

test("end of book: Download and open sends the finish first, downloads through the plugin, opens it", function()
    eobModules()
    local DCat = {}
    DCat.__index = DCat
    function DCat:downloadDefaultFile(detail, file) self:checkDownloadFile("/books/titan.epub", detail, file) end
    function DCat:downloadFile(path, detail, file, rep)
        ok(self.client and self.bookMode == false, "headless, the plugin's client")
        table.insert(eob.calls, "download:" .. detail.id)
        rep.progress(512, 1024)
        rep.finished(true, nil, path)
    end
    function DCat:loadBooks() end
    package.loaded["bookorbit_catalog"] = DCat
    local ui = bookUI()
    ui.status:onEndOfBook()
    eob.calls, W.opened = {}, nil
    sheetRow("card", "Titan's Curse").action()
    run(60)
    local c = table.concat(eob.calls, ",")
    ok(c:find("status:42:read", 1, true) and c:find("download:43", 1, true)
        and c:find("status:42:read", 1, true) < c:find("download:43", 1, true), "finish, then download: " .. c)
    ok(W.opened == "/books/titan.epub", "opened: " .. tostring(W.opened))
    ok(E.EOB.sheet == nil, "sheet closed")
    package.loaded["bookorbit_catalog"] = nil
end)

test("end of book: Home from the companion with the sheet open closes it, opens BookOrbit home, sends the finish", function()
    eobModules()
    local ui, m = bookUI()
    ui.status:onEndOfBook()
    ok(E.EOB.sheet and W.shown[#W.shown] == E.EOB.sheet, "sheet on top")
    eob.calls = {}
    m:onSuspend(); W.clock = W.clock + 0.5
    command(m, "home")
    m:onResume()
    run(30)
    ok(E.EOB.sheet == nil, "sheet closed")
    local cb = ui.bookorbit.catalog_browser
    ok(cb and W.shown[#W.shown] == cb, "BookOrbit home on top: " .. tostring(W.shown[#W.shown] and W.shown[#W.shown].name))
    ok(table.concat(eob.calls, ","):find("status:42:read", 1, true), "finish sent: " .. table.concat(eob.calls, ","))
    cb.close_callback()
    W.intent_extras["net.fledgewing.orbitcompanion.extra.COMMAND"] = nil
end)

test("end of book: the sheet's Home opens BookOrbit home (never its menu) and sends the finish", function()
    eobModules()
    local ui, m = bookUI()
    ui.status:onEndOfBook()
    eob.calls = {}
    sheetRow("footer", "Home").action()
    run(30)
    local top = W.shown[#W.shown]
    ok(ui.bookorbit.catalog_browser and top == ui.bookorbit.catalog_browser, "BookOrbit home on top: " .. tostring(top and top.name))
    ok(not has(ui.bookorbit.calls, "menu_sheet"), "no menu sheet")
    local noted = E.LocalState.load().books["d1"]
    ok(noted and noted.pending and noted.status == "complete", "the open book noted for Home's first paint")
    ok(table.concat(eob.calls, ","):find("status:42:read", 1, true), "finish sent: " .. table.concat(eob.calls, ","))
    -- Home again with BookOrbit home already on top: it stays, no menu sheet.
    m:onOrbitGoHome()
    run(5)
    ok(not has(ui.bookorbit.calls, "menu_sheet") and W.shown[#W.shown] == ui.bookorbit.catalog_browser, "still Home, no menu")
    ui.bookorbit.catalog_browser.close_callback()
end)

test("end of book: a finish marked here leaves Continue reading at once (plugin ids as strings)", function()
    eobModules()
    package.loaded["bookorbit_state_manager"].getBook = function(d) return d == "d1" and { bookId = "42" } or nil end
    local ui = bookUI()
    ui.status:onEndOfBook()
    E.EOB.actions.back()
    local body = { continueReading = { { id = 42, title = "Sea of Monsters", readStatus = "reading", progressPercentage = 99 },
        { id = 8, title = "Dare", readStatus = "reading" } }, readingGoal = { goalBooks = 10, completedBooks = 2 } }
    local out = E.LocalFirst.overlay(body, E.LocalState.view())
    ok(#out.continueReading == 1 and out.continueReading[1].id == 8, "dropped from Continue reading")
    ok(out.readingGoal.completedBooks == 3, "counted toward the goal")
    ui.status:markBook(false)
    E.LocalState.data.books["d1"] = nil
end)

test("outbox: an entry backing off (not drainable) neither holds Wi-Fi nor runs the wait to its cap", function()
    local ui = newUI(true)
    local p = ui.bookorbit
    p.getLifecycleOutbox = function() return { diagnostics = function() return { count = 1, blocked = 0, drainable = 0 } end } end
    local done_at
    local t0 = W.clock
    E.Sync.waitOutbox(p, 20, function(okw) done_at = W.clock; W.wait_ok = okw end)
    run(25)
    ok(done_at and done_at - t0 < 2 and W.wait_ok, "done at once, not at the cap: " .. tostring(done_at and done_at - t0))
    local busy = E.Wifi.busy()
    ok(not busy, "Wi-Fi not held for it")
    p.getLifecycleOutbox = function() return { diagnostics = function() return { count = 1, blocked = 0, drainable = 1 } end } end
    ok(E.Wifi.busy(), "a drainable entry still holds Wi-Fi")
end)

test("end of book: a finished book's stale position is held", function()
    eobModules()
    local PCls = {}
    PCls.__index = PCls
    function PCls:enqueueLifecycleSnapshot(snap) eob.snap = snap end
    function PCls:updateProgress() eob.live_push = true end
    local ui, m = bookUI({ status = "complete" })
    setmetatable(ui.bookorbit, PCls)
    E.EOB.installPluginHooks(ui.bookorbit)
    E.EOB.queue()["d1"] = E.Finish.newJob({ hash = "d1", book_id = 42, final_pos = { percentage = 1 }, now = os.time() })
    E.EOB.session["d1"] = { forward = 0 }
    ui.bookorbit:enqueueLifecycleSnapshot({ digest = "d1", percentage = 0.5, progress = "x", status = "complete" }, "close")
    ok(eob.snap and eob.snap.percentage == nil, "position held")
    ui.bookorbit:enqueueLifecycleSnapshot({ digest = "d1", percentage = 0.95, status = "complete" }, "close")
    ok(eob.snap.percentage == 0.95, "near the end: sent")
    E.EOB.queue()["d1"] = nil
end)


---------------------------------------------------------------- local-first Home (ROADMAP 3)
local lf = {}
local function lfModules(drop)
    lf.evicted, lf.scheduled = {}, {}
    local BUI = {}
    function BUI.statusCluster(d) return { kind = "status" } end
    function BUI.hit(w, action) w.action = action; return w end
    function BUI.icon(name) return { icon = name } end
    function BUI.hstack(_, items) return { items = items } end
    local BD = {}
    function BD.build(_, context, now)
        local body = context.dashboard or {}
        lf.built = body
        local cr = {}
        for _, b in ipairs(body.continueReading or {}) do
            local c = {}
            for k, v in pairs(b) do c[k] = v end
            c.cover_state = (lf.covers or {})[b.id] or "loading"
            table.insert(cr, c)
        end
        return { continue_reading = cr, online = true, date_long = "Sunday", now = now }
    end
    local LV = {}
    local function region(w, action) return { region = action, w } end
    function LV.header(w, o)
        local _r = region
        return { sub = o.sub, status = BUI.statusCluster({ clock = o.clock }) }
    end
    local Cat = {}
    Cat.__index = Cat
    local statusCluster = BUI.statusCluster
    function Cat:boardHeader(d) return { date_long = d.date_long, status = statusCluster(d) } end
    function Cat:switchTo(_, items, context) lf.stock_switch = (lf.stock_switch or 0) + 1; self.current_context = context end
    function Cat:refreshOnDevice() end
    function Cat:updateItems() lf.full_paint = (lf.full_paint or 0) + 1 end
    -- As plugin 2.3.0 (bookorbit_catalog.lua:475-490): a refresh evicts the covers on screen.
    function Cat:refreshCurrent()
        lf.refreshed = true
        local ctx = self.current_context or {}
        if ctx.kind == "dashboard" then self:evictCachedCovers(self.dashboardBooks(ctx.dashboard)) end
    end
    function Cat.dashboardBooks(body) return (body or {}).continueReading or {} end
    function Cat:evictCachedCovers(books) for _, b in ipairs(books or {}) do table.insert(lf.evicted, b.id) end end
    function Cat:cancelThumbnailJobs() lf.cancelled = (lf.cancelled or 0) + 1 end
    function Cat:scheduleThumbnailDownloads(books) for _, b in ipairs(books or {}) do table.insert(lf.scheduled, b.id) end end
    function Cat:dashboardRootFetch() return {}, lf.next_context end
    function Cat:boardRun(action) lf.stock_run = action.kind end
    function Cat:boardRefreshTile(entry) table.insert(lf.repainted, entry.item.type) end
    function Cat:boardRefreshClock() lf.header = (lf.header or 0) + 1 end
    function Cat:listRun(action) lf.stock_list = action.kind end
    function Cat:listHeader() return { title = "Books", sub = "12 books" } end
    if drop then Cat[drop] = nil end
    package.loaded["bookorbit_catalog"], package.loaded["bookorbit_board_data"] = Cat, BD
    package.loaded["bookorbit_list_view"], package.loaded["bookorbit_board_ui"] = LV, BUI
    return Cat, BD, LV, BUI
end

test("local-first: a plugin without a hook -> Home stays the plugin's", function()
    local Cat, BD = lfModules("listRun")
    local build = BD.build
    newUI(false)
    ok(not E.LF.installed and BD.build == build and rawget(Cat, "__orbit_stock") == nil, "nothing wrapped")
end)

test("local-first: Home paints this device's state; ⟳ refreshes; a refresh repaints changed tiles only", function()
    local Cat, BD, LV, BUI = lfModules()
    package.loaded["bookorbit_state_manager"] = { getBook = function(d) return d == "d7" and { bookId = 7 } or nil end }
    newUI(false)
    ok(E.LF.installed, "installed")
    -- Finished here, not yet sent: Home shows it finished before the server knows.
    E.LocalState.put("d7", { status = "complete", percent = 100, pending = true })
    local body = { continueReading = { { id = 7, title = "A", progressPercentage = 40 }, { id = 8, title = "B", progressPercentage = 10 } } }
    local cat = setmetatable({ current_context = { kind = "dashboard", dashboard = body } }, Cat)
    local d = BD.build(cat, cat.current_context, os.time())
    ok(lf.built ~= body and lf.built.orbit_overlay, "an overlaid copy")
    ok(#body.continueReading == 2, "the saved body untouched")
    ok(d.orbit_board, "marked for the header")
    -- Header: ⟳ next to the device status, and the stamp.
    E.LocalState.load().fetchedAt.dashboard = os.time() - 120
    local h = cat:boardHeader(d)
    ok(h.status.items and h.status.items[1].action.kind == "orbit-refresh", "⟳ in the header")
    ok(h.date_long:find("Sunday · updated", 1, true), "stamp: " .. tostring(h.date_long))
    cat:boardRun({ kind = "orbit-refresh" })
    ok(lf.refreshed, "⟳ refreshes")
    cat:boardRun({ kind = "menu" })
    ok(lf.stock_run == "menu", "other actions: the plugin's")
    -- List header: ⟳ and its stamp.
    local lh = cat:listHeader("books", { kind = "books", params = {} })
    local lv = LV.header(500, lh)
    ok(lv.status.items and lv.status.items[1].region.kind == "orbit-refresh", "⟳ on lists")
    lf.refreshed = nil
    cat:listRun({ kind = "orbit-refresh" })
    ok(lf.refreshed, "list ⟳ refreshes")
    -- A refresh lands: one tile changed -> only it repaints, plus the header stamp.
    cat._board_ctx = { d = d }
    cat._board_tiles = { { item = { type = "hero" } }, { item = { type = "clock" } }, { item = { type = "shelf", source = "x" } } }
    lf.repainted, lf.stock_switch, lf.header = {}, 0, 0
    local fresh = { continueReading = { { id = 8, title = "B", progressPercentage = 30 } } }
    lf.next_context = { kind = "dashboard", dashboard = fresh }
    local items, ctx = cat:dashboardRootFetch({})
    cat:switchTo("Home", items, ctx, false)
    ok(lf.stock_switch == 0 and lf.header == 1, "no full repaint; header stamped")
    ok(#lf.repainted == 1 and lf.repainted[1] == "hero", "only the hero tile: " .. table.concat(lf.repainted, ","))
    ok(cat.current_context == ctx, "the new body adopted")
    -- A different board (shelf set changed) -> the plugin's full repaint.
    local other = { kind = "dashboard", dashboard = { continueReading = {}, boardShelves = { y = {} } }, orbit_refresh = true }
    cat:switchTo("Home", {}, other, false)
    ok(lf.stock_switch == 1, "full repaint")
    for _, k in ipairs({ "bookorbit_catalog", "bookorbit_board_data", "bookorbit_list_view", "bookorbit_board_ui", "bookorbit_state_manager" }) do
        package.loaded[k] = nil
    end
end)

test("local-first: ⟳ keeps covers; a quiet refresh keeps cover jobs; a late cover redraws its tile", function()
    local Cat, BD = lfModules()
    E.LF.installed = nil -- install again, onto this test's catalog
    newUI(false)
    lf.evicted, lf.scheduled, lf.cancelled, lf.covers, lf.refreshed = {}, {}, 0, {}, nil
    local body = { continueReading = { { id = 7, title = "A", progressPercentage = 40 } } }
    local cat = setmetatable({ current_context = { kind = "dashboard", dashboard = body } }, Cat)
    local d = BD.build(cat, cat.current_context, os.time())
    -- ⟳: the data refreshes, the covers stay (they are keyed by cover version).
    cat:boardRun({ kind = "orbit-refresh" })
    ok(lf.refreshed, "⟳ refreshes")
    ok(#lf.evicted == 0, "no cover deleted: " .. table.concat(lf.evicted, ","))
    -- The plugin's own refresh paths still evict, as before.
    cat:refreshCurrent()
    ok(#lf.evicted == 1, "the plugin's own refresh unchanged")
    lf.evicted = {}
    -- A refresh lands quietly: no cancelled cover jobs, and the new book's cover is fetched.
    cat._board_ctx = { d = d }
    cat._board_tiles = { { item = { type = "hero" } } }
    lf.repainted, lf.stock_switch, lf.header = {}, 0, 0
    lf.next_context = { kind = "dashboard", dashboard = { continueReading = { { id = 7, title = "A", progressPercentage = 40 }, { id = 9, title = "C", progressPercentage = 5 } } } }
    local items, ctx = cat:dashboardRootFetch({})
    cat:switchTo("Home", items, ctx, false)
    ok(lf.stock_switch == 0 and lf.cancelled == 0, "quiet: cover jobs kept")
    ok(table.concat(lf.scheduled, ",") == "7,9", "covers scheduled: " .. table.concat(lf.scheduled, ","))
    -- A cover lands while a hydration repaint skip is pending: its tile still redraws.
    lf.repainted, lf.full_paint = {}, 0
    lf.covers[9] = "ready"
    cat._orbit_skip_repaint = true
    cat:updateItems(nil, true)
    ok(lf.full_paint == 0, "no full repaint")
    ok(#lf.repainted == 1 and lf.repainted[1] == "hero", "the cover's tile redrew: " .. table.concat(lf.repainted, ","))
    for _, k in ipairs({ "bookorbit_catalog", "bookorbit_board_data", "bookorbit_list_view", "bookorbit_board_ui" }) do
        package.loaded[k] = nil
    end
end)

---------------------------------------------------------------- write-through cache
local cache = {}
-- A fake BookOrbit API client class (bookorbit_api.lua:372 request, :261 requestBlocking,
-- :336 runInSubprocess, :747 downloadCatalogThumbnail) over cache.server (path -> body).
local function cacheSetup()
    local dir = os.tmpname(); os.remove(dir); sh("mkdir -p", dir .. "/events"); sh("mkdir -p", dir .. "/covers")
    local lfs = require("libs/libkoreader-lfs")
    cache.lfs_saved = { attributes = lfs.attributes, dir = lfs.dir, touch = lfs.touch }
    lfs.dir = function(d)
        local h = io.popen('ls -1 "' .. d .. '" 2>/dev/null'); local names = {}
        for n in h:lines() do table.insert(names, n) end
        h:close(); local i = 0
        return function() i = i + 1; return names[i] end
    end
    lfs.touch = function() return true end
    lfs.attributes = function(f, k)
        if W.files[f] then return "file" end
        if os.execute('test -d "' .. f .. '"') == 0 or os.execute('test -d "' .. f .. '"') == true then
            return k == "modification" and 1 or "directory"
        end
        local h = io.open(f, "rb"); if h then h:close(); return k == "modification" and 1 or "file" end
        return nil
    end
    cache.dir, cache.server, cache.calls, cache.writes = dir, {}, {}, {}
    local Api = {}
    Api.__index = Api
    function Api:requestBlocking(method, path, body)
        table.insert(cache.calls, method .. " " .. path)
        if method ~= "GET" then table.insert(cache.writes, path); return {} end
        local b = cache.server[path]
        if b == nil then return nil, 404 end
        return E.Cache.copy(b)
    end
    function Api:request(method, path, body, headers) return self:requestBlocking(method, path, body, headers) end
    function Api:runInSubprocess(fn)
        self.subprocess_depth = (self.subprocess_depth or 0) + 1
        local b, e, eb = fn()
        self.subprocess_depth = self.subprocess_depth - 1
        return true, { body = b, err = e, errbody = eb }
    end
    function Api:downloadCatalogThumbnail(id, path) cache.stock_cover = (cache.stock_cover or 0) + 1; return true end
    function Api:getProxy() return nil end
    package.loaded["bookorbit_api"] = Api
    local Cat = lfModules()
    E.LF.installed = nil
    ok(E.LF.install("test"), "local-first on this catalog")
    function Cat:loadDashboardRoot() cache.reloaded = (cache.reloaded or 0) + 1 end
    E.OC.installed, E.OC._dir, E.OC._index = nil, dir, nil
    E.OC.memo, E.OC.memo_order, E.OC.queue, E.OC.inflight, E.OC.pending, E.OC.active = {}, {}, {}, {}, {}, nil
    E.OC.now = function() return math.floor(W.clock) end
    E.S.offline_cache = true
    ok(E.OC.install("test"), "installed")
    local client = setmetatable({ username = "reader", userkey = "k", server_url = "https://books.example" }, Api)
    return client, Cat, Api
end
local function cacheTeardown()
    local lfs = require("libs/libkoreader-lfs")
    for k, v in pairs(cache.lfs_saved) do lfs[k] = v end
    sh("rm -rf", cache.dir)
    for _, k in ipairs({ "bookorbit_api", "bookorbit_catalog", "bookorbit_board_data", "bookorbit_list_view", "bookorbit_board_ui" }) do
        package.loaded[k] = nil
    end
    E.OC.installed = nil
end
local DASH = "/koreader/plugin/catalog/dashboard"

test("cache: a read is answered from the cache at once, checked after 60 s, redrawn when it changed", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    cache.server[DASH] = { continueReading = { { id = 7, title = "A" } } }
    local b = client:request("GET", DASH)
    ok(b and b.continueReading[1].id == 7 and #cache.calls == 1, "first read: the server")
    local cat = setmetatable({ current_context = { kind = "dashboard", dashboard = b }, client = client }, Cat)
    cat:switchTo("Home", {}, cat.current_context, false)
    ok(cat._orbit_view_keys, "the view knows its keys")
    package.loaded["bookorbit_catalog"] = Cat
    cache.calls = {}
    b = client:request("GET", DASH)
    ok(b.continueReading[1].id == 7 and #cache.calls == 0, "again within 60 s: the cache, no request")
    -- Later: served at once, checked in the background; the server changed -> Home redraws.
    W.clock = W.clock + 61
    cache.server[DASH] = { continueReading = { { id = 8, title = "B" } } }
    E.OC.client = function() return client end
    local hosts = E.bookorbit
    E.bookorbit = function() return { catalog_browser = cat } end
    b = client:request("GET", DASH)
    ok(b.continueReading[1].id == 7 and #cache.calls == 0, "served at once from the cache")
    run(5)
    ok(#cache.calls == 1, "one background check: " .. table.concat(cache.calls, ","))
    ok(cache.reloaded == 1, "Home reloaded from the cache")
    cache.calls = {}
    b = client:request("GET", DASH)
    ok(b.continueReading[1].id == 8 and #cache.calls == 0, "the new body, from the cache")
    -- Unchanged on the next check: no redraw.
    W.clock = W.clock + 61
    client:request("GET", DASH); run(5)
    ok(cache.reloaded == 1, "unchanged: no redraw")
    -- Offline: the cache, no request.
    W.wifi, cache.calls = false, {}
    W.clock = W.clock + 600
    b = client:request("GET", DASH); run(5)
    ok(b.continueReading[1].id == 8 and #cache.calls == 0, "offline: the cache")
    E.bookorbit = hosts
    cacheTeardown()
end)

test("cache: Refresh checks now; Full refresh goes to the server; neither evicts covers", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    cache.server[DASH] = { continueReading = { { id = 7 } } }
    client:request("GET", DASH)
    local cat = setmetatable({ current_context = { kind = "dashboard", dashboard = cache.server[DASH] }, client = client }, Cat)
    function cat:refreshCurrent()
        self:evictCachedCovers(self.dashboardBooks(self.current_context.dashboard))
        self.client:request("GET", DASH)
    end
    lf.evicted, cache.calls = {}, {}
    E.OC.refresh(cat)
    ok(#cache.calls == 0, "Refresh: answered from the cache")
    run(5)
    ok(#cache.calls == 1 and #lf.evicted == 0, "...and checked at once, no cover evicted")
    cache.calls = {}
    E.OC.fullRefresh(cat)
    ok(#cache.calls == 1 and cache.calls[1] == "GET " .. DASH, "Full refresh: from the server")
    ok(#lf.evicted == 0, "no cover evicted")
    -- Hold ⟳ on a list = Full refresh; a broken cover file on screen is removed for re-download.
    local bad = cache.dir .. "/covers/7_1.jpg"
    local good = cache.dir .. "/covers/8_1.jpg"
    local fh = io.open(bad, "wb"); fh:write("<html>oops</html>"); fh:close()
    fh = io.open(good, "wb"); fh:write("\255\216\255\224jpeg"); fh:close()
    cat.current_context = { kind = "books", books = { { id = 7, hasCover = true }, { id = 8, hasCover = true } } }
    function cat:thumbnailPath(b) return cache.dir .. "/covers/" .. b.id .. "_1.jpg" end
    function cat:invalidateThumbnail(b) cache.invalidated = b.id end
    cache.calls = {}
    cat:listRun({ kind = "orbit-refresh" }, nil, true)
    ok(not io.open(bad) and io.open(good) and cache.invalidated == 7, "broken cover removed, good one kept")
    ok(#cache.calls == 1, "Full refresh from a list: from the server")
    cacheTeardown()
end)

test("cache: a write patches the cached book and marks Home stale; accounts never mix", function()
    local client = cacheSetup()
    W.wifi = true
    local DET = "/koreader/plugin/catalog/books/7"
    cache.server[DET] = { id = 7, readStatus = "reading", seriesMembers = { { id = 6, readStatus = "read" } } }
    cache.server[DASH] = { continueReading = { { id = 7, readStatus = "reading" } } }
    client:request("GET", DET); client:request("GET", DASH)
    client:request("PUT", "/koreader/plugin/catalog/books/7/read-status", { status = "read" })
    cache.calls = {}
    local d = client:request("GET", DET)
    ok(d.readStatus == "read" and #cache.calls == 0, "detail patched, from the cache")
    local h = client:request("GET", DASH)
    ok(h.continueReading[1].readStatus == "read", "Home patched")
    run(5)
    ok(#cache.calls == 1 and cache.calls[1] == "GET " .. DASH, "Home stale: checked")
    -- Another account on the same server: nothing of the first is served.
    local other = setmetatable({ username = "kid", userkey = "k2", server_url = "https://books.example" }, getmetatable(client))
    cache.calls = {}
    other:request("GET", DET)
    ok(#cache.calls == 1, "another account: the server")
    cacheTeardown()
end)

test("cache: a read made in the catalog's child process is stored and adopted by the parent", function()
    local client = cacheSetup()
    W.wifi = true
    cache.server[DASH] = { continueReading = { { id = 9 } } }
    local done, r = client:runInSubprocess(function() return client:request("GET", DASH) end)
    ok(done and r.body.continueReading[1].id == 9, "the child's answer")
    ok(E.OC.index().entries[next(E.OC.index().entries)] ~= nil, "the parent's index has it")
    E.OC.memo, E.OC.memo_order = {}, {}
    cache.calls = {}
    local b = client:request("GET", DASH)
    ok(b.continueReading[1].id == 9 and #cache.calls == 0, "then served from the cache")
    cacheTeardown()
end)

test("cache: covers keep their ETag; a moved version asks If-None-Match and a 304 renames the file", function()
    local client = cacheSetup()
    local http = require("socket.http")
    local stock_http = http.request
    local sent = {}
    local server_etag, cover = '"100"', "\255\216\255\224" .. string.rep("x", 60)
    http.request = function(t)
        local inm = t.headers and t.headers["If-None-Match"]
        table.insert(sent, inm or "-")
        if inm == server_etag then return 1, 304, {} end
        t.sink(cover); t.sink(nil)
        return 1, 200, { ["content-type"] = "image/jpeg", etag = server_etag, ["content-length"] = tostring(#cover) }
    end
    local ltn = require("ltn12")
    local stock_file = ltn.sink.file
    ltn.sink.file = function(f) return function(chunk) if chunk then f:write(chunk) end return 1 end end
    local dir = cache.dir .. "/covers"
    local v1 = dir .. "/7_20261101.jpg"
    ok(client:downloadCatalogThumbnail(7, v1, { temp_path = v1 .. ".part", max_bytes = 4e6 }), "first download")
    local f = io.open(v1 .. ".etag"); ok(f and f:read("*a") == server_etag, "ETag kept"); if f then f:close() end
    -- A metadata edit moved updatedAt: one 304, the file renamed, no body transferred.
    local v2 = dir .. "/7_20261121.jpg"
    ok(client:downloadCatalogThumbnail(7, v2, { temp_path = v2 .. ".part", max_bytes = 4e6 }), "304")
    ok(sent[2] == server_etag, "asked If-None-Match")
    ok(io.open(v2) and not io.open(v1), "the file renamed to the new version")
    -- The cover really changed: replaced, the old one gone, the new ETag kept.
    server_etag, cover = '"200"', "\137PNG\r\n\26\n" .. string.rep("y", 40)
    local v3 = dir .. "/7_20261122.jpg"
    ok(client:downloadCatalogThumbnail(7, v3, { temp_path = v3 .. ".part", max_bytes = 4e6 }), "200")
    ok(io.open(v3) and not io.open(v2), "replaced")
    f = io.open(v3 .. ".etag"); ok(f and f:read("*a") == '"200"', "new ETag"); if f then f:close() end
    ok(cache.stock_cover == nil, "never the plugin's download")
    -- Orphaned ETags are cleaned.
    io.open(dir .. "/9_1.jpg.etag", "w"):close()
    ok(E.OC.cleanEtags(dir) == 1, "orphan ETag removed")
    http.request, ltn.sink.file = stock_http, stock_file
    cacheTeardown()
end)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
    for _, l in ipairs(W.logs) do print(l) end
    os.exit(1)
end

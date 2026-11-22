-- Loads the whole patch against small stand-ins for KOReader, the JNI bridge and the
-- BookOrbit plugin, then drives the flows on a fake clock. It catches wiring mistakes
-- (typos, nil calls, wrong order) that the pure tests can't; it proves nothing about
-- the device. Needs LuaJIT (the patch uses ffi): luajit koreader-patch/test/test_flows.lua
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
ORBIT_ANDROID_SELF_PATH = SELF .. ".lua"

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

local function run(limit)
    limit = limit or 120
    local stop = W.clock + limit
    while #W.queue > 0 do
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
    },
    -- KOReader's Android input module: waitForEvent returns what the test queues (default: EINTR).
    ["ffi/input_android"] = { waitForEvent = function() return false, 4 end },
    ["libs/libkoreader-lfs"] = { attributes = function(f, k) return W.files[f] and "file" or nil end },
    json = { decode = function(s) if W.json[s] then return W.json[s] end return { version = "1" } end },
    -- Stand-in hash: "sha:<length>" padded, enough to check the wiring (the real one is ffi/sha2).
    ["ffi/sha2"] = { sha256 = function(s) return W.fake_sha(s) end },
}
for k, v in pairs(preload) do package.preload[k] = function() return v end end

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
        if p.catalog_browser then return true end
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

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1 else
        failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err))
        if os.getenv("ORBIT_TEST_LOGS") then
            for i = math.max(1, #W.logs - 25), #W.logs do print("   | " .. W.logs[i]) end
        end
    end
end
local function ok(v, what) if not v then error(what or "expected true", 2) end end

---------------------------------------------------------------- load
-- The previous KOReader process was killed with this book open (Smart Home cold start).
store.orbit_android = store.orbit_android or {}
store.orbit_android.open_book_at_exit = "/books/killed.epub"
dofile(here .. "/../2-orbit-android.lua")
local plugins = PluginLoader:loadPlugins()
local Orbit = plugins[#plugins]

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

test("module is appended after the plugins, hidden from the plugin manager", function()
    ok(Orbit.name == "orbitandroid", "name")
    ok(#PluginLoader:genPluginManagerSubItem() == 1, "plugin manager list")
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
    UIManager.quit = nil
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
local API = "https://api.github.com/repos/Fledgewing/BookOrbit-Android/releases/latest"
local LUA_URL, SUMS_URL = "https://dl.test/2-orbit-android.lua", "https://dl.test/SHA256SUMS"
local NEW = '-- new\nlocal PATCH_VERSION = "0.2.0"\nreturn\n'
local function serveRelease(sha)
    W.web = { [API] = "LATEST", [LUA_URL] = NEW, [SUMS_URL] = (sha or W.fake_sha(NEW)) .. "  2-orbit-android.lua\n" }
    W.json = { LATEST = { tag_name = "v0.2.0", assets = {
        { name = "2-orbit-android.lua", browser_download_url = LUA_URL },
        { name = "SHA256SUMS", browser_download_url = SUMS_URL },
    } } }
end
local function selfText()
    local f = io.open(ORBIT_ANDROID_SELF_PATH, "rb")
    if not f then return nil end
    local t = f:read("*a"); f:close(); return t
end
local function resetSelf()
    local f = io.open(ORBIT_ANDROID_SELF_PATH, "wb"); f:write("-- old\n"); f:close()
end

test("update: menu check installs a verified newer patch over its own file", function()
    resetSelf(); serveRelease()
    local _ui, orbit = newUI(false)
    orbit:checkPatchUpdate()
    run(5)
    ok(selfText() == NEW, "file replaced")
    ok(io.open(ORBIT_ANDROID_SELF_PATH .. ".new") == nil, "temp file gone")
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
os.remove(ORBIT_ANDROID_SELF_PATH)
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

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
    for _, l in ipairs(W.logs) do print(l) end
    os.exit(1)
end

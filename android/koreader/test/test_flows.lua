-- Loads the whole patch against small stand-ins for KOReader, the JNI bridge and the
-- BookOrbit plugin, then drives the flows on a fake clock. It catches wiring mistakes
-- (typos, nil calls, wrong order) that the pure tests can't; it proves nothing about
-- the device. Needs LuaJIT (the patch uses ffi): luajit android/koreader/test/test_flows.lua
local here = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
-- KOReader's SQLite binding on the host (the offline cache's database: ko/db.lua, ko/store.lua).
dofile(here .. "/sqlite_shim.lua")

---------------------------------------------------------------- fake world
local W = {
    clock = 1000, queue = {}, seq = 0, shown = {}, logs = {},
    wifi = true, vpn = true, screen_on = false, companion = true, server_code = 200,
    broadcasts = {}, activities = {}, intent_extras = {},
    fetched = {}, web = {}, json = {}, files = {}, children = {}, ino = {},
}
function W.fake_sha(s) return string.format("%064x", #s) end
-- The companion's status call (Companion.status): W.web[STATUS_KEY] is its JSON's W.json key.
local STATUS_KEY = "companion:STATUS"
-- The installed companion's certificate (BigInteger hex, as Jni.packageSigners reads it):
-- Orbify's release key unless a test sets another.
local RELEASE_CERT = "f5078c85f8231830c1f18d93fe30d71f87936c1d9424f2d815983d1d21a90a15"
W.companion_cert = RELEASE_CERT
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
    NewObject = function(_, cls, _, a, b)
        if cls.name == "android/os/Bundle" then return { kind = "bundle", extras = {} } end
        if cls.name == "java/math/BigInteger" then return { kind = "big", of = b } end
        return { kind = "intent", action = a.str, extras = {} }
    end,
    CallStaticObjectMethod = function(_, _, m, a)
        if m == "parse" then return { uri = a.str } end
        if m == "getInstance" then return { digest = true } end
    end,
    GetFieldID = function(_, _, name) return name end,
    GetObjectField = function(_, obj, f)
        if f == "signingInfo" then return { signing = obj.pkginfo } end
        if f == "signatures" then return { { sig = obj.pkginfo } } end
    end,
    GetArrayLength = function(_, arr) return #arr end,
    GetObjectArrayElement = function(_, arr, i) return arr[i + 1] end,
    CallObjectMethod = function(_, obj, m, a, b, c, d)
        if m == "call" then return W.companionCall(b.str, d.extras) end
        if obj.kind == "bundle" and m == "getString" then
            local v = obj.extras[a.str]
            return v and { str = v } or nil
        end
        if m == "getPackageInfo" then
            if a.str == "net.fledgewing.orbitcompanion" and W.companion then return { pkginfo = a.str } end
            W.exception = true
            return nil
        end
        if m == "getSigningCertificateHistory" or m == "getApkContentsSigners" then return { { sig = obj.signing } } end
        if m == "toByteArray" or m == "digest" then return { cert = true } end
        if obj.kind == "big" and m == "toString" then return { str = W.companion_cert } end
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
    CallVoidMethod = function(_, obj, m, a, b)
        if m == "putString" then obj.extras[a.str] = b.str
        elseif m == "sendBroadcast" then W.deliver(a)
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

-- What reaches the companion: W.broadcasts (the commands, as { action, package, extras }) and
-- the fake companion (W.on_broadcast).
function W.deliver(a)
    a.at = W.clock; table.insert(W.broadcasts, a)
    if W.on_broadcast then W.on_broadcast(a) end
    -- Optionally play the companion: switch the fake radio.
    if W.simulate_companion and a.action:match("%.WIFI_OFF$") then
        if a.extras.auto ~= "1" or W.owner ~= "manual" then W.radio, W.wifi = false, false end
    elseif W.simulate_companion and a.action:match("%.NET_UP$") then
        if not W.radio then W.owner = a.extras.owner end
        W.radio, W.wifi = true, true
    end
end

-- ContentResolver.call to the companion (Jni.call): the status, or a command.
function W.companionCall(method, extras)
    local function answer(t) return { kind = "bundle", extras = t } end
    if method:match("%.call%.STATUS$") then
        W.last_status = extras
        local body = W.web[STATUS_KEY]
        if body == nil then return answer({ ok = "0", why = "no service" }) end
        return answer({ ok = "1", status = body })
    end
    -- A command on KOReader's start: the companion sent it, unless a test says another app did.
    if method:match("%.call%.TAKE_COMMAND$") then
        W.confirm_asked = extras.command
        return answer({ ok = W.command_not_sent and "0" or "1" })
    end
    if method:match("%.call%.CLICKS$") then return answer({ ok = "1", key = "k1", proof = "p1" }) end
    W.deliver({ kind = "call", action = method, package = "net.fledgewing.orbitcompanion", extras = extras })
    return answer({ ok = "1" })
end
local jni = { env = env, to_string = function(_, j) return j.str end,
    context = function(self, _, fn) return fn(self) end }

-- On Android isConnected is JNI (device/android/device.lua:333 android.getNetworkInfo): a forked
-- child that calls it dies and the plugin gets subprocess_no_result. W.in_child marks a child.
local NetworkMgr = { isConnected = function()
    if W.in_child then error("JNI from a forked child: NetworkMgr:isConnected", 2) end
    return W.wifi
end }
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
            child.run = function()
                W.in_child = true
                local okc, e = pcall(fn, #W.children, child)
                W.in_child = nil
                child.done = true
                if not okc then child.crashed = tostring(e) end
            end
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
    ["libs/libkoreader-lfs"] = { attributes = function(f, k)
        -- An inode for a real file (the SQLite database): W.ino[path] when a test replaces the file.
        if k == "ino" then
            local h = io.open(f, "rb")
            if not h then return nil end
            h:close()
            return W.ino[f] or 1
        end
        return W.files[f] and "file" or nil
    end,
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
    function p:isLoggedIn() return not p.signed_out end
    function p:promptLogin() rec("promptLogin") end
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
    function p:onBookOrbitToggleAutoSync(v) rec("toggle:" .. tostring(v)); p.settings.auto_sync = v end
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
-- Every row of the Orbit menu, submenus included (the menu is grouped by section).
local function menuAll(items, out)
    out = out or {}
    for _, it in ipairs(items) do
        table.insert(out, it)
        if type(it.sub_item_table) == "table" then menuAll(it.sub_item_table, out) end
    end
    return out
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
    if os.getenv("ORBIT_TEST_ONLY") and not name:find(os.getenv("ORBIT_TEST_ONLY"), 1, true) then return end
    local t0 = W.wall()
    local ok, err = withLimit(name, fn)
    if os.getenv("ORBIT_TEST_TIMES") then print(string.format("%6.2f  %s", W.wall() - t0, name)) end
    -- A failed test still undoes its setup (a cache test left open would hang the next one).
    if W.after_fail then local undo = W.after_fail; W.after_fail = nil; if not ok then pcall(undo) end end
    if ok then passed = passed + 1 else
        failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err))
        if os.getenv("ORBIT_TEST_LOGS") then
            for i = math.max(1, #W.logs - 25), #W.logs do print("   | " .. W.logs[i]) end
        end
    end
end
local function ok(v, what) if not v then error(what or "expected true", 2) end end
local function eq(a, b, what) if a ~= b then error((what or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end end

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
-- The flows below test Custom sync (Sync while reading, sync on wake / sleep as set); OrbiSmart's
-- own flows switch it on (the "orbismart:" tests at the end).
store.orbit_android.sync_mode = "custom"
local PLUGIN_MAIN = here .. "/../orbit.koplugin/main.lua"
local Orbit = dofile(PLUGIN_MAIN)
-- The companion's status file. A real companion always writes one with its mode and caps;
-- the fake's is a Full-mode companion with every cap unless a test says otherwise.
local CAPS_FILE = os.tmpname()
local ADDON = { "install", "setup", "stats", "relaunch" }
local FULL = { "install", "setup", "stats", "relaunch", "home", "apps", "wifi", "sleep_sync", "screen_off", "clicker", "pin" }
local function capsFile(mode, caps)
    local f = io.open(CAPS_FILE, "wb")
    if mode then f:write("CAPSFILE"); W.json.CAPSFILE = { proto = "1", mode = mode, caps = caps } end
    f:close()
end
do
    local CO = getfenv(Orbit.onSuspend).Companion
    CO.statusFile = function() return CAPS_FILE end
    capsFile("full", FULL)
end
-- Back to the default companion; empty = true leaves no status file (a test sets its own).
local function capsReset(empty)
    local E = getfenv(Orbit.onSuspend)
    if empty then capsFile(nil) else capsFile("full", FULL) end
    W.web[STATUS_KEY], W.json.STATUS = nil, nil
    store.orbit_android.companion_caps, store.orbit_android.companion_mode = nil, nil
    E.Companion.cap_set, E.Companion.caps_known = nil, nil
    E.installed_cache.at = -1000
    W.companion = true
end

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
    ok(#sub >= 9, "items " .. #sub)
    local titles = {}
    for _, it in ipairs(sub) do if it.text then titles[it.text] = true end end
    for _, t in ipairs({ "Reading and Home", "Sync and Wi-Fi", "Library and storage", "Updates and details" }) do
        ok(titles[t], "section " .. t)
    end
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
    local url = STATUS_KEY
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
    local url = STATUS_KEY
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

test("a command on KOReader's start that Orbit Companion didn't send is ignored", function()
    W.broadcasts = {}
    local ui, m = newUI(true)
    run(5)
    local quit
    UIManager.quit = function(_, code) quit = code or 0 end
    W.command_not_sent = true
    W.intent_extras["net.fledgewing.orbitcompanion.extra.COMMAND"] = "restart"
    ok(m:checkCommand("resume") == false, "not handled")
    ok(W.confirm_asked == "restart", "the companion was asked")
    ok(W.intent_extras["net.fledgewing.orbitcompanion.extra.COMMAND"] == nil, "the extra is used up")
    run(3)
    ok(quit == nil and not lastBroadcast(".RELAUNCH"), "no restart")
    ok(table.concat(W.logs, "\n"):find("command ignored: restart", 1, true), "logged")
    W.command_not_sent = nil
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

local RE = getfenv(Orbit.onSuspend)

---------------------------------------------------------------- the companion's signer (security.md)
test("companion: an app with its name and another signer gets nothing, the login above all", function()
    W.companion_cert = "1234abcd"
    RE.installed_cache.at = -1000
    W.broadcasts = {}
    ok(RE.Companion.state() == "untrusted", "untrusted: " .. tostring(RE.Companion.state()))
    ok(not RE.Companion.send(RE.Companion.ACTION.CHECK, { server = "https://books.example", user = "u", userkey = "k" }), "not sent")
    ok(#W.broadcasts == 0, "nothing reached it")
    ok(RE.Companion.status() == nil, "no status asked")
    ok(RE.Companion.workerProblem() ~= nil, "nothing heavy runs")
    ok(tostring(RE.Companion.problem()):find("not an Orbify release", 1, true), "the menus' problem line")
    W.companion_cert = RELEASE_CERT
    RE.installed_cache.at = -1000
    ok(RE.Companion.state() == "ok", "the release-signed one is used")
    ok(RE.Companion.send(RE.Companion.ACTION.SETUP_LATER, {}), "sent")
    ok(W.broadcasts[#W.broadcasts].kind == "call", "through the caller-checked call, not a broadcast")
    -- Replacing the app must not inherit a recent menu/status check's cached trust.
    W.companion_cert = "1234abcd"
    W.broadcasts = {}
    ok(not RE.Companion.send(RE.Companion.ACTION.CHECK, { userkey = "k" }), "cached trust cannot send a credential")
    eq(#W.broadcasts, 0, "the replacement receives nothing")
    W.companion_cert = RELEASE_CERT
    RE.installed_cache.at = -1000
end)

test("companion: certificate fingerprints read as release.yml prints them", function()
    ok(RE.Companion.fingerprint("abc") == string.rep("00:", 30) .. "0A:BC", RE.Companion.fingerprint("abc"))
    ok(RE.Companion.signedByUs({ RE.Companion.fingerprint(RELEASE_CERT) }), "the release key")
    ok(not RE.Companion.signedByUs({ RE.Companion.fingerprint(RELEASE_CERT), "AA" }), "every signer must be ours")
    ok(not RE.Companion.signedByUs({}) and not RE.Companion.signedByUs(nil), "none read")
end)

-- Settings defaults have one source, shared/settings/schema.json: the plugin's are the schema's
-- (SettingsStoreTest checks the companion's), except where the device decides (DEVICE_DEFAULTS).
test("settings defaults: every shared setting starts at the schema's default", function()
    local SS = RE.SettingsSync
    ok(#RE.SCHEMA.settings >= 30, "the schema loaded: " .. #RE.SCHEMA.settings)
    for _, d in ipairs(RE.SCHEMA.settings) do
        if RE.DEVICE_DEFAULTS[d.key] then
            eq(RE.DEFAULTS[d.key], nil, d.key .. ": the device decides")
        else
            ok(RE.DEFAULTS[d.key] ~= nil, d.key .. " has a default")
            eq(SS.toWire(d, RE.DEFAULTS[d.key]), SS.toWire(d, nil), d.key)
        end
    end
    eq(RE.Shared.defaultMode(), RE.Companion.has("wifi") and "jit" or "always_on", "wifi_mode: jit where the companion switches Wi-Fi")
    eq(RE.SCHEMA.byKey.wifi_mode.default, "jit", "the schema's wifi_mode")
end)

---------------------------------------------------------------- the contract (shared/contract/companion.json)
-- The plugin's side; the companion's is ContractTest.kt. Every entry is the plugin's own and used.
test("contract: every command, call, page, launch command, status key, file and the database", function()
    local C = dofile(here .. "/json_mini.lua").fixture(here, "../contract/companion.json")
    local src = {}
    local p = io.popen("find '" .. here .. "/../orbit.koplugin' -name '*.lua'")
    for f in p:lines() do local h = io.open(f, "rb"); src[#src + 1] = h:read("*a"); h:close() end
    p:close()
    src = table.concat(src, "\n")
    local function count(pat) local n = 0; for _ in src:gmatch(pat) do n = n + 1 end; return n end
    local function esc(x) return (x:gsub("%p", "%%%0")) end
    local CO = RE.Companion
    eq(C.version, 1)
    eq(CO.PACKAGE, C.package); eq(CO.AUTHORITY, C.authority)
    -- Companion.ACTION is exactly the commands and the pages.
    local want = {}
    for _, c in ipairs(C.commands) do want[c.name] = c.method end
    for _, a in ipairs(C.activities) do want[a.name] = a.action end
    for k, v in pairs(want) do eq(CO.ACTION[k], v, "Companion.ACTION." .. k) end
    for k in pairs(CO.ACTION) do ok(want[k], "Companion.ACTION." .. k .. " is in the contract") end
    -- Each is used (beyond its definition), and each extra is set somewhere.
    for k in pairs(want) do ok(count("Companion%.ACTION%." .. k .. "%f[^%w_]") >= 1, k .. " is sent or opened") end
    for _, c in ipairs(C.commands) do
        for _, e in ipairs(c.extras) do
            ok(src:find("%f[%w_]" .. esc(e) .. "%s*=") or src:find("%." .. esc(e) .. "%f[^%w_]") or src:find('%["' .. esc(e) .. '"%]'), c.name .. " extra " .. e)
        end
    end
    for _, e in ipairs(C.common_extras) do ok(src:find("extras%." .. esc(e) .. "%s*="), "every call carries " .. e) end
    -- The calls the plugin makes, and what their answers may carry.
    for _, c in ipairs(C.calls) do
        if c.caller == "koreader" then eq(CO[c.name], c.method, "Companion." .. c.name) end
    end
    eq(table.concat(RE.CALL_ANSWER, ","), table.concat(C.answer, ","), "CALL_ANSWER")
    -- KOReader's start: the extras and every command the plugin obeys, nothing more.
    eq(CO.EXTRA_COMMAND, C.koreader_start.extras.COMMAND); eq(CO.EXTRA_FROM, C.koreader_start.extras.FROM)
    eq(CO.EXTRA_ROTATION, C.koreader_start.extras.ROTATION)
    local h = io.open(here .. "/../orbit.koplugin/ko/home.lua", "rb"); local home = h:read("*a"); h:close()
    local obeyed = {}
    for cmd in home:gmatch('cmd == "([%w_]+)"') do obeyed[cmd] = true end
    local listed = {}
    for _, cmd in ipairs(C.koreader_start.commands) do listed[cmd] = true; ok(obeyed[cmd], "checkCommand obeys " .. cmd) end
    for cmd in pairs(obeyed) do ok(listed[cmd], cmd .. " is in the contract") end
    -- The click channel, the status keys, the shared files, the database.
    ok(src:find("connect%(\"127%.0%.0%.1\", " .. C.loopback.port .. "%)"), "the click channel's port")
    for _, l in ipairs(C.loopback.lines) do ok(src:find('"%^' .. l), "the channel line " .. l) end
    for _, k in ipairs(C.status) do ok(src:find("%." .. k .. "%f[^%w_]"), "status key " .. k .. " is read") end
    for _, f in ipairs(C.files) do
        local name = f.path:gsub("/$", ""):match("[^/]+$")
        ok(src:find(esc(name), 1), "file " .. name)
    end
    eq(RE.Store.VERSION, C.db.user_version, "orbit.db user_version")
    eq(RE.Store.FILE, C.db.file:match("[^/]+$"))
    local schema = assert(io.open(here .. "/../../../" .. C.db.schema, "rb"))
    local tables = {}
    for name in schema:read("*a"):gmatch("CREATE TABLE ([%w_]+)") do tables[#tables + 1] = name end
    schema:close()
    eq(table.concat(tables, ","), table.concat(C.db.tables, ","), "every orbit.db table")
end)

---------------------------------------------------------------- recommended settings (addon-mode §5)
local BO_DEFAULTS = { auto_sync = false, sync_forward = 1, sync_backward = 3, catalog_auto_open = "off" }
-- A KOReader with nothing changed: the plugin and gestures at their stock defaults.
local function recWorld(in_book)
    local ui, m = newUI(in_book)
    local p = ui.bookorbit
    p.default_settings = BO_DEFAULTS
    p.settings.auto_sync, p.settings.sync_forward, p.settings.catalog_auto_open = false, 1, "off"
    ui.gestures.default_settings = { data = { gesture_reader = { two_finger_swipe_north = { increase_frontlight = 0 },
        tap_top_left_corner = { toggle_page_flipping = true } } } }
    ui.gestures.data.gesture_reader = { two_finger_swipe_north = { increase_frontlight = 0 } }
    store.orbit_android.recommended, store.orbit_android.recommended_backup = nil, nil
    store.wifi_enable_action = nil
    RE.Rec.session_applied, RE.Rec.line_pending = 0, false
    RE.installed_cache.at = -1000
    W.shown = {}
    return ui, m, p
end
local function shownText(pat)
    for _, w in ipairs(W.shown) do if w.text and tostring(w.text):find(pat, 1, true) then return w end end
end
local function menuRow(menu, label)
    for _, it in ipairs(menu.item_table) do if it.text == label then return it end end
end
local function pressDialog(label)
    for i = #W.shown, 1, -1 do
        local w = W.shown[i]
        if w.buttons then
            for _, b in ipairs(w.buttons[1]) do if b.text == label then b.callback(); return true end end
        end
    end
    error("no dialog button " .. label)
end

test("recommended: a fresh KOReader at first start: every item applied with a backup, one line off-book", function()
    local ui, m, p = recWorld(false)
    m:recommendedPass("start")
    ok(p.settings.auto_sync == true, "auto-sync through the plugin's toggle")
    ok(p.settings.sync_forward == 2, "Silent")
    ok(p.settings.catalog_auto_open == "home", "Make BookOrbit home")
    ok(store.wifi_enable_action == "turn_on", "KOReader turns Wi-Fi on")
    local g = ui.gestures.data.gesture_reader
    ok(g.hold_top_right_corner.orbit_sync_and_sleep and g.hold_top_left_corner.bookorbit_sync_now
        and g.one_finger_swipe_bottom_edge_right.bookorbit_this_book and g.two_finger_swipe_north.orbit_open_apps, "gestures")
    ok(ui.gestures.flushed, "gestures flushed")
    local b = store.orbit_android.recommended_backup
    ok(b["g.apps"].had and b["g.apps"].prior.increase_frontlight == 0, "backup of the frontlight gesture")
    ok(b["ko.wifi_on"] and not b["ko.wifi_on"].had, "backup: Wi-Fi action was unset")
    ok(shownText("Applied 8 recommended settings · Review"), "the line")
    ok(m:recommendedMenuText() == "Recommended settings: Applied 8 recommended settings · Review", m:recommendedMenuText())
    -- A second start: nothing new, silent, and a value changed by hand since stays.
    p.settings.sync_forward = 3
    W.shown = {}
    m:recommendedPass("start")
    ok(p.settings.sync_forward == 3, "never changed back")
    ok(#W.shown == 0, "silent")
    -- The review page clears the line.
    local menu = m:showRecommended("test")
    ok(menuRow(menu, "Applied"), "Applied section")
    ok(m:recommendedMenuText() == "Recommended settings", "line cleared once seen")
    run(1)
end)

test("recommended: a customised KOReader keeps every changed value; review offers Use Orbit's / Keep mine", function()
    local ui, m, p = recWorld(false)
    p.settings.sync_forward = 3
    ui.gestures.data.gesture_reader.hold_top_left_corner = { toc = true }
    m:recommendedPass("start")
    ok(p.settings.sync_forward == 3, "the user's value stays")
    ok(ui.gestures.data.gesture_reader.hold_top_left_corner.toc, "the user's gesture stays")
    ok(p.settings.auto_sync == true, "at-default items still applied")
    ok(shownText("Applied 6 · 2 to review"), "the line counts both")
    local menu = m:showRecommended("test")
    local row = menuRow(menu, "BookOrbit › When BookOrbit is further ahead")
    ok(row and row.mandatory == "yours: Don't sync · Orbit's: Silent", row and row.mandatory)
    row.callback()
    pressDialog("Use Orbit's")
    ok(p.settings.sync_forward == 2, "Use Orbit's applies")
    ok(store.orbit_android.recommended.items["bo.sync_forward"] == "applied", "recorded")
    run(1)
    menu = m.rec_menu
    menuRow(menu, "Gesture in books: hold top-left corner").callback()
    pressDialog("Keep mine")
    ok(store.orbit_android.recommended.items["g.sync_all"] == "kept", "kept")
    ok(ui.gestures.data.gesture_reader.hold_top_left_corner.toc, "kept unchanged")
    run(1)
    -- Kept stays kept on later passes.
    m:recommendedPass("start")
    ok(ui.gestures.data.gesture_reader.hold_top_left_corner.toc, "a pass never revisits kept")
    run(1)
end)

test("recommended: Undo restores the backup; a value changed since is left as is; Undo all", function()
    local ui, m, p = recWorld(false)
    m:recommendedPass("start")
    local menu = m:showRecommended("test")
    menuRow(menu, "Gesture in books: two-finger swipe up").callback()
    pressDialog("Undo")
    ok(ui.gestures.data.gesture_reader.two_finger_swipe_north.increase_frontlight == 0, "frontlight back")
    ok(store.orbit_android.recommended.items["g.apps"] == "kept", "then shown under Kept yours")
    run(1)
    -- Changed by hand after Orbit set it: Undo leaves it.
    p.settings.catalog_auto_open = "filemanager"
    menuRow(m.rec_menu, "BookOrbit › Make BookOrbit home").callback()
    pressDialog("Undo")
    ok(p.settings.catalog_auto_open == "filemanager", "left as is")
    ok(shownText("Changed since; left as is."), "says so")
    run(1)
    menuRow(m.rec_menu, "Undo all").callback()
    ok(p.settings.auto_sync == false and p.settings.sync_forward == 1, "plugin values back")
    ok(ui.gestures.data.gesture_reader.hold_top_right_corner == nil, "gesture back to nothing")
    ok(store.wifi_enable_action == "turn_on", "KOReader's Wi-Fi action stays while Wi-Fi switching needs it")
    ok(shownText("Wi-Fi switching needs it"), "says why")
    run(1)
end)

test("recommended: in a book the settings are written, the line waits for the file browser", function()
    local ui, m, p = recWorld(true)
    m:recommendedPass("start")
    ok(p.settings.auto_sync == true, "written in a book")
    ok(not shownText("Applied"), "no line in a book")
    local ui2, m2 = newUI(false)
    m2:maybeSetupPrompt("home")
    ok(shownText("Applied 8 recommended settings"), "shown off the book")
    run(1)
end)

test("recommended: missing pieces wait: no BookOrbit plugin, Gestures off; applied on the start they appear", function()
    local ui, m, p = recWorld(false)
    ui.bookorbit = nil
    local gestures = ui.gestures
    ui.gestures = nil
    m:recommendedPass("start")
    local items = store.orbit_android.recommended.items
    ok(items["bo.auto_sync"] == "unavailable" and items["g.apps"] == "unavailable", "unavailable, not failed")
    ok(items["ko.wifi_on"] == "applied", "the rest applied")
    local menu = m:showRecommended("test")
    ok(menuRow(menu, "Gesture in books: hold top-right corner").mandatory == "Turn on KOReader's Gestures plugin", "the reason")
    run(1)
    ui.bookorbit, ui.gestures = p, gestures
    m:recommendedPass("start")
    ok(items["bo.auto_sync"] == "applied" and items["g.apps"] == "applied", "applied once they load")
    run(1)
end)

test("recommended: at load, KOReader's Wi-Fi action is set only with the companion, and backed up", function()
    recWorld(false)
    W.companion = false
    RE.installed_cache.at = -1000
    RE.silentWifiOn()
    ok(store.wifi_enable_action == nil, "no companion: left alone")
    W.companion = true
    RE.installed_cache.at = -1000
    RE.silentWifiOn()
    ok(store.wifi_enable_action == "turn_on", "with the companion")
    ok(store.orbit_android.recommended_backup["ko.wifi_on"], "with a backup")
    -- A value the user chose is never overwritten: listed instead.
    recWorld(false)
    store.wifi_enable_action = "ignore"
    RE.silentWifiOn()
    ok(store.wifi_enable_action == "ignore", "kept")
    ok(store.orbit_android.recommended.items["ko.wifi_on"] == "conflict", "to review")
    store.wifi_enable_action = "turn_on"
end)

test("recommended: Keep mine on KOReader's Wi-Fi action offers to turn Wi-Fi switching off instead", function()
    local ui, m = recWorld(false)
    store.wifi_enable_action = "ignore"
    m:recommendedPass("start")
    local menu = m:showRecommended("test")
    menuRow(menu, "KOReader › Action when Wi-Fi is off").callback()
    pressDialog("Turn Wi-Fi switching off")
    ok(store.orbit_android.wifi_via_companion == false, "switching off")
    ok(store.wifi_enable_action == "ignore", "theirs kept")
    store.orbit_android.wifi_via_companion = true
    store.wifi_enable_action = "turn_on"
    run(1)
end)

---------------------------------------------------------------- companion caps (addon-mode §6)

test("caps: from the status file with no service; the status wins when it answers; a leftover file without the companion is ignored", function()
    capsReset()
    capsFile("addon", ADDON)
    RE.Shared.refresh("test")
    ok(RE.Companion.has("install") and not RE.Companion.has("wifi"), "file: Add-on caps")
    ok(store.orbit_android.companion_mode == "addon", "cached for load-time hooks")
    W.web[STATUS_KEY] = "STATUS"
    W.json.STATUS = { version = "0.11.0", mode = "full", caps = FULL }
    RE.Shared.refresh("test")
    ok(RE.Companion.has("wifi"), "/status wins")
    W.json.STATUS = { version = "0.10.0" }
    capsFile(nil)
    RE.Shared.refresh("test")
    ok(RE.Companion.has("home") and RE.Companion.caps_source == "cache", "a status without caps: the caps seen last time, never a guess")
    capsFile("addon", ADDON)
    W.companion = false
    RE.installed_cache.at = -1000
    ok(not RE.Companion.has("install"), "missing companion: no caps, the file is ignored")
    capsReset()
end)

test("caps: Add-on degrades: Sync and sleep asks for the power button, Other apps says Home, no broadcasts, no errors", function()
    capsReset()
    capsFile("addon", ADDON)
    RE.Shared.refresh("test")
    local ui, m = newUI(true)
    W.broadcasts, W.activities, W.shown = {}, {}, {}
    store.orbit_android.screen_off_hint_shown = nil
    m:onOrbitSyncAndSleep()
    run(30)
    ok(not lastBroadcast(".SLEEP_NOW"), "no SLEEP_NOW")
    ok(not lastBroadcast(".NET_UP"), "no NET_UP: the plugin wakes Tailscale itself")
    ok(lastBroadcast("CONNECT_VPN"), "Tailscale woken directly")
    ok(shownText("Synced. Press the power button to sleep.\nOrbit Companion can do this for you"), "the hint, once")
    W.shown = {}
    m:onOrbitSyncAndSleep()
    run(30)
    ok(shownText("Synced. Press the power button to sleep.") and not shownText("can do this for you"), "hint only once")
    W.shown = {}
    m:onOrbitOpenApps()
    ok(shownText("Use your reader's Home button for other apps."), "apps message")
    ok(#W.activities == 0, "no activity started")
    ok(m:openCompanionHome() == true and #W.activities == 0, "Home at BookOrbit home stays")
    local hasWifiRow, hasHelperLine, hasApps = false, false, false
    for _, it in ipairs(menuAll(m:menuItems())) do
        if it.text == "Let Orbit switch Wi-Fi for syncs" then hasWifiRow = true end
        if it.text == "Wi-Fi switching and sleep sync: in Orbit Companion ›" then hasHelperLine = true end
        if it.text == "Open another app…" then hasApps = true end
    end
    ok(not hasWifiRow and hasHelperLine and not hasApps, "rows hidden, one line instead")
    ok(RE.Shared.mode() == "always_on", "Wi-Fi as left: Always on")
    capsReset()
    run(5)
end)

test("caps: without Wi-Fi switching, KOReader's Wi-Fi action is left alone at load", function()
    capsReset()
    capsFile("addon", ADDON)
    recWorld(false)
    capsFile("addon", ADDON)
    RE.Companion.cap_set = nil
    RE.silentWifiOn()
    ok(store.wifi_enable_action == nil, "left alone")
    ok(store.orbit_android.recommended.items["ko.wifi_on"] == "unavailable", "waits for the capability")
    capsReset()
    store.wifi_enable_action = "turn_on"
end)

test("caps: Full → Add-on undoes KOReader's Wi-Fi action and the apps gesture only; back to Full re-applies them", function()
    capsReset()
    local ui, m, p = recWorld(false)
    capsFile("full", FULL)
    RE.Shared.refresh("test")
    m:recommendedPass("start")
    ok(store.wifi_enable_action == "turn_on" and ui.gestures.data.gesture_reader.two_finger_swipe_north.orbit_open_apps, "applied in Full")
    capsFile("addon", ADDON)
    RE.Shared.refresh("resume")
    ok(store.wifi_enable_action == nil, "Wi-Fi action undone")
    ok(ui.gestures.data.gesture_reader.two_finger_swipe_north.increase_frontlight == 0, "apps gesture undone")
    ok(p.settings.auto_sync == true and ui.gestures.data.gesture_reader.hold_top_right_corner.orbit_sync_and_sleep, "reading settings stay")
    capsFile("full", FULL)
    RE.Shared.refresh("resume")
    ok(store.wifi_enable_action == "turn_on" and ui.gestures.data.gesture_reader.two_finger_swipe_north.orbit_open_apps, "picked up again")
    capsReset()
    store.wifi_enable_action = "turn_on"
    run(5)
end)

test("caps: plugin only, a newer plugin on disk: asks to reopen KOReader, never quits with nobody to relaunch it", function()
    capsReset()
    W.companion = false
    RE.installed_cache.at = -1000
    local was = RE.patchFileVersion
    RE.patchFileVersion = function() return "9.9.9" end
    local _, m = newUI(false)
    W.quits, W.shown = 0, {}
    ok(m:maybeRestart("manual") == "ask", "asks")
    run(2)
    ok(W.quits == 0, "no quit")
    ok(shownText("Orbit v9.9.9 is installed: close KOReader and open it again to finish."), "message")
    RE.patchFileVersion = was
    capsReset()
end)

test("report: signed in yes/no and the recommended state go to the companion, never the login itself", function()
    capsReset()
    local ui, m, p = recWorld(false)
    p.settings.sync_forward = 3
    W.broadcasts = {}
    RE.Rec.last_report = nil
    m:recommendedPass("start")
    local r = lastBroadcast(".REPORT")
    ok(r, "REPORT sent")
    ok(r.extras.signed_in == "1" and r.extras.recommended == "partial" and r.extras.conflicts == "1", "fields")
    for k, v in pairs(r.extras) do
        ok(not tostring(v):find("example.test", 1, true), "no server in " .. k)
    end
    ok(r.extras.server_url == nil and r.extras.username == nil and r.extras.userkey == nil, "no login fields")
    -- Unchanged: not sent again on a refresh; a sign-out is.
    W.broadcasts = {}
    RE.Shared.refresh("resume")
    ok(not lastBroadcast(".REPORT"), "nothing new: no report")
    p.signed_out = true
    RE.Shared.refresh("resume")
    ok(lastBroadcast(".REPORT") and lastBroadcast(".REPORT").extras.signed_in == "0", "sign-out reported")
    p.signed_out = nil
    run(2)
end)

test("commands: signin opens BookOrbit's sign-in; recommended opens the review page", function()
    local ui, m, p = recWorld(false)
    p.signed_out = true
    W.intent_extras[RE.Companion.EXTRA_COMMAND] = "signin"
    ok(m:checkCommand("resume"), "handled")
    run(1)
    ok(has(p.calls, "promptLogin"), "BookOrbit's sign-in")
    p.signed_out = nil
    W.intent_extras[RE.Companion.EXTRA_COMMAND] = "recommended"
    ok(m:checkCommand("resume"), "handled")
    run(1)
    ok(m.rec_menu and m.rec_menu.title == "Recommended settings", "review page")
    run(1)
end)

test("add-on: a restart starts the companion's relaunch window, never at screen-off", function()
    capsReset()
    capsFile("addon", ADDON)
    RE.Shared.refresh("test")
    local was = RE.patchFileVersion
    RE.patchFileVersion = function() return "9.9.8" end
    local _, m = newUI(false)
    W.activities, W.broadcasts, W.quits = {}, {}, 0
    RE.state.restarting_at, store.orbit_android.restart_tried = nil, nil
    ok(m:maybeRestart("sleep") == "wait", "no restart at screen-off without Home")
    ok(m:maybeRestart("check") == "wait", "an automatic update in front: waits")
    ok(m:maybeRestart("manual") == "restart", "the reader asked: restart")
    run(2)
    ok(W.activities[#W.activities] and W.activities[#W.activities].action:match("RELAUNCH_UI$"), "relaunch window")
    ok(not lastBroadcast(".RELAUNCH"), "no RELAUNCH broadcast")
    ok(W.quits == 1, "then quits")
    RE.patchFileVersion = was
    RE.state.restarting_at, store.orbit_android.restart_tried = nil, nil
    capsReset()
end)

test("add-on: with no service, the setup box reads the companion's status file", function()
    capsReset()
    local f = io.open(CAPS_FILE, "wb"); f:write("CAPSFILE"); f:close()
    W.json.CAPSFILE = { proto = "1", mode = "addon", caps = ADDON, setup_needed = 1,
        setup_prompt = { key = "signed_in", rows = { "Signed in to BookOrbit" } } }
    store.orbit_android.setup_prompt_shown = nil
    local _, m = newUI(false)
    W.shown = {}
    local code = W.server_code
    W.server_code = nil -- no service: nothing answers on loopback
    RE.Shared.refresh("resume")
    W.server_code = code
    m:maybeSetupPrompt("resume")
    local box, line = shownText("Orbit Companion needs 1 setup step: Signed in to BookOrbit."), m:statusText()
    capsReset()
    ok(box, "box from the file")
    ok(line:find("1 setup step needs you", 1, true), "status line: " .. line)
end)

test("the status ping says whether a book is open (the companion's restart waits for it)", function()
    local _, m = newUI(true)
    W.last_status = nil
    m:onResume()
    run(2)
    ok(W.last_status and W.last_status.book == "1", "in a book")
    local _, m2 = newUI(false)
    W.last_status = nil
    m2:onResume()
    run(2)
    ok(W.last_status and W.last_status.book == "0", "file browser")
end)

test("the status ping tells the companion which patch is running", function()
    local _, m = newUI(false)
    W.last_status = nil
    m:onResume()
    run(2)
    ok(W.last_status and W.last_status.patch_version, "patch_version sent")
end)

test("clicker: mapped keys turn pages inside KOReader; others reach KOReader untouched", function()
    local url = STATUS_KEY
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
    local url = STATUS_KEY
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
    local url = STATUS_KEY
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
    ok(sent[1] and sent[1]:find("^GET /clicks%?patch_version=.*&key=k1 "), "asked for /clicks with the key: " .. tostring(sent[1]))
    ok(W.looper_fd and W.looper_fd.fd == 42, "socket watched in KOReader's looper")
    local events = {}
    ui.handleEvent = function(_, ev) table.insert(events, ev.name .. ":" .. tostring(ev.args[1])) end
    local wait = require("ffi/input_android").waitForEvent
    table.insert(inbox, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nORBIT p1\nSERVICE on\n")
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

test("clicker: a listener on the port that can't prove it is Orbit Companion is dropped", function()
    W.web[STATUS_KEY] = "STATUS"
    W.json.STATUS = { version = "0.4.2", clicker_service = true, keymap = { ["38"] = { press = "prev" } } }
    local socket = require("socket")
    local inbox = {}
    socket.tcp = function()
        return {
            settimeout = function() end, connect = function() return 1 end, getfd = function() return 43 end,
            send = function(_, d) return #d end, close = function() end,
            receive = function()
                if #inbox > 0 then return nil, "timeout", table.remove(inbox, 1) end
                return nil, "timeout", ""
            end,
        }
    end
    RE.Channel.close("test")
    local ui, m = newUI(true)
    m:onResume()
    run(2)
    ok(RE.Channel.up, "channel opened")
    local events = {}
    ui.handleEvent = function(_, ev) table.insert(events, ev.name) end
    table.insert(inbox, "HTTP/1.1 200 OK\r\n\r\nORBIT wrong\nCLICK prev 1\n")
    require("ffi/input_android").waitForEvent()
    run(1)
    ok(#events == 0, "no click done")
    ok(not RE.Channel.up, "closed")
    ok(table.concat(W.logs, "\n"):find("it is not Orbit Companion", 1, true), "logged")
    socket.tcp = nil
    W.web[STATUS_KEY], W.json.STATUS = nil, nil
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

test("storage menu: all sizes and fractional GB labels", function()
    local E = getfenv(Orbit.onSuspend)
    local _, m = newUI(false)
    local row
    for _, it in ipairs(menuAll(m:menuItems())) do
        if it.text_func and it.text_func():find("Storage limit:", 1, true) == 1 then row = it; break end
    end
    ok(row ~= nil, "storage menu exists")
    local labels = { "100 MB", "250 MB", "500 MB", "1 GB", "2.5 GB", "5 GB", "10 GB", "No limit" }
    ok(#row.sub_item_table == #labels, "all choices")
    local was = E.S.storage_limit_mb
    for i, mb in ipairs(E.Cache.STORAGE_LIMITS_MB) do
        E.S.storage_limit_mb = mb
        ok(row.sub_item_table[i].text == labels[i], "choice label " .. labels[i])
        ok(row.sub_item_table[i].checked_func(), "selected choice")
        ok(row.text_func():find("Storage limit: " .. labels[i], 1, true) == 1, "summary label " .. labels[i])
    end
    E.S.storage_limit_mb = was
end)

local function scheduleMenu(m)
    for _, it in ipairs(menuAll(m:menuItems())) do
        local sub = it.sub_item_table
        if type(sub) == "table" and sub[1] and sub[1].text == "Off" and sub[1].checked_func then return sub end
    end
end

test("sync while reading: set in the companion, applied and saved by the patch, shown in its menu, acked", function()
    local url = STATUS_KEY
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
    local url = STATUS_KEY
    W.web[url] = "STATUS"
    local ui, m = newUI(false)
    local function homeText()
        for _, it in ipairs(menuAll(m:menuItems())) do
            if it.text_func then
                local t = it.text_func()
                if t:find("Home button in KOReader", 1, true) then return t end
            end
        end
    end
    W.json.STATUS = { version = "0.4.8", settings = { settings_at = 0, home_opens = "koreader" } }
    m:onResume(); run(1)
    ok(homeText() == "Home button in KOReader: Back to my book, then BookOrbit home", tostring(homeText()))
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

-- Held left-handed (upside down) in another app; KOReader's file browser had forced upright
-- (filemanager.lua:63-69). Home: BookOrbit Home turns back to how the device is held.
test("home from another app with no book: BookOrbit Home keeps the held rotation", function()
    store.lastfile = nil
    local ui, m = newUI(false)
    run(5)
    local screen = preload.device.screen
    local rot = 0
    screen.getRotationMode = function() return rot end
    local set = {}
    function ui:onSetRotationMode(mode) table.insert(set, mode); rot = mode end
    command(m, "home_smart", "other_app")
    W.intent_extras["net.fledgewing.orbitcompanion.extra.ROTATION"] = "reverse_portrait"
    m:onResume()
    run(2)
    ok(#set == 1, "one turn"); ok(set[1] == 2, "upside down, as held")
    ok(W.intent_extras["net.fledgewing.orbitcompanion.extra.ROTATION"] == nil, "extra consumed")
    -- Already as held: nothing turns.
    command(m, "home_smart", "other_app")
    W.intent_extras["net.fledgewing.orbitcompanion.extra.ROTATION"] = "reverse_portrait"
    ui.bookorbit.catalog_browser = nil
    m:onResume()
    run(2)
    ok(#set == 1, "no second turn")
    screen.getRotationMode, ui.onSetRotationMode = nil, nil
    ui.bookorbit.catalog_browser = nil
    W.shown = {}
end)

test("home from another app back to the open book: the book's rotation stays", function()
    local ui, m = newUI(true)
    run(5)
    local screen = preload.device.screen
    screen.getRotationMode = function() return 0 end
    local turned = false
    screen.setRotationMode = function() turned = true end
    m:onSuspend(); W.clock = W.clock + 30
    command(m, "home_smart", "other_app")
    W.intent_extras["net.fledgewing.orbitcompanion.extra.ROTATION"] = "reverse_portrait"
    m:onResume()
    run(2)
    ok(not turned, "a book keeps its own rotation")
    screen.getRotationMode, screen.setRotationMode = nil, nil
    ui.bookorbit.catalog_browser = nil
    W.shown = {}
end)

test("a book closing: the new file browser keeps the book's rotation", function()
    local calls = 0
    FileManager.setRotationMode = function() calls = calls + 1 end
    FileManager._orbit_keep_rotation = nil
    local _, m = newUI(false)
    run(1)
    FileManager:setRotationMode()
    ok(calls == 0, "KOReader's file browser rotation is not applied")
    ok(FileManager._orbit_keep_rotation, "wrapped once")
    local wrapped = FileManager.setRotationMode
    newUI(false); run(1)
    ok(FileManager.setRotationMode == wrapped, "not wrapped twice")
    m = nil
end)

test("start patch: installed into koreader/patches once, kept current", function()
    local E = getfenv(Orbit.onSuspend)
    local data = os.tmpname()
    os.remove(data); os.execute("mkdir -p '" .. data .. "/patches'")
    local saved_dir, saved_ds = E.PLUGIN_DIR, package.loaded.datastorage
    E.PLUGIN_DIR = PLUGIN_MAIN:match("^(.*)/main%.lua$")
    package.loaded.datastorage = { getDataDir = function() return data end }
    local dest = data .. "/patches/1-orbit-start-rotation.lua"
    local okr, first = pcall(E.installStartPatch, "test")
    local second = okr and E.installStartPatch("test")
    local h = io.open(dest, "wb"); h:write("-- an older copy\n"); h:close()
    local third = okr and E.installStartPatch("test")
    local src = io.open(E.PLUGIN_DIR .. "/patches/1-orbit-start-rotation.lua", "rb"):read("*a")
    local got = io.open(dest, "rb"):read("*a")
    E.PLUGIN_DIR, package.loaded.datastorage = saved_dir, saved_ds
    os.execute("rm -rf '" .. data .. "'")
    ok(okr, tostring(first))
    ok(first == true, "installed"); ok(second == false, "already current"); ok(third == true, "replaced an older copy")
    ok(got == src, "the plugin's copy")
end)

test("home at KOReader's start after the start patch: no second turn", function()
    store.lastfile = nil
    local ui, m = newUI(false)
    run(5)
    local screen = preload.device.screen
    screen.getRotationMode = function() return 2 end
    local set = {}
    function ui:onSetRotationMode(mode) table.insert(set, mode) end
    ORBIT_START_ROTATION = 2
    m:smartHome("start", "other_app", "smart", "landscape")
    run(2)
    ORBIT_START_ROTATION = nil
    ok(#set == 0, "the start kept the held rotation")
    screen.getRotationMode, ui.onSetRotationMode = nil, nil
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
    local R = getfenv(Orbit.onSuspend).Recommended
    ok(R.item("g.apps").ours.orbit_open_apps and R.item("g.apps").key == "two_finger_swipe_north", "two-finger swipe up")
end)

---------------------------------------------------------------- updates (Orbit Companion)
-- The plugin and the companion ship together: the menu's check asks the companion (UPDATE), and
-- the plugin downloads, unpacks and installs nothing itself (docs/design/companion-worker.md).
local function updateBroadcasts() return count(W.broadcasts, function(b) return b.action:sub(-7) == ".UPDATE" end) end

test("update: the menu's check asks Orbit Companion; the plugin fetches nothing and forks nothing", function()
    local UE = getfenv(Orbit.onSuspend)
    local real = UE.Companion.workerProblem
    UE.Companion.workerProblem = function() return nil end
    W.broadcasts, W.fetched, W.shown = {}, {}, {}
    local children = #W.children
    local _ui, orbit = newUI(false)
    orbit:checkPatchUpdate()
    run(5)
    UE.Companion.workerProblem = real
    ok(updateBroadcasts() == 1, "one UPDATE: " .. updateBroadcasts())
    local b = W.broadcasts[#W.broadcasts]
    ok(b.package == "net.fledgewing.orbitcompanion" and b.extras.reason == "menu", "to the companion, with the reason")
    ok(b.extras.userkey == nil and b.extras.server == nil, "no login with it")
    ok(count(W.fetched, function(u) return u:find("github", 1, true) ~= nil end) == 0, "no GitHub request")
    ok(#W.children == children, "no background process")
    ok(tostring(W.shown[#W.shown].text):find("Orbit Companion is checking", 1, true), "says the companion checks")
end)

test("update: without the companion of this version the menu says what to do and asks nothing", function()
    local UE = getfenv(Orbit.onSuspend)
    local real = UE.Companion.workerProblem
    local asked
    UE.Companion.workerProblem = function(purpose) asked = purpose; return "Orbit Companion needed " .. tostring(purpose) end
    W.broadcasts, W.shown = {}, {}
    local _ui, orbit = newUI(false)
    orbit:checkPatchUpdate()
    run(2)
    UE.Companion.workerProblem = real
    ok(updateBroadcasts() == 0, "nothing sent")
    ok(asked == "to check for updates", "the update's own wording: " .. tostring(asked))
    ok(tostring(W.shown[#W.shown].text):find("Orbit Companion needed", 1, true), "says so")
    ok(store.orbit_android.patch_update_status.text:find("Orbit Companion needed", 1, true), "status line too")
end)

test("update: start and wake never check for updates themselves", function()
    W.broadcasts, W.fetched = {}, {}
    W.wifi = true
    local _ui, orbit = newUI(false)
    orbit:wakeFlow("wake")
    run(40)
    ok(updateBroadcasts() == 0, "no UPDATE")
    ok(count(W.fetched, function(u) return u:find("github", 1, true) ~= nil end) == 0, "no GitHub request")
end)
---------------------------------------------------------------- one update covers everything
local function stampSelf(v)
    sh("mkdir -p", ORBIT_ANDROID_PLUGIN_DIR)
    local f = io.open(SELF_PATH, "wb")
    f:write('-- BookOrbit-Android patch\nlocal PATCH_VERSION = "' .. v .. '"\nreturn\n'); f:close()
end
local function relaunches() return count(W.broadcasts, function(b) return b.action:sub(-9) == ".RELAUNCH" end) end
local function restartReset() run(10); W.clock = W.clock + 10; store.orbit_android.restart_tried = nil; W.broadcasts = {} end

test("one update: an automatic update waits in front (no book, Home or a list); the screen going off restarts it", function()
    restartReset(); stampSelf("0.3.0")
    local _ui, m = newUI(false)
    m:onResume()
    run(3)
    ok(relaunches() == 0, "no restart in front: " .. relaunches())
    ok(m:maybeRestart("sleep") == "restart", "the screen off")
    run(2)
    ok(relaunches() == 1, "restarted once: " .. relaunches())
    restartReset()
end)

test("one update: an update the reader asked for restarts at once, book open or not; the book reopens", function()
    restartReset(); stampSelf("0.3.0")
    W.screen_on = true
    local ui, m = newUI(true)
    ok(m:maybeRestart("manual") == "restart", "at once")
    run(2)
    ok(relaunches() == 1, "restarted: " .. relaunches())
    ok(store.orbit_android.restart_book ~= nil, "the book is saved to reopen")
    restartReset()
end)

test("reading gate: nothing shows while a book is open in front; it all shows once the book closes", function()
    restartReset()
    RE.Gate.queue = {}
    local _ui, m = newUI(true)
    W.shown = {}
    ok(RE.reading(), "reading")
    RE.orbitNote("Applied 4 recommended settings · Review", 4)
    RE.orbitNote("Updated to v9.9.9", 3)
    m:showWakeBanner({ detail = "x" })
    local okt, Toast = pcall(require, "bookorbit_toast")
    if okt and Toast.show then Toast.show("Synced") end
    run(3)
    ok(#W.shown == 0, "nothing on screen while reading: " .. #W.shown)
    ok(#RE.Gate.queue >= 3, "held: " .. #RE.Gate.queue)
    m:onCloseWidget()
    newUI(false)
    run(3)
    ok(#RE.Gate.queue == 0, "drained")
    local texts = {}
    for _, w in ipairs(W.shown) do texts[#texts + 1] = tostring(w.text) end
    ok(table.concat(texts, "|"):find("Updated to v9.9.9", 1, true), "shown after the close: " .. table.concat(texts, "|"))
    restartReset()
end)

test("reading gate: a note held too long is dropped, not shown late", function()
    RE.Gate.queue = {}
    local _ui = newUI(true)
    W.shown = {}
    RE.Gate.show("old", function() UIManager:show({ text = "old" }) end, 5)
    W.clock = W.clock + 60
    newUI(false)
    RE.Gate.drain("test")
    ok(#W.shown == 0, "dropped")
end)

test("reading gate: recommended note pending + Home press -> Home opens the first time", function()
    RE.Gate.queue = {}
    local _ui, m = newUI(false)
    W.shown = {}
    RE.orbitNote("Applied 4 recommended settings · Review", 4)
    ok(#W.shown == 1 and W.shown[1].orbit_note, "a note, not in Home's way")
    ok(RE.topWidget() ~= W.shown[1], "Home logic sees through it")
end)

test("one update: KOReader in the background saves and quits (nothing relaunches it); the next start has the new plugin", function()
    restartReset(); stampSelf("0.3.0")
    W.screen_on = true
    local _ui, m = newUI(true)
    m:onResume()
    run(5)
    ok(relaunches() == 0, "never interrupts reading")
    W.quits = 0
    m:onCloseWidget()
    newUI(false)
    run(3)
    ok(relaunches() == 0 and W.quits == 0, "a closed book doesn't restart it")
    ok(m:maybeRestart("background") == "quit", "another app in front")
    run(2)
    ok(relaunches() == 0 and W.quits == 1, "saved and quit, no relaunch: " .. relaunches() .. " " .. W.quits)
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
    for _, w in ipairs(W.shown) do if tostring(w.text) == "Updated to v0.0.0-dev" and w.orbit_note then found = true end end
    ok(found, "a short note, never in Home's way")
    ok(store.orbit_android.restart_tried == nil, "try cleared")
    ok(store.orbit_android.patch_update_status.text == "Updated to v0.0.0-dev", "update status")
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

test("settings PIN: a locked companion makes the Orbit menu read-only, with the keypad one tap away; unreachable stays usable", function()
    local url = STATUS_KEY
    local ui, m = newUI(true)
    local items = {}
    m:addToMainMenu(items)
    W.web[url] = "STATUS"
    W.json.STATUS = { version = "0.4.4", pin_locked = true }
    W.activities = {}
    local sub = items.orbit_android.sub_item_table_func()
    ok(sub[1].text:find("PIN", 1, true), "first row asks for the PIN")
    -- Every value is still there to read; nothing that changes something is enabled.
    local all = menuAll(sub)
    ok(#all > 20, "the whole menu, read-only " .. #all)
    local enabled = 0
    for i, it in ipairs(all) do
        if i > 1 and it.callback and not it.sub_item_table and not it.keep_menu_open and not it.read_only and not (it.enabled_func and it.enabled_func() == false) then
            enabled = enabled + 1
        end
    end
    eq(enabled, 0, "no control enabled while locked")
    local wifi = RE.S.sync_on_wake
    for _, it in ipairs(all) do if it.text == "Sync on wake" then it.callback() end end
    eq(RE.S.sync_on_wake, wifi, "a tap changes nothing")
    run(1)
    for _, a in ipairs(W.activities) do ok(not a.action:match("SHOW_PIN$"), "no keypad until asked") end
    W.activities = {}
    sub[1].callback()
    ok(W.activities[1] and W.activities[1].action:match("SHOW_PIN$"), "the first row opens the keypad")
    W.json.STATUS = { version = "0.4.4", pin_locked = false }
    local open = items.orbit_android.sub_item_table_func()
    ok(not open[1].text:find("PIN", 1, true), "unlocked: the usual menu")
    W.web[url], W.json.STATUS = nil, nil
    W.activities = {}
    ok(#items.orbit_android.sub_item_table_func() >= 9, "companion unreachable: full menu")
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
    local cat = newCatalog(LCat, LApi, { kind = "books", title = "Search", params = { sort = "title", q = "sky" } })
    ok(#cat:listSortSheetModel({}).rows == 1, "a search: no rows")
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

test("end of book: Download and open uses the reader's delivery variant and a supported file (hash_mismatch on M8C)", function()
    eobModules()
    local JSON = dofile(here .. "/json_mini.lua")
    -- @fixture bookorbit/catalog-book.delivery-variants.json
    local fx = JSON.fixture(here, "bookorbit/catalog-book.delivery-variants.json")
    local DCat = {}
    DCat.__index = DCat
    function DCat:fetchDeliveryBook(id) table.insert(eob.calls, "delivery:" .. id); return fx.with_variant end
    function DCat:supportedFiles(detail)
        local out = {}
        for _, f in ipairs(detail.files) do if f.format == "epub" then table.insert(out, f) end end
        return out
    end
    function DCat:downloadDefaultFile(detail, file) self:checkDownloadFile("/books/titan.epub", detail, file) end
    function DCat:downloadFile(path, detail, file, rep)
        eob.file = file
        rep.finished(true, nil, path)
    end
    function DCat:loadBooks() end
    package.loaded["bookorbit_catalog"] = DCat
    local ui = bookUI()
    ui.status:onEndOfBook()
    eob.calls, eob.file = {}, nil
    sheetRow("card", "Titan's Curse").action()
    run(60)
    local c = table.concat(eob.calls, ",")
    ok(c:find("delivery:43", 1, true) and not c:find("book:43", 1, true), "the plugin's delivery detail: " .. c)
    ok(eob.file and eob.file.id == 902 and eob.file.selection == "sel-902", "the EPUB with its selection")
    ok(eob.file.fileHash == "hash-audioless-artifact", "checked against the artifact's hash")
    package.loaded["bookorbit_catalog"] = nil
end)

-- Keep book copies current: BookOrbit rewrote the library files (tags), every copy is
-- position-incompatible; each is downloaded again in place, one at a time, never while reading.
local function copiesSetup(books, md5s)
    eobModules()
    local sm = package.loaded["bookorbit_state_manager"]
    copies = { calls = {}, repaired = {}, md5s = md5s }
    sm.state = function() return { books = books, global = {} } end
    sm.repairFileIdentity = function(file, old, new) table.insert(copies.repaired, file .. ":" .. old .. ">" .. new) end
    local DCat = {}
    DCat.__index = DCat
    function DCat:fetchDeliveryBook(id)
        table.insert(copies.calls, "delivery:" .. id)
        return { id = id, files = { { id = id * 10, role = "primary", fileHash = "new" .. id } } }
    end
    function DCat:downloadFile(path, detail, file, rep)
        table.insert(copies.calls, "download:" .. path)
        ok(file.fileHash == "new" .. detail.id, "checked against the library hash")
        copies.md5s[path] = file.fileHash
        rep.finished(true, nil, path)
    end
    function DCat:downloadDefaultFile() end
    function DCat:loadBooks() end
    package.loaded["bookorbit_catalog"] = DCat
    E.Copies.md5 = function(path) return copies.md5s[path] end
    -- Orbit Companion finds the changed copies (fake_companion.lua), on its own cache folder.
    copies.dir = os.tmpname(); os.remove(copies.dir); sh("mkdir -p", copies.dir .. "/events"); sh("mkdir -p", copies.dir .. "/copies")
    local lfs = require("libs/libkoreader-lfs")
    copies.lfs_dir = lfs.dir
    lfs.dir = function(d)
        local h = io.popen('ls -1 "' .. d .. '" 2>/dev/null'); local names = {}
        for n in h:lines() do table.insert(names, n) end
        h:close(); local i = 0
        return function() i = i + 1; return names[i] end
    end
    copies.saved_dir, copies.saved_problem = E.OC._dir, E.Companion.workerProblem
    E.OC._dir, E.OC._index, E.OC.watching = copies.dir, nil, nil
    E.Companion.workerProblem = function() return copies.problem end
    copies.fc = dofile(here .. "/fake_companion.lua")
    copies.fc.install(E, W, function() return nil, 404 end, UIManager)
    copies.fc.exists = function(path) return copies.md5s[path] ~= nil end
    W.on_broadcast = copies.fc.receive
    E.Copies.state().queue = {}
    E.Copies.scanned_at, E.Copies.active, E.Copies.busy, E.Copies.asked = nil, nil, nil, nil
    W.wifi, W.vpn, W.companion = true, true, true
end
local function copiesTeardown()
    package.loaded["bookorbit_catalog"] = nil
    W.on_broadcast = nil
    E.Companion.workerProblem = copies.saved_problem
    E.OC._dir, E.OC._index = copies.saved_dir, nil
    require("libs/libkoreader-lfs").dir = copies.lfs_dir
    sh("rm -rf", copies.dir)
end
local function copiesUI(in_book)
    local ui, m = newUI(in_book)
    ui.bookorbit.newClient = function() return setmetatable({}, EApi) end
    return ui, m
end
local function copyBooks()
    return {
        old1 = { file = "/books/a.epub", bookId = 1, fileId = 10, positionIncompatible = true },
        old2 = { file = "/books/b.epub", bookId = 2, fileId = 20, positionIncompatible = true },
        cur3 = { file = "/books/c.epub", bookId = 3, fileId = 30 },
    }
end

test("copies: changed copies are replaced in place, one at a time, and their hashes move on", function()
    copiesSetup(copyBooks(), { ["/books/a.epub"] = "old1", ["/books/b.epub"] = "old2", ["/books/c.epub"] = "cur3" })
    copiesUI(false)
    E.Copies.tick("test")
    run(10)
    local c = table.concat(copies.calls, ",")
    ok(c == "delivery:1,download:/books/a.epub,delivery:2,download:/books/b.epub", "one at a time: " .. c)
    ok(table.concat(copies.repaired, ",") == "/books/a.epub:old1>new1,/books/b.epub:old2>new2", "state re-keyed: " .. table.concat(copies.repaired, ","))
    ok(#E.Copies.state().queue == 0, "queue done")
    copiesTeardown()
end)

test("copies: never while reading; the queue waits on disk and goes once the book closes", function()
    copiesSetup(copyBooks(), { ["/books/a.epub"] = "old1", ["/books/b.epub"] = "old2" })
    local _ui, m = copiesUI(true)
    E.Copies.tick("test")
    E.Copies.ask("test")
    run(5)
    ok(#copies.calls == 0, "nothing while reading")
    ok(#E.Copies.state().queue == 2, "queued: " .. #E.Copies.state().queue)
    m:onCloseWidget()
    copiesUI(false)
    run(10)
    ok(#copies.calls == 4, "replaced after the close: " .. table.concat(copies.calls, ","))
    copiesTeardown()
end)

test("copies: offline or turned off, nothing is downloaded; a copy already current is left alone", function()
    copiesSetup(copyBooks(), { ["/books/a.epub"] = "new1", ["/books/b.epub"] = "old2" })
    copiesUI(false)
    store.orbit_android.keep_copies_current = false
    E.Copies.tick("test")
    run(5)
    ok(#copies.calls == 0, "off")
    store.orbit_android.keep_copies_current = true
    W.wifi = false
    E.Copies.tick("test")
    run(5)
    ok(#copies.calls == 0, "offline")
    W.wifi = true
    E.Copies.scanned_at = nil
    E.Copies.tick("test")
    run(10)
    local c = table.concat(copies.calls, ",")
    ok(not c:find("download:/books/a.epub", 1, true), "a already matches the library: " .. c)
    ok(c:find("download:/books/b.epub", 1, true), "b replaced")
    copiesTeardown()
end)

test("copies: Orbit Companion finds the changed copies; the UI thread reads no saved detail and checks no file", function()
    copiesSetup(copyBooks(), { ["/books/a.epub"] = "old1", ["/books/b.epub"] = "old2", ["/books/c.epub"] = "cur3" })
    copiesUI(false)
    local reads, exists = 0, 0
    local get, lfs = E.OC.get, require("libs/libkoreader-lfs")
    local attributes = lfs.attributes
    E.OC.get = function(...) reads = reads + 1; return get(...) end
    lfs.attributes = function(f, ...) if not W.in_companion and tostring(f):find("^/books/") then exists = exists + 1 end return attributes(f, ...) end
    W.broadcasts = {}
    E.Copies.tick("test")
    local b = lastBroadcast(".COPIES")
    ok(b and b.extras.reason == "test" and b.extras.userkey == nil, "asked the companion, no login")
    local ask = E.Cache.decode(E.OC.readFile(copies.dir .. "/copies/ask.lua") or "")
    ok(ask and #ask.books == 3, "the ask lists the books from memory")
    run(10)
    E.OC.get, lfs.attributes = get, attributes
    ok(copies.fc.copies_asks == 1, "the companion looked")
    ok(reads == 0 and exists == 0, "no detail read, no file checked on the UI thread: " .. reads .. " " .. exists)
    ok(#copies.calls == 4, "the two changed copies replaced: " .. table.concat(copies.calls, ","))
    -- Without the companion of this version nothing is checked.
    copies.problem = "Orbit Companion needed"
    E.Copies.scanned_at = nil
    E.Copies.tick("test"); run(5)
    ok(copies.fc.copies_asks == 1, "not asked")
    copies.problem = nil
    copiesTeardown()
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
local FC = dofile(here .. "/fake_companion.lua")
-- A book's detail as the companion's mirror saved it, or nil.
local function detailEntry(client, id)
    local body, at = FC.detail(id)
    if type(body) == "table" then return { body = body, validated_at = at } end
end
local cacheTeardown
local function cacheSetup(prep)
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
        if k == "ino" then return cache.lfs_saved.attributes(f, k) end
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
        if not W.wifi and cache.strict_offline then return nil, "wantread" end
        if cache.server_fn then
            local b = cache.server_fn(path)
            if b == false then return nil, "timeout" end -- no answer (a transport error, not HTTP)
            if b == nil then return nil, 404 end
            return E.Cache.copy(b)
        end
        local b = cache.server[path]
        if b == nil then return nil, 404 end
        return E.Cache.copy(b)
    end
    function Api:request(method, path, body, headers) return self:requestBlocking(method, path, body, headers) end
    -- As bookorbit_api.lua:336-372 with canForkSubprocess true: fn runs in a forked child; a child
    -- that dies (JNI) returns nothing, which the plugin reports as subprocess_no_result (:106).
    function Api:runInSubprocess(fn)
        self.subprocess_depth = (self.subprocess_depth or 0) + 1
        W.in_child = true
        local okc, b, e, eb = pcall(fn)
        W.in_child = nil
        self.subprocess_depth = self.subprocess_depth - 1
        if not okc then cache.child_crash = tostring(b); return true, { err = "subprocess_no_result" } end
        return true, { body = b, err = e, errbody = eb }
    end
    function Api:downloadCatalogThumbnail(id, path) cache.stock_cover = (cache.stock_cover or 0) + 1; return true end
    function Api:getProxy() return nil end
    -- As bookorbit_api.lua:386: sorted keys, empty values and on_device_filter dropped.
    function Api:query(path, params)
        local keys = {}
        for k, v in pairs(params or {}) do if k ~= "on_device_filter" and v ~= nil and v ~= "" then table.insert(keys, k) end end
        table.sort(keys)
        if #keys == 0 then return path end
        local parts = {}
        for _, k in ipairs(keys) do
            table.insert(parts, k .. "=" .. tostring(params[k]):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
        end
        return path .. "?" .. table.concat(parts, "&")
    end
    package.loaded["bookorbit_api"] = Api
    local Cat = lfModules()
    if prep then prep(Cat, Api) end
    cache.connects = 0
    function Cat:runConnected(fn) cache.connects = cache.connects + 1; fn() end
    package.loaded["ui/trapper"] = { wrap = function(_, fn) return fn() end, isWrapped = function() return false end }
    E.LF.installed = nil
    ok(E.LF.install("test"), "local-first on this catalog")
    function Cat:loadDashboardRoot() cache.reloaded = (cache.reloaded or 0) + 1 end
    E.OC.installed, E.OC._dir, E.OC._index = nil, dir, nil
    E.OC.memo, E.OC.memo_order, E.OC.queue, E.OC.inflight, E.OC.pending, E.OC.active = {}, {}, {}, {}, {}, nil
    E.OC.full, E.OC.child, E.OC.offline_pass, E.OC.running = nil, nil, nil, nil
    E.OC.redraw_scheduled, E.OC.redraw_key, E.OC.cache_only = nil, nil, nil
    E.Mirror.active, E.Mirror.busy, E.Mirror.cat, E.Mirror.manual, E.Mirror.ticked_at = nil, nil, nil, nil, nil
    E.Mirror._status, E.Mirror.next, E.Mirror.polling, E.Mirror.logged_at, E.Mirror._keep = nil, nil, nil, nil, nil
    E.OC._saving, E.OC._save_pending, E.OC._save_again = nil, nil, nil
    cache.server_fn, cache.strict_offline = nil, nil
    cache.reloaded = nil
    E.OC.note = function() end
    E.OC.now = function() return math.floor(W.clock) end
    E.S.offline_cache = true
    -- The companion's cache worker, played by the tests (fake_companion.lua), on the same files.
    E.Mirror.run_id, E.Mirror.indicator_at, E.Mirror.blocked, E.Mirror.sent_at, E.Mirror.seen_beat = nil, nil, nil, nil, nil
    E.OC.watching, E.OC.check_blocked = nil, nil
    E.Badge.history, E.Badge.running, E.Badge.widget, E.Badge.pct, E.Badge.expanded = {}, nil, nil, nil, nil
    W.companion = true
    cache.worker_problem = nil
    cache.real_workerProblem = cache.real_workerProblem or E.Companion.workerProblem
    E.Companion.workerProblem = function() return cache.worker_problem end
    FC.install(E, W, function(path)
        -- The server sees the companion's requests like the plugin's (cache.calls).
        table.insert(cache.calls, "GET " .. path)
        if not W.wifi and cache.strict_offline then return nil, "wantread" end
        local b
        if cache.server_fn then
            b = cache.server_fn(path)
            if b == false then return nil, "timeout" end
        else b = cache.server[path] end
        if b == nil then return nil, 404 end
        return E.Cache.copy(b)
    end, UIManager)
    W.on_broadcast = FC.receive
    ok(E.OC.install("test"), "installed")
    W.after_fail = cacheTeardown
    local client = setmetatable({ username = "reader", userkey = "k", server_url = "https://books.example" }, Api)
    return client, Cat, Api
end
function cacheTeardown()
    local lfs = require("libs/libkoreader-lfs")
    for k, v in pairs(cache.lfs_saved) do lfs[k] = v end
    sh("rm -rf", cache.dir)
    E.OC.storage, E.OC.cover_dir = nil, nil
    for _, k in ipairs({ "bookorbit_api", "bookorbit_catalog", "bookorbit_board_data", "bookorbit_list_view", "bookorbit_board_ui", "ui/trapper" }) do
        package.loaded[k] = nil
    end
    E.OC.installed = nil
    W.on_broadcast = nil
    if cache.real_workerProblem then E.Companion.workerProblem = cache.real_workerProblem end
    FC.kill()
end
local DASH = "/koreader/plugin/catalog/dashboard"

test("cache: a read is answered from the cache at once, checked after 60 s, redrawn when it changed", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    cache.server[DASH] = { continueReading = { { id = 7, title = "A" } } }
    local b = client:request("GET", DASH)
    ok(b and b.continueReading[1].id == 7 and #cache.calls == 1, "first read: the server")
    -- The companion saves it (it asks the server again: CHECK mode "store").
    run(1)
    ok(#cache.calls == 2 and E.Store.read(E.OC.owner(client), "x", DASH) == nil, "not saved under another key")
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
    client:request("GET", DASH); run(1)
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
    client:request("GET", DET); client:request("GET", DASH); run(1)
    client:request("PUT", "/koreader/plugin/catalog/books/7/read-status", { status = "read" })
    -- The companion patches the saved replies (PATCH).
    run(1)
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

test("cache: a read made in the catalog's child process is saved by the companion", function()
    local client = cacheSetup()
    W.wifi = true
    cache.server[DASH] = { continueReading = { { id = 9 } } }
    local done, r = client:runInSubprocess(function() return client:request("GET", DASH) end)
    ok(done and r.body.continueReading[1].id == 9, "the child's answer")
    run(1)
    local key = E.Cache.key({ account = E.OC.owner(client), server = client.server_url, method = "GET", path = DASH })
    ok(E.Store.read(E.OC.owner(client), key, DASH) ~= nil, "the companion saved it")
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
    -- A metadata edit moved updatedAt: one 304, the file copied to the new version's name, no
    -- body transferred; the older file stays for a view painted from an older body.
    local v2 = dir .. "/7_20261121.jpg"
    ok(client:downloadCatalogThumbnail(7, v2, { temp_path = v2 .. ".part", max_bytes = 4e6 }), "304")
    ok(sent[2] == server_etag, "asked If-None-Match")
    ok(io.open(v2) and io.open(v1), "the new version's file is there, and the older one stays")
    -- The cover really changed: replaced, the old one gone, the new ETag kept.
    server_etag, cover = '"200"', "\137PNG\r\n\26\n" .. string.rep("y", 40)
    local v3 = dir .. "/7_20261122.jpg"
    ok(client:downloadCatalogThumbnail(7, v3, { temp_path = v3 .. ".part", max_bytes = 4e6 }), "200")
    ok(io.open(v3) and io.open(v2), "the new cover saved; the older version is the plugin's pruner's to drop")
    f = io.open(v3 .. ".etag"); ok(f and f:read("*a") == '"200"', "new ETag"); if f then f:close() end
    ok(cache.stock_cover == nil, "never the plugin's download")
    -- Orphaned ETags are cleaned.
    io.open(dir .. "/9_1.jpg.etag", "w"):close()
    ok(E.OC.cleanEtags(dir) == 1, "orphan ETag removed")
    http.request, ltn.sink.file = stock_http, stock_file
    cacheTeardown()
end)

-- The request paths the pinned plugin builds (bookorbit_api.lua:676-738; query() sorts and drops
-- empty parameters, :386). plugin_compat.lua checks these strings are still in the plugin.
local PLUGIN_PATHS = {
    root = "/koreader/plugin/catalog/root",
    dashboard = "/koreader/plugin/catalog/dashboard",
    discover = "/koreader/plugin/catalog/dashboard/discover",
    dsection = "/koreader/plugin/catalog/dashboard/sections/recently-added",
    section = "/koreader/plugin/catalog/sections/series?page=1&size=50",
    books = "/koreader/plugin/catalog/books?page=2&size=24&sort=title",
    manifest = "/koreader/plugin/catalog/manifest?page=1",
    detail = "/koreader/plugin/catalog/books/549?deviceId=F00D",
}

test("cache: every catalog read the plugin makes in its child process is cached and served (M8C: Home and lists bypassed it)", function()
    local client = cacheSetup()
    W.wifi = true
    for name, path in pairs(PLUGIN_PATHS) do cache.server[path] = { name = name, items = { { id = 1 } } } end
    for name, path in pairs(PLUGIN_PATHS) do
        local done, r = client:runInSubprocess(function() return client:request("GET", path) end)
        ok(done and r.body and r.body.name == name, name .. ": answered in the child, err " .. tostring(r.err) .. " " .. tostring(cache.child_crash))
    end
    run(1)
    cache.calls = {}
    for name, path in pairs(PLUGIN_PATHS) do
        local _, r = client:runInSubprocess(function() return client:request("GET", path) end)
        -- A list's page 2 is served from its positions (its head fields come with page 1).
        ok(r.body and (r.body.name == name or name == "books" and r.body.items[1].id == 1), name .. ": from the cache")
    end
    ok(#cache.calls == 0, "no request the second time: " .. table.concat(cache.calls, ","))
    -- Offline: a cached list page pages without a request or an error.
    W.wifi = false
    W.clock = W.clock + 3600
    local _, r = client:runInSubprocess(function() return client:request("GET", PLUGIN_PATHS.books) end)
    ok(r.body and r.body.items[1].id == 1 and #cache.calls == 0, "offline: the cached page, err " .. tostring(r.err))
    W.wifi = true
    cacheTeardown()
end)

test("cache: offline, a cached page opens without connecting; an uncached one asks Connect and load more", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    cache.server[PLUGIN_PATHS.books] = { items = { { id = 1 } } }
    client:runInSubprocess(function() return client:request("GET", PLUGIN_PATHS.books) end)
    run(1)
    ok(rawget(Cat, "__orbit_stock") and Cat.__orbit_stock["cache:runConnected"], "runConnected wrapped")
    local cat = setmetatable({ client = client }, Cat)
    cache.connects = 0
    W.wifi = false
    local got, err
    cat:runConnected(function() local _, r = client:runInSubprocess(function() return client:request("GET", PLUGIN_PATHS.books) end); got, err = r.body, r.err end)
    ok(got and cache.connects == 0, "cached: no connect, no error")
    local before = #W.shown
    cat:runConnected(function() local _, r = client:runInSubprocess(function() return client:request("GET", "/koreader/plugin/catalog/books?page=9") end); got, err = r.body, r.err end)
    ok(got == nil and err == "cancelled" and cache.connects == 0, "uncached: quiet (cancelled), not yet connected: " .. tostring(err))
    local box = W.shown[#W.shown]
    ok(#W.shown > before and box.ok_text == "Connect and load more", "asks: " .. tostring(box and box.ok_text))
    box.ok_callback()
    ok(cache.connects == 1, "then connects and loads")
    W.wifi = true
    cacheTeardown()
end)

test("cache: tap ⟳ says Refreshing (a tip to hold, once); hold starts a Full refresh with no other note (the badge says it)", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    local notes = {}
    E.OC.note = function(t) table.insert(notes, t) end
    cache.server[DASH] = { continueReading = { { id = 7, hasCover = true } } }
    client:request("GET", DASH)
    local cat = setmetatable({ current_context = { kind = "dashboard", dashboard = cache.server[DASH] }, client = client }, Cat)
    function cat:refreshCurrent() self.client:request("GET", DASH); self:switchTo("Home", {}, self.current_context, false) end
    E.S.refresh_tip_shown = nil
    E.OC.refresh(cat); E.OC.refresh(cat)
    ok(notes[1]:find("Tip: hold ⟳ for a full refresh", 1, true) and notes[2] == "Refreshing…", "tip once: " .. table.concat(notes, " | "))
    notes = {}
    W.logs = {}
    E.OC.fullRefresh(cat)
    run(5)
    ok(#notes == 0, "no note during a Full refresh: " .. table.concat(notes, " | "))
    ok(table.concat(W.logs, "\n"):find("this page is refreshed, 1 covers checked", 1, true), "logged")
    cacheTeardown()
end)

---------------------------------------------------------------- v0.11.1: first paint, covers, offline mirror

-- A small library on a fake server: books 1..n_books (recently added = id order), series 4 with
-- lib.series4 books, and the section indexes. Answers by the request's parameters, like the
-- server: page/size or offset/size (koreader-catalog-query.dto.ts:66-88, :260-285).
local function libraryServer(lib)
    local Q = E.Cache.parseQuery
    return function(path)
        local p, q = path:match("^([^?]*)%??(.*)$")
        local query = Q(q)
        local function page(items)
            local size = tonumber(query.size) or 20
            local start = tonumber(query.offset) or ((tonumber(query.page) or 1) - 1) * size
            local out = {}
            for i = start + 1, math.min(#items, start + size) do table.insert(out, items[i]) end
            return { items = out, total = #items, page = math.floor(start / size) + 1, size = size,
                hasNext = start + size < #items, hasPrevious = start > 0, generatedAt = tostring(W.clock) }
        end
        if p:find("/catalog/books$") then
            local items = {}
            if query.seriesId == "4" then
                for i = 1, lib.series4 do table.insert(items, { id = 1000 + i, title = "S" .. i, seriesIndex = i, hasCover = false }) end
            elseif query.ids then
                for id in query.ids:gmatch("%d+") do table.insert(items, { id = tonumber(id), hasCover = false }) end
            else
                for i = 1, lib.n_books do table.insert(items, { id = i, title = "B" .. i, hasCover = lib.covers == true, updatedAt = "u" .. i }) end
            end
            return page(items)
        end
        local section = p:match("/catalog/sections/([%w%-]+)$")
        if section == "series" then return page({ { id = "Saga", seriesId = 4, name = "Saga" } }) end
        if section then return page({}) end
        local id = p:match("/catalog/books/(%d+)$")
        if id then return { id = tonumber(id), title = "B" .. id } end
        if p:find("/catalog/dashboard$") then return { continueReading = { { id = 7, progressPercentage = 10 } }, generatedAt = tostring(W.clock) } end
        return nil
    end
end

-- The plugin's request builders (bookorbit_catalog.lua:1111 paramsForEntry, :1453 effectiveOrder,
-- bookorbit_catalog_lists.lua:229 listDecorateBookQuery, :246 listSectionParams).
local function pluginCatalog(Cat, client)
    local cat = setmetatable({ client = client, on_device = {}, current_context = { kind = "dashboard", dashboard = {} } }, Cat)
    function cat:paramsForEntry(section, entry)
        local params = { sort = section == "series" and "series" or "title" }
        if section == "series" then params.seriesId = tonumber(entry.seriesId) end
        if section == "authors" then params.author = entry.id end
        if section == "libraries" then params.libraryId = tonumber(entry.id) end
        if section == "collections" then params.collectionId = tonumber(entry.id) end
        if section == "smart-scopes" then params.smartScopeId = tonumber(entry.id) end
        if section == "series" and not entry.seriesId then params.series = entry.id end
        return params
    end
    function cat:effectiveOrder(q) return q.order or (q.sort == "recently_added" and "desc" or "asc") end
    function cat:listDecorateBookQuery(q) if (q.sort or "title") == "title" then q.buckets = 1 end return q end
    function cat:listSectionParams(section, opts) return { size = 11 } end
    function cat:refreshCurrent() self.client:request("GET", DASH) end
    return cat
end

-- What the plugin asks for when it pages a list (fetchBookPage, bookorbit_catalog.lua:1135).
local function pagePath(cat, params, page, size)
    local q = {}
    for k, v in pairs(params) do q[k] = v end
    q.page, q.size = page, size
    q.order = cat:effectiveOrder(q)
    cat:listDecorateBookQuery(q)
    return cat.client:query("/koreader/plugin/catalog/books", q)
end

local function offlineRead(cat, client, path)
    local got, err
    cat:runConnected(function()
        local _, r = client:runInSubprocess(function() return client:request("GET", path) end)
        got, err = r.body, r.err
    end)
    return got, err
end

local function withHost(cat, fn)
    local hosts = E.bookorbit
    E.bookorbit = function() return { catalog_browser = cat } end
    local okf, err = pcall(fn)
    E.bookorbit = hosts
    if not okf then error(err, 0) end
end

-- @fixture catalog/sections.json
test("mirror: every Home shelf and server index is planned before any browsing", function()
    local client, Cat = cacheSetup()
    local cat = pluginCatalog(Cat, client)
    local plan = E.Mirror.plan(cat, "full", "coverage")
    local inventory = E.Mirror.INVENTORY
    local paths = {}
    for _, path in ipairs(plan.browse_lists) do paths[path] = true end
    for kind, params in pairs(inventory.home_books) do
        local q = {}
        for k, v in pairs(params) do q[k] = v end
        q.order = cat:effectiveOrder(q); cat:listDecorateBookQuery(q)
        ok(paths[client:query("/koreader/plugin/catalog/books", q)], "uncovered Home shelf: " .. kind)
    end
    for kind, params in pairs(inventory.root_books) do
        local q = {}
        for k, v in pairs(params) do q[k] = v end
        q.order = cat:effectiveOrder(q); cat:listDecorateBookQuery(q)
        ok(paths[client:query("/koreader/plugin/catalog/books", q)], "uncovered server book row: " .. kind)
    end
    eq(#plan.sections, #inventory.sections)
    for _, section in ipairs(inventory.sections) do
        local template = plan.templates[section]
        ok(template and template.path, "uncovered selector " .. section)
        for _, key in ipairs(inventory.selectors[section]) do
            local path = key == "series" and template.series_name_path or template.path
            ok(path:find(key .. "=" .. E.Mirror.SENTINEL, 1, true), "uncovered selector key " .. key)
        end
    end
    eq(plan.catalog, inventory)
    local incremental = E.Mirror.plan(cat, "incremental", "coverage")
    eq(#incremental.dynamic_lists, #plan.dynamic_lists)
    ok(#incremental.entries >= 5, "root, Home, Discover and composed shelves")
    cacheTeardown()
end)

test("cache: after a Full refresh, offline paging through every page of a linked list never asks to connect", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    local lib = { n_books = 30, series4 = 25 }
    cache.server_fn = libraryServer(lib)
    local cat = pluginCatalog(Cat, client)
    withHost(cat, function()
        -- Home's shelf read page 1 of Recently added (12 a page); the series list was never opened.
        client:request("GET", DASH)
        client:request("GET", pagePath(cat, { sort = "recently_added" }, 1, 12))
        E.OC.fullRefresh(cat)
        run(600)
        local m = E.Mirror.status()
        ok(m.at and m.left == 0, "the Full refresh finished: " .. tostring(m.left) .. " left")
        ok(FC.count("SELECT count(*) FROM lists WHERE identity = ?", "/koreader/plugin/catalog/books?order=desc&sort=recently_added") == 1, "the Home shelf's list is mirrored")
        ok(E.Mirror.savedText():find("^Saved for offline · "), "says when: " .. E.Mirror.savedText())
        -- Offline: every page of the shelf's list, and every page of a series it never opened.
        W.wifi, cache.strict_offline = false, true
        cache.connects = 0
        local before = #W.shown
        for p = 1, 3 do
            local b, err = offlineRead(cat, client, pagePath(cat, { sort = "recently_added" }, p, 12))
            ok(b and #b.items == (p < 3 and 12 or 6), "recently added page " .. p .. ": " .. tostring(err))
        end
        for p = 1, 2 do
            local b, err = offlineRead(cat, client, pagePath(cat, cat:paramsForEntry("series", { seriesId = 4 }), p, 20))
            ok(b and b.items[1] and b.items[1].id == 1000 + (p - 1) * 20 + 1, "series page " .. p .. ": " .. tostring(err))
        end
        local b = offlineRead(cat, client, "/koreader/plugin/catalog/sections/series?offset=0&size=11")
        ok(b and b.items[1].seriesId == 4, "the series index")
        ok(cache.connects == 0 and #W.shown == before, "never asked to connect")
        -- A search offline only says it needs a connection.
        local notes = {}
        E.OC.note = function(t) table.insert(notes, t) end
        offlineRead(cat, client, "/koreader/plugin/catalog/books?q=dune&page=1&size=12")
        ok(notes[1] == "Search needs a connection" and #W.shown == before, "search: " .. tostring(notes[1]))
        W.wifi, cache.strict_offline = true, nil
    end)
    cacheTeardown()
end)

test("cache: offline, a search answers from the saved books (title, author, series); the UI thread decodes only the page it shows", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    cache.server_fn = libraryServer({ n_books = 60, series4 = 3 })
    local cat = pluginCatalog(Cat, client)
    withHost(cat, function()
        client:request("GET", DASH)
        E.OC.fullRefresh(cat); run(600)
        W.wifi, cache.strict_offline = false, true
        cache.connects = 0
        local b
        local decode, biggest = E.Cache.decode, 0
        E.Cache.decode = function(str)
            if type(str) == "string" and not W.in_companion and #str > biggest then biggest = #str end
            return decode(str)
        end
        b = offlineRead(cat, client, "/koreader/plugin/catalog/books?q=b1&page=1&size=5")
        E.Cache.decode = decode
        -- B1, B10..B19: 11 books, the first page of 5.
        ok(b and b.total == 11 and #b.items == 5 and b.hasNext == true, "found: " .. tostring(b and b.total))
        ok(biggest < 4 * 1024, "decoded only what it shows: " .. biggest .. " bytes")
        b = offlineRead(cat, client, "/koreader/plugin/catalog/books?q=b1&page=3&size=5")
        ok(b and #b.items == 1 and b.hasNext == false, "the last page")
        ok(cache.connects == 0, "never asked to connect")
        W.wifi, cache.strict_offline = true, nil
    end)
    cacheTeardown()
end)

test("cache: a series gains a 21st book -> Refresh rechecks every saved page and shows it", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    local lib = { n_books = 5, series4 = 20 }
    cache.server_fn = libraryServer(lib)
    local cat = pluginCatalog(Cat, client)
    withHost(cat, function()
        client:request("GET", DASH)
        E.OC.fullRefresh(cat); run(600)
        local series = cat:paramsForEntry("series", { seriesId = 4 })
        W.wifi = false
        local b = offlineRead(cat, client, pagePath(cat, series, 2, 20))
        ok(b and #b.items == 0 and b.total == 20, "20 books before")
        W.wifi = true
        lib.series4 = 21
        cache.calls = {}
        E.OC.refresh(cat); run(600)
        local rechecked = 0
        for _, c in ipairs(cache.calls) do if c:find("size=100") then rechecked = rechecked + 1 end end
        ok(rechecked == 7, "every saved page rechecked (five section indexes, the series and all books): " .. rechecked)
        W.wifi = false
        b = offlineRead(cat, client, pagePath(cat, series, 2, 20))
        ok(b and #b.items == 1 and b.items[1].id == 1021 and b.total == 21, "the 21st book: " .. tostring(b and b.total))
        W.wifi = true
    end)
    cacheTeardown()
end)

test("cache: a Full refresh is manual only, even after the old TTL", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    cache.server_fn = libraryServer({ n_books = 3, series4 = 2 })
    local cat = pluginCatalog(Cat, client)
    withHost(cat, function()
        client:request("GET", DASH)
        E.OC.fullRefresh(cat); run(600)
        local first = E.Mirror.status().at
        ok(first, "saved once")
        W.clock = W.clock + 30 * 86400
        E.Mirror.tick("network up"); run(600)
        ok(E.Mirror.status().at == first, "no scheduled Full refresh")
    end)
    cacheTeardown()
end)

test("cache: Home's first paint after a progress write comes from this cache with the reader's book on it; no second full paint", function()
    local saved_body = { continueReading = { { id = 7, progressPercentage = 1 } } }
    local client, Cat = cacheSetup(function(Cat)
        function Cat:initialDashboardContext() lf.saved_paint = true; return {}, { kind = "dashboard", dashboard = saved_body, stale = true } end
        function Cat:dashboardRootFetch(opts)
            local b = self.client:request("GET", DASH)
            if not b then return {}, { kind = "dashboard", unavailable = true } end
            return {}, { kind = "dashboard", dashboard = b }
        end
        function Cat:refreshOnDevice() if lf.maps then self.on_device = lf.maps; return true end self:hydrateOnDeviceMaps(); return false end
        function Cat:hydrateOnDeviceMaps() lf.hydrating = true end
    end)
    W.wifi = true
    local book = cache.dir .. "/book7.epub"
    io.open(book, "w"):close()
    cache.server[DASH] = { continueReading = { { id = 7, progressPercentage = 40 } }, generatedAt = "1" }
    client:request("GET", DASH); run(1)
    -- An earlier BookOrbit session knew book 7 is on the reader.
    local old = setmetatable({ client = client, on_device = { [7] = book } }, Cat)
    E.LF.keepOnDevice(old)
    -- Reading moved the book on; the write marks Home stale.
    client:request("PUT", "/koreader/plugin/syncs/progress", { percentage = 0.5 })
    run(1)
    -- A new BookOrbit view: its plugin maps are gone (every state flush drops them).
    lf.maps, lf.full_paint, lf.stock_switch = nil, 0, 0
    local cat = setmetatable({ client = client }, Cat)
    cat:refreshOnDevice()
    ok(cat.on_device and cat.on_device[7] == book, "book 7 is on the reader before BookOrbit's own maps are back (Resume, not Download)")
    local items, ctx = cat:initialDashboardContext()
    ok(not lf.saved_paint and ctx.orbit_first and ctx.dashboard.continueReading[1].progressPercentage == 40, "first paint from this cache")
    cat:switchTo("Home", items, ctx, false)
    ok(lf.stock_switch == 1, "one full paint")
    -- The open-time refresh: the stale Home is checked; only the server's clock moved.
    cache.server[DASH] = { continueReading = { { id = 7, progressPercentage = 40 } }, generatedAt = "2" }
    withHost(cat, function()
        cat._board_ctx, cat._board_tiles = { d = {} }, { { item = { type = "hero" } } }
        cache.calls = {}
        local _, c2 = cat:dashboardRootFetch({})
        run(5)
        ok(#cache.calls == 1, "checked once: " .. table.concat(cache.calls, ","))
        ok(cache.reloaded == nil, "unchanged (generatedAt only): no redraw")
        -- BookOrbit's maps come back the same: no repaint.
        lf.maps = { [7] = book }
        cat:refreshOnDevice()
        cat:updateItems(nil, true)
        ok(lf.full_paint == 0 and lf.stock_switch == 1, "no second full paint")
    end)
    cacheTeardown()
end)

-- The thumbnail worker as the pinned plugin runs it (bookorbit_catalog_thumbnails.lua:368-408):
-- a batch in the API's child process, each cover through downloadCatalogThumbnail, an ok table
-- back; the parent marks each one there (:333-343) and the tile draws from the file.
local function coverWorker(client, jobs)
    local done, r = client:runInSubprocess(function()
        local outcome = {}
        for _, j in ipairs(jobs) do
            local ok_, err = client:downloadCatalogThumbnail(j.id, j.path, { temp_path = j.path .. ".part", max_bytes = 4e6, background = false })
            outcome[tostring(j.id)] = ok_ == true
        end
        return outcome
    end)
    return done and r.body or nil, r and r.err
end

local function coverServer(answers)
    local http = require("socket.http")
    local ltn = require("ltn12")
    local saved = { http.request, ltn.sink.file }
    ltn.sink.file = function(f) return function(chunk) if chunk then f:write(chunk) end return 1 end end
    http.request = function(t)
        local id = tonumber(t.url:match("/books/(%d+)/thumbnail"))
        local a = answers[id] or { code = "timeout" }
        if a.code == 304 and t.headers["If-None-Match"] == a.etag then return 1, 304, {} end
        if a.code == "timeout" then return nil, "timeout" end
        local body = "\255\216\255\224" .. string.rep("c", 30 + id)
        t.sink(body); t.sink(nil)
        return 1, 200, { ["content-type"] = "image/jpeg", etag = a.etag or '"e"', ["content-length"] = tostring(#body) }
    end
    return function() http.request, ltn.sink.file = saved[1], saved[2] end
end

test("covers: the plugin's worker in its child process: 200, 304 and an error; the drawn tiles have their files", function()
    local client = cacheSetup()
    W.wifi = true
    local dir = cache.dir .. "/covers"
    -- Book 2 has an older version with its ETag; the server's cover is the same (304).
    local old2 = dir .. "/2_100.jpg"
    local fh = io.open(old2, "wb"); fh:write("\255\216\255\224old"); fh:close()
    fh = io.open(old2 .. ".etag", "w"); fh:write('"two"'); fh:close()
    local restore = coverServer({ [1] = { code = 200, etag = '"one"' }, [2] = { code = 304, etag = '"two"' }, [3] = { code = "timeout" } })
    local jobs = { { id = 1, path = dir .. "/1_100.jpg" }, { id = 2, path = dir .. "/2_200.jpg" }, { id = 3, path = dir .. "/3_100.jpg" } }
    local out, err = coverWorker(client, jobs)
    restore()
    ok(out and not cache.child_crash, "the worker's batch answered: " .. tostring(err) .. " " .. tostring(cache.child_crash))
    ok(out["1"] and out["2"] and not out["3"], "1 and 2 ok, 3 failed")
    ok(io.open(jobs[1].path) and io.open(jobs[2].path), "tiles 1 and 2 draw from their files")
    ok(io.open(old2), "the older version of 2 is still there for an older body")
    ok(not io.open(jobs[3].path), "3 retries later")
    cacheTeardown()
end)

test("covers: Full refresh re-asks the covers on screen through the companion, never a forked child", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    local dir = cache.dir .. "/covers"
    local books = {}
    for id = 1, 3 do
        books[id] = { id = id, hasCover = true, updatedAt = "100" }
        local f = io.open(dir .. "/" .. id .. "_100.jpg", "wb"); f:write("\255\216\255\224v1"); f:close()
        if id < 3 then f = io.open(dir .. "/" .. id .. "_100.jpg.etag", "w"); f:write('"c' .. id .. '"'); f:close() end
    end
    local function pathOf(b) return dir .. "/" .. b.id .. "_" .. tostring(b.updatedAt) .. ".jpg" end
    function Cat:thumbnailPath(b) return pathOf(b) end
    cache.server[DASH] = { continueReading = books }
    local cat = setmetatable({ client = client, current_context = { kind = "dashboard", dashboard = cache.server[DASH] } }, Cat)
    function cat:refreshCurrent() self.client:request("GET", DASH) end
    local redrawn = 0
    function cat:updateItems() redrawn = redrawn + 1 end
    -- Book 2's cover changed on the server; book 1's didn't (304). Book 3 has no ETag: left alone.
    FC.cover = function(c) return c.id == 2 and 200 or 304 end
    local calls, forks, bg_run = #FC.calls, {}, E.Background.run
    E.Background.run = function(name, ...) table.insert(forks, name); return bg_run(name, ...) end
    W.broadcasts = {}
    withHost(cat, function() E.OC.fullRefresh(cat); run(30) end)
    E.Background.run = bg_run
    local ask = lastBroadcast(".RECHECK")
    ok(ask and ask.extras.ids == "1\n2" and ask.extras.paths == pathOf(books[1]) .. "\n" .. pathOf(books[2]), "the companion is asked for 1 and 2: " .. tostring(ask and ask.extras.ids))
    local rechecked = {}
    for i = calls + 1, #FC.calls do if FC.calls[i]:find("^RECHECK") then table.insert(rechecked, FC.calls[i]) end end
    ok(#rechecked == 2, "the companion re-asked both: " .. table.concat(rechecked, ","))
    for _, name in ipairs(forks) do ok(name == "cache index", "no forked child but the index save: " .. name) end
    local log = table.concat(W.logs, "\n")
    ok(log:find("cache: covers re-asked: 2 checked, 1 replaced", 1, true), "logged")
    ok(redrawn >= 1, "the view redrawn for the replaced cover")
    FC.cover = nil
    cacheTeardown()
end)

test("covers: Full refresh and Refresh with every cover 304 never paint a tile without its cover", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    local dir = cache.dir .. "/covers"
    local books = {}
    for id = 1, 3 do
        books[id] = { id = id, hasCover = true, updatedAt = "200" }
        local f = io.open(dir .. "/" .. id .. "_100.jpg", "wb"); f:write("\255\216\255\224v1"); f:close()
        f = io.open(dir .. "/" .. id .. "_100.jpg.etag", "w"); f:write('"c' .. id .. '"'); f:close()
    end
    local function pathOf(b) return dir .. "/" .. b.id .. "_" .. tostring(b.updatedAt) .. ".jpg" end
    function Cat:thumbnailPath(b) return pathOf(b) end
    function Cat:cachedThumbnailPath(b) local f = io.open(pathOf(b)); if f then f:close(); return pathOf(b) end end
    local blank = {}
    local stock_switch = Cat.__orbit_stock["cache:switchTo"]
    -- Every paint: each listed cover that the tile would draw must be on disk.
    local function check(context)
        for _, b in ipairs((context.dashboard or {}).continueReading or {}) do
            if not io.open(pathOf(b)) then table.insert(blank, b.id .. "@" .. tostring(b.updatedAt)) end
        end
    end
    local inner = Cat.__orbit_stock["lf:switchTo"]
    Cat.__orbit_stock["lf:switchTo"] = function(self, title, items, context, push) check(context); return inner(self, title, items, context, push) end
    local restore = coverServer({ [1] = { code = 304, etag = '"c1"' }, [2] = { code = 304, etag = '"c2"' }, [3] = { code = 304, etag = '"c3"' } })
    -- The server's body names version 200; the plugin's saved body still names 100.
    cache.server[DASH] = { continueReading = { books[1], books[2], books[3] } }
    local cat = setmetatable({ client = client, current_context = { kind = "dashboard", dashboard = cache.server[DASH] } }, Cat)
    function cat:refreshCurrent()
        local b = self.client:request("GET", DASH)
        self:switchTo("Home", {}, { kind = "dashboard", dashboard = b, orbit_refresh = true }, false)
    end
    withHost(cat, function()
        -- The worker fetches version 200 of each: 304s, copied beside version 100.
        coverWorker(client, { { id = 1, path = pathOf(books[1]) }, { id = 2, path = pathOf(books[2]) }, { id = 3, path = pathOf(books[3]) } })
        cat:switchTo("Home", {}, cat.current_context, false)
        E.OC.fullRefresh(cat); run(600)
        E.OC.refresh(cat); run(600)
        -- A refresh that couldn't reach the server brings back the saved body (version 100).
        local saved = { continueReading = { { id = 1, hasCover = true, updatedAt = "100" }, { id = 2, hasCover = true, updatedAt = "100" } } }
        cat:switchTo("Home", {}, { kind = "dashboard", dashboard = saved, stale = true }, false)
    end)
    restore()
    Cat.__orbit_stock["lf:switchTo"] = inner
    ok(#blank == 0, "no tile painted without its cover: " .. table.concat(blank, ","))
    cacheTeardown()
end)

test("wifi: just in time keeps Wi-Fi on while BookOrbit's Home is over the book, and while the cache works", function()
    local WP = E.WifiPlan
    local st = WP.new("jit", 2, 0)
    st.mode, st.foreground, st.in_book, st.last_flow, st.release_at, st.last_activity = "jit", true, true, "wake", 10, 100
    local a, why = WP.decide(st, { now = 20, wifi_on = true, browsing = false })
    ok(a == "off" and why:find("done in a book"), "reading: off after the wake (" .. tostring(why) .. ")")
    a, why = WP.decide(st, { now = 20, wifi_on = true, browsing = true })
    ok(a == nil, "BookOrbit's Home over the book: kept (" .. tostring(why) .. ")")
    a = WP.decide(st, { now = 100 + 121, wifi_on = true, browsing = true })
    ok(a == "off", "idle there for the just-in-time time: off")
    E.OC.inflight = { k = { key = "k", at = 0 } }
    local busy, bwhy = E.Wifi.busy()
    ok(busy and bwhy:find("cache"), "a cache check out at the companion keeps it: " .. tostring(bwhy))
    E.OC.inflight = {}
end)

test("suspend: a Home press (app switch) with the book unmoved skips BookOrbit's snapshot; a page turn, Sync and sleep always snapshot", function()
    local snaps = 0
    local p = { last_page = 10 }
    function p:getDocumentDigest() return "d1" end
    function p:getLastPercent() return 0.25 end
    function p:_onSuspend() snaps = snaps + 1 end
    p.onSuspend = p._onSuspend
    local ui = { annotation = { annotations = {} }, doc_settings = { readSetting = function() return { status = "reading" } end } }
    local hosts, inter = E.bookorbit, E.Jni.isInteractive
    E.bookorbit = function() return p end
    E.Jni.isInteractive = function() return true end
    E.state.last_snapshot_key = nil
    local self = setmetatable({ ui = ui }, { __index = E.OrbitAndroid })
    self:hookSuspendSnapshot()
    p:onSuspend(); p:onSuspend(); p:onSuspend()
    ok(snaps == 1, "three Home presses, one snapshot: " .. snaps)
    p.last_page = 11
    p:onSuspend()
    ok(snaps == 2, "a page turned: snapshot")
    E.state.force_snapshot = true; p:_onSuspend(); E.state.force_snapshot = nil
    ok(snaps == 3, "Sync and sleep: always")
    E.bookorbit, E.Jni.isInteractive = hosts, inter
end)

test("remove: with a book open (no file browser) BookOrbit's remove asks through KOReader's delete; the open book stays", function()
    local asked, deleted = {}, {}
    local FM = { instance = nil }
    function FM:showDeleteFileDialog(path, after) table.insert(asked, path); if self:deleteFile(path, true) and after then after() end end
    function FM:deleteFile(path) table.insert(deleted, path); return true end
    local RUI = { instance = { document = { file = "/books/open.epub" } } }
    local saved_fm, saved_rui = package.loaded["apps/filemanager/filemanager"], package.loaded["apps/reader/readerui"]
    package.loaded["apps/filemanager/filemanager"], package.loaded["apps/reader/readerui"] = FM, RUI
    local errors = {}
    package.loaded["bookorbit_toast"] = { error = function(t) table.insert(errors, t) end, show = function() end }
    local Peek = {}
    -- As bookorbit_book_peek.lua:156-167.
    function Peek.remove(catalog, path)
        local fm = require("apps/filemanager/filemanager").instance
        if not fm or not fm.showDeleteFileDialog then
            require("bookorbit_toast").error("Open the file browser to remove this book.")
            return
        end
        fm:showDeleteFileDialog(path, function() catalog.refreshed = true end)
    end
    package.loaded["bookorbit_book_peek"] = Peek
    E.LF.installRemove()
    local cat = {}
    Peek.remove(cat, "/books/other.epub")
    ok(asked[1] == "/books/other.epub" and deleted[1] == "/books/other.epub" and cat.refreshed, "asked, deleted, refreshed")
    ok(#errors == 0 and FM.instance == nil, "no 'open the file browser'; no file browser left behind")
    Peek.remove(cat, "/books/open.epub")
    ok(#deleted == 1 and errors[1]:find("This book is open"), "the open book stays: " .. tostring(errors[1]))
    package.loaded["apps/filemanager/filemanager"], package.loaded["apps/reader/readerui"] = saved_fm, saved_rui
    package.loaded["bookorbit_toast"], package.loaded["bookorbit_book_peek"] = nil, nil
end)

test("cache: a progress write leaves no false patch count; Continue reading moves at the next check", function()
    local client = cacheSetup()
    W.wifi = true
    cache.server[DASH] = { continueReading = { { id = 7, progressPercentage = 10 } } }
    client:request("GET", DASH); run(1)
    client:request("PUT", "/koreader/syncs/progress", { document = "d7", percentage = 0.5 })
    run(1)
    ok(FC.count("SELECT count(*) FROM entries WHERE home = 1 AND stale = 1") == 1, "Home marked to check")
    for _, l in ipairs(W.logs) do ok(not l:find("patched 0", 1, true), "no 'patched 0' noise: " .. l) end
    cacheTeardown()
end)


---------------------------------------------------------------- v0.11.2 (M8C test of v0.11.1)

test("lists: All books and Recently updated offer By series and By author; read in 100-book pages, grouped once (v0.11.2)", function()
    package.loaded["bookorbit_catalog"], package.loaded["bookorbit_api"] = LCat, LApi
    newUI(false)
    for _, params in ipairs({ { sort = "title" }, { sort = "recently_updated", order = "desc" } }) do
        lists_server.urls = {}
        W.logs = {}
        local cat = newCatalog(LCat, LApi, { kind = "books", title = params.sort == "title" and "All books" or "Recently updated", params = params })
        local m = cat:listSortSheetModel({})
        ok(m.rows[1].key == "orbit-series" and m.rows[2].key == "orbit-authors", params.sort .. ": the rows are offered")
        cat:listRun({ kind = "orbit-group", section = "series" })
        run(1)
        ok(#lists_server.urls == 3, params.sort .. ": three pages of two: " .. #lists_server.urls)
        for _, u in ipairs(lists_server.urls) do
            ok(u:find("size=100", 1, true) and u:find("sort=title", 1, true) and not u:find("recently", 1, true), "the paged read: " .. u)
        end
        local ctx = cat.current_context
        ok(ctx.section == "series" and ctx.orbit_group and ctx.total == 3, "the Series view of the whole library")
        local grouped, read
        for _, l in ipairs(W.logs) do
            if l:find("lists: grouped 5 books of all by series in", 1, true) then grouped = (grouped or 0) + 1 end
            if l:find("lists: read 5 books of all", 1, true) and l:find(" ms (3 page(s))", 1, true) then read = true end
        end
        ok(grouped == 1 and read, "timed in the log: " .. table.concat(W.logs, " | "))
        -- Page 2 of the view reuses the groups.
        cat:loadSection("series", { replace = true, offset = 2 })
        grouped = 0
        for _, l in ipairs(W.logs) do if l:find("lists: grouped", 1, true) then grouped = grouped + 1 end end
        ok(grouped == 1 and #lists_server.urls == 3, "built once per list")
        -- A row: the server's series page with the list's filters (no ids).
        cat:listRun({ kind = "open-series", entry = cat.current_context.entries[1] })
        ok(cat.loaded.params.ids == nil and cat.loaded.params.orbitGroup, "a series of the library, from the server")
    end
    package.loaded["bookorbit_catalog"], package.loaded["bookorbit_api"] = nil, nil
end)

test("reading gate: BookOrbit over the book is not reading, whatever floats on top; Wi-Fi agrees (v0.11.2)", function()
    RE.Gate.queue = {}
    local ui = newUI(true)
    local cat = { name = "catalog" }
    ui.bookorbit.catalog_browser = cat
    W.shown = {}
    ok(RE.reading(), "the book alone: reading")
    -- Home over the book, under BookOrbit's loading pill (not a toast) and a KOReader message.
    W.shown = { ui, cat, { name = "bookorbit_toast" }, { name = "InfoMessage" } }
    ok(not RE.reading(), "Home over the book with a pill and a message on top: not reading")
    local shown
    RE.Gate.show("BookOrbit show: Full refresh · saving for offline 1/146", function() shown = true end)
    ok(shown and #RE.Gate.queue == 0, "the Full refresh progress shows at once")
    W.shown = { ui, { name = "bookorbit_book_sheet" } }
    ok(not RE.reading(), "a BookOrbit sheet over the book")
    W.shown = { ui, { name = "bookorbit_menu_sheet" }, { name = "bookorbit_confirm" } }
    ok(not RE.reading(), "a BookOrbit menu and dialog over the book")
    W.shown = { ui, { name = "bookorbit_toast" } }
    ok(RE.reading(), "a BookOrbit pill alone over the book: still reading")
    W.shown = { cat, ui }
    ok(RE.reading(), "the book over the catalog: reading")
    -- The Wi-Fi plan's "browsing" is the same test: no "done in a book" off with Home over it.
    W.shown = { ui, cat, { name = "bookorbit_toast" } }
    local hosts = RE.bookorbit
    RE.bookorbit = function() return ui.bookorbit end
    ok(RE.bookorbitOverBook(RE.bookorbit()), "browsing for the Wi-Fi plan")
    local st = RE.WifiPlan.new("jit", 2, 0)
    st.in_book, st.last_flow, st.release_at, st.last_activity = true, "wake", W.clock - 1, W.clock
    local a = RE.WifiPlan.decide(st, { now = W.clock, wifi_on = true, browsing = RE.bookorbitOverBook(RE.bookorbit()) })
    ok(a == nil, "kept on while paging BookOrbit lists over the book")
    RE.bookorbit = hosts
    W.shown = {}
end)

test("mirror: a request with no answer is retried in smaller pages, then skipped; the run goes on (v0.11.2)", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    local base = libraryServer({ n_books = 3, series4 = 2 })
    local asked = {}
    cache.server_fn = function(path)
        -- The series index never answers in pages of 100 (M8C: no answer after 60 s); authors never at all.
        if path:find("/sections/series", 1, true) and path:find("size=100", 1, true) then table.insert(asked, path); return false end
        if path:find("/sections/authors", 1, true) then return false end
        return base(path)
    end
    local cat = pluginCatalog(Cat, client)
    withHost(cat, function()
        client:request("GET", DASH)
        W.logs = {}
        E.OC.fullRefresh(cat)
        run(900)
        local m = E.Mirror.status()
        ok(m.at and m.left == 0, "finished: " .. tostring(m.left) .. " left")
        local function saved(identity) return FC.count("SELECT count(*) FROM lists WHERE identity = ?", identity) == 1 end
        local fifty = false
        for _, c in ipairs(FC.calls) do if c:find("/sections/series?page=1&size=50", 1, true) then fifty = true end end
        ok(saved("/koreader/plugin/catalog/sections/series") and fifty, "the series index saved, asked in pages of 50")
        ok(not saved("/koreader/plugin/catalog/sections/authors") and m.skipped == 1, "authors skipped: " .. tostring(m.skipped))
        -- The retries' log lines are the companion's (CacheWorkerTest "retriedInSmallerPagesThenSkipped").
        local log = table.concat(W.logs, "\n")
        ok(not log:find("paused (offline)", 1, true), "never offline")
        -- Offline, the series index opens from its pages of 50.
        W.wifi, cache.strict_offline = false, true
        local b = offlineRead(cat, client, "/koreader/plugin/catalog/sections/series?offset=0&size=11")
        ok(b and b.items[1].seriesId == 4, "the series index offline")
        W.wifi, cache.strict_offline = true, nil
    end)
    cacheTeardown()
end)

test("mirror: a second Full refresh keeps the run; a paused run resumes at network up, wake or Home (v0.11.2)", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    cache.server_fn = libraryServer({ n_books = 30, series4 = 2 })
    local notes = {}
    E.OC.note = function(t) table.insert(notes, t) end
    local cat = pluginCatalog(Cat, client)
    local _ui, mod = newUI(false)
    FC.rate = 1 -- a slow companion, so the test sees the run mid-way
    withHost(cat, function()
        client:request("GET", DASH)
        E.OC.fullRefresh(cat)
        run(7)
        local m = E.Mirror.status()
        local done, total = m.done, m.total
        ok(E.Mirror.fullRunning() and done > 0, "saving: " .. tostring(done))
        notes = {}
        W.logs = {}
        E.OC.fullRefresh(cat)
        E.OC.fullRefresh(cat)
        m = E.Mirror.status()
        ok(m.done >= done and m.total >= total and m.left > 0, "the run is kept, not restarted")
        local h = E.Badge.history or {}
        ok(#notes == 0 and E.Badge.expanded and (h[#h] or ""):find("^Full refresh · %d+%% · [%d,]+ of [%d,]+"), "the badge opens on its full message: " .. tostring(h[#h]))
        ok(table.concat(W.logs, "\n"):find("Full refresh already running (pressed again); kept", 1, true), "logged")
        -- The network goes mid-run: paused; it comes back: resumed, no read needed.
        W.wifi = false
        run(10)
        ok(not E.Mirror.active and E.Mirror.status().left > 0, "paused offline")
        W.wifi = true
        W.logs = {}
        mod:onNetworkConnected()
        run(900)
        ok(table.concat(W.logs, "\n"):find("mirror: resuming (network up)", 1, true), "resumed at network up: " .. table.concat(W.logs, " | "))
        m = E.Mirror.status()
        ok(m.left == 0 and m.at, "finished")
    end)
    cacheTeardown()
end)

test("mirror: background full runs and resumes never display a badge", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    cache.server_fn = libraryServer({ n_books = 50, series4 = 2 })
    local rate = FC.rate
    FC.rate = 1
    local cat = pluginCatalog(Cat, client)
    withHost(cat, function()
        E.Mirror.cat = cat
        E.Badge.close(); E.Badge.running = nil
        E.Mirror.start("background legacy run", false)
        ok(not E.Badge.running, "background start is silent")
        run(3)
        E.Mirror.manual = nil
        ok(not E.Badge.running, "background polls are silent")
        W.wifi = false; E.Mirror.stop("offline"); run(6)
        W.wifi = true; E.Mirror.tick("network up")
        ok(not E.Badge.running, "background resume is silent")
        run(600)
        ok(not E.Badge.running, "background completion is silent")
    end)
    FC.rate = rate
    cacheTeardown()
end)

test("mirror: Full refresh suppresses loading, errors, direct notices and queued notes", function()
    local old = #W.shown
    local saved_toast = package.loaded["bookorbit_toast"]
    local Toast = { show = function() error("toast escaped") end, error = function() error("error escaped") end, loading = function() error("loading escaped refresh gate") end }
    package.loaded["bookorbit_toast"] = Toast
    E.Gate.installToast()
    E.Mirror.notices = true
    local pill = Toast.loading("Loading book...")
    Toast.loading("Loading EPUB delivery preference…"):close()
    Toast.loading("Updating Home…"):close()
    local detail = E.Badge.long({}, 0)
    ok(detail:find("Loading book...", 1, true) and detail:find("Loading EPUB delivery preference…", 1, true)
        and detail:find("Updating Home…", 1, true), "suppressed loading goes into badge details")
    ok(pill and pill.close, "loading keeps its close handle")
    pill:close()
    Toast.show("saved")
    Toast.error("failed")
    UIManager:show(require("ui/widget/infomessage"):new{ text = "direct notice" })
    E.Gate.show("background result", function() error("notice escaped refresh gate") end)
    ok(#W.shown == old, "no notice appears")
    E.Mirror.notices = nil
    E.Badge.notices = nil
    package.loaded["bookorbit_toast"] = saved_toast
end)

test("mirror: Full refresh saves every book's details, outside the cap; covers only with 'Save every cover' (v0.11.2)", function()
    local client, Cat = cacheSetup(function(Cat)
        function Cat:pruneThumbnailCache() for _, p in ipairs(cache.prune or {}) do os.remove(p) end end
    end)
    W.wifi = true
    cache.server_fn = libraryServer({ n_books = 4, series4 = 2, covers = true })
    local cat = pluginCatalog(Cat, client)
    function cat:thumbnailPath(b) return cache.dir .. "/covers/" .. dofile(here .. "/companion_rules.lua")(E.Cache).coverName(b) end
    withHost(cat, function()
        client:request("GET", DASH)
        client:request("GET", pagePath(cat, { sort = "recently_added" }, 1, 12)) -- Home's shelf
        E.S.mirror_covers = false
        E.OC.fullRefresh(cat); run(900)
        local details = {}
        for _, c in ipairs(cache.calls) do
            local id = c:match("^GET /koreader/plugin/catalog/books/(%d+)")
            if id then details[tonumber(id)] = true end
        end
        ok(details[1] and details[2] and details[3] and details[4], "every listed book's details saved")
        local kept = 0
        for id = 1, 4 do if detailEntry(client, id) then kept = kept + 1 end end
        ok(kept == 4, "every book's detail saved, once: " .. kept)
        ok((E.Mirror.status().cover_total or 0) == 0, "no covers fetched for lists with the setting off: " .. tostring(E.Mirror.status().cover_total))
        -- On: Full refresh fetches every cover the mirror lists, shows them in its progress, and
        -- the plugin's pruner leaves them.
        E.S.mirror_covers = true
        local notes = {}
        E.OC.note = function(t) table.insert(notes, t) end
        FC.rate = 2
        E.OC.fullRefresh(cat); run(900)
        local m = E.Mirror.status()
        ok((m.cover_total or 0) >= 4, "every book's cover queued: " .. tostring(m.cover_total))
        -- One number on screen: the badge's %, never a count per kind; no other note.
        local odd
        for _, t in ipairs(E.Badge.history or {}) do if not (t:match("^%d+%%$") or t == "Done") then odd = t end end
        ok(not odd and #notes <= 1, "only the %: " .. tostring(odd) .. " | " .. table.concat(notes, " | "))
        local a, other = cache.dir .. "/covers/1_1.jpg", cache.dir .. "/covers/999_x.jpg"
        io.open(a, "w"):close(); io.open(other, "w"):close()
        cache.prune = { a, other }
        cat:pruneThumbnailCache()
        ok(io.open(a, "rb") and not io.open(other, "rb"), "a mirrored cover stays, another goes")
        -- Off again: nothing deleted now; the plugin's pruner treats them like any cover.
        E.S.mirror_covers = false
        ok(io.open(a, "rb"), "turning it off deletes nothing")
        cat:pruneThumbnailCache()
        ok(not io.open(a, "rb"), "back under the plugin's cap")
        cache.prune = nil
    end)
    E.S.mirror_covers = nil
    cacheTeardown()
end)

test("copies: a Full refresh and Home look for changed copies; the mirror's details find a changed hash (v0.11.2)", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    local base = libraryServer({ n_books = 3, series4 = 2 })
    cache.server_fn = function(path)
        local id = path:match("/catalog/books/(%d+)%f[^%d]")
        if id then return { id = tonumber(id), files = { { id = tonumber(id) * 10, fileHash = "srv" .. id } } } end
        return base(path)
    end
    local cat = pluginCatalog(Cat, client)
    local whys = {}
    local tick = E.Copies.tick
    E.Copies.tick = function(why) table.insert(whys, why) end
    E.EOB.details = {} -- only what the mirror saved
    withHost(cat, function()
        client:request("GET", DASH)
        client:request("GET", pagePath(cat, { sort = "recently_added" }, 1, 12)) -- Home's shelf
        E.OC.fullRefresh(cat); run(900)
        local all = table.concat(whys, ",")
        ok(all:find("full refresh", 1, true), "Full refresh looks: " .. all)
        whys = {}
        E.Mirror.kick("Home"); run(3)
        ok(whys[1] == "Home", "Home open looks (no catalog read needed): " .. table.concat(whys, ","))
        -- Book 2's copy on the reader has the old hash; its saved detail lists the new one.
        local books = { old2 = { file = "/books/b.epub", bookId = 2, fileId = 20 }, srv3 = { file = "/books/c.epub", bookId = 3, fileId = 30 } }
        local sm = package.loaded["bookorbit_state_manager"]
        package.loaded["bookorbit_state_manager"] = { state = function() return { books = books } end }
        local exists = FC.exists
        FC.exists = function() return true end
        local pump = E.Copies.pump
        E.Copies.pump = function() end
        E.Copies.state().queue, E.Copies.asked = {}, nil
        ok(E.Copies.ask("test"), "asked")
        run(3)
        local q = E.Copies.state().queue
        ok(#q == 1 and q[1].path == "/books/b.epub" and q[1].why == "hash", "the changed copy is found from the mirror's details: " .. #q)
        package.loaded["bookorbit_state_manager"], FC.exists, E.Copies.pump = sm, exists, pump
        E.Copies.state().queue = {}
    end)
    E.Copies.tick = tick
    cacheTeardown()
end)

test("local-first: Home's first paint has the on-device marks; a changed tile names what changed (v0.11.2)", function()
    local client, Cat = cacheSetup(function(Cat)
        function Cat:initialDashboardContext() return {}, { kind = "dashboard", dashboard = {}, stale = true } end
        function Cat:dashboardRootFetch() return {}, { kind = "dashboard", dashboard = self.client:request("GET", DASH) } end
    end)
    W.wifi = true
    cache.server[DASH] = { continueReading = { { id = 7, progressPercentage = 40 } } }
    client:request("GET", DASH)
    local sm = package.loaded["bookorbit_state_manager"]
    package.loaded["bookorbit_state_manager"] = {
        hasOnDeviceMaps = function() return true end,
        onDeviceMaps = function() return { byBookId = { [7] = "/books/seven.epub" }, byFileId = {}, generation = 3 } end,
    }
    local cat = setmetatable({ client = client, on_device = {} }, Cat)
    W.logs = {}
    cat:initialDashboardContext()
    ok(cat.on_device[7] == "/books/seven.epub", "BookOrbit's marks before the first paint (Resume, not Download)")
    ok(table.concat(W.logs, "\n"):find("first paint with BookOrbit's on-device marks for 1 book(s)", 1, true), "logged")
    package.loaded["bookorbit_state_manager"] = sm
    W.logs = {}
    E.LF.logChanged({ { key = 1, kind = "hero" } }, { 1 },
        { continue_reading = { { id = 7, progressPercentage = 40 } } },
        { continue_reading = { { id = 7, progressPercentage = 40, on_device = true } } })
    ok(W.logs[1] and W.logs[1]:find("local-first: tile 1 hero changed: book 7 on device no -> yes", 1, true), "the tile and field: " .. tostring(W.logs[1]))
    cacheTeardown()
end)

test("storage limit: Orbit Companion counts and removes; eligible covers go before browsing data, all in last-shown order; never the saved lists", function()
    local client, Cat = cacheSetup()
    local MB = 1048576
    local lfs = require("libs/libkoreader-lfs")
    local cdir = cache.dir .. "/covers"
    E.OC.cover_dir = cdir
    local covers = { ["a.jpg"] = { 20, 10 }, ["m1.jpg"] = { 20, 3 }, ["m2.jpg"] = { 20, 40 } } -- MB, last seen
    for name in pairs(covers) do io.open(cdir .. "/" .. name, "w"):close() end
    local attributes = lfs.attributes
    lfs.attributes = function(f, k)
        local c = covers[tostring(f):match("^" .. cdir:gsub("%p", "%%%0") .. "/(.+)$") or ""]
        if c and io.open(f, "rb") then
            local a = { mode = "file", size = c[1] * MB, modification = c[2] }
            if k then return a[k] end
            return a
        end
        if k == "size" then return nil end
        return attributes(f, k)
    end
    -- In the database: Home (kept) and two browsing replies, by size and when saved.
    local function entry(key, bytes, at, home)
        FC.db():run("INSERT OR REPLACE INTO entries (key, path, body, fetched_at, validated_at, home, bytes) VALUES (?, ?, ?, ?, ?, ?, ?)",
            key, "/p/" .. key, "{}", at, at, home and 1 or nil, bytes)
    end
    local function has(key) return FC.count("SELECT count(*) FROM entries WHERE key = ?", key) == 1 end
    FC.own(E.OC.owner(client))
    entry("list", 30 * MB, 1, true); entry("old", 30 * MB, 2); entry("new", 30 * MB, 50)
    E.S.mirror_covers = true
    FC.db():run("INSERT INTO cover_keep (name) VALUES ('m1.jpg'), ('m2.jpg')")
    E.S.storage_limit_mb = 100
    W.logs, W.broadcasts = {}, {}
    local asks = FC.storage_asks
    local walks = 0
    local dir = lfs.dir
    lfs.dir = function(d) if not W.in_companion and d == cdir then walks = walks + 1 end return dir(d) end
    E.OC.storageCount("start")
    local b = lastBroadcast(".STORAGE")
    ok(b and b.extras.limit == tostring(100 * MB) and b.extras.cover_dir == cdir and b.extras.mirror_covers == "1", "asked the companion")
    ok(b.extras.userkey == nil, "no login with it")
    run(3)
    ok(FC.storage_asks == asks + 1, "the companion counted")
    ok(walks == 0, "the UI thread never walks the cover folder")
    ok(has("old") and has("new"), "browsing data wins over both cover tiers")
    ok(not io.open(cdir .. "/a.jpg", "rb") and not io.open(cdir .. "/m1.jpg", "rb") and not io.open(cdir .. "/m2.jpg", "rb"), "eligible covers went first")
    ok(E.OC.storage.used == 90 * MB and E.OC.storageText() == "Using 90 MB", "Using: " .. E.OC.storageText())
    ok(table.concat(W.logs, "\n"):find("storage: 150.0 MB of 100 MB (start); removed 0 browsing entries, 1 covers, 2 saved-for-offline covers -> 90.0 MB", 1, true), "logged: " .. table.concat(W.logs, " | "))
    -- Once every eligible cover is gone, expendable browsing pages can go; Home stays.
    E.S.storage_limit_mb = 55
    E.OC.storageCount("limit changed"); run(3)
    ok(not has("old") and not has("new"), "browsing pages go only after eligible covers")
    ok(has("list"), "Home stays")
    -- A write over the limit asks for a count.
    E.S.storage_limit_mb = 60
    entry("big", 40 * MB, 99)
    E.OC.storageAdd(40 * MB, "cache"); run(3)
    ok(not has("big") and E.OC.storage.used == 30 * MB, "checked on the write")
    -- The totals are there at the next start (the database's meta).
    E.OC.storage = nil
    E.OC.client = function() return client end
    ok(E.OC.storageTotals() and E.OC.storageTotals().used == 30 * MB, "read back from the database")
    -- 10 GB crosses the signed 32-bit byte boundary: preserve the limit over IPC and enforce it.
    run(10)
    E.S.storage_limit_mb = 10240
    ok(E.OC.limitBytes() == 10737418240, "10 GB in bytes")
    entry("big", 10240 * MB, 99)
    E.OC.storageCount("limit changed")
    ok(lastBroadcast(".STORAGE").extras.limit == "10737418240", "10 GB reaches the companion intact")
    run(3)
    ok(not has("big") and has("list"), "10 GB limit evicts browsing data, preserving saved data")
    -- No limit: nothing goes.
    run(10) -- drain the startup count before changing its limit
    E.S.storage_limit_mb = 0
    entry("big", 900 * MB, 99)
    E.OC.storageCount("limit changed"); run(3)
    ok(has("big"), "no limit")
    run(10) -- the plugin's own count at start
    -- Without the companion of this version nothing is counted on the UI thread.
    cache.worker_problem = "Orbit Companion needed"
    local n = FC.storage_asks
    E.OC.storageCount("count"); run(3)
    ok(FC.storage_asks == n and walks == 0, "nothing counted")
    cache.worker_problem = nil
    lfs.attributes, lfs.dir = attributes, dir
    E.S.mirror_covers, E.S.storage_limit_mb = nil, 250
    cacheTeardown()
end)

test("storage limit: it stops the every-cover pass, then the run, and the Full refresh note says so (v0.11.2)", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    cache.server_fn = libraryServer({ n_books = 4, series4 = 2, covers = true })
    local cat = pluginCatalog(Cat, client)
    function cat:thumbnailPath(b) return cache.dir .. "/covers/" .. dofile(here .. "/companion_rules.lua")(E.Cache).coverName(b) end
    local MB = 1048576
    local notes = {}
    E.OC.note = function(t) table.insert(notes, t) end
    local batch = FC.COVER_BATCH
    FC.COVER_BATCH = 1
    E.S.mirror_covers, E.S.storage_limit_mb = true, 1
    local kept = 0.2 * MB
    -- What else counts (the companion counts it at the run's start: here a kept entry of that size);
    -- each cover the companion saves is 0.4 MB.
    FC.cover_bytes = 0.4 * MB
    local function keptEntry()
        FC.db():run("INSERT OR REPLACE INTO entries (key, path, body, fetched_at, validated_at, home, bytes) VALUES ('k', '/p', '{}', 1, 1, 1, ?)", kept)
    end
    local items = FC.storageItems
    FC.storageItems = function(...)
        keptEntry()
        return items(...)
    end
    withHost(cat, function()
        client:request("GET", DASH)
        client:request("GET", pagePath(cat, { sort = "recently_added" }, 1, 12))
        W.logs = {}
        E.OC.fullRefresh(cat); run(900)
        local m = E.Mirror.status()
        local note = m.limit_note and m.limit_note.text or ""
        ok(note:find("^Storage limit reached: %d+ of %d+ covers saved%. No room for new data; protected covers are kept%. Raise the limit in Orbit settings%.$"), "the stop: " .. note)
        local shown
        for _, t in ipairs(E.Badge.history or {}) do if t == note then shown = true end end
        ok(shown, "the badge says it: " .. table.concat(E.Badge.history or {}, " | "))
        local c = m.covers
        ok((c.ok or 0) + (c.not_modified or 0) + (c.failed or 0) == 2, "two covers, then the pass stopped")
        ok(m.left == 0 and m.at, "the lists and details went on to the end")
        ok(E.Mirror.savedText():find("storage limit reached", 1, true), "the menu line says so")
        -- Lists and details alone fill it: the whole run stops.
        kept = 2 * MB
        notes = {}
        E.OC.fullRefresh(cat); run(900)
        m = E.Mirror.status()
        note = m.limit_note and m.limit_note.text or ""
        ok(note:find("^Storage limit reached: 0 of %d+ lists and books saved"), "the run stops: " .. note)
        local h = E.Badge.history or {}
        ok(m.left == 0 and h[#h] == note, "shown: " .. table.concat(h, " | "))
    end)
    FC.storageItems, FC.COVER_BATCH = items, batch
    E.S.mirror_covers, E.S.storage_limit_mb = nil, 250
    cacheTeardown()
end)

---------------------------------------------------------------- v0.11.3: the mirror off the UI thread
-- (docs/design/companion-worker.md). On the M8C, v0.11.3 showed "KOReader isn't responding": the
-- mirror's queue (5262 jobs) lived in the cache's index, which the UI thread re-encoded after
-- every saved item. These guard the UI thread: nothing of the mirror runs or is encoded there.

-- Records Cache.encode and Cache.decode on the UI thread (W.in_child unset) while fn runs: the
-- largest string either made or read, in bytes.
local function uiEncodes(fn)
    local encode, decode, biggest, n = E.Cache.encode, E.Cache.decode, 0, 0
    E.Cache.encode = function(v, depth)
        local out = encode(v, depth)
        if not depth and not W.in_child and not W.in_companion then
            n = n + 1
            if #out > biggest then biggest = #out end
        end
        return out
    end
    E.Cache.decode = function(str)
        if type(str) == "string" and not W.in_child and not W.in_companion and #str > biggest then biggest = #str end
        return decode(str)
    end
    local okf, err = pcall(fn)
    E.Cache.encode, E.Cache.decode = encode, decode
    if not okf then error(err, 0) end
    return biggest, n
end

test("mirror: a Full refresh of a big library does no request, entry write or queue encode on the UI thread (v0.11.3)", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    cache.server_fn = libraryServer({ n_books = 450, series4 = 30 })
    local on_ui = {}
    local rb = client.requestBlocking
    client.requestBlocking = function(self, method, path, ...)
        if path:find("size=100", 1, true) or path:find("/catalog/books/%d") then
            if not W.in_child then table.insert(on_ui, path) end
        end
        return rb(self, method, path, ...)
    end
    local cat = pluginCatalog(Cat, client)
    withHost(cat, function()
        client:request("GET", DASH)
        client:request("GET", pagePath(cat, { sort = "recently_added" }, 1, 12)) -- Home's shelf
        local biggest = uiEncodes(function()
            E.OC.fullRefresh(cat)
            run(1200)
        end)
        local m = E.Mirror.status()
        ok(m.at and m.left == 0 and m.total > 450, "finished: " .. tostring(m.done) .. "/" .. tostring(m.total))
        ok(#on_ui == 0, "every mirror request ran in the worker: " .. table.concat(on_ui, " | "))
        -- The UI thread encodes only small things (a browsing entry, a log line's data): never the
        -- queue or the index, whatever the library's size.
        ok(biggest < 8 * 1024, "largest encode on the UI thread: " .. biggest .. " bytes")
        ok(not io.open(cache.dir .. "/index.lua", "rb"), "no index: the plugin keeps nothing of the cache but a few lines of its own")
    end)
    client.requestBlocking = rb
    cacheTeardown()
end)

test("mirror: lists are saved before details, so the total stops growing once the lists are in (v0.11.3)", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    cache.server_fn = libraryServer({ n_books = 120, series4 = 30 })
    local cat = pluginCatalog(Cat, client)
    local order, totals = {}, {}
    withHost(cat, function()
        client:request("GET", DASH) -- Home: book 7 is a seed (Continue reading)
        client:request("GET", pagePath(cat, { sort = "recently_added" }, 1, 12)) -- Home's shelf
        E.OC.fullRefresh(cat)
        run(1200)
        for _, t in ipairs(FC.trace) do
            if t.k == "page" or t.k == "detail" then table.insert(order, t.k == "page" and "list" or "detail"); table.insert(totals, t.total) end
        end
        local last_list, first_detail = 0, nil
        for i, k in ipairs(order) do
            if k == "list" then last_list = i end
        end
        -- The seed's detail comes first; after it, no detail before the last list page.
        for i, k in ipairs(order) do if k == "detail" and i > 2 then first_detail = first_detail or i end end
        ok(first_detail and first_detail > last_list, "lists " .. last_list .. ", first detail " .. tostring(first_detail))
        local final = E.Mirror.status().total
        local grew_after = false
        for i = last_list + 1, #totals do if totals[i] ~= final then grew_after = true end end
        ok(not grew_after and final > 120, "the total held at " .. tostring(final) .. " once the lists were saved")
    end)
    cacheTeardown()
end)

test("cache: a background check of a big page compares and saves it in the child; the UI thread never handles the body (v0.11.3)", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    local function shelf(n)
        local items = {}
        for i = 1, 400 do items[i] = { id = i, title = string.rep("T", 40) .. i, progressPercentage = n } end
        return { continueReading = items }
    end
    cache.server[DASH] = shelf(1)
    client:request("GET", DASH); run(1)
    local cat = setmetatable({ current_context = { kind = "dashboard", dashboard = {} }, client = client }, Cat)
    cat:switchTo("Home", {}, cat.current_context, false)
    cache.server[DASH] = shelf(2)
    W.clock = W.clock + 61
    W.logs = {}
    -- The read decodes the one reply it serves (from the database); the check is the companion's.
    client:request("GET", DASH)
    local biggest = uiEncodes(function() run(10) end)
    ok(table.concat(W.logs, "\n"):find("checked: changed", 1, true), "checked and changed: " .. table.concat(W.logs, " | "))
    ok(biggest < 8 * 1024, "the UI thread handled at most " .. biggest .. " bytes")
    local e = E.Store.read(E.OC.owner(client), E.Cache.key({ account = E.OC.owner(client), server = client.server_url, method = "GET", path = DASH }), DASH)
    ok(e and e.body.continueReading[1].progressPercentage == 2, "the new page is saved")
    cacheTeardown()
end)

test("mirror: the Full refresh badge: a popup at the start, then one % that only rises, redrawn at most every 3 s, Done at the end; no other note (rc.6)", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    cache.server_fn = libraryServer({ n_books = 450, series4 = 30 })
    local cat = pluginCatalog(Cat, client)
    local notes = {}
    E.OC.note = function(t) table.insert(notes, t) end
    local popups = {}
    local orbitNote = E.orbitNote
    E.orbitNote = function(t, timeout) table.insert(popups, { text = t, timeout = timeout }) end
    local dirties, shown, closed = {}, 0, 0
    local setDirty, show, close = UIManager.setDirty, UIManager.show, UIManager.close
    UIManager.setDirty = function(self, w, how, ...)
        if w == E.Badge.widget then table.insert(dirties, { at = W.clock, region = type(how) == "function" and select(2, how()) or nil }) end
        return setDirty(self, w, how, ...)
    end
    UIManager.show = function(self, w, ...) if type(w) == "table" and w.name == "orbit_refresh_badge" then shown = shown + 1 end return show(self, w, ...) end
    UIManager.close = function(self, w, ...) if type(w) == "table" and w.name == "orbit_refresh_badge" then closed = closed + 1 end return close(self, w, ...) end
    FC.rate = 7 -- a run of about a minute and a half: many polls
    E.Badge.history = {}
    withHost(cat, function()
        client:request("GET", DASH)
        client:request("GET", pagePath(cat, { sort = "recently_added" }, 1, 12))
        E.OC.fullRefresh(cat)
        run(1200)
        local m = E.Mirror.status()
        ok(m.at and m.left == 0 and m.total > 450, "finished: " .. tostring(m.done) .. "/" .. tostring(m.total))
        ok(#popups == 1 and popups[1].text:find("^Full refresh in progress · about %d+%% done · you can keep reading and browsing while it loads$"), "one popup: " .. tostring(popups[1] and popups[1].text))
        ok(#notes == 0, "no other note: " .. table.concat(notes, " | "))
        local h, last = E.Badge.history, -1
        ok(#h > 5, "the % moved along: " .. table.concat(h, " "))
        for i, t in ipairs(h) do
            local p = tonumber(t:match("^(%d+)%%$"))
            if i < #h then
                ok(p and p >= last and p < 100, "one number, only rising, 100 only at the end: " .. table.concat(h, " "))
                last = p or last
            end
        end
        ok(h[#h] == "Done", "Done at the end: " .. tostring(h[#h]))
        ok(shown == 1, "one badge, changed in place: " .. shown)
        for i = 2, #dirties do ok(dirties[i].at - dirties[i - 1].at >= E.Badge.EVERY_S or i == #dirties, "at most every 3 s") end
        ok(dirties[1] and dirties[1].region and dirties[1].region.w and dirties[1].region.w < 600, "only its rectangle redrawn")
        run(E.Badge.DONE_S + 1)
        ok(closed == 1 and E.Badge.widget == nil, "then it goes")
        ok(E.Cache.count(8551) == "8,551" and E.Cache.count(512) == "512" and E.Cache.count(1234567) == "1,234,567", "thousands")
    end)
    -- A tap outside a book unfolds it to the full message; in a book it stays passive.
    E.Badge.running = true; E.Badge.pct = 40; E.Badge.status = { done = 400, total = 1000, eta_s = 600, errors = 2 }
    E.Badge.draw()
    E.Badge.toggle()
    local h = E.Badge.history
    ok(h[#h] == "Full refresh · 40% · 400 of 1,000 · about 10 min left · 2 errors", "unfolded: " .. h[#h])
    E.Badge.toggle()
    ok(h[#h] == "40%", "folded")
    E.Badge.running = nil; E.Badge.close()
    UIManager.setDirty, UIManager.show, UIManager.close = setDirty, show, close
    E.orbitNote = orbitNote
    cacheTeardown()
end)

test("companion: the cache worker needs the companion of the plugin's own version; nothing runs in KOReader without it", function()
    local client, Cat = cacheSetup()
    W.wifi = true
    cache.server_fn = libraryServer({ n_books = 3, series4 = 2 })
    local cat = pluginCatalog(Cat, client)
    E.Companion.workerProblem = cache.real_workerProblem
    client.userkey = "s3cret-Key-9f2"
    local file = { version = E.PATCH_VERSION }
    local readFile = E.Companion.readFile
    E.Companion.readFile = function() return file end
    local function fresh() E.installed_cache.at, E.Companion.version_at = -1000, nil end
    local function mirrors() local n = 0; for _, b in ipairs(W.broadcasts) do if b.action:match("%.MIRROR$") then n = n + 1 end end return n end
    local function checks() local n = 0; for _, b in ipairs(W.broadcasts) do if b.action:match("%.CHECK$") then n = n + 1 end end return n end
    withHost(cat, function()
        client:request("GET", DASH)
        -- Missing: no run, no check, and the menu line says what is needed.
        W.companion = false; fresh()
        W.broadcasts = {}
        local notes = {}
        E.OC.note = function(t) table.insert(notes, t) end
        E.OC.fullRefresh(cat); run(30)
        ok(mirrors() == 0 and not E.Mirror.active, "no run without the companion: " .. mirrors() .. " " .. tostring(E.Mirror.active))
        ok(E.Mirror.savedText() == "Orbit Companion needed to save BookOrbit for offline", "menu: " .. E.Mirror.savedText())
        ok(table.concat(notes, "|"):find("Orbit Companion needed", 1, true), "said when pressed: " .. table.concat(notes, " | "))
        W.clock = W.clock + 61
        cache.calls = {}
        client:request("GET", DASH); run(5)
        ok(checks() == 0 and #cache.calls == 0, "no background check either: " .. table.concat(cache.calls, ","))
        -- Another version: update it.
        W.companion = true; file = { version = "0.0.1" }; fresh()
        ok(E.Mirror.savedText():find("^Update Orbit Companion to " .. E.PATCH_VERSION:gsub("%p", "%%%0") .. " to save BookOrbit for offline %(it is 0%.0%.1%)$"), "menu: " .. E.Mirror.savedText())
        E.OC.fullRefresh(cat); run(30)
        ok(mirrors() == 0, "no run with another version")
        -- The same version: the run goes to the companion, with the login in the broadcast only.
        file = { version = E.PATCH_VERSION }; fresh()
        W.logs = {}
        E.OC.fullRefresh(cat); run(600)
        ok(mirrors() == 1 and E.Mirror.status().at, "run by the companion")
        local b
        for _, x in ipairs(W.broadcasts) do if x.action:match("%.MIRROR$") then b = x end end
        ok(b.package == "net.fledgewing.orbitcompanion" and b.extras.userkey == client.userkey and b.extras.user == client.username
            and b.extras.server == client.server_url, "the login goes to the companion's package")
        local plan = io.open(cache.dir .. "/mirror/plan.lua", "rb"):read("*a")
        ok(not plan:find(client.userkey, 1, true) and not plan:find("userkey", 1, true), "never in the plan file")
        local decoded = E.Cache.decode(plan)
        ok(decoded.cover_width > 0 and decoded.cover_height > 0, "device thumbnail bounds travel in the plan")
        local counted = false
        for _, x in ipairs(W.broadcasts) do
            if x.action:match("%.STORAGE$") and x.extras.reason == "after refresh" then counted = true end
        end
        ok(counted, "run completion requests live totals instead of adding replacement bytes")
        local log = table.concat(W.logs, "\n")
        ok(not log:find(client.userkey, 1, true), "never in the log")
    end)
    E.Companion.readFile = readFile
    cacheTeardown()
end)

test("sleep screen: back from a real sleep the plugin tells the companion (no service needed); an app switch doesn't", function()
    local on = RE.Sleep.on
    RE.Sleep.on = function() return true end
    local function wakes()
        return count(W.broadcasts, function(x) return x.action:sub(-11) == ".SLEEP_POOL" and x.extras.wake == "1" end)
    end
    local _ui, m = newUI(false)
    run(5)
    W.broadcasts = {}
    W.screen_on = false
    m:onSuspend()
    run(2)
    W.screen_on = true
    m:onResume()
    run(1)
    ok(wakes() == 1, "one wake: " .. wakes())
    local b = lastBroadcast(".SLEEP_POOL")
    ok(b.package == "net.fledgewing.orbitcompanion" and b.extras.reason == "wake", "to the companion")
    -- Another app in front and back, the screen on throughout: no wake.
    m:onSuspend()
    run(2)
    m:onResume()
    run(1)
    ok(wakes() == 1, "an app switch is no wake: " .. wakes())
    RE.Sleep.on = on
    W.screen_on = false
end)

-- Orbit Companion refreshes the sleep screen's pool (fake_companion.lua plays SleepPoolBuilder).
local function sleepCompanion()
    local fc = dofile(here .. "/fake_companion.lua")
    fc.install(RE, W, function() return nil, 404 end, UIManager)
    local saved = { dir = RE.OC._dir, index = RE.OC._index, problem = RE.Companion.workerProblem, companion = W.companion }
    local d = os.tmpname(); os.remove(d); sh("mkdir -p", d .. "/events")
    RE.OC._dir, RE.OC._index, RE.OC.watching = d, nil, nil
    RE.Companion.workerProblem = function() return fc.problem end
    RE.Sleep.asked, RE.Sleep.scopes_asked, RE.Sleep.problem = nil, nil, nil
    W.on_broadcast, W.companion = fc.receive, true
    function fc.done()
        W.on_broadcast, W.companion = nil, saved.companion
        RE.OC._dir, RE.OC._index, RE.Companion.workerProblem = saved.dir, saved.index, saved.problem
        RE.Sleep.asked, RE.Sleep.scopes_asked = nil, nil
        sh("rm -rf", d)
    end
    return fc
end

test("sleep screen: the menu, SETTINGS to the companion, a pool from Up next through Leave out, the current cover", function()
    local JSON = dofile(here .. "/json_mini.lua")
    capsReset()
    local caps = {}
    for _, c in ipairs(FULL) do table.insert(caps, c) end
    table.insert(caps, "sleep_screen")
    W.web[STATUS_KEY] = "STATUS"
    W.json.STATUS = { version = "0.12.0", mode = "full", caps = caps, sleep = { shown_by = "Orbit screen saver ✓" } }
    local dir = os.tmpname(); os.remove(dir); sh("mkdir -p", dir .. "/covers")
    local lfs = require("libs/libkoreader-lfs")
    local saved = { attributes = lfs.attributes, dir = lfs.dir }
    lfs.attributes = function(f, k)
        local d = os.execute('test -d "' .. f .. '"')
        if d == 0 or d == true then return "directory" end
        local h = io.open(f, "rb"); if h then h:close(); return "file" end
        return saved.attributes(f, k)
    end
    lfs.dir = function(d)
        local h = io.popen('ls -1 "' .. d .. '" 2>/dev/null'); local names = {}
        for n in h:lines() do table.insert(names, n) end
        h:close(); local i = 0
        return function() i = i + 1; return names[i] end
    end
    local S, Sleep = RE.S, RE.Sleep
    Sleep.base_dir = dir
    local ui, m = newUI(false)
    RE.Shared.refresh("test")
    ok(RE.Companion.has("sleep_screen"), "the companion offers it")
    local item
    for _, it in ipairs(m:menuItems()) do if it.text == "Sleep screen" then item = it end end
    ok(item, "Tools › Android sync › Sleep screen")
    local rows = item.sub_item_table_func()
    ok(rows[1].text_func() == "Sleep screen: The reader's own", "off by default: " .. rows[1].text_func())
    ok(rows[2].enabled_func() == false, "Pick from waits for Recommended")
    ok(rows[#rows - 1].text_func() == "Shown by: Orbit screen saver ✓", "how the companion shows it")
    -- Recommended on: saved, and the companion gets every sleep extra.
    W.broadcasts = {}
    rows[1].sub_item_table[2].callback()
    ok(S.sleep_mode == "recommended", "saved")
    local b = lastBroadcast(".SETTINGS")
    ok(b and b.extras.sleep_mode == "recommended" and b.extras.sleep_hours == "6" and b.extras.sleep_style == "bar"
        and b.extras.sleep_battery == "0" and b.extras.sleep_from == "up_next", "SETTINGS extras")
    Sleep.set("sleep_leave_out", { "tag:age:18" })
    ok(lastBroadcast(".SETTINGS").extras.sleep_leave_out == "tag:age:18", "rules, one per line")
    -- The pool: Up next is empty, so Want to read; one read, one without a cover, one left out by tag.
    local calls = {}
    local client = {}
    function client:query(path, q)
        local keys = {}
        for k in pairs(q) do table.insert(keys, k) end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do table.insert(parts, k .. "=" .. tostring(q[k])) end
        return path .. "?" .. table.concat(parts, "&")
    end
    local ui_calls = 0
    function client:requestBlocking(method, path)
        table.insert(calls, path)
        if not W.in_companion then ui_calls = ui_calls + 1 end
        if path:find("sections/up%-next%-in%-series") then return { section = { books = {} } } end
        if path:find("sections/want%-to%-read") then
            return { section = { books = {
                { id = 1, title = "Read One", hasCover = true, readStatus = "read" },
                { id = 2, title = "Tagged", hasCover = true },
                { id = 3, title = "Kept", hasCover = true },
                { id = 4, title = "No Cover", hasCover = false },
            } } }
        end
        local id = tonumber(path:match("/catalog/books/(%d+)$"))
        if id == 2 then return { id = 2, title = "Tagged", hasCover = true, tags = { "Age:18" } } end
        if id == 3 then return { id = 3, title = "Kept", hasCover = true, tags = { "cosy" } } end
        return nil, 404
    end
    local oc_client = RE.OC.client
    RE.OC.client = function() return client end
    local fc = sleepCompanion()
    fc.sleepDownload = function(_, id, path) local f = io.open(path, "wb"); f:write("jpg" .. id); f:close(); return true end
    io.open(dir .. "/covers/99.jpg", "wb"):close() -- a cover from an earlier pool
    W.broadcasts = {}
    Sleep.refreshed_at = nil
    Sleep.kick("test")
    run(60)
    local f = io.open(dir .. "/pool.json", "rb")
    ok(f, "pool.json written")
    local pool = JSON.decode(f:read("*a")); f:close()
    ok(#pool.items == 1 and pool.items[1].id == 3 and pool.items[1].file == "covers/3.jpg", "only the kept book: " .. tostring(#pool.items))
    ok(io.open(dir .. "/covers/3.jpg", "rb"), "its cover")
    ok(not io.open(dir .. "/covers/99.jpg", "rb"), "the old cover went")
    local ask = lastBroadcast(".SLEEP_REFRESH")
    ok(ask and ask.extras.from == "up_next" and ask.extras.rules == "tag:age:18" and ask.extras.every == "0", "the companion is asked")
    ok(ui_calls == 0 and fc.sleep_asks == 1, "the companion lists, checks and fetches; KOReader asks nothing: " .. ui_calls)
    -- Without the right companion nothing is asked.
    local at = Sleep.refreshed_at
    fc.problem = "Update Orbit Companion"
    Sleep.refreshed_at = nil
    ok(Sleep.refresh("old companion") == false and fc.sleep_asks == 1, "an older companion: not asked")
    fc.problem, Sleep.refreshed_at = nil, at
    local log = table.concat(W.logs, "\n")
    ok(log:find("sleep screen: pool 1 cover(s)", 1, true) and log:find("from want-to-read (the chosen list was empty)", 1, true), "logged")
    -- Not again within REFRESH_EVERY_S; never in a book.
    local n = #calls
    Sleep.kick("again"); run(10)
    ok(#calls == n, "not again so soon")
    -- The current book's cover, once per book.
    package.loaded["apps/filemanager/filemanagerbookinfo"] = { getCoverImage = function()
        return { writeToFile = function(_, path) local g = io.open(path, "wb"); g:write("png"); g:close(); return true end, free = function() end }
    end }
    local book = { document = { file = "/books/made-up.epub" }, doc_props = { display_title = "A Made-Up Book", authors = "Ann Example" } }
    ok(Sleep.writeCurrent(book, "test") == true, "written")
    ok(Sleep.writeCurrent(book, "test") == false, "once per book")
    f = io.open(dir .. "/current.json", "rb")
    local cur = JSON.decode(f:read("*a")); f:close()
    ok(cur.title == "A Made-Up Book" and cur.file == "current.png" and cur.authors == "Ann Example", "current.json")
    ok(io.open(dir .. "/current.png", "rb"), "current.png")
    -- Off again: nothing more is written.
    rows[1].sub_item_table[1].callback()
    S.sleep_current_file = nil
    ok(Sleep.writeCurrent(book, "off") == false, "off writes nothing")
    package.loaded["apps/filemanager/filemanagerbookinfo"] = nil
    RE.OC.client = oc_client
    fc.done()
    lfs.attributes, lfs.dir = saved.attributes, saved.dir
    Sleep.base_dir = nil
    S.sleep_leave_out = {}
    sh("rm -rf", dir)
    capsReset()
    run(5)
end)

test("sleep screen: settings changed in the companion are applied; an older companion changes nothing", function()
    capsReset()
    local S = RE.S
    S.shared_settings_at = 1000
    W.web[STATUS_KEY] = "STATUS"
    W.json.STATUS = { version = "0.11.0", mode = "full", caps = FULL, settings = { wifi_mode = "always_on", settings_at = 2000 } }
    RE.Shared.refresh("test")
    ok(S.sleep_mode == "off" and S.sleep_hours == 6, "no sleep keys: unchanged")
    W.json.STATUS = { version = "0.12.0", mode = "full", caps = FULL, settings = { settings_at = 3000,
        sleep_mode = "current", sleep_hours = 12, sleep_battery = true, sleep_style = "overlay",
        sleep_leave_out = "tag:a\nscope:4", sleep_battery_corner = "nowhere" } }
    RE.Shared.refresh("test")
    ok(S.sleep_mode == "current" and S.sleep_hours == 12 and S.sleep_battery == true and S.sleep_style == "overlay", "applied")
    ok(#S.sleep_leave_out == 2 and S.sleep_leave_out[2] == "scope:4", "rules")
    ok(S.sleep_battery_corner == "bottom_left", "a bad value is the default")
    for _, k in ipairs({ "sleep_mode", "sleep_hours", "sleep_battery", "sleep_style", "sleep_leave_out" }) do S[k] = nil end
    S.sleep_mode, S.sleep_hours, S.sleep_battery, S.sleep_style, S.sleep_leave_out = "off", 6, false, "bar", {}
    capsReset()
    run(5)
end)

test("sleep screen: Pick from and Leave out list every smart scope and collection, all pages, with counts, saved for offline", function()
    local JSON = dofile(here .. "/json_mini.lua")
    local function fixture(name)
        local f = assert(io.open(here .. "/../../../shared/fixtures/bookorbit/" .. name, "rb"))
        local v = JSON.decode(f:read("*a")); f:close(); return v
    end
    -- @fixture bookorbit/catalog-sections.smart-scopes.json @fixture bookorbit/catalog-sections.collections.json
    local scopes, collections = fixture("catalog-sections.smart-scopes.json"), fixture("catalog-sections.collections.json")
    -- scopes.json is read back with KOReader's json module: the real decoder here.
    local jm = require("json")
    local stub_decode = jm.decode
    jm.decode = function(str) return W.json[str] or JSON.decode(str) end
    capsReset()
    local caps = {}
    for _, c in ipairs(FULL) do table.insert(caps, c) end
    table.insert(caps, "sleep_screen")
    W.web[STATUS_KEY] = "STATUS"
    W.json.STATUS = { version = "0.12.0", mode = "full", caps = caps }
    local dir = os.tmpname(); os.remove(dir); sh("mkdir -p", dir .. "/covers")
    local S, Sleep = RE.S, RE.Sleep
    Sleep.base_dir, Sleep.scopes_cache, Sleep.scope_names, Sleep.scopes_at = dir, nil, nil, nil
    S.sleep_mode = "recommended"
    local ui, m = newUI(false)
    RE.Shared.refresh("test")
    -- Smart scopes come in two pages (hasNext), collections whole, as the server sends them.
    local calls, down = {}, false
    local client = {}
    function client:query(path, q) return string.format("%s?page=%d&size=%d", path, q.page, q.size) end
    function client:requestBlocking(_, path)
        table.insert(calls, path)
        if down then return nil, "offline" end
        if path:find("/sections/smart%-scopes%?page=1&size=100") then
            local items = {}
            for i = 1, 7 do items[i] = scopes.items[i] end
            return { section = "smart-scopes", items = items, hasNext = true }
        end
        if path:find("/sections/smart%-scopes%?page=2&size=100") then
            local items = {}
            for i = 8, #scopes.items do table.insert(items, scopes.items[i]) end
            return { section = "smart-scopes", items = items, hasNext = false }
        end
        if path:find("/sections/collections%?page=1") then return collections end
        return nil, 404
    end
    local oc_client = RE.OC.client
    RE.OC.client = function() return client end
    local fc = sleepCompanion()
    W.wifi = true
    local item
    for _, it in ipairs(m:menuItems()) do if it.text == "Sleep screen" then item = it end end
    local rows = item.sub_item_table_func()
    local from = rows[2].sub_item_table
    local picker = from[#from]
    -- First open: nothing saved yet, fetched behind the menu.
    local first = picker.sub_item_table_func()
    ok(#first == 1 and first[1].text_func():find("Loading", 1, true), "loading: " .. first[1].text_func())
    run(10)
    ok(#calls == 3, "two pages of scopes, one of collections: " .. table.concat(calls, " "))
    local f = io.open(dir .. "/scopes.json", "rb")
    ok(f, "scopes.json saved"); if f then f:close() end
    local function texts(list)
        local out = {}
        for _, r in ipairs(list) do table.insert(out, r.text or (r.text_func and r.text_func())) end
        return out
    end
    local got = texts(picker.sub_item_table_func())
    ok(#got == 15, "2 headers, 12 scopes, 1 collection: " .. #got)
    ok(got[1] == "Smart scopes" and got[2] == "Cosy Mysteries · 5" and got[13] == "Holiday Picks", "scopes with counts, the last without: " .. tostring(got[13]))
    ok(got[14] == "Collections" and got[15] == "ToRead · 23", "the collection: " .. tostring(got[15]))
    -- Tapping one ticks it beside Up next (Pick from is a set, R1c), and both names show.
    local tapped = picker.sub_item_table_func()
    ok(tapped[15].checked_func and not tapped[15].checked_func(), "a tick box, not ticked yet")
    tapped[15].callback()
    ok(S.sleep_from == "up_next\ncollection:7" and Sleep.fromLabel(S.sleep_from) == "Up next in series, ToRead", "picked: " .. tostring(S.sleep_from))
    ok(picker.sub_item_table_func()[15].checked_func(), "ticked")
    -- Library stands alone: ticking it clears the others; ticking a list clears it.
    from[1].callback()
    ok(S.sleep_from == "library" and Sleep.fromLabel(S.sleep_from) == "Whole library", "library: " .. tostring(S.sleep_from))
    from[3].callback()
    ok(S.sleep_from == "want_to_read", "a list clears Library: " .. tostring(S.sleep_from))
    from[3].callback()
    ok(S.sleep_from == "want_to_read", "the last one stays ticked")
    tapped[15].callback()
    -- Offline, after a restart: the same lists from scopes.json, in Leave out too.
    down, W.wifi = true, false
    Sleep.scopes_cache, Sleep.scope_names, Sleep.scopes_at = nil, nil, nil
    local leave = rows[3].sub_item_table_func()
    local add
    for _, r in ipairs(leave) do if r.text == "Add a rule: Library, smart scope or collection…" then add = r end end
    local lo = texts(add.sub_item_table_func())
    ok(#lo == 15 and lo[3] == "Space Opera · 8", "Leave out lists them offline: " .. #lo)
    add.sub_item_table_func()[4].callback()
    ok(S.sleep_leave_out[1] == "scope:103" and Sleep.ruleLabel("scope:103") == "Short Reads (smart scope)", "rule added: " .. tostring(S.sleep_leave_out[1]))
    RE.OC.client, jm.decode = oc_client, stub_decode
    fc.done()
    Sleep.base_dir, Sleep.scopes_cache, Sleep.scope_names, Sleep.scopes_at = nil, nil, nil, nil
    S.sleep_mode, S.sleep_from, S.sleep_leave_out = "off", "up_next", {}
    sh("rm -rf", dir)
    capsReset()
    run(5)
end)

test("sleep screen: the tag picker opens from the companion's tags.json; KOReader reads no saved detail", function()
    capsReset()
    local caps = {}
    for _, c in ipairs(FULL) do table.insert(caps, c) end
    table.insert(caps, "sleep_screen")
    W.web[STATUS_KEY] = "STATUS"
    W.json.STATUS = { version = "0.12.0", mode = "full", caps = caps }
    local jm = require("json")
    local JSON = dofile(here .. "/json_mini.lua")
    local stub_decode = jm.decode
    jm.decode = function(str) return W.json[str] or JSON.decode(str) end
    local sdir = os.tmpname(); os.remove(sdir); sh("mkdir -p", sdir .. "/covers")
    local S, Sleep = RE.S, RE.Sleep
    Sleep.base_dir, Sleep.tags_cache, Sleep.scopes_cache, Sleep.scope_names, Sleep.scopes_at = sdir, nil, nil, nil, nil
    S.sleep_mode, S.sleep_leave_out = "recommended", {}
    newUI(false)
    RE.Shared.refresh("test")
    local client = {}
    function client:query(path, q) return path .. "?page=" .. q.page end
    function client:requestBlocking(_, path)
        if path:find("/sections/") then return { items = {}, hasNext = false } end
        return nil, 404
    end
    local oc_client = RE.OC.client
    RE.OC.client = function() return client end
    local fc = sleepCompanion()
    -- 400 saved details in the database, each with tags, and one more.
    local cdir = RE.OC.dir()
    local st = fc.db()
    st:begin()
    for i = 1, 400 do st:putDetail(i, { id = i, tags = { i % 2 == 0 and "Age:18" or "cosy", "Fantasy" } }, 1) end
    st:putDetail(900, { id = 900, tags = { "Space" } }, 1)
    st:commit()
    -- Every file KOReader's UI thread opens in the cache folder while the picker opens.
    local reads, open = 0, io.open
    io.open = function(path, ...)
        -- The companion's small answers (events/) are read; no saved detail or index is.
        if not W.in_companion and tostring(path):find(cdir, 1, true) and not tostring(path):find("/events/", 1, true) then reads = reads + 1 end
        return open(path, ...)
    end
    W.wifi = true
    local item
    for _, it in ipairs(select(2, newUI(false)):menuItems()) do if it.text == "Sleep screen" then item = it end end
    local leave = item.sub_item_table_func()[3].sub_item_table_func()
    local tagItem
    for _, r in ipairs(leave) do if r.text == "Add a rule: Tag…" then tagItem = r end end
    -- First open: nothing counted yet; the companion counts behind it.
    local first = tagItem.sub_item_table_func()
    ok(#first == 2 and first[2].text_func():find("Counting", 1, true), "counting: " .. tostring(first[2] and first[2].text_func and first[2].text_func()))
    run(10)
    ok(fc.sleep_asks == 1 and fc.sleep_last.scopes_only == "1", "the companion was asked for the pickers' lists")
    local rows = tagItem.sub_item_table_func()
    local texts = {}
    for _, r in ipairs(rows) do table.insert(texts, r.text or "") end
    ok(texts[2] == "Fantasy · 400" and texts[3] == "Age:18 · 200" and texts[4] == "cosy · 200" and texts[5] == "Space · 1", "counted by the companion: " .. table.concat(texts, " | "))
    ok(reads == 0, "KOReader read no saved detail: " .. reads)
    rows[3].callback()
    ok(S.sleep_leave_out[1] == "tag:age:18", "picked: " .. tostring(S.sleep_leave_out[1]))
    io.open = open
    RE.OC.client, jm.decode = oc_client, stub_decode
    fc.done()
    Sleep.base_dir, Sleep.tags_cache, Sleep.scopes_cache, Sleep.scope_names, Sleep.scopes_at = nil, nil, nil, nil, nil
    S.sleep_mode, S.sleep_leave_out = "off", {}
    sh("rm -rf", sdir)
    capsReset()
    run(5)
end)

test("sleep screen: 24 covers ready whatever the source; Every sleep retires the used-up and tops up", function()
    local JSON = dofile(here .. "/json_mini.lua")
    local jm = require("json")
    local stub_decode = jm.decode
    jm.decode = function(str) return W.json[str] or JSON.decode(str) end
    capsReset()
    local caps = {}
    for _, c in ipairs(FULL) do table.insert(caps, c) end
    table.insert(caps, "sleep_screen")
    W.web[STATUS_KEY] = "STATUS"
    W.json.STATUS = { version = "0.12.0", mode = "full", caps = caps }
    local dir = os.tmpname(); os.remove(dir); sh("mkdir -p", dir .. "/covers")
    local lfs = require("libs/libkoreader-lfs")
    local saved = { attributes = lfs.attributes, dir = lfs.dir }
    lfs.attributes = function(f, k)
        local d = os.execute('test -d "' .. f .. '"')
        if d == 0 or d == true then return "directory" end
        local h = io.open(f, "rb"); if h then h:close(); return "file" end
        return saved.attributes(f, k)
    end
    lfs.dir = function(d)
        local h = io.popen('ls -1 "' .. d .. '" 2>/dev/null'); local names = {}
        for n in h:lines() do table.insert(names, n) end
        h:close(); local i = 0
        return function() i = i + 1; return names[i] end
    end
    local S, Sleep = RE.S, RE.Sleep
    Sleep.base_dir = dir
    newUI(false)
    RE.Shared.refresh("test")
    S.sleep_mode, S.sleep_from, S.sleep_hours, S.sleep_leave_out = "recommended", "up_next", 6, {}
    local books = {}
    for i = 1, 30 do books[i] = { id = i, title = "Book " .. i, hasCover = true } end
    local client = {}
    function client:query(path) return path end
    function client:requestBlocking(_, path)
        if path:find("sections/up%-next%-in%-series") then return { section = { books = books } } end
        return nil, 404
    end
    local oc_client = RE.OC.client
    RE.OC.client = function() return client end
    local fc = sleepCompanion()
    fc.sleepDownload = function(_, id, path) local f = io.open(path, "wb"); f:write("jpg" .. id); f:close(); return true end
    W.wifi = true
    local function build()
        Sleep.refreshed_at = nil
        Sleep.kick("test"); run(60)
        local ids, f = {}, io.open(dir .. "/pool.json", "rb")
        for _, it in ipairs(JSON.decode(f:read("*a")).items) do table.insert(ids, it.id) end
        f:close()
        return ids
    end
    local function has(ids, id) for _, x in ipairs(ids) do if x == id then return true end end return false end
    local function state(shows)
        local f = io.open(dir .. "/state.json", "wb"); f:write(shows); f:close()
    end
    -- 30 in the source: the batch is 24, with hours too.
    local ids = build()
    ok(#ids == 24 and ids[1] == 1 and ids[24] == 24, "24 of 30: " .. #ids)
    -- Every sleep: 1 and 2 were shown 3 times; they go, 25 and 26 come in; the rest stay.
    S.sleep_hours = 0
    state('{"v":1,"shown":3,"changed_at":1,"shows":{"1":3,"2":3,"3":1}}')
    ids = build()
    ok(#ids == 24 and not has(ids, 1) and not has(ids, 2) and has(ids, 3) and has(ids, 25) and has(ids, 26), "retired and topped up: " .. table.concat(ids, ","))
    ok(not io.open(dir .. "/covers/1.jpg", "rb"), "a retired cover's file goes")
    ok(table.concat(W.logs, "\n"):find("every sleep: 22 kept, 2 retired", 1, true), "logged")
    -- A one-book source: fewer than 24 is fine, and a used-up last cover stays rather than nothing.
    books = { { id = 40, title = "Only", hasCover = true } }
    state('{"v":1,"shown":0,"changed_at":1,"shows":{}}')
    ids = build()
    ok(#ids == 1 and ids[1] == 40, "one book: " .. table.concat(ids, ","))
    state('{"v":1,"shown":40,"changed_at":1,"shows":{"40":3}}')
    ids = build()
    ok(#ids == 1 and ids[1] == 40, "kept cycling: " .. table.concat(ids, ","))
    RE.OC.client, jm.decode = oc_client, stub_decode
    fc.done()
    lfs.attributes, lfs.dir = saved.attributes, saved.dir
    Sleep.base_dir = nil
    S.sleep_mode, S.sleep_from, S.sleep_hours, S.sleep_leave_out = "off", "up_next", 6, {}
    sh("rm -rf", dir)
    capsReset()
    run(5)
end)


test("settings v2: a change queued in the companion while KOReader was off applies, then is echoed", function()
    capsReset()
    local S = RE.S
    local was = { sync_on_sleep = S.sync_on_sleep, storage_limit_mb = S.storage_limit_mb, wifi_mode = S.wifi_mode }
    local at = S.settings_at
    S.settings_at = { sync_on_sleep = 1, storage_limit_mb = 1, wifi_mode = 5000 }
    S.sync_on_sleep, S.storage_limit_mb, S.wifi_mode = true, 250, "always_on"
    W.web[STATUS_KEY] = "STATUS"
    -- The companion changed two keys while KOReader was closed; its Wi-Fi mode is older than ours.
    W.json.STATUS = { version = "0.12.0", mode = "full", caps = FULL, settings = { settings_at = 9000, values = {
        sync_on_sleep = { v = "0", at = 8000 }, storage_limit_mb = { v = "500", at = 8000 },
        wifi_mode = { v = "jit", at = 100 } } } }
    local n = #W.broadcasts
    RE.Shared.refresh("start")
    ok(S.sync_on_sleep == false and S.storage_limit_mb == 500, "the companion's newer changes applied")
    ok(S.wifi_mode == "always_on", "our newer Wi-Fi mode kept (per key, not the whole set)")
    eq(S.settings_at.sync_on_sleep, 8000, "the companion's time kept")
    local echo
    for i = n + 1, #W.broadcasts do if W.broadcasts[i].action:match("SETTINGS$") then echo = W.broadcasts[i] end end
    ok(echo ~= nil, "echoed with SETTINGS")
    eq(echo.extras.settings_v, "2")
    ok(echo.extras.values:find('"sync_on_sleep":{"at":8000,"v":"0"}', 1, true), "echo carries the applied time: " .. tostring(echo.extras.values))
    ok(echo.extras.values:find('"wifi_mode":{"at":5000,"v":"always_on"}', 1, true), "and our newer Wi-Fi mode")
    -- A menu change gets its own time and goes out at once.
    n = #W.broadcasts
    RE.Shared.set("key_log", false)
    ok(S.settings_at.key_log and S.settings_at.key_log > 1, "menu change stamped")
    ok(#W.broadcasts > n, "sent")
    S.sync_on_sleep, S.storage_limit_mb, S.wifi_mode, S.key_log = was.sync_on_sleep, was.storage_limit_mb, was.wifi_mode, true
    S.settings_at = at
    capsReset()
    run(5)
end)

test("settings v2: the companion's look-now line refreshes at once", function()
    local refreshed
    local base = RE.Shared.refresh
    RE.Shared.refresh = function(why) refreshed = why end
    RE.Channel.proven = true
    ok(RE.Channel.onLine("SETTINGS 12345") == true, "taken")
    RE.Channel.proven = false
    run(1)
    RE.Shared.refresh = base
    eq(refreshed, "channel")
end)

---------------------------------------------------------------- SQLite stress test (sqlite-cache.md)
local SQ3 = require("lua-ljsqlite3/init")

-- The companion's writer, played here (SqliteStress.kt): one page of 100 rows per transaction.
local function stressWrite(conn, gen, opts)
    opts = opts or {}
    local page = gen % RE.SqliteStress.PAGES
    conn:exec("BEGIN IMMEDIATE")
    local sum = 0
    local st = conn:prepare("INSERT OR REPLACE INTO rows (page, pos, gen, val) VALUES (?, ?, ?, ?)")
    for pos = 0, RE.SqliteStress.ROWS - 1 do
        local len = RE.SqliteStress.len(gen, pos)
        sum = sum + len
        local g = (opts.torn and pos == 50) and gen - 1 or gen
        st:bind(page, pos, g, string.rep("x", len)):step()
        st:reset()
    end
    st:close()
    conn:exec("INSERT OR REPLACE INTO head (page, gen, sum) VALUES (" .. page .. ", " .. gen .. ", " .. sum .. ")")
    conn:exec("COMMIT")
end

local function stressDb()
    local path = os.tmpname() .. ".db"
    local w = SQ3.open(path, "rwc")
    w:exec("PRAGMA journal_mode=TRUNCATE")
    w:exec("CREATE TABLE rows (page INTEGER, pos INTEGER, gen INTEGER, val TEXT, PRIMARY KEY (page, pos)) WITHOUT ROWID")
    w:exec("CREATE TABLE head (page INTEGER PRIMARY KEY, gen INTEGER, sum INTEGER)")
    return path, w
end

-- A clock that moves 0.01 s per look, so a "2 s" read makes about 100 reads.
local function tickClock() local t = 0; return function() t = t + 0.01; return t end end

test("sqlite stress: the reader sees whole pages through lua-ljsqlite3, read-only", function()
    local path, w = stressDb()
    for gen = 1, 120 do stressWrite(w, gen) end
    local r = RE.SqliteStress.read(path, 2, tickClock())
    ok(r.reads > 20, "reads: " .. tostring(r.reads))
    eq(r.errors, 0, "errors: " .. tostring(r.first_error))
    -- Read-only: the reader's connection can't write.
    local ro = RE.Db.connect(path, "ro")
    ok(not pcall(ro.exec, ro, "DELETE FROM head"), "a read-only connection refuses writes")
    ro:close()
    w:close(); os.remove(path)
end)

test("sqlite stress: a torn page and a locked file are caught and counted", function()
    local path, w = stressDb()
    for gen = 1, 50 do stressWrite(w, gen, { torn = gen == 17 }) end
    local r = RE.SqliteStress.read(path, 2, tickClock())
    ok(r.errors > 0 and tostring(r.first_error):find("torn page") ~= nil, "torn: " .. tostring(r.first_error))
    -- A writer holding the commit lock: the reader waits (busy) and goes on once it's released.
    local path2, w2 = stressDb()
    for gen = 1, 50 do stressWrite(w2, gen) end
    w2:exec("BEGIN EXCLUSIVE")
    local n, release = 0, nil
    local clock = function() n = n + 1; if n == 30 then w2:exec("COMMIT") end; return n * 0.01 end
    local r2 = RE.SqliteStress.read(path2, 1, clock)
    eq(r2.errors, 0, "errors after the wait: " .. tostring(r2.first_error))
    ok(r2.busy >= 1, "the wait is counted")
    ok(r2.reads > 0, "reads after the lock went")
    w:close(); w2:close(); os.remove(path); os.remove(path2)
end)

-- The offline cache's database, as CacheStoreTest reads it: the same fixture, the plugin's reads.
local JSONF = dofile(here .. "/json_mini.lua")
-- @fixture cache/db.json @fixture cache/schema.sql
local DBFX = JSONF.decode(io.open(here .. "/../../../shared/fixtures/cache/db.json", "rb"):read("*a"))
local FakeStore = dofile(here .. "/fake_store.lua")(RE.Cache, SQ3, here .. "/../../../shared/fixtures/cache/schema.sql")

local function fixtureStore()
    local dir = os.tmpname() .. "-store"
    os.execute("mkdir -p '" .. dir .. "'")
    local st = FakeStore.open(dir .. "/orbit.db")
    st:own(DBFX.owner)
    for i, sv in ipairs(DBFX.saves) do
        local key = sv.key or RE.Cache.key({ account = DBFX.owner:match("^([^|]*)"), server = DBFX.owner:match("|(.*)$"), method = "GET", path = sv.path })
        st:save(key, sv.path, sv.reply, 1000 + i, DBFX.detail_template)
    end
    return dir, st
end

local function withStore(dir, fn)
    local saved = RE.OC._dir
    RE.OC._dir = dir
    local okf, err = pcall(fn)
    RE.Db.close(dir .. "/orbit.db")
    RE.OC._dir = saved
    if not okf then error(err, 0) end
end

test("sqlite cache: the plugin's reads answer the shared fixture (db.json) from the rows", function()
    local dir, st = fixtureStore()
    withStore(dir, function()
        for _, r in ipairs(DBFX.reads) do
            local key = r.key or RE.Cache.key({ account = DBFX.owner:match("^([^|]*)"), server = DBFX.owner:match("|(.*)$"), method = "GET", path = r.path })
            local e = RE.Store.read(DBFX.owner, key, r.path, DBFX.detail_template)
            if r["null"] then
                ok(e == nil, r.path .. " should not be saved")
            else
                ok(e ~= nil, r.path .. " not answered")
                local b = e.body
                if r.ids then
                    local got = {}
                    for _, it in ipairs(b.items) do table.insert(got, tostring(it.id)) end
                    local want = {}
                    for _, id in ipairs(r.ids) do table.insert(want, tostring(id)) end
                    eq(table.concat(got, ","), table.concat(want, ","), r.path)
                    if r.read_status_2 then
                        for _, it in ipairs(b.items) do if it.id == 2 then eq(it.readStatus, r.read_status_2, "newest item wins") end end
                    end
                end
                for _, k in ipairs({ "total", "page", "size", "offset", "hasNext", "hasPrevious" }) do
                    if r[k] ~= nil then eq(b[k], r[k], r.path .. " " .. k) end
                end
                for _, k in ipairs(r.no or {}) do eq(b[k], nil, r.path .. " has " .. k) end
                if r.head then eq(b.authorSummary.bookCount, 2) end
                if r.titles then for i, t in ipairs(r.titles) do eq(b.items[i].title, t) end end
                if r.detail then eq(b.id, r.detail); eq(#b.files, r.files) end
                if r.continue then eq(b.continueReading[1].id, r.continue[1]) end
            end
        end
        -- Another account's database answers nothing.
        eq(RE.Store.read("other|http://x", "k", DBFX.reads[1].path, DBFX.detail_template), nil, "another owner")
    end)
    local n = st:run("SELECT count(*) FROM books")[1][1]
    eq(tonumber(n), DBFX.books_rows, "each book is one row")
    for id, text in pairs(DBFX.search_text) do
        eq(st:run("SELECT search FROM books WHERE id = ?", tonumber(id))[1][1], text, "search text " .. id)
    end
    st:close()
end)

test("sqlite cache: offline search over the saved books", function()
    local dir, st = fixtureStore()
    withStore(dir, function()
        for _, s in ipairs(DBFX.searches) do
            local body = RE.Store.search(DBFX.owner, "/koreader/plugin/catalog/books?page=1&q=" .. s.q:gsub(" ", "%%20") .. "&size=20")
            ok(body ~= nil, s.q)
            local got = {}
            for _, it in ipairs(body.items) do table.insert(got, tostring(it.id)) end
            local want = {}
            for _, id in ipairs(s.ids) do table.insert(want, tostring(id)) end
            eq(table.concat(got, ","), table.concat(want, ","), "search " .. s.q)
            eq(body.total, #s.ids)
        end
    end)
    st:close()
end)

test("sqlite cache: a replaced or busy database is reopened or missed, never an error", function()
    local dir, st = fixtureStore()
    withStore(dir, function()
        local path = DBFX.reads[1].path
        ok(RE.Store.read(DBFX.owner, "k", path, nil) ~= nil, "first read")
        -- The companion holds the commit lock: return the cached result within the UI budget.
        local saved_busy = RE.Db.BUSY_MS
        RE.Db.close(dir .. "/orbit.db")
        ok(RE.Db.BUSY_MS <= 20, "UI busy timeout stays short")
        st.conn:exec("BEGIN EXCLUSIVE")
        local before = W.wall()
        ok(RE.Store.read(DBFX.owner, "k", path, nil) ~= nil, "busy: cached fallback")
        ok(W.wall() - before < 0.1, "UI read stays below 100 ms")
        st.conn:exec("COMMIT")
        RE.Db.BUSY_MS = saved_busy
        -- A new file (another inode): reopened. Here: an empty database of the same schema.
        st:close()
        os.remove(dir .. "/orbit.db")
        local st2 = FakeStore.open(dir .. "/orbit.db")
        st2:own(DBFX.owner)
        W.ino[dir .. "/orbit.db"] = 2
        eq(RE.Store.read(DBFX.owner, "k", path, nil), nil, "the new file is read, not the old one")
        st2:close()
        W.ino[dir .. "/orbit.db"] = nil
    end)
end)

test("sqlite stress: the verdict line", function()
    local line = RE.SqliteStress.verdict({ reads = 900, errors = 0, busy = 3, max_busy_ms = 41 },
        { writes = 1200, errors = 0, max_wait_ms = 12, integrity = "ok" })
    eq(line, "sqlite-stress: 1200 writes, 900 reads, 0 errors, max busy wait 41 ms")
    local l2, notes = RE.SqliteStress.verdict({ reads = 5, errors = 0, max_busy_ms = 0 }, nil)
    eq(l2, "sqlite-stress: 0 writes, 5 reads, 1 errors, max busy wait 0 ms", "no writer answer is an error")
    ok(notes[1]:find("didn't answer") ~= nil)
end)

---------------------------------------------------------------- OrbiSmart sync (docs/design/orbismart.md)
-- A 300-page book; places are pages, xpointers "/p<page>". The BookOrbit plugin's API client is
-- a fake bookorbit_api (getProgress answers W.osm_server; updateProgress stores it), wrapped by
-- ko/orbismart.lua like the real one.
local OSMApi = { puts = 0 }
function OSMApi:getProgress(d) return W.osm_server end
function OSMApi:updateProgress(d, pct, progress, ts)
    OSMApi.puts = OSMApi.puts + 1
    W.osm_server = { percentage = pct, progress = progress, timestamp = ts, device = "M8C", device_id = "me" }
    return { document = d, timestamp = ts }
end
package.loaded["bookorbit_api"] = OSMApi
local OSM = RE.OSM
local function osmLog(pat)
    for i = #W.logs, 1, -1 do if W.logs[i]:find(pat, 1, true) then return W.logs[i] end end
end
local function osmPopup()
    for i = #W.shown, 1, -1 do local w = W.shown[i]; if type(w) == "table" and w.ok_callback and w.cancel_callback then return w end end
end
local function osmAnswer(yes)
    local w = osmPopup()
    UIManager:close(w) -- KOReader's ConfirmBox closes itself, then runs the callback
    if yes then w.ok_callback() else w.cancel_callback() end
end
local function osmServer(page, at, device)
    W.osm_server = { percentage = page / 300, progress = "/p" .. page, timestamp = at, device = device or "Boox", device_id = "boox" }
end
-- A book open on this reader at page `page`, OrbiSmart on, with what this reader knew before.
local function osmBook(page, rec)
    store.orbit_android.sync_mode = "orbismart"
    store.orbit_android.orbismart = { d1 = rec }
    store.orbit_android.osm_saved_plugin = nil
    W.page, W.logs, W.shown, OSMApi.puts = page, {}, {}, 0
    W.osm_server = nil
    local ui, m = newUI(true)
    ui.document.info = {}
    function ui.document:getPageCount() return 300 end
    function ui.document:getCurrentPage() return W.page end
    function ui.document:getPageFromXPointer(xp) return tonumber(xp:match("%d+")) end
    ui.doc_settings = { readSetting = function(_, k) if k == "summary" then return { status = W.osm_status } end end }
    local p = ui.bookorbit
    p.device_id = "me"
    function p:getLastPercent() return W.page / 300 end
    function p:getLastProgress() return "/p" .. W.page end
    function p:syncToProgress(progress) W.page = tonumber(progress:match("%d+")); table.insert(p.calls, "goto:" .. W.page) end
    function p:noteProgressCompared() end
    function p:fetchRemoteProgress(d, cb)
        table.insert(p.calls, "fetch")
        local body = require("bookorbit_api"):getProgress(d)
        p.last_remote_progress = body and { digest = d, percentage = body.percentage, progress = body.progress, timestamp = body.timestamp } or nil
        UIManager:nextTick(function() cb(body ~= nil) end)
    end
    function p:requestProgressPush(_, _, src)
        table.insert(p.calls, "push:" .. src)
        require("bookorbit_api"):updateProgress("d1", W.page / 300, "/p" .. W.page, os.time())
    end
    return ui, m, p
end
local function osmRec() return store.orbit_android.orbismart.d1 end

-- KOReader doShowReader constructs ReaderUI in a coroutine, sends ReaderReady during
-- init, then shows it. BookOrbit runInSyncCoroutine reuses ANY current coroutine
-- (Trapper:isWrapped), and its background GET yields until the first 125 ms poll.
-- An empty window stack exits UIManager before that poll can resume construction.
test("startup smoke: last document remains the top reader through a yielding progress pull", function()
    W.queue, W.shown = {}, {}
    capsReset()
    W.wifi, W.vpn, W.server_code = true, true, 200
    W.radio = true
    RE.Net.inflight = nil
    store.orbit_android.wifi_mode = "jit"
    RE.Wifi.plan = nil
    local ui, m, p = osmBook(120, nil)
    local closes, quits = 0, W.quits or 0
    local stock_close = UIManager.close
    UIManager.close = function(self, w, ...)
        if w == ui then closes = closes + 1 end
        return stock_close(self, w, ...)
    end
    W.after_fail = function() UIManager.close = stock_close end
    -- Host LuaJIT builds with Lua 5.2 compatibility may return (main_thread, true)
    -- on the main thread. KOReader's Trapper expects Lua 5.1's nil there.
    local function running()
        local co, main = coroutine.running()
        return not main and co or nil
    end
    local Trapper = {
        isWrapped = function() return running() ~= nil end,
        wrap = function(_, fn)
            local resumed, err = coroutine.resume(coroutine.create(fn))
            assert(resumed, err)
        end,
    }
    -- CI also runs this case with the pinned KOReader's actual Trapper methods.
    local checkout = os.getenv("ORBIT_KOREADER_SOURCE")
    if checkout then
        local chunk = assert(loadfile(checkout .. "/frontend/ui/trapper.lua"))
        local co_api = setmetatable({ running = running }, { __index = coroutine })
        setfenv(chunk, setmetatable({ coroutine = co_api, require = function(name)
            if name == "string.buffer" then return {} end
            return require(name)
        end }, { __index = _G }))
        Trapper = chunk()
        UIManager.preventStandby, UIManager.allowStandby = function() end, function() end
    end
    function p:fetchRemoteProgress(_, cb)
        local function fetch()
            local co = coroutine.running()
            UIManager:scheduleIn(0.125, function()
                local resumed, err = coroutine.resume(co)
                assert(resumed, err)
            end)
            coroutine.yield()
            cb(false)
        end
        if Trapper:isWrapped() then return fetch() end
        return Trapper:wrap(fetch)
    end
    -- The opening message has expired; the reader is the only persistent window.
    local co = coroutine.create(function()
        m:onReaderReady()
        UIManager:show(ui)
    end)
    local resumed, err = coroutine.resume(co)
    ok(resumed, err)
    eq(UIManager:getTopmostVisibleWidget(), ui, "ReaderReady must finish before yielding network work")
    eq(coroutine.status(co), "dead", "reader construction completed")
    run(30)
    eq(UIManager:getTopmostVisibleWidget(), ui, "reader stays on top after open and wake tasks")
    eq(closes, 0, "no reader close requested")
    eq(W.quits or 0, quits, "no exit requested")
    UIManager.close = stock_close
    store.orbit_android.sync_mode = "custom"
end)

test("orbismart: before render, a further place already known opens there with no popup", function()
    local ui, m, p = osmBook(120, { server = { at = 5000, pct = 214 / 300, progress = "/p214", device = "Boox" } })
    m:onReaderReady()
    eq(W.page, 214, "opened at the further place")
    ok(osmLog("orbismart: rule3 L=120 R=214 -> take (prerender, now)"), "decision logged")
    run(30)
    eq(osmPopup(), nil, "no popup")
end)

test("orbismart: after render, a further place asks; Yes moves there", function()
    local ui, m, p = osmBook(120, nil)
    m:onReaderReady()
    run(5)
    osmServer(214, 5000)
    p:fetchRemoteProgress("d1", function() end)
    run(2)
    local w = osmPopup()
    ok(w, "popup")
    eq(w.text, "Continue from Boox, p. 214?")
    eq(w.ok_text, "Yes"); eq(w.cancel_text, "No")
    eq(W.page, 120, "not moved before the answer")
    ok(osmLog("orbismart: rule3 L=120 R=214 -> take (open, ask)"), "decision logged")
    osmAnswer(true)
    eq(W.page, 214, "moved")
    eq(osmRec().m.at, 5000, "marker")
    ok(osmLog("orbismart: popup 120->214 yes"), "answer logged")
end)

test("orbismart: after render, No stays, pushes nothing and never asks again for that place", function()
    local ui, m, p = osmBook(120, nil)
    m:onReaderReady()
    run(5)
    osmServer(214, 5000)
    p:fetchRemoteProgress("d1", function() end)
    run(2)
    osmAnswer(false)
    eq(W.page, 120, "stayed")
    eq(osmRec().declined_at, 5000, "declined")
    eq(osmRec().override, nil, "No is not an override")
    p:fetchRemoteProgress("d1", function() end)
    run(2)
    eq(osmPopup(), nil, "not asked again")
    ok(osmLog("orbismart: declined L=120 R=214 -> stay (open, no)"), "declined logged")
    eq(OSMApi.puts, 0, "nothing pushed")
    -- A newer place elsewhere asks again.
    osmServer(230, 5200)
    p:fetchRemoteProgress("d1", function() end)
    run(2)
    ok(osmPopup() and osmPopup().text == "Continue from Boox, p. 230?", "a newer place asks")
    osmAnswer(false)
end)

test("orbismart: No declines a standing reset until normal progress returns", function()
    local ui, m, p = osmBook(120, {})
    run(1)
    OSM.installApi()
    local function reset(at)
        OSM.onPulled("d1", { percentage = 0, progress = "/p0", timestamp = at,
            device = "web", device_id = "bookorbit-web" })
        run(1)
    end
    reset(5000)
    ok(OSM.popup, "reset asks")
    osmAnswer(false)
    reset(5001)
    eq(OSM.popup, nil, "same standing reset was only re-dated")
    OSM.onPulled("d1", { percentage = 0.4, progress = "/p120", timestamp = 6000, device_id = "other" })
    run(1)
    eq(osmRec().declined_reset, nil, "normal progress ends the declined reset")
    reset(7000)
    ok(OSM.popup, "a later reset asks again")
    osmAnswer(false)
end)

test("orbismart: a further place found while reading (a pause) asks once, no silent jump", function()
    local ui, m, p = osmBook(100, nil)
    osmServer(100, 4000)
    m:onReaderReady()
    run(30)
    eq(osmPopup(), nil, "same place: no popup")
    for pg = 101, 110 do W.page = pg; m:onPageUpdate(pg) end
    osmServer(214, 5000)
    run(150)
    ok(has(p.calls, "fetch"), "the pause pulled")
    local w = osmPopup()
    ok(w and w.text == "Continue from Boox, p. 214?", "asked")
    eq(W.page, 110, "no silent jump mid-book")
    ok(osmLog("orbismart: rule3 L=110 R=214 -> take (pause, ask)"), "logged as a pause")
    osmAnswer(true)
    eq(W.page, 214)
end)

test("orbismart: a pause where this reader is further pushes", function()
    local ui, m, p = osmBook(100, nil)
    osmServer(100, 4000)
    m:onReaderReady()
    run(30)
    for pg = 101, 140 do W.page = pg; m:onPageUpdate(pg) end
    run(150)
    ok(has(p.calls, "push:orbismart"), "pushed")
    eq(W.osm_server.progress, "/p140")
    ok(osmLog("orbismart: rule4 L=140 R=100 -> push (pause, no)"), "logged")
end)

test("orbismart: never push behind the server's place (the behind-hold), further goes", function()
    local ui, m, p = osmBook(150, { server = { at = 5000, pct = 214 / 300, progress = "/p214" }, m = { at = 5000, pct = 214 / 300, progress = "/p214" } })
    run(1)
    OSM.installApi()
    p:requestProgressPush(false, false, "close")
    eq(OSMApi.puts, 0, "held")
    ok(osmLog("orbismart: push held L=150 R=214 (behind the server)"), "held logged")
    -- The outbox's snapshot goes through the same client.
    local body = require("bookorbit_api"):updateProgress("d1", 150 / 300, "/p150", 6000)
    ok(body and body.orbit_held, "answered as done, not sent")
    eq(OSMApi.puts, 0)
    W.page = 230
    p:requestProgressPush(false, false, "close")
    eq(OSMApi.puts, 1, "further: sent")
    -- A closed book (no open document for it): compared by percent.
    store.orbit_android.orbismart.d2 = { server = { at = 1, pct = 0.6 } }
    require("bookorbit_api"):updateProgress("d2", 0.3, nil, 7000)
    eq(OSMApi.puts, 1, "closed book held too")
end)

test("orbismart: Read from here everywhere online: sent now, skipping the hold", function()
    local ui, m, p = osmBook(50, { server = { at = 5000, pct = 214 / 300, progress = "/p214" }, m = { at = 5000, pct = 214 / 300, progress = "/p214" } })
    run(1)
    OSM.installApi()
    OSM.readFromHere("test")
    run(30)
    eq(OSMApi.puts, 1, "sent")
    eq(W.osm_server.progress, "/p50", "the server has this place")
    eq(osmRec().override, nil, "done")
    ok(osmLog("orbismart: override sent"), "logged")
end)

test("orbismart: Read from here everywhere offline: queued, then sent first at the next sync", function()
    local ui, m, p = osmBook(50, { server = { at = 5000, pct = 214 / 300, progress = "/p214" }, m = { at = 5000, pct = 214 / 300, progress = "/p214" } })
    run(1)
    OSM.installApi()
    W.server_code = nil
    OSM.readFromHere("test")
    run(40)
    W.server_code = 200
    ok(osmLog("orbismart: override queued (offline)"), "queued")
    eq(OSMApi.puts, 0)
    ok(osmRec().override, "still queued")
    -- The next sync (a wake after a real sleep): the override decides first and goes.
    osmServer(214, 5000)
    RE.state.paused_for = 900
    m:wakeFlow("wake")
    run(40)
    ok(osmLog("orbismart: override L=50 R=214 -> override (wake, no)"), "decided first")
    eq(W.osm_server.progress, "/p50", "sent")
    eq(osmRec().override, nil)
end)

test("orbismart: a released reread replaces a completed place short of the end once", function()
    local ui, m, p = osmBook(50, { server = { at = 5000, pct = 0.9, progress = "/p270" } })
    run(1)
    W.osm_status = "complete"
    RE.EOB.session.d1 = { released = true, forward = 10 }
    OSM.installApi()
    OSM.decide("pause")
    eq(W.osm_server.progress, "/p50", "released reread starts behind completed place")
    require("bookorbit_api"):updateProgress("d1", 0.1, "/p30", 4000)
    eq(OSMApi.puts, 1, "exemption consumed after successful push")
    W.osm_status = nil
end)

test("orbismart: a finished-book override is one shot and later stale pushes stay held", function()
    local ui, m, p = osmBook(50, { server = { at = 5000, pct = 1, progress = "/p300" } })
    run(1)
    W.osm_status = "complete"
    OSM.installApi()
    OSM.readFromHere("test")
    run(30)
    eq(W.osm_server.progress, "/p50", "backward override starts reread")
    require("bookorbit_api"):updateProgress("d1", 0.1, "/p30", 4000)
    eq(OSMApi.puts, 1, "reread release cannot exempt another backward push")
    W.osm_status = nil
end)

test("orbismart: offline override sends the chosen place before an older outbox snapshot", function()
    local ui, m, p = osmBook(50, { server = { at = 5000, pct = 214 / 300, progress = "/p214" } })
    run(1)
    OSM.installApi()
    W.server_code = nil
    OSM.readFromHere("test")
    run(40)
    eq(osmRec().override.progress, "/p50", "chosen place persisted")
    W.page = 80
    W.server_code = 200
    require("bookorbit_api"):updateProgress("d1", 0.1, "/p30", 4000)
    eq(W.osm_server.progress, "/p50", "override precedes the stale snapshot and later reading")
    eq(osmRec().override, nil, "acknowledged once")
    require("bookorbit_api"):updateProgress("d1", 0.1, "/p30", 4000)
    eq(OSMApi.puts, 1, "stale snapshot is now held")
end)

test("orbismart: a deferred pull cannot move or ask for a different open book", function()
    local ui, m, p = osmBook(120, {})
    run(1)
    OSM.installApi()
    osmServer(214, 5000)
    OSM.onPulled("d1", W.osm_server)
    p.getDocumentDigest = function() return "d2" end
    run(1)
    eq(osmPopup(), nil)
    eq(W.page, 120)
end)

test("orbismart: a further place found at sleep is asked at wake, before any network", function()
    W.screen_on = false
    local ui, m, p = osmBook(120, nil)
    osmServer(120, 4000)
    m:onReaderReady()
    run(30)
    osmServer(214, 5000)
    m:onSuspend()
    run(30)
    eq(osmPopup(), nil, "nothing shown at sleep")
    ok(osmRec().pending, "kept for the wake")
    ok(osmLog("orbismart: rule3 L=120 R=214 -> take (sleep, wake)"), "logged")
    W.server_code = nil -- the wake's network never comes up
    m:onResume()
    local w = osmPopup()
    ok(w and w.text == "Continue from Boox, p. 214?", "asked at once")
    osmAnswer(true)
    eq(W.page, 214)
    run(40)
    W.server_code = 200
end)

test("orbismart: an update keeps Custom for a reader whose sync settings were changed by hand", function()
    local S0 = store.orbit_android
    local saved = { S0.reading_schedule, S0.sync_mode, S0.settings_at.sync_mode }
    S0.orbismart_migrated, S0.reading_schedule, S0.sync_mode, S0.settings_at.sync_mode = nil, "pg25", "orbismart", 1
    OSM.migrate()
    eq(S0.sync_mode, "custom", "Sync while reading was set by hand")
    ok(S0.settings_at.sync_mode > 1, "sent to the companion")
    S0.orbismart_migrated, S0.reading_schedule, S0.sync_mode, S0.settings_at.sync_mode = nil, "off", "orbismart", 1
    OSM.migrate()
    eq(S0.sync_mode, "orbismart", "untouched settings: OrbiSmart")
    S0.orbismart_migrated, S0.reading_schedule, S0.settings_at.sync_mode = nil, "pg25", 5000
    OSM.migrate()
    eq(S0.sync_mode, "orbismart", "a Sync value chosen already stays")
    OSM.migrate()
    S0.reading_schedule, S0.sync_mode, S0.settings_at.sync_mode = saved[1], saved[2], saved[3]
end)

test("orbismart: no wake check after a short nap", function()
    local ui, m, p = osmBook(120, nil)
    run(30)
    p.calls = {}
    RE.state.paused_for = 60
    m:wakeFlow("wake")
    run(30)
    ok(not has(p.calls, "fetch"), "no pull")
    ok(osmLog("no wake check under 300 s"), "logged")
    RE.state.paused_for = nil
end)

test("orbismart: a move back elsewhere (an override there) is asked, labelled", function()
    local ui, m, p = osmBook(214, { server = { at = 4000, pct = 214 / 300, progress = "/p214" }, m = { at = 4000, pct = 214 / 300, progress = "/p214" } })
    m:onReaderReady()
    run(5)
    osmServer(12, 5000, "X4 Pro")
    p:fetchRemoteProgress("d1", function() end)
    run(2)
    local w = osmPopup()
    ok(w and w.text == "Continue from X4 Pro, p. 12 (moved back there)?", w and w.text)
    osmAnswer(true)
    eq(W.page, 12)
end)

test("orbismart: OrbiSmart enables automatic lifecycle sync and Custom restores it", function()
    local ui, m, p = osmBook(120, {})
    run(1)
    p.settings.auto_sync = false
    OSM.preset(p)
    eq(p.settings.auto_sync, true, "lifecycle snapshots and drains enabled")
    eq(OSM.savedPluginSetting("auto_sync").value, false, "Custom value kept")
    store.orbit_android.sync_mode = "custom"
    OSM.modeChanged("test")
    eq(p.settings.auto_sync, false, "Custom value restored")
    store.orbit_android.sync_mode = "orbismart"
end)

test("orbismart: the plugin never moves the reader itself (today's newest-dated jump); Custom gives its settings back", function()
    local ui, m, p = osmBook(120, nil)
    p.settings.sync_forward, p.settings.sync_backward = 2, 3
    m:onReaderReady()
    eq(p.settings.sync_forward, 3, "further ahead: Don't sync")
    eq(p.settings.sync_backward, 3, "further behind: Don't sync")
    -- A newer-dated place behind this reader, while reading here: furthest wins, no move.
    for pg = 121, 125 do W.page = pg; m:onPageUpdate(pg) end
    p.last_page_turn_timestamp = os.time()
    osmServer(60, os.time() - 30)
    store.orbit_android.orbismart.d1 = { m = { at = 1, pct = 120 / 300, progress = "/p120" } }
    p:fetchRemoteProgress("d1", function() end)
    run(2)
    eq(W.page, 125, "not moved back")
    eq(osmPopup(), nil, "not asked either")
    ok(osmLog("orbismart: rule6 L=125 R=60 -> push"), "furthest wins")
    store.orbit_android.sync_mode = "custom"
    OSM.modeChanged("test")
    eq(p.settings.sync_forward, 2, "given back")
    store.orbit_android.sync_mode = "orbismart"
end)

test("orbismart: Recommended settings review the plugin's own value kept for Custom", function()
    local ui, m, p = osmBook(50, nil)
    p.settings.sync_forward, p.settings.sync_backward = 1, 3
    m:onReaderReady()
    eq(OSM.savedPluginSetting("sync_forward").value, 1, "the reader's Ask, kept")
    ok(OSM.setSavedPluginSetting("sync_forward", 2), "Recommended writes the kept value")
    eq(p.settings.sync_forward, 3, "OrbiSmart's stays in force")
    store.orbit_android.sync_mode = "custom"
    OSM.modeChanged("test")
    eq(p.settings.sync_forward, 2, "Custom gets the recommended value")
    eq(OSM.savedPluginSetting("sync_forward"), nil, "nothing kept under Custom")
    store.orbit_android.sync_mode = "orbismart"
end)

test("orbismart: This book sheet gets Read from here everywhere", function()
    local made = {}
    package.loaded["bookorbit_menu_ui"] = { row = function(w, o) local r = { row = o }; table.insert(made, r); return r end,
        divider = function() return { divider = true } end }
    package.loaded["bookorbit_menu_page"] = { runAction = function(page, action) page.ran = action.kind end }
    package.loaded["bookorbit_board_ui"] = { vstack = function(o, kids) return { stack = kids } end }
    local ui, m, p = osmBook(50, { server = { at = 5000, pct = 0.7, progress = "/p210" } })
    OSM.sheet_hooked = nil
    m:onReaderReady()
    local MenuUI = package.loaded["bookorbit_menu_ui"]
    local auto = MenuUI.row(400, { label = "Auto-sync", action = { kind = "auto" } })
    ok(auto.stack and auto.stack[3].row.label == "Read from here everywhere", "the row under Auto-sync")
    local other = MenuUI.row(400, { label = "Book details", action = { kind = "details" } })
    eq(other.stack, nil, "other rows unchanged")
    local page = { close = function(pg) pg.closed = true end }
    package.loaded["bookorbit_menu_page"].runAction(page, { kind = "orbit_read_here" })
    ok(page.closed, "sheet closed")
    run(1)
    ok(osmLog("orbismart: override queued (This book)"), "override made from the sheet")
    package.loaded["bookorbit_menu_page"].runAction(page, { kind = "sync" })
    eq(page.ran, "sync", "the sheet's own actions still run")
    run(40)
end)

test("orbismart: menu: Sync first in its section; the rows it sets hidden; the override in a book", function()
    local ui, m = osmBook(50, nil)
    local sync
    for _, it in ipairs(m:menuItems()) do if it.text == "Sync and Wi-Fi" then sync = it.sub_item_table end end
    ok(sync[1].text_func():find("Sync: OrbiSmart", 1, true), sync[1].text_func())
    local texts = {}
    for _, it in ipairs(menuAll(m:menuItems())) do texts[#texts + 1] = it.text or (it.text_func and it.text_func()) or "" end
    local all = table.concat(texts, "|")
    ok(all:find("Read from here everywhere", 1, true), "override item")
    ok(not all:find("Sync on wake", 1, true), "hidden under OrbiSmart")
    store.orbit_android.sync_mode = "custom"
    texts = {}
    for _, it in ipairs(menuAll(m:menuItems())) do texts[#texts + 1] = it.text or (it.text_func and it.text_func()) or "" end
    all = table.concat(texts, "|")
    ok(all:find("Sync on wake", 1, true), "shown under Custom")
    ok(not all:find("Read from here everywhere", 1, true), "no override under Custom")
end)

test("About: the locked menu shows every shared credit paragraph and the project URL", function()
    local _, m = newUI(false)
    local items = m.readOnly(m:menuItems())
    local about
    for _, it in ipairs(items) do if it.text == "About" then about = it end end
    ok(about and about.callback, "About remains available without unlocking")
    ok(not about.enabled_func or about.enabled_func(), "About is enabled")
    W.shown = {}
    about.callback()
    run(1)
    local widget = W.shown[#W.shown]
    ok(widget and widget.text, "About opens a text viewer")
    local f = assert(io.open(here .. "/../../../shared/about/credits.json", "rb"))
    local credits = dofile(here .. "/json_mini.lua").decode(f:read("*a"))
    f:close()
    for _, text in ipairs(credits.paragraphs) do ok(widget.text:find(text, 1, true), text) end
    ok(widget.text:find(credits.url, 1, true), "visible project URL")
    ok(not widget.text:lower():find("powered by", 1, true), "no misleading credit")
end)

store.orbit_android.sync_mode = "custom"

dofile(here .. "/status_layout_flows.lua")(here, test, ok, eq)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
    for _, l in ipairs(W.logs) do print(l) end
    os.exit(1)
end

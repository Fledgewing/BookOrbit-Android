-- Loads the whole patch against small stand-ins for KOReader, the JNI bridge and the
-- BookOrbit plugin, then drives the flows on a fake clock. It catches wiring mistakes
-- (typos, nil calls, wrong order) that the pure tests can't; it proves nothing about
-- the device. Needs LuaJIT (the patch uses ffi): luajit android/koreader/test/test_flows.lua
local here = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."
-- KOReader's SQLite binding on the host (the offline cache's database: ko/db.lua, ko/store.lua).
dofile(here .. "/sqlite_shim.lua")

---------------------------------------------------------------- fake world
local W = {
    clock = 1000, queue = {}, seq = 0, shown = {}, presented = {}, logs = {},
    wifi = true, vpn = true, screen_on = false, companion = true, server_code = 200,
    broadcasts = {}, activities = {}, intent_extras = {},
    fetched = {}, web = {}, json = {}, files = {}, children = {}, ino = {},
}
function W.fake_sha(s) return string.format("%064x", #s) end
-- The companion's status call (Companion.status): W.web[STATUS_KEY] is its JSON's W.json key.
local STATUS_KEY = "companion:STATUS"
-- The installed companion's certificate (BigInteger hex, as Jni.packageSigners reads it):
-- BookSync's release key unless a test sets another.
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
    show = function(_, w) table.insert(W.shown, w); table.insert(W.presented, w) end,
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
        if W.main_loop_guard then W.main_loop_guard(t.fn, t.args) else t.fn(unpack(t.args)) end
    end
end

-- Bound UI work, not host speed: companion/child fakes may do arbitrary background IO.
-- Wrap the file methods too, so repeated reads on one handle cannot evade the open budget.
local function uiWorkBudget(fn, budget)
    local lfs = require("libs/libkoreader-lfs")
    local methods = getmetatable(io.stdout).__index
    local saved = { open = io.open, read = methods.read, dir = lfs.dir, deliver = W.deliver }
    local counts = { opens = 0, reads = 0, bytes = 0, walks = 0, entries = 0, intents = 0 }
    local function ui() return not W.in_companion and not W.in_child end
    io.open = function(...)
        if ui() then counts.opens = counts.opens + 1 end
        return saved.open(...)
    end
    methods.read = function(...)
        local on_ui = ui()
        if on_ui then counts.reads = counts.reads + 1 end
        local result = { saved.read(...) }
        if on_ui then
            for _, v in ipairs(result) do if type(v) == "string" then counts.bytes = counts.bytes + #v end end
        end
        return unpack(result)
    end
    lfs.dir = function(...)
        if ui() then counts.walks = counts.walks + 1 end
        local iter, state, first = saved.dir(...)
        return function(...)
            if ui() then counts.entries = counts.entries + 1 end
            return iter(...)
        end, state, first
    end
    W.deliver = function(...)
        if ui() then counts.intents = counts.intents + 1 end
        return saved.deliver(...)
    end
    local success, err = pcall(fn)
    io.open, methods.read, lfs.dir, W.deliver = saved.open, saved.read, saved.dir, saved.deliver
    if not success then error(err, 0) end
    -- Small status/ack files are allowed; catalog/cover inventory belongs to the companion.
    local limits = budget or { opens = 8, reads = 8, bytes = 64 * 1024, walks = 0, entries = 0, intents = 4 }
    for kind, limit in pairs(limits) do
        assert(counts[kind] <= limit, "UI " .. kind .. " budget exceeded: " .. counts[kind] .. " > " .. limit)
    end
    return counts
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
    if W.intent_window then
        local window = W.intent_window
        while window[1] and window[1] <= W.clock - 60 do table.remove(window, 1) end
        window[#window + 1] = W.clock
        W.intent_max = math.max(W.intent_max or 0, #window)
        assert(#window <= 30, "companion intent budget exceeded: " .. #window .. " in 60 seconds")
    end
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
local stockShowReader = ReaderUI.showReader
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
        if type(it.sub_item_table) == "table" then menuAll(it.sub_item_table, out)
        elseif it.settings_group then menuAll((it.sub_item_table_func or it.settings_rows)(), out) end
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
local executed = {}
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
    executed[name] = true
    W.intent_window, W.intent_max = {}, 0
    local t0 = W.wall()
    local ok, err = withLimit(name, fn)
    if (W.intent_max or 0) > 30 then ok, err = false, "companion intent budget exceeded: " .. W.intent_max .. " in 60 seconds" end
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

test("harness: UI budgets reject walks, repeated/bulk reads and intents, but allow worker IO", function()
    local path = os.tmpname()
    local f = assert(io.open(path, "wb")); f:write(string.rep("x", 65537)); f:close()
    local function rejects(kind, fn)
        local success, err = pcall(uiWorkBudget, fn)
        ok(not success and tostring(err):find("UI " .. kind .. " budget exceeded", 1, true), tostring(err))
    end
    rejects("opens", function() for i=1,9 do local h=assert(io.open(path)); h:close() end end)
    -- One already-open file must not evade the read-call or byte budget.
    f = assert(io.open(path, "rb"))
    rejects("reads", function() for i=1,9 do f:read(1) end end)
    f:seek("set")
    rejects("bytes", function() f:read("*a") end)
    f:close()
    local lfs = require("libs/libkoreader-lfs")
    local dir = lfs.dir
    lfs.dir = function() return function() return nil end end
    rejects("walks", function() lfs.dir(".") end)
    rejects("intents", function() for i=1,5 do W.deliver({ action = "test", extras = {} }) end end)
    local success, err = pcall(uiWorkBudget, function()
        W.in_companion = true
        for i=1,9 do local h=assert(io.open(path)); h:read("*a"); h:close() end
        for _ in lfs.dir(".") do end
        W.in_companion = nil
    end)
    W.in_companion = nil
    lfs.dir = dir
    os.remove(path)
    ok(success, err)
end)

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

test("home from the companion: library home opens over the book, which stays open", function()
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
    ok(entry and entry.text == "BookSync" and entry.sorting_hint == "tools", "Tools entry")
    local sub = entry.sub_item_table_func()
    ok(#sub >= 9, "items " .. #sub)
    local titles = {}
    for _, it in ipairs(sub) do if it.text then titles[it.text] = true end end
    for _, t in ipairs({ "Home", "Reading", "Sync, Wi-Fi & power", "Library & downloads", "Updates", "About & help" }) do
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
    ok(viewer and viewer.text and viewer.text:match("5%. library plugin synced ✓"), viewer and viewer.text or "no viewer")
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
    ok(m:statusText():find("BookSync Companion is disabled by", 1, true), "menu status: " .. m:statusText())
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
    ok(m:statusText():find("BookSync Companion: 2 setup steps need you", 1, true), "status: " .. m:statusText())
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
    ok(box.text == "BookSync Companion needs 1 setup step: Clicker buttons (accessibility).", box.text)
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

test("a command on KOReader's start that BookSync Companion didn't send is ignored", function()
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
    -- The next process: KOReader starts in the file browser, library home opened over it.
    W.opened = nil
    local ui2, m2 = newUI(false)
    local cb = {}
    cb.close_callback = function() ui2.bookorbit.catalog_browser = nil; W.catalog_closed = true end
    ui2.bookorbit.catalog_browser = cb
    W.catalog_closed = false
    m2:reopenAfterRestart("start") -- what init schedules 1 s after a start with restart_book set
    run(1)
    ok(W.opened == "/b.epub", "the book reopened: " .. tostring(W.opened))
    ok(W.catalog_closed, "library home closed so the book is on top")
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
    ok(not RE.Companion.send(RE.Companion.ACTION.SLEEP_REFRESH, { server = "https://books.example", user = "u", userkey = "k" }), "not sent")
    ok(#W.broadcasts == 0, "nothing reached it")
    ok(RE.Companion.status() == nil, "no status asked")
    ok(RE.Companion.workerProblem() ~= nil, "nothing heavy runs")
    ok(tostring(RE.Companion.problem()):find("not a BookSync release", 1, true), "the menus' problem line")
    W.companion_cert = RELEASE_CERT
    RE.installed_cache.at = -1000
    ok(RE.Companion.state() == "ok", "the release-signed one is used")
    ok(RE.Companion.send(RE.Companion.ACTION.SETUP_LATER, {}), "sent")
    ok(W.broadcasts[#W.broadcasts].kind == "call", "through the caller-checked call, not a broadcast")
    -- Replacing the app must not inherit a recent menu/status check's cached trust.
    W.companion_cert = "1234abcd"
    W.broadcasts = {}
    ok(not RE.Companion.send(RE.Companion.ACTION.SLEEP_REFRESH, { userkey = "k" }), "cached trust cannot send a credential")
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
    local mailbox_file = assert(io.open(here .. "/../../companion/app/src/main/java/net/fledgewing/orbitcompanion/EventMailbox.kt", "rb"))
    local mailbox_source = mailbox_file:read("*a"); mailbox_file:close()
    local workflows=assert(io.open(here .. "/../../companion/app/src/main/java/net/fledgewing/orbitcompanion/LibraryAccount.kt","rb"))
    mailbox_source=mailbox_source..workflows:read("*a");workflows:close()
    local cache=assert(io.open(here .. "/../../companion/app/src/main/java/net/fledgewing/orbitcompanion/server/bookorbit/CacheWorker.kt","rb"))
    mailbox_source=mailbox_source..cache:read("*a");cache:close()
    local actions=assert(io.open(here .. "/../../companion/app/src/main/java/net/fledgewing/orbitcompanion/server/bookorbit/CatalogWorkflow.kt","rb"))
    mailbox_source=mailbox_source..actions:read("*a");actions:close()
    for _, f in ipairs(C.files) do
        local name = f.path:gsub("/$", ""):match("[^/]+$")
        local source = f.reader == "companion" and (src .. mailbox_source) or src
        ok(source:find(esc(name), 1), "file " .. name)
    end
    eq(RE.Store.VERSION, C.db.user_version, "orbit.db user_version")
    eq(RE.Store.FILE, C.db.file:match("[^/]+$"))
    local schema = assert(io.open(here .. "/../../../" .. C.db.schema, "rb"))
    local tables = {}
    for name in schema:read("*a"):gmatch("CREATE TABLE ([%w_]+)") do tables[#tables + 1] = name end
    schema:close()
    eq(table.concat(tables, ","), table.concat(C.db.tables, ","), "every orbit.db table")
end)

test("library bridge: real JNI decoding returns command IDs and bounded state/result fields",function()
    local call=W.companionCall
    local body=RE.Cache.encode({title="Résumé",local_path="/fixture/é.epub"})
    W.companionCall=function() return {kind="bundle",extras={ok="1",id="job-1",body=body,owner="lecteur-é",pending="1"}} end
    local success,err=pcall(function()
        local result=RE.Jni.call(RE.Companion.AUTHORITY,RE.Companion.PACKAGE..".call.SERVER_STATE",{reload="1"})
        eq(result.id,"job-1");eq(result.body,body);eq(result.owner,"lecteur-é");eq(result.pending,"1")
        eq(RE.Cache.decode(result.body).title,"Résumé")
    end)
    W.companionCall=call
    ok(success,err)
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
    RE.Recommendations.session_applied, RE.Recommendations.line_pending = 0, false
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
    ok(shownText("Synced. Press the power button to sleep.\nBookSync Companion can do this for you"), "the hint, once")
    W.shown = {}
    m:onOrbitSyncAndSleep()
    run(30)
    ok(shownText("Synced. Press the power button to sleep.") and not shownText("can do this for you"), "hint only once")
    W.shown = {}
    m:onOrbitOpenApps()
    ok(shownText("Use your reader's Home button for other apps."), "apps message")
    ok(#W.activities == 0, "no activity started")
    ok(m:openCompanionHome() == true and #W.activities == 0, "Home at library home stays")
    local hasWifiRow, hasHelperLine, hasApps = false, false, false
    for _, it in ipairs(menuAll(m:menuItems())) do
        if it.text == "Let BookSync switch Wi-Fi for syncs" then hasWifiRow = true; eq(it.enabled_func(), false, "unavailable control is visible and disabled") end
        if it.text == "Wi-Fi switching and sleep sync: in BookSync Companion ›" then hasHelperLine = true end
        if it.text == "Open another app…" then hasApps = true end
    end
    ok(hasWifiRow and not hasApps, "settings remain visible in Add-on mode")
    ok(RE.Shared.mode() == "always_on", "Wi-Fi as left: Always on")
    capsReset()
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
    ok(shownText("BookSync v9.9.9 is installed: close KOReader and open it again to finish."), "message")
    RE.patchFileVersion = was
    capsReset()
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
    local box, line = shownText("BookSync Companion needs 1 setup step: Signed in to BookOrbit."), m:statusText()
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

test("clicker: a listener on the port that can't prove it is BookSync Companion is dropped", function()
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
    ok(table.concat(W.logs, "\n"):find("it is not BookSync Companion", 1, true), "logged")
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

test("smart home: pressed in a book -> library home", function()
    local ui, m = newUI(true)
    run(5)
    W.home_called = false
    m:onSuspend(); W.clock = W.clock + 0.5
    command(m, "home_smart")
    m:onResume()
    run(1)
    ok(has(ui.bookorbit.calls, "dashboard") and not W.home_called, "library home over the book")
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

test("smart home: from the file browser with no book open -> library home, not history", function()
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
    ok(has(ui.bookorbit.calls, "dashboard"), "library home")
end)

test("smart home: book -> library home -> companion -> back to the book", function()
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
    ok(ui.bookorbit.catalog_browser ~= nil and W.shown[#W.shown] == ui.bookorbit.catalog_browser, "1: library home")
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

test("home: plugin handlers wrapped by KOReader 2026.07 -> Home on the file browser opens library home", function()
    store.lastfile = nil
    local ui, m = newUI(false)
    sandboxed(ui.bookorbit)
    run(5)
    W.shown, W.activities = { { name = "filemanager" } }, {}
    command(m, "home_smart", "other_app")
    m:onResume()
    run(2)
    ok(has(ui.bookorbit.calls, "dashboard"), "dashboard handler ran")
    ok(W.shown[#W.shown] == ui.bookorbit.catalog_browser, "library home on top")
    ok(#W.activities == 0, "no companion page")
    ui.bookorbit.catalog_browser = nil
    W.shown = {}
end)

test("home: the instance shows no handler but the UI routes the event -> library home opens", function()
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
    ok(W.shown[#W.shown] == real.catalog_browser, "library home on top")
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
    ok(homeText() == "Home button in KOReader: Back to my book, then Server plugin's Home", tostring(homeText()))
    W.json.STATUS = { version = "0.4.8", settings = { settings_at = 0, home_opens = "launcher" } }
    m:onResume(); run(1)
    ok(homeText():find("Home button in KOReader", 1, true), homeText())
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

test("compat: a catalog without dashboardMode -> not treated as library home", function()
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

test("smart home: no last book -> library home", function()
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
    test("home (" .. cmd .. "): pressed on library home -> the companion's launcher page", function()
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

test("home: from the companion page while library home is on top, no book -> library home", function()
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

test("home: file browser on top of a stale library home -> library home brought to the top", function()
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
    ok(top == ui.bookorbit.catalog_browser, "library home is on top")
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

test("home: library home on page 2 -> page 1, not the companion", function()
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
    ok(actions.orbit_open_apps and actions.orbit_open_apps.title == "BookSync Companion: apps", "action title")
    local R = getfenv(Orbit.onSuspend).Recommended
    ok(R.item("g.apps").ours.orbit_open_apps and R.item("g.apps").key == "two_finger_swipe_north", "two-finger swipe up")
end)

---------------------------------------------------------------- updates (BookSync Companion)
-- The plugin and the companion ship together: the menu's check asks the companion (UPDATE), and
-- the plugin downloads, unpacks and installs nothing itself (docs/design/companion-worker.md).
local function updateBroadcasts() return count(W.broadcasts, function(b) return b.action:sub(-7) == ".UPDATE" end) end

test("update: the menu's check asks BookSync Companion; the plugin fetches nothing and forks nothing", function()
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
    ok(tostring(W.shown[#W.shown].text):find("BookSync Companion is checking", 1, true), "says the companion checks")
end)

test("update: without the companion of this version the menu says what to do and asks nothing", function()
    local UE = getfenv(Orbit.onSuspend)
    local real = UE.Companion.workerProblem
    local asked
    UE.Companion.workerProblem = function(purpose) if purpose then asked = purpose end; return "BookSync Companion needed " .. tostring(purpose) end
    W.broadcasts, W.shown = {}, {}
    local _ui, orbit = newUI(false)
    orbit:checkPatchUpdate()
    run(2)
    UE.Companion.workerProblem = real
    ok(updateBroadcasts() == 0, "nothing sent")
    ok(asked == "to check for updates", "the update's own wording: " .. tostring(asked))
    ok(tostring(W.shown[#W.shown].text):find("BookSync Companion needed", 1, true), "says so")
    ok(store.orbit_android.patch_update_status.text:find("BookSync Companion needed", 1, true), "status line too")
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
    ok(#RE.Gate.queue >= 2, "held user notices (wake banner suppressed): " .. #RE.Gate.queue)
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

test("one update: after restart status is saved without a background pill", function()
    restartReset(); stampSelf("0.0.0-dev")
    store.orbit_android.restart_tried = "0.0.0-dev"
    W.shown = {}
    local _ui, m = newUI(false)
    m:onResume()
    run(3)
    local found = false
    for _, w in ipairs(W.shown) do if tostring(w.text) == "Updated to v0.0.0-dev" and w.orbit_note then found = true end end
    ok(not found, "background completion stays in status, without a pill")
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

test("settings PIN: a locked companion makes the BookSync menu read-only, with the keypad one tap away; unreachable stays usable", function()
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
        if i > 1 and it.callback and not it.settings_group and not it.sub_item_table and not it.keep_menu_open and not it.read_only and not (it.enabled_func and it.enabled_func() == false) then
            enabled = enabled + 1
        end
    end
    eq(enabled, 0, "no control enabled while locked")
    local wifi = RE.S.sync_on_wake
    for _, it in ipairs(all) do if it.text == "Sync when it wakes" then it.callback() end end
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
    ui.bookorbit.newClient = function() return setmetatable({ server_url = "https://books.example", username = "reader", userkey = "k",
        query = function(_, path) return path end }, EApi) end
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
    package.loaded["bookorbit_delivery"] = { preference = function() return "audioless_epub" end }
    E.Copies.md5 = function(path) return copies.md5s[path] end
    -- BookSync Companion finds the changed copies (fake_companion.lua), on its own cache folder.
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
    copies.fc.copyMd5 = function(job) return copies.md5s[job.path] end
    copies.fc.prepareCopy = function(job)
        ok(W.in_companion, "copy preparation belongs to companion")
        return DCat:fetchDeliveryBook(job.book_id)
    end
    W.on_broadcast = copies.fc.receive
    E.Copies.state().queue = {}
    E.Copies.scanned_at, E.Copies.active, E.Copies.busy, E.Copies.asked = nil, nil, nil, nil
    W.wifi, W.vpn, W.companion = true, true, true
end
local function copiesTeardown()
    package.loaded["bookorbit_catalog"] = nil
    package.loaded["bookorbit_delivery"] = nil
    W.on_broadcast = nil
    E.Companion.workerProblem = copies.saved_problem
    E.OC._dir, E.OC._index = copies.saved_dir, nil
    require("libs/libkoreader-lfs").dir = copies.lfs_dir
    sh("rm -rf", copies.dir)
end
local function copiesUI(in_book)
    local ui, m = newUI(in_book)
    ui.bookorbit.newClient = function() return setmetatable({ server_url = "https://books.example", username = "reader", userkey = "k",
        query = function(_, path) return path end }, EApi) end
    return ui, m
end
local function copyBooks()
    return {
        old1 = { file = "/books/a.epub", bookId = 1, fileId = 10, positionIncompatible = true },
        old2 = { file = "/books/b.epub", bookId = 2, fileId = 20, positionIncompatible = true },
        cur3 = { file = "/books/c.epub", bookId = 3, fileId = 30 },
    }
end

-- Emit through every notice API used by native background work. These stand-ins
-- retain the real Toast loading-handle and Trapper coroutine contracts.
local function noticeFixture()
    local savedToast, savedTrapper = package.loaded["bookorbit_toast"], package.loaded["ui/trapper"]
    local Info = require("ui/widget/infomessage")
    local function show(text) local w = Info:new{ text = text }; UIManager:show(w); return w end
    local Toast = { show = show, error = show, loading = function(text)
        local w = show(text); w.close = function() UIManager:close(w) end; return w
    end }
    local Trapper = { wrap = function(_, fn)
        local okc, err = coroutine.resume(coroutine.create(fn)); assert(okc, err)
    end, info = function(_, text) show(text); return true end }
    package.loaded["bookorbit_toast"], package.loaded["ui/trapper"] = Toast, Trapper
    E.Gate.installToast()
    local function burst(label)
        Toast.loading(label .. ": Loading book..."):close()
        Toast.loading(label .. ": Loading EPUB delivery preference..."):close()
        Toast.show(label .. ": saved")
        Toast.error(label .. ": error")
        E.orbitNote(label .. ": own note")
        UIManager:show(Info:new{ text = label .. ": direct InfoMessage" })
        UIManager:show(require("ui/widget/notification"):new{ text = label .. ": Notification" })
        Trapper:info(label .. ": Trapper")
    end
    return burst, function()
        package.loaded["bookorbit_toast"], package.loaded["ui/trapper"] = savedToast, savedTrapper
    end, Trapper
end
local function noticeLog(text)
    return count(W.logs, function(line) return line:find(text, 1, true) ~= nil end) > 0
end

test("background notices: start and wake pulls are silent, including delayed callbacks and offline errors", function()
    local burst, restore, Trapper = noticeFixture()
    local ui, m = newUI(false)
    local p = ui.bookorbit
    local pulls = 0
    function p:requestLifecycleOutboxDrain()
        pulls = pulls + 1
        burst("pull")
        UIManager:nextTick(function() burst("delayed pull") end)
        Trapper:wrap(function()
            burst("coroutine pull")
            local co = coroutine.running()
            UIManager:scheduleIn(0.1, function() assert(coroutine.resume(co)) end)
            coroutine.yield()
            burst("resumed pull")
        end)
    end
    local started = E.state.started
    E.state.started = false
    m:init()
    W.shown, W.presented = {}, {}
    run(10)
    m:onResume()
    run(10)
    m:showWakeBanner({ detail = "offline wake" })
    ok(pulls >= 2, "both start and wake performed pulls")
    eq(#W.presented, 0, "start, wake and deferred work show zero notices")
    eq(#E.Gate.queue, 0, "background notices are dropped, never deferred")
    for _, label in ipairs({ "pull", "delayed pull", "coroutine pull", "resumed pull" }) do
        for _, text in ipairs({ "Loading book...", "Loading EPUB delivery preference...", "saved", "error", "own note", "direct InfoMessage", "Notification", "Trapper" }) do
            ok(noticeLog("suppressed notice: ") and noticeLog(label .. ": " .. text), "suppression text logged: " .. label .. ": " .. text)
        end
    end
    ok(noticeLog("offline wake"), "wake banner text logged")
    burst("explicit action")
    ok(#W.shown > 0 and noticeLog("notice: shown: explicit action: direct InfoMessage"), "user notices show and log text after background finishes")
    E.state.started = started
    restore()
end)


test("background notices: yielding scope is isolated, error safe, and timers still cancel", function()
    local burst, restore, Trapper = noticeFixture()
    newUI(false)
    W.shown, W.presented = {}, {}
    local co
    E.Gate.background(function()
        Trapper:wrap(function()
            co = coroutine.running()
            coroutine.yield()
            burst("resumed background")
        end)
        local cancel = function() error("cancelled callback ran") end
        UIManager:scheduleIn(0.1, cancel)
        UIManager:nextTick(cancel)
        UIManager:unschedule(cancel)
    end)
    burst("while background yields")
    ok(#W.shown > 0, "concurrent user action is visible")
    W.shown, W.presented = {}, {}
    assert(coroutine.resume(co))
    run(1)
    eq(#W.presented, 0, "resumed coroutine remains silent")
    ok(not pcall(E.Gate.background, function() error("test error") end), "error propagated")
    ok(not E.Gate.inBackground(), "error restored scope")
    restore()
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
    ok(not E.LF.installed and BD.build == build and not (rawget(Cat, "__orbit_stock") or {})["lf:boardRun"], "no local-first hooks installed")
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
    W.shown = { cat }; run(0.1)
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
    W.shown = { cat }; run(0.1)
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
    E.OC.events_read_at, E.OC.events_sent_at, E.OC.events_ack = nil, nil, nil
    E.OC.events_polling = nil
    E.OC.storage_asked, E.OC.storage_again, E.OC.storage_last = nil, nil, nil
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
    E.Mirror.active, E.Mirror.busy, E.Mirror.manual, E.Mirror.notices, E.Mirror.preparing = nil, nil, nil, nil, nil
    E.Badge.running = nil; E.Badge.close()
    for _, k in ipairs({ "bookorbit_api", "bookorbit_catalog", "bookorbit_board_data", "bookorbit_list_view", "bookorbit_board_ui", "ui/trapper" }) do
        package.loaded[k] = nil
    end
    E.OC.installed = nil
    W.on_broadcast = nil
    if cache.real_workerProblem then E.Companion.workerProblem = cache.real_workerProblem end
    FC.kill()
end
local DASH = "/koreader/plugin/catalog/dashboard"











test("covers: low-level legacy calls are local only even with caching disabled", function()
    local client = cacheSetup()
    local saved=E.Library.cachedCover
    E.Library.cachedCover=function(path) return path=="/fixture/cached.jpg" and path or nil end
    E.S.offline_cache=false
    eq(client:downloadCatalogThumbnail(7,"/fixture/cached.jpg"),true)
    eq(client:downloadCatalogThumbnail(7,"/fixture/missing.jpg"),nil)
    eq(client:downloadCatalogAuthorPhoto(7,"/fixture/missing.jpg"),nil)
    eq(cache.stock_cover,nil); eq(#cache.calls,0)
    E.Library.cachedCover=saved; E.S.offline_cache=true
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
    local hosts = E.serverPlugin
    E.serverPlugin = function() return { catalog_browser = cat } end
    local okf, err = pcall(fn)
    E.serverPlugin = hosts
    if not okf then error(err, 0) end
end

-- @fixture catalog/sections.json












test("covers: companion batches never fork and stale results cannot redraw", function()
    local function prep(Cat)
        function Cat:thumbnailEntry(book)
            self.thumbnail_memo=self.thumbnail_memo or {}
            local key=tostring(book.id)
            self.thumbnail_memo[key]=self.thumbnail_memo[key] or {path=cache.dir.."/covers/"..key.."_100.jpg"}
            return self.thumbnail_memo[key]
        end
        function Cat:stopThumbnailWorker() self.stopped=true end
        function Cat:updateItems() self.redraws=(self.redraws or 0)+1 end
    end
    local client,Cat=cacheSetup(prep)
    local commands={}; local paths={}
    local cached,command=E.Library.cachedCover,E.LibraryAdapter.command
    E.Library.cachedCover=function(ref) return paths[ref] end
    E.LibraryAdapter.command=function(op,args,done)
        eq(op,"covers.acquire"); ok(not W.in_child,"parent-side dispatch")
        commands[#commands+1]=args
        UIManager:scheduleIn(0.1,function() paths[args.reference]=args.reference; done({local_path=args.reference}) end)
        return true
    end
    local cat=setmetatable({client=client,thumbnail_generation=1,thumbnail_queue={head=1,tail=2,{id=1},{id=2}},
        thumbnail_prefetch_queue={head=1,tail=0}},Cat)
    cat:runThumbnailWorker(1); run(0.5)
    eq(#commands,2); eq(cat.redraws,1); ok(cat.stopped); eq(cache.stock_cover,nil); eq(cache.child_crash,nil)
    cat.thumbnail_queue={head=1,tail=1,{id=3}}; cat.stopped=false
    cat:runThumbnailWorker(1); cat.thumbnail_generation=2; run(0.5)
    eq(cat.redraws,1,"departed generation cannot redraw")
    E.Library.cachedCover,E.LibraryAdapter.command=cached,command
    cacheTeardown()
end)

test("covers: forced recheck dispatches neutral references and never redraws while reading", function()
    local _,Cat=cacheSetup()
    local command=E.LibraryAdapter.command
    local requests={}
    E.LibraryAdapter.command=function(op,args,done)
        eq(op,"covers.acquire"); eq(args.refresh,true); ok(args.server==nil and args.userkey==nil)
        requests[#requests+1]=args.reference
        UIManager:scheduleIn(0.1,function() done({local_path=args.reference}) end)
        return true
    end
    local cat=setmetatable({thumbnail_generation=1},Cat)
    local redraw=0
    function cat:updateItems() redraw=redraw+1 end
    E.OC.recheckCovers(cat,{{path="/fixture/one.jpg"},{path="/fixture/two.jpg"}})
    run(0.5); eq(#requests,2); eq(redraw,1)
    local reading=E.reading; E.reading=function() return true end
    E.OC.recheckCovers(cat,{{path="/fixture/one.jpg"}})
    run(0.5); eq(redraw,1,"reading is never interrupted by a cover completion")
    E.reading=reading; E.LibraryAdapter.command=command
    cacheTeardown()
end)

test("covers: saved local references stay drawable offline while refresh waits", function()
    local function prep(Cat)
        function Cat:thumbnailEntry(book)
            self.thumbnail_memo=self.thumbnail_memo or {}
            self.thumbnail_memo[book.id]=self.thumbnail_memo[book.id] or {path=cache.dir.."/covers/"..book.id.."_200.jpg"}
            return self.thumbnail_memo[book.id]
        end
        function Cat:stopThumbnailWorker() end
        function Cat:updateItems() end
    end
    local _,Cat=cacheSetup(prep)
    local cached,command=E.Library.cachedCover,E.LibraryAdapter.command
    local old=cache.dir.."/covers/1_100.jpg"
    local f=assert(io.open(old,"wb")); f:write("\255\216\255\224cached"); f:close()
    E.Library.cachedCover=function() return old end
    local calls=0
    E.LibraryAdapter.command=function(op,args,done)
        calls=calls+1; eq(op,"covers.acquire")
        UIManager:scheduleIn(0.1,function() done({local_path=old,stale=true}) end)
        return true
    end
    local cat=setmetatable({thumbnail_generation=1,thumbnail_queue={head=1,tail=1,{id=1}},thumbnail_prefetch_queue={head=1,tail=0}},Cat)
    W.wifi=false
    local row=cat:thumbnailEntry({id=1}); eq(row.path,old); eq(row.exists,true); eq(calls,0,"paint is local-only")
    cat:runThumbnailWorker(1)
    eq(cat:thumbnailEntry({id=1}).path,old,"pending acquisition keeps the saved cover")
    run(0.5); eq(cat:thumbnailEntry({id=1}).path,old); eq(#cache.calls,0)
    E.Library.cachedCover,E.LibraryAdapter.command=cached,command
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
    E.Library.catalog_active=true
    local busy, bwhy = E.Wifi.busy()
    ok(busy and bwhy:find("catalog"), "a cache check out at the companion keeps it: " .. tostring(bwhy))
    E.Library.catalog_active=nil
end)

test("suspend: a Home press (app switch) with the book unmoved skips BookOrbit's snapshot; a page turn, Sync and sleep always snapshot", function()
    local snaps = 0
    local p = { last_page = 10 }
    function p:getDocumentDigest() return "d1" end
    function p:getLastPercent() return 0.25 end
    function p:_onSuspend() snaps = snaps + 1 end
    p.onSuspend = p._onSuspend
    local ui = { annotation = { annotations = {} }, doc_settings = { readSetting = function() return { status = "reading" } end } }
    local hosts, inter = E.serverPlugin, E.Jni.isInteractive
    E.serverPlugin = function() return p end
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
    E.serverPlugin, E.Jni.isInteractive = hosts, inter
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




---------------------------------------------------------------- v0.11.2 (M8C test of v0.11.1)


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
    local hosts = RE.serverPlugin
    RE.serverPlugin = function() return ui.bookorbit end
    ok(RE.serverOverBook(RE.serverPlugin()), "browsing for the Wi-Fi plan")
    local st = RE.WifiPlan.new("jit", 2, 0)
    st.in_book, st.last_flow, st.release_at, st.last_activity = true, "wake", W.clock - 1, W.clock
    local a = RE.WifiPlan.decide(st, { now = W.clock, wifi_on = true, browsing = RE.serverOverBook(RE.serverPlugin()) })
    ok(a == nil, "kept on while paging BookOrbit lists over the book")
    RE.serverPlugin = hosts
    W.shown = {}
end)









test("background notices: queued native jobs retain their own interactive flag", function()
    local burst, restore = noticeFixture()
    local ui = newUI(false)
    local submitted = {}
    function ui.bookorbit:submitSyncJob(job) submitted[#submitted + 1] = job end
    E.Gate.installPlugin(ui.bookorbit)
    ui.bookorbit:submitSyncJob{ run = function() burst("queued automatic sync") end }
    ui.bookorbit:submitSyncJob{ interactive = true, run = function() burst("queued manual sync") end }
    W.shown, W.presented = {}, {}
    submitted[1].run()
    eq(#W.presented, 0, "queued background job is silent outside its submitting callback")
    E.Gate.background(submitted[2].run)
    ok(#W.shown > 0, "manual job is visible even if the previous background job starts it")
    restore()
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

-- BookSync Companion refreshes the sleep screen's pool (fake_companion.lua plays SleepPoolBuilder).
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
    W.json.STATUS = { version = "0.12.0", mode = "full", caps = caps, sleep = { shown_by = "BookSync screen saver ✓" } }
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
    item = RE.Sleep.menuItem(m, function(fn) return fn end)
    ok(item, "Tools › BookSync › Sleep screen")
    local rows = item.sub_item_table_func()
    ok(rows[1].text_func() == "Sleep screen: The reader's own", "off by default: " .. rows[1].text_func())
    ok(rows[2].enabled_func() == false, "Pick from waits for Recommended")
    ok(rows[#rows - 1].text_func() == "Shown by: BookSync screen saver ✓", "how the companion shows it")
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
    fc.problem = "Update BookSync Companion"
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

test("sleep screen: Pick from and Leave out list every list and collection, all pages, with counts, saved for offline", function()
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
    -- Lists come in two pages (hasNext), collections whole, as the server sends them.
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
    item = RE.Sleep.menuItem(m, function(fn) return fn end)
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
    ok(got[1] == "Lists" and got[2] == "Cosy Mysteries · 5" and got[13] == "Holiday Picks", "scopes with counts, the last without: " .. tostring(got[13]))
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
    for _, r in ipairs(leave) do if r.text == "Add a rule: Library, list or collection…" then add = r end end
    local lo = texts(add.sub_item_table_func())
    ok(#lo == 15 and lo[3] == "Space Opera · 8", "Leave out lists them offline: " .. #lo)
    add.sub_item_table_func()[4].callback()
    ok(S.sleep_leave_out[1] == "scope:103" and Sleep.ruleLabel("scope:103") == "Short Reads (list)", "rule added: " .. tostring(S.sleep_leave_out[1]))
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
        if not W.in_companion and tostring(path):find(cdir, 1, true) and not tostring(path):find("/events/", 1, true) and not tostring(path):find("/events-batch.lua", 1, true) then reads = reads + 1 end
        return open(path, ...)
    end
    W.wifi = true
    local item
    item = RE.Sleep.menuItem(select(2, newUI(false)), function(fn) return fn end)
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
local FakeStore = dofile(here .. "/fake_store.lua")(RE.ServerCache, SQ3, here .. "/../../../shared/fixtures/cache/schema.sql")

local function fixtureStore()
    local dir = os.tmpname() .. "-store"
    os.execute("mkdir -p '" .. dir .. "'")
    local st = FakeStore.open(dir .. "/orbit.db")
    st:own(DBFX.owner)
    for i, sv in ipairs(DBFX.saves) do
        local key = sv.key or RE.ServerCache.key({ account = DBFX.owner:match("^([^|]*)"), server = DBFX.owner:match("|(.*)$"), method = "GET", path = sv.path })
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

-- @fixture catalog/bulk-refresh/catalog.json @fixture catalog/bulk-refresh/schema.sql








test("reading: a locked cache cannot delay page turns or cold/warm cache reads", function()
    local dir, st = fixtureStore()
    withStore(dir, function()
        local path = DBFX.reads[1].path
        local reading, conn = RE.reading, RE.Db.conn
        RE.reading = function() return false end
        st.conn:exec("CREATE TABLE IF NOT EXISTS library_views (owner TEXT,request TEXT,body BLOB,at INTEGER,PRIMARY KEY(owner,request))")
        st.conn:exec("INSERT INTO library_views VALUES ('"..DBFX.owner.."','tap-warm','{items={}}',1)")
        local warm = RE.Store.library(DBFX.owner, "tap-warm")
        ok(warm ~= nil, "prime the decoded cache before reading")
        local ui, m = newUI(true)
        RE.EOB.page_digests[ui] = { file = ui.document.file, digest = "tap-regression" }
        local bookOf = RE.EOB.bookOf
        RE.EOB.bookOf = function() error("page turn read plugin state") end
        RE.reading = function() return true end
        local opens = 0
        RE.Db.conn = function(...) opens = opens + 1; return conn(...) end
        st.conn:exec("BEGIN EXCLUSIVE")
        local okf, err = pcall(function()
            uiWorkBudget(function()
                for page = 2, 26 do
                    m:onPageUpdate(page)
                    eq(RE.Store.library(DBFX.owner,"tap-warm"), warm, "memory hit")
                    eq(RE.Store.library(DBFX.owner,"tap-cold"), nil, "cold miss skips SQL")
                end
            end, { opens = 0, reads = 0, walks = 0, entries = 0, intents = 0 })
        end)
        st.conn:exec("COMMIT")
        RE.reading, RE.Db.conn, RE.EOB.bookOf = reading, conn, bookOf
        if not okf then error(err) end
        eq(RE.EOB.session["tap-regression"].forward, 24, "forward turns still release the stale-push hold")
        eq(opens, 0, "no SQLite access on a page turn, even under an exclusive lock")
    end)
    st:close()
end)

test("reading: finish sync returns immediately and dispatches only outside reading", function()
    local reading,action=RE.reading,RE.Library.catalogAction
    local done,calls=0,0
    RE.Library.catalogAction=function(op,args,cb) eq(op,"finish.drain");calls=calls+1;cb({ok=true}) end
    RE.reading=function() return true end
    RE.FinishUI.drain({},false,function() done=done+1 end)
    eq(calls,0);eq(done,1)
    RE.reading=function() return false end
    RE.FinishUI.drain({},false,function() done=done+1 end)
    eq(calls,1);eq(done,2)
    RE.reading,RE.Library.catalogAction=reading,action
end)

test("network: even an unanswered probe runs only in a background worker", function()
    run(30)
    local background, probe = RE.Background.run, RE.probeServer
    local job, done
    local jobs, probes = 0, 0
    RE.Background.run = function(name, fn, timeout, cb)
        jobs = jobs + 1; job = { fn = fn, cb = cb }
    end
    RE.probeServer = function()
        probes = probes + 1
        ok(W.in_child, "HTTP must never execute on the UI thread")
        return false, "timeout"
    end
    uiWorkBudget(function()
        RE.Net.up(newPlugin(), { reason = "tap regression", cap = 2, need_server = true }, function() done = true end)
    end)
    eq(jobs, 1, "one background job")
    eq(probes, 0, "no synchronous probe")
    ok(job and not done, "probe pending without blocking input")
    W.in_child = true
    local result = job.fn()
    W.in_child = nil
    -- The whole network budget elapsed while input remained available.
    W.clock = W.clock + 2
    job.cb(result)
    RE.Background.run, RE.probeServer = background, probe
    ok(done and RE.Net.inflight == nil, "timeout completes, no synchronous retry")
    eq(jobs, 1, "no retry job")
    eq(probes, 1, "only the background probe ran")
end)

test("main-loop diagnostics: slow callbacks log, preserve returns/errors and cancel by original identity", function()
    local f = RE.MainLoop.wrap(function() W.clock = W.clock + 0.125; return nil, "kept", false end, "test callback")
    local a, b, c = f()
    eq(a, nil); eq(b, "kept"); eq(c, false)
    ok(table.concat(W.logs, "\n"):find("booksync: main-loop stall 125 ms in test callback", 1, true), "persistent stall diagnostic")
    local bad = RE.MainLoop.wrap(function() W.clock = W.clock + 0.125; error("timing regression") end, "test error")
    local good, err = pcall(bad)
    ok(not good and tostring(err):find("timing regression", 1, true), "errors propagate")
    local slow = setfenv(function() W.clock = W.clock + 0.125 end, RE)
    local nlogs = #W.logs
    UIManager:nextTick(slow)
    run(0.2)
    ok(#W.logs > nlogs and W.logs[#W.logs]:find("booksync: main-loop stall 125 ms", 1, true), "scheduled callbacks are timed")
    local fn = setfenv(function() error("cancelled callback ran") end, RE)
    UIManager:scheduleIn(0, fn)
    UIManager:nextTick(fn)
    UIManager:unschedule(fn)
    run(0.1)
end)

test("sqlite stress: the verdict line", function()
    local line = RE.SqliteStress.verdict({ reads = 900, errors = 0, busy = 3, max_busy_ms = 41 },
        { writes = 1200, errors = 0, max_wait_ms = 12, integrity = "ok" })
    eq(line, "sqlite-stress: 1200 writes, 900 reads, 0 errors, max busy wait 41 ms")
    local l2, notes = RE.SqliteStress.verdict({ reads = 5, errors = 0, max_busy_ms = 0 }, nil)
    eq(l2, "sqlite-stress: 0 writes, 5 reads, 1 errors, max busy wait 0 ms", "no writer answer is an error")
    ok(notes[1]:find("didn't answer") ~= nil)
end)

---------------------------------------------------------------- OrbiSmart sync (docs/design/position-sync.md)
-- A 300-page book; places are pages, xpointers "/p<page>". The BookOrbit plugin's API client is
-- a fake bookorbit_api (getProgress answers W.osm_server; updateProgress stores it), wrapped by
-- ko/server/bookorbit/orbismart.lua like the real one.
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
    RE.Net.inflight, RE.state.started = nil, nil
    store.lastfile = "/b.epub"
    store.orbit_android.open_book_at_exit = store.lastfile
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
    local started, completed = 0, 0
    function p:fetchRemoteProgress(_, cb)
        local function fetch()
            started = started + 1
            local co = coroutine.running()
            UIManager:scheduleIn(0.125, function()
                local resumed, err = coroutine.resume(co)
                assert(resumed, err)
            end)
            coroutine.yield()
            completed = completed + 1
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
    eq(started, 0, "network pull deferred until after construction")
    run(30)
    ok(started > 0, "progress pull actually ran")
    eq(completed, started, "yielding pulls resumed and completed")
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

test("orbismart: scheduled reading sync asks once, no silent jump", function()
    local ui, m, p = osmBook(100, nil)
    osmServer(100, 4000)
    m:onReaderReady()
    run(30)
    eq(osmPopup(), nil, "same place: no popup")
    for pg = 101, 110 do W.page = pg; m:onPageUpdate(pg) end
    osmServer(214, 5000)
    m:readingSync()
    run(5)
    ok(has(p.calls, "fetch"), "the pause pulled")
    local w = osmPopup()
    ok(w and w.text == "Continue from Boox, p. 214?", "asked")
    eq(W.page, 110, "no silent jump mid-book")
    ok(osmLog("orbismart: rule3 L=110 R=214 -> take (pause, ask)"), "logged as a pause")
    osmAnswer(true)
    eq(W.page, 214)
end)

test("orbismart: scheduled reading sync where this reader is further pushes", function()
    local ui, m, p = osmBook(100, nil)
    osmServer(100, 4000)
    m:onReaderReady()
    run(30)
    for pg = 101, 140 do W.page = pg; m:onPageUpdate(pg) end
    m:readingSync()
    run(5)
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

test("settings: Off reading cadence adds no pause sync under the furthest-position rule", function()
    local ui, m, p = osmBook(100, nil)
    RE.S.reading_schedule = "off"
    m:onReaderReady()
    run(30)
    p.calls = {}
    W.page = 110; m:onPageUpdate(110)
    run(150)
    ok(not has(p.calls, "fetch"), "Off means no automatic pause pull")
    eq(OSM.pause_task, nil)
end)

test("settings: sync controls remain visible under either position rule", function()
    local _, m = osmBook(50, nil)
    for _, mode in ipairs({"orbismart", "custom"}) do
        store.orbit_android.sync_mode = mode
        local texts = {}
        for _, it in ipairs(menuAll(m:menuItems())) do texts[#texts+1] = it.text or (it.text_func and it.text_func()) or "" end
        local all = table.concat(texts, "|")
        ok(all:find("Sync when it wakes", 1, true), "wake always visible")
        ok(all:find("Sleep sync limit", 1, true), "sleep budget always visible")
        eq(not not all:find("Read from here everywhere", 1, true), mode == "orbismart")
    end
end)

test("settings: Sync now uses the existing snapshot/drain without sleeping", function()
    local ui, m = newUI(true)
    run(30)
    W.broadcasts = {}; ui.bookorbit.calls = {}
    local release, handled = RE.Wifi.release, nil
    RE.Wifi.release = function(name, flag)
        if name == "sync_and_sleep" then handled = flag end
        return release(name, flag)
    end
    RE.Library.syncNow(m)
    run(5)
    RE.Wifi.release = release
    eq(handled, false, "normal Wi-Fi lease restoration")
    eq(lastBroadcast(".NET_DONE").extras.reason, "menu_sync")
    ok(has(ui.bookorbit.calls, "onSuspend"), "current position snapshotted")
    ok(not lastBroadcast(".SLEEP_NOW"), "screen stays awake")
end)

test("settings: failed Sync now leaves the screen awake", function()
    W.server_code = nil
    local _, m = newUI(true)
    run(30)
    W.broadcasts = {}
    RE.Library.syncNow(m)
    run(40)
    ok(not lastBroadcast(".SLEEP_NOW"), "failed sync also stays awake")
    eq(lastBroadcast(".NET_DONE").extras.reason, "menu_sync")
    W.server_code = 200
end)

test("settings PIN: keep-open Custom editors and copy remain read-only", function()
    local _,m = newUI(false)
    local reading
    for _,group in ipairs(m:lockedMenuItems()) do
        if group.settings_group == "reading" then reading=group.sub_item_table_func() end
    end
    ok(reading)
    local before=RE.Library.readingCustom()
    for _,i in ipairs({2,4,6,8,9}) do
        local r=reading[i]
        eq(r.enabled_func(),false,"locked Custom/copy row " .. i)
        r.callback()
        eq(RE.CustomReading.editor,nil)
        eq(RE.CustomReading.copy_toast,nil)
    end
    for k,v in pairs(before) do eq(RE.Library.readingCustom()[k],v,"locked values stay unchanged") end
    local about=RE.OrbitAndroid.readOnly({{read_only=true,keep_menu_open=true,callback=function() end}})
    eq(about[1].enabled_func,nil,"explicit read-only navigation remains available")
end)

test("settings: Custom sync mode labels are clear and keep the stored custom id", function()
    local _,m = newUI(false)
    local row=m:settingRow("sync_mode")
    eq(row.sub_item_table[2].text,"KOReader decides")
    local old=RE.S.sync_mode
    row.sub_item_table[2].callback(); eq(RE.S.sync_mode,"custom")
    ok(row.text_func():find("KOReader decides",1,true))
    eq(RE.SettingsUI.modeLabel({}),"Your own settings")
    RE.Shared.set("sync_mode",old)
end)

test("settings: Home layout actions enter the existing editor in the requested mode", function()
    local _, m = newUI(false)
    local open, calls = RE.HomeEditor.open, {}
    RE.HomeEditor.open = function(mode) calls[#calls+1] = mode end
    local modes = {["Edit layout"]="edit", ["Reset layout"]="reset", ["Page names"]="rename"}
    for _, group in ipairs(m:menuItems()) do
        if group.settings_group == "home" then
            for _, row in ipairs(group.sub_item_table_func()) do
                if modes[row.text] then row.callback(); run(1); eq(calls[#calls], modes[row.text]) end
            end
        end
    end
    RE.HomeEditor.open = open
    eq(#calls, 3)
end)

test("settings: Home selector uses the host's shared setting and labels its button policy", function()
    local _, m = newUI(false)
    local home
    for _, group in ipairs(m:menuItems()) do if group.settings_group == "home" then home = group.sub_item_table_func() end end
    local old = RE.S.home_screen
    home[3].sub_item_table[2].callback()
    eq(RE.S.home_screen, "booksync")
    ok(home[5].text_func():find("BookSync Home", 1, true), "button policy names the selected Home")
    ok(lastBroadcast(".SETTINGS"), "shared settings transport")
    RE.Shared.set("home_screen", old)
end)

test("settings: Full refresh without an imported owner dispatches nothing", function()
    local owner,command=RE.LibraryAdapter.owner,RE.LibraryAdapter.command
    RE.LibraryAdapter.owner=function() end
    RE.LibraryAdapter.command=function() error("must not dispatch without an owner") end
    local result=RE.Library.fullRefresh()
    RE.LibraryAdapter.owner,RE.LibraryAdapter.command=owner,command
    eq(result,false)
end)

test("settings: every group has a budget and neutral screen text; one channel row opens its picker", function()
    local _, m = newUI(false)
    local groups = {}
    eq(#m:menuItems(),8,"approved Settings root has eight groups")
    for _, it in ipairs(m:menuItems()) do
        if it.settings_group then
            groups[it.settings_group] = it.sub_item_table_func()
            ok(RE.Budgets.get("screens", "settings-" .. it.settings_group))
        end
    end
    for _, id in ipairs({"account", "sync", "library", "reading", "home", "sleep", "updates", "about"}) do
        ok(groups[id] and #groups[id] > 0, id)
    end
    local channel = 0
    for _, row in ipairs(menuAll(m:menuItems())) do
        for _, text in ipairs({row.text or "", row.text_func and row.text_func() or "", row.help_text or ""}) do
            local lower = text:lower()
            for _, name in ipairs({"bookorbit", "grimmory", "tailscale", "tailnet", "boox", "xteink"}) do
                ok(not lower:find(name, 1, true), "vendor in screen text: " .. text)
            end
        end
        if row.text_func and row.text_func():find("Update channel:", 1, true) == 1 then
            channel = channel + 1
            eq(#row.sub_item_table, 3)
            local old = RE.S.update_channel
            row.sub_item_table[3].callback()
            eq(RE.S.update_channel, "preview")
            ok(lastBroadcast(".SETTINGS"), "channel uses settings sync")
            RE.Shared.set("update_channel", old)
        end
    end
    eq(channel, 1)
end)

test("settings: mode estimates come from one bounded library read; presets and Custom keep every control", function()
    local _, m = newUI(false)
    local oldRead, oldRequest = RE.LibraryAdapter.read, RE.LibraryAdapter.request
    local requests, trips = 0, 0
    RE.LibraryAdapter.read = function(encoded)
        local args = RE.Cache.decode(encoded)
        if args.op=="account.state" then eq(args.limit,1); return {signedIn=false},128 end
        if args.op=="settings.device" then eq(args.limit,1); return {reader="Reader",sleep_ms=600000,sleep_label="10 min idle"},128 end
        eq(args.op, "mode-estimates"); eq(args.limit, 3)
        requests = requests + 1
        return {items={{id="saver", text="≈ 4 days at your usual use"}}}, 128
    end
    RE.LibraryAdapter.request = function(batch) trips=trips+1; eq(#batch, 2); return true end
    local row
    for _, group in ipairs(m:menuItems()) do
        if group.settings_group == "sync" then row = group.sub_item_table_func()[2] end
    end
    RE.LibraryAdapter.read, RE.LibraryAdapter.request = oldRead, oldRequest
    eq(requests, 1); eq(trips, 1)
    ok(row.sub_item_table[1].text:find("≈ 4 days at your usual use", 1, true))
    local has = RE.Companion.has
    RE.Companion.has = function(cap) return cap == "wifi" or has(cap) end
    local saved = {}
    for _, key in ipairs(RE.SettingsUI.modeKeys) do saved[key] = RE.S[key] end
    for i, mode in ipairs(RE.SettingsUI.modes) do
        row.sub_item_table[i].callback()
        eq(RE.SettingsUI.mode(RE.S), mode.id)
        for _, key in ipairs(RE.SettingsUI.modeKeys) do eq(RE.S[key], mode.values[key]) end
    end
    RE.Shared.set("wifi_idle_min", 10)
    eq(RE.SettingsUI.mode(RE.S), "custom")
    for _, key in ipairs(RE.SettingsUI.modeKeys) do RE.Shared.set(key, saved[key]) end
    RE.Companion.has = has
end)

test("settings: Battery navigation opens the owned snapshot screen", function()
    local _, m = newUI(false)
    local show = RE.BatteryUI.show
    local opened = 0
    RE.BatteryUI.show = function() opened=opened+1 end
    local success,err=pcall(function()
        local battery
        for _,group in ipairs(m:menuItems()) do
            if group.settings_group == "sync" then
                for _,row in ipairs(group.sub_item_table_func()) do if row.text == "Battery ›" then battery=row end end
            end
        end
        ok(battery and battery.callback); battery.callback(); run(1); eq(opened,1)
    end)
    RE.BatteryUI.show = show
    ok(success,err)
end)

test("About: the locked menu shows every shared credit paragraph and the project URL", function()
    local _, m = newUI(false)
    local items = m.readOnly(m:menuItems())
    local about
    for _, it in ipairs(menuAll(items)) do if it.text == "About" then about = it end end
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

test("main loop: yielding work is attributed to each resume rather than a combined stall", function()
    local M=E.MainLoop
    local logs=W.logs; W.logs={}
    local co=coroutine.create(function()
        M.wrap(function()
            for i=1,3 do
                W.clock=W.clock+0.03
                if i<3 then
                    coroutine.yield()
                    local current=coroutine.running()
                    M.turns[current]=(M.turns[current] or 0)+1
                end
            end
        end,"cooperative test")()
    end)
    for i=1,3 do local resumed,err=coroutine.resume(co); ok(resumed,err) end
    eq(coroutine.status(co),"dead")
    ok(not table.concat(W.logs,"\n"):find("cooperative test",1,true),"90 ms spread over three turns is not one stall")
    W.logs=logs
end)

test("Home calendar: worker snapshots replace a correctly dated empty calendar", function()
    local LF, C, OC = E.LF, E.Companion, E.OC
    local saved={year=LF.year,key=LF.year_key,waiting=LF.year_waiting,send=C.send,problem=C.workerProblem,watch=OC.watchChecks,catalog=E.Mirror.catalog}
    local asks={}
    C.send=function(action, extras) asks[#asks+1]=extras; return true end
    C.workerProblem=function() return nil end
    OC.watchChecks=function() end
    E.Mirror.catalog=function() return nil end
    LF.year={values={},start=0,today=0}; LF.year_key=nil
    local now=os.time(); local body={}
    local values,start,today=LF.yearMinutes(now,body)
    ok(start>now-365*86400 and today<=now and now-today<86400,"current calendar dates before first answer")
    ok(#values>=358 and #values<=364); eq(#asks,1)
    LF.yearMinutes(now,body); eq(#asks,1,"pending ask coalesced")
    LF.yearLanded({key=asks[1].board_key,data={values={10,20},start=start,today=today}})
    eq(select(1,LF.yearMinutes(now,body))[2],20,"worker answer used")
    LF.year,LF.year_key,LF.year_waiting=saved.year,saved.key,saved.waiting
    C.send,C.workerProblem,OC.watchChecks,E.Mirror.catalog=saved.send,saved.problem,saved.watch,saved.catalog
end)

test("startup: 7000 cover files keep each UI callback within a fixed IO/intent budget", function()
    local client = cacheSetup()
    local lfs = require("libs/libkoreader-lfs")
    local cdir = cache.dir .. "/covers"
    for i=1,7000 do local f=assert(io.open(cdir .. "/" .. i .. ".jpg.etag", "wb")); f:write("etag"); f:close() end
    E.OC.cover_dir = cdir
    FC.coverDirectory=cdir
    local checked = 0
    local items = FC.storageItems
    -- The fake worker walks the real directory; companion tests cover its actual cleanup/count.
    FC.storageItems = function(folder)
        ok(W.in_companion, "storage runs in companion")
        local count=0; for name in lfs.dir(folder) do if name:match("%.etag$") then count=count+1 end end
        eq(count,7000)
        return {}
    end
    W.main_loop_guard = function(fn,args)
        uiWorkBudget(function() fn(unpack(args)) end)
        if getfenv(fn)==E then checked=checked+1 end
    end
    local passed_guard, err=pcall(function()
        uiWorkBudget(function()
            E.OC.storageCount("orphan ETags")
            eq(E.OC.olderCover,nil,"older-cover enumeration is companion-only")
        end)
        run(12)
        local reader={document={file="/books/reading.epub"}}
        ReaderUI.instance=reader; W.shown={reader}
        uiWorkBudget(function() E.OC.storageCount("orphan ETags") end)
        run(12)
        ReaderUI.instance=nil; W.shown={}
        ok(checked > 0, "guard measured production callbacks")
    end)
    W.main_loop_guard=nil; FC.storageItems=items
    ReaderUI.instance=nil; W.shown={}
    cacheTeardown()
    ok(passed_guard,err)
end)















-- This case is also in the emulated release gate (ORBIT_TEST_ONLY=startup).
-- With a pinned checkout it executes KOReader's actual opening coroutine.
test("startup smoke: Home, history and file browser open during Full refresh with repair pending", function()
    local Reader = require("apps/reader/readerui")
    eq(Reader.showReader, stockShowReader, "book opening is never intercepted for repair")
    local show = Reader.showReader
    local old_do, old_co = Reader.doShowReader, Reader.showReaderCoroutine
    local old_notices, old_busy, old_active = E.Mirror.notices, E.Mirror.busy, E.Mirror.active
    local Info = require("ui/widget/infomessage")
    local source = [[
function Reader:showReaderCoroutine(file, provider, seamless)
    UIManager:show(InfoMessage:new{ text = "Opening file", timeout = 0.0, invisible = seamless })
    UIManager:forceRePaint()
    UIManager:nextTick(function() self:doShowReader(file, provider, seamless) end)
end
]]
    local checkout = os.getenv("ORBIT_KOREADER_SOURCE")
    if checkout then
        local f = assert(io.open(checkout .. "/frontend/apps/reader/readerui.lua", "rb"))
        local text = f:read("*a"); f:close()
        source = assert(text:match("(function ReaderUI:showReaderCoroutine.-)\nfunction ReaderUI:doShowReader"))
    end
    local chunk = assert(loadstring(source))
    setfenv(chunk, setmetatable({ Reader=Reader, ReaderUI=Reader, UIManager=UIManager, InfoMessage=Info,
        _=function(t) return t end, T=function(t) return t end, BD={filepath=function(t) return t end},
        filemanagerutil={abbreviate=function(t) return t end}, logger={dbg=function() end} }, {__index=_G}))
    chunk()
    Reader.showReader = function(self, ...) return self:showReaderCoroutine(...) end
    local success, err = pcall(function()
        for _, origin in ipairs({ "Home", "history", "file browser" }) do
            W.queue, W.shown = {}, {}
            ReaderUI.instance = nil
            E.Mirror.notices, E.Mirror.busy, E.Mirror.active = true, true, true
            -- No companion repair answer is delivered. Opening cannot wait for one.
            local before, quits = #W.broadcasts, W.quits or 0
            local reader = { document={file="/books/synthetic.epub"}, name="reader" }
            Reader.doShowReader = function() ReaderUI.instance=reader; UIManager:show(reader) end
            Reader:showReader("/books/synthetic.epub", "epub")
            ok(#W.shown > 0, origin .. ": opening widget keeps UIManager alive before next tick")
            run(0)
            eq(UIManager:getTopmostVisibleWidget(), reader, origin .. ": ReaderUI shown")
            eq(ReaderUI.instance, reader, origin .. ": reader instance survives")
            eq(W.quits or 0, quits, origin .. ": KOReader did not exit")
            for n=before+1,#W.broadcasts do ok(not W.broadcasts[n].extras.repair_book, "open never sends repair") end
        end
        local Trap = class()
        local old = package.loaded["ui/widget/trapwidget"]
        package.loaded["ui/widget/trapwidget"] = Trap
        local w = Trap:new{ text="input trap", dismiss_callback=function() end }
        UIManager:show(w)
        eq(UIManager:getTopmostVisibleWidget(), w, "Trapper control widget is never suppressed")
        package.loaded["ui/widget/trapwidget"] = old
    end)
    Reader.showReader, Reader.doShowReader, Reader.showReaderCoroutine = show, old_do, old_co
    E.Mirror.notices, E.Mirror.busy, E.Mirror.active = old_notices, old_busy, old_active
    ReaderUI.instance = nil; W.shown = {}
    ok(success, err)
end)

test("library ready model: real SQLite reads stay bounded and batch once", function()
    local dir, st = fixtureStore()
    st:run("CREATE TABLE library_views(owner TEXT,request TEXT,body BLOB,at INTEGER,PRIMARY KEY(owner,request))")
    local owner, send, problem = RE.LibraryAdapter.owner, RE.Companion.send, RE.Companion.workerProblem
    local trips, batch = 0
    RE.LibraryAdapter.owner = function() return DBFX.owner end
    RE.Companion.workerProblem = function() end
    RE.Companion.send = function(action, extras)
        eq(action, RE.Companion.ACTION.PATCH)
        trips=trips+1; batch=RE.Cache.decode(extras.library_batch)
    end
    local success, err=pcall(function() withStore(dir,function()
        local p=RE.Library.paint("home")
        eq(p:widget("booklist"):window("reading",{},0,2).pending,true)
        p:widget("library"):counts(); p:flush(); eq(trips,1); eq(#batch,2)
        local body=RE.Cache.encode({items={{key="opaque",title="Ready"}},freshness={saved=true}})
        st:run("INSERT INTO library_views VALUES(?,?,?,1)",DBFX.owner,batch[1],body)
        local decoded, decode=0,RE.Cache.decode
        RE.Cache.decode=function(value) decoded=decoded+#value; return decode(value) end
        local q=RE.Library.paint("home")
        eq(q:widget("booklist"):window("reading",{},0,2).items[1].title,"Ready")
        eq(decoded,#body); q:flush(); eq(trips,1,"repeat paint is coalesced")
        st:run("UPDATE library_views SET body=?",string.rep("x",16385))
        decoded=0
        local r=RE.Library.paint("home")
        eq(r:widget("booklist"):window("reading",{},0,2).pending,true)
        eq(decoded,0,"oversized snapshot never decoded")
        RE.Cache.decode=decode
    end) end)
    RE.LibraryAdapter.owner,RE.Companion.send,RE.Companion.workerProblem=owner,send,problem
    st.conn:close(); os.execute("rm -rf '" .. dir .. "'")
    ok(success,err)
end)

dofile(here .. "/settings_flows.lua")(test,eq,ok,RE,W,Widget)

dofile(here .. "/home_host_flows.lua")(test,eq,ok,RE,W,Widget)

dofile(here .. "/status_layout_flows.lua")(here, test, ok, eq)
dofile(here .. "/reader_panel_flows.lua")(here, test, ok, eq)

if os.getenv("ORBIT_REQUIRE_READER_FLOWS") then
    for _, name in ipairs({
        "startup smoke: last document remains the top reader through a yielding progress pull",
        "startup smoke: Home, history and file browser open during Full refresh with repair pending",
    }) do
        assert(executed[name], "required reader flow did not run: " .. name)
    end
end
dofile(here .. "/catalog_actions_flows.lua")({E=RE,W=W,test=test,eq=eq,ok=ok,newUI=newUI,UIManager=UIManager,store=store})
print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then
    for _, l in ipairs(W.logs) do print(l) end
    os.exit(1)
end

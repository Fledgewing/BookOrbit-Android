-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookOrbit-Android (see koreader-patch/LICENSE).
--[[--
orbit-android: a KOReader user patch for Android e-readers (first target: Meebook M8C).

The official BookOrbit plugin (bookorbit.koplugin) does ALL syncing and holds the login.
This patch never talks to BookOrbit's API. It only:

  * gets the network ready (Wi-Fi through the "Orbit Companion" app, Tailscale wake),
  * checks that the plugin's configured server answers at its base URL (no login),
  * then triggers or waits on the plugin's own functions:
      requestLifecycleOutboxDrain, requestProgressPull, requestProgressPush,
      fetchRemoteProgress, _onSuspend, onBookOrbitSyncBook, startSweep,
      onBookOrbitOpenDashboard.

File name: "2-" is KOReader's `late` priority (frontend/userpatch.lua:13): it runs after
UIManager is ready and before the file browser or reader starts, so the module below is
created alongside the plugins in every FileManager and ReaderUI.

Companion interface: docs/INTERFACE.md. Logs: `adb logcat | grep OrbitAndroid`.
]]

-- Stamped by the release workflow (.github/workflows/release.yml) from the tag; a copy from the
-- repo says 0.0.0-dev, which any release replaces.
local PATCH_VERSION = "0.0.0-dev"

---------------------------------------------------------------------------------------------
-- Pure logic (no KOReader modules). Unit-tested by koreader-patch/test/.
---------------------------------------------------------------------------------------------

local Schedule = {}

-- "Sync while reading" options, in menu order.
Schedule.OPTIONS = {
    { id = "off",    kind = "off",      n = 0,   label = "Off" },
    { id = "min10",  kind = "minutes",  n = 10,  label = "Every 10 minutes" },
    { id = "min15",  kind = "minutes",  n = 15,  label = "Every 15 minutes" },
    { id = "min30",  kind = "minutes",  n = 30,  label = "Every 30 minutes" },
    { id = "min60",  kind = "minutes",  n = 60,  label = "Every 60 minutes" },
    { id = "pg25",   kind = "pages",    n = 25,  label = "Every 25 pages" },
    { id = "pg50",   kind = "pages",    n = 50,  label = "Every 50 pages" },
    { id = "pg100",  kind = "pages",    n = 100, label = "Every 100 pages" },
    { id = "ch1",    kind = "chapters", n = 1,   label = "Every chapter" },
    { id = "ch2",    kind = "chapters", n = 2,   label = "Every 2 chapters" },
}

function Schedule.option(id)
    for _, o in ipairs(Schedule.OPTIONS) do
        if o.id == id then return o end
    end
    return Schedule.OPTIONS[1]
end

-- A fresh counter. `now` is in seconds (any monotonic clock).
function Schedule.new(id, now)
    local o = Schedule.option(id)
    return {
        id = o.id, kind = o.kind, n = o.n,
        last_sync = now or 0,
        pages = 0,          -- page turns since the last sync
        chapters = 0,       -- forward chapter changes since the last sync
        chapter_key = nil,  -- start page of the current chapter
        active = false,     -- a page was turned since the last sync
    }
end

-- One page turn. chapter_key identifies the chapter the new page is in (its start page),
-- or nil when the book has no table of contents.
function Schedule.onPage(state, chapter_key, now)
    if state.kind == "off" then return end
    state.pages = state.pages + 1
    state.active = true
    if chapter_key ~= nil then
        if state.chapter_key ~= nil and chapter_key > state.chapter_key then
            state.chapters = state.chapters + 1
        end
        state.chapter_key = chapter_key
    end
end

-- Whether a sync is due. Minutes only count while reading: an idle book never syncs.
function Schedule.isDue(state, now)
    if state.kind == "off" then return false end
    if state.kind == "minutes" then
        return state.active and (now - state.last_sync) >= state.n * 60
    elseif state.kind == "pages" then
        return state.pages >= state.n
    elseif state.kind == "chapters" then
        return state.chapters >= state.n
    end
    return false
end

function Schedule.markSynced(state, now)
    state.last_sync = now
    state.pages = 0
    state.chapters = 0
    state.active = false
end

-- Decisions taken on plugin state, kept pure so they can be tested.
local Plan = {}

-- Strategy values from bookorbit main.lua:56-60.
Plan.STRATEGY = { PROMPT = 1, SILENT = 2, DISABLE = 3 }

-- While waiting for the plugin's lifecycle outbox after a sleep sync.
--   pending: entries still to send (count - blocked)
--   busy: the plugin's sync coordinator is running or has queued work
--   new_error: the plugin recorded an error since we started
-- Returns "done", "failed", "timeout", "nudge" (ask the plugin to drain again) or "wait".
function Plan.outboxVerdict(o)
    if o.pending == 0 and not o.busy then return "done" end
    if o.elapsed >= o.cap then return "timeout" end
    if not o.busy and o.new_error then return "failed" end
    if not o.busy and o.since_nudge >= 2 then return "nudge" end
    return "wait"
end

-- Sync while reading: what to do once the plugin has refreshed BookOrbit's position
-- (fetchRemoteProgress, which never moves the reader or prompts).
--   has_remote: BookOrbit has a position for this book
--   same_place / remote_newer: the plugin's own isSamePlace / remoteProgressIsNewer
--   forward: the plugin's "BookOrbit is further ahead" strategy
-- Returns "push", "pull" or "none". Never "prompt": a PROMPT strategy waits for the next
-- wake or book open, so nothing interrupts the page.
function Plan.readingAction(o)
    if not o.has_remote then return "push" end
    if o.same_place then return "none" end
    if o.remote_newer then
        if o.forward == Plan.STRATEGY.SILENT then return "pull" end
        return "none"
    end
    return "push"
end

-- Self-update from the repo's GitHub releases.
local Update = {
    INTERVAL = 24 * 60 * 60, -- at most one automatic check per day (os.time seconds)
    ASSET = "2-orbit-android.lua",
    SUMS = "SHA256SUMS",
}

-- "v1.2.3", "1.2.3-rc.1", "1.2.3+build" -> { 1, 2, 3, pre = "rc.1" | nil }, or nil.
function Update.parseVersion(s)
    if type(s) ~= "string" then return nil end
    s = s:match("^%s*(.-)%s*$"):gsub("^[vV]", "")
    s = s:gsub("%+[%w%.%-]*$", "")
    local a, b, c, rest = s:match("^(%d+)%.(%d+)%.(%d+)(.*)$")
    if not a then return nil end
    local pre = nil
    if rest ~= "" then
        pre = rest:match("^%-([%w%.%-]+)$")
        if not pre then return nil end
    end
    return { tonumber(a), tonumber(b), tonumber(c), pre = pre }
end

local function comparePre(x, y)
    if x == y then return 0 end
    if x == nil then return 1 end  -- a release sorts after its pre-releases
    if y == nil then return -1 end
    local xs, ys = {}, {}
    for part in x:gmatch("[^%.]+") do xs[#xs + 1] = part end
    for part in y:gmatch("[^%.]+") do ys[#ys + 1] = part end
    for i = 1, math.min(#xs, #ys) do
        local xn, yn = tonumber(xs[i]), tonumber(ys[i])
        if xn and yn then
            if xn ~= yn then return xn < yn and -1 or 1 end
        elseif xn then return -1  -- numeric identifiers sort first
        elseif yn then return 1
        elseif xs[i] ~= ys[i] then return xs[i] < ys[i] and -1 or 1 end
    end
    if #xs == #ys then return 0 end
    return #xs < #ys and -1 or 1
end

-- -1, 0 or 1; nil when either side isn't a version.
function Update.compare(a, b)
    a = type(a) == "table" and a or Update.parseVersion(a)
    b = type(b) == "table" and b or Update.parseVersion(b)
    if not a or not b then return nil end
    for i = 1, 3 do
        if a[i] ~= b[i] then return a[i] < b[i] and -1 or 1 end
    end
    return comparePre(a.pre, b.pre)
end

-- sha256sum output, "<64 hex>  name" or "<64 hex> *name" -> { [name] = lowercase hex }.
function Update.parseSums(text)
    local out = {}
    for line in (text or ""):gmatch("[^\r\n]+") do
        local hex, name = line:match("^%s*(%x+) [ %*](.-)%s*$")
        if hex and #hex == 64 and name ~= "" then out[name] = hex:lower() end
    end
    return out
end

-- The PATCH_VERSION a downloaded patch declares, so a release can't install an unstamped file.
function Update.stampedVersion(text)
    return (text or ""):match('\nlocal PATCH_VERSION = "([^"\n]+)"')
end

-- releases: decoded GitHub release objects. The newest that is not a draft and, unless
-- include_pre, not a pre-release. Returns the release and its parsed version.
function Update.pick(releases, include_pre)
    local best, best_v
    for _i, r in ipairs(releases or {}) do
        local v = type(r) == "table" and Update.parseVersion(r.tag_name)
        if v and not r.draft and (include_pre or not r.prerelease) then
            if not best_v or Update.compare(v, best_v) > 0 then best, best_v = r, v end
        end
    end
    return best, best_v
end

function Update.assetUrl(release, name)
    for _i, a in ipairs(release and release.assets or {}) do
        if a.name == name then return a.browser_download_url end
    end
end

-- A clock that went backwards also allows a check.
function Update.isDue(last, now, interval)
    last = tonumber(last) or 0
    return last <= 0 or now < last or now - last >= (interval or Update.INTERVAL)
end

if rawget(_G, "ORBIT_ANDROID_TEST") then
    return { Schedule = Schedule, Plan = Plan, Update = Update, PATCH_VERSION = PATCH_VERSION }
end

---------------------------------------------------------------------------------------------
-- KOReader side
---------------------------------------------------------------------------------------------

local Device = require("device")
local logger = require("logger")

local function log(...)
    logger.info("OrbitAndroid:", ...)
end

if not Device:isAndroid() then
    log("not Android; patch inactive")
    return
end

local ffi = require("ffi")
local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local PluginLoader = require("pluginloader")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local time = require("ui/time")
local _ = require("gettext")

local has_android, android = pcall(require, "android")

local function now_s()
    return time.to_s(time.now())
end

local function fmt(seconds)
    return string.format("%.1fs", seconds or 0)
end

---------------------------------------------------------------------------------------------
-- Settings (G_reader_settings "orbit_android")
---------------------------------------------------------------------------------------------

local DEFAULTS = {
    wifi_via_companion = true,
    wake_tailscale = true,
    sync_on_wake = true,
    sync_on_sleep = true,
    reading_schedule = "off",
    sleep_cap = 20,
    last_sleep_sync = nil, -- { at, ok, seconds, reason }
    auto_update_patch = true,
    patch_update_prerelease = false,
    patch_update_checked_at = 0,  -- os.time() of the last check
    patch_update_status = nil,    -- { at, text }
}

local S = G_reader_settings:readSetting("orbit_android") or {}
for k, v in pairs(DEFAULTS) do
    if S[k] == nil then S[k] = v end
end

local function saveSettings()
    G_reader_settings:saveSetting("orbit_android", S)
end
saveSettings()

---------------------------------------------------------------------------------------------
-- JNI: explicit broadcasts, activities, screen state, VPN state, launch extras
-- Built on KOReader's own JNI bridge (android-luajit-launcher assets/android.lua:1400-1416,
-- JNI:context, with the raw JNIEnv). Every Java call is checked for a pending exception,
-- because calling on with one pending aborts the VM.
---------------------------------------------------------------------------------------------

local Jni = {}

local FLAG_INCLUDE_STOPPED_PACKAGES = 0x00000020
local FLAG_RECEIVER_FOREGROUND = 0x10000000
local FLAG_ACTIVITY_NEW_TASK = 0x10000000
local TRANSPORT_VPN = 4

local function int32(n) return ffi.new("int32_t", n) end

local function check(env, what)
    if env[0].ExceptionCheck(env) ~= 0 then
        env[0].ExceptionClear(env)
        error("java exception in " .. what, 0)
    end
end

local function del(env, obj)
    if obj ~= nil then env[0].DeleteLocalRef(env, obj) end
end

local function methodId(env, obj, name, sig)
    local cls = env[0].GetObjectClass(env, obj)
    local id = env[0].GetMethodID(env, cls, name, sig)
    del(env, cls)
    if id == nil then
        env[0].ExceptionClear(env)
        error("no method " .. name .. sig, 0)
    end
    return id
end

local function callObject(env, obj, name, sig, ...)
    local r = env[0].CallObjectMethod(env, obj, methodId(env, obj, name, sig), ...)
    check(env, name)
    return r
end

local function callVoid(env, obj, name, sig, ...)
    env[0].CallVoidMethod(env, obj, methodId(env, obj, name, sig), ...)
    check(env, name)
end

local function callBool(env, obj, name, sig, ...)
    local r = env[0].CallBooleanMethod(env, obj, methodId(env, obj, name, sig), ...)
    check(env, name)
    return r ~= 0
end

local function withEnv(what, fn)
    if not has_android or not android.app then return nil, "no android bridge" end
    -- Results travel through upvalues: JNI:context returns unpack({...}), which drops
    -- values after a leading nil.
    local ra, rb, err
    local ok, ctx_err = pcall(android.jni.context, android.jni, android.app.activity.vm, function(jni)
        local env = jni.env
        local ok_inner, a, b = pcall(fn, env, android.app.activity.clazz, jni)
        if env[0].ExceptionCheck(env) ~= 0 then
            env[0].ExceptionClear(env)
            if ok_inner then ok_inner, a = false, "java exception" end
        end
        if ok_inner then ra, rb = a, b else err = a end
    end)
    if not ok then err = ctx_err end
    if err ~= nil then
        log(what, "failed:", tostring(err))
        return nil, err
    end
    return ra, rb
end

-- spec: { action, package?, class?, extras = { k = "string" }, flags? }
local function newIntent(env, spec)
    local cls = env[0].FindClass(env, "android/content/Intent")
    check(env, "FindClass Intent")
    local ctor = env[0].GetMethodID(env, cls, "<init>", "(Ljava/lang/String;)V")
    check(env, "Intent.<init>")
    local jaction = env[0].NewStringUTF(env, spec.action)
    local intent = env[0].NewObject(env, cls, ctor, jaction)
    check(env, "new Intent")
    del(env, jaction)
    del(env, cls)
    if spec.class then
        local p = env[0].NewStringUTF(env, spec.package)
        local c = env[0].NewStringUTF(env, spec.class)
        del(env, callObject(env, intent, "setClassName",
            "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;", p, c))
        del(env, p); del(env, c)
    elseif spec.package then
        local p = env[0].NewStringUTF(env, spec.package)
        del(env, callObject(env, intent, "setPackage", "(Ljava/lang/String;)Landroid/content/Intent;", p))
        del(env, p)
    end
    for k, v in pairs(spec.extras or {}) do
        local jk = env[0].NewStringUTF(env, k)
        local jv = env[0].NewStringUTF(env, tostring(v))
        del(env, callObject(env, intent, "putExtra",
            "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;", jk, jv))
        del(env, jk); del(env, jv)
    end
    if spec.flags then
        del(env, callObject(env, intent, "addFlags", "(I)Landroid/content/Intent;", int32(spec.flags)))
    end
    return intent
end

function Jni.sendBroadcast(spec)
    spec.flags = (spec.flags or 0) + FLAG_INCLUDE_STOPPED_PACKAGES + FLAG_RECEIVER_FOREGROUND
    return withEnv("broadcast " .. spec.action, function(env, activity)
        local intent = newIntent(env, spec)
        callVoid(env, activity, "sendBroadcast", "(Landroid/content/Intent;)V", intent)
        del(env, intent)
        return true
    end)
end

function Jni.startActivity(spec)
    spec.flags = (spec.flags or 0) + FLAG_ACTIVITY_NEW_TASK
    return withEnv("startActivity " .. spec.action, function(env, activity)
        local intent = newIntent(env, spec)
        callVoid(env, activity, "startActivity", "(Landroid/content/Intent;)V", intent)
        del(env, intent)
        return true
    end)
end

local function systemService(env, activity, name)
    local jname = env[0].NewStringUTF(env, name)
    local svc = callObject(env, activity, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;", jname)
    del(env, jname)
    return svc
end

-- PowerManager.isInteractive(): false once the screen is off. nil if unknown.
function Jni.isInteractive()
    return withEnv("isInteractive", function(env, activity)
        local pm = systemService(env, activity, "power")
        if pm == nil then error("no PowerManager", 0) end
        local on = callBool(env, pm, "isInteractive", "()Z")
        del(env, pm)
        return on
    end)
end

-- Whether any network has the VPN transport (Tailscale up). nil if unknown.
function Jni.vpnActive()
    return withEnv("vpnActive", function(env, activity)
        local cm = systemService(env, activity, "connectivity")
        if cm == nil then error("no ConnectivityManager", 0) end
        local nets = callObject(env, cm, "getAllNetworks", "()[Landroid/net/Network;")
        local found = false
        if nets ~= nil then
            local n = env[0].GetArrayLength(env, nets)
            for i = 0, n - 1 do
                local net = env[0].GetObjectArrayElement(env, nets, i)
                check(env, "GetObjectArrayElement")
                local caps = callObject(env, cm, "getNetworkCapabilities",
                    "(Landroid/net/Network;)Landroid/net/NetworkCapabilities;", net)
                if caps ~= nil then
                    if callBool(env, caps, "hasTransport", "(I)Z", int32(TRANSPORT_VPN)) then found = true end
                    del(env, caps)
                end
                del(env, net)
                if found then break end
            end
            del(env, nets)
        end
        del(env, cm)
        return found
    end)
end

-- Reads and removes a string extra from the activity's current intent (the launch intent,
-- or the latest one: MainActivity.onNewIntent calls setIntent, android-luajit-launcher
-- MainActivity.kt:205-210).
function Jni.takeIntentExtra(key)
    return withEnv("takeIntentExtra", function(env, activity, jni)
        local intent = callObject(env, activity, "getIntent", "()Landroid/content/Intent;")
        if intent == nil then return false end
        local jk = env[0].NewStringUTF(env, key)
        local jv = callObject(env, intent, "getStringExtra", "(Ljava/lang/String;)Ljava/lang/String;", jk)
        local value = false
        if jv ~= nil then
            value = jni:to_string(jv)
            del(env, jv)
            callVoid(env, intent, "removeExtra", "(Ljava/lang/String;)V", jk)
        end
        del(env, jk)
        del(env, intent)
        return value
    end)
end

---------------------------------------------------------------------------------------------
-- Orbit Companion and Tailscale (docs/INTERFACE.md)
---------------------------------------------------------------------------------------------

local Companion = {
    PACKAGE = "net.fledgewing.orbitcompanion",
    PROTOCOL = "1",
    STATUS_URL = "http://127.0.0.1:47913/status",
}
Companion.ACTION = {
    NET_UP = Companion.PACKAGE .. ".action.NET_UP",
    NET_DONE = Companion.PACKAGE .. ".action.NET_DONE",
    WIFI_OFF = Companion.PACKAGE .. ".action.WIFI_OFF",
    SLEEP_NOW = Companion.PACKAGE .. ".action.SLEEP_NOW",
    SHOW_STATUS = Companion.PACKAGE .. ".action.SHOW_STATUS",
    SHOW_APPS = Companion.PACKAGE .. ".action.SHOW_APPS",
}
-- Extra the companion puts on the intent that starts KOReader ("home").
Companion.EXTRA_COMMAND = Companion.PACKAGE .. ".extra.COMMAND"

local TAILSCALE = {
    action = "com.tailscale.ipn.CONNECT_VPN",
    package = "com.tailscale.ipn",
    class = "com.tailscale.ipn.IPNReceiver",
}

local installed_cache = { at = -1000, value = false }

function Companion.installed()
    local t = now_s()
    if t - installed_cache.at > 30 then
        local ok, v = pcall(android.isPackageEnabled, Companion.PACKAGE)
        installed_cache.value = ok and v == true
        installed_cache.at = t
    end
    return installed_cache.value
end

local request_seq = 0

function Companion.send(action, extras)
    extras = extras or {}
    extras.proto = Companion.PROTOCOL
    extras.sender = "org.koreader.launcher"
    local ok = Jni.sendBroadcast{ action = action, package = Companion.PACKAGE, extras = extras }
    log("companion", action:match("[^.]+$"), ok and "sent" or "NOT sent", extras.reason or "")
    return ok
end

function Companion.netUp(reason, opts)
    opts = opts or {}
    request_seq = request_seq + 1
    return Companion.send(Companion.ACTION.NET_UP, {
        reason = reason,
        request_id = tostring(request_seq),
        wifi = S.wifi_via_companion and "1" or "0",
        tailscale = S.wake_tailscale and "1" or "0",
        wake_lock_s = tostring(opts.wake_lock_s or 0),
    }), tostring(request_seq)
end

function Companion.netDone(reason, ok, seconds, detail)
    if not Companion.installed() then return end
    Companion.send(Companion.ACTION.NET_DONE, {
        reason = reason,
        ok = ok and "1" or "0",
        seconds = string.format("%.1f", seconds or 0),
        detail = detail or "",
    })
end

-- Optional loopback status. Returns a table or nil.
function Companion.status(timeout)
    local okr, http = pcall(require, "socket.http")
    if not okr then return nil end
    local socket = require("socket")
    local socketutil = require("socketutil")
    local ltn12 = require("ltn12")
    local body = {}
    socketutil:set_timeout(timeout or 1, (timeout or 1) + 1)
    local code = socket.skip(1, http.request{ url = Companion.STATUS_URL, sink = ltn12.sink.table(body) })
    socketutil:reset_timeout()
    if code ~= 200 then return nil end
    local okj, json = pcall(require, "json")
    if not okj then return {} end
    local okd, data = pcall(json.decode, table.concat(body))
    return okd and type(data) == "table" and data or {}
end

local function tailscaleConnect(reason)
    local ok = Jni.sendBroadcast{ action = TAILSCALE.action, package = TAILSCALE.package, class = TAILSCALE.class }
    log("tailscale CONNECT_VPN", ok and "sent" or "NOT sent", reason or "")
    return ok
end

---------------------------------------------------------------------------------------------
-- The BookOrbit plugin
---------------------------------------------------------------------------------------------

-- The reader or file browser on screen now. Flows outlive the module that started them
-- (a book can close mid-flow), so they look the UI up again when they need it.
local function liveUI()
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance then return ReaderUI.instance end
    return require("apps/filemanager/filemanager").instance
end

local function bookorbit(ui)
    ui = liveUI() or ui
    local p = ui and ui.bookorbit
    if not p then
        local ok, inst = pcall(PluginLoader.getPluginInstance, PluginLoader, "bookorbit")
        p = ok and inst or nil
    end
    return p
end

local function inBook()
    local ui = liveUI()
    return ui ~= nil and ui.document ~= nil
end

local function serverUrl(p)
    local settings = p and p.settings or G_reader_settings:readSetting("bookorbit")
    return settings and settings.server_url or nil
end

-- Any HTTP status from the base URL counts: it proves the route and the server, with no login.
local function probeServer(url, timeout)
    local http = require("socket.http")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local ltn12 = require("ltn12")
    socketutil:set_timeout(timeout, timeout + 1)
    local code = socket.skip(1, http.request{ url = url, method = "HEAD", sink = ltn12.sink.null() })
    socketutil:reset_timeout()
    return type(code) == "number", code
end

---------------------------------------------------------------------------------------------
-- Network up: companion or Tailscale, then Wi-Fi, VPN and server, capped
---------------------------------------------------------------------------------------------

local Net = { inflight = nil }

-- opts: reason, cap (s), need_server, wake_lock_s. cb(ok, res) with
-- res = { companion, wifi_s, vpn_s, server_s, elapsed, failed_at, detail }.
function Net.up(p, opts, cb)
    if Net.inflight then
        log("network: joining running attempt (", Net.inflight.reason, ") for", opts.reason)
        table.insert(Net.inflight.waiters, cb)
        return
    end
    local cap = opts.cap or 20
    local flight = { reason = opts.reason, waiters = { cb } }
    Net.inflight = flight
    local t0 = now_s()
    local res = { companion = Companion.installed() }
    local url = opts.need_server and serverUrl(p) or nil
    log("network up: start", opts.reason, "cap", cap .. "s", "companion", res.companion and "yes" or "no",
        "server", url and "set" or "none")

    if res.companion and (S.wifi_via_companion or S.wake_tailscale) then
        Companion.netUp(opts.reason, { wake_lock_s = opts.wake_lock_s })
    elseif S.wake_tailscale then
        tailscaleConnect(opts.reason)
    end

    local next_probe = 0
    local ts_resent = false
    local function finish(ok, failed_at, detail)
        res.elapsed = now_s() - t0
        res.failed_at = failed_at
        res.detail = detail
        Net.inflight = nil
        log("network up:", ok and "ok" or ("FAILED at " .. tostring(failed_at)), opts.reason,
            "wifi", res.wifi_s and fmt(res.wifi_s) or "-", "vpn", res.vpn_s and fmt(res.vpn_s) or "-",
            "server", res.server_s and fmt(res.server_s) or "-", "total", fmt(res.elapsed), detail or "")
        for _i, w in ipairs(flight.waiters) do
            local okc, err = pcall(w, ok, res)
            if not okc then log("network callback error:", err) end
        end
    end

    local function tick()
        local el = now_s() - t0
        if not NetworkMgr:isConnected() then
            if el >= cap then return finish(false, "wifi", "Wi-Fi did not connect in " .. cap .. " s") end
            return UIManager:scheduleIn(0.5, tick)
        end
        if not res.wifi_s then
            res.wifi_s = el
            log("network: Wi-Fi connected after", fmt(el))
            -- Without the companion, Tailscale may need Wi-Fi first: ask once more now.
            if S.wake_tailscale and not res.companion and not ts_resent then
                ts_resent = true
                tailscaleConnect(opts.reason .. "+wifi")
            end
        end
        if not res.vpn_s and Jni.vpnActive() then
            res.vpn_s = el
            log("network: VPN up after", fmt(el))
        end
        if not url then return finish(true) end
        if el >= next_probe then
            local remaining = cap - el
            local answered, code = probeServer(url, math.max(0.5, math.min(2, remaining)))
            local after = now_s() - t0
            if answered then
                res.server_s = after
                log("network: server answered", code, "after", fmt(after))
                return finish(true)
            end
            log("network: server not answering yet:", tostring(code), "at", fmt(after))
            next_probe = after + 1
            el = after
        end
        if el >= cap then
            local stage = (S.wake_tailscale and not res.vpn_s) and "tailscale" or "server"
            return finish(false, stage, stage == "tailscale" and ("Tailscale didn't connect in " .. cap .. " s")
                or ("BookOrbit didn't answer in " .. cap .. " s"))
        end
        UIManager:scheduleIn(0.5, tick)
    end
    tick()
end

---------------------------------------------------------------------------------------------
-- Waiting on the plugin's lifecycle outbox (bookorbit main.lua:374-547)
---------------------------------------------------------------------------------------------

local Sync = {}

function Sync.waitOutbox(p, cap, cb)
    local t0 = now_s()
    local start_os = os.time()
    local last_nudge = t0
    local function tick()
        local el = now_s() - t0
        local okd, diag = pcall(function() return p:getLifecycleOutbox():diagnostics() end)
        if not okd then
            log("outbox: cannot read:", diag)
            return cb(false, "outbox unreadable", el)
        end
        local coordinator = p:getSyncCoordinator()
        local busy = coordinator:isBusy() or coordinator:queuedCount() > 0
        local err = p.settings.last_error
        local verdict = Plan.outboxVerdict{
            pending = (diag.count or 0) - (diag.blocked or 0),
            busy = busy,
            new_error = err ~= nil and (err.at or 0) >= start_os,
            elapsed = el,
            cap = cap,
            since_nudge = now_s() - last_nudge,
        }
        if verdict == "done" then
            log("outbox: drained after", fmt(el), "(parked:", diag.blocked or 0, ")")
            return cb(true, nil, el)
        elseif verdict == "failed" then
            log("outbox: plugin reported", err.event, err.message, "after", fmt(el))
            return cb(false, err.message or "plugin sync failed", el)
        elseif verdict == "timeout" then
            log("outbox: still", (diag.count or 0) - (diag.blocked or 0), "pending at the", cap .. "s cap")
            return cb(false, "time limit reached", el)
        elseif verdict == "nudge" then
            last_nudge = now_s()
            p:requestLifecycleOutboxDrain("orbit_wait")
        end
        UIManager:scheduleIn(0.5, tick)
    end
    tick()
end

---------------------------------------------------------------------------------------------
-- Self-update from github.com/Fledgewing/BookOrbit-Android releases (README "Updates").
-- Checks at most once a day on start/wake when the network is already up (never brings it up
-- for this), or from the menu. The new file is SHA-256-checked against the release's
-- SHA256SUMS, written next to this file and renamed over it; it runs from the next start.
---------------------------------------------------------------------------------------------

local Updater = { busy = false }
local RELEASES_API = "https://api.github.com/repos/Fledgewing/BookOrbit-Android/releases"
-- This file, as userpatch.lua dofile()d it (frontend/userpatch.lua: patch_dir .. "/" .. entry).
local SELF_PATH = rawget(_G, "ORBIT_ANDROID_SELF_PATH") -- tests only
    or (debug.getinfo(1, "S").source or ""):match("^@(.+%.lua)$")

-- GET with manual redirects (release assets redirect to another host). Returns body or nil, err.
local function httpGet(url, block_timeout, total_timeout)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    socketutil:set_timeout(block_timeout, total_timeout)
    local okp, body, err = pcall(function()
        for _hop = 1, 5 do
            local chunks = {}
            local is_api = url:find("api.github.com", 1, true) ~= nil
            local code, headers = socket.skip(1, http.request{
                url = url,
                method = "GET",
                headers = {
                    ["User-Agent"] = "BookOrbit-Android-patch/" .. PATCH_VERSION,
                    ["Accept"] = is_api and "application/vnd.github+json" or "*/*",
                },
                sink = ltn12.sink.table(chunks),
                redirect = false,
            })
            if type(code) ~= "number" then return nil, "network: " .. tostring(code) end
            local location = type(headers) == "table" and (headers.location or headers.Location) or nil
            if code >= 300 and code < 400 and location then
                log("update: redirect", code, "to", (location:match("^https?://([^/]+)") or "?"))
                url = location
            elseif code == 200 then
                return table.concat(chunks)
            else
                return nil, "HTTP " .. code
            end
        end
        return nil, "too many redirects"
    end)
    socketutil:reset_timeout()
    if not okp then return nil, tostring(body) end
    return body, err
end

local function setUpdateStatus(text)
    S.patch_update_status = { at = os.time(), text = text }
    saveSettings()
    log("update:", text)
end

-- Returns ok, status text. Blocking: callers schedule it.
function Updater.run(why)
    S.patch_update_checked_at = os.time()
    saveSettings()
    local pre = S.patch_update_prerelease == true
    log("update: check started (" .. why .. "), installed", PATCH_VERSION, "pre-releases", tostring(pre))
    local url = pre and (RELEASES_API .. "?per_page=5") or (RELEASES_API .. "/latest")
    local body, err = httpGet(url, 10, 30)
    if not body then return false, "check failed: " .. tostring(err) end
    local okj, json = pcall(require, "json")
    if not okj then return false, "check failed: no JSON module" end
    local okd, data = pcall(json.decode, body)
    if not okd or type(data) ~= "table" then return false, "check failed: unreadable answer" end
    local rel, v = Update.pick(pre and data or { data }, pre)
    if not rel then return false, "no release found" end
    log("update: newest release", rel.tag_name)
    if Update.compare(v, PATCH_VERSION) ~= 1 then return true, "up to date (" .. PATCH_VERSION .. ")" end

    local lua_url, sums_url = Update.assetUrl(rel, Update.ASSET), Update.assetUrl(rel, Update.SUMS)
    if not lua_url or not sums_url then return false, rel.tag_name .. " has no " .. Update.ASSET .. " or " .. Update.SUMS end
    local sums, err2 = httpGet(sums_url, 15, 60)
    if not sums then return false, "SHA256SUMS download failed: " .. tostring(err2) end
    local expected = Update.parseSums(sums)[Update.ASSET]
    if not expected then return false, "SHA256SUMS has no line for " .. Update.ASSET end
    log("update: expecting sha256", expected)
    local text, err3 = httpGet(lua_url, 15, 60)
    if not text then return false, "patch download failed: " .. tostring(err3) end
    -- koreader-base ffi/sha2.lua:5612 (sha256 returns lowercase hex); also used by frontend/util.lua.
    local sha2 = require("ffi/sha2")
    local got = sha2.sha256(text)
    if got:lower() ~= expected then
        log("update: checksum MISMATCH, got", got)
        return false, "download failed its checksum; not installed"
    end
    log("update: checksum ok,", #text, "bytes")
    local stamped = Update.stampedVersion(text)
    if Update.compare(stamped, v) ~= 0 then
        return false, "download declares " .. tostring(stamped) .. ", not " .. rel.tag_name .. "; not installed"
    end

    if not SELF_PATH then return false, "can't find this patch's own file; not installed" end
    -- Not *.lua: the patch loader must never run a half-written file.
    local tmp = SELF_PATH .. ".new"
    local f, ferr = io.open(tmp, "wb")
    if not f then return false, "can't write " .. tmp .. ": " .. tostring(ferr) end
    local okw, werr = f:write(text)
    f:close()
    local rf = io.open(tmp, "rb")
    local back = rf and rf:read("*a")
    if rf then rf:close() end
    if not okw or back ~= text then
        os.remove(tmp)
        return false, "write failed: " .. tostring(werr or "short write")
    end
    local okr, rerr = os.rename(tmp, SELF_PATH)
    if not okr then
        os.remove(tmp)
        return false, "rename failed: " .. tostring(rerr)
    end
    log("update: wrote", stamped, "over", SELF_PATH)
    return true, "updated to " .. stamped .. "; restart KOReader to use it"
end

function Updater.check(why, done)
    if Updater.busy then
        log("update: check already running; ignored (" .. why .. ")")
        return
    end
    Updater.busy = true
    local okc, ok, text = pcall(Updater.run, why)
    Updater.busy = false
    if not okc then
        ok, text = false, "check failed: " .. tostring(ok)
    end
    setUpdateStatus(text)
    if done then done(ok, text) end
end

-- Daily automatic check, only when the network is already up.
function Updater.maybeAuto(reason)
    if not S.auto_update_patch then return end
    if not Update.isDue(S.patch_update_checked_at, os.time()) then return end
    -- After the plugin's own drain and pull, which share the connection.
    UIManager:scheduleIn(8, function()
        if Updater.busy or not Update.isDue(S.patch_update_checked_at, os.time()) then return end
        if not NetworkMgr:isConnected() then
            log("update: daily check due, network not up; skipped (" .. reason .. ")")
            return
        end
        Updater.check("auto, " .. reason)
    end)
end

---------------------------------------------------------------------------------------------
-- The patch's module: one per FileManager / ReaderUI, created like a plugin
---------------------------------------------------------------------------------------------

local state = {
    started = false,            -- first module of this process seen
    sas_done_at = -1000,        -- "Sync and sleep" finished (monotonic s)
    pending_home = nil,         -- "go home" waiting for the file browser
}

local OrbitAndroid = WidgetContainer:extend{
    name = "orbitandroid",
    fullname = "Orbit Android (user patch)",
    is_doc_only = false,
}

function OrbitAndroid:init()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then self.ui.menu:registerToMainMenu(self) end
    local in_reader = self.ui ~= nil and self.ui.document ~= nil
    self.schedule = Schedule.new(S.reading_schedule, now_s())
    if in_reader then self:hookPluginPagePush() end

    if not state.started then
        state.started = true
        log("start: KOReader started (treated as a wake)", in_reader and "in reader" or "in file browser")
        UIManager:scheduleIn(1, function() self:checkCommand("start") end)
        UIManager:scheduleIn(1.5, function() self:wakeFlow("start") end)
    elseif state.pending_home and not in_reader then
        UIManager:scheduleIn(1, function() self:finishHome() end)
    end
end

function OrbitAndroid:onDispatcherRegisterActions()
    Dispatcher:registerAction("orbit_sync_and_sleep",
        { category = "none", event = "OrbitSyncAndSleep", title = _("Orbit: sync and sleep"), general = true })
    Dispatcher:registerAction("orbit_go_home",
        { category = "none", event = "OrbitGoHome", title = _("Orbit: go to BookOrbit home"), general = true })
    Dispatcher:registerAction("orbit_open_companion",
        { category = "none", event = "OrbitOpenCompanion", title = _("Orbit: open Orbit Companion"), general = true })
    Dispatcher:registerAction("orbit_open_apps",
        { category = "none", event = "OrbitOpenApps", title = _("Orbit: open another app"), general = true, separator = true })
end

-- "Sync while reading" replaces the plugin's every-few-pages push while it is on.
-- The plugin schedules that push from _onPageUpdate (main.lua:1314-1327) through
-- schedulePeriodicPush (bookorbit_progress_sync.lua:538-543); this instance override
-- skips it while our schedule is on and leaves the plugin's setting untouched.
function OrbitAndroid:hookPluginPagePush()
    local p = bookorbit(self.ui)
    if not p or p._orbit_page_push_hooked or type(p.schedulePeriodicPush) ~= "function" then return end
    local orig = p.schedulePeriodicPush
    p._orbit_page_push_hooked = true
    p.schedulePeriodicPush = function(plugin, ...)
        if S.reading_schedule ~= "off" then
            plugin.page_update_counter = 0
            return
        end
        return orig(plugin, ...)
    end
    log("hooked plugin page push (sync while reading:", S.reading_schedule .. ")")
end

---------------------------------------------------------------------------------------------
-- Wake / start
---------------------------------------------------------------------------------------------

function OrbitAndroid:onResume()
    log("resume")
    UIManager:scheduleIn(0.3, function()
        self:checkCommand("resume")
        -- Also after "home": the closed book's sync needs the network.
        self:wakeFlow("wake")
    end)
end

function OrbitAndroid:wakeFlow(reason)
    if not S.sync_on_wake then
        log(reason .. ": sync on wake is off")
        if NetworkMgr:isConnected() then Updater.maybeAuto(reason) end
        return
    end
    local p = bookorbit(self.ui)
    if not p or not p:isLoggedIn() then
        log(reason .. ": BookOrbit plugin missing or signed out; nothing to do")
        if NetworkMgr:isConnected() then Updater.maybeAuto(reason) end
        return
    end
    local t0 = now_s()
    Net.up(p, { reason = reason, cap = 20, need_server = true }, function(ok, res)
        if not ok then
            self:showWakeBanner(res)
            return
        end
        p:requestLifecycleOutboxDrain("orbit_" .. reason)
        Updater.maybeAuto(reason)
        if inBook() then
            -- The plugin debounces pulls for 25 s (bookorbit_progress_sync.lua:26, 383-387).
            -- Clear it for this one pull; on a fresh start skip it if a pull already ran.
            if reason ~= "start" or (p.pull_timestamp or 0) == 0 then
                p.pull_timestamp = 0
            end
            p:requestProgressPull(false, false, "orbit_" .. reason)
            log(reason .. ": asked plugin to drain outbox and pull, network ready in", fmt(now_s() - t0))
        else
            log(reason .. ": asked plugin to drain outbox (no book open), network ready in", fmt(now_s() - t0))
        end
    end)
end

function OrbitAndroid:showWakeBanner(res)
    local text = _("Can't reach BookOrbit. Reading from this device's place.") .. "\n" .. (res.detail or "")
    local retry = function() self:wakeFlow("retry") end
    local okt, Toast = pcall(require, "bookorbit_toast")
    if okt then
        Toast.error(text, retry, { timeout = 6 })
    else
        UIManager:show(InfoMessage:new{ text = text, timeout = 6 })
    end
end

---------------------------------------------------------------------------------------------
-- "Go home" from the companion launcher
---------------------------------------------------------------------------------------------

function OrbitAndroid:checkCommand(source)
    local cmd = Jni.takeIntentExtra(Companion.EXTRA_COMMAND)
    if not cmd or cmd == "" then return false end
    log("command from companion:", cmd, "(" .. source .. ")")
    if cmd == "home" then
        self:onOrbitGoHome()
        return true
    end
    log("unknown command ignored:", cmd)
    return false
end

-- Close the open book (the reader saves it and the plugin syncs it as on any close,
-- main.lua:1292-1312), then show the plugin's BookOrbit home.
function OrbitAndroid:onOrbitGoHome()
    state.pending_home = os.time()
    local ui = liveUI()
    if ui and ui.document then
        log("home: closing book, then BookOrbit home")
        UIManager:nextTick(function() ui:onHome() end)
    else
        self:finishHome()
    end
    return true
end

function OrbitAndroid:finishHome()
    if not state.pending_home then return end
    if os.time() - state.pending_home > 15 then state.pending_home = nil return end
    state.pending_home = nil
    local p = bookorbit(self.ui)
    if not p then
        log("home: BookOrbit plugin missing; staying in the file browser")
        return
    end
    -- With "Make BookOrbit home" the plugin opens itself when the book closes (main.lua:1404-1412).
    if p.catalog_browser then
        log("home: BookOrbit home already open")
        return
    end
    log("home: opening BookOrbit home")
    p:onBookOrbitOpenDashboard()
end

---------------------------------------------------------------------------------------------
-- Sleep (Suspend)
---------------------------------------------------------------------------------------------

function OrbitAndroid:onSuspend()
    if not S.sync_on_sleep then return end
    if now_s() - state.sas_done_at < 15 then
        log("suspend: just synced by Sync and sleep; skip")
        return
    end
    local screen_on = Jni.isInteractive()
    if screen_on == true then
        -- Switching apps also sends Suspend. Look again in a moment before giving up.
        UIManager:scheduleIn(1, function()
            if Jni.isInteractive() == true then
                log("suspend: screen still on (app switch); no sleep sync")
            else
                self:sleepSync("sleep")
            end
        end)
        return
    end
    self:sleepSync("sleep")
end

function OrbitAndroid:sleepSync(reason)
    local cap = S.sleep_cap or 20
    local t0 = now_s()
    local p = bookorbit(self.ui)
    log(reason .. ": sleep sync start, cap", cap .. "s")
    local function done(ok, detail)
        local seconds = now_s() - t0
        S.last_sleep_sync = { at = os.time(), ok = ok, seconds = seconds, reason = reason, detail = detail }
        saveSettings()
        log(reason .. ": sleep sync", ok and "done" or "FAILED", "in", fmt(seconds), detail or "")
        Companion.netDone(reason, ok, seconds, detail)
    end
    if not p or not p:isLoggedIn() then
        return done(false, "BookOrbit plugin missing or signed out")
    end
    Net.up(p, { reason = reason, cap = cap, need_server = true, wake_lock_s = cap + 5 }, function(ok, res)
        if not ok then return done(false, res.detail) end
        -- The plugin queued its snapshot in its own _onSuspend (main.lua:1340-1351) but drains
        -- only when already connected (main.lua:411-419). Now we are: drain and wait.
        p:requestLifecycleOutboxDrain("orbit_" .. reason)
        Sync.waitOutbox(p, math.max(1, cap - (now_s() - t0)), function(synced, why)
            done(synced, why)
        end)
    end)
end

---------------------------------------------------------------------------------------------
-- "Sync and sleep"
---------------------------------------------------------------------------------------------

local function sleepNow(reason)
    if Companion.installed() then
        Companion.send(Companion.ACTION.SLEEP_NOW, { reason = reason })
    else
        log("sleep now: no companion; asking the reader to press the power button")
        UIManager:show(InfoMessage:new{
            text = _("Synced. Press the power button to sleep.\n(Install Orbit Companion to turn the screen off by itself.)"),
            timeout = 4,
        })
    end
end

function OrbitAndroid:onOrbitSyncAndSleep()
    if self.sas_running then return true end
    self.sas_running = true
    local cancelled, closing = false, false
    local cap = S.sleep_cap or 20
    local t0 = now_s()
    log("sync and sleep: start")
    local msg = InfoMessage:new{
        text = _("Syncing…") .. "\n" .. _("BookOrbit · then sleep"),
        dismiss_callback = function()
            if not closing then
                cancelled = true
                log("sync and sleep: cancelled by tap; screen stays on")
            end
        end,
    }
    UIManager:show(msg)
    UIManager:forceRePaint()

    local function finish(ok, detail)
        self.sas_running = false
        closing = true
        UIManager:close(msg)
        local seconds = now_s() - t0
        S.last_sleep_sync = { at = os.time(), ok = ok, seconds = seconds, reason = "sync_and_sleep", detail = detail }
        saveSettings()
        log("sync and sleep:", ok and "synced" or "FAILED", "in", fmt(seconds), detail or "")
        Companion.netDone("sync_and_sleep", ok, seconds, detail)
        if cancelled then return end
        state.sas_done_at = now_s()
        if ok then
            sleepNow("sync_and_sleep")
        else
            UIManager:show(InfoMessage:new{
                text = _("Couldn't reach BookOrbit — saved on this device.") .. "\n"
                    .. _("It sends first when you next wake it. Sleeping now…"),
                timeout = 3,
            })
            UIManager:scheduleIn(3, function()
                state.sas_done_at = now_s()
                sleepNow("sync_and_sleep_failed")
            end)
        end
    end

    local p = bookorbit(self.ui)
    if not p or not p:isLoggedIn() then
        finish(false, "BookOrbit plugin missing or signed out")
        return true
    end
    Net.up(p, { reason = "sync_and_sleep", cap = cap, need_server = true, wake_lock_s = cap + 5 }, function(ok, res)
        if cancelled then return finish(false, "cancelled") end
        if not ok then return finish(false, res.detail) end
        if inBook() then
            -- Exactly what the plugin does on sleep: snapshot the open book into its
            -- durable outbox and drain it (main.lua:1340-1351).
            p:_onSuspend()
        else
            p:requestLifecycleOutboxDrain("orbit_sync_and_sleep", true)
        end
        Sync.waitOutbox(p, math.max(1, cap - (now_s() - t0)), function(synced, why)
            if cancelled then return finish(false, "cancelled") end
            finish(synced, why)
        end)
    end)
    return true
end

---------------------------------------------------------------------------------------------
-- Sync while reading
---------------------------------------------------------------------------------------------

function OrbitAndroid:chapterKey(page)
    local toc = self.ui and self.ui.toc
    if not toc or type(page) ~= "number" then return nil end
    local ok, key = pcall(function()
        if toc:isChapterStart(page) then return page end
        return toc:getPreviousChapter(page)
    end)
    return ok and key or nil
end

function OrbitAndroid:onCloseWidget()
    if self.reading_task then
        UIManager:unschedule(self.reading_task)
        self.reading_task = nil
    end
end

function OrbitAndroid:onReaderReady()
    self.schedule = Schedule.new(S.reading_schedule, now_s())
    self:hookPluginPagePush()
end

function OrbitAndroid:onPageUpdate(page)
    if S.reading_schedule == "off" or not (self.ui and self.ui.document) then return end
    local t = now_s()
    Schedule.onPage(self.schedule, self:chapterKey(page), t)
    if Schedule.isDue(self.schedule, t) then
        -- Run once the reader settles on a page, never in the middle of turning.
        if self.reading_task then UIManager:unschedule(self.reading_task) end
        self.reading_task = function()
            self.reading_task = nil
            self:readingSync()
        end
        UIManager:scheduleIn(3, self.reading_task)
    end
end

function OrbitAndroid:readingSync()
    if self.reading_running then return end
    local p = bookorbit(self.ui)
    if not p or not p:isLoggedIn() or not inBook() then return end
    self.reading_running = true
    local t0 = now_s()
    Schedule.markSynced(self.schedule, t0)
    log("reading: sync due (" .. S.reading_schedule .. ")")
    Net.up(p, { reason = "reading", cap = 20, need_server = true }, function(ok, res)
        if not ok then
            self.reading_running = false
            log("reading: network not ready; try again at the next interval:", res.detail or "")
            return
        end
        p:requestLifecycleOutboxDrain("orbit_reading")
        local digest = p:getDocumentDigest()
        p:fetchRemoteProgress(digest, function(fetched)
            self.reading_running = false
            if not fetched then
                log("reading: plugin could not read BookOrbit's position")
                return
            end
            local remote = p.last_remote_progress
            local has_remote = remote ~= nil and remote.digest == digest and remote.percentage ~= nil
            local local_pct = p:getLastPercent()
            local action = Plan.readingAction{
                has_remote = has_remote,
                same_place = has_remote and p:isSamePlace(remote, local_pct, p:getLastProgress()),
                remote_newer = has_remote and p:remoteProgressIsNewer(remote, local_pct),
                forward = p.settings.sync_forward,
            }
            if action == "pull" then
                p.pull_timestamp = 0
                p:requestProgressPull(false, false, "orbit_reading")
            elseif action == "push" then
                p.push_timestamp = 0
                p:requestProgressPush(false, false, "orbit_reading")
            end
            log("reading: plugin", action, "in", fmt(now_s() - t0))
        end, true)
    end)
end

---------------------------------------------------------------------------------------------
-- Test sync path (mockup screen 7)
---------------------------------------------------------------------------------------------

function OrbitAndroid:testSyncPath()
    local p = bookorbit(self.ui)
    local lines = {}
    local t0 = now_s()
    local wait = InfoMessage:new{ text = _("Testing the sync path…") }
    UIManager:show(wait)
    UIManager:forceRePaint()
    local function add(ok, label, seconds, hint)
        local line = string.format("%d. %s %s %s", #lines + 1, label, ok and "✓" or "✗", seconds and fmt(seconds) or "")
        if not ok and hint then line = line .. "\n   " .. hint end
        table.insert(lines, line)
        log("test:", label, ok and "ok" or "FAILED", seconds and fmt(seconds) or "", hint or "")
    end
    local function show()
        UIManager:close(wait)
        local text = table.concat(lines, "\n") .. "\n\n" .. string.format(_("Total %s."), fmt(now_s() - t0))
            .. "\n" .. _("Step 4 only checks that the server answers at its base address; it uses no login.")
        UIManager:show(TextViewer:new{ title = _("Test sync path"), text = text })
    end

    local c0 = now_s()
    if Companion.installed() then
        local status = Companion.status(1)
        add(status ~= nil, _("Companion answered"), now_s() - c0,
            _("Orbit Companion is installed but did not answer: open it once."))
    else
        add(false, _("Companion answered"), nil, _("Orbit Companion is not installed: Wi-Fi stays as it is, Tailscale is woken directly."))
    end
    if not p or not p:isLoggedIn() then
        add(false, _("BookOrbit plugin signed in"), nil, _("Sign in to BookOrbit first."))
        return show()
    end
    Net.up(p, { reason = "test", cap = 20, need_server = true }, function(ok, res)
        add(res.wifi_s ~= nil, _("Wi-Fi connected"), res.wifi_s, _("Turn Wi-Fi on, or check Orbit Companion's Wi-Fi permission."))
        add(res.vpn_s ~= nil, _("Tailscale up"), res.vpn_s, _("Tailscale not connected: open Tailscale and sign in."))
        add(res.server_s ~= nil, _("BookOrbit server answered"), res.server_s, _("No answer from the server: check Tailscale and the server address in BookOrbit settings."))
        if not ok then return show() end
        local s0 = now_s()
        local reported = false
        local function plugin_done(err)
            if reported then return end
            reported = true
            add(err == nil, _("BookOrbit plugin synced"), now_s() - s0,
                err and (_("The plugin reported: ") .. tostring(p:errorLabel(err))) or nil)
            show()
        end
        -- The plugin's own Sync now: this book in a book, the library otherwise.
        if inBook() then
            p:onBookOrbitSyncBook({ quiet = true, on_done = plugin_done })
        else
            p:startSweep({ quiet = true, on_progress = function() end, on_done = plugin_done })
        end
        UIManager:scheduleIn(60, function() plugin_done("timeout") end)
    end)
end

---------------------------------------------------------------------------------------------
-- Companion activities
---------------------------------------------------------------------------------------------

local function openCompanion(action, what)
    if not Companion.installed() then
        UIManager:show(InfoMessage:new{ text = _("Orbit Companion isn't installed."), timeout = 3 })
        log("open", what, ": companion not installed")
        return
    end
    local ok = Jni.startActivity{ action = action, package = Companion.PACKAGE }
    log("open", what, ok and "started" or "FAILED")
end

function OrbitAndroid:onOrbitOpenCompanion()
    openCompanion(Companion.ACTION.SHOW_STATUS, "companion")
    return true
end

function OrbitAndroid:onOrbitOpenApps()
    openCompanion(Companion.ACTION.SHOW_APPS, "apps")
    return true
end

---------------------------------------------------------------------------------------------
-- Recommended plugin settings and gestures (only when tapped)
---------------------------------------------------------------------------------------------

function OrbitAndroid:applyRecommendedSettings()
    local p = bookorbit(self.ui)
    if not p then
        UIManager:show(InfoMessage:new{ text = _("The BookOrbit plugin isn't loaded."), timeout = 3 })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("Set these BookOrbit plugin options?\n\n• Auto-sync: on\n• BookOrbit is further ahead: Silent\n• BookOrbit is further behind: Don't sync\n• Make BookOrbit home\n• KOReader: Action when Wi-Fi is off → Turn on"),
        ok_text = _("Apply"),
        ok_callback = function()
            G_reader_settings:saveSetting("wifi_enable_action", "turn_on")
            p.settings.sync_forward = Plan.STRATEGY.SILENT
            p.settings.sync_backward = Plan.STRATEGY.DISABLE
            p.settings.catalog_auto_open = "home"
            if not p.settings.auto_sync then
                -- The plugin's own toggle also registers its reader events (main.lua:1416-1448).
                p:onBookOrbitToggleAutoSync(true, true, true)
            end
            G_reader_settings:flush()
            log("applied recommended plugin settings; auto_sync", tostring(p.settings.auto_sync))
            UIManager:show(InfoMessage:new{ text = _("Recommended settings applied."), timeout = 2 })
        end,
    })
end

local RECOMMENDED_GESTURES = {
    { id = "hold_top_right_corner", action = "orbit_sync_and_sleep", label = "Hold top-right corner → Sync and sleep" },
    { id = "hold_top_left_corner", action = "bookorbit_sync_now", label = "Hold top-left corner → BookOrbit: sync all books" },
    -- KOReader has no one-finger "swipe up from the bottom"; this bottom-edge swipe is the nearest.
    { id = "one_finger_swipe_bottom_edge_right", action = "bookorbit_this_book", label = "Swipe right along the bottom edge → BookOrbit: this book" },
}

function OrbitAndroid:applyRecommendedGestures()
    local gestures = self.ui and self.ui.gestures
    if not gestures or type(gestures.data) ~= "table" then
        UIManager:show(InfoMessage:new{ text = _("Turn on KOReader's Gestures plugin first."), timeout = 3 })
        return
    end
    local lines = {}
    for _i, g in ipairs(RECOMMENDED_GESTURES) do table.insert(lines, "• " .. g.label) end
    UIManager:show(ConfirmBox:new{
        text = _("In books, set these gestures? Each replaces what the gesture does now.") .. "\n\n" .. table.concat(lines, "\n"),
        ok_text = _("Apply"),
        ok_callback = function()
            -- The same write path the plugin uses for its shortcut (bookorbit_shortcut.lua:111-117).
            gestures.data.gesture_reader = gestures.data.gesture_reader or {}
            for _i, g in ipairs(RECOMMENDED_GESTURES) do
                gestures.data.gesture_reader[g.id] = { [g.action] = true }
            end
            gestures.updated = true
            if gestures.onFlushSettings then gestures:onFlushSettings() end
            log("applied recommended gestures")
            UIManager:show(InfoMessage:new{ text = _("Gestures set. They work in books."), timeout = 2 })
        end,
    })
end

---------------------------------------------------------------------------------------------
-- Menu (mockup screen 6): Tools › BookOrbit › Android sync
---------------------------------------------------------------------------------------------

local function toggle(key, text)
    return {
        text = text,
        checked_func = function() return S[key] == true end,
        callback = function()
            S[key] = not S[key]
            saveSettings()
            log("setting", key, "=", tostring(S[key]))
        end,
    }
end

function OrbitAndroid:statusText()
    local parts = {}
    if Companion.installed() then
        table.insert(parts, _("companion installed"))
    else
        table.insert(parts, _("no companion"))
    end
    local last = S.last_sleep_sync
    if last then
        table.insert(parts, string.format("%s %s %s", _("last sleep sync"), last.ok and fmt(last.seconds) or _("failed"),
            os.date("%H:%M", last.at)))
    end
    return _("Status: ") .. table.concat(parts, " · ")
end

function OrbitAndroid:updateStatusText()
    local st = S.patch_update_status
    local head = string.format(_("Patch %s"), PATCH_VERSION)
    if not st then return head .. " · " .. _("not checked yet") end
    return string.format("%s · %s (%s)", head, st.text, os.date("%m-%d %H:%M", st.at))
end

function OrbitAndroid:checkPatchUpdate()
    if not NetworkMgr:isConnected() then
        UIManager:show(InfoMessage:new{ text = _("Patch update: connect to Wi-Fi first."), timeout = 4 })
        return
    end
    local msg = InfoMessage:new{ text = _("Checking for a patch update…") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    UIManager:scheduleIn(0.2, function()
        Updater.check("menu", function(_ok, text)
            UIManager:close(msg)
            UIManager:show(InfoMessage:new{ text = _("Patch update: ") .. text, timeout = 6 })
        end)
    end)
end

function OrbitAndroid:menuItems()
    local schedule_items = {}
    for _i, o in ipairs(Schedule.OPTIONS) do
        table.insert(schedule_items, {
            text = _(o.label),
            radio = true,
            checked_func = function() return S.reading_schedule == o.id end,
            callback = function()
                S.reading_schedule = o.id
                saveSettings()
                self.schedule = Schedule.new(o.id, now_s())
                self:hookPluginPagePush()
                log("setting reading_schedule =", o.id)
            end,
        })
    end
    local cap_items = {}
    for _i, c in ipairs({ 10, 15, 20 }) do
        table.insert(cap_items, {
            text = string.format("%d s", c),
            radio = true,
            checked_func = function() return S.sleep_cap == c end,
            callback = function() S.sleep_cap = c; saveSettings() end,
        })
    end
    local function later(fn)
        return function(touchmenu)
            if touchmenu and touchmenu.closeMenu then touchmenu:closeMenu() end
            UIManager:scheduleIn(0.2, fn)
        end
    end
    return {
        toggle("wifi_via_companion", _("Wi-Fi via Orbit Companion")),
        toggle("wake_tailscale", _("Wake Tailscale before syncing")),
        toggle("sync_on_wake", _("Always sync on wake")),
        toggle("sync_on_sleep", _("Sync when the screen goes off")),
        {
            text_func = function() return _("Sync while reading: ") .. _(Schedule.option(S.reading_schedule).label) end,
            sub_item_table = schedule_items,
            separator = true,
        },
        { text = _("Sync and sleep now"), callback = later(function() self:onOrbitSyncAndSleep() end) },
        {
            text_func = function() return string.format(_("Sleep sync limit: %d s"), S.sleep_cap or 20) end,
            sub_item_table = cap_items,
        },
        { text = _("Apply recommended settings"), keep_menu_open = true, callback = function() self:applyRecommendedSettings() end },
        { text = _("Apply recommended gestures"), keep_menu_open = true, callback = function() self:applyRecommendedGestures() end },
        { text = _("Test sync path"), callback = later(function() self:testSyncPath() end), separator = true },
        { text = _("Open Orbit Companion"), callback = later(function() self:onOrbitOpenCompanion() end) },
        { text = _("Open another app…"), callback = later(function() self:onOrbitOpenApps() end), separator = true },
        toggle("auto_update_patch", _("Auto-update patch")),
        toggle("patch_update_prerelease", _("Include pre-releases")),
        { text = _("Check for patch update"), callback = later(function() self:checkPatchUpdate() end) },
        { text_func = function() return self:updateStatusText() end, keep_menu_open = true, callback = function() end, separator = true },
        { text_func = function() return self:statusText() end, keep_menu_open = true, callback = function() end },
    }
end

function OrbitAndroid:addToMainMenu(menu_items)
    local entry = { text = _("Android sync"), sub_item_table_func = function() return self:menuItems() end }
    -- The plugin registers its Tools › BookOrbit entry first (bookorbit_main_menu.lua:320-366).
    local host = menu_items.bookorbit
    if host and type(host.sub_item_table) == "table" then
        table.insert(host.sub_item_table, entry)
    else
        entry.sorting_hint = "tools"
        menu_items.orbit_android = entry
    end
end

---------------------------------------------------------------------------------------------
-- Wi-Fi on/off through the companion (KOReader's Android backend only opens Settings,
-- frontend/device/android/device.lua:316-327)
---------------------------------------------------------------------------------------------

local stock_turnOnWifi = NetworkMgr.turnOnWifi
local stock_turnOffWifi = NetworkMgr.turnOffWifi

function NetworkMgr:turnOnWifi(complete_callback, interactive)
    if not S.wifi_via_companion then
        return stock_turnOnWifi(self, complete_callback, interactive)
    end
    if Companion.installed() then
        Companion.netUp("koreader_wifi_on")
    elseif interactive then
        return stock_turnOnWifi(self, complete_callback, interactive)
    else
        log("wifi on: no companion; waking Tailscale and waiting for Android's Wi-Fi")
        if S.wake_tailscale then tailscaleConnect("koreader_wifi_on") end
    end
    -- KOReader's connectivity check now polls and broadcasts NetworkConnected
    -- (frontend/ui/network/manager.lua:82-133).
    if complete_callback then complete_callback() end
end

function NetworkMgr:turnOffWifi(complete_callback)
    if S.wifi_via_companion and Companion.installed() then
        Companion.send(Companion.ACTION.WIFI_OFF, { reason = "koreader_wifi_off" })
        if complete_callback then complete_callback() end
        return
    end
    return stock_turnOffWifi(self, complete_callback)
end

---------------------------------------------------------------------------------------------
-- Load the module next to the plugins in every FileManager and ReaderUI
-- (apps/reader/readerui.lua:464-478, apps/filemanager/filemanager.lua:418-429)
---------------------------------------------------------------------------------------------

local stock_loadPlugins = PluginLoader.loadPlugins
local stock_genPluginManagerSubItem = PluginLoader.genPluginManagerSubItem
local listing_plugins = false

function PluginLoader:loadPlugins(...)
    local enabled, disabled = stock_loadPlugins(self, ...)
    if listing_plugins then return enabled, disabled end
    local list = {}
    for i, v in ipairs(enabled) do list[i] = v end
    table.insert(list, OrbitAndroid) -- last, so the BookOrbit plugin exists first
    return list, disabled
end

-- Keep the Plugin manager's list to real plugins.
function PluginLoader:genPluginManagerSubItem(...)
    listing_plugins = true
    local ok, r = pcall(stock_genPluginManagerSubItem, self, ...)
    listing_plugins = false
    if not ok then error(r, 0) end
    return r
end

log("patch", PATCH_VERSION, "loaded; companion", Companion.installed() and "installed" or "not installed",
    "| schedule", S.reading_schedule, "| sleep cap", S.sleep_cap .. "s")

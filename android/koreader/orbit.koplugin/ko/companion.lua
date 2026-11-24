-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Orbit Companion and Tailscale (android/docs/INTERFACE.md)
---------------------------------------------------------------------------------------------

Companion = {
    PACKAGE = "net.fledgewing.orbitcompanion",
    PROTOCOL = "1",
    STATUS_URL = "http://127.0.0.1:47913/status",
}
Companion.ACTION = {
    -- The cache worker (docs/design/companion-worker.md): a mirror run, a cache check.
    MIRROR = Companion.PACKAGE .. ".action.MIRROR",
    CHECK = Companion.PACKAGE .. ".action.CHECK",
    -- The storage limit: the companion counts and removes (OC.storageCount).
    STORAGE = Companion.PACKAGE .. ".action.STORAGE",
    -- Keep copies current: the companion finds the changed copies (Copies.ask).
    COPIES = Companion.PACKAGE .. ".action.COPIES",
    -- Updates: the companion checks, installs itself and then the plugin of its release.
    UPDATE = Companion.PACKAGE .. ".action.UPDATE",
    NET_UP = Companion.PACKAGE .. ".action.NET_UP",
    NET_DONE = Companion.PACKAGE .. ".action.NET_DONE",
    WIFI_OFF = Companion.PACKAGE .. ".action.WIFI_OFF",
    SLEEP_NOW = Companion.PACKAGE .. ".action.SLEEP_NOW",
    SHOW_STATUS = Companion.PACKAGE .. ".action.SHOW_STATUS",
    SHOW_APPS = Companion.PACKAGE .. ".action.SHOW_APPS",
    SHOW_LAUNCHER = Companion.PACKAGE .. ".action.SHOW_LAUNCHER",
    STATS = Companion.PACKAGE .. ".action.STATS",
    RELAUNCH = Companion.PACKAGE .. ".action.RELAUNCH",
    -- Companion 0.4.1+: the setup box's "Fix now" (activity) and "Later" (broadcast).
    SHOW_SETUP = Companion.PACKAGE .. ".action.SHOW_SETUP",
    SETUP_LATER = Companion.PACKAGE .. ".action.SETUP_LATER",
    -- Companion 0.4.4+: the Settings PIN keypad (activity).
    SHOW_PIN = Companion.PACKAGE .. ".action.SHOW_PIN",
    -- Companion 0.11.0+ (docs/design/addon-mode.md §7.3): signed in yes/no and the recommended
    -- settings' state, for its two Setup rows. Never the server, the account or the key.
    REPORT = Companion.PACKAGE .. ".action.REPORT",
    -- Companion 0.11.0+ in Add-on mode: its invisible window that starts KOReader again after a
    -- restart (no Home role to do it from the background, docs/design/addon-mode.md §7.4).
    RELAUNCH_UI = Companion.PACKAGE .. ".action.RELAUNCH_UI",
    -- Companion with the "sleep_screen" cap (docs/design/lock-screen.md): the files in
    -- koreader/settings/orbit-sleep/ changed (broadcast); its preview and its Sleep screen page
    -- (activities, from the menu).
    SLEEP_POOL = Companion.PACKAGE .. ".action.SLEEP_POOL",
    SLEEP_PREVIEW = Companion.PACKAGE .. ".action.SLEEP_PREVIEW",
    SHOW_SLEEP = Companion.PACKAGE .. ".action.SHOW_SLEEP",
}
-- Extra the companion puts on the intent that starts KOReader ("home").
Companion.EXTRA_COMMAND = Companion.PACKAGE .. ".extra.COMMAND"
-- With "home_smart": "other_app" when the companion knows Home came from outside KOReader.
Companion.EXTRA_FROM = Companion.PACKAGE .. ".extra.FROM"
-- The display orientation when Home was pressed (companions after 0.11.2): portrait, landscape,
-- reverse_portrait, reverse_landscape (HomePlan.ROTATIONS).
Companion.EXTRA_ROTATION = Companion.PACKAGE .. ".extra.ROTATION"

TAILSCALE = {
    action = "com.tailscale.ipn.CONNECT_VPN",
    package = "com.tailscale.ipn",
    class = "com.tailscale.ipn.IPNReceiver",
}

Companion.ACTION.SETTINGS = Companion.PACKAGE .. ".action.SETTINGS"

-- Vendor quirks, kept to this table (mirrors the companion's Vendor.kt): a vendor launcher that
-- "freezes" (disables) apps, and where it re-enables them. Matched by the launcher being installed.
-- Meebook/Haoqing: measured on a device. Boox/Onyx: unverified (Boox help center documents
-- Apps › App Management › Freeze Settings; the package name is from community reports).
VENDORS = {
    { id = "haoqing", launcher = "com.haoqing.app.hqreader", hint = "Freeze management" },
    { id = "onyx", launcher = "com.onyx", hint = "Apps › App Management › Freeze Settings", unverified = true },
}

vendor_cache = nil
-- The installed vendor launcher's label and hint, or {} (generic Android).
function vendorDisabler()
    if vendor_cache then return vendor_cache end
    vendor_cache = {}
    for _, v in ipairs(VENDORS) do
        local label = Jni.appLabel(v.launcher)
        if label then
            vendor_cache = { id = v.id, label = label, hint = v.hint }
            log("vendor profile:", v.id, "(" .. label .. ")", v.unverified and "[unverified]" or "")
            break
        end
    end
    return vendor_cache
end

function Companion.disabledText()
    local v = vendorDisabler()
    return disabledText("Orbit Companion", v.label, v.hint)
end

installed_cache = { at = -1000, value = "missing", logged = nil }

-- "ok", "frozen" (installed but disabled, e.g. by a vendor launcher's app freeze) or "missing".
function Companion.state()
    local t = now_s()
    if t - installed_cache.at > 30 then
        local ok, v = pcall(android.isPackageEnabled, Companion.PACKAGE)
        local st
        if ok and v == true then
            st = "ok"
        else
            local setting = Jni.appEnabledSetting(Companion.PACKAGE)
            st = (setting == nil or setting == false) and "missing" or "frozen"
        end
        installed_cache.value, installed_cache.at = st, t
        if installed_cache.logged ~= st then
            installed_cache.logged = st
            if st == "frozen" then
                log("companion disabled:", Companion.disabledText(), "Wi-Fi can't be switched")
            else
                log("companion", st == "ok" and "available" or "not installed")
            end
        end
    end
    return installed_cache.value
end

-- Usable: installed and not frozen.
function Companion.installed()
    return Companion.state() == "ok"
end

-- The status file the companion writes (docs/design/addon-mode.md §6.2): koreader/settings/.
function Companion.statusFile()
    local okd, DataStorage = pcall(require, "datastorage")
    if not okd or type(DataStorage) ~= "table" then return nil end
    return DataStorage:getSettingsDir() .. "/orbit-companion.json"
end

-- The decoded status file, or nil (missing, unreadable or half-written: ignored).
function Companion.readFile()
    local path = Companion.statusFile()
    local f = path and io.open(path, "rb")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    local okj, json = pcall(require, "json")
    if not okj then return nil end
    local okd, data = pcall(json.decode, body or "")
    return okd and type(data) == "table" and data or nil
end

-- Resolve the companion's mode and caps (Caps.resolve) from /status (st, or nil) and the file.
-- Returns the caps before, the caps now, and whether both are the companion's own word (so a
-- change is real, not a first guess).
function Companion.updateCaps(st, why)
    local cached = S.companion_caps and { mode = S.companion_mode, caps = S.companion_caps } or nil
    local cstate = Companion.state()
    local file = Companion.readFile()
    Companion.file = cstate == "ok" and file or nil
    local caps, mode, source = Caps.resolve(cstate, file, st, cached)
    Companion.caps_state = cstate
    local before, was_known = Companion.cap_set, Companion.caps_known
    Companion.cap_set, Companion.mode, Companion.caps_source = caps, mode, source
    Companion.caps_known = source == "status" or source == "file" or source == "cache"
    if source == "status" or source == "file" then
        local list = Caps.list(caps)
        if table.concat(list, ",") ~= table.concat(S.companion_caps or {}, ",") or mode ~= S.companion_mode then
            S.companion_caps, S.companion_mode = list, mode
            saveSettings()
            log("companion: mode", tostring(mode), "caps", table.concat(list, ","), "(from " .. source .. ", " .. tostring(why) .. ")")
        end
    end
    return before, caps, was_known and Companion.caps_known and (source == "status" or source == "file")
end

-- A companion feature is available (docs/design/addon-mode.md §6.3). The package being installed
-- is Companion.installed(); this is what a feature needs. Before the first refresh: the file, or
-- the caps seen last time (load-time hooks decide before any refresh, §6.2 step 5).
function Companion.has(cap)
    if not Companion.installed() then return false end
    if not Companion.cap_set or Companion.caps_state ~= "ok" then Companion.updateCaps(nil, "first use") end
    return Companion.cap_set[cap] == true
end

-- The cache worker's one check (docs/design/companion-worker.md "Required companion"): the plugin
-- and the companion ship together, so the companion must be installed and be this plugin's
-- version. nil when it is, else the line to show. No skew handling and no fallback: without it,
-- nothing heavy runs in KOReader either (no mirror, no background checks).
-- The plugin and the companion ship together (docs/design/companion-worker.md "Required
-- companion"): nil when the companion of this plugin's own version is there, else what to do.
-- purpose: what it is needed for (default "to save BookOrbit for offline").
function Companion.workerProblem(purpose)
    purpose = purpose or _("to save BookOrbit for offline")
    local st = Companion.state()
    if st ~= "ok" then return _("Orbit Companion needed") .. " " .. purpose end
    local t = now_s()
    if not Companion.version_at or t - Companion.version_at > 30 then
        local f = Companion.readFile()
        Companion.version, Companion.version_at = f and f.version, t
    end
    local v = Companion.version
    if v ~= PATCH_VERSION then
        return string.format(_("Update Orbit Companion to %s %s (it is %s)"), PATCH_VERSION, purpose, tostring(v or "older"))
    end
    return nil
end

-- For menus and the test: what's wrong with the companion, or nil.
function Companion.problem()
    local st = Companion.state()
    if st == "frozen" then return Companion.disabledText() end
    if st == "missing" then return _("Orbit Companion is not installed.") end
    return nil
end

request_seq = 0

function Companion.send(action, extras)
    extras = extras or {}
    extras.proto = Companion.PROTOCOL
    extras.sender = "org.koreader.launcher"
    extras.patch_version = PATCH_VERSION
    local ok = Jni.sendBroadcast{ action = action, package = Companion.PACKAGE, extras = extras }
    log("companion", action:match("[^.]+$"), ok and "sent" or "NOT sent", extras.reason or "")
    return ok
end

-- opts: wake_lock_s, owner ("auto": the patch needs it; "manual": the reader asked by hand).
function Companion.netUp(reason, opts)
    opts = opts or {}
    request_seq = request_seq + 1
    return Companion.send(Companion.ACTION.NET_UP, {
        reason = reason,
        request_id = tostring(request_seq),
        wifi = S.wifi_via_companion and "1" or "0",
        tailscale = S.wake_tailscale and "1" or "0",
        wake_lock_s = tostring(opts.wake_lock_s or 0),
        owner = opts.owner or "auto",
        mode = S.wifi_mode or "",
    }), tostring(request_seq)
end

-- restore: "off" when Wi-Fi was off before this sleep sync (the companion turns it off again).
function Companion.netDone(reason, ok, seconds, detail, restore)
    if not Companion.has("sleep_sync") then return end
    Companion.send(Companion.ACTION.NET_DONE, {
        reason = reason,
        ok = ok and "1" or "0",
        seconds = string.format("%.1f", seconds or 0),
        detail = detail or "",
        restore = restore or "",
    })
end

-- auto: only if the companion (or the patch) turned Wi-Fi on; the companion keeps Wi-Fi the
-- reader turned on by hand. force (auto = "0"): the reader's own "Wi-Fi off" or off while reading.
function Companion.wifiOff(reason, auto)
    return Companion.send(Companion.ACTION.WIFI_OFF, { reason = reason, auto = auto and "1" or "0", mode = S.wifi_mode or "" })
end

-- Optional loopback status. Returns a table or nil.
-- A book is open in KOReader (the reader UI has a document).
function Companion.bookOpen()
    local okr, ReaderUI = pcall(require, "apps/reader/readerui")
    return okr and type(ReaderUI) == "table" and ReaderUI.instance ~= nil and ReaderUI.instance.document ~= nil
end

function Companion.status(timeout)
    local okr, http = pcall(require, "socket.http")
    if not okr then return nil end
    local socket = require("socket")
    local socketutil = require("socketutil")
    local ltn12 = require("ltn12")
    local body = {}
    -- Loopback only (never Wi-Fi), so it answers at once or not at all: the UI thread waits at
    -- most `timeout` (1 s), well under Android's 5 s input timeout.
    socketutil:set_timeout(timeout or 1, timeout or 1)
    -- patch_version tells the companion which patch is running (its "restart to finish" row).
    -- book (0.5.2+): a book is open, so the companion waits with a restart until it closes.
    local url = Companion.STATUS_URL .. "?patch_version=" .. PATCH_VERSION .. "&book=" .. (Companion.bookOpen() and "1" or "0")
    local code = socket.skip(1, http.request{ url = url, sink = ltn12.sink.table(body) })
    socketutil:reset_timeout()
    if code ~= 200 then return nil end
    local okj, json = pcall(require, "json")
    if not okj then return {} end
    local okd, data = pcall(json.decode, table.concat(body))
    return okd and type(data) == "table" and data or {}
end

---------------------------------------------------------------------------------------------

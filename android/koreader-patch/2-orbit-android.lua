-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader-patch/LICENSE).
--[[--
orbit-android: a KOReader user patch for Android e-readers (generic Android; vendor quirks live in VENDORS).

The official BookOrbit plugin (bookorbit.koplugin) does ALL syncing and holds the login.
This patch never talks to BookOrbit's API. It only:

  * gets the network ready (Wi-Fi through the "Orbit Companion" app, Tailscale wake),
  * checks that the plugin's configured server answers at its base URL (no login),
  * then triggers or waits on the plugin: its public action BookOrbitOpenDashboard and its
    "Push while reading" setting, and, behind a compatibility check with a fallback for each
    (Compat below; android/koreader-patch/README.md "Plugin hook points"), its internals
    requestLifecycleOutboxDrain, requestProgressPull, requestProgressPush,
    fetchRemoteProgress, _onSuspend, onBookOrbitSyncBook, startSweep.

File name: "2-" is KOReader's `late` priority (frontend/userpatch.lua:13): it runs after
UIManager is ready and before the file browser or reader starts, so the module below is
created alongside the plugins in every FileManager and ReaderUI.

Companion interface: android/docs/INTERFACE.md. Logs: `adb logcat | grep OrbitAndroid`.
]]

-- Stamped by the release workflow (.github/workflows/release.yml) from the tag; a copy from the
-- repo says 0.0.0-dev, which any release replaces.
local PATCH_VERSION = "0.0.0-dev"

---------------------------------------------------------------------------------------------
-- Pure logic (no KOReader modules). Unit-tested by android/koreader-patch/test/.
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

function Schedule.valid(id)
    for _, o in ipairs(Schedule.OPTIONS) do
        if o.id == id then return true end
    end
    return false
end

-- "Sync while reading" set in the companion (android/docs/INTERFACE.md "reading_schedule_request"):
-- req = { id, at (ms) } from /status. The patch keeps the setting; it applies a request once,
-- newer than the last it applied (applied_at, ms). Returns the id to apply, or nil.
function Schedule.request(req, applied_at)
    if type(req) ~= "table" or not Schedule.valid(req.id) then return nil end
    local at = tonumber(req.at)
    if not at or at <= (tonumber(applied_at) or 0) then return nil end
    return req.id, at
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

-- "v1.2.3", "android-v1.2.3", "1.2.3-rc.1", "1.2.3+build" -> { 1, 2, 3, pre = "rc.1" | nil }, or nil.
-- Orbify releases Android (v<version>; android-v<version> is read too) and firmware
-- (xteink-v<version>) from one repo (AGENTS.md "Releases"); a firmware tag is not a version
-- here, so the patch never picks one.
function Update.parseVersion(s)
    if type(s) ~= "string" then return nil end
    s = s:match("^%s*(.-)%s*$"):gsub("^android%-", ""):gsub("^[vV]", "")
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
Update.BLOCKED = "Internet blocked: is 'Block connections without VPN' on for Tailscale?"

Update.WENT_DOWN = "network went down during the check"
Update.NO_ANSWER = "GitHub didn't answer (the network may still be starting). Try again in a minute."

-- A connect timeout or reset right after Wi-Fi or Tailscale comes up is usually gone seconds
-- later (11-21 Boox: a 15 s timeout, then 0.04 s a minute after). Retry twice, after 3 s
-- and 10 s, with a shorter per-try timeout (Update.TRY_TIMEOUT_S).
Update.RETRY_WAITS = { 3, 10 }
Update.TRY_TIMEOUT_S = 8

function Update.transient(err)
    local low = tostring(err or ""):lower()
    if not low:find("^network:") then return false end
    return low:find("timeout", 1, true) ~= nil or low:find("timed out", 1, true) ~= nil
        or low:find("reset", 1, true) ~= nil
end

-- fn() returns body or nil, err. Retries transient errors after each wait in RETRY_WAITS.
-- sleep(s) and note(try, err, wait) are injected (tests; the child sleeps for real).
function Update.withRetry(fn, sleep, note)
    local body, err = fn()
    for i, wait in ipairs(Update.RETRY_WAITS) do
        if body or not Update.transient(err) then break end
        if note then note(i, err, wait) end
        sleep(wait)
        body, err = fn()
    end
    return body, err
end

-- An update request failed: plain words. err: httpGet's error ("network: permission denied"
-- is EACCES, what Android returns when "Block connections without VPN" stops a socket outside
-- Tailscale). st (the state after the failure; nil fields: unknown):
--   wifi_on, connected: the radio and KOReader's "connected";
--   lockdown: the companion's reading of "Block connections without VPN" (only true blames it);
--   went_down: Wi-Fi was switched off (or decided off) while the check ran.
function Update.errorText(err, st)
    err = tostring(err)
    st = st or {}
    local low = err:lower()
    if low:find("permission denied", 1, true) or err:find("EACCES", 1, true) or err:find("EPERM", 1, true)
        or low:find("operation not permitted", 1, true) then
        if st.lockdown == true then return Update.BLOCKED end
        return "no internet: Android refused the connection (" .. err:gsub("^network: ", "") .. ")"
    end
    if st.went_down then return Update.WENT_DOWN end
    if st.wifi_on == false then return "no internet: Wi-Fi is off" end
    if st.connected == false then return "no internet: Wi-Fi isn't connected" end
    if err:find("network:", 1, true) then
        if st.lockdown == true then return Update.BLOCKED end
        return Update.NO_ANSWER
    end
    return "check failed: " .. err
end

-- After a failed check, wait this long before an automatic retry.
Update.RETRY_S = 3600

-- The automatic check's gate. ctx: enabled, now (os.time), checked_at (last success),
-- failed_at (last failure), connected, in_book, off_decided (a just-in-time Wi-Fi off was
-- decided recently). Returns ok, why.
function Update.autoGate(ctx)
    if not ctx.enabled then return false, "auto-update is off" end
    if not Update.isDue(ctx.checked_at, ctx.now) then return false, "checked today" end
    local failed = tonumber(ctx.failed_at) or 0
    if failed > 0 and ctx.now >= failed and ctx.now - failed < Update.RETRY_S then
        return false, "failed " .. math.floor((ctx.now - failed) / 60) .. " min ago; retry after 1 h"
    end
    if ctx.in_book then return false, "a book is open; deferred to the file browser or BookOrbit home" end
    if ctx.off_decided then return false, "Wi-Fi is going off" end
    if not ctx.connected then return false, "network not up" end
    return true
end

-- The child's result over the pipe: "1|0 <tab> net|msg <tab> text".
function Update.encode(ok, text, neterr)
    return (ok and "1" or "0") .. "\t" .. (neterr and "net" or "msg") .. "\t" .. tostring(neterr or text or "")
end

function Update.decode(data)
    local okf, kind, text = tostring(data or ""):match("^([01])\t(%a+)\t(.*)$")
    if not okf then return false, "msg", "check failed: no answer from the background check" end
    return okf == "1", kind, text
end

function Update.isDue(last, now, interval)
    last = tonumber(last) or 0
    return last <= 0 or now < last or now - last >= (interval or Update.INTERVAL)
end

-- Wi-Fi modes (android/docs/DESIGN.md "Wi-Fi modes"). The companion does the switching and refuses an
-- automatic off when the user turned Wi-Fi on by hand; this plan only says *when* the patch
-- asks for on or off.
--   always_on    the user's Wi-Fi stays as it is; flows that had to turn it on put it back off
--   off_reading  a book opening turns Wi-Fi off; closing it restores what it was before
--   jit          off unless something needs it: off when a flow ends in a book, and after
--                idle_s with no network activity
local WifiPlan = {
    MODES = {
        { id = "always_on",   label = "Always on" },
        { id = "off_reading", label = "Off while reading" },
        { id = "jit",         label = "Just in time" },
    },
    IDLE_MINUTES = { 1, 2, 5, 10 },
    GRACE = 3, -- seconds after the last flow ends before acting (lets the plugin start its follow-ups)
}

function WifiPlan.validMode(m)
    for _i, o in ipairs(WifiPlan.MODES) do if o.id == m then return true end end
    return false
end

function WifiPlan.modeLabel(m)
    for _i, o in ipairs(WifiPlan.MODES) do if o.id == m then return o.label end end
    return m
end

function WifiPlan.new(mode, idle_min, now)
    return {
        mode = WifiPlan.validMode(mode) and mode or "jit",
        idle_s = (tonumber(idle_min) or 2) * 60,
        leases = {},          -- flow name -> count
        n = 0,                -- total leases held
        restore_off = false,  -- Wi-Fi was off when the first current lease started
        release_at = nil,     -- the last lease ended; act from this time on
        last_flow = nil,
        last_activity = now or 0,
        in_book = false,
        book_was_on = nil,    -- off_reading: Wi-Fi state when the book opened
        force_off_once = false,
        foreground = true,    -- KOReader in front (Suspend/Resume)
    }
end

-- A flow needs the network. wifi_on: the radio state now (nil = unknown).
function WifiPlan.acquire(st, name, wifi_on, now)
    if st.n == 0 then st.restore_off = (wifi_on == false) end
    st.leases[name] = (st.leases[name] or 0) + 1
    st.n = st.n + 1
    st.release_at = nil
    st.last_activity = now
end

-- handled: someone else restores (the companion, after a sleep sync).
function WifiPlan.release(st, name, now, handled)
    if (st.leases[name] or 0) <= 0 then return end
    st.leases[name] = st.leases[name] - 1
    st.n = st.n - 1
    st.last_activity = now
    st.last_flow = name
    if handled then st.restore_off = false end
    if st.n == 0 then st.release_at = now + WifiPlan.GRACE end
end

function WifiPlan.activity(st, now) st.last_activity = now end

function WifiPlan.bookOpened(st, wifi_on)
    st.in_book = true
    st.book_was_on = wifi_on
    st.force_off_once = st.mode == "off_reading" and wifi_on == true
end

-- Returns "on" when off_reading should turn Wi-Fi back on.
function WifiPlan.bookClosed(st)
    local was = st.book_was_on
    st.in_book, st.book_was_on, st.force_off_once = false, nil, false
    if st.mode == "off_reading" and was == true then return "on" end
    return nil
end

-- Wi-Fi went off (by anyone): nothing left to restore.
function WifiPlan.wifiOff(st)
    st.restore_off = false
    st.release_at = nil
    st.force_off_once = false
end

-- ctx = { now, wifi_on, busy, screen_off }. Returns action ("off" | nil), reason, force.
-- force: off_reading's book-open off, which applies even to Wi-Fi turned on by hand.
-- Never off while a flow holds the network, the plugin or a download is busy, or (except
-- with the screen off) while another app is in front.
function WifiPlan.decide(st, ctx)
    if ctx.wifi_on == false then return nil, "already off" end
    if st.n > 0 then return nil, "in use" end
    if ctx.busy then return nil, "busy" end
    if not st.foreground and not ctx.screen_off then return nil, "KOReader not in front" end
    local released = st.release_at ~= nil and ctx.now >= st.release_at
    if st.force_off_once and st.in_book and (released or st.release_at == nil) then
        return "off", "book opened (off while reading)", true
    end
    if released then
        if st.restore_off then return "off", "restore previous state (off) after " .. tostring(st.last_flow) end
        if st.in_book and st.mode ~= "always_on" then
            return "off", (st.mode == "jit" and "just in time" or "off while reading") .. ": " .. tostring(st.last_flow) .. " done in a book"
        end
    end
    if st.mode == "jit" and ctx.now - st.last_activity >= st.idle_s then
        return "off", string.format("just in time: idle %d min", math.floor(st.idle_s / 60))
    end
    return nil, "needed or not idle"
end

-- Settings.Global "wifi_on" -> radio on? (nil: unknown)
function Plan.wifiOnSetting(v)
    if v == 1 or v == 2 then return true end
    if v == 0 or v == 3 then return false end
    return nil
end

-- Smart Home (android/docs/INTERFACE.md "go home"). What Home does in KOReader.
--   mode: "smart" | "bookorbit"; in_reader: a book is open; covered: a menu or the
--   plugin's views are over it; on_dashboard: the plugin's BookOrbit home (dashboard) is the
--   top widget; from_other: Home came from another app (or KOReader was just started);
--   reopen: a current book that isn't open now and still exists: the book Home itself closed
--   (home_book), or the one KOReader was killed with (cold start, open_book_at_exit). A book
--   the user closed is never reopened from history.
-- bookorbit_sub: a BookOrbit screen that isn't its main page is on top (BookOrbit.screen).
-- Returns "bookorbit_main" (that BookOrbit main page), "companion" (the companion's launcher page), "dashboard" (close any book,
-- BookOrbit home) or "book" (show the book: close what covers it, or open the last one).
-- Presses in KOReader step book -> BookOrbit home -> companion; Home from another app (the
-- companion included) goes back to the book, so the steps never loop.
local HomePlan = {}

function HomePlan.decide(o)
    -- A BookOrbit page past its first (the dashboard's page 2, a list's page 3), nothing over
    -- it: page 1 first; only page 1 leaves (v0.5.4).
    if o.page_above_1 and not o.from_other then return "first_page" end
    -- Any BookOrbit screen other than its main page (a detail, list, search, board, settings,
    -- a sheet or dialog over the catalog): back to the main page (v0.4.9).
    if o.bookorbit_sub then return "bookorbit_main" end
    if o.on_dashboard and not o.from_other then return "companion" end
    if o.mode ~= "smart" then return "dashboard" end
    if o.in_reader then
        if not o.covered and not o.from_other then return "dashboard" end
        return "book"
    end
    if o.reopen then return "book" end
    return "dashboard"
end

-- KOReader was in the background this long before the command arrived: Home from inside
-- KOReader pauses it for well under this; a stay in another app is longer.
HomePlan.OTHER_APP_S = 2.5

function HomePlan.cameFromOtherApp(from_extra, suspended_s)
    if from_extra == "other_app" then return true end
    if from_extra == "koreader" then return false end
    return suspended_s == nil or suspended_s >= HomePlan.OTHER_APP_S
end

-- "<app> is disabled by <launcher label>: re-enable it in <label> › <hint>.", or a neutral text.
-- Pure (tested): disabler is the label read at run time, or nil.
local function disabledText(app, disabler, hint)
    if disabler and hint then
        return string.format("%s is disabled by %s: re-enable it in %s › %s.", app, disabler, disabler, hint)
    elseif disabler then
        return string.format("%s is disabled by %s: re-enable it there.", app, disabler)
    end
    return app .. " is disabled by the system: re-enable it in Settings › Apps."
end

-- Plugin compatibility (survive BookOrbit plugin updates). Every plugin internal the patch
-- calls, grouped by the feature that needs it. A missing one turns off only that feature, which
-- then falls back to the plugin's own behaviour. Definitions (bookorbit.koplugin 2.3.0):
-- main.lua:283 isLoggedIn, :287 errorLabel, :361 getSyncCoordinator, :374 getLifecycleOutbox,
-- :414 requestLifecycleOutboxDrain, :717 requestProgressPush, :730 requestProgressPull,
-- :1246 startSweep, :1269 onBookOrbitSyncBook, :1340 _onSuspend, :1381 onBookOrbitOpenDashboard,
-- :1416 onBookOrbitToggleAutoSync; bookorbit_progress_sync.lua:63 getLastPercent, :71
-- getLastProgress, :81 getDocumentDigest, :145 isSamePlace, :157 remoteProgressIsNewer, :521
-- fetchRemoteProgress; the catalog widget: main.lua:1207-1230
-- (catalog_browser, close_callback), bookorbit_catalog.lua:1875 dashboardMode.
-- test/plugin_compat.lua checks the same list against the latest plugin source (CI, weekly).
local Compat = {}
Compat.FEATURES = {
    { id = "core", needs = { isLoggedIn = "function", settings = "table" },
      fallback = "the patch leaves syncing to the plugin" },
    { id = "outbox", needs = { requestLifecycleOutboxDrain = "function", getLifecycleOutbox = "function",
        getSyncCoordinator = "function" },
      fallback = "wake and sleep syncs use the plugin's own sync" },
    { id = "wake_pull", needs = { requestProgressPull = "function" },
      fallback = "wake and open pulls use the plugin's own timing" },
    { id = "sleep_snapshot", needs = { _onSuspend = "function" },
      fallback = "Sync and sleep sends what the plugin already queued" },
    { id = "reading_sync", needs = { fetchRemoteProgress = "function", isSamePlace = "function",
        remoteProgressIsNewer = "function", getLastPercent = "function", getLastProgress = "function",
        getDocumentDigest = "function", requestProgressPush = "function", requestProgressPull = "function",
        requestLifecycleOutboxDrain = "function" },
      fallback = "Sync while reading is off" },
    { id = "dashboard", needs = { onBookOrbitOpenDashboard = "function" },
      fallback = "Home closes the book, then the plugin opens BookOrbit home" },
    { id = "test_sync", needs = { onBookOrbitSyncBook = "function", startSweep = "function", errorLabel = "function" },
      fallback = "Test sync path skips the plugin step" },
    { id = "recommended", needs = { onBookOrbitToggleAutoSync = "function" },
      fallback = "Apply recommended settings can't turn on Auto-sync" },
}
-- The feature that names each plugin event (advisory logging in pluginEvent).
local PLUGIN_EVENT_FEATURE = { BookOrbitOpenDashboard = "dashboard", BookOrbitSyncBook = "test_sync",
    BookOrbitToggleAutoSync = "recommended" }
-- Plugin settings the patch writes, with the values the plugin accepts. catalog_auto_open is the
-- plugin's open mode (2.3.0 bookorbit_settings_page.lua:205-209 "Make BookOrbit home" = "home";
-- read by main.lua:940-960 onStart/maybeAutoOpenCatalog; the plugin saves it by setting the
-- field and flushing G_reader_settings, bookorbit_settings_page.lua:822-825).
Compat.SETTINGS = { catalog_auto_open = { off = true, filemanager = true, home = true } }

-- The setting can be written: the plugin's settings table, and the current value unset or one
-- the plugin knows (a value we don't know means the plugin changed the setting: leave it alone).
function Compat.settable(settings, key, value)
    local known = Compat.SETTINGS[key]
    if type(settings) ~= "table" or not known or not known[value] then return false end
    local cur = settings[key]
    return cur == nil or (type(cur) == "string" and known[cur] == true)
end

-- On the catalog widget, checked when it is open.
Compat.CATALOG = { dashboardMode = "function", close_callback = "function", goDashboard = "function" }

-- Lists by series and by author (v0.6.0, Grouping): the catalog class's methods it wraps or
-- calls (bookorbit_catalog.lua :847 switchTo, :881 fetch, :974 loadSection, :1111
-- paramsForEntry, :1181 loadBooks, :924 runConnected, :970 showRetry; the list methods copied
-- onto it by CatalogLists.install, bookorbit_catalog_lists.lua :45 listKind, :246
-- listSectionParams, :659 listSortSheetModel, :739 listRun, :1115 listToolbar, :1155
-- listHeader), and the API class's (bookorbit_api.lua :386 query, :714 catalogBooks, :720
-- catalogManifest). A missing one turns off only this feature (logged once).
Compat.CATALOG_CLASS = { switchTo = "function", fetch = "function", loadSection = "function",
    paramsForEntry = "function", loadBooks = "function", runConnected = "function", showRetry = "function",
    listKind = "function", listSectionParams = "function", listSortSheetModel = "function", listRun = "function",
    listToolbar = "function", listHeader = "function" }
Compat.API_CLASS = { query = "function", catalogBooks = "function", catalogManifest = "function" }

-- Paging on the catalog, for Home's "page 1 first" (v0.5.4): the dashboard's page
-- (bookorbit_catalog_board.lua:119-123 boardPage, :968-976 boardFlip) and a list's page
-- (bookorbit_catalog_lists.lua:64-66 listMode, :390-411 listPaging, :421-446 listGoPage).
Compat.PAGING = { boardPage = "function", boardFlip = "function", listMode = "function",
    listPaging = "function", listGoPage = "function" }

-- "function" means callable: KOReader 2025.10+ wraps every plugin on* handler in a
-- HandlerSandbox, a table with __call (frontend/pluginloader.lua v2026.07.1:117-128, :158-164,
-- applied at :263); up to 2025.08 the wrapper was a plain function. A type() check alone saw
-- 2.3.0's handlers as missing on 2025.10+ (11-21 Boox Page, KOReader 2026.07.1).
function Compat.callable(v)
    if type(v) == "function" then return true end
    if type(v) ~= "table" and type(v) ~= "userdata" then return false end
    local okm, mt = pcall(getmetatable, v)
    return okm and type(mt) == "table" and mt.__call ~= nil
end

local function hasKind(v, kind)
    if kind == "function" then return Compat.callable(v) end
    return type(v) == kind
end

-- { [id] = missing symbols (sorted list) } for one plugin instance; {} when all is there.
function Compat.check(p)
    local out = {}
    for _, f in ipairs(Compat.FEATURES) do
        local missing = {}
        for name, kind in pairs(f.needs) do
            local okv, v = pcall(function() return p[name] end)
            if not okv or not hasKind(v, kind) then table.insert(missing, name) end
        end
        if #missing > 0 then table.sort(missing); out[f.id] = missing end
    end
    return out
end

-- The names in needs that obj lacks (sorted); {} when all are there.
function Compat.missingOn(obj, needs)
    local missing = {}
    for name, kind in pairs(needs) do
        local okv, v = pcall(function() return obj[name] end)
        if not okv or not hasKind(v, kind) then table.insert(missing, name) end
    end
    table.sort(missing)
    return missing
end

function Compat.fallback(id)
    for _, f in ipairs(Compat.FEATURES) do if f.id == id then return f.fallback end end
    return id
end

-- One line per unavailable feature, e.g. "BookOrbit 2.4.0 changed: sleep sync uses ...".
function Compat.lines(missing, version)
    local ids = {}
    for id in pairs(missing) do table.insert(ids, id) end
    table.sort(ids)
    local out = {}
    for _, id in ipairs(ids) do
        table.insert(out, string.format("BookOrbit %s changed: %s", version or "?", Compat.fallback(id)))
    end
    return out
end

---------------------------------------------------------------------------------------------
-- Battery stats (docs/design/STATS-DESIGN.md): the patch counts page turns and screen refreshes and
-- sends them to the companion in batches (STATS), never per page. The companion stores them.
---------------------------------------------------------------------------------------------

local Stats = { INTERVAL = 300 }

local function set(list) local t = {} for w in list:gmatch("%S+") do t[w] = true end return t end
Stats.TEXT = set("epub epub3 fb2 fb3 txt text html htm xhtml mobi azw azw3 prc pdb doc docx rtf odt md chm")
Stats.COMIC = set("cbz cbr cb7 cbt jpg jpeg png gif webp bmp tif tiff")
Stats.PDF = set("pdf djvu djv xps oxps")
-- Flashing refreshes (refresh_methods, frontend/ui/uimanager.lua:1142-1152); the rest
-- (partial, ui, fast, a2, [ui], [partial]) are partial.
Stats.FULL = set("full flashui flashpartial")

-- text, comic, webtoon (a comic in continuous mode: ReaderView.page_scroll,
-- readerview.lua:959/986), pdf, or none (no book). Unknown extensions go by the engine.
function Stats.contentOf(file, page_scroll, paging)
    if type(file) ~= "string" or file == "" then return "none" end
    local f = file:lower():gsub("%.zip$", "")
    local ext = f:match("%.([%w]+)$")
    if ext and Stats.COMIC[ext] then return page_scroll and "webtoon" or "comic" end
    if ext and Stats.PDF[ext] then return "pdf" end
    if ext and Stats.TEXT[ext] then return "text" end
    return paging and "pdf" or "text"
end

function Stats.new(now) return { pages = 0, full = 0, partial = 0, at = now, seq = 0 } end

function Stats.refresh(acc, mode)
    if Stats.FULL[mode] then acc.full = acc.full + 1 else acc.partial = acc.partial + 1 end
end

function Stats.page(acc) acc.pages = acc.pages + 1 end

function Stats.counted(acc) return acc.pages + acc.full + acc.partial > 0 end

-- Takes the batch since the last one as STATS extras (all strings) and starts a new one.
-- content: the open book's type, or "none". open: a book stays open after this batch.
-- Nothing to send (no book and nothing counted, or paused by a suspend): nil.
function Stats.take(acc, now, content, open, extra)
    if not acc.at then return nil end
    if content == "none" and not Stats.counted(acc) then acc.at = now return nil end
    local period = math.max(0, now - acc.at)
    acc.seq = acc.seq + 1
    local out = {
        seq = tostring(acc.seq),
        period_s = tostring(math.floor(period + 0.5)),
        pages = tostring(acc.pages), full = tostring(acc.full), partial = tostring(acc.partial),
        content = content,
        open = open and "1" or "0",
        reading_min = string.format("%.1f", content ~= "none" and period / 60 or 0),
    }
    for k, v in pairs(extra or {}) do out[k] = tostring(v) end
    acc.pages, acc.full, acc.partial, acc.at = 0, 0, 0, now
    return out
end

-- When the next batch is due: every INTERVAL while a book is open or something was counted.
function Stats.isDue(acc, now, book_open)
    return acc.at ~= nil and (book_open or Stats.counted(acc)) and now - acc.at >= Stats.INTERVAL
end

---------------------------------------------------------------------------------------------
-- Clicker buttons (android/docs/BTKEYS-DESIGN.md): the companion's key map, handled inside KOReader.
-- Keys are Android keycodes (ev.code in Input:handleKeyBoardEv, frontend/device/input.lua:723).
---------------------------------------------------------------------------------------------

local Clicks = { HOLD = 0.6, DOUBLE = 0.35, EPS = 1e-6, map = {} }
Clicks.ACTIONS = set("next prev home back light sync_sleep")
Clicks.KINDS = { "press", "hold", "double" }

-- /status "keymap": { ["87"] = { press = "next", hold = "sync_sleep" }, ... } -> keycode-keyed.
function Clicks.parse(keymap)
    local out = {}
    if type(keymap) ~= "table" then return out end
    for k, v in pairs(keymap) do
        local code = tonumber(k)
        if code and type(v) == "table" then
            local acts
            for _, kind in ipairs(Clicks.KINDS) do
                if Clicks.ACTIONS[v[kind]] then acts = acts or {}; acts[kind] = v[kind] end
            end
            out[code] = acts
        end
    end
    return out
end

-- Press/hold/double for one key, never blocking: feed down/up, call tick at nextDue. A key with
-- only "press" fires on key down (no delay); hold/double are timed only when mapped.
function Clicks.down(st, now, acts)
    if st.down_at then return nil end
    st.down_at, st.hold_fired = now, false
    local pending, late = st.single_due, false
    if pending then
        st.single_due = nil
        if acts.double and now <= pending then st.hold_fired = true return "double" end
        late = acts.press ~= nil
    end
    if not acts.hold and not acts.double then
        st.hold_fired = true
        return acts.press and "press" or nil
    end
    return late and "press" or nil
end

function Clicks.up(st, now, acts)
    local d = st.down_at
    if not d then return nil end
    st.down_at = nil
    if st.hold_fired then return nil end
    if acts.hold and now - d >= Clicks.HOLD - Clicks.EPS then return "hold" end
    if acts.double then st.single_due = now + Clicks.DOUBLE return nil end
    return acts.press and "press" or nil
end

function Clicks.nextDue(st, acts)
    if st.down_at and not st.hold_fired and acts.hold then return st.down_at + Clicks.HOLD end
    return st.single_due
end

function Clicks.tick(st, now, acts)
    if st.down_at and not st.hold_fired and acts.hold and now - st.down_at >= Clicks.HOLD - Clicks.EPS then
        st.hold_fired = true
        return "hold"
    end
    if st.single_due and now >= st.single_due - Clicks.EPS then
        st.single_due = nil
        return acts.press and "press" or nil
    end
    return nil
end

-- One interception path (v0.4.2, android/docs/BTKEYS-DESIGN.md "One path"): with the companion's
-- accessibility service on, it takes mapped keys in KOReader too and sends the action over the
-- /clicks channel. The patch's own key path is the fallback: on unless the channel is up and
-- the service on, so a key never turns two pages.
function Clicks.ownPath(channel_up, service_on)
    return not (channel_up and service_on)
end

-- A /clicks line: "CLICK next 12" -> "click", "next"; "SERVICE on" -> "service", true.
function Clicks.parseLine(line)
    local action = type(line) == "string" and line:match("^CLICK (%S+)")
    if action then return "click", Clicks.ACTIONS[action] and action or nil end
    local svc = type(line) == "string" and line:match("^SERVICE (%S+)")
    if svc then return "service", svc == "on" end
    return nil
end

---------------------------------------------------------------------------------------------
-- "Setup needs you" box (companion 0.4.1+): /status carries setup_prompt = { key, rows } only
-- while rows need the user and they didn't say Later (the companion's snooze). Shown once per
-- key, never with a book on screen: the file browser, BookOrbit home or a menu.
---------------------------------------------------------------------------------------------

local SetupPrompt = {}

-- where: "reader" (a book on screen), "browser", "bookorbit" or "menu". Returns show, why.
function SetupPrompt.decide(prompt, where, shown_key)
    if type(prompt) ~= "table" or type(prompt.key) ~= "string" or prompt.key == "" then return false, "nothing needed" end
    if where == "reader" then return false, "in a book" end
    if prompt.key == shown_key then return false, "already shown" end
    return true, where
end

function SetupPrompt.text(prompt)
    local rows = type(prompt.rows) == "table" and prompt.rows or {}
    local n = #rows
    if n == 0 then return "Orbit Companion needs a setup step." end
    if n == 1 then return "Orbit Companion needs 1 setup step: " .. tostring(rows[1]) .. "." end
    local list = {}
    for i, r in ipairs(rows) do list[i] = "• " .. tostring(r) end
    return "Orbit Companion needs " .. n .. " setup steps:\n" .. table.concat(list, "\n")
end

---------------------------------------------------------------------------------------------
-- Settings PIN (companion 0.4.4+): /status carries pin_locked. Locked: the Orbit menu shows
-- only "Enter the PIN" and asks the companion for its keypad (SHOW_PIN). No answer from the
-- companion (not installed, not running, older version): the menu stays usable, so nobody is
-- ever locked out by the patch.
---------------------------------------------------------------------------------------------

local MenuLock = {}

-- st: the decoded /status table, or nil when the companion didn't answer.
function MenuLock.locked(st)
    return type(st) == "table" and st.pin_locked == true
end

---------------------------------------------------------------------------------------------
-- One update covers everything: a newer patch file on disk (the companion installed it after
-- its own update, or our updater wrote it) gets loaded by a restart that never interrupts
-- reading: at once with no book open, else right after the book closes or the device sleeps.
-- One try per version: a file that still doesn't load after its restart is left to Setup.
---------------------------------------------------------------------------------------------

local RestartPlan = {}

-- The PATCH_VERSION a file's head declares (it sits near the top), or nil.
function RestartPlan.fileVersion(head)
    return (head or ""):match('\nlocal PATCH_VERSION = "([^"\n]+)"')
end

-- want: the file's version; running: PATCH_VERSION; tried: the version a restart was already
-- made for (S.restart_tried); in_book; event: "check" (start, resume, after an update),
-- "close" (a book just closed) or "sleep" (screen off).
-- Returns "none" | "done" (already running it) | "restart" | "wait" | "gave_up".
function RestartPlan.decide(want, running, tried, in_book, event)
    if not want then return "none" end
    if Update.compare(want, running) ~= 1 then return tried and "done" or "none" end
    if tried and Update.compare(tried, want) == 0 then return "gave_up" end
    if not in_book or event == "sleep" or event == "close" then return "restart" end
    return "wait"
end

-- The one status line after a restart made for an update.
function RestartPlan.doneText(version)
    return string.format("Updated to v%s (KOReader restarted)", tostring(version))
end

---------------------------------------------------------------------------------------------
-- Lists by series and by author (v0.6.0, android/docs/DESIGN.md "Lists by series and by author").
-- BookOrbit's Series and Authors views are server-wide: its sections endpoint takes no list
-- (KoreaderCatalogSectionQueryDto whitelists q, page, offset, size, sort, filter). So the
-- patch reads a list's books once and groups them here, in the section shape the plugin draws
-- (bookorbit_list_data.lua:195-225: count, readingCount, finishedCount, memberStates,
-- authorNames, previewBooks, letter), with the server's semantics copied from
-- opds-book.service.ts: read buckets (:115-118, readStatusBucket :193-198), the series and
-- author filters (:711, :793-797), the name and "most books" orders (:211-231), the A-Z letter
-- (latinJumpBucketExpr :200-205) and buckets (first row of each letter, :865-877), series
-- members in series order with the first author of each (:965-1035, 40 states, 2 names,
-- 3 previews), author previews reading, then finished, then newest (:899-960) and an author's
-- series line (their series with the most books, :885-897). Pure (tested).
---------------------------------------------------------------------------------------------
local Group = { PAGE = 100, IDS_MAX = 200, MANIFEST_IDS_MAX = 500, PREVIEWS = 3, MEMBER_STATES = 40,
    AUTHOR_NAMES = 2, SECTION_SIZE = 60, STANDALONE = "orbit:standalone", SNAPSHOTS = 6 }

local READING_STATUS = { reading = true, rereading = true, on_hold = true }
local FINISHED_STATUS = { read = true, skimmed = true, abandoned = true }

function Group.bucket(status)
    if READING_STATUS[status] then return "reading" end
    if FINISHED_STATUS[status] then return "finished" end
    return "unread"
end

-- Latin-1 letters with accents, folded (UTF-8 pairs), as bookorbit_unaccent does for these.
local FOLD = {}
for from, to in pairs({ A = "ÀÁÂÃÄÅàáâãäå", C = "Çç", E = "ÈÉÊËèéêë", I = "ÌÍÎÏìíîï", N = "Ññ",
    O = "ÒÓÔÕÖØòóôõöø", U = "ÙÚÛÜùúûü", Y = "Ýýÿ" }) do
    for ch in to:gmatch("[\192-\223][\128-\191]") do FOLD[ch] = to:find(ch, 1, true) and from end
end
-- Lower case, accents folded, spaces trimmed: the key names compare and match by.
function Group.fold(s)
    s = tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("[\192-\223][\128-\191]", function(ch) return FOLD[ch] or ch end)
    return s:lower()
end

-- "A".."Z" for a name starting with a (folded) letter, else "#".
function Group.letter(name)
    local c = Group.fold(name):sub(1, 1)
    if c:match("^[a-z]$") then return c:upper() end
    return "#"
end

-- A book's series: its id, or (an older server sends no seriesId) its name. nil: no series.
function Group.seriesKey(book)
    if book.seriesId ~= nil then return "id:" .. tostring(book.seriesId) end
    local name = book.seriesName
    if type(name) == "string" and name:match("%S") then return "name:" .. Group.fold(name) end
    return nil
end

-- Series order: the index as a number, then as text, missing last; then title, then id.
function Group.bySeriesIndex(a, b)
    local ia, ib = tonumber(a.seriesIndex), tonumber(b.seriesIndex)
    if ia ~= ib then
        if ia == nil then return false end
        if ib == nil then return true end
        return ia < ib
    end
    local sa, sb = tostring(a.seriesIndex or ""), tostring(b.seriesIndex or "")
    if sa ~= sb then return sa < sb end
    local ta, tb = Group.fold(a.title), Group.fold(b.title)
    if ta ~= tb then return ta < tb end
    return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
end

local function counts(books)
    local reading, finished = 0, 0
    for _, b in ipairs(books) do
        local k = Group.bucket(b.readStatus)
        if k == "reading" then reading = reading + 1 elseif k == "finished" then finished = finished + 1 end
    end
    return reading, finished
end

local function firstN(list, n)
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i] end
    return out
end

-- Books grouped by key(book) (nil: left out), in first-seen order: { key, books }.
local function groupBy(books, key)
    local groups, by = {}, {}
    for _, b in ipairs(books or {}) do
        for _, k in ipairs(key(b)) do
            local g = by[k]
            if not g then g = { key = k, books = {} }; by[k] = g; table.insert(groups, g) end
            table.insert(g.books, b)
        end
    end
    return groups
end

-- One series row per series among the books (each book under its primary series only).
function Group.series(books)
    local out = {}
    for _, g in ipairs(groupBy(books, function(b) local k = Group.seriesKey(b); return k and { k } or {} end)) do
        local members = firstN(g.books, #g.books)
        table.sort(members, Group.bySeriesIndex)
        local first = members[1]
        local name = first.seriesName or ""
        for _, b in ipairs(members) do if type(b.seriesName) == "string" and b.seriesName ~= "" then name = b.seriesName break end end
        local reading, finished = counts(members)
        local states, names, seen = {}, {}, {}
        for i, b in ipairs(members) do
            if i <= Group.MEMBER_STATES then states[i] = Group.bucket(b.readStatus) end
            local who = b.authors and b.authors[1]
            if who and not seen[who] and #names < Group.AUTHOR_NAMES then seen[who] = true; table.insert(names, who) end
        end
        local sid = tonumber(first.seriesId)
        table.insert(out, {
            id = sid and ("series:" .. sid) or name, title = name, section = "series", seriesId = sid,
            count = #members, readingCount = reading, finishedCount = finished,
            memberStates = states, authorNames = names, previewBooks = firstN(members, Group.PREVIEWS),
            letter = Group.letter(name), orbitKey = g.key,
        })
    end
    return out
end

-- The time a preview orders by: reading by last read, finished by last read, others by added.
local function previewTier(b)
    local k = Group.bucket(b.readStatus)
    if k == "reading" then return 0, b.lastReadAt or "" end
    if k == "finished" then return 1, b.lastReadAt or "" end
    return 2, b.addedAt or ""
end

function Group.byPreview(a, b)
    local ta, ra = previewTier(a)
    local tb, rb = previewTier(b)
    if ta ~= tb then return ta < tb end
    if ra ~= rb then return ra > rb end
    return (tonumber(a.id) or 0) > (tonumber(b.id) or 0)
end

-- One author row per author among the books (a book counts for each of its authors).
function Group.authors(books)
    local out = {}
    local groups = groupBy(books, function(b)
        local keys, seen = {}, {}
        for _, a in ipairs(b.authors or {}) do
            if type(a) == "string" and a ~= "" and not seen[a] then seen[a] = true; table.insert(keys, a) end
        end
        return keys
    end)
    for _, g in ipairs(groups) do
        local reading, finished = counts(g.books)
        local previews = firstN(g.books, #g.books)
        table.sort(previews, Group.byPreview)
        -- Their series with the most books here; a tie goes to the name first A-Z.
        local top, top_n, top_fold
        for _, s in ipairs(groupBy(g.books, function(b) local k = Group.seriesKey(b); return k and { k } or {} end)) do
            local name = s.books[1].seriesName or ""
            local f = Group.fold(name)
            if not top or #s.books > top_n or (#s.books == top_n and f < top_fold) then top, top_n, top_fold = name, #s.books, f end
        end
        table.insert(out, {
            id = g.key, title = g.key, section = "authors", count = #g.books,
            readingCount = reading, finishedCount = finished, seriesName = top,
            previewBooks = firstN(previews, Group.PREVIEWS), letter = Group.letter(g.key), orbitKey = "author:" .. g.key,
        })
    end
    return out
end

-- The "Not in a series" row of an author's books by series: always last.
function Group.standalone(books)
    local alone = {}
    for _, b in ipairs(books or {}) do if Group.seriesKey(b) == nil then table.insert(alone, b) end end
    if #alone == 0 then return nil end
    local reading, finished = counts(alone)
    local states = {}
    for i, b in ipairs(alone) do if i <= Group.MEMBER_STATES then states[i] = Group.bucket(b.readStatus) end end
    return { id = Group.STANDALONE, title = "Not in a series", section = "series", count = #alone,
        readingCount = reading, finishedCount = finished, memberStates = states, authorNames = {},
        previewBooks = firstN(alone, Group.PREVIEWS), letter = "", orbitKey = Group.STANDALONE }
end

-- The server's Reading / Finished filters: a series under way (a book in progress, or some but
-- not all finished) or all finished; an author with a book in progress, or one finished.
function Group.keep(e, section, filter)
    local n, r, f = e.count or 0, e.readingCount or 0, e.finishedCount or 0
    if filter == "reading" then
        if section == "authors" then return r > 0 end
        return r > 0 or (f > 0 and f < n)
    elseif filter == "finished" then
        if section == "authors" then return f > 0 end
        return f == n
    end
    return true
end

-- Name A-Z (or Z-A), or most books first then name A-Z; ties by id.
function Group.sort(entries, sort)
    table.sort(entries, function(a, b)
        local fa, fb = Group.fold(a.title), Group.fold(b.title)
        if sort == "books" and a.count ~= b.count then return a.count > b.count end
        if fa ~= fb then
            if sort == "name_desc" then return fa > fb end
            return fa < fb
        end
        return tostring(a.id) < tostring(b.id)
    end)
    return entries
end

-- One page of rows, as the sections endpoint answers it. params: the plugin's section
-- request (q, sort, filter, size, offset or page; bookorbit_catalog_lists.lua:246-260).
-- A section of an author's books adds the "Not in a series" row last.
function Group.sectionBody(rows, section, params, extra_last)
    params = params or {}
    local sort = params.sort or "name"
    local q = params.q and Group.fold(params.q) or ""
    local list = {}
    for _, e in ipairs(rows) do
        if (q == "" or Group.fold(e.title):find(q, 1, true)) and Group.keep(e, section, params.filter) then
            table.insert(list, e)
        end
    end
    Group.sort(list, sort)
    local buckets
    if sort ~= "books" then
        buckets = {}
        local seen = {}
        for i, e in ipairs(list) do
            if not seen[e.letter] then seen[e.letter] = true; table.insert(buckets, { key = e.letter, index = i - 1 }) end
        end
    end
    if extra_last and q == "" and Group.keep(extra_last, "series", params.filter) then table.insert(list, extra_last) end
    local size = tonumber(params.size) or Group.SECTION_SIZE
    local offset = tonumber(params.offset) or ((tonumber(params.page) or 1) - 1) * size
    local items = {}
    for i = offset + 1, math.min(#list, offset + size) do table.insert(items, list[i]) end
    return {
        items = items, total = #list, size = size, sort = sort, filter = params.filter, buckets = buckets,
        page = math.floor(offset / size) + 1, offset = params.offset ~= nil and offset or nil,
        hasNext = offset + size < #list, hasPrevious = offset > 0, query = params.q,
    }
end

-- The books of one row: an author's, a series', or (STANDALONE) an author's outside a series.
function Group.select(books, author, key)
    local out = {}
    for _, b in ipairs(books or {}) do
        local by = author == nil
        if not by then for _, a in ipairs(b.authors or {}) do if a == author then by = true break end end end
        local sk = Group.seriesKey(b)
        local in_key = key == nil or (key == Group.STANDALONE and sk == nil) or (key ~= Group.STANDALONE and sk == key)
        if by and in_key then table.insert(out, b) end
    end
    return out
end

-- Which list a book list is: { section, id } from its params, or nil (All books, a search...).
function Group.listOf(params)
    params = params or {}
    if params.smartScopeId then return { section = "smart-scopes", id = tonumber(params.smartScopeId) } end
    if params.collectionId then return { section = "collections", id = tonumber(params.collectionId) } end
    if params.libraryId then return { section = "libraries", id = tonumber(params.libraryId) } end
    return nil
end

-- The request for every book of the list, page by page: its params with the list's filters.
local FETCH_DROP = { page = true, size = true, offset = true, sort = true, order = true, buckets = true, on_device_filter = true }
function Group.fetchParams(params, page)
    local q = {}
    for k, v in pairs(params or {}) do
        if not FETCH_DROP[k] and not tostring(k):match("^orbit") then q[k] = v end
    end
    q.sort, q.size, q.page = "title", Group.PAGE, page or 1
    return q
end

-- Book ids, ascending, joined for the ids parameter.
function Group.ids(books, max)
    local ids = {}
    for _, b in ipairs(books) do table.insert(ids, tonumber(b.id)) end
    table.sort(ids)
    if max and #ids > max then for i = #ids, max + 1, -1 do ids[i] = nil end end
    return table.concat(ids, ",")
end

-- The request for some of a list's books (a row tapped in the grouped view).
--   list: { section, id }; list_params: the list's own params (its filters); books: those books;
--   target: what the page is (seriesId/series, author, sort); marks: orbit* keys to carry.
-- A library or collection: the server ANDs libraryId / collectionId with the target
-- (opds-book.service.ts:378-395), with the list's filters. A smart scope: the server drops
-- every other filter when smartScopeId is set (:368-375), so the books go by id instead (ids
-- caps at 200, koreader-catalog-query.dto.ts:114); past that the patch serves them from the
-- books it holds (orbitLocal). flat: always by id (a flat book list, not the author page).
function Group.drill(list, list_params, books, target, marks, flat)
    local p = {}
    for k, v in pairs(target or {}) do p[k] = v end
    for k, v in pairs(marks or {}) do p[k] = v end
    if not flat and list.section ~= "smart-scopes" then
        for _, k in ipairs({ "libraryId", "collectionId", "readStatus", "format", "ids" }) do
            if list_params[k] ~= nil then p[k] = list_params[k] end
        end
        return p, "server"
    end
    if #books <= Group.IDS_MAX then
        p.ids = Group.ids(books)
        return p, "ids"
    end
    p.orbitLocal = "1"
    return p, "held"
end

-- A page of the held books (orbitLocal), as the books endpoint answers it.
local SORT_KEY = {
    title = function(b) return Group.fold(b.title) end,
    author = function(b) return Group.fold(b.authors and b.authors[1]) end,
    series = function(b) return Group.fold(b.seriesName) end,
    recently_added = function(b) return b.addedAt or "" end,
    recently_read = function(b) return b.lastReadAt or "" end,
}
local NATURAL = { recently_added = "desc", recently_read = "desc", recently_updated = "desc", published = "desc" }
function Group.booksBody(books, params)
    params = params or {}
    local list = {}
    for _, b in ipairs(books or {}) do
        local k = Group.bucket(b.readStatus)
        if params.readStatus == nil or k == params.readStatus then table.insert(list, b) end
    end
    local sort = SORT_KEY[params.sort] and params.sort or "series"
    local desc = (params.order or NATURAL[params.sort] or "asc") == "desc"
    table.sort(list, function(a, b)
        local ka, kb = SORT_KEY[sort](a), SORT_KEY[sort](b)
        if ka ~= kb then if desc then return ka > kb end return ka < kb end
        return Group.bySeriesIndex(a, b)
    end)
    local size = tonumber(params.size) or 20
    local offset = tonumber(params.offset) or ((tonumber(params.page) or 1) - 1) * size
    local items = {}
    for i = offset + 1, math.min(#list, offset + size) do table.insert(items, list[i]) end
    return { items = items, total = #list, size = size, page = math.floor(offset / size) + 1,
        offset = params.offset ~= nil and offset or nil, hasNext = offset + size < #list, hasPrevious = offset > 0 }
end

-- Lists read for the grouped views, by token: { list, params, title, books }. A few at a time
-- (the oldest goes); the token rides in the request params (orbitGroup), never to the server.
Group.held, Group.order, Group.next = {}, {}, 0
function Group.remember(snap)
    Group.next = Group.next + 1
    local token = "g" .. Group.next
    Group.held[token] = snap
    table.insert(Group.order, token)
    while #Group.order > Group.SNAPSHOTS do Group.held[table.remove(Group.order, 1)] = nil end
    return token
end

-- Request params never sent: the patch's own marks.
function Group.strip(params)
    if type(params) ~= "table" then return params end
    local has = false
    for k in pairs(params) do if tostring(k):match("^orbit") then has = true break end end
    if not has then return params end
    local out = {}
    for k, v in pairs(params) do if not tostring(k):match("^orbit") then out[k] = v end end
    return out
end

-- The books a request with orbitLocal means: the held list, narrowed by its marks.
function Group.localBooks(params)
    local snap = Group.held[params.orbitGroup or ""]
    if not snap then return nil end
    local key = params.orbitSeries
    return Group.select(snap.books, params.orbitAuthor, key ~= "" and key or nil)
end

if rawget(_G, "ORBIT_ANDROID_TEST") then
    return { Schedule = Schedule, Plan = Plan, Update = Update, WifiPlan = WifiPlan, HomePlan = HomePlan,
        disabledText = disabledText, Compat = Compat, Stats = Stats, Clicks = Clicks, SetupPrompt = SetupPrompt,
        MenuLock = MenuLock, RestartPlan = RestartPlan, Group = Group,
        PATCH_VERSION = PATCH_VERSION }
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
local Event = require("ui/event")
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
    -- Shared with the companion, which stores them (android/docs/INTERFACE.md "Settings"); these are
    -- the patch's cached copy, refreshed from the companion's loopback status.
    wifi_mode = nil,              -- "always_on" | "off_reading" | "jit"; nil = default for this device
    wifi_idle_min = 2,            -- just in time: minutes of no network activity before Wi-Fi goes off
    home_button = "smart",        -- "smart" | "bookorbit"
    shared_settings_at = 0,       -- ms, when the shared settings last changed (either side)
    auto_update_patch = true,
    patch_update_prerelease = false,
    patch_update_checked_at = 0,  -- os.time() of the last successful check
    patch_update_status = nil,    -- { at, text }
    open_book_at_exit = nil,      -- path of the open book; set on ReaderReady, cleared on a close
    restart_book = nil,           -- the book open when a restart quit; reopened by the next start
    home_book = nil,              -- the book Home closed (fallback path); cleared by a user close or another book
    saved_pages_before_update = nil, -- the plugin's Push while reading value, kept while ours is on
    key_log = true,               -- log every key KOReader gets (clicker diagnosis; v0.4.2 default on)
}

local S = G_reader_settings:readSetting("orbit_android") or {}
for k, v in pairs(DEFAULTS) do
    if S[k] == nil then S[k] = v end
end

local function saveSettings()
    G_reader_settings:saveSetting("orbit_android", S)
end
saveSettings()

-- The book that was open when the previous KOReader process ended without a close (killed,
-- e.g. by a firmware after sleep). Read once per process, before this run's ReaderReady.
local killed_with_book = S.open_book_at_exit

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

local function callInt(env, obj, name, sig, ...)
    local r = env[0].CallIntMethod(env, obj, methodId(env, obj, name, sig), ...)
    check(env, name)
    return tonumber(r)
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

-- WifiManager.isWifiEnabled(): the radio, not the connection. nil if unknown.
-- KOReader's Android backend only knows "connected" (device.lua:335-341, isWifiOn = isConnected).
-- Wi-Fi radio on? true/false, nil if unknown. Not WifiManager.isWifiEnabled(): KOReader's
-- manifest has no ACCESS_WIFI_STATE (android-luajit-launcher app/src/main/AndroidManifest.xml:
-- INTERNET, ACCESS_NETWORK_STATE, ...), so that call throws SecurityException. Settings.Global
-- "wifi_on" (Settings.Global.WIFI_ON) needs no permission: 1 on, 2 on in airplane mode, 0 off,
-- 3 off by airplane mode.
function Jni.wifiEnabled()
    return withEnv("wifi_on", function(env, activity)
        local cr = callObject(env, activity, "getContentResolver", "()Landroid/content/ContentResolver;")
        if cr == nil then error("no ContentResolver", 0) end
        local cls = env[0].FindClass(env, "android/provider/Settings$Global")
        check(env, "FindClass Settings$Global")
        local mid = env[0].GetStaticMethodID(env, cls, "getInt", "(Landroid/content/ContentResolver;Ljava/lang/String;I)I")
        check(env, "Settings.Global.getInt")
        local key = env[0].NewStringUTF(env, "wifi_on")
        local v = tonumber(env[0].CallStaticIntMethod(env, cls, mid, cr, key, int32(-1)))
        check(env, "Settings.Global.getInt wifi_on")
        del(env, key)
        del(env, cls)
        del(env, cr)
        return Plan.wifiOnSetting(v)
    end)
end

-- PackageManager.getApplicationEnabledSetting(pkg): 0 default, 1 enabled, 2/3/4 disabled.
-- nil when the package isn't installed (it throws IllegalArgumentException).
function Jni.appEnabledSetting(pkg)
    return withEnv("getApplicationEnabledSetting " .. pkg, function(env, activity)
        local pm = callObject(env, activity, "getPackageManager", "()Landroid/content/pm/PackageManager;")
        if pm == nil then error("no PackageManager", 0) end
        local jp = env[0].NewStringUTF(env, pkg)
        local okc, v = pcall(callInt, env, pm, "getApplicationEnabledSetting", "(Ljava/lang/String;)I", jp)
        del(env, jp)
        del(env, pm)
        if not okc then return false end -- missing: false, so withEnv doesn't log it as a failure
        return v
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
-- An app's label ("Meebook Launcher"), also when it's disabled; false when missing.
function Jni.appLabel(pkg)
    return withEnv("appLabel " .. pkg, function(env, activity, jni)
        local pm = callObject(env, activity, "getPackageManager", "()Landroid/content/pm/PackageManager;")
        if pm == nil then error("no PackageManager", 0) end
        local jp = env[0].NewStringUTF(env, pkg)
        local label = false
        local oka, ai = pcall(callObject, env, pm, "getApplicationInfo", "(Ljava/lang/String;I)Landroid/content/pm/ApplicationInfo;", jp, 0x200)
        if oka and ai ~= nil then
            local okl, cs = pcall(callObject, env, pm, "getApplicationLabel", "(Landroid/content/pm/ApplicationInfo;)Ljava/lang/CharSequence;", ai)
            if okl and cs ~= nil then
                local okt, js = pcall(callObject, env, cs, "toString", "()Ljava/lang/String;")
                if okt and js ~= nil then label = jni:to_string(js); del(env, js) end
                del(env, cs)
            end
            del(env, ai)
        end
        del(env, jp)
        del(env, pm)
        return label
    end)
end

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
-- Orbit Companion and Tailscale (android/docs/INTERFACE.md)
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
    SHOW_LAUNCHER = Companion.PACKAGE .. ".action.SHOW_LAUNCHER",
    STATS = Companion.PACKAGE .. ".action.STATS",
    RELAUNCH = Companion.PACKAGE .. ".action.RELAUNCH",
    -- Companion 0.4.1+: the setup box's "Fix now" (activity) and "Later" (broadcast).
    SHOW_SETUP = Companion.PACKAGE .. ".action.SHOW_SETUP",
    SETUP_LATER = Companion.PACKAGE .. ".action.SETUP_LATER",
    -- Companion 0.4.4+: the Settings PIN keypad (activity).
    SHOW_PIN = Companion.PACKAGE .. ".action.SHOW_PIN",
}
-- Extra the companion puts on the intent that starts KOReader ("home").
Companion.EXTRA_COMMAND = Companion.PACKAGE .. ".extra.COMMAND"
-- With "home_smart": "other_app" when the companion knows Home came from outside KOReader.
Companion.EXTRA_FROM = Companion.PACKAGE .. ".extra.FROM"

local TAILSCALE = {
    action = "com.tailscale.ipn.CONNECT_VPN",
    package = "com.tailscale.ipn",
    class = "com.tailscale.ipn.IPNReceiver",
}

Companion.ACTION.SETTINGS = Companion.PACKAGE .. ".action.SETTINGS"

-- Vendor quirks, kept to this table (mirrors the companion's Vendor.kt): a vendor launcher that
-- "freezes" (disables) apps, and where it re-enables them. Matched by the launcher being installed.
-- Meebook/Haoqing: measured on a device. Boox/Onyx: unverified (Boox help center documents
-- Apps › App Management › Freeze Settings; the package name is from community reports).
local VENDORS = {
    { id = "haoqing", launcher = "com.haoqing.app.hqreader", hint = "Freeze management" },
    { id = "onyx", launcher = "com.onyx", hint = "Apps › App Management › Freeze Settings", unverified = true },
}

local vendor_cache
-- The installed vendor launcher's label and hint, or {} (generic Android).
local function vendorDisabler()
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

local installed_cache = { at = -1000, value = "missing", logged = nil }

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

-- For menus and the test: what's wrong with the companion, or nil.
function Companion.problem()
    local st = Companion.state()
    if st == "frozen" then return Companion.disabledText() end
    if st == "missing" then return _("Orbit Companion is not installed.") end
    return nil
end

local request_seq = 0

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
    if not Companion.installed() then return end
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
-- Settings shared with the companion (Wi-Fi mode, idle minutes, Home button). The companion
-- stores them; the patch reads them from its loopback status and sends changes made in its
-- own menu with a SETTINGS broadcast. Newest change wins (settings_at, ms).
---------------------------------------------------------------------------------------------

local Shared = {}
-- The /clicks channel's state (filled in below, "The /clicks channel").
local Channel = { up = false, service_on = false, buf = "" }

function Shared.defaultMode()
    return Companion.installed() and "jit" or "always_on"
end

function Shared.mode()
    if not Companion.installed() then return "always_on" end -- nothing can switch Wi-Fi
    return WifiPlan.validMode(S.wifi_mode) and S.wifi_mode or Shared.defaultMode()
end

-- Pull the companion's copy if it is newer. Cheap: loopback, 1 s timeout.
-- "Orbit Companion: 1 setup step needs you", or nil.
function Shared.setupNeededText()
    local n = Shared.setup_needed
    if not n or n < 1 or not Companion.installed() then return nil end
    return string.format(n == 1 and _("Orbit Companion: %d setup step needs you (open the companion)")
        or _("Orbit Companion: %d setup steps need you (open the companion)"), n)
end

function Shared.refresh(why)
    if not Companion.installed() then return false end
    local st = Companion.status(1)
    -- Clicker buttons: the companion's key map (an empty map turns ours off).
    if st then
        local m = Clicks.parse(st.keymap)
        local n = 0
        for _ in pairs(m) do n = n + 1 end
        if n ~= Clicks.count or why == "start" then log("clicker: key map from the companion,", n, "key(s) (" .. why .. ")") end
        Clicks.map, Clicks.count = m, n
        -- One path: the channel (when the companion has it) lets its service drive KOReader.
        if st.clicker_service ~= nil then Shared.clicker_service = st.clicker_service == true end
        if n > 0 and not Channel.up then pcall(Channel.connect, why) end
    end
    -- "Setup needs you": the count in the menu status; setup_prompt for the one-time box.
    Shared.setup_needed = st and tonumber(st.setup_needed) or nil
    Shared.setup_prompt = st and type(st.setup_prompt) == "table" and st.setup_prompt or nil
    -- The companion's "Home opens": koreader, launcher or app (nil: unknown, older companion).
    local so = st and type(st.settings) == "table" and st.settings.home_opens or nil
    Shared.home_opens = (so == "koreader" or so == "launcher" or so == "app") and so or nil
    -- Sync while reading set in the companion: apply and save it here, then tell the companion.
    local req_id, req_at = Schedule.request(st and st.reading_schedule_request, S.reading_schedule_request_at)
    if req_id then
        local was = S.reading_schedule
        S.reading_schedule, S.reading_schedule_request_at = req_id, req_at
        saveSettings()
        log("setting reading_schedule =", req_id, "(from the companion, was " .. tostring(was) .. ", " .. why .. ")")
        if Shared.onSchedule then pcall(Shared.onSchedule, req_id) end
        Shared.push("reading schedule from the companion")
    end
    -- Settings PIN: locked only on the companion's word; no answer = unlocked (MenuLock).
    Shared.pin_locked = MenuLock.locked(st)
    -- The companion's lockdown reading (true/false; nil: unknown or no companion).
    if st then Shared.vpn_lockdown = type(st.vpn_lockdown) == "boolean" and st.vpn_lockdown or nil end
    local remote = st and type(st.settings) == "table" and st.settings or nil
    if not remote then return false end
    local at = tonumber(remote.settings_at) or 0
    if at > (S.shared_settings_at or 0) then
        local changed = {}
        if WifiPlan.validMode(remote.wifi_mode) and remote.wifi_mode ~= S.wifi_mode then
            S.wifi_mode = remote.wifi_mode; table.insert(changed, "wifi_mode=" .. remote.wifi_mode)
        end
        local idle = tonumber(remote.wifi_idle_min)
        if idle and idle ~= S.wifi_idle_min then S.wifi_idle_min = idle; table.insert(changed, "wifi_idle_min=" .. idle) end
        if (remote.home_button == "smart" or remote.home_button == "bookorbit") and remote.home_button ~= S.home_button then
            S.home_button = remote.home_button; table.insert(changed, "home_button=" .. remote.home_button)
        end
        S.shared_settings_at = at
        saveSettings()
        log("settings from companion (" .. why .. "):", #changed > 0 and table.concat(changed, " ") or "no change")
        return #changed > 0
    elseif at < (S.shared_settings_at or 0) then
        Shared.push("companion older (" .. why .. ")")
    end
    return false
end

function Shared.push(why)
    if not Companion.installed() then return end
    Companion.send(Companion.ACTION.SETTINGS, {
        reason = why,
        wifi_mode = S.wifi_mode or Shared.defaultMode(),
        wifi_idle_min = tostring(S.wifi_idle_min or 2),
        home_button = S.home_button or "smart",
        settings_at = string.format("%.0f", S.shared_settings_at or 0),
        -- The patch owns Sync while reading; the companion shows it (and the request it applied).
        reading_schedule = S.reading_schedule or "off",
        reading_schedule_applied_at = string.format("%.0f", S.reading_schedule_request_at or 0),
    })
end

function Shared.set(key, value)
    S[key] = value
    S.shared_settings_at = os.time() * 1000
    saveSettings()
    log("setting", key, "=", tostring(value), "(sent to the companion)")
    Shared.push("patch menu")
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

local compat_seen = setmetatable({}, { __mode = "k" })
local compat_logged = {}
local Grouping -- lists by series and by author; defined with the catalog hooks below

-- The plugin's version (main.lua:54/95: BookOrbit.PLUGIN_VERSION; _meta.lua has none).
local function pluginVersion(p)
    local okv, v = pcall(function() return p.PLUGIN_VERSION end)
    return (okv and type(v) == "string") and v or "unknown"
end

-- Unavailable features for this plugin instance, logged once per feature. Only a full pass is
-- cached (per live instance): a check that finds something missing, e.g. one made before the
-- plugin finished init, is made again next time.
local function compatOf(p)
    if not p then return {} end
    local m = compat_seen[p]
    if m then return m end
    m = Compat.check(p)
    if next(m) == nil then compat_seen[p] = m end
    for id, missing in pairs(m) do
        if not compat_logged[id] then
            compat_logged[id] = true
            log("compat:", id, "unavailable (plugin " .. pluginVersion(p) .. "): missing",
                table.concat(missing, ", "), "->", Compat.fallback(id))
        end
    end
    return m
end

-- Can the patch use this plugin feature?
local function can(p, id)
    return p ~= nil and compatOf(p)[id] == nil
end

local function bookorbit(ui)
    ui = liveUI() or ui
    local p = ui and ui.bookorbit
    if not p then
        local ok, inst = pcall(PluginLoader.getPluginInstance, PluginLoader, "bookorbit")
        p = ok and inst or nil
    end
    -- Without isLoggedIn/settings nothing else is safe: behave as without the plugin.
    if p and not can(p, "core") then return nil end
    return p
end

-- Status lines for the menu and Test sync path; {} when the plugin is fully supported.
local function compatLines(p)
    if not p then return {} end
    return Compat.lines(compatOf(p), pluginVersion(p))
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
-- Runs on the UI thread, so each probe is capped (block and total) at `timeout` <= 1.5 s,
-- with the UI loop running between probes: well under Android's 5 s input timeout. Name
-- lookup isn't covered by socket timeouts; the server is usually a Tailscale address or name
-- that Tailscale's resolver answers locally.
local function probeServer(url, timeout)
    local http = require("socket.http")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local ltn12 = require("ltn12")
    timeout = math.min(1.5, timeout)
    socketutil:set_timeout(timeout, timeout)
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

    -- Wi-Fi switched off (not just disconnected) and nobody to switch it on: say so now
    -- rather than wait out the cap.
    if Jni.wifiEnabled() == false and not (res.companion and S.wifi_via_companion) then
        local why
        if Companion.state() == "frozen" then
            why = Companion.disabledText()
        elseif res.companion then
            why = "Wi-Fi is off and \"Wi-Fi via Orbit Companion\" is off"
        else
            why = "Wi-Fi is off and Orbit Companion isn't installed to turn it on"
        end
        log("network up: Wi-Fi is off and can't be turned on; skipped:", why)
        if S.wake_tailscale then tailscaleConnect(opts.reason) end
        return finish(false, "wifi", why)
    end

    if res.companion and (S.wifi_via_companion or S.wake_tailscale) then
        Companion.netUp(opts.reason, { wake_lock_s = opts.wake_lock_s })
    elseif S.wake_tailscale then
        tailscaleConnect(opts.reason)
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
            local answered, code = probeServer(url, math.max(0.5, math.min(1.5, remaining)))
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

-- The plugin skips a non-interactive pull within 25 s of the last one
-- (API_CALL_DEBOUNCE_DELAY, bookorbit_progress_sync.lua:26, 384-387). Clear it only when the
-- last pull really was that recent; on a fresh start a pull that already ran stands.
function Sync.clearPullDebounce(p, reason)
    local okc, cleared = pcall(function()
        local last = p.pull_timestamp
        if type(last) ~= "number" or last == 0 then return false end
        if reason == "start" then return false end
        local now = UIManager:getElapsedTimeSinceBoot()
        local window = time.s(25)
        if now - last <= window then p.pull_timestamp = 0; return true end
        return false
    end)
    if okc and cleared then log("pull: cleared the plugin's 25 s debounce for this pull (" .. reason .. ")") end
end

function Sync.waitOutbox(p, cap, cb)
    if not can(p, "outbox") then
        -- Can't see the plugin's outbox: leave it to the plugin's own sync.
        return UIManager:nextTick(function() cb(true, "left to the plugin (compat)", 0) end)
    end
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
-- Wi-Fi modes: when to ask the companion for Wi-Fi on or off (WifiPlan above decides).
-- Every decision is logged with its reason and the mode, so a battery day can be audited:
--   adb logcat | grep -E "OrbitAndroid: wifi|OrbitCompanion: wifi"
---------------------------------------------------------------------------------------------

local Wifi = { plan = nil, inflight_http = 0, ticking = false, tx = nil }
local TICK_S = 15

function Wifi.state()
    if not Wifi.plan then
        Wifi.plan = WifiPlan.new(Shared.mode(), S.wifi_idle_min, now_s())
        log("wifi: mode", Wifi.plan.mode, "idle", S.wifi_idle_min .. " min")
    end
    return Wifi.plan
end

-- Settings changed (menu or companion): keep the state, swap mode and idle time.
function Wifi.applySettings(why)
    local st = Wifi.state()
    local mode = Shared.mode()
    local idle = (tonumber(S.wifi_idle_min) or 2) * 60
    if st.mode ~= mode or st.idle_s ~= idle then
        log("wifi: mode", st.mode, "->", mode, "idle", math.floor(idle / 60) .. " min (" .. why .. ")")
        st.mode, st.idle_s = mode, idle
        st.last_activity = now_s()
    end
    Wifi.kick()
end

-- The radio state: Jni first (the radio), KOReader's "connected" as a fallback.
function Wifi.radioOn()
    local on = Jni.wifiEnabled()
    if on == nil then on = NetworkMgr:isConnected() end
    return on
end

-- tx_packets of wlan0 when the firmware lets apps read it (NetworkListener reads the same
-- counter for auto_disable_wifi, networklistener.lua:101-113, but only where KOReader knows the
-- interface name, which it doesn't on Android: networklistener.lua:184-185).
local function txPackets()
    local f = io.open("/sys/class/net/wlan0/statistics/tx_packets", "rb")
    if not f then return nil end
    local n = f:read("*number")
    f:close()
    return n
end

function Wifi.busy()
    if Wifi.inflight_http > 0 then return true, "download in progress" end
    local p = bookorbit()
    if p and can(p, "outbox") then
        local okb, busy = pcall(function()
            local c = p:getSyncCoordinator()
            if c:isBusy() or c:queuedCount() > 0 then return true end
            local d = p:getLifecycleOutbox():diagnostics()
            return ((d.count or 0) - (d.blocked or 0)) > 0
        end)
        if okb and busy then return true, "BookOrbit plugin syncing" end
    end
    return false
end

function Wifi.activity(what)
    local st = Wifi.state()
    WifiPlan.activity(st, now_s())
    if what then log("wifi: activity", what) end
    Wifi.kick()
end

function Wifi.acquire(name)
    local st = Wifi.state()
    local on = Wifi.radioOn()
    WifiPlan.acquire(st, name, on, now_s())
    log("wifi: hold for", name, "(Wi-Fi was", on == false and "off" or "on", ") mode", st.mode)
    return on
end

-- handled: the companion restores (sleep sync). Returns whether a restore to off is pending.
function Wifi.release(name, handled)
    local st = Wifi.state()
    WifiPlan.release(st, name, now_s(), handled)
    log("wifi: release", name, handled and "(companion restores)" or "", "mode", st.mode)
    Wifi.kick()
    if st.n == 0 and st.release_at then
        UIManager:scheduleIn(WifiPlan.GRACE + 0.1, function() Wifi.evaluate("after " .. name) end)
    end
    return st.restore_off and st.n == 0
end

-- Decide now; ask the companion when the answer is "off".
function Wifi.evaluate(why)
    local st = Wifi.state()
    if not Companion.installed() then return nil, "no companion" end
    local wifi_on = Wifi.radioOn()
    if wifi_on == false then
        if st.restore_off or st.release_at or st.force_off_once then WifiPlan.wifiOff(st) end
        return nil, "already off"
    end
    local tx = txPackets()
    if tx and Wifi.tx and tx - Wifi.tx > 10 then WifiPlan.activity(st, now_s()) end
    Wifi.tx = tx
    local busy, busy_why = Wifi.busy()
    local screen_off = Jni.isInteractive() == false
    local action, reason, force = WifiPlan.decide(st, { now = now_s(), wifi_on = wifi_on, busy = busy, screen_off = screen_off })
    if action == "off" then
        log("wifi: OFF decided:", reason, "| mode", st.mode, force and "| forced" or "| only if turned on automatically", "(" .. why .. ")")
        Wifi.off_decided_at = now_s()
        Companion.wifiOff(reason, not force)
        WifiPlan.wifiOff(st)
        -- If the companion keeps it (turned on by hand), wait a full idle period before asking again.
        st.last_activity = now_s()
    elseif busy and st.release_at and now_s() >= st.release_at then
        log("wifi: kept on while", busy_why, "| mode", st.mode)
    end
    return action, reason
end

-- A cheap loop that only runs while Wi-Fi is on or a restore is pending.
function Wifi.kick()
    if Wifi.ticking or not Companion.installed() then return end
    Wifi.ticking = true
    local function tick()
        local st = Wifi.state()
        local action, reason = Wifi.evaluate("timer")
        local pending = st.n > 0 or st.release_at ~= nil or st.force_off_once
        if not pending and (reason == "already off" or st.mode ~= "jit") then
            Wifi.ticking = false
            return
        end
        UIManager:scheduleIn((st.release_at and st.release_at > now_s()) and math.max(0.5, st.release_at - now_s() + 0.1) or TICK_S, tick)
    end
    UIManager:scheduleIn(0.5, tick)
end

-- Every HTTP(S) request KOReader makes counts as network activity, and an in-flight one
-- (a download) blocks Wi-Fi off. Wraps the module tables, so callers that look up
-- http.request at call time (all of KOReader's) are covered.
local function pack(...) return { n = select("#", ...), ... } end

local function wrapRequests(modname)
    local okm, mod = pcall(require, modname)
    if not okm or type(mod) ~= "table" or type(mod.request) ~= "function" or mod._orbit_wrapped then return end
    local orig = mod.request
    mod._orbit_wrapped = true
    mod.request = function(...)
        Wifi.inflight_http = Wifi.inflight_http + 1
        if Wifi.plan then WifiPlan.activity(Wifi.plan, now_s()) end
        local r = pack(pcall(orig, ...))
        Wifi.inflight_http = Wifi.inflight_http - 1
        if Wifi.plan then WifiPlan.activity(Wifi.plan, now_s()) end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, r.n)
    end
end

---------------------------------------------------------------------------------------------
-- Self-update from github.com/Fledgewing/Orbify releases (README "Updates").
-- Checks at most once a day on start/wake when the network is already up (never brings it up
-- for this), or from the menu. The new file is SHA-256-checked against the release's
-- SHA256SUMS, written next to this file and renamed over it; it runs from the next start.
---------------------------------------------------------------------------------------------

local Updater = { busy = false }
local RELEASES_API = "https://api.github.com/repos/Fledgewing/Orbify/releases"
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
                    ["User-Agent"] = "Orbify-patch/" .. PATCH_VERSION,
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

-- Returns ok, status text (or ok=false, nil, network error). Blocking: runs only in the
-- background process (Updater.check), never on KOReader's UI thread.
function Updater.run(why)
    local pre = S.patch_update_prerelease == true
    log("update: check started (" .. why .. "), installed", PATCH_VERSION, "pre-releases", tostring(pre))
    -- The list holds firmware releases too: a longer page still reaches the newest Android one.
    local url = pre and (RELEASES_API .. "?per_page=30") or (RELEASES_API .. "/latest")
    local body, err = Update.withRetry(function() return httpGet(url, Update.TRY_TIMEOUT_S, 20) end,
        function(s) require("socket").sleep(s) end,
        function(i, e, wait) log("update: try", i, "failed:", tostring(e), "- retrying in", wait, "s") end)
    if not body then
        -- The parent words it (Update.errorText) from the state after the check: no JNI here.
        log("update: check failed:", tostring(err))
        return false, nil, err
    end
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
    return true, "updated to " .. stamped .. "; KOReader restarts to use it (after the book, if one is open)"
end

---------------------------------------------------------------------------------------------
-- Network I/O off KOReader's UI thread. fn runs in a forked process: koreader-base
-- ffi/util.lua:350 runInSubProcess (with a pipe), the way KOReader's own Trapper runs
-- network lookups. The UI thread only polls it (isSubProcessDone :462, never waiting) and
-- reads the short result once the process has exited (readAllFromFD :558, EOF at once).
-- On timeout it is killed (terminateSubProcess :476). The child must not use JNI or the UI.
---------------------------------------------------------------------------------------------

local Background = { POLL_S = 0.25 }

-- cb(result string) or cb(nil, error).
function Background.run(name, fn, timeout_s, cb)
    local okf, ffiutil = pcall(require, "ffi/util")
    if not okf or type(ffiutil) ~= "table" or type(ffiutil.runInSubProcess) ~= "function" then
        log(name .. ": no background process available; not run (never on the UI thread)")
        return cb(nil, "no background process")
    end
    local pid, fd = ffiutil.runInSubProcess(function(_pid, wfd)
        local okc, out = pcall(fn)
        ffiutil.writeToFD(wfd, okc and tostring(out or "") or Update.encode(false, "check failed: " .. tostring(out)), true)
    end, true)
    if not pid then
        log(name .. ": background process failed:", tostring(fd))
        return cb(nil, tostring(fd))
    end
    local t0 = now_s()
    local function poll()
        if ffiutil.isSubProcessDone(pid) then
            return cb(ffiutil.readAllFromFD(fd))
        end
        if now_s() - t0 > timeout_s then
            log(name .. ": no answer after", fmt(now_s() - t0) .. "; stopped")
            ffiutil.terminateSubProcess(pid)
            local function reap()
                if ffiutil.isSubProcessDone(pid) then pcall(ffiutil.readAllFromFD, fd) else UIManager:scheduleIn(1, reap) end
            end
            UIManager:scheduleIn(1, reap)
            return cb(nil, "timed out")
        end
        UIManager:scheduleIn(Background.POLL_S, poll)
    end
    UIManager:scheduleIn(Background.POLL_S, poll)
end

Updater.TIMEOUT_S = 210 -- the child's own timeouts add up to at most 3 x 20 + 3 + 10 + 60 + 60 s

function Updater.check(why, done)
    if Updater.busy then
        log("update: check already running; ignored (" .. why .. ")")
        return
    end
    Updater.busy = true
    local started = now_s()
    log("update: check started (" .. why .. ") in the background")
    Background.run("update", function() return Update.encode(Updater.run(why)) end, Updater.TIMEOUT_S, function(data, berr)
        Updater.busy = false
        local ok, kind, text
        if data then
            ok, kind, text = Update.decode(data)
        else
            ok, kind, text = false, "net", "network: " .. tostring(berr)
        end
        if kind == "net" then
            local went_down = (Wifi.off_decided_at ~= nil and Wifi.off_decided_at >= started - 1)
                or Wifi.radioOn() == false
            local raw = text
            text = Update.errorText(raw, {
                wifi_on = Wifi.radioOn(), connected = NetworkMgr:isConnected() and true or false,
                lockdown = Shared.vpn_lockdown, went_down = went_down })
            log("update: check failed:", raw, "->", text, "after", fmt(now_s() - started))
        end
        -- A success starts the 24 h wait; a failure the 1 h back-off (Update.autoGate).
        if ok then
            S.patch_update_checked_at = os.time()
            S.patch_update_failed_at = nil
        else
            S.patch_update_failed_at = os.time()
        end
        setUpdateStatus(text)
        -- One update covers everything: load the new file now or when reading allows.
        if ok and Updater.onInstalled and tostring(text):find("^updated to") then
            UIManager:scheduleIn(1, Updater.onInstalled)
        end
        if done then done(ok, text) end
    end)
end

-- Daily automatic check: only with the network up, never in a book or with Wi-Fi going off,
-- and inside its own Wi-Fi hold so just-in-time Wi-Fi off waits for it.
function Updater.maybeAuto(reason)
    local function gate()
        return Update.autoGate{
            enabled = S.auto_update_patch, now = os.time(),
            checked_at = S.patch_update_checked_at, failed_at = S.patch_update_failed_at,
            connected = NetworkMgr:isConnected(), in_book = inBook(),
            off_decided = Wifi.off_decided_at ~= nil and now_s() - Wifi.off_decided_at < 60,
        }
    end
    if Updater.busy or Updater.waiting then return end
    local ok, why = gate()
    -- In a book: try again on reaching the file browser or BookOrbit home (OrbitAndroid:init).
    Updater.deferred = (not ok and why:find("book is open", 1, true) ~= nil) or nil
    if not ok then
        if why ~= "auto-update is off" and why ~= "checked today" then log("update: daily check not now (" .. reason .. "):", why) end
        return
    end
    Updater.waiting = true
    local held_at = now_s()
    Wifi.acquire("update")
    -- After the plugin's own drain and pull, which share the connection.
    UIManager:scheduleIn(8, function()
        Updater.waiting = false
        local ok2, why2 = gate()
        if ok2 and Wifi.off_decided_at and Wifi.off_decided_at >= held_at then ok2, why2 = false, "Wi-Fi went off" end
        if not ok2 then
            log("update: daily check dropped (" .. reason .. "):", why2)
            return Wifi.release("update")
        end
        Updater.check("auto, " .. reason, function() Wifi.release("update") end)
    end)
end

---------------------------------------------------------------------------------------------
-- The patch's module: one per FileManager / ReaderUI, created like a plugin
---------------------------------------------------------------------------------------------

local state = {
    started = false,            -- first module of this process seen
    sas_done_at = -1000,        -- "Sync and sleep" finished (monotonic s)
    pending_home = nil,         -- "go home" waiting for the file browser
    suspended_at = nil,         -- last Suspend (monotonic s)
    paused_for = nil,           -- how long the last Suspend lasted, set on Resume
}

-- Battery stats batches (Stats above). One accumulator per KOReader process.
local stats_acc = Stats.new(now_s())

local function contentOfUI(ui)
    local doc = ui and ui.document
    if not doc then return "none" end
    return Stats.contentOf(doc.file, ui.view and ui.view.page_scroll, ui.paging ~= nil)
end

local function readerContent()
    return contentOfUI(require("apps/reader/readerui").instance)
end

-- Sends the batch so far. content/open default to the open book (or none).
function Stats.send(why, content, open)
    if not Companion.installed() then return end
    content = content or readerContent()
    if open == nil then open = content ~= "none" end
    local extras = Stats.take(stats_acc, now_s(), content, open,
        { reason = why, wifi_mode = Shared.mode(), reading_schedule = S.reading_schedule or "off" })
    if extras then Companion.send(Companion.ACTION.STATS, extras) end
end

-- Every INTERVAL while a book is open. A Lua timer only: it never wakes the device.
local function statsTick()
    local t = now_s()
    if Stats.isDue(stats_acc, t, readerContent() ~= "none") then Stats.send("interval") end
    local wait = stats_acc.at and math.max(5, stats_acc.at + Stats.INTERVAL - now_s()) or Stats.INTERVAL
    UIManager:scheduleIn(wait, statsTick)
end

-- Count every physical refresh: _repaint drains _refresh_stack through refresh_methods
-- (uimanager.lua:1388) and then replaces it (:1399), so the old table lists exactly what was
-- sent to the screen, after merging (:1200) and full-refresh promotion.
if UIManager._repaint then
    local stock_repaint = UIManager._repaint
    function UIManager:_repaint(...)
        local stack = self._refresh_stack
        local r = pack(stock_repaint(self, ...))
        if type(stack) == "table" and self._refresh_stack ~= stack then
            for i = 1, #stack do Stats.refresh(stats_acc, stack[i].mode) end
        end
        return unpack(r, 1, r.n)
    end
end

-- Clicker actions inside KOReader (android/docs/BTKEYS-DESIGN.md "Actions"): exact page turns
-- (ReaderPaging/ReaderRolling:onGotoViewRel, readerpaging.lua:575, readerrolling.lua:900),
-- Back (ReaderBack:onBack, readerback.lua:117), frontlight (DeviceListener:onToggleFrontlight,
-- devicelistener.lua:175), and the patch's own Home and Sync and sleep.
function Clicks.run(action, code)
    local ReaderUI = require("apps/reader/readerui")
    local ui = ReaderUI.instance or liveUI()
    log("clicker: key", code, "->", action)
    if action == "next" or action == "prev" then
        if ReaderUI.instance then ReaderUI.instance:handleEvent(Event:new("GotoViewRel", action == "next" and 1 or -1)) end
    elseif action == "back" then
        UIManager:sendEvent(Event:new("Back"))
    elseif action == "light" then
        if ui then ui:handleEvent(Event:new("ToggleFrontlight")) end
    elseif action == "home" then
        if state.module then state.module:onOrbitGoHome() end
    elseif action == "sync_sleep" then
        if state.module then state.module:onOrbitSyncAndSleep() end
    end
end

local click_state = {}

local function clickSchedule(code, st, acts)
    if st.task then UIManager:unschedule(st.task); st.task = nil end
    local due = Clicks.nextDue(st, acts)
    if not due then return end
    st.task = function()
        st.task = nil
        local kind = Clicks.tick(st, now_s(), acts)
        if kind then Clicks.run(acts[kind], code) end
        clickSchedule(code, st, acts)
    end
    UIManager:scheduleIn(math.max(0.01, due - now_s()), st.task)
end

-- A mapped key: handled here and dropped (KEY_PRESS 1, KEY_RELEASE 0, KEY_REPEAT 2,
-- input.lua:23-25). Returns true when it was ours.
function Clicks.onKey(ev)
    local acts = ev and Clicks.map[ev.code]
    if not acts then return false end
    local st = click_state[ev.code] or {}
    click_state[ev.code] = st
    local kind
    if ev.value == 1 then kind = Clicks.down(st, now_s(), acts)
    elseif ev.value == 0 then kind = Clicks.up(st, now_s(), acts) end
    if kind then Clicks.run(acts[kind], ev.code) end
    clickSchedule(ev.code, st, acts)
    return true
end

---------------------------------------------------------------------------------------------
-- The /clicks channel (companion 0.4.2+): a kept-open loopback connection the companion writes
-- one line per action to. Its fd is added to KOReader's own ALooper (the one
-- ffi/input_android.lua waitForEvent polls), so a click wakes KOReader at once and nothing
-- polls. waitForEvent is wrapped to read the socket after every wake-up.
---------------------------------------------------------------------------------------------

Channel.IDENT, Channel.EVENT_INPUT = 20306, 1 -- our looper ident (KOReader uses 1-3); ALOOPER_EVENT_INPUT

local function looper()
    if not has_android or type(android) ~= "table" or not android.app or not android.lib then return nil end
    pcall(ffi.cdef, [[
        int ALooper_addFd(ALooper* looper, int fd, int ident, int events, ALooper_callbackFunc callback, void* data);
        int ALooper_removeFd(ALooper* looper, int fd);
    ]])
    return android.app.looper
end

function Channel.close(why)
    if Channel.sock then
        local lp = looper()
        if lp and Channel.fd then pcall(function() android.lib.ALooper_removeFd(lp, Channel.fd) end) end
        pcall(function() Channel.sock:close() end)
    end
    if Channel.up then log("clicks: channel closed (" .. why .. "); KOReader's own key path is on") end
    Channel.sock, Channel.fd, Channel.up, Channel.service_on, Channel.buf = nil, nil, false, false, ""
end

function Channel.onLine(line)
    local kind, v = Clicks.parseLine(line)
    if kind == "service" then
        if v ~= Channel.service_on then
            log("clicks: companion's clicker service", v and "on: it handles mapped keys" or "off: KOReader's own key path is on")
        end
        Channel.service_on = v
    elseif kind == "click" and v then
        UIManager:nextTick(function()
            Clicks.run(v, "service")
            log("CLICK", v, "done")
        end)
        return true
    elseif kind == "click" then
        log("clicks: unknown action in", line)
    end
    return false
end

-- Read what arrived (never blocks). True if a click is to be done.
function Channel.drain()
    local sock = Channel.sock
    if not sock then return false end
    local got = false
    for _i = 1, 16 do
        local data, err, partial = sock:receive(4096)
        local chunk = data or partial
        if chunk and #chunk > 0 then Channel.buf = Channel.buf .. chunk end
        if err == "closed" then Channel.close("the companion went away") break end
        if not data then break end
    end
    while true do
        local line, rest = Channel.buf:match("^([^\n]*)\n(.*)$")
        if not line then break end
        Channel.buf = rest
        if Channel.onLine((line:gsub("\r$", ""))) then got = true end
    end
    return got
end

local wait_wrapped = false
local function wrapWait()
    if wait_wrapped then return true end
    local okm, mod = pcall(require, "ffi/input_android")
    if not okm or type(mod) ~= "table" or type(mod.waitForEvent) ~= "function" then return false end
    local stock_wait = mod.waitForEvent
    mod.waitForEvent = function(...)
        local ok, ev, extra = stock_wait(...)
        if Channel.sock then
            local okd, got = pcall(Channel.drain)
            -- Our fd woke the looper (input_android returns EINTR for it): hand control back so
            -- UIManager runs the click now instead of waiting out its deadline.
            if okd and got and not ok then return true, {} end
        end
        return ok, ev, extra
    end
    wait_wrapped = true
    return true
end

function Channel.connect(why)
    if Channel.up or not Companion.installed() then return Channel.up end
    local lp = looper()
    if not lp or not wrapWait() then return false end
    local oks, socket = pcall(require, "socket")
    if not oks or type(socket.tcp) ~= "function" then return false end
    local sock = socket.tcp()
    sock:settimeout(1)
    local ok, err = sock:connect("127.0.0.1", 47913)
    if not ok then
        sock:close()
        log("clicks: no channel (" .. why .. "):", err)
        return false
    end
    local fd = sock:getfd()
    local okA, rc = pcall(function() return android.lib.ALooper_addFd(lp, fd, Channel.IDENT, Channel.EVENT_INPUT, nil, nil) end)
    if not okA or rc ~= 1 then
        sock:close()
        log("clicks: can't watch the channel in KOReader's event loop; own key path only")
        return false
    end
    sock:send("GET /clicks?patch_version=" .. PATCH_VERSION .. " HTTP/1.0\r\n\r\n")
    sock:settimeout(0)
    Channel.sock, Channel.fd, Channel.up, Channel.buf = sock, fd, true, ""
    log("clicks: channel open (" .. why .. ")")
    return true
end

---------------------------------------------------------------------------------------------
-- KOReader's key path: Input:handleKeyBoardEv (input.lua:723), called for every EV_KEY at
-- :1814. On Android every key the activity gets becomes an EV_KEY with the Android keycode
-- (ffi/input_android.lua keyEventHandler:195-231), letters and gamepad buttons included;
-- media keys, power and (when KOReader ignores them) volume keys are handed back to Android
-- unconsumed and never reach Lua, so only the companion's service can map those.
-- Returning nothing drops the event, so a mapped key never also does KOReader's own thing.
-- Installed on the Input class and on the live Device.input: inhibitInput (input.lua:1859-1905,
-- used by ReaderUI:init and suspend) copies the handler onto the instance, which then shadows
-- the class.
---------------------------------------------------------------------------------------------

local key_wrappers = setmetatable({}, { __mode = "k" })

function Clicks.handleKey(self, ev, stock)
    local acts = ev and Clicks.map[ev.code]
    local result
    if acts and Clicks.ownPath(Channel.up, Channel.service_on) then
        local ok, mine = pcall(Clicks.onKey, ev)
        if ok and mine then result = "mapped (own path)" end
        if not ok then log("clicker: key handler error:", mine) end
    elseif acts then
        result = nil -- the companion's service has it; anything that still arrives is KOReader's
    end
    if S.key_log and ev and ev.code then
        local name = self and type(self.event_map) == "table" and self.event_map[ev.code] or "?"
        local what = result or (acts and "pass (service handles mapped keys)" or "pass")
        log("key", ev.code, name, ev.value == 1 and "down" or ev.value == 0 and "up" or "repeat", "->", what)
    end
    if result then return end
    return stock(self, ev)
end

local function wrapKey(stock)
    local w = function(self, ev) return Clicks.handleKey(self, ev, stock) end
    key_wrappers[w] = true
    return w
end

function Clicks.install(why)
    local okI, Input = pcall(require, "device/input")
    if okI and type(Input) == "table" and type(Input.handleKeyBoardEv) == "function" and not key_wrappers[Input.handleKeyBoardEv] then
        Input.handleKeyBoardEv = wrapKey(Input.handleKeyBoardEv)
        log("clicker: key hook on Input (" .. why .. ")")
    end
    local inst = type(Device) == "table" and rawget(Device, "input") or nil
    if type(inst) == "table" and inst ~= Input then
        for _i, field in ipairs({ "handleKeyBoardEv", "_key_ev_handler" }) do
            local own = rawget(inst, field)
            -- handleKeyBoardEv is the power-only handler while input is inhibited: leave it.
            local inhibited = field == "handleKeyBoardEv" and rawget(inst, "_key_ev_handler") ~= nil
            if type(own) == "function" and not key_wrappers[own] and not inhibited then
                inst[field] = wrapKey(own)
                log("clicker: key hook on Device.input." .. field .. " (" .. why .. ")")
            end
        end
    end
end
Clicks.install("load")

local OrbitAndroid = WidgetContainer:extend{
    name = "orbitandroid",
    fullname = "Orbit Android (user patch)",
    is_doc_only = false,
}

function OrbitAndroid:init()
    state.module = self
    Grouping.install("init")
    Clicks.install("init")
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then self.ui.menu:registerToMainMenu(self) end
    local in_reader = self.ui ~= nil and self.ui.document ~= nil
    self.schedule = Schedule.new(S.reading_schedule, now_s())
    if in_reader then self:hookPluginPagePush() end
    -- A Sync while reading change from the companion (Shared.refresh) restarts this counter.
    Updater.onInstalled = function() self:maybeRestart("check") end
    Shared.onSchedule = function(id)
        self.schedule = Schedule.new(id, now_s())
        if self.ui and self.ui.document then self:hookPluginPagePush() end
    end

    if not state.started then
        state.started = true
        log("start: KOReader started (treated as a wake)", in_reader and "in reader" or "in file browser")
        UIManager:scheduleIn(0.8, function()
            Shared.refresh("start")
            Shared.push("start") -- the companion shows the patch's Sync while reading
            Wifi.applySettings("start")
            self:maybeSetupPrompt("start")
        end)
        UIManager:scheduleIn(1, function()
            local handled = self:checkCommand("start")
            if S.restart_book ~= nil then
                if handled then S.restart_book = nil; saveSettings() else self:reopenAfterRestart("start") end
            end
            self:maybeRestart("check")
        end)
        UIManager:scheduleIn(1.5, function() self:wakeFlow("start") end)
        UIManager:scheduleIn(Stats.INTERVAL, statsTick)
    elseif state.pending_home and not in_reader then
        UIManager:scheduleIn(1, function() self:finishHome() end)
    end
    if state.started and not in_reader and Updater.deferred then
        UIManager:scheduleIn(2, function() Updater.maybeAuto("deferred from the book") end)
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
        { category = "none", event = "OrbitOpenApps", title = _("Orbit Companion: apps"), general = true, separator = true })
end

-- "Sync while reading" replaces the plugin's every-few-pages push while it is on.
-- The plugin's every-few-pages push is its user setting "Push while reading"
-- (settings.pages_before_update, bookorbit_settings_page.lua:259-260; read by _onPageUpdate,
-- main.lua:1322-1324; 0 = off). While our Sync while reading is on we set it to 0 and keep the
-- reader's value; when it goes off we put that value back (unless they changed it meanwhile).
function OrbitAndroid:hookPluginPagePush()
    local p = bookorbit(self.ui)
    if not p or type(p.settings) ~= "table" then return end
    local cur = p.settings.pages_before_update
    if S.reading_schedule ~= "off" then
        if S.saved_pages_before_update == nil and (cur or 0) > 0 then
            S.saved_pages_before_update = cur
            p.settings.pages_before_update = 0
            saveSettings()
            log("page push: plugin's Push while reading", cur, "-> off while Sync while reading is on")
        end
    elseif S.saved_pages_before_update ~= nil then
        if (cur or 0) == 0 then
            p.settings.pages_before_update = S.saved_pages_before_update
            log("page push: plugin's Push while reading restored to", S.saved_pages_before_update)
        end
        S.saved_pages_before_update = nil
        saveSettings()
    end
end

---------------------------------------------------------------------------------------------
-- Wake / start
---------------------------------------------------------------------------------------------

function OrbitAndroid:onResume()
    if not stats_acc.at then
        stats_acc.at = now_s()
        if readerContent() ~= "none" then Stats.send("resume") end
    end
    state.paused_for = state.suspended_at and (now_s() - state.suspended_at) or nil
    state.suspended_at = nil
    Wifi.state().foreground = true
    log("resume", state.paused_for and ("after " .. fmt(state.paused_for) .. " in the background") or "")
    Clicks.install("resume")
    UIManager:scheduleIn(0.3, function()
        Shared.refresh("resume")
        Wifi.applySettings("resume")
        self:checkCommand("resume")
        self:maybeRestart("check")
        -- After checkCommand: a Home command moves to BookOrbit home first (finishHome checks too).
        self:maybeSetupPrompt("resume")
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
    local lease = "wake"
    Wifi.acquire(lease)
    Net.up(p, { reason = reason, cap = 20, need_server = true }, function(ok, res)
        if not ok then
            Wifi.release(lease)
            self:showWakeBanner(res)
            return
        end
        if can(p, "outbox") then p:requestLifecycleOutboxDrain("orbit_" .. reason) end
        Updater.maybeAuto(reason)
        -- Hold Wi-Fi until the plugin's drain and pull are done, then restore.
        UIManager:scheduleIn(1, function()
            Sync.waitOutbox(p, 20, function() Wifi.release(lease) end)
        end)
        if inBook() and can(p, "wake_pull") then
            -- The plugin debounces pulls for 25 s (bookorbit_progress_sync.lua:26, 383-387).
            -- Clear it for this one pull; on a fresh start skip it if a pull already ran.
            Sync.clearPullDebounce(p, reason)
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
    local from = Jni.takeIntentExtra(Companion.EXTRA_FROM)
    log("command from companion:", cmd, "(" .. source .. ")", from and ("from " .. tostring(from)) or "")
    if cmd == "home" or cmd == "home_smart" then
        self:smartHome(source, from or nil, cmd == "home" and "bookorbit" or "smart")
        return true
    end
    if cmd == "restart" then
        self:restartForCompanion(source)
        return true
    end
    if cmd == "reopen_book" then
        self:reopenAfterRestart(source)
        return true
    end
    log("unknown command ignored:", cmd)
    return false
end

-- COMMAND=restart (android/docs/INTERFACE.md): the companion installed a newer patch file; a restart
-- loads it. KOReader's own restart (UIManager:restartKOReader, frontend/ui/uimanager.lua:1766,
-- quit(85)) relies on a launcher script that Android lacks (Device canRestart = no,
-- frontend/device/android/device.lua:86), so: save like a kill would leave it (the open book
-- stays open_book_at_exit, so the cold start reopens it), ask the companion to start KOReader
-- again (RELAUNCH), and quit (Android Device:exit finishes the activity, device.lua:492-497).
function OrbitAndroid:restartForCompanion(source)
    -- Once: the quit ends this process (a second request in the meantime is the same restart).
    if state.restarting_at and now_s() - state.restarting_at < 5 then return end
    state.restarting_at = now_s()
    log("restart: requested by the companion (" .. tostring(source) .. "); saving, then quitting so the new patch loads")
    local ui = liveUI()
    if ui and ui.document and ui.saveSettings then pcall(ui.saveSettings, ui) end
    -- The quit closes the reader (which clears open_book_at_exit): remember the book apart, so
    -- the next start reopens it where it was (v0.5.5).
    S.restart_book = ui and ui.document and ui.document.file or nil
    saveSettings()
    pcall(function() G_reader_settings:flush() end)
    Stats.send("restart", nil, false)
    Companion.send(Companion.ACTION.RELAUNCH, { reason = "restart" })
    UIManager:scheduleIn(0.5, function()
        if Device.canRestart and Device:canRestart() then UIManager:restartKOReader() else UIManager:quit() end
    end)
end

-- RestartPlan here: the version our own file on disk declares (PATCH_VERSION is near its top).
local function patchFileVersion()
    if not SELF_PATH then return nil end
    local f = io.open(SELF_PATH, "rb")
    if not f then return nil end
    local head = f:read(8192)
    f:close()
    return RestartPlan.fileVersion("\n" .. (head or ""))
end

-- A newer patch file waits on disk: restart now, or when reading allows (RestartPlan).
function OrbitAndroid:maybeRestart(event)
    if state.restarting_at and now_s() - state.restarting_at < 5 then return "restart" end
    local want = patchFileVersion()
    local act = RestartPlan.decide(want, PATCH_VERSION, S.restart_tried, inBook(), event)
    if act == "wait" then
        if state.restart_waiting ~= want then
            state.restart_waiting = want
            log("restart: v" .. tostring(want) .. " is installed; restarting after the book closes or the device sleeps")
        end
    elseif act == "done" then
        local text = RestartPlan.doneText(PATCH_VERSION)
        S.restart_tried = nil
        setUpdateStatus(text)
        UIManager:show(InfoMessage:new{ text = _(text), timeout = 3 })
    elseif act == "gave_up" then
        if state.restart_gave_up ~= want then
            state.restart_gave_up = want
            setUpdateStatus("v" .. tostring(want) .. " is installed but didn't load after a restart: restart KOReader by hand (Orbit Companion > Setup)")
        end
    elseif act == "restart" then
        S.restart_tried = want
        saveSettings()
        self:restartForCompanion("v" .. tostring(want) .. " installed (" .. event .. ")")
    end
    return act
end

-- The plugin's BookOrbit home is the top widget: its catalog widget (main.lua:1207-1230) is
-- topmost (the plugin's own test, main.lua:1384) and shows its dashboard context
-- (BookOrbitCatalog:dashboardMode, bookorbit_catalog.lua:1875-1877). Its other views
-- (book details, lists, sheets over it) don't count.
local function topWidget()
    local okt, top = pcall(function() return UIManager:getTopmostVisibleWidget() end)
    return okt and top or nil
end

-- What is really showing, by identity with the plugin's catalog widget (never its flag alone:
-- plugin.catalog_browser stays set while the file browser or a book covers it).
local function catalogOnTop(p)
    local cb = p and p.catalog_browser
    return cb ~= nil and topWidget() == cb
end

-- The topmost widget, named for the log: KOReader's own screens by identity, else its name,
-- title or (for a class instance) its class's name.
local function widgetName(w, p)
    if w == nil then return "nothing" end
    if p and w == p.catalog_browser then return "BookOrbit catalog" end
    local okr, RUI = pcall(require, "apps/reader/readerui")
    if okr and type(RUI) == "table" and w == RUI.instance then return "ReaderUI (book)" end
    local okf, FM = pcall(require, "apps/filemanager/filemanager")
    if okf and type(FM) == "table" and w == FM.instance then return "FileManager (file browser)" end
    local okn, n = pcall(function()
        local v = w.name or w.title
        if v == nil then
            local mt = getmetatable(w)
            local cls = mt and (rawget(mt, "__index") or mt)
            v = type(cls) == "table" and (rawget(cls, "name") or rawget(cls, "title")) or nil
        end
        return v
    end)
    if okn and n ~= nil and (type(n) == "string" or type(n) == "number") then return tostring(n) end
    return "unnamed widget"
end

-- Visible widgets, topmost first (uimanager.lua:858-866 skips invisible ones the same way).
local function visibleStack()
    local out = {}
    local okw, stack = pcall(function() return UIManager._window_stack end)
    if okw and type(stack) == "table" then
        for i = #stack, 1, -1 do
            local w = type(stack[i]) == "table" and stack[i].widget or nil
            if w ~= nil and not w.invisible then table.insert(out, w) end
        end
    else
        local top = topWidget()
        if top then out[1] = top end
    end
    return out
end

-- Which BookOrbit screen is showing (plugin 2.3.0), from the real window stack:
--   "main": the catalog (main.lua:1207-1229) is the topmost widget, in dashboard mode
--     (bookorbit_catalog.lua:1875-1877: current_context.kind == "dashboard").
--   "sub": BookOrbit, but not its main page: the catalog in another mode (books, detail, lists,
--     search, board, ... switched in place, bookorbit_catalog.lua:1350 showBookPage, :1288
--     showRecentSearches; detail_sheet/list_sheet live in that context, :2451-2462), or
--     widgets over the catalog: its dialogs (bookorbit_catalog.lua:1439, :1534, :1559, :1598,
--     :1792), the book sheet (bookorbit_book_sheet.lua:385, :410), settings
--     (bookorbit_settings_page.lua:952), menu pages and dialogs (bookorbit_dialog_ui.lua:91),
--     the main menu sheet (bookorbit_main_menu.lua:380 openMenuSheet).
--   nil: no catalog showing (none, or KOReader's file browser or a book over it).
-- Returns kind, the widgets over the catalog (topmost first), and a description for the log.
local function bookorbitScreen(p)
    local cb = p and p.catalog_browser
    if cb == nil then return nil, {}, "no BookOrbit view" end
    -- Without dashboardMode the main page can't be told apart: the pre-0.4.9 behaviour.
    if not Compat.callable(cb.dashboardMode) then return nil, {}, "BookOrbit catalog without dashboardMode" end
    local above, found = {}, false
    local okr, RUI = pcall(require, "apps/reader/readerui")
    local okf, FM = pcall(require, "apps/filemanager/filemanager")
    for _, w in ipairs(visibleStack()) do
        if w == cb then found = true break end
        if (okr and type(RUI) == "table" and w == RUI.instance) or (okf and type(FM) == "table" and w == FM.instance) then
            return nil, {}, "BookOrbit covered by " .. widgetName(w, p)
        end
        table.insert(above, w)
    end
    if not found then return nil, {}, "BookOrbit view not in the window stack" end
    local okk, kind = pcall(function() return cb.current_context and cb.current_context.kind end)
    kind = okk and kind or nil
    local dash = Compat.callable(cb.dashboardMode) and select(2, pcall(function() return cb:dashboardMode() end)) == true
    if #above == 0 and dash then return "main", above, "BookOrbit main page" end
    local names = {}
    for _, w in ipairs(above) do table.insert(names, widgetName(w, p)) end
    local desc = "BookOrbit " .. tostring(kind or "?") .. " view"
    if #names > 0 then desc = desc .. " under " .. table.concat(names, ", ") end
    return "sub", above, desc
end

-- The catalog's page past the first, with nothing over it: page, how to go to page 1, what.
-- nil on page 1, with something over the catalog, or a plugin without the paging hooks.
local function catalogPage(cb)
    if cb == nil then return nil end
    local missing = Compat.missingOn(cb, Compat.PAGING)
    if #missing > 0 then
        if not compat_logged.paging then
            compat_logged.paging = true
            log("compat: paging unavailable: missing " .. table.concat(missing, ", ") .. " -> Home leaves any page")
        end
        return nil
    end
    local okp, page, go, what = pcall(function()
        if cb:dashboardMode() then
            local n = tonumber(cb:boardPage())
            return n, function() cb:boardFlip(1 - n) end, "dashboard"
        end
        if cb:listMode() then
            local pg = cb:listPaging()
            return tonumber(type(pg) == "table" and pg.page), function() cb:listGoPage(1) end, "list"
        end
    end)
    if not okp then log("home: paging check failed:", tostring(page)); return nil end
    if page and page > 1 then return page, go, what end
    return nil
end

local function onDashboard(p)
    local cb = p and p.catalog_browser
    if cb == nil then return false end
    if topWidget() ~= cb then return false end
    if not Compat.callable(cb.dashboardMode) then
        if not compat_logged.catalog then
            compat_logged.catalog = true
            log("compat: catalog unavailable (plugin " .. pluginVersion(p) .. "): missing dashboardMode -> Home on BookOrbit home goes back to the book")
        end
        return false
    end
    if not Compat.callable(cb.dashboardMode) then return false end
    local okd, dash = pcall(function() return cb:dashboardMode() end)
    return okd and dash == true
end

-- Home (android/docs/INTERFACE.md "go home"): HomePlan decides. mode: "smart" (home_smart) or
-- "bookorbit" (home).
function OrbitAndroid:smartHome(source, from_extra, mode)
    mode = mode or "smart"
    local ui = liveUI()
    local in_reader = ui ~= nil and ui.document ~= nil
    local p = bookorbit(ui)
    local menu_open = in_reader and ui.menu ~= nil and ui.menu.menu_container ~= nil
    local view_open = p ~= nil and p.catalog_browser ~= nil
    local screen, over, screen_desc = bookorbitScreen(p)
    local on_dash = screen == "main" or (screen == nil and onDashboard(p))
    local page, first_page, page_what
    if screen == "main" or (screen == "sub" and #over == 0) then
        page, first_page, page_what = catalogPage(p.catalog_browser)
    end
    -- Reopen only the current book: one Home closed, or one KOReader was killed with (first
    -- command of this process). Never history.
    local last = nil
    if not in_reader then
        last = S.home_book or (source == "start" and killed_with_book) or nil
    end
    local reopen = false
    if type(last) == "string" then
        local okl, lfs = pcall(require, "libs/libkoreader-lfs")
        reopen = okl and lfs.attributes(last, "mode") == "file"
        if not reopen and last == S.home_book then S.home_book = nil; saveSettings() end
    end
    if source == "start" then killed_with_book = nil end
    local paused = source == "start" and nil or state.paused_for
    local from_other = HomePlan.cameFromOtherApp(from_extra, paused)
    local action = HomePlan.decide{
        mode = mode, in_reader = in_reader, covered = menu_open or view_open, on_dashboard = on_dash,
        bookorbit_sub = screen == "sub", page_above_1 = page ~= nil,
        from_other = from_other, reopen = reopen,
    }
    log("home (" .. mode .. "):", action, "| in reader", tostring(in_reader), "menu", tostring(menu_open), "BookOrbit view",
        tostring(view_open), "dashboard on top", tostring(on_dash), "(top: " .. widgetName(topWidget(), p) .. ")",
        "from other app", tostring(from_other),
        "(paused", paused and fmt(paused) or "-", ")", "reopen current book", reopen and tostring(last) or "no")
    log("home: screen:", screen_desc)
    if action == "first_page" then
        log("home: BookOrbit " .. page_what .. " page " .. page .. " -> page 1")
        local okg, err = pcall(first_page)
        if not okg then log("home: going to page 1 failed:", tostring(err)) end
        return true
    end
    if action == "bookorbit_main" then return self:bookorbitMain(p, over, screen_desc) end
    if action == "companion" then return self:openCompanionHome() end
    if action == "dashboard" then return self:onOrbitGoHome() end
    -- Back to the book: close what covers it, or open the last one.
    if menu_open then pcall(function() ui.menu:onCloseReaderMenu() end) end
    if view_open then
        -- The plugin's own close (close_callback, main.lua:1225-1228; used by the catalog itself,
        -- bookorbit_catalog_download.lua:359-362) also clears plugin.catalog_browser, without
        -- which openCatalogBrowser (main.lua:1207) never opens it again.
        local cb = p.catalog_browser
        local okc, err = pcall(function()
            if cb.close_callback then cb.close_callback() else UIManager:close(cb); p.catalog_browser = nil end
        end)
        log("home (smart): closed the BookOrbit view", okc and "" or tostring(err))
    end
    if not in_reader then
        log("home (smart): reopening the current book", tostring(last))
        UIManager:nextTick(function()
            require("apps/reader/readerui"):showReader(last)
        end)
    end
    return true
end

-- BookOrbit home. With a book open, the plugin's dashboard opens on top of the reader without
-- closing it (onBookOrbitOpenDashboard, main.lua:1381-1389 -> browseCatalog, main.lua:1235-1241
-- -> openCatalogBrowser, main.lua:1206-1230: UIManager:show of its catalog widget; its own menu
-- does the same from a book, bookorbit_main_menu.lua:307). Fallback (no plugin, signed out):
-- close the book (the reader saves it; the plugin syncs it as on any close, main.lua:1292-1312)
-- and remember it as the current book (home_book), so Home elsewhere goes back to it.
-- The plugin has some BookOrbitOpenDashboard handler. Advisory: anything there counts (a
-- KOReader HandlerSandbox or a future wrapper); only a plugin without it is "missing".
local function hasHandler(p, event)
    if p == nil then return false end
    local okv, v = pcall(function() return p["on" .. event] end)
    return okv and v ~= nil
end

-- Send a plugin event the way KOReader's dispatcher does (the plugin's public actions, e.g.
-- bookorbit_open_dashboard -> BookOrbitOpenDashboard, main.lua:987-988): through the live UI,
-- which passes it to its plugin modules. Without a UI that takes it, call the handler.
local function pluginEvent(host, p, event, ...)
    if not can(p, PLUGIN_EVENT_FEATURE[event] or "core") then
        log("compat: the method check doesn't see on" .. event .. "; sending the event anyway")
    end
    host = host or liveUI()
    if host and host.handleEvent then
        local okh, err = pcall(host.handleEvent, host, Event:new(event, ...))
        if okh then return true end
        log("plugin event", event, "failed:", tostring(err))
    end
    local okv, h = pcall(function() return p and p["on" .. event] end)
    if okv and Compat.callable(h) then
        local okc, err = pcall(h, p, ...)
        if not okc then log("plugin handler on" .. event, "failed:", tostring(err)) end
        return okc
    end
    local okb = pcall(UIManager.broadcastEvent, UIManager, Event:new(event, ...))
    return okb
end

-- After opening BookOrbit home: say so if it isn't on top a second later.
local function checkDashboardOpened(p, why)
    UIManager:scheduleIn(1, function()
        local q = bookorbit(liveUI()) or p
        if catalogOnTop(q) then
            log("home: BookOrbit home is on top (" .. why .. ")")
        else
            log("home: BookOrbit home did NOT open (" .. why .. "); top:", widgetName(topWidget(), q))
        end
    end)
end

-- Close one widget the plugin's way: its close_callback (the catalog, main.lua:1225-1228),
-- else UIManager:close, which runs its onCloseWidget / on_close (MenuPage sheets).
local function closeWidget(w)
    local okc, err = pcall(function()
        if Compat.callable(w.close_callback) then w.close_callback() else UIManager:close(w) end
    end)
    if not okc then log("home: closing", widgetName(w), "failed:", tostring(err)) end
end

-- After a restart that quit with a book open: that book again, at its saved place (the reader
-- saved it before the quit; showReader opens at the last position). The book: the one this
-- patch remembered (restart_book), else KOReader's last file (a restart by an older patch,
-- which the companion follows with COMMAND=reopen_book). BookOrbit home opened by the start
-- (the plugin's open mode) is closed so the book is on top.
function OrbitAndroid:reopenAfterRestart(source)
    local file = S.restart_book
    if file ~= nil then S.restart_book = nil; saveSettings() end
    if type(file) ~= "string" then
        local okl, last = pcall(function() return G_reader_settings:readSetting("lastfile") end)
        file = okl and last or nil
    end
    local ui = liveUI()
    if type(file) ~= "string" then log("restart: no book to reopen (" .. source .. ")"); return end
    if ui and ui.document then log("restart: a book is already open; not reopening", file); return end
    local okl, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (okl and lfs.attributes(file, "mode") == "file") then log("restart: the book is gone:", file); return end
    local p = bookorbit(ui)
    if p and p.catalog_browser then closeWidget(p.catalog_browser) end
    log("restart: reopening the book at its place (" .. source .. "):", file)
    UIManager:nextTick(function()
        require("apps/reader/readerui"):showReader(file)
    end)
end

-- Home on a BookOrbit screen that isn't its main page: close what is over the catalog, then
-- the catalog's own Home (goDashboard, bookorbit_catalog.lua:530-537; also its hold-Return,
-- :2521-2525). If anything is left over it, or the plugin lacks goDashboard: close the catalog
-- and open BookOrbit home fresh (the plugin's event), so no half-closed stack is left.
function OrbitAndroid:bookorbitMain(p, over, desc)
    log("home: on", desc, "-> BookOrbit main page")
    for _, w in ipairs(over or {}) do
        log("home: closing", widgetName(w, p))
        closeWidget(w)
    end
    local cb = p.catalog_browser
    local screen = bookorbitScreen(p)
    if cb and screen ~= nil and topWidget() == cb and Compat.callable(cb.goDashboard) then
        if screen ~= "main" then
            local okg, err = pcall(function() cb:goDashboard() end)
            if okg then
                log("home: BookOrbit catalog back to its main page (goDashboard)")
                checkDashboardOpened(p, "back to main")
                return true
            end
            log("home: goDashboard failed:", tostring(err))
        else
            log("home: BookOrbit main page showing")
            return true
        end
    end
    log("home: reopening BookOrbit home fresh (top:", widgetName(topWidget(), p) .. ")")
    if p.catalog_browser then closeWidget(p.catalog_browser) end
    p.catalog_browser = nil
    pluginEvent(liveUI(), p, "BookOrbitOpenDashboard")
    checkDashboardOpened(p, "reopened")
    return true
end

function OrbitAndroid:onOrbitGoHome()
    local ui = liveUI()
    local p = bookorbit(ui)
    if ui and ui.document and hasHandler(p, "BookOrbitOpenDashboard") and p:isLoggedIn() then
        log("home: BookOrbit home over the open book")
        -- The plugin's public action bookorbit_open_dashboard (event BookOrbitOpenDashboard,
        -- main.lua:987-988).
        UIManager:nextTick(function()
            pluginEvent(ui, p, "BookOrbitOpenDashboard")
            checkDashboardOpened(p, "over the book")
        end)
        UIManager:scheduleIn(1, function() self:maybeSetupPrompt("home") end)
        return true
    end
    state.pending_home = os.time()
    if ui and ui.document then
        log("home: closing book, then BookOrbit home (it stays the current book)")
        state.closing_for_home = ui.document.file
        UIManager:nextTick(function() ui:onHome() end)
    else
        self:finishHome()
    end
    -- Also when finishHome stays put (BookOrbit home already open, no plugin): once off the book.
    UIManager:scheduleIn(2.5, function() self:maybeSetupPrompt("home") end)
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
    if p.catalog_browser and catalogOnTop(p) then
        log("home: BookOrbit home already showing")
        return
    end
    if not hasHandler(p, "BookOrbitOpenDashboard") then
        -- Advisory: the live UI may still route the event to a plugin module we can't see.
        log("home: this plugin instance shows no BookOrbit home handler; sending the event anyway")
    end
    if p.catalog_browser then
        -- Open but covered (the file browser on top): the plugin's open action does nothing while
        -- catalog_browser is set (main.lua:1381-1385), so close it the plugin's way, then reopen.
        log("home: BookOrbit home is open but not showing (top: " .. widgetName(topWidget(), p) .. "); bringing it to the top")
        local cb = p.catalog_browser
        local okc, err = pcall(function()
            if cb.close_callback then cb.close_callback() else UIManager:close(cb); p.catalog_browser = nil end
        end)
        if not okc then log("home: closing the covered BookOrbit view failed:", tostring(err)) end
        p.catalog_browser = nil
    end
    log("home: opening BookOrbit home")
    pluginEvent(liveUI() or self.ui, p, "BookOrbitOpenDashboard")
    checkDashboardOpened(p, "from the file browser")
    UIManager:scheduleIn(1, function() self:maybeSetupPrompt("home") end)
end

-- Where the reader is now, for the setup box: a book on screen, BookOrbit home, the file browser.
function OrbitAndroid:whereNow()
    local ui = liveUI() or self.ui
    local p = bookorbit(ui)
    if catalogOnTop(p) then return "bookorbit" end
    if ui and ui.document then return "reader" end
    return "browser"
end

-- The one-time "Setup needs you" box (SetupPrompt). where: given (the menu) or looked up.
function OrbitAndroid:maybeSetupPrompt(why, where)
    if not Companion.installed() then return end
    where = where or self:whereNow()
    local prompt = Shared.setup_prompt
    local show, reason = SetupPrompt.decide(prompt, where, S.setup_prompt_shown)
    if prompt then log("setup box (" .. why .. "):", show and ("showing in " .. where) or ("not now, " .. reason)) end
    if not show then return end
    S.setup_prompt_shown = prompt.key
    saveSettings()
    UIManager:show(ConfirmBox:new{
        text = _(SetupPrompt.text(prompt)),
        ok_text = _("Fix now"),
        cancel_text = _("Later"),
        ok_callback = function()
            local ok = Jni.startActivity{ action = Companion.ACTION.SHOW_SETUP, package = Companion.PACKAGE }
            if not ok then ok = Jni.startActivity{ action = Companion.ACTION.SHOW_STATUS, package = Companion.PACKAGE } end
            log("setup box: Fix now", ok and "opened the companion" or "FAILED to open the companion")
        end,
        cancel_callback = function()
            -- The companion's own Later: quiet until an update or a step stops working.
            Companion.send(Companion.ACTION.SETUP_LATER, {})
            log("setup box: Later")
        end,
    })
end

---------------------------------------------------------------------------------------------
-- Sleep (Suspend)
---------------------------------------------------------------------------------------------

function OrbitAndroid:onSuspend()
    -- Screen off or another app in front: KOReader isn't being read until Resume.
    if stats_acc.at then
        Stats.send("suspend", nil, false)
        stats_acc.at = nil
    end
    state.suspended_at = now_s()
    Wifi.state().foreground = false
    -- A patch update waiting for the book: the device sleeping is the moment (after any sleep sync).
    if patchFileVersion() and RestartPlan.decide(patchFileVersion(), PATCH_VERSION, S.restart_tried, true, "check") == "wait" then
        UIManager:scheduleIn(1.5, function()
            if Jni.isInteractive() ~= false then return end
            if state.sleep_syncing then
                state.restart_after_sync = true
            else
                self:maybeRestart("sleep")
            end
        end)
    end
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
    local held = false
    state.sleep_syncing = true
    local function done(ok, detail)
        state.sleep_syncing = false
        if state.restart_after_sync then
            state.restart_after_sync = false
            UIManager:scheduleIn(1, function() self:maybeRestart("sleep") end)
        end
        local seconds = now_s() - t0
        S.last_sleep_sync = { at = os.time(), ok = ok, seconds = seconds, reason = reason, detail = detail }
        saveSettings()
        local restore = held and Wifi.state().restore_off and Wifi.state().n == 1 and "off" or ""
        log(reason .. ": sleep sync", ok and "done" or "FAILED", "in", fmt(seconds), detail or "",
            restore == "off" and "| Wi-Fi was off before: companion restores off" or "")
        Companion.netDone(reason, ok, seconds, detail, restore)
        if held then Wifi.release("sleep", true) end
    end
    if not p or not p:isLoggedIn() then
        return done(false, "BookOrbit plugin missing or signed out")
    end
    Wifi.acquire("sleep")
    held = true
    Net.up(p, { reason = reason, cap = cap, need_server = true, wake_lock_s = cap + 5 }, function(ok, res)
        if not ok then return done(false, res.detail) end
        -- The plugin queued its snapshot in its own _onSuspend (main.lua:1340-1351) but drains
        -- only when already connected (main.lua:411-419). Now we are: drain and wait.
        if can(p, "outbox") then p:requestLifecycleOutboxDrain("orbit_" .. reason) end
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
        local restore = self.sas_held and Wifi.state().restore_off and Wifi.state().n == 1 and "off" or ""
        log("sync and sleep:", ok and "synced" or "FAILED", "in", fmt(seconds), detail or "",
            restore == "off" and "| Wi-Fi was off before: companion restores off" or "")
        Companion.netDone("sync_and_sleep", ok, seconds, detail, restore)
        if self.sas_held then
            self.sas_held = false
            Wifi.release("sync_and_sleep", true)
        end
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
    Wifi.acquire("sync_and_sleep")
    self.sas_held = true
    Net.up(p, { reason = "sync_and_sleep", cap = cap, need_server = true, wake_lock_s = cap + 5 }, function(ok, res)
        if cancelled then return finish(false, "cancelled") end
        if not ok then return finish(false, res.detail) end
        if inBook() and can(p, "sleep_snapshot") then
            -- Exactly what the plugin does on sleep: snapshot the open book into its
            -- durable outbox and drain it (main.lua:1340-1351).
            p:_onSuspend()
        elseif can(p, "outbox") then
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
    if self.ui and self.ui.document then Stats.send("close", contentOfUI(self.ui), false) end
    -- A patch update waiting for the book: once nothing is open (another book may be opening).
    if self.ui and self.ui.document and state.restart_waiting then
        UIManager:scheduleIn(1.5, function() OrbitAndroid.maybeRestart(self, "check") end)
    end
    -- A close (Back to file browser, Exit) runs this; a kill or suspend doesn't. A close Home
    -- started keeps the book as the current one (home_book); the user's own close clears it.
    if self.ui and self.ui.document then
        local file = self.ui.document.file
        if state.closing_for_home and state.closing_for_home == file then
            S.home_book = file
            log("home: book closed by Home; it stays the current book")
        else
            S.home_book = nil
        end
        state.closing_for_home = nil
        S.open_book_at_exit = nil
        saveSettings()
        pcall(function() G_reader_settings:flush() end)
    end
    if self.reading_task then
        UIManager:unschedule(self.reading_task)
        self.reading_task = nil
    end
    if self.ui and self.ui.document and self.book_tracked then
        self.book_tracked = false
        local st = Wifi.state()
        local restore = WifiPlan.bookClosed(st)
        log("wifi: book closed | mode", st.mode, restore == "on" and "| Wi-Fi was on before the book: turning it back on" or "")
        if restore == "on" and Companion.installed() then
            Companion.netUp("book_closed", { owner = "auto" })
        end
    end
end

function OrbitAndroid:onReaderReady()
    -- "Open book at exit": survives a kill (flushed now), cleared when the book is closed.
    -- Another book opening replaces Home's current book.
    local file = self.ui and self.ui.document and self.ui.document.file
    if file and (S.open_book_at_exit ~= file or S.home_book) then
        S.open_book_at_exit = file
        S.home_book = nil
        saveSettings()
        pcall(function() G_reader_settings:flush() end)
    end
    self.schedule = Schedule.new(S.reading_schedule, now_s())
    self:hookPluginPagePush()
    Stats.send("open", contentOfUI(self.ui), true)
    self:bookOpenFlow()
end

-- A book opened: remember Wi-Fi for off while reading; in the off-while-reading and just-in-time
-- modes, bring the network up for the plugin's open-time pull, then let Wi-Fi go off.
function OrbitAndroid:bookOpenFlow()
    if not Companion.installed() then return end
    local st = Wifi.state()
    local on = Wifi.radioOn()
    WifiPlan.bookOpened(st, on)
    self.book_tracked = true
    log("wifi: book opened (Wi-Fi", on == false and "off" or "on", ") mode", st.mode)
    if st.mode == "always_on" then return end
    local p = bookorbit(self.ui)
    if not p or not p:isLoggedIn() then return Wifi.kick() end
    Wifi.acquire("open")
    Net.up(p, { reason = "open", cap = 20, need_server = true }, function(ok)
        if not ok then return Wifi.release("open") end
        -- The plugin pulls on open by itself, or on NetworkConnected when it was offline
        -- (main.lua:1353-1361); its 25 s debounce keeps this from doubling up.
        p:requestProgressPull(false, false, "orbit_open")
        UIManager:scheduleIn(1, function()
            Sync.waitOutbox(p, 20, function() Wifi.release("open") end)
        end)
    end)
end

function OrbitAndroid:onNetworkConnected()
    Wifi.kick()
end

function OrbitAndroid:onPageUpdate(page)
    if self.ui and self.ui.document then Stats.page(stats_acc) end
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
    if not can(p, "reading_sync") then return end
    self.reading_running = true
    local t0 = now_s()
    Schedule.markSynced(self.schedule, t0)
    log("reading: sync due (" .. S.reading_schedule .. ")")
    Wifi.acquire("reading")
    Net.up(p, { reason = "reading", cap = 20, need_server = true }, function(ok, res)
        if not ok then
            Wifi.release("reading")
            self.reading_running = false
            log("reading: network not ready; try again at the next interval:", res.detail or "")
            return
        end
        p:requestLifecycleOutboxDrain("orbit_reading")
        local digest = p:getDocumentDigest()
        p:fetchRemoteProgress(digest, function(fetched)
            self.reading_running = false
            -- Wi-Fi goes back to its previous state once the plugin's push or pull is done.
            UIManager:scheduleIn(1, function()
                Sync.waitOutbox(p, 20, function() Wifi.release("reading") end)
            end)
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
    local held = false
    local function show()
        if held then
            held = false
            -- Put Wi-Fi back as the test found it, now rather than after the usual grace.
            local st = Wifi.state()
            local restore = st.restore_off
            Wifi.release("test")
            if restore then
                st.release_at = now_s()
                local action, reason = Wifi.evaluate("test done")
                add(action == "off", _("Wi-Fi turned back off (it was off)"), nil,
                    _("Left on: ") .. tostring(reason))
            end
        end
        UIManager:close(wait)
        local text = table.concat(lines, "\n") .. "\n\n" .. string.format(_("Total %s."), fmt(now_s() - t0))
            .. "\n" .. _("Step 4 only checks that the server answers at its base address; it uses no login.")
        local cl = compatLines(bookorbit(self.ui))
        if #cl > 0 then text = text .. "\n\n" .. table.concat(cl, "\n") end
        UIManager:show(TextViewer:new{ title = _("Test sync path"), text = text })
    end

    local c0 = now_s()
    local cstate = Companion.state()
    if cstate == "ok" then
        local status = Companion.status(1)
        add(status ~= nil, _("Companion answered"), now_s() - c0,
            _("Orbit Companion is installed but did not answer: open it once."))
    elseif cstate == "frozen" then
        add(false, _("Companion answered"), nil, Companion.disabledText())
    else
        add(false, _("Companion answered"), nil, _("Orbit Companion is not installed: Wi-Fi stays as it is, Tailscale is woken directly."))
    end
    if not p or not p:isLoggedIn() then
        add(false, _("BookOrbit plugin signed in"), nil, _("Sign in to BookOrbit first."))
        return show()
    end
    local was_on = Wifi.acquire("test")
    held = true
    if was_on == false then add(Companion.installed(), _("Wi-Fi was off: turning it on for the test"), nil, Companion.problem()) end
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
        if not (hasHandler(p, "BookOrbitSyncBook") and Compat.callable(p.startSweep) and Compat.callable(p.errorLabel)) then
            add(true, _("BookOrbit plugin step skipped: ") .. Compat.fallback("test_sync"), nil)
            return show()
        end
        -- The plugin's own Sync now: this book in a book, the library otherwise.
        if inBook() then
            pluginEvent(liveUI(), p, "BookOrbitSyncBook", { quiet = true, on_done = plugin_done })
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

-- Home from BookOrbit home: the companion's launcher page (as on a double Home). A companion
-- older than 0.2.1 has no SHOW_LAUNCHER; its apps page stands in.
function OrbitAndroid:openCompanionHome()
    if not Companion.installed() then
        log("home: companion not usable; staying on BookOrbit home")
        return true
    end
    local ok = Jni.startActivity{ action = Companion.ACTION.SHOW_LAUNCHER, package = Companion.PACKAGE }
    if not ok then
        ok = Jni.startActivity{ action = Companion.ACTION.SHOW_APPS, package = Companion.PACKAGE }
        log("home: companion launcher page missing (older companion); apps page", ok and "started" or "FAILED")
    else
        log("home: companion launcher page started")
    end
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
            -- Make BookOrbit home, the way the plugin's own Opening page saves it.
            if Compat.settable(p.settings, "catalog_auto_open", "home") then
                p.settings.catalog_auto_open = "home"
            else
                log("compat: catalog_auto_open is", tostring(p.settings.catalog_auto_open), "- left to the plugin's Opening page")
            end
            if not p.settings.auto_sync and hasHandler(p, "BookOrbitToggleAutoSync") then
                -- The plugin's own toggle also registers its reader events (main.lua:1416-1448).
                pluginEvent(liveUI(), p, "BookOrbitToggleAutoSync", true, true, true)
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
    -- Not used by the three above. KOReader's default for it in books is "brighter frontlight"
    -- on devices with a frontlight (gestures.koplugin/defaults.lua:129); this replaces that.
    { id = "two_finger_swipe_north", action = "orbit_open_apps", label = "Two-finger swipe up → Orbit Companion: apps (replaces brighter frontlight)" },
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
-- Menu (mockup screen 6): Tools › Android sync
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
    local cstate = Companion.state()
    if cstate == "ok" then
        table.insert(parts, _("companion installed"))
    elseif cstate == "frozen" then
        table.insert(parts, Companion.disabledText())
    else
        table.insert(parts, _("no companion"))
    end
    table.insert(parts, _("Wi-Fi: ") .. _(WifiPlan.modeLabel(Shared.mode())))
    local last = S.last_sleep_sync
    if last then
        table.insert(parts, string.format("%s %s %s", _("last sleep sync"), last.ok and fmt(last.seconds) or _("failed"),
            os.date("%H:%M", last.at)))
    end
    local need = Shared.setupNeededText()
    if need then table.insert(parts, need) end
    for _i, l in ipairs(compatLines(bookorbit(self.ui))) do table.insert(parts, l) end
    return _("Status: ") .. table.concat(parts, " · ")
end

function OrbitAndroid:updateStatusText()
    local st = S.patch_update_status
    local head = string.format(_("Patch %s"), PATCH_VERSION)
    if not st then return head .. " · " .. _("not checked yet") end
    return string.format("%s · %s (%s)", head, st.text, os.date("%m-%d %H:%M", st.at))
end

-- By hand: bring Wi-Fi up if needed (through the companion), check, then put Wi-Fi back.
function OrbitAndroid:checkPatchUpdate()
    local msg = InfoMessage:new{ text = _("Checking for a patch update…") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local function report(text)
        UIManager:close(msg)
        UIManager:show(InfoMessage:new{ text = _("Patch update: ") .. text, timeout = 6 })
    end
    local function run(held)
        UIManager:scheduleIn(0.2, function()
            Updater.check("menu", function(_ok, text)
                if held then Wifi.release("update") end
                report(text)
            end)
        end)
    end
    if NetworkMgr:isConnected() then return run(false) end
    if not Companion.installed() then
        setUpdateStatus("no internet: Wi-Fi is off")
        return report((Companion.problem() and (Companion.problem() .. " ") or "") .. _("No internet: Wi-Fi is off."))
    end
    Wifi.acquire("update")
    Net.up(nil, { reason = "update", cap = 20, need_server = false }, function(ok, res)
        if not ok then
            Wifi.release("update")
            setUpdateStatus("no internet: " .. tostring(res.detail))
            return report(_("No internet: ") .. tostring(res.detail))
        end
        run(true)
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
                Shared.push("menu: sync while reading")
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
    local wifi_items = {}
    for _i, o in ipairs(WifiPlan.MODES) do
        table.insert(wifi_items, {
            text = _(o.label),
            radio = true,
            enabled_func = function() return Companion.installed() end,
            checked_func = function() return Shared.mode() == o.id end,
            callback = function()
                Shared.set("wifi_mode", o.id)
                Wifi.applySettings("menu")
            end,
        })
    end
    local idle_items = {}
    for _i, m in ipairs(WifiPlan.IDLE_MINUTES) do
        table.insert(idle_items, {
            text = string.format(_("%d min"), m),
            radio = true,
            checked_func = function() return (S.wifi_idle_min or 2) == m end,
            callback = function()
                Shared.set("wifi_idle_min", m)
                Wifi.applySettings("menu")
            end,
        })
    end
    table.insert(wifi_items, {
        text_func = function() return string.format(_("Just in time: off after %d min idle"), S.wifi_idle_min or 2) end,
        enabled_func = function() return Shared.mode() == "jit" end,
        sub_item_table = idle_items,
        separator = true,
    })
    table.insert(wifi_items, {
        text_func = function()
            return Companion.problem() or _("Only Orbit Companion switches Wi-Fi. It never turns off Wi-Fi you turned on by hand in just in time, and never while another app is in front.")
        end,
        keep_menu_open = true,
        callback = function() end,
    })
    local home_items = {
        {
            text = _("Back to my book, then BookOrbit home"),
            radio = true,
            checked_func = function() return S.home_button ~= "bookorbit" end,
            callback = function() Shared.set("home_button", "smart") end,
        },
        {
            text = _("BookOrbit home"),
            radio = true,
            checked_func = function() return S.home_button == "bookorbit" end,
            callback = function() Shared.set("home_button", "bookorbit") end,
        },
    }
    return {
        {
            text_func = function() return _("Wi-Fi: ") .. _(WifiPlan.modeLabel(Shared.mode())) end,
            sub_item_table = wifi_items,
        },
        {
            text_func = function()
                local t = _("In KOReader, Home goes to: ") .. (S.home_button == "bookorbit" and _("BookOrbit home") or _("Back to my book, then BookOrbit home"))
                -- The companion's "Home opens" (companion 0.4.8+): this applies only with KOReader.
                if Shared.home_opens == "launcher" then t = t .. _(" (Home opens the Orbit launcher page)")
                elseif Shared.home_opens == "app" then t = t .. _(" (Home opens another app)") end
                return t
            end,
            sub_item_table = home_items,
            separator = true,
        },
        toggle("wifi_via_companion", _("Wi-Fi via Orbit Companion")),
        toggle("wake_tailscale", _("Wake Tailscale before syncing")),
        toggle("sync_on_wake", _("Always sync on wake")),
        toggle("sync_on_sleep", _("Sync when the screen goes off")),
        toggle("key_log", _("Log every key (clicker diagnosis)")),
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

-- Settings PIN set and locked: the companion's keypad, then open the menu again.
function OrbitAndroid:showPinKeypad(why)
    local ok = Jni.startActivity{ action = Companion.ACTION.SHOW_PIN, package = Companion.PACKAGE }
    log("menu: locked by the Settings PIN; keypad (" .. why .. ")", ok and "started" or "FAILED")
    return ok
end

function OrbitAndroid:lockedMenuItems()
    UIManager:scheduleIn(0.1, function() self:showPinKeypad("menu") end)
    return {
        { text = _("Enter the Settings PIN…"), callback = function() self:showPinKeypad("tap") end },
        { text = _("Locked by the companion's Settings PIN. Enter it, then open this menu again."),
            keep_menu_open = true, callback = function() end },
    }
end

function OrbitAndroid:addToMainMenu(menu_items)
    local entry = { text = _("Android sync"), sub_item_table_func = function()
        Shared.refresh("menu")
        if Shared.pin_locked then return self:lockedMenuItems() end
        UIManager:scheduleIn(0.5, function() self:maybeSetupPrompt("menu", "menu") end)
        return self:menuItems()
    end }
    -- Its own top-level entry in Tools, the way plugins and user patches add menus: an item
    -- missing from the menu order goes to the menu its sorting_hint names
    -- (frontend/ui/menusorter.lua:162-189). Nothing is injected into the plugin's menu.
    entry.sorting_hint = "tools"
    menu_items.orbit_android = entry
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
        -- interactive: the reader's own Wi-Fi toggle (manager.lua:433 toggleWifiOn), so it is
        -- theirs to turn off. Otherwise beforeWifiAction/runWhenOnline (manager.lua:605-619,
        -- 698-719) needs the network for something: just in time may turn it off again.
        local owner = interactive and "manual" or "auto"
        log("wifi: ON requested by KOReader (" .. owner .. ") | mode", Shared.mode())
        Wifi.activity()
        Companion.netUp("koreader_wifi_on", { owner = owner })
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
        log("wifi: OFF requested by KOReader's own toggle | mode", Shared.mode())
        Companion.wifiOff("koreader_wifi_off", false)
        if complete_callback then complete_callback() end
        return
    end
    return stock_turnOffWifi(self, complete_callback)
end

-- KOReader's Android backend calls "connected" Wi-Fi on (device.lua:341). With the companion we
-- know the radio itself, so the menu toggle and turnOnWifiAndWaitForConnection
-- (manager.lua:517-567) see real state.
local stock_isWifiOn = NetworkMgr.isWifiOn
function NetworkMgr:isWifiOn()
    if S.wifi_via_companion and Companion.installed() then
        local on = Jni.wifiEnabled()
        if on ~= nil then return on end
    end
    return stock_isWifiOn(self)
end

-- Anything that asks for the network through KOReader's framework (the plugin's catalog and
-- downloads, OPDS, updates) counts as activity for just in time.
local stock_beforeWifiAction = NetworkMgr.beforeWifiAction
function NetworkMgr:beforeWifiAction(callback)
    Wifi.activity("KOReader needs the network")
    return stock_beforeWifiAction(self, callback)
end

-- No "Turn on Wi-Fi?" prompt, in every Wi-Fi mode, when the companion can switch Wi-Fi:
-- beforeWifiAction then calls turnOnWifiAndWaitForConnection (manager.lua:609-611), whose
-- turnOnWifi goes to the companion. Without a usable companion, KOReader's stock behaviour stays.
-- KOReader's turn_on path shows a centred "Connecting to Wi-Fi…" InfoMessage until the
-- connection is up (frontend/ui/network/manager.lua:539-541, closed at :110-113 or replaced by
-- "Error connecting to the network" at :88-92). It runs for every beforeWifiAction
-- (manager.lua:605-619), e.g. the plugin's resume pull, which asks for the network 1 s after
-- each wake (bookorbit.koplugin main.lua:1329-1337 -> requestProgressPull(true, ...) ->
-- willRerunWhenConnected, bookorbit_progress_sync.lua:389). With Wi-Fi off after a sleep
-- sync or "just in time", that flashed on every wake. With the companion, the same steps run
-- without the message: ask for Wi-Fi (requestToTurnOnWifi, manager.lua:67-78), then the
-- stock connectivity check with no widget (:82-133), which shows nothing on success and
-- nothing on its 45 s give-up; a wake that can't connect still gets the patch's own banner.
local stock_turnOnWifiAndWait = NetworkMgr.turnOnWifiAndWaitForConnection
function NetworkMgr:turnOnWifiAndWaitForConnection(callback)
    if not (S.wifi_via_companion and Companion.installed()) or not self.requestToTurnOnWifi
            or not self.scheduleConnectivityCheck then
        return stock_turnOnWifiAndWait(self, callback)
    end
    if self:isWifiOn() and self:isConnected() then
        local fresh = not self.hasLeaseForCurrentNetwork or self:hasLeaseForCurrentNetwork()
        if fresh then
            if callback then callback() end
            return
        end
        if self.releaseIP then self:releaseIP() end
        self.lease_ssid = nil
    end
    log("wifi: KOReader needs the network; bringing it up quietly (no Connecting message) | mode", Shared.mode())
    local status = self:requestToTurnOnWifi(function()
        if self.pending_connectivity_check then self:unscheduleConnectivityCheck() end
        self:scheduleConnectivityCheck(callback)
    end)
    if status == false then
        log("wifi: quiet bring-up failed to start")
        if self._abortWifiConnection then self:_abortWifiConnection() end
        return false
    end
end

local function silentWifiOn()
    if not (S.wifi_via_companion and Companion.installed()) then return end
    local cur = G_reader_settings:readSetting("wifi_enable_action")
    if cur ~= "turn_on" then
        G_reader_settings:saveSetting("wifi_enable_action", "turn_on")
        log("wifi: KOReader's \"Action when Wi-Fi is off\" was", tostring(cur), "-> turn_on (the companion switches Wi-Fi, no prompt)")
    end
end
silentWifiOn()

wrapRequests("socket.http")
wrapRequests("ssl.https")

---------------------------------------------------------------------------------------------
-- Lists by series and by author (v0.6.0): the KOReader side of Group. The plugin's own views
-- draw everything; the patch wraps methods on its catalog class (bookorbit_catalog.lua; the
-- list methods are copied onto that class by CatalogLists.install, bookorbit_catalog_lists.lua
-- :1492-1496, so wrapping CatalogLists would change nothing) and on its API class
-- (bookorbit_api.lua). Each wrapper passes through unchanged unless its own mark is there:
--   - a list's Sort sheet (listSortSheetModel, :659; rows :707-713) gets "By series" and
--     "By author" (action orbit-group) on a library, collection or smart scope;
--   - orbit-group reads the list's books once (catalogBooks, 100 a page, "Reading N of M
--     books…"), holds them (Group.remember), and opens the plugin's Series or Authors view
--     (loadSection, bookorbit_catalog.lua:974) for them: listSectionParams (:246) hands the
--     request to fetch (:881), which answers it from the held books (Group.sectionBody), and
--     switchTo (:847) tags the context with orbit_group, so paging, the A-Z rail, sort, the
--     filter and reloads (reloadSection :1047, listReload :336) all keep working;
--   - listRun (:739) opens a row in the list (open-series / open-author), and the chips;
--   - listHeader (:1155) and listToolbar (:1115) say which list, and carry the chips;
--   - the API's query (:386) never sends the patch's orbit* marks; catalogBooks (:714) and
--     catalogManifest (:720) answer orbitLocal (a smart scope's row past 200 books) from the
--     held books.
---------------------------------------------------------------------------------------------
Grouping = { installed = false }

local function bookCount(n)
    return n == 1 and "1 book" or string.format("%d books", n)
end

-- The held list a context belongs to: from its orbit_group, or its request's orbitGroup.
local function heldOf(context)
    context = context or {}
    local token = (context.orbit_group and context.orbit_group.token) or (context.params and context.params.orbitGroup)
    return token and Group.held[token] or nil, token
end

-- Reads every book of the current list (inside a connected job), then opens the grouped view.
function Grouping.start(cat, section)
    local context = cat.current_context or {}
    local params = context.params or {}
    local list = Group.listOf(params)
    if not list then return end
    local function open(token)
        cat:loadSection(section, { orbit_group = { token = token, section = section } })
    end
    if context.orbit_snapshot and Group.held[context.orbit_snapshot] then
        return open(context.orbit_snapshot)
    end
    cat:runConnected(function()
        local books, total, page = {}, nil, 1
        while true do
            local label = total and string.format("Reading %d of %d books…", #books, total) or "Reading the list…"
            local q = Group.fetchParams(params, page)
            local body, err = cat:fetch(label, function() return cat.client:catalogBooks(q) end)
            if not body then
                if err ~= "cancelled" then
                    cat:showRetry(err, function() Grouping.start(cat, section) end)
                end
                return
            end
            local items = body.items or {}
            for _, b in ipairs(items) do table.insert(books, b) end
            total = tonumber(body.total) or total
            if #items == 0 or (total and #books >= total) or body.hasNext == false then break end
            page = page + 1
        end
        local token = Group.remember({ list = list, params = params, title = context.title or "", books = books })
        context.orbit_snapshot = token
        log("lists: read", #books, "books of", list.section, tostring(list.id), "for", section)
        UIManager:nextTick(function() open(token) end)
    end)
end

-- Opens a row of a grouped view: a series' books (in the list), an author's books by series.
function Grouping.openRow(cat, kind, entry)
    local context = cat.current_context or {}
    local og = context.orbit_group
    local snap = Group.held[og.token]
    if not snap then return false end
    if kind == "open-author" then
        cat:loadSection("series", { orbit_group = { token = og.token, section = "series", author = entry.title } })
        return true
    end
    local key = entry.orbitKey
    local books = Group.select(snap.books, og.author, key)
    local marks = { orbitGroup = og.token, orbitAuthor = og.author, orbitSeries = key }
    local target, flat
    if key == Group.STANDALONE then
        target, flat = { sort = "title" }, true
    else
        target = cat:paramsForEntry("series", entry)
        if og.author then target.author = og.author end
    end
    local p, how = Group.drill(snap.list, snap.params, books, target, marks, flat)
    log("lists: open", entry.title, "in", snap.list.section, tostring(snap.list.id), "(" .. how .. ", " .. #books .. " books)")
    cat:loadBooks(p, entry.title, true)
    return true
end

-- The chips: an author's books by series, all of them flat, or the author with no list.
function Grouping.chip(cat, chip)
    local context = cat.current_context or {}
    local params = context.params or {}
    local snap, token = heldOf(context)
    local author = (context.orbit_group and context.orbit_group.author) or params.orbitAuthor
    if chip == "whole-series" then
        local whole = { sort = "series", seriesId = params.seriesId, series = params.series }
        return cat:loadBooks(whole, context.title, true)
    end
    if chip == "all-by-author" and author then
        return cat:loadBooks({ author = author, sort = "series" }, author, true)
    end
    if not snap or not author then return end
    if chip == "by-series" then
        return cat:loadSection("series", { orbit_group = { token = token, section = "series", author = author }, replace = true })
    end
    if chip == "all-books" then
        local books = Group.select(snap.books, author, nil)
        local p = Group.drill(snap.list, snap.params, books, { sort = "title" }, { orbitGroup = token, orbitAuthor = author }, true)
        return cat:loadBooks(p, author, false)
    end
end

local function chipButton(label, on, chip, icon)
    return { icon = icon, label = label, on = on, action = { kind = "orbit-chip", chip = chip }, key = "orbit-" .. chip }
end

local function authorChips(on)
    return {
        chipButton("By series", on == "by-series", "by-series", "layers-2"),
        chipButton("All books", on == "all-books", "all-books", "book"),
        chipButton("All by author", false, "all-by-author", "user"),
    }
end

-- Wraps one class method once; the original stays callable as Cls.__orbit_stock[name].
local function wrap(Cls, name, make)
    local stock = rawget(Cls, "__orbit_stock") or {}
    rawset(Cls, "__orbit_stock", stock)
    if stock[name] then return end
    stock[name] = Cls[name]
    Cls[name] = make(stock[name])
end

function Grouping.install(why)
    if Grouping.installed then return true end
    local Catalog = package.loaded["bookorbit_catalog"]
    local Api = package.loaded["bookorbit_api"]
    if type(Catalog) ~= "table" or type(Api) ~= "table" then return false end
    local missing = {}
    for _, m in ipairs(Compat.missingOn(Catalog, Compat.CATALOG_CLASS)) do table.insert(missing, m) end
    for _, m in ipairs(Compat.missingOn(Api, Compat.API_CLASS)) do table.insert(missing, "api." .. m) end
    if #missing > 0 then
        if not compat_logged.grouping then
            compat_logged.grouping = true
            log("compat: lists by series and author off (plugin changed): missing " .. table.concat(missing, ", "))
        end
        return false
    end
    Grouping.installed = true

    wrap(Api, "query", function(stock) return function(self, path, params)
        return stock(self, path, Group.strip(params))
    end end)
    wrap(Api, "catalogBooks", function(stock) return function(self, params)
        if type(params) == "table" and params.orbitLocal == "1" then
            local books = Group.localBooks(params)
            if not books then return nil, 404 end
            return Group.booksBody(books, params)
        end
        return stock(self, params)
    end end)
    wrap(Api, "catalogManifest", function(stock) return function(self, params)
        if type(params) == "table" and params.orbitLocal == "1" then
            local books = Group.localBooks(params)
            if not books then return nil, 404 end
            local p = Group.strip(params)
            p.ids = Group.ids(books, Group.MANIFEST_IDS_MAX)
            return stock(self, p)
        end
        return stock(self, params)
    end end)

    wrap(Catalog, "listSortSheetModel", function(stock) return function(self, sheet)
        local m = stock(self, sheet)
        local context = self.current_context or {}
        local params = context.params or {}
        if type(m) == "table" and type(m.rows) == "table" and self:listKind() == "books"
            and Group.listOf(params) and not params.orbitGroup then
            table.insert(m.rows, 1, { icon = "user", label = "By author", value = "authors in this list", chevron = true,
                action = { kind = "orbit-group", section = "authors" }, key = "orbit-authors" })
            table.insert(m.rows, 1, { icon = "layers-2", label = "By series", value = "series in this list", chevron = true,
                action = { kind = "orbit-group", section = "series" }, key = "orbit-series" })
        end
        return m
    end end)

    wrap(Catalog, "listRun", function(stock) return function(self, action, region, hold)
        local context = self.current_context or {}
        local kind = type(action) == "table" and action.kind
        if not hold and kind == "orbit-group" then
            context.list_sheet = nil
            pcall(self.updateItems, self, nil, true) -- the sheet closes while the list is read
            return Grouping.start(self, action.section)
        elseif not hold and kind == "orbit-chip" then
            return Grouping.chip(self, action.chip)
        elseif not hold and (kind == "open-series" or kind == "open-author") and context.orbit_group
            and not context.dashboard_source_index and action.entry then
            if Grouping.openRow(self, kind, action.entry) then return end
        end
        return stock(self, action, region, hold)
    end end)

    -- A grouped view's request: marked by loadSection, taken by listSectionParams, answered by fetch.
    wrap(Catalog, "loadSection", function(stock) return function(self, section, opts)
        opts = opts or {}
        local og = opts.orbit_group
        local cur = self.current_context or {}
        if not og and opts.replace and cur.kind == "section" and cur.section == section and cur.orbit_group then
            og = cur.orbit_group
        end
        self._orbit_pending = og and Group.held[og.token] and { section = section, group = og } or nil
        return stock(self, section, opts)
    end end)
    wrap(Catalog, "listSectionParams", function(stock) return function(self, section, opts)
        local params = stock(self, section, opts)
        local pend = self._orbit_pending
        self._orbit_pending = nil
        if pend and pend.section == section then self._orbit_next = { group = pend.group, params = params or {} } end
        return params
    end end)
    wrap(Catalog, "fetch", function(stock) return function(self, text, fn, opts)
        local nxt = self._orbit_next
        if nxt then
            self._orbit_next = nil
            local snap = Group.held[nxt.group.token]
            if snap then
                local og = nxt.group
                local books = og.author and Group.select(snap.books, og.author, nil) or snap.books
                local rows = og.section == "authors" and Group.authors(books) or Group.series(books)
                self._orbit_tag = og
                return Group.sectionBody(rows, og.section, nxt.params, og.author and Group.standalone(books) or nil)
            end
        end
        return stock(self, text, fn, opts)
    end end)
    wrap(Catalog, "switchTo", function(stock) return function(self, title, item_table, context, push)
        local tag = self._orbit_tag
        self._orbit_tag = nil
        if tag and type(context) == "table" and context.kind == "section" then context.orbit_group = tag end
        return stock(self, title, item_table, context, push)
    end end)

    wrap(Catalog, "listHeader", function(stock) return function(self, kind, context)
        local h = stock(self, kind, context)
        local snap = heldOf(context)
        if type(h) ~= "table" or not snap or h.select then return h end
        local name = snap.title ~= "" and snap.title or "this list"
        local og = context.orbit_group
        if og and og.author then
            local n = #Group.select(snap.books, og.author, nil)
            h.title, h.title_data = og.author, true
            h.sub = string.format("%s in %s · by series", bookCount(n), name)
        elseif og then
            h.title = string.format(og.section == "authors" and "Authors in %s" or "Series in %s", name)
            h.title_data = true
        elseif kind == "seriespage" or kind == "books" then
            local n = tonumber(context.total) or #(context.books or {})
            if kind == "seriespage" then
                local summary = context.series_summary or {}
                n = tonumber(summary.total) or n
                local b = context.books and context.books[1]
                local who = b and b.authors and b.authors[1]
                h.sub = (who and (who .. " · ") or "") .. string.format("%s in %s", bookCount(n), name)
            else
                local sort = Compat.callable(self.listSortLabel) and (" · " .. self:listSortLabel(context.params or {})) or ""
                h.sub = string.format("%s in %s", bookCount(n), name) .. sort
            end
        end
        return h
    end end)

    wrap(Catalog, "listToolbar", function(stock) return function(self, kind, context)
        local buttons = stock(self, kind, context)
        local snap = heldOf(context)
        if not snap then return buttons end
        local og = context.orbit_group
        local params = context.params or {}
        if og and og.author then return authorChips("by-series") end
        if kind == "books" and params.orbitAuthor and not params.orbitSeries then return authorChips("all-books") end
        if kind == "seriespage" then
            buttons = type(buttons) == "table" and buttons or {}
            table.insert(buttons, chipButton("Whole series", false, "whole-series", "layers-2"))
        end
        return buttons
    end end)

    log("lists: by series and by author on (" .. tostring(why) .. ")")
    return true
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

-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- OrbiSmart sync on Android (docs/design/position-sync.md §3.3): the "Sync: OrbiSmart" setting's
-- runtime. The decision is logic/orbismart.lua (the shared table); this file feeds it and acts.
--   * Every pull and push of the BookOrbit plugin goes through its API client
--     (bookorbit_api.lua :578 getProgress, :582 updateProgress; the live push
--     bookorbit_progress_sync.lua :325, the outbox's bookorbit_book_sync.lua :858). Both are
--     wrapped: a pull records the server's place and runs the decision for the open book; a push
--     behind the last known server place is held (the behind-hold) and answered as done, so the
--     outbox entry completes without sending it.
--   * The plugin's own "further ahead" / "further behind" are Don't sync under OrbiSmart (kept
--     and given back under Custom): its pulls never move the reader. Orbit moves it: silently
--     before the page renders (ReaderReady, with a place already known), otherwise by asking
--     ("Continue from Boox, p. 214? Yes / No"), at open, wake, a pause or a pull while reading.
--   * A pause (120 s without a turn, moved more than a page) pulls and pushes.
--   * "Read from here everywhere" (Orbit menu, This book sheet) queues an override for the book,
--     sent now when the network comes up, else first at the next sync.
-- Per book (S.orbismart[digest]): m (the marker: server time and place of the last sync), server
-- (the last server place pulled), declined_at / declined_reset (the reader's No), override,
-- pending (a move found at sleep, asked at wake), pushed (the place of the last push).
---------------------------------------------------------------------------------------------

OSM = { PAUSE_S = 120, WAKE_MIN_S = 300, MAX_BOOKS = 300, MOMENT_S = 40, logged = {} }

-- The stock plugin's strategy for "Don't sync" (main.lua:56-60, Plan.STRATEGY).
local DONT = Plan.STRATEGY.DISABLE
-- BookOrbit's reset is served as the start of the book by this device id (koreader.service.ts:44-45).
local RESET_DEVICE_ID = "bookorbit-web"

function OSM.on() return S.sync_mode ~= "custom" end

local function once(key, ...)
    if OSM.logged[key] then return end
    OSM.logged[key] = true
    log(...)
end

-- The first run of a build with this setting: OrbiSmart, unless the reader changed a sync
-- setting it would override (docs/design/position-sync.md §6, the recommended-settings rule).
-- S.sync_mode already holds the schema's default (ko/settings.lua); a value chosen on either side
-- has a real time in S.settings_at (more than the 1 ms seed) and is left alone.
function OSM.migrate()
    if S.orbismart_migrated then return end
    S.orbismart_migrated = true
    local chosen = (tonumber(S.settings_at and S.settings_at.sync_mode) or 0) > 1
    local bo = G_reader_settings:readSetting("bookorbit")
    bo = type(bo) == "table" and bo or {}
    local custom = (S.reading_schedule or "off") ~= "off" or S.sync_on_wake == false or S.sync_on_sleep == false
        or bo.sync_forward == DONT or (bo.sync_backward ~= nil and bo.sync_backward ~= DONT)
    if custom and not chosen then
        S.sync_mode = "custom"
        S.settings_at.sync_mode = os.time() * 1000
        log("orbismart: this reader's sync settings were changed by hand; Sync stays Custom")
    end
    saveSettings()
end

---------------------------------------------------------------- per-book record

function OSM.rec(digest, create)
    if not digest then return nil end
    if type(S.orbismart) ~= "table" then S.orbismart = {} end
    local r = S.orbismart[digest]
    if not r and create then
        r = {}
        S.orbismart[digest] = r
        OSM.trim()
    end
    if r then r.seen = os.time() end
    return r
end

function OSM.trim()
    local list = {}
    for k, v in pairs(S.orbismart) do table.insert(list, { k = k, seen = type(v) == "table" and v.seen or 0 }) end
    if #list <= OSM.MAX_BOOKS then return end
    table.sort(list, function(a, b) return a.seen < b.seen end)
    for i = 1, #list - OSM.MAX_BOOKS do S.orbismart[list[i].k] = nil end
end

---------------------------------------------------------------- places (local pages)

local function openDigest(p)
    local okd, d = pcall(p.getDocumentDigest, p)
    return okd and d or nil
end

function OSM.pages(ui)
    local doc = ui and ui.document
    if not doc then return nil end
    local okn, n = pcall(function() return doc:getPageCount() end)
    return okn and type(n) == "number" and n > 0 and n or nil
end

-- A place in this layout's pages: the exact position when there is one (an xpointer, or a page
-- number for paged formats), else the percentage. -> page, percent_only.
function OSM.place(ui, pct, progress)
    local doc = ui and ui.document
    if doc and type(progress) == "string" and progress ~= "" then
        if doc.info and doc.info.has_pages then
            local n = tonumber(progress)
            if n then return n, false end
        else
            local okp, pg = pcall(function() return doc:getPageFromXPointer(progress) end)
            if okp and type(pg) == "number" then return pg, false end
        end
    end
    local n = OSM.pages(ui)
    if type(pct) == "number" and n then return math.floor(pct * n + 0.5), true end
    return nil, true
end

function OSM.localPlace(p, ui)
    local doc = ui and ui.document
    local okc, pg = pcall(function() return doc:getCurrentPage() end)
    if okc and type(pg) == "number" then return pg end
    if type(OSM.page) == "number" then return OSM.page end
    local okp, pct = pcall(p.getLastPercent, p)
    local n = OSM.pages(ui)
    if okp and type(pct) == "number" and n then return math.floor(pct * n + 0.5) end
    return nil
end

local function chapterOf(ui, page)
    local toc = ui and ui.toc
    if not toc or type(page) ~= "number" then return nil end
    local okk, key = pcall(function()
        if toc:isChapterStart(page) then return page end
        return toc:getPreviousChapter(page)
    end)
    return okk and key or nil
end

local function finished(ui)
    local okst, status = pcall(function() return ui.doc_settings:readSetting("summary").status end)
    return okst and status == "complete"
end

local function released(digest)
    local s = EOB and EOB.session and EOB.session[digest]
    return s ~= nil and (s.released == true or (s.forward or 0) >= Finish.HOLD_RELEASE_PAGES)
end

-- The decision's input (logic/orbismart.lua) for the open book against server place R.
function OSM.input(p, ui, digest, R, rec)
    local L = OSM.localPlace(p, ui)
    if not L then return nil end
    local i = { ["local"] = L, turn_at = p.last_page_turn_timestamp or 0, finished = finished(ui),
        released = released(digest), override = rec.override }
    local pages = OSM.pages(ui) or 100
    if R then
        local rp, pct_only = OSM.place(ui, R.pct, R.progress)
        i.server, i.server_at = rp, tonumber(R.at) or 0
        i.percent_only = pct_only and rp ~= nil
        if i.percent_only then i.tolerance = math.max(1, 0.02 * pages) end
        i.reset = R.device_id == RESET_DEVICE_ID and (R.pct or 0) == 0
        i.declined_at = (i.reset and rec.declined_reset) and i.server_at or rec.declined_at
    end
    if rec.m then
        local mp = OSM.place(ui, rec.m.pct, rec.m.progress)
        if mp then i.marker = { at = tonumber(rec.m.at) or 0, place = mp } end
    end
    -- BookOrbit's web reader re-dates the place it opens at: the start of a page or a chapter in
    -- the chapter last synced, at or before it (BookOrbitSmartSync::onlyRedated, design §5).
    if R and R.device == "web" and not i.reset and i.marker and i.server then
        local chapter = chapterOf(ui, i.server)
        i.redated = chapter ~= nil and chapter == chapterOf(ui, i.marker.place) and i.server - i.marker.place <= 1
    end
    return i
end

local function remoteOf(body)
    return { at = body.timestamp, pct = body.percentage, progress = body.progress, device = body.device,
        device_name = body.device_name, device_id = body.device_id }
end

---------------------------------------------------------------- the moment

-- What the next decision is for: set by the flows (open, wake, pause, sleep) for their pull;
-- otherwise a pull while a book is open is "reading".
function OSM.setMoment(m) OSM.moment, OSM.moment_until = m, now_s() + OSM.MOMENT_S end
function OSM.currentMoment()
    if OSM.moment and now_s() <= (OSM.moment_until or 0) then return OSM.moment end
    return "reading"
end

---------------------------------------------------------------- decide and act

function OSM.mark(rec, R) rec.m = { at = R.at, pct = R.pct, progress = R.progress } end

-- Decide for the open book against R (nil: the last server place known) at moment.
function OSM.decide(moment, R)
    if not OSM.on() then return nil end
    local ui = liveUI and liveUI() or nil
    local p = bookorbit(ui)
    if not p or not ui or not ui.document then return nil end
    local digest = openDigest(p)
    local rec = OSM.rec(digest, true)
    if not rec then return nil end
    R = R or rec.server
    local i = OSM.input(p, ui, digest, R, rec)
    if not i then return nil end
    local out = OrbiSmart.decide(i)
    local applied = OrbiSmart.apply(out.decision, moment)
    log(OrbiSmart.line(i, out, moment))
    if out.dropped then
        rec.override = nil
        log("orbismart: override dropped (newer reading elsewhere)")
    end
    local d = out.decision
    -- A released reread may replace the completed read's place once, even when that read
    -- finished short of 100%. A successful push consumes this exemption.
    if out.rule == "rule7" and d == "push" then rec.reread_at = i.server_at end
    if d == "same" and R then
        OSM.mark(rec, R)
        rec.pending = nil
    elseif d == "take" or d == "follow" then
        if applied == "now" then OSM.jump(p, digest, R, rec, i)
        elseif applied == "ask" then OSM.ask(p, ui, digest, R, i, d)
        elseif applied == "wake" then rec.pending = true end
    elseif d == "push" or d == "override" then
        -- Before render nothing is sent (the open flow follows); at sleep the plugin's snapshot
        -- carries the place, held or not by the behind-hold.
        if moment ~= "prerender" and moment ~= "sleep" and moment ~= "close" then OSM.push(p, d) end
    end
    saveSettings()
    return out, applied
end

function OSM.jump(p, digest, R, rec, i)
    rec.pending = nil
    OSM.mark(rec, R)
    pcall(p.noteProgressCompared, p, digest)
    local okj, err = pcall(p.syncToProgress, p, R.progress, R.pct)
    log("orbismart: moved", tostring(i["local"]) .. "->" .. tostring(i.server), okj and "" or ("FAILED: " .. tostring(err)))
end

function OSM.push(p, kind)
    if not NetworkMgr:isConnected() then return end
    p.push_timestamp = 0 -- the plugin's 25 s debounce (bookorbit_progress_sync.lua:26)
    p:requestProgressPush(false, false, kind == "override" and "orbismart_override" or "orbismart")
end

local function deviceLabel(R)
    local okn, Names = pcall(require, "bookorbit_device_names")
    if okn and type(Names) == "table" and type(Names.label) == "function" then
        local okl, l = pcall(Names.label, R.device, R.device_name)
        if okl and l then return l end
    end
    return R.device_name or R.device or _("another reader")
end

-- Closes the open popup without answering it (a newer place, or the book closed).
function OSM.closePopup()
    local cur = OSM.popup
    if not cur then return end
    cur.answered = true
    OSM.popup = nil
    pcall(UIManager.close, UIManager, cur.widget)
end

-- The Yes / No popup (ruling 1): one draw, no animation; one at a time, a newer place replaces it.
function OSM.ask(p, ui, digest, R, i, decision)
    local cur = OSM.popup
    if cur and cur.digest == digest and cur.at == R.at then return end
    OSM.closePopup()
    local t0 = now_s()
    local entry = { digest = digest, at = R.at }
    local function answer(yes)
        if entry.answered then return end
        entry.answered = true
        if OSM.popup == entry then OSM.popup = nil end
        local rec = OSM.rec(digest, true)
        log(string.format("orbismart: popup %s->%s %s after %d s", tostring(i["local"]), tostring(i.server),
            yes and "yes" or "no", math.floor(now_s() - t0)))
        if yes then
            local live = bookorbit(liveUI and liveUI() or ui)
            if live and openDigest(live) == digest then OSM.jump(live, digest, R, rec, i) end
        else
            rec.pending = nil
            if i.reset then rec.declined_reset = true else rec.declined_at = R.at end
        end
        saveSettings()
    end
    entry.widget = ConfirmBox:new{
        text = OrbiSmart.question(deviceLabel(R), i.server, decision),
        ok_text = _("Yes"),
        cancel_text = _("No"),
        ok_callback = function() answer(true) end,
        -- Back or a tap outside is No too (ConfirmBox:onClose calls cancel_callback, confirmbox.lua:242-244).
        cancel_callback = function() answer(false) end,
    }
    OSM.popup = entry
    UIManager:show(entry.widget) -- gate: OrbiSmart's Yes / No popup, shown while reading by the user's ruling (docs/design/position-sync.md ruling 1)
end

---------------------------------------------------------------- the plugin's API client

-- A pull of any book: remember the server's place; for the open book, decide.
function OSM.onPulled(digest, body)
    if type(body) ~= "table" or body.percentage == nil then return end
    local rec = OSM.rec(digest, true)
    rec.server = remoteOf(body)
    -- A standing reset is re-dated on each GET (pinned koreader.service.ts:579-589), so No
    -- covers that standing place until normal progress returns, not every future reset.
    if body.device_id ~= RESET_DEVICE_ID or body.percentage ~= 0 then rec.declined_reset = nil end
    saveSettings()
    local ui = liveUI and liveUI() or nil
    local p = bookorbit(ui)
    if not p or not ui or not ui.document or openDigest(p) ~= digest then return end
    -- The This book sheet shows BookOrbit's place itself, with its own Jump / Stay.
    if p.book_sheet then return end
    local moment = OSM.currentMoment()
    local remote = rec.server
    UIManager:nextTick(function()
        local current = liveUI and liveUI() or nil
        local live = bookorbit(current)
        if OSM.on() and current == ui and live == p and openDigest(live) == digest and rec.server == remote then
            OSM.decide(moment, remote)
        end
    end)
end

-- The behind-hold: a push behind the last server place this reader knows waits, except an
-- override or a released reread. -> true when held.
function OSM.holdPush(digest, pct, progress)
    local rec = OSM.rec(digest)
    if not rec or not rec.server or type(pct) ~= "number" then return false end
    if rec.override or (rec.reread_at ~= nil and rec.reread_at == (tonumber(rec.server.at) or 0)) then return false end
    local ui = liveUI and liveUI() or nil
    local p = bookorbit(ui)
    local L, R, tol
    if ui and ui.document and p and openDigest(p) == digest then
        local pct_only
        L = OSM.place(ui, pct, progress)
        R, pct_only = OSM.place(ui, rec.server.pct, rec.server.progress)
        tol = pct_only and math.max(1, 0.02 * (OSM.pages(ui) or 100)) or 1
    else
        -- A closed book: percent, a point either way.
        L, R, tol = pct * 100, (rec.server.pct or 0) * 100, 1
    end
    if L == nil or R == nil or OrbiSmart.mayPush(L, R, tol, false) then return false end
    log(string.format("orbismart: push held L=%s R=%s (behind the server)", tostring(L), tostring(R)))
    return true
end

function OSM.onPushed(digest, pct, progress, ts)
    local rec = OSM.rec(digest, true)
    rec.m = { at = ts, pct = pct, progress = progress }
    rec.server = rec.server or {}
    rec.server.at, rec.server.pct, rec.server.progress = ts, pct, progress
    rec.server.device_id = nil
    rec.pushed, rec.reread_at = pct, nil
    if rec.override then
        rec.override = nil
        log("orbismart: override sent")
    end
    saveSettings()
end

function OSM.installApi()
    if OSM.api_hooked then return true end
    local oka, Api = pcall(require, "bookorbit_api")
    if not oka or type(Api) ~= "table" then return false end
    local missing = Compat.missingOn(Api, Compat.ORBISMART_API)
    if #missing > 0 then
        once("api", "compat: BookSync's behind-hold and decisions off (plugin changed): missing api." .. table.concat(missing, ", api."))
        return false
    end
    OSM.api_hooked = true
    wrap(Api, "getProgress", function(stock) return function(self, digest, ...)
        local body, err = stock(self, digest, ...)
        if OSM.on() and type(body) == "table" then
            local okp, e = pcall(OSM.onPulled, digest, body)
            if not okp then log("orbismart: pull follow-up failed:", tostring(e)) end
        end
        return body, err
    end end, "orbismart")
    wrap(Api, "updateProgress", function(stock) return function(self, digest, pct, progress, ts, ...)
        if OSM.on() then
            -- An outbox snapshot may predate the override, or reading may have moved on while
            -- offline. The explicit action sends the place chosen then, before any snapshot.
            local rec = OSM.rec(digest)
            if rec and rec.override and type(rec.override.pct) == "number" then
                pct, progress, ts = rec.override.pct, rec.override.progress, os.time()
            end
            local okh, held = pcall(OSM.holdPush, digest, pct, progress)
            if not okh then return nil, "BookSync could not check the server place" end
            -- Answered as sent: the outbox entry completes, the server keeps its further place.
            if okh and held then return { document = digest, timestamp = ts, orbit_held = true } end
        end
        local body, err = stock(self, digest, pct, progress, ts, ...)
        if OSM.on() and body then pcall(OSM.onPushed, digest, pct, progress, ts) end
        return body, err
    end end, "orbismart")
    return true
end

---------------------------------------------------------------- the plugin's settings

-- Under OrbiSmart the plugin never moves the reader by itself: "further ahead" and "further
-- behind" are Don't sync (its settings page, bookorbit_settings_page.lua sync strategies). Its
-- own values are kept and given back under Custom, unless the reader changed them meanwhile.
function OSM.preset(p)
    if not p or type(p.settings) ~= "table" then return end
    local st = p.settings
    if OSM.on() then
        if st.sync_forward ~= DONT or st.sync_backward ~= DONT or st.auto_sync ~= true then
            if S.osm_saved_plugin == nil then
                S.osm_saved_plugin = { sync_forward = st.sync_forward, sync_backward = st.sync_backward, auto_sync = st.auto_sync }
            end
            st.sync_forward, st.sync_backward = DONT, DONT
            if st.auto_sync ~= true then pluginEvent(liveUI(), p, "BookOrbitToggleAutoSync", true, true, true) end
            saveSettings()
            log("orbismart: the plugin's further ahead / behind -> Don't sync (Orbit decides)")
        end
    elseif S.osm_saved_plugin then
        if st.sync_forward == DONT and st.sync_backward == DONT then
            st.sync_forward = S.osm_saved_plugin.sync_forward
            st.sync_backward = S.osm_saved_plugin.sync_backward
            if st.auto_sync == true and S.osm_saved_plugin.auto_sync ~= true then
                pluginEvent(liveUI(), p, "BookOrbitToggleAutoSync", false, true, true)
            end
            log("orbismart: Custom; the plugin's further ahead / behind given back")
        end
        S.osm_saved_plugin = nil
        saveSettings()
    end
end

-- The plugin's own value of a setting OrbiSmart presets, kept for Custom: { value } or nil when
-- OrbiSmart holds none (Recommended settings read and write this one, ko/recommended.lua).
function OSM.savedPluginSetting(key)
    if not OSM.on() or type(S.osm_saved_plugin) ~= "table" then return nil end
    if key ~= "sync_forward" and key ~= "sync_backward" and key ~= "auto_sync" then return nil end
    return { value = S.osm_saved_plugin[key] }
end

function OSM.setSavedPluginSetting(key, value)
    if not OSM.savedPluginSetting(key) then return false end
    S.osm_saved_plugin[key] = value
    saveSettings()
    return true
end

function OSM.modeChanged(why)
    if not OSM.on() then OSM.closePopup() end
    log("orbismart: Sync =", OSM.on() and "OrbiSmart" or "Custom", "(" .. tostring(why) .. ")")
    local ui = liveUI and liveUI() or nil
    local p = bookorbit(ui)
    if p then OSM.preset(p) end
    local m = state.module
    if m and m.ui and m.ui.document then pcall(m.hookPluginPagePush, m) end
end

---------------------------------------------------------------- flows

-- ReaderReady runs before the first paint (ReaderUI:init ends with it; showReader paints after),
-- so a further place already known opens straight there (ruling 1: silent before render).
function OSM.onReaderReady(m)
    local p = bookorbit(m.ui)
    if not p then return end
    OSM.installApi()
    OSM.installSheet()
    OSM.preset(p)
    if not OSM.on() then return end
    OSM.page = nil
    local digest = openDigest(p)
    local rec = OSM.rec(digest)
    local R = rec and rec.server
    local live = p.last_remote_progress
    if type(live) == "table" and live.digest == digest and live.percentage ~= nil and (not R or (live.timestamp or 0) > (R.at or 0)) then
        R = remoteOf({ timestamp = live.timestamp, percentage = live.percentage, progress = live.progress,
            device = live.device, device_name = live.device_name })
    end
    if R then OSM.decide("prerender", R) end
    OSM.setMoment("open")
end

-- Resume: a move found at sleep is asked now, before any network.
function OSM.onResume()
    if not OSM.on() or not inBook() then return end
    local ui = liveUI()
    local p = bookorbit(ui)
    local rec = p and OSM.rec(openDigest(p))
    OSM.setMoment("wake")
    if rec and rec.pending and rec.server then OSM.decide("wake", rec.server) end
end

-- Pull, then the outbox (the behind-hold needs the server's place first), then done().
function OSM.pullThenDrain(p, moment, source, done)
    OSM.setMoment(moment)
    local digest = openDigest(p)
    p:fetchRemoteProgress(digest, function()
        -- onPulled's queued decision runs first, including sending or dropping an override.
        UIManager:nextTick(function()
            OSM.setMoment(moment)
            if can(p, "outbox") then p:requestLifecycleOutboxDrain(source) end
            done()
        end)
    end, true)
end

function OSM.onPage(m, page)
    OSM.page = page
    if OSM.pause_task then UIManager:unschedule(OSM.pause_task) end
    OSM.pause_task = function()
        OSM.pause_task = nil
        OSM.pause(m)
    end
    UIManager:scheduleIn(OSM.PAUSE_S, OSM.pause_task)
end

-- A pause: 120 s without a turn, and the place moved more than a page since the last push.
function OSM.pause(m)
    if not OSM.on() or not inBook() or OSM.pausing then return end
    local ui = liveUI()
    local p = bookorbit(ui)
    if not p or not p:isLoggedIn() or not can(p, "reading_sync") then return end
    local digest = openDigest(p)
    local rec = OSM.rec(digest, true)
    local L = OSM.localPlace(p, ui)
    local last = rec.pushed and OSM.place(ui, rec.pushed, nil) or (rec.m and OSM.place(ui, rec.m.pct, rec.m.progress))
    if L == nil or (last and math.abs(L - last) <= 1) then return end
    OSM.pausing = true
    Wifi.acquire("pause")
    Net.up(p, { reason = "pause", cap = 20, need_server = true }, function(ok, res)
        if not ok then
            OSM.pausing = false
            Wifi.release("pause")
            log("orbismart: pause sync skipped, network not ready:", res and res.detail or "")
            return
        end
        OSM.pullThenDrain(p, "pause", "orbismart_pause", function()
            OSM.pausing = false
            UIManager:scheduleIn(1, function() Sync.waitOutbox(p, 20, function() Wifi.release("pause") end) end)
        end)
    end)
end

-- "Read from here everywhere": pushes this place now, skipping the behind-hold once; queued for
-- the next sync when offline (design §3.5). On a finished book it starts a reread (ruling 2).
function OSM.readFromHere(why)
    local ui = liveUI()
    local p = bookorbit(ui)
    if not p or not ui or not ui.document then return end
    local digest = openDigest(p)
    local rec = OSM.rec(digest, true)
    local okp, pct = pcall(p.getLastPercent, p)
    local okx, progress = pcall(p.getLastProgress, p)
    if not okp or type(pct) ~= "number" or not okx then return end
    rec.override = { at = os.time(), pct = pct, progress = progress }
    rec.declined_at, rec.declined_reset, rec.pending = nil, nil, nil
    if finished(ui) and EOB and EOB.session and digest then
        EOB.session[digest] = EOB.session[digest] or { forward = 0 }
        EOB.session[digest].released = true
    end
    saveSettings()
    log("orbismart: override queued (" .. tostring(why) .. ")")
    if not p:isLoggedIn() then return end
    Wifi.acquire("override")
    Net.up(p, { reason = "override", cap = 20, need_server = true }, function(ok)
        if not ok then
            Wifi.release("override")
            log("orbismart: override queued (offline); sent first at the next sync")
            return
        end
        OSM.push(p, "override")
        UIManager:scheduleIn(1, function() Sync.waitOutbox(p, 20, function() Wifi.release("override") end) end)
    end)
end

---------------------------------------------------------------- the This book sheet

-- One row under Auto-sync in the plugin's This book sheet (bookorbit_book_sheet.lua :241-243,
-- built through bookorbit_menu_ui.lua :217 MenuUI.row, :71 MenuUI.divider), and its action
-- (bookorbit_menu_page.lua :189 MenuPage:runAction). Missing: the Orbit menu still has it.
function OSM.installSheet()
    if OSM.sheet_hooked then return true end
    local oku, MenuUI = pcall(require, "bookorbit_menu_ui")
    local okp, MenuPage = pcall(require, "bookorbit_menu_page")
    local okb, BoardUI = pcall(require, "bookorbit_board_ui")
    if not (oku and okp and okb) or type(MenuUI) ~= "table" or type(MenuPage) ~= "table" or type(BoardUI) ~= "table" then return false end
    local missing = {}
    for _, n in ipairs(Compat.missingOn(MenuUI, { row = "function", divider = "function" })) do table.insert(missing, "MenuUI." .. n) end
    for _, n in ipairs(Compat.missingOn(MenuPage, { runAction = "function" })) do table.insert(missing, "MenuPage." .. n) end
    for _, n in ipairs(Compat.missingOn(BoardUI, { vstack = "function" })) do table.insert(missing, "BoardUI." .. n) end
    if #missing > 0 then
        once("sheet", "compat: \"Read from here everywhere\" in This book off (plugin changed): missing " .. table.concat(missing, ", "))
        return false
    end
    OSM.sheet_hooked = true
    wrap(MenuUI, "row", function(stock) return function(w, o, ...)
        local row = stock(w, o, ...)
        if type(o) == "table" and type(o.action) == "table" and o.action.kind == "auto" and OSM.on() and inBook() then
            local here = stock(w, { icon = "arrow-right", label = _("Read from here everywhere"),
                sub = _("Your other readers move here at their next sync"), action = { kind = "orbit_read_here" } })
            return BoardUI.vstack({ w = w }, { row, MenuUI.divider(w), here })
        end
        return row
    end end, "orbismart")
    wrap(MenuPage, "runAction", function(stock) return function(page, action, ...)
        if type(action) == "table" and action.kind == "orbit_read_here" then
            pcall(page.close, page)
            UIManager:nextTick(function() OSM.readFromHere("This book") end)
            return
        end
        return stock(page, action, ...)
    end end, "orbismart")
    return true
end

---------------------------------------------------------------- wiring

Compat.ORBISMART_API = { getProgress = "function", updateProgress = "function" }

OSM.migrate()
-- Cover closed-book startup outbox drains too; ReaderReady retries if BookOrbit loads later.
OSM.installApi()

do
    local base_ready = OrbitAndroid.onReaderReady
    function OrbitAndroid:onReaderReady(...)
        -- Before the rest: a known further place opens before the first paint.
        local okr, err = pcall(OSM.onReaderReady, self)
        if not okr then log("orbismart: open failed:", tostring(err)) end
        return base_ready(self, ...)
    end
    local base_page = OrbitAndroid.onPageUpdate
    function OrbitAndroid:onPageUpdate(page, ...)
        if OSM.on() and type(page) == "number" and self.ui and self.ui.document then pcall(OSM.onPage, self, page) end
        return base_page(self, page, ...)
    end
    local base_resume = OrbitAndroid.onResume
    function OrbitAndroid:onResume(...)
        pcall(OSM.onResume)
        return base_resume(self, ...)
    end
    local base_close = OrbitAndroid.onCloseWidget
    function OrbitAndroid:onCloseWidget(...)
        if OSM.pause_task then UIManager:unschedule(OSM.pause_task); OSM.pause_task = nil end
        OSM.closePopup()
        return base_close(self, ...)
    end
end

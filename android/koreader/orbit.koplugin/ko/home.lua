-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- "Go home" from the companion launcher
---------------------------------------------------------------------------------------------

function OrbitAndroid:checkCommand(source)
    local cmd = Jni.takeIntentExtra(Companion.EXTRA_COMMAND)
    if not cmd or cmd == "" then return false end
    local from = Jni.takeIntentExtra(Companion.EXTRA_FROM)
    local held = Jni.takeIntentExtra(Companion.EXTRA_ROTATION)
    if not Companion.confirmCommand(cmd) then
        log("command ignored:", cmd, "(" .. source .. "): not sent by Orbit Companion")
        return false
    end
    log("command from companion:", cmd, "(" .. source .. ")", from and ("from " .. tostring(from)) or "",
        held and ("held " .. tostring(held)) or "")
    if cmd == "home" or cmd == "home_smart" then
        self:smartHome(source, from or nil, cmd == "home" and HomePlan.SERVER_HOME or "smart", held or nil)
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
    -- recommended settings' review page.
    if cmd == "signin" then
        UIManager:scheduleIn(0.5, function() self:openSignIn(source) end)
        return true
    end
    if cmd == "recommended" then
        UIManager:scheduleIn(0.5, function() self:showRecommended("companion") end)
        return true
    end
    -- The companion's Settings buttons (docs/design/companion-settings.md §3.2, A2, A4, A5): the work
    -- happens here in KOReader, which the command brought to the front.
    if cmd == "full_refresh" then
        UIManager:scheduleIn(0.5, function() Library.fullRefresh() end)
        return true
    end
    if cmd == "sync_sleep" then
        UIManager:scheduleIn(0.5, function() self:onOrbitSyncAndSleep() end)
        return true
    end
    if cmd == "test_sync_path" then
        UIManager:scheduleIn(0.5, function() self:testSyncPath() end)
        return true
    end
    log("unknown command ignored:", cmd)
    return false
end

function OrbitAndroid:openSignIn(source)
    return AccountView.open("account")
end

-- COMMAND=restart (android/docs/INTERFACE.md): the companion installed a newer patch file; a restart
-- loads it. KOReader's own restart (UIManager:restartKOReader, frontend/ui/uimanager.lua:1766,
-- quit(85)) relies on a launcher script that Android lacks (Device canRestart = no,
-- frontend/device/android/device.lua:86), so: save like a kill would leave it (the open book
-- stays open_book_at_exit, so the cold start reopens it), ask the companion to start KOReader
-- again (RELAUNCH), and quit (Android Device:exit finishes the activity, device.lua:492-497).
-- quit_only: another app is in front; KOReader saves and quits without coming back, and the
-- next start (Home, the launcher) loads the new plugin and reopens the book.
function OrbitAndroid:restartForCompanion(source, quit_only)
    -- Once: the quit ends this process (a second request in the meantime is the same restart).
    if state.restarting_at and now_s() - state.restarting_at < 5 then return end
    state.restarting_at = now_s()
    log("orbit: closing reader because companion restart:", quit_only and "KOReader is in the background; saving and quitting, the new plugin loads at the next start ("
        .. tostring(source) .. ")" or ("requested (" .. tostring(source) .. "); saving, then quitting so the new patch loads"))
    local ui = liveUI()
    if ui and ui.document and ui.saveSettings then pcall(ui.saveSettings, ui) end
    -- The quit closes the reader (which clears open_book_at_exit): remember the book apart, so
    -- the next start reopens it where it was (v0.5.5).
    S.restart_book = ui and ui.document and ui.document.file or nil
    S.restart_screen = HomeHost.foreground() and HomePlan.SERVER_HOME or nil
    saveSettings()
    pcall(function() G_reader_settings:flush() end)
    Stats.send("restart", nil, false)
    if quit_only then
        -- nothing relaunches it
    elseif Companion.has("home") then
        Companion.send(Companion.ACTION.RELAUNCH, { reason = "restart" })
    else
        -- Add-on: KOReader is in front, so it may start the companion's relaunch window, which
        -- then starts KOReader again once it has gone (docs/design/addon-mode.md §7.4).
        local ok = Jni.startActivity{ action = Companion.ACTION.RELAUNCH_UI, package = Companion.PACKAGE } -- gate: restarts only per RestartPlan (manual, screen off, background) or the companion's own restart
        log("restart: companion relaunch window", ok and "started" or "FAILED (reopen KOReader by hand)")
    end
    UIManager:scheduleIn(0.5, function()
        if Device.canRestart and Device:canRestart() then UIManager:restartKOReader() else UIManager:quit() end -- gate: restarts only per RestartPlan (manual, screen off, background) or the companion's own restart
    end)
end

-- RestartPlan here: the version our own file on disk declares (PATCH_VERSION is near its top).
function patchFileVersion()
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
    -- Without the Home role nothing can start KOReader from the background: no restart at
    -- screen-off, only while KOReader is in front (docs/design/addon-mode.md §7.4).
    if event == "sleep" and not Companion.has("home") then event = "check_asleep" end
    local act = RestartPlan.decide(want, PATCH_VERSION, S.restart_tried, inBook(), event)
    if act == "wait" then
        if state.restart_waiting ~= want then
            state.restart_waiting = want
            log("restart: v" .. tostring(want) .. " is installed; restarting when KOReader goes to the background or the screen goes off")
        end
    elseif act == "done" then
        local text = RestartPlan.doneText(PATCH_VERSION)
        S.restart_tried = nil
        setUpdateStatus(text)
        orbitNote(_(text), 3)
    elseif act == "gave_up" then
        if state.restart_gave_up ~= want then
            state.restart_gave_up = want
            setUpdateStatus("v" .. tostring(want) .. " is installed but didn't load after a restart: restart KOReader by hand (BookSync Companion > Setup)")
        end
    elseif act == "quit" then
        S.restart_tried = want
        saveSettings()
        self:restartForCompanion("v" .. tostring(want) .. " installed (" .. event .. ")", true)
    elseif act == "restart" and not Companion.has("relaunch") then
        -- Nobody can start KOReader again after a quit (no companion): ask once, never quit
        -- (docs/design/addon-mode.md §3, "Restart KOReader after an update").
        if state.restart_asked ~= want then
            state.restart_asked = want
            local text = string.format(_("BookSync v%s is installed: close KOReader and open it again to finish."), tostring(want))
            setUpdateStatus(text)
            log("restart: v" .. tostring(want) .. " installed; no companion to relaunch KOReader, asking the reader")
            Gate.show("restart ask", function() UIManager:show(InfoMessage:new{ text = text, timeout = 6 }) end) -- gate: Gate.show
        end
        return "ask"
    elseif act == "restart" then
        S.restart_tried = want
        saveSettings()
        self:restartForCompanion("v" .. tostring(want) .. " installed (" .. event .. ")")
    end
    return act
end

-- topmost (the plugin's own test, main.lua:1384) and shows its dashboard context
-- (book details, lists, sheets over it) don't count.
-- The topmost screen: notes (KOReader's toasts, Orbit's own notes) float over it and never count.
function topWidget()
    local okw, stack = pcall(function() return UIManager._window_stack end)
    if okw and type(stack) == "table" and #stack > 0 then
        for i = #stack, 1, -1 do
            local w = stack[i] and stack[i].widget
            if w and not w.invisible and not w.toast and not w.orbit_note then return w end
        end
        return nil
    end
    local okt, top = pcall(function() return UIManager:getTopmostVisibleWidget() end)
    return okt and top or nil
end

-- Nothing interrupts reading (docs/design/reading-gate.md): while a book is open in front,
-- nothing from BookSync shows, restarts or takes focus. reading() is the one gate; every note and
-- message goes through Gate.show, which holds it until the next moment nobody is reading
-- and drops it when it has gone stale. Exceptions are only what the reader does in the book:
-- menus they open, the end-of-book sheet.
function reading()
    if StorageUI and (StorageUI.opening or StorageUI.active and topWidget() == StorageUI.active) then return false end
    if BatteryUI and (BatteryUI.opening or BatteryUI.active and topWidget() == BatteryUI.active) then return false end
    if HomeHost and (HomeHost.opening or HomeHost.foreground()) then return false end
    local ui = liveUI()
    if not (ui and ui.document) then return false end
    if Wifi and Wifi.state and Wifi.state().foreground == false then return false end

    if ui.menu and ui.menu.menu_container then return false end -- a menu the reader opened
    if (FinishUI and FinishUI.sheet~=nil) then return false end                -- the reader reached the end
    return true
end

Gate = { queue = {}, MAX_AGE_S = 600 }

function Gate.refreshNotice(what)
    local full = Library.catalog_active
    log((full and "Full refresh" or "background") .. ": suppressed notice: " .. tostring(what))
    if full and Badge and Badge.notice then Badge.notice(what) end
end

-- what: for the log; fn: shows it; max_age_s: dropped after this long held.
function Gate.show(what, fn, max_age_s)
    if Gate.silent() then
        Gate.refreshNotice(what)
        return
    end
    if not reading() then
        log("notice: shown: " .. tostring(what))
        return fn()
    end
    log("notice: suppressed (held while reading): " .. tostring(what))
    for _, q in ipairs(Gate.queue) do
        if q.what == what then q.fn, q.at = fn, now_s(); return end -- the newest of the same kind
    end
    table.insert(Gate.queue, { what = what, fn = fn, at = now_s(), max_age = max_age_s or Gate.MAX_AGE_S })
end

function Gate.drain(why)
    if Gate.inBackground() and not (Library.catalog_active) then return end
    if Gate.silent() then
        for _, q in ipairs(Gate.queue) do Gate.refreshNotice(q.what) end
        Gate.queue = {}
        return
    end
    if #Gate.queue == 0 or reading() then return end
    local list = Gate.queue
    Gate.queue = {}
    for _, q in ipairs(list) do
        if now_s() - q.at <= q.max_age then
            log("gate: shown now (" .. tostring(why) .. "):", q.what)
            pcall(q.fn)
        else
            log("notice: suppressed (stale): " .. tostring(q.what))
        end
    end
end

function Gate.installToast()
    -- The final boundary also catches direct KOReader and Trapper messages.
    -- Dialogs (including position-sync choices) are unaffected.
    wrap(UIManager, "show", function(stock) return function(self, w, ...)
        local notice = w and (false or w.is_infomessage or w.orbit_note)
        local m = w and getmetatable(w)
        while m and not notice do
            notice = m == InfoMessage or m == package.loaded["ui/widget/notification"]
            m = getmetatable(m)
        end
        if notice then
            local text = w.text
            if not text and w.variants then
                local parts = {}
                for _, part in ipairs(w.variants[1] or {}) do parts[#parts + 1] = tostring(part.t or "") end
                text = table.concat(parts)
            end
            -- Invisible Trapper input traps have no message and must keep working.
            if text ~= nil then
                -- Zero-timeout opening messages keep UIManager alive until its
                -- next-tick ReaderUI constructor runs. Callback-bearing widgets
                -- also belong to a caller's control flow, not the notice queue.
                if not w.orbit_refresh_popup and w.timeout ~= 0 and not w.dismiss_callback
                    and not w.invisible and Gate.silent() then
                    Gate.refreshNotice("notice: " .. tostring(text)); return
                end
                log("notice: shown: " .. tostring(text))
            end
        end
        return stock(self, w, ...)
    end end, "refresh_notices")
    Gate.installCatalog()
    Gate.installTrapper()


end

-- A short note that never sits in the way: KOReader's Notification is a toast (it lets every
-- tap through and closes on the next event, notification.lua:63), so Home opening under it
-- still sees Home on top. Without it: an InfoMessage marked as a note. Held while reading.
function orbitNote(text, timeout, refresh_popup)
    local show = function()
        local okn, Notification = pcall(require, "ui/widget/notification")
        if okn and type(Notification) == "table" and type(Notification.new) == "function" then
            local okw, w = pcall(Notification.new, Notification, { text = text, timeout = timeout or 4 })
            if okw and w then w.orbit_note = true; w.orbit_refresh_popup = refresh_popup; UIManager:show(w); return w end -- gate: inside Gate.show
        end
        local w = InfoMessage:new{ text = text, timeout = timeout or 4 }
        w.orbit_note = true
        w.orbit_refresh_popup = refresh_popup
        UIManager:show(w) -- gate: inside Gate.show
        return w
    end
    if refresh_popup then return show() end
    return Gate.show("note: " .. tostring(text), show)
end

-- as toasts) and KOReader's widgets float over Home while the reader browses it (v0.11.1 on the
-- M8C held Full refresh's progress "while reading" with Home on screen). The pills alone, over
-- the book, don't count. Shared by reading() and the Wi-Fi plan's "browsing".
function visibleStack()
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

--   "main": the catalog (main.lua:1207-1229) is the topmost widget, in dashboard mode
--     showRecentSearches; detail_sheet/list_sheet live in that context, :2451-2462), or
--   nil: no catalog showing (none, or KOReader's file browser or a book over it).
-- Returns kind, the widgets over the catalog (topmost first), and a description for the log.
function keepHeldRotation(action, held, in_reader, source)
    if held == nil then return end
    -- KOReader's start already kept the held rotation (patches/1-orbit-start-rotation.lua).
    if source == "start" and rawget(_G, "ORBIT_START_ROTATION") ~= nil then
        log("home: rotation kept from the start (" .. tostring(rawget(_G, "ORBIT_START_ROTATION")) .. ")")
        return
    end
    local okc, current = pcall(function() return Device.screen:getRotationMode() end)
    local okl, locked = pcall(function() return G_reader_settings:isTrue("lock_rotation") end)
    local mode = HomePlan.rotation{
        action = action, held = held, in_reader = in_reader,
        current = okc and current or nil, locked = okl and locked or false,
    }
    if mode == nil then
        log("home: rotation stays", okc and tostring(current) or "?", "(held " .. tostring(held) .. ")")
        return
    end
    local okf, FM = pcall(require, "apps/filemanager/filemanager")
    local oks, err = pcall(function()
        if okf and type(FM) == "table" and FM.instance then FM.instance:onSetRotationMode(mode)
        else Device.screen:setRotationMode(mode) end
    end)
    log("home: rotation", tostring(current), "->", mode, "(held " .. held .. ")", oks and "" or tostring(err))
end

-- A book closing opens a new file browser, which turns the device to the file browser's rotation
-- start sets it before plugins load (reader.lua:291); the companion's ROTATION corrects that one.
function keepRotationOnFileBrowser(why)
    local okf, FM = pcall(require, "apps/filemanager/filemanager")
    if not okf or type(FM) ~= "table" or rawget(FM, "_orbit_keep_rotation") then return end
    if not Compat.callable(FM.setRotationMode) then
        log("compat: FileManager.setRotationMode missing; the file browser keeps its own rotation")
        return
    end
    FM._orbit_keep_rotation = true
    FM.setRotationMode = function()
        log("file browser: rotation stays", tostring(select(2, pcall(function() return Device.screen:getRotationMode() end))))
    end
    log("file browser: keeps the current rotation (" .. why .. ")")
end

-- The early user patch that keeps the held rotation through KOReader's start
-- (patches/1-orbit-start-rotation.lua): copied into koreader/patches/ when missing or different.
-- KOReader runs it at its next start (userpatch.lua, reader.lua:26-27); builds that skip user
-- patches fall back to keepHeldRotation, which turns once more after the start.
START_PATCH = "1-orbit-start-rotation.lua"

function installStartPatch(why)
    local function slurp(path)
        local h = io.open(path, "rb")
        if not h then return nil end
        local text = h:read("*a")
        h:close()
        return text
    end
    local want = slurp(PLUGIN_DIR .. "/patches/" .. START_PATCH)
    local okd, DataStorage = pcall(require, "datastorage")
    if not want or not okd then return false end
    local dir = DataStorage:getDataDir() .. "/patches"
    local dest = dir .. "/" .. START_PATCH
    if slurp(dest) == want then return false end
    local okl, lfs = pcall(require, "libs/libkoreader-lfs")
    if okl and lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    local tmp = dest .. ".tmp"
    local h = io.open(tmp, "wb")
    if not h then log("start patch: can't write", dest); return false end
    h:write(want)
    h:close()
    local okr, err = os.rename(tmp, dest)
    if not okr then os.remove(tmp); log("start patch: install failed:", tostring(err)); return false end
    log("start patch: installed", dest, "(" .. why .. ")")
    return true
end

-- Home (android/docs/INTERFACE.md "go home"): HomePlan decides. mode: "smart" (home_smart) or
-- HomePlan.SERVER_HOME (home).
function OrbitAndroid:smartHome(source,from_extra,mode,held)
    local host=HomeHost.active
    local ui=liveUI()
    if host and HomeHost.foreground() and (mode==nil or mode=="smart") then
        if from_extra=="other_app" and ui and ui.document then UIManager:close(host);return true end
        if host.list_layout or host.series_key then return host:onClose() end
        return self:openCompanionHome()
    end
    if from_extra=="other_app" and ui and ui.document and (mode==nil or mode=="smart") then return true end
    return HomeHost.show()
end

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
    if HomeHost.active then UIManager:close(HomeHost.active) end
    log("restart: reopening the book at its place (" .. source .. "):", file)
    local screen = S.restart_screen
    if screen then S.restart_screen = nil; saveSettings() end
    UIManager:nextTick(function()
        local ReaderUI = require("apps/reader/readerui")
        if ReaderUI.instance then log("orbit: closing reader because companion requested reopening the saved book") end
        ReaderUI:showReader(file)
        if screen == HomePlan.SERVER_HOME then
            UIManager:scheduleIn(2, function()
                log("restart: back to library Home, where the reader was")
                pcall(self.smartHome, self, "restart", nil, HomePlan.SERVER_HOME)
            end)
        end
    end)
end

-- :2521-2525). If anything is left over it, or the plugin lacks goDashboard: close the catalog
function OrbitAndroid:onOrbitGoHome() return HomeHost.show() end
function OrbitAndroid:finishHome()
    if state.pending_home then state.pending_home=nil;return HomeHost.show() end
end

function OrbitAndroid:whereNow()
    local ui = liveUI() or self.ui
    if HomeHost.foreground() then return HomePlan.SERVER_HOME end
    if ui and ui.document then return "reader" end
    return "browser"
end

-- The one-time "Setup needs you" box (SetupPrompt). where: given (the menu) or looked up.
function OrbitAndroid:maybeSetupPrompt(why, where)
    pcall(self.maybeRecommendedLine, self, where)
    if not Companion.has("setup") then return end
    where = where or self:whereNow()
    local prompt = Shared.setup_prompt
    local show, reason = SetupPrompt.decide(prompt, where, S.setup_prompt_shown)
    if prompt then log("setup box (" .. why .. "):", show and ("showing in " .. where) or ("not now, " .. reason)) end
    if not show then return end
    S.setup_prompt_shown = prompt.key
    saveSettings()
    UIManager:show(ConfirmBox:new{ -- gate: SetupPrompt.decide never shows it in a book
        text = _(SetupPrompt.text(prompt)),
        ok_text = _("Fix now"),
        cancel_text = _("Later"),
        ok_callback = function()
            local ok = Jni.startActivity{ action = Companion.ACTION.SHOW_SETUP, package = Companion.PACKAGE } -- gate: user action (setup box button)
            if not ok then ok = Jni.startActivity{ action = Companion.ACTION.SHOW_STATUS, package = Companion.PACKAGE } end -- gate: user action (setup box button)
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

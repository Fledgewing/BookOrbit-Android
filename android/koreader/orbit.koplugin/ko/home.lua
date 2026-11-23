-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

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
function topWidget()
    local okt, top = pcall(function() return UIManager:getTopmostVisibleWidget() end)
    return okt and top or nil
end

-- What is really showing, by identity with the plugin's catalog widget (never its flag alone:
-- plugin.catalog_browser stays set while the file browser or a book covers it).
function catalogOnTop(p)
    local cb = p and p.catalog_browser
    return cb ~= nil and topWidget() == cb
end

-- The topmost widget, named for the log: KOReader's own screens by identity, else its name,
-- title or (for a class instance) its class's name.
function widgetName(w, p)
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
function bookorbitScreen(p)
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
function catalogPage(cb)
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

function onDashboard(p)
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
function hasHandler(p, event)
    if p == nil then return false end
    local okv, v = pcall(function() return p["on" .. event] end)
    return okv and v ~= nil
end

-- Send a plugin event the way KOReader's dispatcher does (the plugin's public actions, e.g.
-- bookorbit_open_dashboard -> BookOrbitOpenDashboard, main.lua:987-988): through the live UI,
-- which passes it to its plugin modules. Without a UI that takes it, call the handler.
function pluginEvent(host, p, event, ...)
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
function checkDashboardOpened(p, why)
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
function closeWidget(w)
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

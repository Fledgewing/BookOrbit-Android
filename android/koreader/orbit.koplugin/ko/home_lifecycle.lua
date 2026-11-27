-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Existing restart and installation lifecycle, owned by the interface.
function patchFileVersion()
    if not SELF_PATH then return nil end
    local f = io.open(SELF_PATH, "rb")
    if not f then return nil end
    local head = f:read(8192)
    f:close()
    return RestartPlan.fileVersion("\n" .. (head or ""))
end


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
            Gate.show("restart ask", function() ServiceNotices.showInfo{ text = text, timeout = 6 } end) -- gate: Gate.show
        end
        return "ask"
    elseif act == "restart" then
        S.restart_tried = want
        saveSettings()
        self:restartForCompanion("v" .. tostring(want) .. " installed (" .. event .. ")")
    end
    return act
end


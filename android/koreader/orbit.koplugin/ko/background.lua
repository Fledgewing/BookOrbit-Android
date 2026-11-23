-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Network I/O off KOReader's UI thread. fn runs in a forked process: koreader-base
-- ffi/util.lua:350 runInSubProcess (with a pipe), the way KOReader's own Trapper runs
-- network lookups. The UI thread only polls it (isSubProcessDone :462, never waiting) and
-- reads the short result once the process has exited (readAllFromFD :558, EOF at once).
-- On timeout it is killed (terminateSubProcess :476). The child must not use JNI or the UI.
---------------------------------------------------------------------------------------------

Background = { POLL_S = 0.25 }

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

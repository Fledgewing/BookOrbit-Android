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
        if not okc then log(name .. ": failed in the background:", tostring(out)) end
        ffiutil.writeToFD(wfd, okc and tostring(out or "") or "", true)
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

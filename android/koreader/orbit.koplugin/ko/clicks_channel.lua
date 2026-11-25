-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- The /clicks channel: a kept-open loopback connection the companion writes
-- one line per action to. Its fd is added to KOReader's own ALooper (the one
-- ffi/input_android.lua waitForEvent polls), so a click wakes KOReader at once and nothing
-- polls. waitForEvent is wrapped to read the socket after every wake-up.
---------------------------------------------------------------------------------------------

Channel.IDENT, Channel.EVENT_INPUT = 20306, 1 -- our looper ident (KOReader uses 1-3); ALOOPER_EVENT_INPUT

function looper()
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
    Channel.proof, Channel.proven = nil, false
end

function Channel.onLine(line)
    -- Nothing counts before the proof line ("ORBIT <proof>"); a channel line before it, or another
    -- proof, means something else answered on the port.
    if not Channel.proven then
        local proof = line:match("^ORBIT%s+(%S+)")
        if proof and proof == Channel.proof then
            Channel.proven = true
            return false
        end
        if proof or line:match("^SETTINGS") or line:match("^SERVICE") or line:match("^CLICK") then
            Channel.close("it is not BookSync Companion")
        end
        return false
    end
    -- "SETTINGS <ms>": a setting changed in the companion; read /status now (companion-settings §4.5).
    local sat = line:match("^SETTINGS%s+(%d+)")
    if sat then
        UIManager:nextTick(function() pcall(Shared.refresh, "channel") end)
        return true
    end
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

wait_wrapped = false
function wrapWait()
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
    if Channel.up or not (Companion.has("clicker") or Companion.has("settings2")) then return Channel.up end
    local lp = looper()
    if not lp or not wrapWait() then return false end
    local oks, socket = pcall(require, "socket")
    if not oks or type(socket.tcp) ~= "function" then return false end
    -- The key opens the channel; the proof, the channel's first line, shows it is the companion.
    local keys = Jni.call(Companion.AUTHORITY, Companion.CLICKS, {})
    if not keys or keys.ok ~= "1" or not keys.key or not keys.proof then
        log("clicks: no channel (" .. why .. "): the companion gave no key")
        return false
    end
    local sock = socket.tcp()
    sock:settimeout(0.02) -- loopback only: never spend a second on the UI thread
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
    sock:send("GET /clicks?patch_version=" .. PATCH_VERSION .. "&key=" .. keys.key .. " HTTP/1.0\r\n\r\n")
    sock:settimeout(0)
    Channel.sock, Channel.fd, Channel.up, Channel.buf = sock, fd, true, ""
    Channel.proof, Channel.proven = keys.proof, false
    log("clicks: channel open (" .. why .. ")")
    return true
end

---------------------------------------------------------------------------------------------

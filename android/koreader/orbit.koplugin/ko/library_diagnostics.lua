-- SPDX-License-Identifier: AGPL-3.0-or-later
function Library.testSyncPath(done)
    local lines = {}
    local t0 = now_s()
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
        local text = table.concat(lines, "\n") .. "\n\n" .. string.format(_("Total %s."), fmt(now_s() - t0))
            .. "\n" .. _("Server requests run in BookSync Companion; saved changes are sent through its sync owner.")
        done(text)
    end

    local c0 = now_s()
    local cstate = Companion.state()
    if cstate == "ok" then
        local status = Companion.status(1)
        add(status ~= nil, _("Companion answered"), now_s() - c0,
            _("BookSync Companion is installed but did not answer: open it once."))
    elseif cstate == "frozen" then
        add(false, _("Companion answered"), nil, Companion.disabledText())
    else
        add(false, _("Companion answered"), nil, _("BookSync Companion is not installed: Wi-Fi stays as it is, Tailscale is woken directly."))
    end
    local was_on = Wifi.acquire("test")
    held = true
    if was_on == false then add(Companion.has("wifi"), _("Wi-Fi was off: turning it on for the test"), nil, Companion.problem()) end
    Net.up(nil, { reason = "test", cap = 20, need_server = true }, function(ok, res)
        add(res.wifi_s ~= nil, _("Wi-Fi connected"), res.wifi_s, _("Turn Wi-Fi on, or check BookSync Companion's Wi-Fi permission."))
        add(res.vpn_s ~= nil, _("Tailscale up"), res.vpn_s, _("Tailscale not connected: open Tailscale and sign in."))
        if not ok then return show() end
        local s0 = now_s()
        local reported = false
        local function plugin_done(err)
            if reported then return end
            reported = true
            add(err == nil, _("library plugin synced"), now_s() - s0,
                err and (_("The plugin reported: ") .. tostring(err)) or nil)
            show()
        end
        ReadingSync.run(inBook() and "manual" or "close",function(ok,why) plugin_done(not ok and (why or "delivery pending") or nil) end)
        UIManager:scheduleIn(60, function() plugin_done("timeout") end)
    end)
end

---------------------------------------------------------------------------------------------

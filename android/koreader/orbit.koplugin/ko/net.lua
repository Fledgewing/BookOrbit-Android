-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Network up: companion or Tailscale, then Wi-Fi, VPN and server, capped
---------------------------------------------------------------------------------------------

Net = { inflight = nil }

-- opts: reason, cap (s), need_server, wake_lock_s. cb(ok, res) with
-- res = { companion, wifi_s, vpn_s, server_s, elapsed, failed_at, detail }.
function Net.up(p, opts, cb)
    if not WifiPlan.shouldConnect(Shared.mode(), opts.reason, false) then
        return cb(false, { detail = "No network flow requested" })
    end
    if Net.inflight then
        log("network: joining running attempt (", Net.inflight.reason, ") for", opts.reason)
        table.insert(Net.inflight.waiters, cb)
        return
    end
    local cap = opts.cap or 20
    local flight = { reason = opts.reason, waiters = { cb } }
    Net.inflight = flight
    local t0 = now_s()
    -- The companion takes part when it switches Wi-Fi or holds the wake lock for sleep syncs;
    -- otherwise the plugin wakes Tailscale itself (docs/design/addon-mode.md §3).
    local res = { companion = Companion.has("wifi") or Companion.has("sleep_sync"), wifi_switch = Companion.has("wifi") }
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
        if ok and Mirror and Mirror.kick then Mirror.kick("network up") end
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
    if Jni.wifiEnabled() == false and not (res.wifi_switch and S.wifi_via_companion) then
        local why
        if Companion.state() == "frozen" then
            why = Companion.disabledText()
        elseif res.wifi_switch then
            why = "Wi-Fi is off and \"Wi-Fi via BookSync Companion\" is off"
        elseif Companion.installed() then
            why = "Wi-Fi is off and Wi-Fi switching is off in BookSync Companion"
        else
            why = "Wi-Fi is off and BookSync Companion isn't installed to turn it on"
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
        if el < cap and el >= next_probe then
            local remaining = cap - el
            -- A HEAD can wait on DNS/connect/read for seconds. Scheduling tick does not
            -- make that I/O asynchronous: run it in a child, including while reading.
            Background.run("network probe", function()
                local answered, code = probeServer(url, math.max(0.05, math.min(1.5, remaining)))
                return answered and tostring(code) or ""
            end, math.min(2, remaining), function(result)
                local after = now_s() - t0
                local code = tonumber(result)
                if code then
                    res.server_s = after
                    log("network: server answered", code, "after", fmt(after))
                    return finish(true)
                end
                log("network: server not answering yet at", fmt(after))
                next_probe = after + 1
                tick()
            end)
            return
        end
        if el >= cap then
            local stage = (S.wake_tailscale and not res.vpn_s) and "tailscale" or "server"
            return finish(false, stage, stage == "tailscale" and ("Tailscale didn't connect in " .. cap .. " s")
                or ("library didn't answer in " .. cap .. " s"))
        end
        UIManager:scheduleIn(0.5, tick)
    end
    tick()
end

---------------------------------------------------------------------------------------------

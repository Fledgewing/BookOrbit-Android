-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Wi-Fi modes (android/docs/DESIGN.md "Wi-Fi modes"). The companion does the switching and refuses an
-- automatic off when the user turned Wi-Fi on by hand; this plan only says *when* the patch
-- asks for on or off.
--   always_on    the user's Wi-Fi stays as it is; flows that had to turn it on put it back off
--   off_reading  a book opening turns Wi-Fi off; closing it restores what it was before
--   jit          off unless something needs it: off when a flow ends in a book, and after
--                idle_s with no network activity
WifiPlan = {
    MODES = {
        { id = "always_on",   label = "Always on" },
        { id = "off_reading", label = "Off while reading" },
        { id = "jit",         label = "Just in time" },
    },
    IDLE_MINUTES = { 1, 2, 5, 10 },
    GRACE = 3, -- seconds after the last flow ends before acting (lets the plugin start its follow-ups)
}

-- Shared with X4 core/WifiPolicy.h and fixtures/wifi/policy.json. Modes govern
-- release; every requested network flow may connect, while a saved view never does.
function WifiPlan.shouldConnect(mode, reason, saved)
    return not saved and type(reason) == "string" and reason ~= ""
end

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
    -- A fast companion command may finish before a second wake/open lease starts.
    -- Preserve ownership through the grace window; the companion still rejects auto-off
    -- if the reader has manually taken ownership of the radio in the meantime.
    if st.n == 0 and not (st.restore_off and st.release_at) then st.restore_off = (wifi_on == false) end
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

-- ctx = { now, wifi_on, busy, screen_off, browsing }. Returns action ("off" | nil), reason, force.
-- browsing: BookOrbit's catalog is on top (Home opens over the book): not reading, so the
-- "done in a book" offs wait; just in time's idle rule still applies.
-- force: off_reading's book-open off, which applies even to Wi-Fi turned on by hand.
-- Never off while a flow holds the network, the plugin or a download is busy, or (except
-- with the screen off) while another app is in front.
function WifiPlan.decide(st, ctx)
    if ctx.wifi_on == false then return nil, "already off" end
    if st.n > 0 then return nil, "in use" end
    if ctx.busy then return nil, "busy" end
    if not st.foreground and not ctx.screen_off then return nil, "KOReader not in front" end
    local released = st.release_at ~= nil and ctx.now >= st.release_at
    local in_book = st.in_book and not ctx.browsing
    if st.force_off_once and in_book and (released or st.release_at == nil) then
        return "off", "book opened (off while reading)", true
    end
    if released then
        if st.restore_off then return "off", "restore previous state (off) after " .. tostring(st.last_flow) end
        if in_book and st.mode ~= "always_on" then
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

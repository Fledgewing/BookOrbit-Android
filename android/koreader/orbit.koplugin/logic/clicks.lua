-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Clicker buttons (android/docs/BTKEYS-DESIGN.md): the companion's key map, handled inside KOReader.
-- Keys are Android keycodes (ev.code in Input:handleKeyBoardEv, frontend/device/input.lua:723).
---------------------------------------------------------------------------------------------

Clicks = { HOLD = 0.6, DOUBLE = 0.35, EPS = 1e-6, map = {} }
Clicks.ACTIONS = set("next prev home back light sync_sleep")
Clicks.KINDS = { "press", "hold", "double" }

-- /status "keymap": { ["87"] = { press = "next", hold = "sync_sleep" }, ... } -> keycode-keyed.
function Clicks.parse(keymap)
    local out = {}
    if type(keymap) ~= "table" then return out end
    for k, v in pairs(keymap) do
        local code = tonumber(k)
        if code and type(v) == "table" then
            local acts
            for _, kind in ipairs(Clicks.KINDS) do
                if Clicks.ACTIONS[v[kind]] then acts = acts or {}; acts[kind] = v[kind] end
            end
            out[code] = acts
        end
    end
    return out
end

-- Press/hold/double for one key, never blocking: feed down/up, call tick at nextDue. A key with
-- only "press" fires on key down (no delay); hold/double are timed only when mapped.
function Clicks.down(st, now, acts)
    if st.down_at then return nil end
    st.down_at, st.hold_fired = now, false
    local pending, late = st.single_due, false
    if pending then
        st.single_due = nil
        if acts.double and now <= pending then st.hold_fired = true return "double" end
        late = acts.press ~= nil
    end
    if not acts.hold and not acts.double then
        st.hold_fired = true
        return acts.press and "press" or nil
    end
    return late and "press" or nil
end

function Clicks.up(st, now, acts)
    local d = st.down_at
    if not d then return nil end
    st.down_at = nil
    if st.hold_fired then return nil end
    if acts.hold and now - d >= Clicks.HOLD - Clicks.EPS then return "hold" end
    if acts.double then st.single_due = now + Clicks.DOUBLE return nil end
    return acts.press and "press" or nil
end

function Clicks.nextDue(st, acts)
    if st.down_at and not st.hold_fired and acts.hold then return st.down_at + Clicks.HOLD end
    return st.single_due
end

function Clicks.tick(st, now, acts)
    if st.down_at and not st.hold_fired and acts.hold and now - st.down_at >= Clicks.HOLD - Clicks.EPS then
        st.hold_fired = true
        return "hold"
    end
    if st.single_due and now >= st.single_due - Clicks.EPS then
        st.single_due = nil
        return acts.press and "press" or nil
    end
    return nil
end

-- One interception path (v0.4.2, android/docs/BTKEYS-DESIGN.md "One path"): with the companion's
-- accessibility service on, it takes mapped keys in KOReader too and sends the action over the
-- /clicks channel. The patch's own key path is the fallback: on unless the channel is up and
-- the service on, so a key never turns two pages.
function Clicks.ownPath(channel_up, service_on)
    return not (channel_up and service_on)
end

-- A /clicks line: "CLICK next 12" -> "click", "next"; "SERVICE on" -> "service", true.
function Clicks.parseLine(line)
    local action = type(line) == "string" and line:match("^CLICK (%S+)")
    if action then return "click", Clicks.ACTIONS[action] and action or nil end
    local svc = type(line) == "string" and line:match("^SERVICE (%S+)")
    if svc then return "service", svc == "on" end
    return nil
end

---------------------------------------------------------------------------------------------

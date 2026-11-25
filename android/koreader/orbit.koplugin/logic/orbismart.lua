-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- OrbiSmart sync (docs/design/position-sync.md §3): which way a book's place moves, when a move is
-- shown, and whether a push may go. Pure: no KOReader modules. The table is
-- shared/fixtures/orbismart/cases.json; the Xteink's orbify::orbismart (xteink/orbify/core/
-- OrbiSmart.cpp) runs the same cases.
---------------------------------------------------------------------------------------------

OrbiSmart = {
    SKEW_S = 600, -- rule 6: R dated this far after the last turn here is a deliberate move elsewhere
    DECISIONS = { same = true, take = true, follow = true, push = true, hold = true, stay = true, override = true },
}

local function abs(x) return x < 0 and -x or x end

-- i: { local, server (nil = none), tolerance, server_at, marker = {at, place}, turn_at, reset,
-- redated, finished, released, declined_at, override = {at}, percent_only }.
-- Returns { decision, rule, dropped } (dropped: a queued override was dropped).
function OrbiSmart.decide(i)
    local L, R = tonumber(i["local"]) or 0, tonumber(i.server)
    local tol = tonumber(i.tolerance) or 1
    local M = type(i.marker) == "table" and i.marker or nil
    local at = tonumber(i.server_at) or 0
    local out = { dropped = false }
    local function done(decision, rule) out.decision, out.rule = decision, rule; return out end
    local moved = M ~= nil and R ~= nil and at ~= (tonumber(M.at) or 0) and not i.redated
    -- A queued "Read from here everywhere" goes first, unless reading elsewhere came after it.
    if type(i.override) == "table" then
        if moved and at > (tonumber(i.override.at) or 0) then
            out.dropped = true
        else
            return done("override", "override")
        end
    end
    if R == nil then return done("push", "no-server") end
    local declined = (tonumber(i.declined_at) or 0) ~= 0 and tonumber(i.declined_at) == at
    local function move(decision, rule)
        if declined then return done("stay", "declined") end
        return done(decision, rule)
    end
    if abs(L - R) <= tol then return done("same", "rule1") end
    if i.reset then return move("follow", "rule2") end
    if i.finished and L < R then
        return done(i.released and "push" or "hold", "rule7")
    end
    if R > L then return move("take", "rule3") end
    -- L is further.
    if not moved then return done("push", "rule4") end
    if i.percent_only then return done("push", "percent") end
    local read_here = abs(L - (tonumber(M.place) or 0)) > tol
    if not read_here then return move("follow", "rule5") end
    if at > (tonumber(i.turn_at) or 0) + OrbiSmart.SKEW_S then return move("follow", "rule6") end
    return done("push", "rule6")
end

-- When a move is shown, by the moment it was found (ruling 1): "now" (silently, before the page
-- rendered), "ask" (the Yes / No popup), "wake" (asked at the next wake), "no" (nothing to show).
function OrbiSmart.apply(decision, moment)
    if decision ~= "take" and decision ~= "follow" then return "no" end
    if moment == "prerender" then return "now" end
    if moment == "sleep" then return "wake" end
    if moment == "close" then return "no" end
    return "ask"
end

-- The behind-hold: a push behind the last known server place waits, except an override or a
-- released reread (exempt).
function OrbiSmart.mayPush(place, server, tolerance, exempt)
    if exempt or server == nil or place == nil then return true end
    return tonumber(place) >= tonumber(server) - (tonumber(tolerance) or 1)
end

local function num(v)
    if v == nil then return "none" end
    return string.format("%g", v)
end

-- The decision's log line: "orbismart: rule3 L=120 R=214 -> take (open, ask)".
function OrbiSmart.line(i, out, moment)
    local applied = OrbiSmart.apply(out.decision, moment)
    return string.format("orbismart: %s%s L=%s R=%s -> %s (%s, %s)", out.dropped and "override-dropped " or "",
        out.rule, num(i["local"]), num(i.server), out.decision, tostring(moment), applied)
end

-- The popup's question (ruling 1).
function OrbiSmart.question(device, page, decision)
    local where = string.format("Continue from %s, p. %s", tostring(device or "another device"), num(page))
    if decision == "follow" then return where .. " (moved back there)?" end
    return where .. "?"
end

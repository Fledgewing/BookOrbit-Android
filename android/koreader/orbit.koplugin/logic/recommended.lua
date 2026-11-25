-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Recommended settings (docs/design/addon-mode.md §5). Pure: the KOReader side
-- (ko/recommended.lua) observes each item and writes it; this file decides.
--
-- The rule, the same in every mode: an item still at its stock default is applied (with a
-- backup); an item the user changed is never overwritten, only listed for review; an item whose
-- plugin or capability is missing waits. A pass looks only at items no earlier pass settled
-- (new ids in a later release, or items that were unavailable), so a setting the user changes
-- by hand later is never changed back.
---------------------------------------------------------------------------------------------

Recommended = { REV = 1 }

-- kind: "bo" (the BookOrbit plugin's settings), "ko" (a KOReader global setting), "gesture" (a
-- KOReader gesture in books). needs: a companion capability (docs/design/addon-mode.md §6.1).
-- untouched_only: at default only when the pass finds KOReader untouched (no conflicts at all).
-- required_by: the capability that can't work without it (its conflict offers to turn that off).
Recommended.ITEMS = {
    { id = "bo.auto_sync", kind = "bo", key = "auto_sync", ours = true, label = "BookOrbit › Auto-sync" },
    { id = "bo.sync_forward", kind = "bo", key = "sync_forward", ours = Plan.STRATEGY.SILENT,
      label = "BookOrbit › When BookOrbit is further ahead" },
    { id = "bo.home", kind = "bo", key = "catalog_auto_open", ours = "home", label = "BookOrbit › Make BookOrbit home" },
    { id = "ko.wifi_on", kind = "ko", key = "wifi_enable_action", ours = "turn_on", stock = "prompt",
      needs = "wifi", required_by = "wifi", label = "KOReader › Action when Wi-Fi is off" },
    { id = "g.sync_sleep", kind = "gesture", key = "hold_top_right_corner", ours = { orbit_sync_and_sleep = true },
      label = "Gesture in books: hold top-right corner" },
    { id = "g.sync_all", kind = "gesture", key = "hold_top_left_corner", ours = { bookorbit_sync_now = true },
      label = "Gesture in books: hold top-left corner" },
    -- KOReader has no one-finger "swipe up from the bottom"; this bottom-edge swipe is the nearest.
    { id = "g.this_book", kind = "gesture", key = "one_finger_swipe_bottom_edge_right", ours = { bookorbit_this_book = true },
      label = "Gesture in books: swipe right along the bottom edge" },
    -- KOReader's default here is "brighter frontlight" on devices with a light (gestures defaults.lua:62).
    { id = "g.apps", kind = "gesture", key = "two_finger_swipe_north", ours = { orbit_open_apps = true }, needs = "apps",
      label = "Gesture in books: two-finger swipe up" },
}

function Recommended.item(id)
    for _, it in ipairs(Recommended.ITEMS) do if it.id == id then return it end end
end

-- Deep equality, nil-safe (util.tableEquals semantics, gestures.koplugin main.lua:310-312).
function Recommended.equal(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do if not Recommended.equal(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

function Recommended.copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = Recommended.copy(x) end
    return out
end

-- obs: { current, default, stock } (stock: another value KOReader treats as its default).
-- Returns "already" | "at_default" | "conflict".
function Recommended.classify(item, obs)
    if Recommended.equal(obs.current, item.ours) then return "already" end
    if Recommended.equal(obs.current, obs.default) then return "at_default" end
    if item.stock ~= nil and Recommended.equal(obs.current, item.stock) then return "at_default" end
    return "conflict"
end

-- Items a pass looks at: never settled, or unavailable last time. only: { [id] = true } or nil.
function Recommended.candidates(items, record, only)
    local seen = type(record) == "table" and type(record.items) == "table" and record.items or {}
    local out = {}
    for _, it in ipairs(items) do
        local st = seen[it.id]
        if (st == nil or st == "unavailable") and (not only or only[it.id]) then table.insert(out, it) end
    end
    return out
end

-- observe(item) -> { available = bool, reason, current, default }. Returns
-- { decisions = { { item, state, obs } }, applied = n, conflicts = n, unavailable = n }.
-- The mode is not an input: the same KOReader gives the same plan in every mode.
function Recommended.plan(items, record, observe, only)
    local out = { decisions = {}, applied = 0, conflicts = 0, unavailable = 0 }
    local later = {}
    local function decide(it, state, obs)
        table.insert(out.decisions, { item = it, state = state, obs = obs })
        if state == "at_default" then out.applied = out.applied + 1
        elseif state == "conflict" then out.conflicts = out.conflicts + 1
        elseif state == "unavailable" then out.unavailable = out.unavailable + 1 end
    end
    for _, it in ipairs(Recommended.candidates(items, record, only)) do
        local obs = observe(it) or { available = false, reason = "unknown" }
        if not obs.available then decide(it, "unavailable", obs)
        else
            local state = Recommended.classify(it, obs)
            if it.untouched_only and state == "at_default" then table.insert(later, { it, obs })
            else decide(it, state, obs) end
        end
    end
    -- An item with no stock default of its own: at default only on a KOReader with no changed
    -- values at all (this pass's conflicts, or any the user kept before).
    local touched = out.conflicts > 0
    local seen = type(record) == "table" and type(record.items) == "table" and record.items or {}
    for _, st in pairs(seen) do if st == "conflict" or st == "kept" then touched = true end end
    for _, l in ipairs(later) do decide(l[1], touched and "conflict" or "at_default", l[2]) end
    return out
end

local STATUS = { at_default = "applied", already = "already", conflict = "conflict", unavailable = "unavailable" }

-- The record after a plan: S.recommended = { rev, at, items = { [id] = status }, unseen }.
-- applied_ok: { [id] = false } for an apply that failed (it stays unavailable).
function Recommended.record(record, plan, now, applied_ok)
    record = type(record) == "table" and record or {}
    record.items = type(record.items) == "table" and record.items or {}
    record.rev, record.at = Recommended.REV, now
    local applied = 0
    for _, d in ipairs(plan.decisions) do
        local st = STATUS[d.state]
        if d.state == "at_default" and applied_ok and applied_ok[d.item.id] == false then st = "unavailable"
        elseif d.state == "at_default" then applied = applied + 1 end
        record.items[d.item.id] = st
    end
    record.unseen = (record.unseen or 0) + applied
    return record, applied
end

-- The backup kept before an apply (S.recommended_backup[id]).
function Recommended.backup(obs, item, now)
    return { had = obs.current ~= nil, prior = Recommended.copy(obs.current), ours = Recommended.copy(item.ours), at = now }
end

-- Undo restores the prior value only while the current one is still ours.
function Recommended.undoable(entry, current)
    return type(entry) == "table" and Recommended.equal(current, entry.ours)
end

-- Counts of each status in the record.
function Recommended.counts(record)
    local c = { applied = 0, already = 0, conflict = 0, kept = 0, unavailable = 0 }
    local items = type(record) == "table" and type(record.items) == "table" and record.items or {}
    for _, st in pairs(items) do c[st] = (c[st] or 0) + 1 end
    return c
end

-- For the companion's row (REPORT recommended=): none (no pass yet), partial (conflicts to
-- review), reviewed (the user kept some of theirs), applied.
function Recommended.reportState(record)
    if type(record) ~= "table" or type(record.items) ~= "table" or next(record.items) == nil then return "none" end
    local c = Recommended.counts(record)
    if c.conflict > 0 then return "partial" end
    if c.kept > 0 then return "reviewed" end
    return "applied"
end

-- The one line: "Applied 7 recommended settings · Review", "Applied 4 · 2 to review",
-- "Review 2 recommended settings", or nil (nothing to say).
function Recommended.lineText(applied, conflicts)
    applied, conflicts = applied or 0, conflicts or 0
    if applied > 0 and conflicts > 0 then return string.format("Applied %d · %d to review", applied, conflicts) end
    if applied > 0 then
        return string.format(applied == 1 and "Applied %d recommended setting · Review" or "Applied %d recommended settings · Review", applied)
    end
    if conflicts > 0 then
        return string.format(conflicts == 1 and "Review %d recommended setting" or "Review %d recommended settings", conflicts)
    end
    return nil
end

-- Items to undo when capabilities go away (Full → Add-on): applied by Orbit, needing a cap now lost.
function Recommended.lostCaps(record, has)
    local out = {}
    local items = type(record) == "table" and type(record.items) == "table" and record.items or {}
    for _, it in ipairs(Recommended.ITEMS) do
        if it.needs and items[it.id] == "applied" and not has(it.needs) then table.insert(out, it) end
    end
    return out
end

-- Plain words for a value (the review page).
local LABELS = {
    auto_sync = function(v) return v and "On" or "Off" end,
    sync_forward = function(v) return ({ [1] = "Ask", [2] = "Silent", [3] = "Don't sync" })[v] or tostring(v) end,
    catalog_auto_open = function(v)
        return ({ off = "Off", filemanager = "File browser", home = "BookOrbit home" })[v] or tostring(v)
    end,
    wifi_enable_action = function(v) return ({ turn_on = "Turn on", prompt = "Ask", ignore = "Ignore" })[v or "prompt"] or tostring(v) end,
}
local ACTIONS = {
    orbit_sync_and_sleep = "BookSync: Sync and sleep", bookorbit_sync_now = "BookOrbit: sync all books",
    bookorbit_this_book = "BookOrbit: this book", orbit_open_apps = "BookSync: other apps",
    increase_frontlight = "Brighter frontlight", toggle_page_flipping = "Page flipping",
}
function Recommended.valueLabel(item, v)
    if item.kind == "gesture" then
        if type(v) ~= "table" or next(v) == nil then return "Nothing" end
        local names = {}
        for k in pairs(v) do table.insert(names, ACTIONS[k] or k) end
        table.sort(names)
        return table.concat(names, " + ")
    end
    local f = LABELS[item.key]
    if f then return f(v) end
    return tostring(v)
end

---------------------------------------------------------------------------------------------

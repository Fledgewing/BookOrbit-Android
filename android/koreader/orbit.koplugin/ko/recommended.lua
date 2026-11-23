-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Recommended settings, applied by themselves at setup and on updates (docs/design/addon-mode.md
-- §5; the decisions are logic/recommended.lua's). This side reads and writes each item, keeps
-- the backup (S.recommended_backup) and shows the line and the review page.
---------------------------------------------------------------------------------------------

Rec = { session_applied = 0, line_pending = false }

-- What a pass reads: the BookOrbit plugin, KOReader's Gestures plugin (it may be off).
function Rec.context(ui)
    ui = liveUI() or ui
    return { p = bookorbit(ui), gestures = ui and ui.gestures or nil }
end

-- KOReader's stock gesture defaults in books: the Gestures plugin keeps defaults.lua as
-- Gestures.default_settings (gestures.koplugin main.lua:229), read the way it marks "(default)"
-- (main.lua:249, :310-312), so device-dependent defaults (a frontlight) come out right.
local function gestureDefaults(g)
    local ds = g and g.default_settings
    local data = type(ds) == "table" and ds.data or nil
    return type(data) == "table" and type(data.gesture_reader) == "table" and data.gesture_reader or nil
end

-- { available, reason, current, default } for one item.
-- raw: read the value even when the item's capability is missing (Undo after a cap went away).
function Rec.observe(it, ctx, raw)
    if it.needs and not raw and not Companion.has(it.needs) then
        return { available = false, reason = Rec.capReason(it.needs) }
    end
    if it.kind == "bo" then
        local p = ctx.p
        if not p or type(p.settings) ~= "table" then return { available = false, reason = _("needs the BookOrbit plugin") } end
        local defaults = p.default_settings
        if type(defaults) ~= "table" then return { available = false, reason = _("BookOrbit changed: its defaults can't be read") } end
        if it.key == "catalog_auto_open" and not Compat.settable(p.settings, it.key, it.ours) then
            return { available = false, reason = _("BookOrbit changed: Make BookOrbit home") }
        end
        if it.key == "auto_sync" and not hasHandler(p, "BookOrbitToggleAutoSync") then
            return { available = false, reason = _("BookOrbit changed: Auto-sync can't be turned on") }
        end
        return { available = true, current = p.settings[it.key], default = defaults[it.key] }
    elseif it.kind == "ko" then
        if it.required_by == "wifi" and not S.wifi_via_companion and not raw then
            return { available = false, reason = _("needs Wi-Fi via Orbit Companion") }
        end
        return { available = true, current = G_reader_settings:readSetting(it.key), default = nil }
    elseif it.kind == "gesture" then
        local g = ctx.gestures
        local defaults = gestureDefaults(g)
        if not g or type(g.data) ~= "table" or not defaults then
            return { available = false, reason = _("Turn on KOReader's Gestures plugin") }
        end
        local mine = type(g.data.gesture_reader) == "table" and g.data.gesture_reader or {}
        return { available = true, current = mine[it.key], default = defaults[it.key] }
    end
    return { available = false, reason = "unknown item" }
end

function Rec.capReason(cap)
    if not Companion.installed() then return _("needs Orbit Companion") end
    if cap == "wifi" then return _("needs Wi-Fi switching in Orbit Companion") end
    if cap == "apps" then return _("needs Full mode in Orbit Companion") end
    return _("needs Orbit Companion")
end

-- Write one item. value nil: back to unset. Returns true when the value took.
function Rec.write(it, ctx, value)
    if it.kind == "bo" then
        local p = ctx.p
        if not p then return false end
        if it.key == "auto_sync" then
            -- The plugin's own toggle also registers its reader events (main.lua:1416-1448).
            if (p.settings.auto_sync == true) ~= (value == true) then
                pluginEvent(liveUI(), p, "BookOrbitToggleAutoSync", value == true, true, true)
            end
        else
            -- Saved the way the plugin's own settings page saves (bookorbit_settings_page.lua:822-825).
            p.settings[it.key] = Recommended.copy(value)
        end
        G_reader_settings:flush()
        return Recommended.equal(p.settings[it.key], value)
    elseif it.kind == "ko" then
        if value == nil and G_reader_settings.delSetting then G_reader_settings:delSetting(it.key)
        else G_reader_settings:saveSetting(it.key, value) end
        return Recommended.equal(G_reader_settings:readSetting(it.key), value)
    elseif it.kind == "gesture" then
        local g = ctx.gestures
        if not g or type(g.data) ~= "table" then return false end
        -- The same write path the plugin uses for its shortcut (bookorbit_shortcut.lua:111-117).
        g.data.gesture_reader = g.data.gesture_reader or {}
        g.data.gesture_reader[it.key] = Recommended.copy(value)
        g.updated = true
        if g.onFlushSettings then g:onFlushSettings() end
        return true
    end
    return false
end

function Rec.saveRecord(record)
    S.recommended = record
    S.recommended_backup = S.recommended_backup or {}
    saveSettings()
end

-- One pass (§5.3): looks only at items no pass settled. only: { [id] = true } (the load-time pass
-- for KOReader's Wi-Fi action). Returns the plan.
function Rec.pass(why, ui, only)
    local ctx = Rec.context(ui)
    local plan = Recommended.plan(Recommended.ITEMS, S.recommended, function(it) return Rec.observe(it, ctx) end, only)
    if #plan.decisions == 0 then return plan end
    S.recommended_backup = S.recommended_backup or {}
    local okmap = {}
    for _i, d in ipairs(plan.decisions) do
        if d.state == "at_default" then
            local entry = Recommended.backup(d.obs, d.item, os.time())
            local okw, took = pcall(Rec.write, d.item, ctx, d.item.ours)
            if okw and took then
                S.recommended_backup[d.item.id] = entry
            else
                okmap[d.item.id] = false
                log("recommended:", d.item.id, "could not be applied:", tostring(took))
            end
        end
    end
    local record, applied = Recommended.record(S.recommended, plan, os.time(), okmap)
    Rec.saveRecord(record)
    Rec.session_applied = Rec.session_applied + applied
    if applied > 0 then Rec.line_pending = true end
    local parts = {}
    for _i, d in ipairs(plan.decisions) do
        table.insert(parts, d.item.id .. "=" .. (record.items[d.item.id] or "?") .. (d.obs.reason and ("(" .. d.obs.reason .. ")") or ""))
    end
    log("recommended (" .. why .. "): applied", applied, "| to review", plan.conflicts, "|", table.concat(parts, " "))
    if why ~= "load" then pcall(Rec.report, "recommended " .. why, false, ui) end
    return plan
end

-- The line for the menu and the toast, from the record: unseen applied + conflicts waiting.
function Rec.line()
    local c = Recommended.counts(S.recommended)
    return Recommended.lineText(type(S.recommended) == "table" and S.recommended.unseen or 0, c.conflict)
end

-- After a pass that changed something: the line for 4 s, off a book only (§5.4). In a book it
-- waits for the next off-book moment (Home, the menu, the setup box's checks).
function OrbitAndroid:maybeRecommendedLine(where)
    if not Rec.line_pending then return end
    where = where or self:whereNow()
    if where == "reader" then return end
    local text = Rec.line()
    Rec.line_pending = false
    if not text then return end
    log("recommended: line shown in " .. where .. ": " .. text)
    orbitNote(_(text) .. " · " .. _("Tools › Android sync › Recommended settings"), 4)
end

-- Start: a pass once the BookOrbit plugin instance can be found (module.lua's next-tick fallback).
function OrbitAndroid:recommendedPass(why)
    local okp, err = pcall(Rec.pass, why, self.ui)
    -- The first report of this process, changed or not: the companion may have been updated.
    pcall(Rec.report, why, true, self.ui)
    if not okp then log("recommended: pass failed:", tostring(err)) return end
    self:maybeRecommendedLine()
end

---------------------------------------------------------------------------------------------
-- Review page (§5.5): To review (Use Orbit's / Keep mine), Applied (with Undo), Kept yours,
-- Unavailable; Use all of Orbit's, Keep all mine, Undo all.
---------------------------------------------------------------------------------------------

local function setStatus(id, st)
    S.recommended = S.recommended or { rev = Recommended.REV, items = {} }
    S.recommended.items = S.recommended.items or {}
    S.recommended.items[id] = st
    saveSettings()
end

-- "Use Orbit's" on a conflict or a kept item: apply with a backup.
function Rec.useOrbits(it, ctx)
    local obs = Rec.observe(it, ctx)
    if not obs.available then return false, obs.reason end
    local entry = Recommended.backup(obs, it, os.time())
    local okw, took = pcall(Rec.write, it, ctx, it.ours)
    if not (okw and took) then return false, tostring(took) end
    S.recommended_backup = S.recommended_backup or {}
    S.recommended_backup[it.id] = entry
    setStatus(it.id, "applied")
    log("recommended:", it.id, "Use Orbit's")
    return true
end

function Rec.keepMine(it)
    setStatus(it.id, "kept")
    log("recommended:", it.id, "Keep mine")
end

-- Undo one applied item. Returns "undone" | "changed" (the user changed it since; left as is).
function Rec.undo(it, ctx)
    local entry = (S.recommended_backup or {})[it.id]
    local current = Rec.observe(it, ctx, true).current
    if not Recommended.undoable(entry, current) then
        setStatus(it.id, "kept")
        log("recommended:", it.id, "undo: changed since; left as is")
        return "changed"
    end
    pcall(Rec.write, it, ctx, entry.had and entry.prior or nil)
    S.recommended_backup[it.id] = nil
    setStatus(it.id, "kept")
    log("recommended:", it.id, "undone (back to", Recommended.valueLabel(it, entry.prior) .. ")")
    return "undone"
end

-- Capabilities went away (Full → Add-on, §8 step 4): undo what needed them, if Orbit set it.
function Rec.capsLost(why, ui)
    local ctx = Rec.context(ui)
    for _i, it in ipairs(Recommended.lostCaps(S.recommended, Companion.has)) do
        local r = Rec.undo(it, ctx)
        -- Unavailable again, so the pass re-offers it if the capability comes back.
        setStatus(it.id, "unavailable")
        log("recommended:", it.id, "capability", it.needs, "gone (" .. why .. "):", r)
    end
end

-- KOReader's Wi-Fi action while Wi-Fi switching is on: switching can't work without it.
local function wifiNeeded(it) return it.required_by == "wifi" and S.wifi_via_companion and Companion.has("wifi") end

function OrbitAndroid:showRecommended(why)
    local ctx = Rec.context(self.ui)
    if type(S.recommended) == "table" and (S.recommended.unseen or 0) > 0 then
        S.recommended.unseen = 0
        saveSettings()
    end
    log("recommended: review page (" .. tostring(why) .. ")")
    local items = {}
    local status = type(S.recommended) == "table" and S.recommended.items or {}
    local function reopen()
        if self.rec_menu then UIManager:close(self.rec_menu); self.rec_menu = nil end
        UIManager:scheduleIn(0.1, function() self:showRecommended("refresh") end)
    end
    local function note(text) UIManager:show(InfoMessage:new{ text = text, timeout = 3 }) end -- gate: user action (Recommended settings menu)
    local function dialog(title, buttons)
        local ButtonDialog = require("ui/widget/buttondialog")
        local d
        local row = {}
        for _i, b in ipairs(buttons) do
            table.insert(row, { text = b[1], callback = function() UIManager:close(d); b[2]() end })
        end
        d = ButtonDialog:new{ title = title, buttons = { row } }
        UIManager:show(d) -- gate: user action (Recommended settings menu)
        return d
    end
    local groups = { conflict = {}, applied = {}, already = {}, kept = {}, unavailable = {} }
    for _i, it in ipairs(Recommended.ITEMS) do
        local st = status[it.id]
        if groups[st] then table.insert(groups[st], it) end
    end
    local function cur(it)
        local obs = Rec.observe(it, ctx)
        return obs.available and Recommended.valueLabel(it, obs.current) or nil, obs
    end
    local function header(text) table.insert(items, { text = text, bold = true, dim = false, callback = function() end }) end
    if #groups.conflict > 0 then
        header(_("To review"))
        table.insert(items, { text = _("Use all of Orbit's"), callback = function()
            for _i, it in ipairs(groups.conflict) do Rec.useOrbits(it, ctx) end
            Rec.report("review"); reopen()
        end })
        table.insert(items, { text = _("Keep all mine"), callback = function()
            for _i, it in ipairs(groups.conflict) do
                if wifiNeeded(it) then S.wifi_via_companion = false; saveSettings() end
                Rec.keepMine(it)
            end
            Rec.report("review"); reopen()
        end })
        for _i, it in ipairs(groups.conflict) do
            local yours = cur(it) or "?"
            local orbit = Recommended.valueLabel(it, it.ours)
            table.insert(items, { text = _(it.label), mandatory = string.format(_("yours: %s · Orbit's: %s"), yours, orbit),
                callback = function()
                    local keep = { _("Keep mine"), function() Rec.keepMine(it); Rec.report("review"); reopen() end }
                    if wifiNeeded(it) then
                        keep = { _("Turn Wi-Fi switching off"), function()
                            S.wifi_via_companion = false; saveSettings()
                            log("recommended: Wi-Fi via Orbit Companion turned off (kept KOReader's Wi-Fi action)")
                            Rec.keepMine(it); Rec.report("review"); reopen()
                        end }
                    end
                    dialog(_(it.label) .. "\n" .. (wifiNeeded(it) and _("Wi-Fi switching needs this.") .. "\n" or ""), {
                        { _("Use Orbit's"), function()
                            local okd, why2 = Rec.useOrbits(it, ctx)
                            if not okd then note(tostring(why2)) end
                            Rec.report("review"); reopen()
                        end },
                        keep,
                    })
                end })
        end
    end
    if #groups.applied + #groups.already > 0 then
        header(_("Applied"))
        for _i, it in ipairs(groups.applied) do
            local entry = (S.recommended_backup or {})[it.id]
            local was = entry and Recommended.valueLabel(it, entry.prior) or "?"
            table.insert(items, { text = _(it.label), mandatory = string.format(_("%s (was: %s)"), Recommended.valueLabel(it, it.ours), was),
                callback = function()
                    dialog(_(it.label), { { _("Undo"), function()
                        local function go()
                            local r = Rec.undo(it, ctx)
                            if r == "changed" then note(_("Changed since; left as is.")) end
                            Rec.report("review"); reopen()
                        end
                        if wifiNeeded(it) then
                            UIManager:show(ConfirmBox:new{ -- gate: user action (Recommended settings menu)
                                text = _("Wi-Fi switching needs this. Turn off Wi-Fi via Orbit Companion and undo?"),
                                ok_text = _("Turn off and undo"),
                                ok_callback = function() S.wifi_via_companion = false; saveSettings(); go() end,
                            })
                        else go() end
                    end } })
                end })
        end
        for _i, it in ipairs(groups.already) do
            table.insert(items, { text = _(it.label), mandatory = Recommended.valueLabel(it, it.ours), dim = true, callback = function() end })
        end
    end
    if #groups.kept > 0 then
        header(_("Kept yours"))
        for _i, it in ipairs(groups.kept) do
            table.insert(items, { text = _(it.label), mandatory = cur(it) or "",
                callback = function()
                    dialog(_(it.label), { { _("Use Orbit's"), function()
                        local okd, why2 = Rec.useOrbits(it, ctx)
                        if not okd then note(tostring(why2)) end
                        Rec.report("review"); reopen()
                    end } })
                end })
        end
    end
    if #groups.unavailable > 0 then
        header(_("Unavailable"))
        for _i, it in ipairs(groups.unavailable) do
            local _v, obs = cur(it)
            table.insert(items, { text = _(it.label), mandatory = obs.reason or "", dim = true, callback = function() end })
        end
    end
    if #groups.applied > 0 then
        table.insert(items, { text = _("Undo all"), callback = function()
            local skipped = false
            for _i, it in ipairs(groups.applied) do
                if wifiNeeded(it) then skipped = true else Rec.undo(it, ctx) end
            end
            if skipped then note(_("KOReader's Wi-Fi action stays: Wi-Fi switching needs it.")) end
            Rec.report("review"); reopen()
        end })
    end
    if #items == 0 then
        table.insert(items, { text = _("No recommended settings yet. They are applied at the next start."), callback = function() end })
    end
    table.insert(items, { text = _("Done"), callback = function()
        if self.rec_menu then UIManager:close(self.rec_menu); self.rec_menu = nil end
    end })
    local Menu = require("ui/widget/menu")
    self.rec_menu = Menu:new{
        title = _("Recommended settings"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        close_callback = function() if self.rec_menu then UIManager:close(self.rec_menu); self.rec_menu = nil end end,
    }
    UIManager:show(self.rec_menu) -- gate: user action (Recommended settings menu)
    return self.rec_menu
end

-- The menu row: "Recommended settings" with the line while there is something to say.
function OrbitAndroid:recommendedMenuText()
    local line = Rec.line()
    return line and (_("Recommended settings: ") .. _(line)) or _("Recommended settings")
end

-- REPORT to the companion (docs/design/addon-mode.md §7.3): one yes/no about the BookOrbit
-- login (isLoggedIn, never the server, the account or the key), the recommended settings'
-- state and how many wait for review. Sent at start, after a pass or a review change, and
-- whenever the answer changed (checked on each refresh: start, resume, menu). force: send even
-- when unchanged.
function Rec.reportFields(ui)
    local p = bookorbit(liveUI() or ui)
    local signed = nil
    if p then
        local okl, v = pcall(p.isLoggedIn, p)
        if okl then signed = v and "1" or "0" end
    end
    return {
        signed_in = signed or "",
        recommended = Recommended.reportState(S.recommended),
        conflicts = tostring(Recommended.counts(S.recommended).conflict),
    }
end

function Rec.report(why, force, ui)
    if not Companion.installed() then return end
    local f = Rec.reportFields(ui)
    local key = f.signed_in .. "|" .. f.recommended .. "|" .. f.conflicts
    if not force and Rec.last_report == key then return end
    Rec.last_report = key
    f.reason = why
    Companion.send(Companion.ACTION.REPORT, f)
end

-- KOReader's "Action when Wi-Fi is off" → Turn on, at load (before any UI): with the companion
-- switching Wi-Fi, KOReader asks for Wi-Fi without a prompt. Through the engine: applied only
-- at KOReader's default, with a backup; a value the user chose is listed for review instead.
function silentWifiOn()
    local okp, err = pcall(Rec.pass, "load", nil, { ["ko.wifi_on"] = true })
    if not okp then log("recommended: load pass failed:", tostring(err)) end
end

---------------------------------------------------------------------------------------------

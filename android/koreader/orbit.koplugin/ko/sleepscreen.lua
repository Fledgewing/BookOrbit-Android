-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Sleep menu and native reader hook. All state/work is behind Library.sleep.
local base_ready = OrbitAndroid.onReaderReady
function OrbitAndroid:onReaderReady(...)
    local ui = self.ui
    UIManager:scheduleIn(3, function()
        local okw, err = pcall(Library.sleep.writeCurrent, ui, "book opened")
        if not okw then log("sleep screen: current cover failed:", tostring(err)) end
    end)
    return base_ready(self, ...)
end

---------------------------------------------------------------------------------------------

local function radios(list, key, after)
    local out = {}
    for _i, o in ipairs(list) do
        local id = type(o) == "table" and o.id or o
        table.insert(out, {
            text = type(o) == "table" and _(o.label) or _(SleepPool.hoursLabel(o)),
            radio = true,
            checked_func = function() return Library.sleep.settings()[key] == id end,
            callback = function() Library.sleep.set(key, id); if after then after(id) end end,
        })
    end
    return out
end

local function info(text_func)
    return { text_func = text_func, keep_menu_open = true, callback = function() end }
end

-- The lists and collections, as menu rows; pick(key) on a tap; checked(key): ticked (a set).
local function scopeRows(pick, checked)
    return function()
        local rows = {}
        -- The saved lists at once; a fresh copy is fetched behind them for the next open.
        local got = Library.sleep.scopes()
        local fetching = Library.sleep.refreshScopes("picker")
        if not got then
            return { info(function()
                return fetching and _("Loading the lists and collections… open this again in a moment.")
                    or _("No saved list of lists and collections yet: connect, then open this again.")
            end) }
        end
        local function add(title, list, kind)
            table.insert(rows, info(function() return title end))
            if #list == 0 then table.insert(rows, info(function() return _("  none") end)) end
            for _i, e in ipairs(list) do
                local key = kind .. ":" .. e.id
                table.insert(rows, {
                    text = e.count and string.format("%s · %d", e.title, e.count) or e.title,
                    checked_func = checked and function() return checked(key) end or nil,
                    keep_menu_open = checked ~= nil,
                    callback = function() pick(key) end,
                })
            end
        end
        if got.libraries and #got.libraries > 0 then add(_("Libraries"), got.libraries, "library") end
        add(_("Lists"), got.scopes or {}, "scope")
        add(_("Collections"), got.collections or {}, "collection")
        return rows
    end
end

local function addRule(rule)
    local list = {}
    for _i, r in ipairs(Library.sleep.settings().sleep_leave_out) do table.insert(list, r) end
    table.insert(list, rule)
    Library.sleep.set("sleep_leave_out", SleepPool.decodeRules(list))
end

local function removeRule(rule)
    local list = {}
    for _i, r in ipairs(Library.sleep.settings().sleep_leave_out) do if r ~= rule then table.insert(list, r) end end
    Library.sleep.set("sleep_leave_out", list)
end

-- A one-line input (Text…, Type a tag…). done(text) on Save.
local function askText(title, value, hint, done)
    local okd, InputDialog = pcall(require, "ui/widget/inputdialog")
    if not okd then return end
    local dialog
    dialog = InputDialog:new{
        title = title, input = value or "", input_hint = hint,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local v = dialog:getInputText()
                UIManager:close(dialog)
                done(v)
            end },
        } },
    }
    UIManager:show(dialog) -- gate: user action (menu)
    pcall(dialog.onShowKeyboard, dialog)
end

function Library.sleep.menuItem(_plugin, later)
    if not Library.companion.installed() then return false end
    if not Library.sleep.available() then
        return info(function() return _("Sleep screen: needs a newer BookSync Companion") end)
    end
    local function rec() return Library.sleep.settings().sleep_mode == "recommended" end
    local function overlay() return Library.sleep.settings().sleep_style == "overlay" end
    -- Pick from is a set (R1c): each item ticks on and off; Library stands alone.
    local function picked(id)
        for _i, it in ipairs(SleepPool.sources(Library.sleep.settings().sleep_from)) do if it == id then return true end end
        return false
    end
    local function togglePick(id)
        Library.sleep.set("sleep_from", SleepPool.togglePick(Library.sleep.settings().sleep_from, id))
    end
    local from_items = {
        { text = _("Whole library OR pick sources"), checked_func = function() return picked(SleepPool.LIBRARY) end,
            keep_menu_open = true, callback = function() togglePick(SleepPool.LIBRARY) end, separator = true },
    }
    for _i, l in ipairs(SleepPool.LISTS) do
        table.insert(from_items, { text = _(l.label), checked_func = function() return picked(l.id) end,
            keep_menu_open = true, callback = function() togglePick(l.id) end })
    end
    table.insert(from_items, {
        text_func = function()
            local n = 0
            for _i, it in ipairs(SleepPool.sources(Library.sleep.settings().sleep_from)) do
                local p = SleepPool.parseFrom(it)
                if p and (p.kind == "scope" or p.kind == "collection") then n = n + 1 end
            end
            return _("Libraries, lists and collections…") .. (n > 0 and string.format(" (%d)", n) or "")
        end,
        sub_item_table_func = scopeRows(togglePick, picked),
    })
    local function leaveOutItems()
        local rows = {}
        for _i, r in ipairs(Library.sleep.settings().sleep_leave_out) do
            table.insert(rows, { text = Library.sleep.ruleLabel(r) .. _(" · tap to remove"), callback = function() removeRule(r) end })
        end
        if #rows == 0 then table.insert(rows, info(function() return _("No rules: every cover can show.") end)) end
        rows[#rows].separator = true
        table.insert(rows, {
            text = _("Add a rule: Tag…"),
            sub_item_table_func = function()
                local out = {}
                -- The saved list at once; the companion counts again behind it for the next open.
                local tags = Library.sleep.tags()
                local fetching = Library.sleep.refreshScopes("tag picker")
                for _i, t in ipairs(tags or {}) do
                    table.insert(out, { text = string.format("%s · %d", t.label, t.count), callback = function() addRule("tag:" .. t.tag) end })
                    if #out >= 60 then break end
                end
                if not tags then
                    table.insert(out, info(function()
                        return fetching and _("Counting the tags in the saved books… open this again in a moment.")
                            or _("No tags counted yet: connect, then open this again.")
                    end))
                end
                table.insert(out, 1, { text = _("Type a tag…"), separator = true, callback = later(function()
                    askText(_("Leave out books with the tag"), "", _("e.g. age:18"), function(v)
                        local p = SleepPool.parseRule("tag:" .. tostring(v or ""))
                        if p then addRule(p.key) end
                    end)
                end) })
                return out
            end,
        })
        local function hasRule(key)
            for _i, r in ipairs(Library.sleep.settings().sleep_leave_out) do if r == key then return true end end
            return false
        end
        local function toggleRule(key) if hasRule(key) then removeRule(key) else addRule(key) end end
        table.insert(rows, { text = _("Add a rule: Library, list or collection…"),
            sub_item_table_func = scopeRows(toggleRule, hasRule) })

        table.insert(rows, info(function()
            return _("For a custom field: make a list with that condition in library, then add it here.")
        end))
        return rows
    end
    return {
        text = _("Sleep screen"),
        sub_item_table_func = function()
            return {
                {
                    text_func = function() return _("Sleep screen: ") .. _(SleepPool.label(SleepPool.MODES, Library.sleep.settings().sleep_mode)) end,
                    sub_item_table = radios(SleepPool.MODES, "sleep_mode"),
                },
                {
                    text_func = function() return _("Pick from: ") .. Library.sleep.fromLabel(Library.sleep.settings().sleep_from) end,
                    enabled_func = rec,
                    sub_item_table = from_items,
                },
                {
                    text_func = function()
                        local n = #Library.sleep.settings().sleep_leave_out
                        return n == 0 and _("Leave out: nothing") or string.format(n == 1 and _("Leave out: %d rule") or _("Leave out: %d rules"), n)
                    end,
                    enabled_func = rec,
                    sub_item_table_func = leaveOutItems,
                },
                {
                    text_func = function() return _("Change cover every: ") .. _(SleepPool.hoursLabel(Library.sleep.settings().sleep_hours)) end,
                    enabled_func = rec,
                    sub_item_table = radios(SleepPool.HOURS, "sleep_hours"),
                    separator = true,
                },
                {
                    text_func = function()
                        local t = Library.sleep.settings().sleep_text
                        return _("Text: ") .. (t == "" and _("none") or t)
                    end,
                    keep_menu_open = true,
                    callback = function()
                        askText(_("Sleep screen text (up to 60 characters)"), Library.sleep.settings().sleep_text, _("e.g. Please return to the front desk"),
                            function(v) Library.sleep.set("sleep_text", SleepPool.cleanText(v)) end)
                    end,
                },
                {
                    text = _("Show battery level"),
                    checked_func = function() return Library.sleep.settings().sleep_battery end,
                    callback = function() Library.sleep.set("sleep_battery", not Library.sleep.settings().sleep_battery) end,
                },
                {
                    text_func = function() return _("Style: ") .. _(SleepPool.label(SleepPool.STYLES, Library.sleep.settings().sleep_style)) end,
                    sub_item_table = radios(SleepPool.STYLES, "sleep_style"),
                },
                {
                    text_func = function() return _("Text position: ") .. _(SleepPool.label(SleepPool.TEXT_POSITIONS, Library.sleep.settings().sleep_text_position)) end,
                    enabled_func = overlay,
                    sub_item_table = radios(SleepPool.TEXT_POSITIONS, "sleep_text_position"),
                },
                {
                    text_func = function()
                        local s = Library.sleep.settings()
                        local t = _("Battery corner: ") .. _(SleepPool.label(SleepPool.CORNERS, s.sleep_battery_corner))
                        local moved = SleepPool.batteryCorner(s.sleep_battery_corner, s.sleep_text_position)
                        if s.sleep_text ~= "" and moved ~= s.sleep_battery_corner then
                            t = t .. string.format(_(" (moves to %s beside the text)"), _(SleepPool.label(SleepPool.CORNERS, moved)):lower())
                        end
                        return t
                    end,
                    enabled_func = overlay,
                    sub_item_table = radios(SleepPool.CORNERS, "sleep_battery_corner"),
                    separator = true,
                },
                {
                    text_func = function() return _("Shown by: ") .. (Library.settings.status("sleep_shown_by") or _("BookSync Companion")) end,
                    callback = later(function() Library.sleep.openCompanion() end),
                },
                { text = _("Preview"), enabled_func = function() return Library.sleep.settings().sleep_mode ~= "off" end,
                  callback = later(function() Library.sleep.preview() end) },
            }
        end,
        separator = true,
    }
end

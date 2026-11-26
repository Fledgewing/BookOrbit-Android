-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Menu (mockup screen 6): Tools › BookSync
---------------------------------------------------------------------------------------------

function toggle(key, text, help)
    return {
        text = text,
        help_text = help,
        checked_func = function() return S[key] == true end,
        callback = function()
            -- A shared setting goes to the companion with its time (docs/design/companion-settings.md §4).
            if SCHEMA.byKey[key] then return Shared.set(key, not S[key]) end
            S[key] = not S[key]
            saveSettings()
            log("setting", key, "=", tostring(S[key]))
        end,
    }
end

-- A shared key's toggle with the companion's words: the schema's label, its line as help
-- (docs/design/companion-settings.md §5.7).
function stoggle(key)
    local d = SCHEMA.byKey[key]
    if not d then return toggle(key, key) end
    return toggle(key, _(d.label), _(d.line) .. (d.applies == "restart" and (" " .. _("Applies when KOReader restarts.")) or ""))
end

local function label(key, fallback)
    local d = SCHEMA.byKey[key]
    return d and _(d.label) or fallback
end

local function sectionTitle(id, fallback)
    for _i, sec in ipairs(SCHEMA.sections or {}) do if sec.id == id then return _(sec.title) end end
    return fallback
end

-- Drops the false placeholders a conditional row leaves.
local function compact(items)
    local out = {}
    for i = 1, table.maxn(items) do if items[i] then table.insert(out, items[i]) end end
    return out
end

-- Tiny bundled notice, loaded only for this explicit menu action.
function OrbitAndroid:showAbout()
    local credits
    for _i, path in ipairs({ SOURCE_DIR .. "/about_credits.json", SOURCE_DIR .. "/../../../shared/about/credits.json" }) do
        local f = io.open(path, "rb")
        if f then
            local text = f:read("*a")
            f:close()
            credits = SettingsSync.decodeJson(text)
            if credits then break end
        end
    end
    assert(credits, "BookSync: shared About credits missing")
    local lines = { "BookSync " .. PATCH_VERSION }
    for i, text in ipairs(credits.paragraphs) do
        table.insert(lines, text)
        if i == 2 then table.insert(lines, credits.url) end
    end
    UIManager:show(TextViewer:new{ title = _("About BookSync"), text = table.concat(lines, "\n\n") }) -- gate: user action (About menu)
end

function OrbitAndroid:statusText()
    local parts = {}
    local cstate = Companion.state()
    if cstate == "ok" then
        table.insert(parts, _("companion installed"))
    elseif cstate == "frozen" then
        table.insert(parts, Companion.disabledText())
    else
        table.insert(parts, _("no companion"))
    end
    table.insert(parts, _("Wi-Fi: ") .. _(WifiPlan.modeLabel(Shared.mode())))
    local last = S.last_sleep_sync
    if last then
        table.insert(parts, string.format("%s %s %s", _("last sleep sync"), last.ok and fmt(last.seconds) or _("failed"),
            os.date("%H:%M", last.at)))
    end
    local need = Shared.setupNeededText()
    if need then table.insert(parts, need) end
    for _i, l in ipairs(compatLines(bookorbit(self.ui))) do table.insert(parts, l) end
    return _("Status: ") .. table.concat(parts, " · ")
end

function OrbitAndroid:updateStatusText()
    local st = S.patch_update_status
    local head = string.format(_("Patch %s"), PATCH_VERSION)
    if not st then return head .. " · " .. _("not checked yet") end
    return string.format("%s · %s (%s)", head, st.text, os.date("%m-%d %H:%M", st.at))
end

-- By hand: Orbit Companion checks (it brings Wi-Fi up for a check by hand) and installs the update.
function OrbitAndroid:checkPatchUpdate()
    UIManager:show(InfoMessage:new{ text = Updater.check("menu"), timeout = 6 }) -- gate: user action (menu Update)
end

-- All values and choices come from the shared schema; wire IDs stay unchanged.
function OrbitAndroid:settingRow(key)
    local d = assert(SCHEMA.byKey[key], "Missing shared setting: " .. key)
    local function display(text)
        return SettingsUI.words(text, key == "home_button" and S.home_screen or nil)
    end
    local function set(value)
        Shared.set(key, value)
        Shared.onChange(key, "settings")
    end
    local row = { help_text = _(display(d.line or "")) }
    if d.type == "bool" then
        row.text = _(display(d.label))
        row.checked_func = function() return S[key] == true end
        row.callback = function() set(not S[key]) end
    elseif d.type == "source" then
        row.text = _(display(d.label))
        row.sub_item_table = {}
        for _i, choice in ipairs(d.values) do
            row.sub_item_table[#row.sub_item_table+1] = {text=_(choice.label),
                checked_func=function()
                    for _j, id in ipairs(SleepPool.sources(S[key])) do if id == choice.id then return true end end
                    return false
                end,
                callback=function() set(SleepPool.togglePick(S[key], choice.id)) end}
        end
        row.sub_item_table[#row.sub_item_table+1] = {text=_("Choose saved lists…"), callback=function() Sleep.openCompanion() end}
    elseif d.type == "rules" then
        row.text_func = function() return _(d.label) .. ": " .. SettingsUI.value(d, S[key]) end
        row.callback = function() Sleep.openCompanion() end
    elseif d.type == "text" then
        row.text_func = function() return _(display(d.label)) .. ": " .. SettingsUI.value(d, S[key]) end
        row.callback = function()
            local InputDialog = require("ui/widget/inputdialog")
            local dialog
            dialog = InputDialog:new{title=_(display(d.label)), input=SettingsSync.toWire(d, S[key]),
                buttons={{
                    {text=_("Cancel"), callback=function() UIManager:close(dialog) end},
                    {text=_("Save"), callback=function()
                        local value = SettingsSync.fromWire(d, dialog:getInputText())
                        UIManager:close(dialog)
                        if value ~= nil then set(value) end
                    end},
                }}}
            UIManager:show(dialog) -- gate: user action (settings input)
            pcall(dialog.onShowKeyboard, dialog)
        end
    else
        row.text_func = function()
            return _(display(d.label)) .. ": " .. _(display(SettingsUI.value(d, key == "wifi_mode" and Shared.mode() or S[key])))
        end
        row.sub_item_table = {}
        for _i, v in ipairs(d.values or {}) do
            local value = SettingsSync.fromWire(d, v.id)
            table.insert(row.sub_item_table, {text=_(display(v.label)), radio=true,
                checked_func=function() return SettingsSync.toWire(d, S[key]) == tostring(v.id) end,
                callback=function() set(value) end})
        end
    end
    if key == "wifi_mode" or key == "wifi_idle_min" or key == "wifi_via_companion" then
        row.enabled_func = function() return Companion.has("wifi") end
        if not Companion.has("wifi") then
            row.help_text = row.help_text .. " " .. _("Wi-Fi switching is unavailable in this setup. Wi-Fi stays as you leave it.")
        end
    end
    return row
end

function OrbitAndroid:menuItems()
    local finish = Budgets.span("settings.paint", now_s, log)
    local function later(fn)
        return function(touchmenu)
            if touchmenu and touchmenu.closeMenu then touchmenu:closeMenu() end
            UIManager:scheduleIn(0.2, fn)
        end
    end
    local function action(text, fn) return {text=_(text), callback=later(fn)} end
    local function rows(keys)
        local out = {}
        for _i, key in ipairs(keys) do out[#out+1] = self:settingRow(key) end
        return out
    end
    local function group(id, title, make)
        return {text=_(title), settings_group=id, sub_item_table_func=function()
            local span = Budgets.span("settings." .. id .. ".paint", now_s, log)
            local items = make()
            assert(#items <= Budgets.get("screens", "settings-" .. id).rows, "Settings row budget exceeded")
            span()
            return items
        end}
    end
    local items = {
        group("account", "Account & server", function() return {
            action("Connection and sign-in…", function() self:onOrbitOpenCompanion() end),
        } end),
        group("sync", "Sync, Wi-Fi & power", function()
            local paint = Library.paint("settings-sync")
            local estimates = paint:modeEstimates()
            paint:flush()
            local modes = {}
            for _i, mode in ipairs(SettingsUI.modes) do
                modes[#modes+1] = {text=_(mode.label) .. " · " .. SettingsUI.estimate(estimates, mode.id), help_text=_(mode.help) .. (Companion.has("wifi") and "" or (" " .. _("Wi-Fi switching is unavailable in this setup."))), radio=true,
                    enabled_func=function() return Companion.has("wifi") end,
                    checked_func=function() return SettingsUI.mode(S, Shared.mode()) == mode.id end,
                    callback=function()
                        if not Companion.has("wifi") then return end
                        for _i, key in ipairs(SettingsUI.modeKeys) do Shared.set(key, mode.values[key]) end
                        for _i, key in ipairs(SettingsUI.modeKeys) do Shared.onChange(key, "mode") end
                    end}
            end
            local out = {{text_func=function() return _("Mode") .. ": " .. _(SettingsUI.modeLabel(S, Shared.mode())) end, sub_item_table=modes}}
            table.insert(out, 1, action("Sync now", function() Library.syncNow(self) end))
            if SettingsUI.mode(S, Shared.mode()) == "custom" then
                local reset = action("Back to Balanced", modes[2].callback)
                reset.enabled_func = modes[2].enabled_func
                out[#out+1] = reset
            end
            for _i, row in ipairs(rows(SettingsUI.syncKeys)) do out[#out+1] = row end
            -- Device sleep is owned by Android, reachable even when the companion cannot switch Wi-Fi.
            out[#out+1] = action("Sleep & power: open companion…", function() self:onOrbitOpenCompanion() end)
            out[#out+1] = {text=_("Battery · estimates need measured use"), enabled_func=function() return false end}
            out[#out+1] = action("Sync and sleep now", function() self:onOrbitSyncAndSleep() end)
            if OSM and OSM.on() and self.ui and self.ui.document then
                out[#out+1] = action("Read from here everywhere", function() OSM.readFromHere("menu") end)
            end
            return out
        end),
        group("library", "Library & downloads", function()
            local out = rows({"offline_cache", "mirror_covers", "storage_limit_mb", "keep_copies_current"})
            out[#out+1] = action("Full refresh", function() Library.fullRefresh() end)
            return out
        end),
        group("reading", "Reading", function()
            return rows({"status_orbit_layout", "status_orbit_size", "local_first", "eob_sheet", "eob_auto"})
        end),
        group("home", "Home", function() return rows({"home_screen", "home_button"}) end),
        group("sleep", "Sleep screen", function()
            -- Only shared values here: named-list/tag browsing stays in the companion until
            -- the library supplies bounded choice windows. Never decode scopes.json on paint.
            local keys = {}
            for _i, d in ipairs(SCHEMA.settings) do if d.section == "sleep" and not d.hidden then keys[#keys+1] = d.key end end
            local out = rows(keys)
            out[#out+1] = action("Choose lists and exclusions…", function() Sleep.openCompanion() end)
            return out
        end),
        group("updates", "Updates", function()
            local out = rows({"auto_update_patch", "update_channel", "key_log"})
            table.insert(out, 1, {text="BookSync " .. PATCH_VERSION, enabled_func=function() return false end})
            out[#out+1] = action("Check now", function() self:checkPatchUpdate() end)
            return out
        end),
        group("about", "About & help", function() return {
            (function() local row = action("About", function() self:showAbout() end); row.read_only=true; return row end)(),
            action("Help and guides", function() self:onOrbitOpenCompanion() end),
            action("Advanced: open companion app", function() self:onOrbitOpenCompanion() end),
        } end),
        action("Open BookSync Companion", function() self:onOrbitOpenCompanion() end),
    }
    assert(#items <= Budgets.get("screens", "settings").rows, "Settings row budget exceeded")
    finish()
    return items
end

-- Settings PIN set and locked: the companion's keypad, then open the menu again.
function OrbitAndroid:showPinKeypad(why)
    local ok = Jni.startActivity{ action = Companion.ACTION.SHOW_PIN, package = Companion.PACKAGE } -- gate: user action (menu)
    log("menu: locked by the Settings PIN; keypad (" .. why .. ")", ok and "started" or "FAILED")
    return ok
end

-- Locked by the companion's Settings PIN: the same menu, read-only (docs/design/companion-settings.md
-- §4.7). Submenus open, so every value can be seen; nothing that changes or does something is
-- enabled. The first row asks for the PIN.
function OrbitAndroid.readOnly(items)
    local out = {}
    for _i, it in ipairs(items) do
        local c = {}
        for k, v in pairs(it) do c[k] = v end
        if type(it.sub_item_table) == "table" then
            c.sub_item_table = OrbitAndroid.readOnly(it.sub_item_table)
        elseif it.sub_item_table_func then
            local f = it.sub_item_table_func
            c.sub_item_table_func = function(...) return OrbitAndroid.readOnly(f(...) or {}) end
        elseif not it.keep_menu_open and not it.read_only then
            c.enabled_func = function() return false end
            c.callback = function() end
        end
        table.insert(out, c)
    end
    return out
end

function OrbitAndroid:lockedMenuItems()
    local items = OrbitAndroid.readOnly(self:menuItems())
    table.insert(items, 1, { text = _("Locked by the Settings PIN. Enter it to change these…"), separator = true,
        callback = function(touchmenu)
            if touchmenu and touchmenu.closeMenu then touchmenu:closeMenu() end
            self:showPinKeypad("tap")
        end })
    return items
end

function OrbitAndroid:addToMainMenu(menu_items)
    local entry = { text = _("BookSync"), sub_item_table_func = function()
        Shared.refresh("menu")
        if Shared.pin_locked then return self:lockedMenuItems() end
        UIManager:scheduleIn(0.5, function() self:maybeSetupPrompt("menu", "menu") end)
        return self:menuItems()
    end }
    -- Its own top-level entry in Tools, the way plugins and user patches add menus: an item
    -- missing from the menu order goes to the menu its sorting_hint names
    -- (frontend/ui/menusorter.lua:162-189). Nothing is injected into the plugin's menu.
    entry.sorting_hint = "tools"
    menu_items.orbit_android = entry
end

---------------------------------------------------------------------------------------------

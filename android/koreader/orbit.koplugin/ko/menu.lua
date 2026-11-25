-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Menu (mockup screen 6): Tools › Android sync
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
    for _, path in ipairs({ SOURCE_DIR .. "/about_credits.json", SOURCE_DIR .. "/../../../shared/about/credits.json" }) do
        local f = io.open(path, "rb")
        if f then
            local text = f:read("*a")
            f:close()
            credits = SettingsSync.decodeJson(text)
            if credits then break end
        end
    end
    assert(credits, "Orbit: shared About credits missing")
    local lines = { "Orbit " .. PATCH_VERSION }
    for i, text in ipairs(credits.paragraphs) do
        table.insert(lines, text)
        if i == 2 then table.insert(lines, credits.url) end
    end
    UIManager:show(TextViewer:new{ title = _("About Orbit"), text = table.concat(lines, "\n\n") }) -- gate: user action (About menu)
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

function OrbitAndroid:menuItems()
    local schedule_items = {}
    for _i, o in ipairs(Schedule.OPTIONS) do
        table.insert(schedule_items, {
            text = _(o.label),
            radio = true,
            checked_func = function() return S.reading_schedule == o.id end,
            callback = function()
                Shared.set("reading_schedule", o.id)
                self.schedule = Schedule.new(o.id, now_s())
                self:hookPluginPagePush()
            end,
        })
    end
    -- Storage limit (v0.11.2): one limit on everything Orbit stores (OC.storageCount, counted by Orbit Companion).
    local limit_items = {}
    for _i, mb in ipairs(Cache.STORAGE_LIMITS_MB) do
        table.insert(limit_items, {
            text = mb == 0 and _("No limit") or (mb >= 1024 and string.format(_("%g GB"), mb / 1024) or string.format(_("%d MB"), mb)),
            radio = true,
            checked_func = function() return (tonumber(S.storage_limit_mb) or Cache.STORAGE_DEFAULT_MB) == mb end,
            callback = function()
                Shared.set("storage_limit_mb", mb)
                log("storage: limit set to", mb == 0 and "none" or (mb .. " MB"))
                pcall(OC.storageCount, "limit changed")
            end,
        })
    end
    local cap_items = {}
    for _i, c in ipairs({ 10, 15, 20 }) do
        table.insert(cap_items, {
            text = string.format("%d s", c),
            radio = true,
            checked_func = function() return S.sleep_cap == c end,
            callback = function() Shared.set("sleep_cap", c) end,
        })
    end
    local function later(fn)
        return function(touchmenu)
            if touchmenu and touchmenu.closeMenu then touchmenu:closeMenu() end
            UIManager:scheduleIn(0.2, fn)
        end
    end
    local wifi_items = {}
    for _i, o in ipairs(WifiPlan.MODES) do
        table.insert(wifi_items, {
            text = _(o.label),
            radio = true,
            enabled_func = function() return Companion.installed() end,
            checked_func = function() return Shared.mode() == o.id end,
            callback = function()
                Shared.set("wifi_mode", o.id)
                Wifi.applySettings("menu")
            end,
        })
    end
    local idle_items = {}
    for _i, m in ipairs(WifiPlan.IDLE_MINUTES) do
        table.insert(idle_items, {
            text = string.format(_("%d min"), m),
            radio = true,
            checked_func = function() return (S.wifi_idle_min or 2) == m end,
            callback = function()
                Shared.set("wifi_idle_min", m)
                Wifi.applySettings("menu")
            end,
        })
    end
    table.insert(wifi_items, {
        text_func = function() return string.format(_("Just in time: off after %d min idle"), S.wifi_idle_min or 2) end,
        enabled_func = function() return Shared.mode() == "jit" end,
        sub_item_table = idle_items,
        separator = true,
    })
    table.insert(wifi_items, {
        text_func = function()
            return Companion.problem() or _("Only Orbit Companion switches Wi-Fi. It never turns off Wi-Fi you turned on by hand in just in time, and never while another app is in front.")
        end,
        keep_menu_open = true,
        callback = function() end,
    })
    local home_items = {
        {
            text = _("Back to my book, then BookOrbit home"),
            radio = true,
            checked_func = function() return S.home_button ~= "bookorbit" end,
            callback = function() Shared.set("home_button", "smart") end,
        },
        {
            text = _("BookOrbit home"),
            radio = true,
            checked_func = function() return S.home_button == "bookorbit" end,
            callback = function() Shared.set("home_button", "bookorbit") end,
        },
    }
    -- A feature the companion doesn't offer here: its rows are hidden, with one line saying
    -- where it lives (docs/design/addon-mode.md §6.4).
    local wifi_rows
    if Companion.has("wifi") then
        wifi_rows = {
            { text_func = function() return label("wifi_mode", _("Wi-Fi")) .. ": " .. _(WifiPlan.modeLabel(Shared.mode())) end, sub_item_table = wifi_items },
            stoggle("wifi_via_companion"),
        }
    elseif Companion.installed() then
        wifi_rows = { { text = _("Wi-Fi switching and sleep sync: in Orbit Companion ›"),
            callback = later(function() self:onOrbitOpenCompanion() end) } }
    else
        wifi_rows = { { text_func = function()
            return (Companion.problem() or "") .. " " .. _("Wi-Fi stays as you leave it: switching it needs Orbit Companion.")
        end, keep_menu_open = true, callback = function() end } }
    end
    -- The companion's eight sections (docs/design/companion-settings.md §5.7): five submenus here
    -- with the same labels; Buttons, Kids and PIN and Setup live in the companion.
    local reading = compact({
        {
            text_func = function()
                local t = label("home_button", _("Home button in KOReader")) .. ": " .. (S.home_button == "bookorbit" and _("BookOrbit home") or _("Back to my book, then BookOrbit home"))
                -- The companion's "Home opens": this applies only with KOReader.
                if Shared.home_opens == "launcher" then t = t .. _(" (Home opens the Orbit launcher page)")
                elseif Shared.home_opens == "app" then t = t .. _(" (Home opens another app)") end
                return t
            end,
            help_text = _(SCHEMA.byKey.home_button and SCHEMA.byKey.home_button.line or ""),
            sub_item_table = home_items,
            separator = true,
        },
        stoggle("local_first"),
        stoggle("eob_sheet"),
        stoggle("eob_auto"),
    })
    -- Sync: OrbiSmart / Custom (docs/design/orbismart.md §6), the section's first row. OrbiSmart
    -- sets the rows below it and hides them; Custom shows them again, with their last values.
    local mode_items = {}
    local mode_def = SCHEMA.byKey.sync_mode
    for _i, v in ipairs(mode_def and mode_def.values or { { id = "orbismart", label = "OrbiSmart (recommended)" }, { id = "custom", label = "Custom" } }) do
        table.insert(mode_items, {
            text = _(v.label),
            radio = true,
            checked_func = function() return (S.sync_mode or "orbismart") == v.id end,
            callback = function()
                if (S.sync_mode or "orbismart") == v.id then return end
                Shared.set("sync_mode", v.id)
                OSM.modeChanged("menu")
            end,
        })
    end
    local custom = not (OSM and OSM.on())
    local sync = compact({
        {
            text_func = function() return label("sync_mode", _("Sync")) .. ": " .. ((OSM and OSM.on()) and _("OrbiSmart") or _("Custom")) end,
            help_text = _(mode_def and mode_def.line or ""),
            sub_item_table = mode_items,
            separator = true,
        },
        wifi_rows[1],
        custom and stoggle("sync_on_sleep"),
        custom and {
            text_func = function() return string.format(label("sleep_cap", _("Sleep sync limit")) .. ": %d s", S.sleep_cap or 20) end,
            enabled_func = function() return S.sync_on_sleep ~= false end,
            sub_item_table = cap_items,
        },
        custom and stoggle("sync_on_wake"),
        custom and {
            text_func = function() return label("reading_schedule", _("Sync while reading")) .. ": " .. _(Schedule.option(S.reading_schedule).label) end,
            sub_item_table = schedule_items,
        },
        stoggle("wake_tailscale"),
        { text = _("Test sync path"), callback = later(function() self:testSyncPath() end) },
    })
    local library = compact({
        stoggle("offline_cache"),
        {
            text = label("mirror_covers", _("Save every cover for offline")),
            checked_func = function() return S.mirror_covers == true end,
            help_text = _("A Full refresh also saves the cover of every book it saves, and keeps them. Off: covers are saved as you see books, and the oldest go when there are many. Turning it off deletes nothing."),
            callback = function()
                Shared.set("mirror_covers", not S.mirror_covers)
                log("mirror: every cover for offline", S.mirror_covers and "on" or "off")
                if S.mirror_covers then pcall(Mirror.coverPass, "turned on") end
            end,
        },
        {
            text_func = function()
                local mb = tonumber(S.storage_limit_mb) or Cache.STORAGE_DEFAULT_MB
                local okt, used = pcall(OC.storageText)
                return label("storage_limit_mb", _("Storage limit")) .. ": " .. (mb == 0 and _("No limit") or (mb >= 1024 and string.format(_("%g GB"), mb / 1024) or string.format(_("%d MB"), mb)))
                    .. (okt and (" · " .. used) or "")
            end,
            help_text = _("One limit on everything Orbit stores: pages it saved, books saved for offline and covers. Book files and KOReader's own data don't count. Over it, the least recently shown covers go first, including covers saved for offline. Browsing pages go only after eligible covers. Protected covers and lists and book details saved for offline always stay."),
            sub_item_table = limit_items,
        },
        toggle("keep_copies_current", label("keep_copies_current", _("Keep book copies current")),
            _("When a book's file changes in the library (BookOrbit writes tags into it), the copy on this reader is downloaded again in the background, never while you read. Position, highlights and bookmarks stay.")),
        { text_func = function() return Mirror.savedText() end, keep_menu_open = true, callback = function() end },
    })
    local updates = compact({
        -- Updates come with Orbit Companion, which updates the plugin with it (its own switches).
        { text = _("Check for updates (Orbit Companion)"), callback = later(function() self:checkPatchUpdate() end) },
        { text_func = function() return self:updateStatusText() end, keep_menu_open = true, callback = function() end, separator = true },
        stoggle("key_log"),
        wifi_rows[2] or false,
        -- Debug: SQLite on shared storage (docs/design/sqlite-cache.md "Stress test").
        S.key_log and { text = _("SQLite stress test (2 min)"), callback = later(function() SqliteStress.start() end) } or false,
    })
    local items = {
        { text = _("About"), read_only = true, callback = later(function() self:showAbout() end) },
        { text = sectionTitle("reading", _("Reading and Home")), sub_item_table = reading },
        Sleep.menuItem(self, later),
        { text = sectionTitle("sync", _("Sync and Wi-Fi")), sub_item_table = sync },
        { text = sectionTitle("library", _("Library and storage")), sub_item_table = library },
        { text = sectionTitle("updates", _("Updates and details")), sub_item_table = updates, separator = true },
        -- OrbiSmart's override (docs/design/orbismart.md §3.5), in a book only.
        (OSM and OSM.on() and self.ui and self.ui.document) and { text = _("Read from here everywhere"),
          help_text = _("Sends this page to BookOrbit now, even if it is behind the place there. Your other readers move here at their next sync. Offline, it is sent first at the next sync."),
          callback = later(function() OSM.readFromHere("menu") end) } or false,
        { text = _("Sync and sleep now"), callback = later(function() self:onOrbitSyncAndSleep() end) },
        { text = _("Full refresh of BookOrbit"), callback = later(function() OC.menuFullRefresh() end),
          help_text = _("Gets this view and Home fresh from the server, re-checks the covers, then saves everything reachable from Home for reading offline. Tap ⟳ for a normal refresh; hold ⟳ for this.") },
        { text_func = function() return self:recommendedMenuText() end, callback = later(function() self:showRecommended("menu") end), separator = true },
        { text = _("Open Orbit Companion"), callback = later(function() self:onOrbitOpenCompanion() end) },
        Companion.has("apps") and { text = _("Open another app…"), callback = later(function() self:onOrbitOpenApps() end) } or false,
        Companion.installed() and { text = _("Buttons, PIN and setup: in Orbit Companion ›"), callback = later(function() self:onOrbitOpenCompanion() end), separator = true } or false,
        { text_func = function() return self:statusText() end, keep_menu_open = true, callback = function() end },
    }
    return compact(items)
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
    local entry = { text = _("Android sync"), sub_item_table_func = function()
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

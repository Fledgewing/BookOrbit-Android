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

-- By hand: bring Wi-Fi up if needed (through the companion), check, then put Wi-Fi back.
function OrbitAndroid:checkPatchUpdate()
    local msg = InfoMessage:new{ text = _("Checking for a patch update…") }
    UIManager:show(msg) -- gate: user action (menu Update)
    UIManager:forceRePaint()
    local function report(text)
        UIManager:close(msg)
        UIManager:show(InfoMessage:new{ text = _("Patch update: ") .. text, timeout = 6 }) -- gate: user action (menu Update)
    end
    local function run(held)
        UIManager:scheduleIn(0.2, function()
            Updater.check("menu", function(_ok, text)
                if held then Wifi.release("update") end
                report(text)
            end)
        end)
    end
    if NetworkMgr:isConnected() then return run(false) end
    if not Companion.installed() then
        setUpdateStatus("no internet: Wi-Fi is off")
        return report((Companion.problem() and (Companion.problem() .. " ") or "") .. _("No internet: Wi-Fi is off."))
    end
    Wifi.acquire("update")
    Net.up(nil, { reason = "update", cap = 20, need_server = false }, function(ok, res)
        if not ok then
            Wifi.release("update")
            setUpdateStatus("no internet: " .. tostring(res.detail))
            return report(_("No internet: ") .. tostring(res.detail))
        end
        run(true)
    end)
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
    -- The offline mirror's automatic Full refresh (docs/design/write-through-cache.md).
    local ttl_items = {}
    for _i, d in ipairs({ 1, 3, 7, 14, 30 }) do
        table.insert(ttl_items, {
            text = string.format(d == 1 and _("Every day") or _("Every %d days"), d),
            radio = true,
            checked_func = function() return S.mirror_auto ~= false and (S.mirror_ttl_days or 7) == d end,
            callback = function() Shared.set("mirror_auto", true); Shared.set("mirror_ttl_days", d) end,
        })
    end
    table.insert(ttl_items, {
        text = _("Only by hand (hold ⟳)"), radio = true,
        checked_func = function() return S.mirror_auto == false end,
        callback = function() Shared.set("mirror_auto", false) end,
    })
    -- Storage limit (v0.11.2): one limit on everything Orbit stores (OC.storageEnforce).
    local limit_items = {}
    for _i, mb in ipairs(Cache.STORAGE_LIMITS_MB) do
        table.insert(limit_items, {
            text = mb == 0 and _("No limit") or (mb >= 1024 and string.format(_("%d GB"), mb / 1024) or string.format(_("%d MB"), mb)),
            radio = true,
            checked_func = function() return (tonumber(S.storage_limit_mb) or Cache.STORAGE_DEFAULT_MB) == mb end,
            callback = function()
                Shared.set("storage_limit_mb", mb)
                log("storage: limit set to", mb == 0 and "none" or (mb .. " MB"))
                pcall(OC.storageEnforce, "limit changed")
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
            { text_func = function() return _("Wi-Fi: ") .. _(WifiPlan.modeLabel(Shared.mode())) end, sub_item_table = wifi_items },
            toggle("wifi_via_companion", _("Wi-Fi via Orbit Companion")),
        }
    elseif Companion.installed() then
        wifi_rows = { { text = _("Wi-Fi switching and sleep sync: in Orbit Companion ›"),
            callback = later(function() self:onOrbitOpenCompanion() end) } }
    else
        wifi_rows = { { text_func = function()
            return (Companion.problem() or "") .. " " .. _("Wi-Fi stays as you leave it: switching it needs Orbit Companion.")
        end, keep_menu_open = true, callback = function() end } }
    end
    local items = {
        wifi_rows[1],
        {
            text_func = function()
                local t = _("In KOReader, Home goes to: ") .. (S.home_button == "bookorbit" and _("BookOrbit home") or _("Back to my book, then BookOrbit home"))
                -- The companion's "Home opens" (companion 0.4.8+): this applies only with KOReader.
                if Shared.home_opens == "launcher" then t = t .. _(" (Home opens the Orbit launcher page)")
                elseif Shared.home_opens == "app" then t = t .. _(" (Home opens another app)") end
                return t
            end,
            sub_item_table = home_items,
            separator = true,
        },
        wifi_rows[2] or false,
        toggle("wake_tailscale", _("Wake Tailscale before syncing")),
        toggle("sync_on_wake", _("Always sync on wake")),
        toggle("sync_on_sleep", _("Sync when the screen goes off")),
        toggle("eob_sheet", _("End of book: Orbit's sheet for BookOrbit books")),
        toggle("eob_auto", _("End of book: mark it finished")),
        toggle("local_first", _("Home shows this device's reading first (restart to apply)")),
        toggle("offline_cache", _("BookOrbit opens from Orbit's cache (restart to apply)")),
        { text = _("Full refresh of BookOrbit"), callback = later(function() OC.menuFullRefresh() end),
          help_text = _("Gets this view and Home fresh from the server, re-checks the covers, then saves everything reachable from Home for reading offline. Tap ⟳ for a normal refresh; hold ⟳ for this.") },
        { text_func = function() return Mirror.savedText() end, keep_menu_open = true, callback = function() end },
        {
            text = _("Save every cover for offline (about 100 KB per book)"),
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
                return _("Storage limit: ") .. (mb == 0 and _("No limit") or (mb >= 1024 and string.format(_("%d GB"), mb / 1024) or string.format(_("%d MB"), mb)))
                    .. (okt and (" · " .. used) or "")
            end,
            help_text = _("One limit on everything Orbit stores: pages it saved, books saved for offline and covers. Book files and KOReader's own data don't count. Over it, the least recently used pages and covers go first, then covers saved for offline; the lists and book details saved for offline always stay."),
            sub_item_table = limit_items,
        },
        {
            text_func = function()
                if S.mirror_auto == false then return _("Automatic Full refresh: off") end
                return string.format(_("Automatic Full refresh: every %d days"), S.mirror_ttl_days or 7)
            end,
            sub_item_table = ttl_items,
        },
        toggle("keep_copies_current", _("Keep book copies current"),
            _("When a book's file changes in the library (BookOrbit writes tags into it), the copy on this reader is downloaded again in the background, never while you read. Position, highlights and bookmarks stay.")),
        toggle("key_log", _("Log every key (clicker diagnosis)")),
        {
            text_func = function() return _("Sync while reading: ") .. _(Schedule.option(S.reading_schedule).label) end,
            sub_item_table = schedule_items,
            separator = true,
        },
        { text = _("Sync and sleep now"), callback = later(function() self:onOrbitSyncAndSleep() end) },
        {
            text_func = function() return string.format(_("Sleep sync limit: %d s"), S.sleep_cap or 20) end,
            sub_item_table = cap_items,
        },
        Sleep.menuItem(self, later),
        { text_func = function() return self:recommendedMenuText() end, callback = later(function() self:showRecommended("menu") end) },
        { text = _("Test sync path"), callback = later(function() self:testSyncPath() end), separator = true },
        { text = _("Open Orbit Companion"), callback = later(function() self:onOrbitOpenCompanion() end) },
        Companion.has("apps") and { text = _("Open another app…"), callback = later(function() self:onOrbitOpenApps() end), separator = true } or false,
        toggle("auto_update_patch", _("Auto-update patch")),
        toggle("patch_update_prerelease", _("Include pre-releases")),
        { text = _("Check for patch update"), callback = later(function() self:checkPatchUpdate() end) },
        { text_func = function() return self:updateStatusText() end, keep_menu_open = true, callback = function() end, separator = true },
        { text_func = function() return self:statusText() end, keep_menu_open = true, callback = function() end },
    }
    local out = {}
    for i = 1, #items do if items[i] then table.insert(out, items[i]) end end
    return out
end

-- Settings PIN set and locked: the companion's keypad, then open the menu again.
function OrbitAndroid:showPinKeypad(why)
    local ok = Jni.startActivity{ action = Companion.ACTION.SHOW_PIN, package = Companion.PACKAGE } -- gate: user action (menu)
    log("menu: locked by the Settings PIN; keypad (" .. why .. ")", ok and "started" or "FAILED")
    return ok
end

function OrbitAndroid:lockedMenuItems()
    UIManager:scheduleIn(0.1, function() self:showPinKeypad("menu") end)
    return {
        { text = _("Enter the Settings PIN…"), callback = function() self:showPinKeypad("tap") end },
        { text = _("Locked by the companion's Settings PIN. Enter it, then open this menu again."),
            keep_menu_open = true, callback = function() end },
    }
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

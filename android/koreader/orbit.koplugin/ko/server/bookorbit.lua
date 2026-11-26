-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- The BookOrbit plugin
---------------------------------------------------------------------------------------------

-- The reader or file browser on screen now. Flows outlive the module that started them
-- (a book can close mid-flow), so they look the UI up again when they need it.
function liveUI()
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance then return ReaderUI.instance end
    return require("apps/filemanager/filemanager").instance
end

compat_seen = setmetatable({}, { __mode = "k" })
compat_logged = {}
Grouping = nil -- lists by series and by author; defined with the catalog hooks below

-- The plugin's version (main.lua:54/95: BookOrbit.PLUGIN_VERSION; _meta.lua has none).
function pluginVersion(p)
    local okv, v = pcall(function() return p.PLUGIN_VERSION end)
    return (okv and type(v) == "string") and v or "unknown"
end

-- Unavailable features for this plugin instance, logged once per feature. Only a full pass is
-- cached (per live instance): a check that finds something missing, e.g. one made before the
-- plugin finished init, is made again next time.
function compatOf(p)
    if not p then return {} end
    local m = compat_seen[p]
    if m then return m end
    m = Compat.check(p)
    if next(m) == nil then compat_seen[p] = m end
    for id, missing in pairs(m) do
        if not compat_logged[id] then
            compat_logged[id] = true
            log("compat:", id, "unavailable (plugin " .. pluginVersion(p) .. "): missing",
                table.concat(missing, ", "), "->", Compat.fallback(id))
        end
    end
    return m
end

-- Can the patch use this plugin feature?
function can(p, id)
    return p ~= nil and compatOf(p)[id] == nil
end

function serverPlugin(ui)
    ui = liveUI() or ui
    local p = ui and ui.bookorbit
    if not p then
        local ok, inst = pcall(PluginLoader.getPluginInstance, PluginLoader, "bookorbit")
        p = ok and inst or nil
    end
    -- Without isLoggedIn/settings nothing else is safe: behave as without the plugin.
    if p and not can(p, "core") then return nil end
    return p
end

-- Status lines for the menu and Test sync path; {} when the plugin is fully supported.
function compatLines(p)
    if not p then return {} end
    return Compat.lines(compatOf(p), pluginVersion(p))
end

function inBook()
    local ui = liveUI()
    return ui ~= nil and ui.document ~= nil
end

---------------------------------------------------------------------------------------------

-- One compatibility entry point. Only main.lua loads this implementation.
Server = {}
Server.events = { home = "BookOrbitOpenDashboard", sync = "BookOrbitSyncBook", auto = "BookOrbitToggleAutoSync" }
function Server.loaded(name) return package.loaded["bookorbit_" .. name] end
function Server.require(name) return require("bookorbit_" .. name) end
function Server.ownsView(name) return type(name) == "string" and name:find("^bookorbit") ~= nil end
function Server.notice(w) return w and w.name == "bookorbit_toast" end
function Server.credentials(client, extras)
    extras.server, extras.user, extras.userkey = client.server_url, client.username, client.userkey
    return extras
end

function Server.signedIn(p) return p ~= nil and p:isLoggedIn() end
function Server.openLogin(p) return p:promptLogin() end
-- Legacy service bridge. Only reviewed lifecycle/sheet modules use this facade.
function Server.cacheClient() return OC.client() end
function Server.readerIdle()
    if Copies and Copies.tick then pcall(Copies.tick,"book closed") end
    if EOB and EOB.drain and not reading() then
        local p=serverPlugin()
        if p then EOB.drain(p,false,function() end) end
    end
end
function Server.watchCache() return OC.watchChecks() end
function Server.cacheBusy() if OC and OC.busy then return OC.busy() end end
function Server.refreshLibrary(...) return OC.menuFullRefresh(...) end
function Server.resumeCache(...) if Mirror and Mirror.kick then return Mirror.kick(...) end end
function Server.fullRefreshNotice() return Mirror and (Mirror.notices or Mirror.fullRunning()) end
function Server.installGrouping(...) return Grouping.install(...) end
function Server.countStorage(...) if OC and OC.storageCount then return OC.storageCount(...) end end
function Server.refreshCovers(...) if Mirror and Mirror.coverPass then return Mirror.coverPass(...) end end
function Server.reportRecommended(...) if Rec then return Rec.report(...) end end
function Server.applyRecommended(...) if Rec then return Rec.applyChoices(...) end end
function Server.capabilitiesLost(...) if Rec then return Rec.capsLost(...) end end
function Server.capabilitiesGained(...) if Rec then return Rec.pass(...) end end
function Server.endSheetOpen() return EOB and EOB.sheet~=nil end
function Server.leaveEndSheet(...) return EOB and EOB.leaveForHome(...) end
function Server.endAction(name,...) return EOB.actions[name](...) end
function Server.localBookId(path)
    local cat=Mirror and Mirror.catalog and Mirror.catalog()
    if not (path and cat and type(cat.on_device)=="table") then return nil end
    for id,p in pairs(cat.on_device) do if p==path then return tonumber(id) end end
end
function Server.quietLegacy(quiet)
    quiet(Copies,{"ask","tick","pump","found","prepared"})
    quiet(OC,{"watchChecks","applyEvents","landed","redraw_soon","redraw","storageCount","storageCounted","rechecked"})
    quiet(Mirror,{"tick","kick","poll","ran","finish","coverPass"})
    quiet(LF,{"quiet","paintTiles","quietSwitch"})
end
function Server.timeLegacy(wrap)
    for _,name in ipairs({"EOB","OC","LF","Mirror","Copies"}) do
        wrap(getfenv(1)[name],name)
    end
end

-- Temporary non-transport compatibility for the finish adapter while its parallel cutover lands.
Sync = { waitOutbox=function(_,_,done) return ReadingSync.run("close",done) end }

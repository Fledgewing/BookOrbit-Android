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

function serverUrl(p)
    local settings = p and p.settings or G_reader_settings:readSetting("bookorbit")
    return settings and settings.server_url or nil
end

-- Any HTTP status from the base URL counts: it proves the route and the server, with no login.
-- Blocking primitive: only called by Net.up's background child. Socket timeouts
-- do not bound DNS resolution; Background.run also caps the child's lifetime.
function probeServer(url, timeout)
    local http = require("socket.http")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local ltn12 = require("ltn12")
    timeout = math.min(1.5, timeout)
    socketutil:set_timeout(timeout, timeout)
    local code = socket.skip(1, http.request{ url = url, method = "HEAD", sink = ltn12.sink.null() })
    socketutil:reset_timeout()
    return type(code) == "number", code
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
function Server.drain(p, ...) return p:requestLifecycleOutboxDrain(...) end
function Server.pull(p, reason) return p:requestProgressPull(false, false, reason) end
function Server.snapshot(p) return pcall(p._onSuspend, p) end
function Server.syncBusy(p)
    local c = p:getSyncCoordinator()
    if c:isBusy() or c:queuedCount() > 0 then return true end
    return outboxPending(p:getLifecycleOutbox():diagnostics()) > 0
end
function Server.testReady(p)
    return hasHandler(p, Server.events.sync) and Compat.callable(p.startSweep) and Compat.callable(p.errorLabel)
end
function Server.testError(p, err) return p:errorLabel(err) end
function Server.testSync(p, reader, done)
    if reader then pluginEvent(liveUI(), p, Server.events.sync, {quiet=true, on_done=done})
    else p:startSweep({quiet=true, on_progress=function() end, on_done=done}) end
end

-- Legacy service bridge. Only reviewed lifecycle/sheet modules use this facade.
function Server.cacheClient() return OC.client() end
function Server.watchCache() return OC.watchChecks() end
function Server.cacheBusy() if OC and OC.busy then return OC.busy() end end
function Server.refreshLibrary(...) return OC.menuFullRefresh(...) end
function Server.resumeCache(...) if Mirror and Mirror.kick then return Mirror.kick(...) end end
function Server.fullRefreshNotice() return Mirror and (Mirror.notices or Mirror.fullRunning()) end
function Server.installGrouping(...) return Grouping.install(...) end
function Server.positionOn() return OSM and OSM.on() end
function Server.positionWakeMinimum() return OSM.WAKE_MIN_S end
function Server.pullThenDrain(...) return OSM.pullThenDrain(...) end
function Server.readFromHere(...) return OSM.readFromHere(...) end
function Server.waitOutbox(...) return Sync.waitOutbox(...) end
function Server.clearPullDebounce(...) return Sync.clearPullDebounce(...) end
function Server.countStorage(...) if OC and OC.storageCount then return OC.storageCount(...) end end
function Server.refreshCovers(...) if Mirror and Mirror.coverPass then return Mirror.coverPass(...) end end
function Server.positionModeChanged(...) if OSM and OSM.modeChanged then return OSM.modeChanged(...) end end
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
    quiet(OSM,{"pause","pullThenDrain"})
end
function Server.timeLegacy(wrap)
    for _,name in ipairs({"EOB","OSM","OC","LF","Sync","Mirror","Copies"}) do
        wrap(getfenv(1)[name],name)
    end
end

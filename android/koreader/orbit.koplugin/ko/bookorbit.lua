-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
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

function bookorbit(ui)
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

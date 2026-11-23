-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Plugin compatibility (survive BookOrbit plugin updates). Every plugin internal the patch
-- calls, grouped by the feature that needs it. A missing one turns off only that feature, which
-- then falls back to the plugin's own behaviour. Definitions (bookorbit.koplugin 2.3.0):
-- main.lua:283 isLoggedIn, :287 errorLabel, :361 getSyncCoordinator, :374 getLifecycleOutbox,
-- :414 requestLifecycleOutboxDrain, :717 requestProgressPush, :730 requestProgressPull,
-- :1246 startSweep, :1269 onBookOrbitSyncBook, :1340 _onSuspend, :1381 onBookOrbitOpenDashboard,
-- :1416 onBookOrbitToggleAutoSync; bookorbit_progress_sync.lua:63 getLastPercent, :71
-- getLastProgress, :81 getDocumentDigest, :145 isSamePlace, :157 remoteProgressIsNewer, :521
-- fetchRemoteProgress; the catalog widget: main.lua:1207-1230
-- (catalog_browser, close_callback), bookorbit_catalog.lua:1875 dashboardMode.
-- test/plugin_compat.lua checks the same list against the latest plugin source (CI, weekly).
Compat = {}
Compat.FEATURES = {
    { id = "core", needs = { isLoggedIn = "function", settings = "table" },
      fallback = "the patch leaves syncing to the plugin" },
    { id = "outbox", needs = { requestLifecycleOutboxDrain = "function", getLifecycleOutbox = "function",
        getSyncCoordinator = "function" },
      fallback = "wake and sleep syncs use the plugin's own sync" },
    { id = "wake_pull", needs = { requestProgressPull = "function" },
      fallback = "wake and open pulls use the plugin's own timing" },
    { id = "sleep_snapshot", needs = { _onSuspend = "function" },
      fallback = "Sync and sleep sends what the plugin already queued" },
    { id = "reading_sync", needs = { fetchRemoteProgress = "function", isSamePlace = "function",
        remoteProgressIsNewer = "function", getLastPercent = "function", getLastProgress = "function",
        getDocumentDigest = "function", requestProgressPush = "function", requestProgressPull = "function",
        requestLifecycleOutboxDrain = "function" },
      fallback = "Sync while reading is off" },
    { id = "dashboard", needs = { onBookOrbitOpenDashboard = "function" },
      fallback = "Home closes the book, then the plugin opens BookOrbit home" },
    { id = "test_sync", needs = { onBookOrbitSyncBook = "function", startSweep = "function", errorLabel = "function" },
      fallback = "Test sync path skips the plugin step" },
    { id = "recommended", needs = { onBookOrbitToggleAutoSync = "function" },
      fallback = "Recommended settings can't turn on Auto-sync" },
}
-- The feature that names each plugin event (advisory logging in pluginEvent).
PLUGIN_EVENT_FEATURE = { BookOrbitOpenDashboard = "dashboard", BookOrbitSyncBook = "test_sync",
    BookOrbitToggleAutoSync = "recommended" }
-- Plugin settings the patch writes, with the values the plugin accepts. catalog_auto_open is the
-- plugin's open mode (2.3.0 bookorbit_settings_page.lua:205-209 "Make BookOrbit home" = "home";
-- read by main.lua:940-960 onStart/maybeAutoOpenCatalog; the plugin saves it by setting the
-- field and flushing G_reader_settings, bookorbit_settings_page.lua:822-825).
Compat.SETTINGS = { catalog_auto_open = { off = true, filemanager = true, home = true } }

-- The setting can be written: the plugin's settings table, and the current value unset or one
-- the plugin knows (a value we don't know means the plugin changed the setting: leave it alone).
function Compat.settable(settings, key, value)
    local known = Compat.SETTINGS[key]
    if type(settings) ~= "table" or not known or not known[value] then return false end
    local cur = settings[key]
    return cur == nil or (type(cur) == "string" and known[cur] == true)
end

-- On the catalog widget, checked when it is open.
Compat.CATALOG = { dashboardMode = "function", close_callback = "function", goDashboard = "function" }

-- Lists by series and by author (v0.6.0, Grouping): the catalog class's methods it wraps or
-- calls (bookorbit_catalog.lua :847 switchTo, :881 fetch, :974 loadSection, :1111
-- paramsForEntry, :1181 loadBooks, :924 runConnected, :970 showRetry; the list methods copied
-- onto it by CatalogLists.install, bookorbit_catalog_lists.lua :45 listKind, :246
-- listSectionParams, :659 listSortSheetModel, :739 listRun, :1115 listToolbar, :1155
-- listHeader), and the API class's (bookorbit_api.lua :386 query, :714 catalogBooks, :720
-- catalogManifest). A missing one turns off only this feature (logged once).
Compat.CATALOG_CLASS = { switchTo = "function", fetch = "function", loadSection = "function",
    paramsForEntry = "function", loadBooks = "function", runConnected = "function", showRetry = "function",
    listKind = "function", listSectionParams = "function", listSortSheetModel = "function", listRun = "function",
    listToolbar = "function", listHeader = "function" }
Compat.API_CLASS = { query = "function", catalogBooks = "function", catalogManifest = "function" }

-- Paging on the catalog, for Home's "page 1 first" (v0.5.4): the dashboard's page
-- (bookorbit_catalog_board.lua:119-123 boardPage, :968-976 boardFlip) and a list's page
-- (bookorbit_catalog_lists.lua:64-66 listMode, :390-411 listPaging, :421-446 listGoPage).
Compat.PAGING = { boardPage = "function", boardFlip = "function", listMode = "function",
    listPaging = "function", listGoPage = "function" }

-- "function" means callable: KOReader 2025.10+ wraps every plugin on* handler in a
-- HandlerSandbox, a table with __call (frontend/pluginloader.lua v2026.07.1:117-128, :158-164,
-- applied at :263); up to 2025.08 the wrapper was a plain function. A type() check alone saw
-- 2.3.0's handlers as missing on 2025.10+ (11-21 Boox Page, KOReader 2026.07.1).
function Compat.callable(v)
    if type(v) == "function" then return true end
    if type(v) ~= "table" and type(v) ~= "userdata" then return false end
    local okm, mt = pcall(getmetatable, v)
    return okm and type(mt) == "table" and mt.__call ~= nil
end

function hasKind(v, kind)
    if kind == "function" then return Compat.callable(v) end
    return type(v) == kind
end

-- { [id] = missing symbols (sorted list) } for one plugin instance; {} when all is there.
function Compat.check(p)
    local out = {}
    for _, f in ipairs(Compat.FEATURES) do
        local missing = {}
        for name, kind in pairs(f.needs) do
            local okv, v = pcall(function() return p[name] end)
            if not okv or not hasKind(v, kind) then table.insert(missing, name) end
        end
        if #missing > 0 then table.sort(missing); out[f.id] = missing end
    end
    return out
end

-- The names in needs that obj lacks (sorted); {} when all are there.
function Compat.missingOn(obj, needs)
    local missing = {}
    for name, kind in pairs(needs) do
        local okv, v = pcall(function() return obj[name] end)
        if not okv or not hasKind(v, kind) then table.insert(missing, name) end
    end
    table.sort(missing)
    return missing
end

function Compat.fallback(id)
    for _, f in ipairs(Compat.FEATURES) do if f.id == id then return f.fallback end end
    return id
end

-- One line per unavailable feature, e.g. "BookOrbit 2.4.0 changed: sleep sync uses ...".
function Compat.lines(missing, version)
    local ids = {}
    for id in pairs(missing) do table.insert(ids, id) end
    table.sort(ids)
    local out = {}
    for _, id in ipairs(ids) do
        table.insert(out, string.format("BookOrbit %s changed: %s", version or "?", Compat.fallback(id)))
    end
    return out
end

---------------------------------------------------------------------------------------------

-- Checks that every BookOrbit plugin internal the patch uses (Compat in 2-orbit-android.lua)
-- is still defined in a plugin checkout. Static: looks for each definition in the source.
--   luajit plugin_compat.lua <path to bookorbit.koplugin>
-- Prints the plugin version and any missing symbols; exits 1 when something is missing.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
local dir = arg[1] or error("usage: plugin_compat.lua <bookorbit.koplugin dir>")
_G.ORBIT_ANDROID_TEST = true
local M = dofile(here .. "/../2-orbit-android.lua")

local function list(d)
    local p = io.popen('ls "' .. d .. '"')
    local out = {}
    for f in p:lines() do if f:match("%.lua$") then table.insert(out, d .. "/" .. f) end end
    p:close()
    return out
end
local src = {}
for _, f in ipairs(list(dir)) do
    local h = io.open(f, "rb"); src[f] = h:read("*a"); h:close()
end
local function any(pattern)
    for _, text in pairs(src) do if text:find(pattern) then return true end end
    return false
end
local function esc(s) return (s:gsub("[%-%.%+%[%]%(%)%$%^%%%?%*]", "%%%0")) end

local version = (src[dir .. "/main.lua"] or ""):match('local PLUGIN_VERSION = "([^"]+)"') or "unknown"
local missing, seen = {}, {}
local function need(name, kind)
    if seen[name] then return end
    seen[name] = true
    local ok
    if kind == "function" then
        -- function X:name( / function X.name( / name = function
        ok = any("function%s+[%w_%.]+[:%.]" .. esc(name) .. "%s*%(") or any("[%.%s]" .. esc(name) .. "%s*=%s*function")
    else
        ok = any("[%.%s]" .. esc(name) .. "%s*=")
    end
    if not ok then table.insert(missing, name) end
end
for _, f in ipairs(M.Compat.FEATURES) do
    for name, kind in pairs(f.needs) do need(name, kind) end
end
for name, kind in pairs(M.Compat.CATALOG) do need(name, kind) end
for name, kind in pairs(M.Compat.PAGING) do need(name, kind) end
-- Lists by series and by author (Grouping): the class methods it wraps or calls.
for name, kind in pairs(M.Compat.CATALOG_CLASS) do need(name, kind) end
for name, kind in pairs(M.Compat.API_CLASS) do need(name, kind) end
local lists = src[dir .. "/bookorbit_catalog_lists.lua"] or ""
local catalog = src[dir .. "/bookorbit_catalog.lua"] or ""
local function has(text, plain, what) if not text:find(plain, 1, true) then table.insert(missing, what) end end
-- The list methods are copied onto the catalog class (so the patch wraps that class).
has(lists, "function CatalogLists.install(Catalog)", "CatalogLists.install")
has(catalog, "CatalogLists.install(BookOrbitCatalog)", "CatalogLists.install(BookOrbitCatalog)")
-- The row actions it takes over inside a grouped view, and the sheet rows it adds to.
has(lists, 'kind == "open-series"', 'action kind "open-series"')
has(lists, 'kind == "open-author"', 'action kind "open-author"')
local sheet = lists:match("function CatalogLists:listSortSheetModel%(sheet%)(.-)\nend\n") or ""
has(sheet, "rows = {", "rows = { in listSortSheetModel")
-- The section body and context fields its answer and wrappers rely on.
for _, f in ipairs({ "body.items", "body.total", "body.size", "body.buckets", "body.hasNext", "body.offset", "body.sort", "body.filter" }) do
    has(catalog, f, "loadSection reads " .. f)
end
for _, f in ipairs({ "list_sheet", "dashboard_source_index", "series_summary" }) do need(f, "field") end
has(lists, "params.q = opts.q", "listSectionParams sends q")
-- Fields and events the patch reads or writes directly.
for _, name in ipairs({ "catalog_browser", "pull_timestamp", "push_timestamp", "pages_before_update",
    "last_remote_progress", "PLUGIN_VERSION", "last_error", "sync_forward", "sync_backward",
    "catalog_auto_open", "auto_sync", "current_context" }) do need(name, "field") end
-- Public actions the patch sends as events.
local main = src[dir .. "/main.lua"] or ""
if not main:find('registerAction%("bookorbit_open_dashboard"') then table.insert(missing, "action bookorbit_open_dashboard") end
-- Setting values the patch writes (Compat.SETTINGS): the plugin still offers each one.
for key, values in pairs(M.Compat.SETTINGS) do
    for v in pairs(values) do
        if v ~= "off" and not any('"' .. esc(v) .. '"') then table.insert(missing, key .. " = " .. v) end
    end
end

table.sort(missing)
print("BookOrbit plugin " .. version)
if #missing == 0 then
    print("all hooked symbols present")
    os.exit(0)
end
print("missing: " .. table.concat(missing, ", "))
os.exit(1)

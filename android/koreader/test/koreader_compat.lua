-- Checks that every KOReader internal the Orbit plugin hooks or calls is still defined in a
-- KOReader checkout (and its koreader-base, for the ffi/ modules). Static: it looks for each
-- definition in the source, like plugin_compat.lua does for the BookOrbit plugin.
--   luajit koreader_compat.lua <koreader checkout> [<koreader-base checkout>]
-- Without a koreader-base checkout, the base checks are skipped and named.
-- Prints the KOReader version and any missing symbols; exits 1 when something is missing.
-- When the plugin starts using another KOReader symbol, add it here.
local root = arg[1] or error("usage: koreader_compat.lua <koreader dir> [<koreader-base dir>]")
local base = arg[2]

local function read(path)
    local h = io.open(path, "rb")
    if not h then return nil end
    local s = h:read("*a")
    h:close()
    return s
end
local function esc(s) return (s:gsub("[%-%.%+%[%]%(%)%$%^%%%?%*]", "%%%0")) end

-- Every .lua file under dir (for symbols KOReader defines in more than one place).
local function tree(dir)
    local out = {}
    local p = io.popen('find "' .. dir .. '" -name "*.lua" -type f 2>/dev/null')
    for f in p:lines() do table.insert(out, f) end
    p:close()
    return out
end

-- kind: "fn" a function (function X:name( / X.name = function / name = function), "field" an
-- assignment (name = / .name =), "text" a plain substring.
local function defined(text, name, kind)
    if kind == "text" then return text:find(name, 1, true) ~= nil end
    if kind == "fn" then
        return text:find("function%s+[%w_%.]+[:%.]" .. esc(name) .. "%s*%(") ~= nil
            or text:find("[%.%s{,]" .. esc(name) .. "%s*=%s*function") ~= nil
            -- a function another one stands for: isAndroid = yes, canRestart = no
            or text:find("[%.%s{,]" .. esc(name) .. "%s*=%s*[%w_%.]+%s*[,\n}]") ~= nil
    end
    return text:find("[%.%s{,]" .. esc(name) .. "%s*=") ~= nil
end

-- { file (relative to the checkout, "*" for anywhere under frontend/ and plugins/), symbols, base? }
-- Symbols: name (a function), or { name, kind }.
local F, T = "field", "text"
local NEEDS = {
    { "frontend/ui/uimanager.lua", { "show", "close", "scheduleIn", "nextTick", "unschedule", "setDirty",
        "forceRePaint", "getElapsedTimeSinceBoot", "getTopmostVisibleWidget", "quit", "restartKOReader",
        "sendEvent", "broadcastEvent", "_repaint", { "_window_stack", F }, { "_refresh_stack", F },
        { "refresh_methods", T } } },
    { "*", { "isConnected", "isWifiOn", "turnOnWifi", "turnOffWifi", "beforeWifiAction",
        "turnOnWifiAndWaitForConnection", "scheduleConnectivityCheck" } },
    { "frontend/ui/network/manager.lua", { { "NetworkMgr", T } } },
    { "frontend/device/generic/device.lua", { "canRestart", "exit", "isAndroid", { "screen", F }, { "input", F },
        { "closed_rotation_mode", T } } },
    -- The start patch (orbit.koplugin/patches/1-orbit-start-rotation.lua): early patches, then the
    -- settings, the Device, the late patches, the first file browser.
    { "frontend/userpatch.lua", { "applyPatches", { "early", F }, { "late", F } } },
    { "reader.lua", { { "userpatch.applyPatches(userpatch.early)", T }, { "userpatch.applyPatches(userpatch.late)", T },
        { "settings.reader.lua", T } } },
    { "frontend/device/input.lua", { "handleKeyBoardEv" } },
    { "frontend/apps/reader/readerui.lua", { "init", "showReader", "registerModule", "onHome",
        { "instance", F }, { "registerModule(\"status\"", T }, { "registerModule(\"toc\"", T },
        { "registerModule(\"menu\"", T } } },
    -- Home keeps the held rotation (ko/home.lua keepHeldRotation, keepRotationOnFileBrowser).
    { "frontend/apps/filemanager/filemanager.lua", { { "instance", F }, "setRotationMode", "onSetRotationMode",
        { "lock_rotation", T } } },
    { "frontend/ui/widget/eventlistener.lua", { "handleEvent" } },
    { "frontend/apps/reader/modules/readermenu.lua", { "registerToMainMenu", "onCloseReaderMenu",
        { "menu_container", F } } },
    { "frontend/apps/reader/modules/readertoc.lua", { "isChapterStart", "getPreviousChapter" } },
    { "frontend/apps/reader/modules/readerstatus.lua", { "onEndOfBook", "markBook", "onShowBookStatus",
        { "end_document_action", T } } },
    { "frontend/dispatcher.lua", { "registerAction" } },
    -- Plugin handlers are HandlerSandbox tables with __call (compat.lua Compat.callable).
    { "frontend/pluginloader.lua", { "loadPlugins", "genPluginManagerSubItem", "getPluginInstance",
        { "HandlerSandbox", T }, { "__call", T } } },
    -- Recommended settings (ko/recommended.lua): the stock gesture defaults, Gestures.default_settings.
    { "plugins/gestures.koplugin/main.lua", { "onFlushSettings", { "data", F }, { "updated", F }, { "default_settings", F } } },
    { "plugins/gestures.koplugin/defaults.lua", { { "gesture_reader", F } } },
    { "frontend/docsettings.lua", { "open", { "LuaSettings:extend", T } } }, -- readSetting: LuaSettings'
    { "frontend/luasettings.lua", { "open", "readSetting", "saveSetting", "flush", "isTrue" } },
    { "datastorage.lua", { "getSettingsDir", "getDocSettingsHashDir" } },
    { "frontend/ui/event.lua", { "new" } },
    { "frontend/ui/time.lua", { "now", "to_s" } },
    { "frontend/ui/font.lua", { { "smallinfofont", F }, "getFace", { "xx_smallinfofont", F } } },
    -- The Full refresh badge (ko/badge.lua): a toast (taps go on through it) that redraws only its rectangle.
    { "frontend/ui/uimanager.lua", { { "widget.toast", T } } },
    { "frontend/ui/size.lua", { { "padding", F }, { "radius", F }, { "line", F }, { "border", F } } },
    -- The end-of-book sheet's footer: one ButtonTable row without separators.
    { "frontend/ui/widget/buttontable.lua", { { "zero_sep", F }, { "sep_width", F } } },
    { "frontend/ui/geometry.lua", { "new", "contains" } },
    { "frontend/ui/gesturerange.lua", { { "GestureRange", T } } },
    { "frontend/socketutil.lua", { "set_timeout", "reset_timeout" } },
    { "frontend/logger.lua", { { "info", T }, { "warn", T } } },
    { "frontend/gettext.lua", { { "GetText", T } } },
    { "frontend/ui/widget/container/widgetcontainer.lua", { { "extend", T }, "paintTo" } },
    { "frontend/ui/widget/container/inputcontainer.lua", { { "ges_events", T } } },
    -- W17 reading status: instance hooks, geometry, native gestures and temporary CRE state.
    { "frontend/apps/reader/modules/readerfooter.lua", { "getHeight", "applyFooterMode",
        "updateFooterText", "unscheduleFooterAutoRefresh", "rescheduleFooterAutoRefreshIfNeeded",
        "TapFooter", "onToggleFooterMode", "updateFooterContainer", "resetLayout", "onUpdateFooter", { "mode_list", F }, { "reclaim_height", F },
        { "pageno", F }, { "pages", F }, { "percent_finished", F } } },
    { "frontend/apps/reader/modules/readerview.lua", { "paintTo", "onSetDimensions", "onRestoreDimensions",
        "drawSinglePage", "drawScrollPages", "drawPageBackground", "drawPageSurround", "getSinglePagePosition",
        "getScrollPagePosition", "getSinglePageRect", "getScrollPageRect", "getScreenPageArea", "recalculate", "drawScrollView", "screenToPageTransform", "pageToScreenTransform" } },
    { "frontend/apps/reader/modules/readerzooming.lua", { "onSetDimensions", "onRestoreDimensions" } },
    { "frontend/apps/reader/modules/readerpaging.lua", { "onInitScrollPageStates", "getTopPosition", "setPagePosition" } },
    { "frontend/apps/reader/modules/readertypeset.lua", { "onSetPageMargins", { "unscaled_margins", F } } },
    { "frontend/apps/reader/modules/readerrolling.lua", { "onSetStatusLine", "onGotoViewRel", "_gotoPos", { "cre_top_bar_enabled", F } } },
    { "frontend/apps/reader/modules/readercoptlistener.lua", { "unscheduleHeaderRefresh", "rescheduleHeaderRefreshIfNeeded" } },
    { "frontend/apps/reader/modules/readertoc.lua", { "getTocTitleByPage" } },
    { "frontend/document/document.lua", { "getPageCount" } },
    { "frontend/document/credocument.lua", { "setPageMargins", "setStatusLineProp", "setViewDimen", "setViewMode", "getScreenPositionFromXPointer", "getLinkFromPosition" } },
    { "frontend/ui/geometry.lua", { "copy", "offsetWithin" } },
    { "frontend/ui/widget/textwidget.lua", { "getSize", "paintTo", "free" } },
    { "frontend/device/generic/device.lua", { "getPowerDevice" } },
    { "frontend/device/generic/powerd.lua", { "getCapacity", "isCharging" } },
    -- OrbiSmart (ko/orbismart.lua): places in this layout's pages, and the Yes / No popup (its
    -- Back / tap outside runs cancel_callback).
    { "frontend/document/credocument.lua", { "getPageCount", "getPageFromXPointer", "getCurrentPage" } },
    { "frontend/ui/widget/confirmbox.lua", { { "ok_text", F }, { "cancel_text", F }, { "cancel_callback", F },
        { "self.cancel_callback()", T } } },
    -- The sleep screen (ko/sleepscreen.lua): the open book's cover and title, and the text input.
    { "frontend/apps/filemanager/filemanagerbookinfo.lua", { "getCoverImage" } },
    { "frontend/apps/reader/readerui.lua", { { "doc_props", F } } },
    { "frontend/ui/widget/inputdialog.lua", { "getInputText", "onShowKeyboard" } },
}
-- Widgets the plugin builds with: each module must still exist.
for _, w in ipairs({ "infomessage", "textviewer", "confirmbox", "button", "container/bottomcontainer",
    "container/framecontainer", "horizontalgroup", "horizontalspan", "linewidget", "textboxwidget",
    "verticalgroup", "verticalspan", "buttontable", "textwidget", "imagewidget", "container/centercontainer",
    "container/leftcontainer", "menu", "buttondialog", "notification" }) do
    table.insert(NEEDS, { "frontend/ui/widget/" .. w .. ".lua", {} })
end
-- koreader-base (the base/ submodule): ffi modules the plugin requires.
local BASE = {
    { "ffi/util.lua", { "runInSubProcess", "isSubProcessDone", "readAllFromFD", "writeToFD",
        "terminateSubProcess" } },
    { "ffi/input_android.lua", { { "waitForEvent", T } } },
    { "ffi/blitbuffer.lua", { { "COLOR_BLACK", F }, { "COLOR_WHITE", F }, "writeToFile", "free" } },
    { "ffi/framebuffer_android.lua", { "getRotationMode", "setRotationMode", { "ASCREEN_ORIENTATION_", T } } },
    -- The offline cache's database (ko/db.lua; docs/design/sqlite-cache.md), as KOReader's statistics plugin uses it.
    { "thirdparty/lua-ljsqlite3/init.lua", { "open", "set_busy_timeout", "prepare", "exec", "rowexec", "step", "bind",
        "reset", "close", "_ncol", { "ro = sql.SQLITE_OPEN_READONLY", T } } },
}

local missing = {}
local function check(dir, list, label)
    local all
    for _, need in ipairs(list) do
        local file, syms = need[1], need[2]
        local text
        if file == "*" then
            if not all then
                local parts = {}
                for _, sub in ipairs({ "frontend", "plugins" }) do
                    for _, f in ipairs(tree(dir .. "/" .. sub)) do table.insert(parts, read(f) or "") end
                end
                all = table.concat(parts, "\n")
            end
            text = all
        else
            text = read(dir .. "/" .. file)
            if not text then table.insert(missing, label .. file .. " (file gone)") end
        end
        if text then
            for _, s in ipairs(syms) do
                local name, kind = s, "fn"
                if type(s) == "table" then name, kind = s[1], s[2] end
                if not defined(text, name, kind) then
                    table.insert(missing, label .. (file == "*" and "" or file .. ": ") .. name)
                end
            end
        end
    end
end

-- KOREADER_REF names what was checked (CI passes the tag); else the checkout's commit.
local function commit()
    local p = io.popen('git -C "' .. root .. '" rev-parse --short HEAD 2>/dev/null')
    local c = p:read("*l")
    p:close()
    return c
end
local version = os.getenv("KOREADER_REF") or commit() or "unknown"
check(root, NEEDS, "")
if base then check(base, BASE, "base ") end

table.sort(missing)
print("KOReader " .. tostring(version) .. (base and "" or " (koreader-base not given: ffi checks skipped)"))
if #missing == 0 then
    print("all hooked symbols present")
    os.exit(0)
end
print("missing: " .. table.concat(missing, ", "))
os.exit(1)

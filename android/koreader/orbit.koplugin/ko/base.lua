-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- KOReader side
---------------------------------------------------------------------------------------------

Device = require("device")
logger = require("logger")

function log(...)
    logger.info("OrbitAndroid:", ...)
end

if not Device:isAndroid() then
    log("not Android; patch inactive")
    INACTIVE = true -- main.lua stops loading here
    return
end

ffi = require("ffi")
ConfirmBox = require("ui/widget/confirmbox")
Dispatcher = require("dispatcher")
InfoMessage = require("ui/widget/infomessage")
NetworkMgr = require("ui/network/manager")
PluginLoader = require("pluginloader")
TextViewer = require("ui/widget/textviewer")
UIManager = require("ui/uimanager")
WidgetContainer = require("ui/widget/container/widgetcontainer")
time = require("ui/time")
Event = require("ui/event")
_ = require("gettext")

has_android, android = pcall(require, "android")

function now_s()
    return time.to_s(time.now())
end

function fmt(seconds)
    return string.format("%.1fs", seconds or 0)
end

---------------------------------------------------------------------------------------------

-- Shared native-hook chain, once per feature. No transport or catalog interpretation.
function wrap(Cls,name,make,feature)
    local stock=rawget(Cls,"__orbit_stock") or {};rawset(Cls,"__orbit_stock",stock)
    local key=feature and (feature..":"..name) or name
    if stock[key] then return end
    stock[key]=Cls[name];Cls[name]=make(stock[key])
end

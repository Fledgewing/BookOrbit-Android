-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

OrbitAndroid = WidgetContainer:extend{
    name = "orbit", -- PluginLoader names it after its folder, orbit.koplugin
    fullname = "BookSync",
    is_doc_only = false,
}

function OrbitAndroid:init() return Library.initializePlugin(self) end

function OrbitAndroid:onDispatcherRegisterActions()
    for i,action in ipairs(Library.actions()) do
        if i<=8 then Dispatcher:registerAction(action.id,{category="none",event=action.event,title=_(action.title),general=true}) end
    end
    Dispatcher:registerAction("orbit_sync_and_sleep",
        { category = "none", event = "OrbitSyncAndSleep", title = _("BookSync: sync and sleep"), general = true })
    Dispatcher:registerAction("orbit_go_home",
        { category = "none", event = "OrbitGoHome", title = _("BookSync: go to library home"), general = true })
    Dispatcher:registerAction("orbit_open_companion",
        { category = "none", event = "OrbitOpenCompanion", title = _("BookSync: Reader Status"), general = true })
    Dispatcher:registerAction("orbit_open_apps",
        { category = "none", event = "OrbitOpenApps", title = _("BookSync Companion: apps"), general = true, separator = true })
end

function OrbitAndroid:onLibrarySyncAll() return Library.syncCurrent(function() end) end
function OrbitAndroid:onLibraryThisBook() return ReaderPanel.show(self.ui,"reader-top-panel") end

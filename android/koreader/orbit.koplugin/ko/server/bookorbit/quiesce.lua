-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Migration-only retirement gate: this module never calls the retired transport.
-- Installed while PluginLoader is still loading classes, before any instances start.
SyncRetirement = { safe = not (PluginLoader.loaded_plugins and PluginLoader.loaded_plugins.bookorbit) }
local function retired() return nil, "sync_owned_by_companion" end
local function disarm(plugin)
    if plugin and plugin.name == "bookorbit" then
        for _,name in ipairs({"requestLifecycleOutboxDrain","requestProgressPull","requestProgressPush",
            "fetchRemoteProgress","enqueueLifecycleSnapshot","startSweep","onBookOrbitSyncBook","onStart","_onSuspend","_onCloseDocument","_onPageUpdate","_onResume","_onNetworkConnected","_onNetworkDisconnecting",
            "onReaderReady","registerEvents","schedulePeriodicPush","requestAnnotationExchange","requestOpenBookMatch",
            "requestSweep","requestManualBookSync","scheduleOpenAnnotationSync","submitSyncJob","startMatchRecheck"}) do
            plugin[name] = retired
        end
    end
    local api = package.loaded.bookorbit_api
    if type(api) == "table" then
        -- This closes even bypasses from a legacy scheduled job. No original method is invoked.
        for _,name in ipairs({"request","requestBlocking","getProgress","updateProgress","matchCheck","uploadPageStats",
            "uploadAnnotations","exchangeAnnotations","exchangeAck","exchangeBookmarks","exchangeBookmarksAck",
            "uploadBookStates","bulkProgress","sweepComplete"}) do api[name] = retired end
    end
end
for _,plugin in ipairs(PluginLoader.enabled_plugins or {}) do disarm(plugin) end
if type(PluginLoader.createPluginInstance) == "function" then
    local stock = PluginLoader.createPluginInstance
    function PluginLoader:createPluginInstance(plugin, ...)
        disarm(plugin)
        return stock(self, plugin, ...)
    end
else
    -- No known startup seam: retain all source data and refuse companion ownership.
    SyncRetirement.safe = false
end

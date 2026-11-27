-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Local migration metadata only. Retire complete legacy classes before instance startup;
-- no original method is invoked, and a late/missing handshake never activates our writer.
NativeRetirement={}
SyncRetirement={safe=false}
local result=Library.bootstrap()
if result and result.ok=="1" and type(result.body)=="string" and #result.body<=16384 then
    local plan=Cache.decode(result.body)
    if type(plan)=="table" and type(plan.plugins)=="table" and #plan.plugins<=4 and type(plan.modules)=="table" and #plan.modules<=8 then
        NativeRetirement.plan=plan
        HomePlan.SERVER_HOME=plan.home_key or HomePlan.SERVER_HOME
        local function retired() return nil,"companion_owned" end
        local function disable(target,keep_constructor)
            if type(target)~="table" then return end
            for name,value in pairs(target) do
                if type(value)=="function" and (not keep_constructor or name~="new") then target[name]=retired end
            end
        end
        local function disarm(plugin)
            for _,id in ipairs(plan.plugins) do
                if plugin and plugin.name==id then
                    NativeRetirement.defaults=plugin.default_settings
                    disable(plugin,true)
                end
            end
            for _,id in ipairs(plan.modules) do disable(package.loaded[id],false) end
        end
        local late=false
        for _,id in ipairs(plan.plugins) do if PluginLoader.loaded_plugins and PluginLoader.loaded_plugins[id] then late=true end end
        for _,plugin in ipairs(PluginLoader.enabled_plugins or {}) do disarm(plugin) end
        if type(PluginLoader.createPluginInstance)=="function" then
            local stock=PluginLoader.createPluginInstance
            function PluginLoader:createPluginInstance(plugin,...)
                disarm(plugin)
                return stock(self,plugin,...)
            end
            SyncRetirement.safe=not late
        end
    end
end

-- SPDX-License-Identifier: MIT
-- Test-only user patch installed on a dedicated emulator, never packaged with BookSync.
local UI=require("ui/uimanager")
local base="/sdcard/koreader/e2e-"
local function run()
    UI:scheduleIn(.2,run)
    local file=io.open(base.."command.lua","rb")
    if not file then return end
    local code=file:read("*a");file:close();os.remove(base.."command.lua")
    local plugin=require("pluginloader"):getPluginInstance("orbit")
    local ok,result=pcall(function()
        assert(plugin,"plugin not loaded")
        local method=plugin.onSuspend
        -- KOReader's HandlerSandbox retains the original function as .f.
        if type(method)=="table" then method=method.f end
        local env=getfenv(assert(method,"Home handler missing"))
        local top=env.topWidget or function() return UI:getTopmostVisibleWidget() end
        local chunk=assert(loadstring(code))
        local function click(text)
            local seen={}
            local function visit(node)
                if type(node)~="table" or seen[node] then return false end
                seen[node]=true
                if node.text==text and node.callback then node.callback();return true end
                for _,child in ipairs(node) do if visit(child) then return true end end
                if node.buttons and visit(node.buttons) then return true end
                return false
            end
            assert(visit(top()),"missing button: "..text)
        end
        setfenv(chunk,setmetatable({plugin=plugin,UI=UI,click=click,top=top},{__index=env}))
        return chunk()
    end)
    local out=assert(io.open(base.."result","wb"));out:write(ok and "OK\n" or "FAIL\n",tostring(result));out:close()
end
UI:scheduleIn(1,run)

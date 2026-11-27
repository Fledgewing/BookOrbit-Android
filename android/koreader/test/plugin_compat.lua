-- BookSync retires the legacy plugin instead of calling its UI or transport methods.
-- Check only the pinned metadata/settings that the companion migration still consumes.
-- Run: luajit plugin_compat.lua <bookorbit.koplugin directory>
local dir=assert(arg[1],"plugin directory required")
local function read(name)
    local f=assert(io.open(dir.."/"..name,"rb"),name);local s=f:read("*a");f:close();return s
end
local main=read("main.lua")
assert(main:match('name%s*=%s*["\']bookorbit["\']'),"legacy class identity changed: update the companion retirement descriptor")
assert(main:find("default_settings",1,true),"native setting defaults no longer available")
for _,key in ipairs({"auto_sync","sync_forward","sync_backward","catalog_auto_open"}) do
    assert(main:find(key,1,true),"native setting changed: "..key)
end
for _,entry in ipairs({{"PROMPT",1},{"SILENT",2},{"DISABLE",3}}) do
    assert(main:match(entry[1].."%s*=%s*"..entry[2]),"native direction value changed: "..entry[1])
end
read("bookorbit_api.lua") -- the companion retirement descriptor disables this complete module
local state=read("bookorbit_state.lua")
assert(state:find("bookorbit_sync_state",1,true),"native import source filename changed")
local outbox=read("bookorbit_lifecycle_outbox.lua")
assert(outbox:find("payload_generation",1,true),"native lifecycle generation format changed")
assert(outbox:find("acknowledged",1,true),"native lifecycle checkpoint format changed")
print("legacy retirement metadata and migration formats match the pinned plugin; no UI/transport dependency")

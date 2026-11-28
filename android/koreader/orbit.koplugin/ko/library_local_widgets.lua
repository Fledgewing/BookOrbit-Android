-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Local native access stays behind Library; the host alone requests projections.
function Library.localWidgetNeed(id)
    if id=="achievements" then return {op="account.badges",limit=1} end
    if id=="next-stop" then
        local ui=liveUI();return {op="local.nextstop",limit=1,native=ui and ui.document and Library.readerInput(ui,true) or {}}
    end
    if id=="sync-controls" or id=="reader-toggles" then return {op="local.controls",limit=1,native=Library.controlInput()} end
    if id=="dust" then local ui=liveUI();local pick=S.home_dust_pick or {};return {op="local.dust",limit=1,day=pick.day,pick=pick.skip,exclude_path=ui and ui.document and ui.document.file} end
    if id=="recommended" or id=="discover" then
        return {op="personal.reading",kind=id,limit=1,pick=id=="discover" and (S.home_discover_pick or 0) or nil}
    end
    if id=="highlight" or id=="yearago" then return {op="personal.reading",kind=id,limit=1} end
    local need={op="local."..id,limit=1}
    if id=="light" then
        local device=require("device")
        local supported=device.hasFrontlight and device:hasFrontlight() or false
        local power=supported and device:getPowerDevice()
        need.native={supported=supported,level=power and power:frontlightIntensity()}
    end
    return need
end
function Library.localWidgetAction(action,value)
    if action:match("^control%-") then return Library.controlAction(action) end
    if action=="dust-another" then
        if type(value)~="table" or type(value.day)~="string" or not value.day:match("^%d%d%d%d%-%d%d%-%d%d$") or type(value.pick)~="number" or value.pick~=value.pick or value.pick<0 or value.pick>1000000000 then return false end
        S.home_dust_pick={day=value.day,skip=math.max(0,math.min(1000000000,math.floor(value.pick)+1))};saveSettings();G_reader_settings:flush();Library.retry();return true
    end
    if action=="discover-another" then
        S.home_discover_pick=((S.home_discover_pick or 0)+1)%1000000000
        saveSettings(); Library.retry(); return true
    end
    if action=="word-lookup" then
        if type(value)~="string" or #value>384 or value=="" then return false end
        local ui=liveUI() or require("apps/filemanager/filemanager").instance
        if ui and ui.dictionary then ui.dictionary:onLookupWord(value,true); return true end
        return false
    end
    if action=="light-down" or action=="light-up" then
        local need=Library.localWidgetNeed("light")
        if not need.native.supported or not need.native.level then return false end
        return Library.readerControl({},"light",math.max(0,math.min(100,need.native.level+(action=="light-up" and 10 or -10))))
    end
    return false
end

-- Native font metadata and one glyph probe, without a directory scan or document parse.
function Library.glyphFace(codepoint,size)
    if type(codepoint)~="number" or codepoint~=math.floor(codepoint) or codepoint<65 or codepoint>90 then return nil end
    local ok,face,name=pcall(function()
        local f=require("ui/font"):getFace("cfont",size)
        if not f or not f.ftsize:hasGlyph(codepoint) then return nil end
        return f,f.ftsize:getInfo().name
    end)
    if ok then return face,name end
end

-- Cached native scalars only; no packet counters, folder scans or server work.
function Library.controlInput()
    local controller=Library.controller()
    local last=type(S.last_sleep_sync)=="table" and S.last_sleep_sync or {}
    local device=require("device")
    local ui=liveUI() or require("apps/filemanager/filemanager").instance
    local holds=Wifi.state().n or 0
    local busy=Wifi.busy() or holds>0
    return {sync_available=controller~=nil,sync_busy=controller and controller.sas_running==true,
        at=last.at,ok=last.ok,kind=last.reason,
        wifi_available=S.wifi_via_companion==true and Companion.has("wifi"),wifi_on=Wifi.radioOn(),wifi_busy=busy==true,
        night=G_reader_settings:isTrue("night_mode"),rotate_available=ui~=nil and device.screen.getRotationMode~=nil}
end
function Library.controlAction(action)
    local n=Library.controlInput()
    if action=="control-sync" then
        if not n.sync_available or n.sync_busy then return false end
        local result=Library.syncNow(Library.controller())
        Library.retry();return result
    elseif action=="control-wifi" then
        if not n.wifi_available or n.wifi_busy or type(n.wifi_on)~="boolean" then return false end
        if n.wifi_on then Companion.wifiOff("home_manual",false)
        else Companion.netUp("home_manual",{owner="manual"}) end
    elseif action=="control-night" then
        local ui=liveUI() or require("apps/filemanager/filemanager").instance
        require("device/devicelistener"):new{ui=ui}:onToggleNightMode()
    elseif action=="control-rotate" then
        if not n.rotate_available then return false end
        local ui=liveUI() or require("apps/filemanager/filemanager").instance
        require("device/devicelistener"):new{ui=ui}:onIterateRotation()
    else return false end
    Library.retry();return true
end

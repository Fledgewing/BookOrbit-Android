-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Local native access stays behind Library; the host alone requests projections.
function Library.localWidgetNeed(id)
    if id=="next-stop" then
        local ui=liveUI();return {op="local.nextstop",limit=1,native=ui and ui.document and Library.readerInput(ui,true) or {}}
    end
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

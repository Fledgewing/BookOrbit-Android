-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Local native access stays behind Library; the host alone requests projections.
function Library.localWidgetNeed(id)
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
LocalWidgets = {}
function LocalWidgets.render(p,snapshot,dispatch,rect)
    local finish=Budgets.span("local-widget."..p.widget,now_s,log)
    assert(Budgets.check(Budgets.get("widgets",p.widget),{rows=1,bytes=snapshot.bytes,snapshotBytes=snapshot.bytes,spawns=0,network=0,roundTrips=0}))
    local plan=LocalWidgetPlan.build(p.widget,snapshot)
    local scale=function(n) return Device.screen:scaleBySize(n) end
    local w,h=rect.w-2,rect.h-2
    local pad=scale(10)
    local c=HomeWidgets.canvas(w,h)
    HomeWidgets.text(c,p.widget=="light" and plan.ready and plan.message or _(plan.title),pad,pad,w-2*pad,18,false,true)
    if p.widget=="word" and plan.word then
        if p.h==1 then
            HomeWidgets.button(c,plan.word.." ›",pad,h-pad-scale(50),w-2*pad,scale(50),function() dispatch("word-lookup",plan.word) end)
        else
            HomeWidgets.text(c,plan.word,pad,pad+scale(30),w-2*pad,22,false,true)
            HomeWidgets.text(c,plan.context or "",pad,pad+scale(60),w-2*pad,14)
            HomeWidgets.text(c,plan.source or "Source unavailable",pad,pad+scale(83),w-2*pad,13)
            HomeWidgets.button(c,_("Look up ›"),pad,h-pad-scale(50),w-2*pad,scale(50),function() dispatch("word-lookup",plan.word) end)
        end
    elseif p.widget=="light" and plan.ready then
        local bw=math.floor((w-3*pad)/2)
        if p.h>1 then HomeWidgets.text(c,plan.message,pad,pad+scale(36),w-2*pad,22,false,true) end
        HomeWidgets.button(c,"−",pad,h-pad-scale(50),bw,scale(50),function() dispatch("light-down") end)
        HomeWidgets.button(c,"+",2*pad+bw,h-pad-scale(50),bw,scale(50),function() dispatch("light-up") end)
    else
        -- A single bounded line in compact cards; no hidden history or render reads.
        HomeWidgets.text(c,_(plan.message),pad,pad+scale(32),w-2*pad,14)
        if plan.retry then
            if p.h==1 then table.remove(c) end -- compact message is itself the retry target
            HomeWidgets.button(c,_(p.h==1 and plan.message or "Retry"),pad,h-pad-scale(50),w-2*pad,scale(50),function() dispatch("retry") end)
        end
    end
    finish()
    return HomeWidgets.ui().Frame:new{padding=0,margin=0,bordersize=1,c}
end
for _,id in ipairs({"word","light","buddy"}) do
    local name=id
    HomeWidgets.register(name,LocalWidgets.render,function() return Library.localWidgetNeed(name) end)
    WidgetRegistry[name].renderers={['android-tablet']=LocalWidgets.render}
end

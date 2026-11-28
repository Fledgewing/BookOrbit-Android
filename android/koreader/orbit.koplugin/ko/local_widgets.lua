-- SPDX-License-Identifier: AGPL-3.0-or-later
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
    if (p.widget=="recommended" or p.widget=="discover") and plan.ready and plan.book then
        local bw=p.widget=="discover" and math.floor((w-3*pad)/2) or w-2*pad
        if p.h>1 then
            HomeWidgets.text(c,plan.book.title or _("Untitled"),pad,pad+scale(36),w-2*pad,18,false,true)
            HomeWidgets.text(c,plan.source or "",pad,pad+scale(68),w-2*pad,13)
        end
        HomeWidgets.button(c,p.h==1 and (plan.book.title or _("Untitled")) or _("Open book ›"),pad,h-pad-scale(50),bw,scale(50),function() dispatch("book",plan.book) end)
        if p.widget=="discover" then
            HomeWidgets.button(c,_("Another"),2*pad+bw,h-pad-scale(50),bw,scale(50),function() dispatch("discover-another") end)
        end
    elseif (p.widget=="highlight" or p.widget=="yearago") and plan.ready then
        local content=p.widget=="highlight" and plan.passage or plan.book_title
        if p.widget=="highlight" and p.h>1 then
            local u=HomeWidgets.ui()
            HomeWidgets.put(c,require("ui/widget/textboxwidget"):new{text=content or "",face=u.Font:getFace("cfont",16),
                width=w-2*pad,height=math.max(scale(20),h-2*pad-scale(120)),height_adjust=false},pad,pad+scale(30))
        else
            HomeWidgets.text(c,content or "",pad,pad+scale(30),w-2*pad,p.h==1 and 13 or 16)
        end
        if p.h>1 then
            HomeWidgets.text(c,plan.summary or plan.source or "On this reader",pad,p.widget=="highlight" and h-pad-scale(76) or pad+scale(65),w-2*pad,13)
            if p.widget=="highlight" and plan.book then
                HomeWidgets.button(c,_("Open book ›"),pad,h-pad-scale(50),w-2*pad,scale(50),function() dispatch("book",plan.book) end)
            end
        elseif p.widget=="yearago" then
            HomeWidgets.text(c,plan.summary or "",pad,pad+scale(53),w-2*pad,12)
        elseif p.widget=="highlight" and plan.book then
            table.remove(c)
            HomeWidgets.text(c,plan.source or "On this reader",pad,pad+scale(22),w-2*pad,12)
            HomeWidgets.button(c,content or _("Open book ›"),pad,h-pad-scale(50),w-2*pad,scale(50),function() dispatch("book",plan.book) end)
        end
    elseif (p.widget=="moon" or p.widget=="glyph") and plan.ready then
        local d=snapshot.data or {}
        if p.widget=="moon" then
            HomeWidgets.text(c,d.phase or "Unknown phase",pad,pad+scale(30),w-2*pad,20,false,true)
            HomeWidgets.text(c,"≈ "..tostring(d.illumination or "—").."% lit",pad,pad+scale(60),w-2*pad,24)
            HomeWidgets.text(c,d.next or "Next phase unavailable",pad,pad+scale(100),w-2*pad,12)
            HomeWidgets.text(c,d.source or "Approximate",pad,h-pad-scale(12),w-2*pad,10)
        else
            local face,font=Library.glyphFace(d.codepoint,60)
            if face then
                -- Reuse the exact probed face; no fallback glyph is presented as a sample.
                local sample=require("ui/widget/textwidget"):new{text=d.sample,face=face,max_width=w-2*pad}
                HomeWidgets.put(c,sample,pad,pad+scale(24))
                HomeWidgets.text(c,d.name or "Glyph",pad,pad+scale(100),w-2*pad,12)
                HomeWidgets.text(c,(d.code or "").." · "..(font or d.source or "Font"),pad,h-pad-scale(12),w-2*pad,10)
            else HomeWidgets.text(c,"Glyph unavailable in the interface font",pad,pad+scale(36),w-2*pad,13) end
        end
    elseif p.widget=="next-stop" and plan.ready then
        local d=snapshot.data or {}
        HomeWidgets.text(c,d.current,pad,pad+scale(26),w-2*pad,11)
        HomeWidgets.text(c,d.next,pad,pad+scale(44),w-2*pad,12,false,true)
        HomeWidgets.text(c,d.to_next,pad,pad+scale(64),w-2*pad,16)
        HomeWidgets.text(c,d.to_end,pad,pad+scale(87),w-2*pad,11)
        HomeWidgets.text(c,d.remaining,pad,pad+scale(104),w-2*pad,10)
        HomeWidgets.text(c,d.source or "On this reader",pad,h-pad-scale(12),w-2*pad,9)
    elseif p.widget=="word" and plan.word then
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
for _,id in ipairs({"next-stop","moon","glyph","word","light","buddy","highlight","yearago","recommended","discover"}) do
    local name=id
    HomeWidgets.register(name,LocalWidgets.render,function() return Library.localWidgetNeed(name) end)
    WidgetRegistry[name].renderers={['android-tablet']=LocalWidgets.render}
end

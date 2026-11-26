-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Host supplies one immutable reading.stats snapshot, placement pixels and grid height.
-- No reads, timers or dispatch: the library/host owns batching and invalidation.
ReadingStatsWidgets = {}
function ReadingStatsWidgets.render(id, snapshot, placement)
    local finish=Budgets.span(id..'.render',now_s,log)
    local budget=Budgets.get('widgets',id)
    local bytes=placement.snapshotBytes or #Cache.encode(snapshot or {})
    assert(Budgets.check(budget,{rows=1,bytes=bytes,snapshotBytes=bytes,spawns=0,network=0,roundTrips=0}))
    local scale=Device and Device.screen:scaleBySize(100)/100 or 1
    local width,height=placement.w/scale,placement.h/scale
    local plan=ReadingStatsPlan.build(id,snapshot,width,height,placement.rows)
    local Widget = require('ui/widget/widget')
    local Geom = require('ui/geometry')
    local Font = require('ui/font')
    local Text = require('ui/widget/textwidget')
    local BB = require('ffi/blitbuffer')
    local widget=Widget:new{dimen=Geom:new{w=placement.w,h=placement.h}}
    local texts={}
    local function text(x,y,value,bold,size,width)
        texts[#texts+1]={x=x*scale,y=y*scale,widget=Text:new{text=value,face=Font:getFace('cfont',size or (bold and 18 or 12)),
            bold=bold, max_width=math.max(1,math.min(width and width*scale or placement.w,placement.w-x*scale-8*scale))}}
    end
    text(8,4,plan.title,true)
    if plan.source then
        local weekStrip=id=='this-week' and plan.sourceInline
        local x,y=weekStrip and 112 or plan.sourceInline and math.max(180,width-160) or 8,plan.sourceInline and 4 or 24
        local badgeWidth=weekStrip and 118 or math.min(width-x-6,154)
        plan.sourceRect={x=x-2,y=y-1,w=badgeWidth,h=16}
        text(x,y,plan.source,false,11,badgeWidth-4)
    end
    if plan.message then text(8,plan.source and 44 or 32,plan.message) end
    for _,v in ipairs(plan.labels) do text(v.x,v.y,v.text,v.bold,v.size,v.width) end
    local colors={BB.COLOR_WHITE,BB.COLOR_LIGHT_GRAY,BB.COLOR_GRAY,BB.COLOR_DARK_GRAY,BB.COLOR_BLACK}
    function widget:paintTo(bb,x,y)
        local done=Budgets.span(id..'.paint',now_s,log)
        bb:paintRect(x,y,self.dimen.w,self.dimen.h,BB.COLOR_WHITE)
        for _,r in ipairs(plan.rects) do
            bb:paintRect(x+math.floor(r.x*scale),y+math.floor(r.y*scale),math.max(0,math.floor(r.w*scale)),math.max(0,math.floor(r.h*scale)),colors[r.level+1])
            if r.outline or r.level==0 and r.w>=1 and r.h>=1 then
                local color=r.outline and BB.COLOR_BLACK or BB.COLOR_LIGHT_GRAY
                local rx,ry,rw,rh=x+math.floor(r.x*scale),y+math.floor(r.y*scale),math.max(1,math.floor(r.w*scale)),math.max(1,math.floor(r.h*scale))
                bb:paintRect(rx,ry,rw,1,color); bb:paintRect(rx,ry+rh-1,rw,1,color)
                bb:paintRect(rx,ry,1,rh,color); bb:paintRect(rx+rw-1,ry,1,rh,color)
            end
        end
        if plan.sourceRect then
            local r=plan.sourceRect
            local sx,sy,sw,sh=x+r.x*scale,y+r.y*scale,r.w*scale,r.h*scale
            bb:paintRect(sx,sy,sw,1,BB.COLOR_BLACK); bb:paintRect(sx,sy+sh-1,sw,1,BB.COLOR_BLACK)
            bb:paintRect(sx,sy,1,sh,BB.COLOR_BLACK); bb:paintRect(sx+sw-1,sy,1,sh,BB.COLOR_BLACK)
        end
        for _,t in ipairs(texts) do t.widget:paintTo(bb,x+math.floor(t.x),y+math.floor(t.y)) end
        done()
    end
    function widget:free() for _,t in ipairs(texts) do t.widget:free() end end
    finish()
    return widget
end
for _,id in ipairs({'year-in-reading','this-week','when-you-read','reading-records'}) do
    local name=id
    WidgetRegistry[name].renderers=WidgetRegistry[name].renderers or {}
    WidgetRegistry[name].renderers['android-tablet']=function(snapshot,placement)
        return ReadingStatsWidgets.render(name,snapshot,placement)
    end
end

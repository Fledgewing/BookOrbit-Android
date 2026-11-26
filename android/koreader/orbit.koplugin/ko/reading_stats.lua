-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Host supplies one immutable reading.stats snapshot, placement pixels and grid height.
-- No reads, timers or dispatch: the library/host owns batching and invalidation.
ReadingStatsWidgets = {}
function ReadingStatsWidgets.render(id, snapshot, placement)
    local finish=Budgets.span(id..'.render',now_s,log)
    local budget=Budgets.get('widgets',id)
    local bytes=#Cache.encode(snapshot or {})
    assert(Budgets.check(budget,{rows=1,bytes=bytes,snapshotBytes=bytes,spawns=0,network=0,roundTrips=0}))
    local plan=ReadingStatsPlan.build(id,snapshot,placement.w,placement.h,placement.rows)
    local Widget = require('ui/widget/widget')
    local Geom = require('ui/geometry')
    local Font = require('ui/font')
    local Text = require('ui/widget/textwidget')
    local BB = require('ffi/blitbuffer')
    local widget=Widget:new{dimen=Geom:new{w=placement.w,h=placement.h}}
    local texts={}
    local function text(x,y,value,bold)
        texts[#texts+1]={x=x,y=y,widget=Text:new{text=value,face=Font:getFace('cfont',bold and 18 or 12),
            bold=bold, max_width=math.max(1,placement.w-x-8)}}
    end
    text(8,4,plan.title,true)
    if plan.message then text(8,32,plan.message) end
    for _,v in ipairs(plan.labels) do text(v.x,v.y,v.text) end
    local colors={BB.COLOR_WHITE,BB.COLOR_LIGHT_GRAY,BB.COLOR_GRAY,BB.COLOR_DARK_GRAY,BB.COLOR_BLACK}
    function widget:paintTo(bb,x,y)
        local done=Budgets.span(id..'.paint',now_s,log)
        bb:paintRect(x,y,self.dimen.w,self.dimen.h,BB.COLOR_WHITE)
        for _,r in ipairs(plan.rects) do
            bb:paintRect(x+math.floor(r.x),y+math.floor(r.y),math.max(0,math.floor(r.w)),math.max(0,math.floor(r.h)),colors[r.level+1])
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

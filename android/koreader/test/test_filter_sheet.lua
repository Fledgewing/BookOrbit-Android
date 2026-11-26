-- SPDX-License-Identifier: AGPL-3.0-or-later
return function(test, eq, ok, here, M)
    local F=M.FilterSheet
    test("filter: nine reusable rows, context defaults and no caller mutation",function()
        local q={author={"A"},len={max=249}}
        local m=F.new{query=q}
        eq(#m:rows(),9); eq(m:rows()[1].key,"show"); eq(m:rows()[9].key,"gs")
        eq(m:value("author"),"A"); eq(m:value("tags"),"Any"); eq(m:value("len"),"Short")
        m:choose("author",{value="B"}); eq(#q.author,1)
        eq(#F.new{source="on-device"}:rows(),8)
        eq(F.new{source="search"}.query.sort,"match")
        eq(#F.new{source="reading"}:rows(),8)
    end)
    test("filter: chips remove one tick, sort resets order, reset preserves search",function()
        local m=F.new{source="search",query={q="stars",author={"A","B"},show="unread",dir="desc"}}
        local p=m:presentation(3); ok(p.active); eq(p.icon,"filter.filled"); eq(#p.chips,4)
        ok(p.subtitle:find("3 books",1,true))
        m:clear("author","A"); eq(m.query.author[1],"B")
        m:clear("sort"); eq(m.query.dir,"asc"); eq(m.query.sort,"match")
        m:choose("show",{id="any"}); eq(m.query.show,"all")
        m:reset(); eq(m.query.q,"stars"); eq(#m:chips(),0); eq(m:presentation(0).active,false)
        local custom=F.new{defaults={show="unread"}}
        custom:choose("show",{}); eq(custom.query.show,"all"); custom:reset(); eq(custom.query.show,"unread")
    end)
    test("filter: selected zero-count values stay tickable and gray without a number",function()
        local zero=F.option({label="A",value="A",count=0,selected=true},true)
        ok(zero.gray); eq(zero.text,"☑ A")
        eq(F.option({label="Short",count=3,selected=false},false).text,"○ Short · 3")
        local m=F.new{query={tags={"Gone"}}}; m:choose("tags",{value="Gone"}); eq(m.query.tags,nil)
    end)
    test("filter: actual view uses one bounded facet read, returns radios, saves a copy and cancels polling",function()
        local timer
        local request, flushes, result, saved, applied, logs= nil,0,{pending=true,items={}},nil,nil,0
        local e=setmetatable({FilterSheet=F,Layout=M.Layout,Budgets=M.Budgets,now_s=function() return 1 end,
            log=function() logs=logs+1 end,reading=function() return false end,
            Gate={show=function(_,fn) fn() end},
            Library={paint=function(screen)
                ok(screen=="filter" or screen=="filter-picker")
                return {facets=function(_,source,q,field,offset,limit) request={source=source,q=q,field=field,offset=offset,limit=limit}; return result end,
                    flush=function() flushes=flushes+1 end}
            end},UIManager={show=function() end,close=function() end,scheduleIn=function(_,_,fn) timer=fn end,unschedule=function() timer=nil end}}, {__index=_G})
        local dialog={new=function(_,v) v.moveFocusTo=function() end; v.getButtonById=function() return {label_widget={}} end; return v end}
        e.require=function(name)
            if name=="device" then return {screen={getHeight=function() return 1200 end,getWidth=function() return 900 end,scaleBySize=function(_,n) return n end}} end
            if name=="ui/size" then return {padding={buttontable=5}} end
            if name=="ffi/blitbuffer" then return {COLOR_DARK_GRAY=1} end
            eq(name,"ui/widget/buttondialog"); return dialog
        end
        setfenv(assert(loadfile(here .. "/../orbit.koplugin/ko/filter_sheet.lua")),e)()
        local view=e.FilterView.new{source="search",query={q="stars"},onApply=function(q) applied=q end,onSave=function(q) saved=q end}
        view:show(); eq(flushes,1); eq(request.limit,8); eq(request.field,nil); ok(view.retry)
        result={items={},total=7,freshness={saved=true}}
        timer(); eq(view.total,7); eq(view.retry,nil)
        view.dialog.buttons[1][1].callback(); eq(request.field,"show")
        result={items={{id="unread",label="Unread",value="unread",count=3,selected=false}},total=7,freshness={saved=true}}
        view:paint(); view.dialog.buttons[1][1].callback()
        eq(view.model.pick,nil); eq(view.model.query.show,"unread")
        local h=view:header(3); ok(h.active); h.chips[1].callback(); eq(view.model.query.show,"all")
        view.dialog.buttons[11][1].callback() -- divider makes the save row 11
        eq(saved.source,"custom-filter"); eq(saved.query.q,"stars"); ok(applied); eq(view.alive,false)
        saved.query.q="changed"; eq(view.model.query.q,"stars"); ok(logs>0)
        local b=M.Budgets.get("screens","filter-picker")
        eq(b.spawns,0); eq(b.network,0); eq(b.roundTrips,1)
        eq(M.Budgets.check(b,{rows=25,bytes=0,spawns=0,roundTrips=0,network=0,snapshotBytes=0}),nil)
    end)
end

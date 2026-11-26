-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Original KOReader renderers. Only the host owns queries and invalidation.
HomeWidgets = {renderers={},needs={}}
function HomeWidgets.register(id, renderer, need)
    assert(WidgetRegistry[id] and Budgets.widgets[id], "Widget contract/budget required")
    HomeWidgets.renderers[id]=renderer
    HomeWidgets.needs[id]=need
end
function HomeWidgets.ui()
    if HomeWidgets._ui then return HomeWidgets._ui end
    local u={}
    for k,path in pairs({Overlap="overlapgroup",Frame="container/framecontainer",Text="textwidget",Button="button",Progress="progresswidget"}) do
        u[k]=require("ui/widget/"..path)
    end
    u.Font=require("ui/font"); u.BB=require("ffi/blitbuffer")
    HomeWidgets._ui=u; return u
end
function HomeWidgets.canvas(w,h)
    return HomeWidgets.ui().Overlap:new{dimen={w=w,h=h},allow_mirroring=false}
end
function HomeWidgets.put(canvas, child, x,y)
    child.overlap_offset={x,y}; canvas[#canvas+1]=child; return child
end
function HomeWidgets.text(canvas, text, x,y,w,size,ink,bold)
    local u=HomeWidgets.ui()
    return HomeWidgets.put(canvas,u.Text:new{text=tostring(text or ""),face=u.Font:getFace(bold and "tfont" or "cfont",size),
        max_width=w,fgcolor=ink and u.BB.COLOR_WHITE or u.BB.COLOR_BLACK},x,y)
end
function HomeWidgets.button(canvas,text,x,y,w,h,callback)
    return HomeWidgets.put(canvas,HomeWidgets.ui().Button:new{text=text,width=w,height=h,padding=0,bordersize=0,
        text_font_size=16,avoid_text_truncation=false,callback=callback},x,y)
end
function HomeWidgets.card(p, snapshot, dispatch, rect)
    local u=HomeWidgets.ui(); local scale=function(n) return Device.screen:scaleBySize(n) end
    local w,h=rect.w-2,rect.h-2
    local compact=h<scale(120)
    local pad=scale(compact and 8 or 14)
    local canvas=HomeWidgets.canvas(w,h)
    local ready=snapshot.state == "ready" or snapshot.state == "offline-with-data"
    local hero=p.widget == "continue-reading" and ready
    local title=type((p.settings or {}).title) == "string" and p.settings.title or (p.widget == "continue-reading" and "Continue reading" or p.widget == "lists" and "Lists" or "Shelf")
    if hero or p.widget == "lists" then HomeWidgets.text(canvas,_(title),pad,pad,w-2*pad,18,hero,true)
    else HomeWidgets.button(canvas,_(title).."  ›",pad,pad,w-2*pad,scale(30),function() dispatch("all") end) end
    if not ready then
        local labels={loading="Loading…",empty="Nothing here yet",["offline-without-data"]="Not saved yet",error="Couldn't load this widget"}
        if not compact then HomeWidgets.text(canvas,_(labels[snapshot.state] or "Unavailable"),pad,pad+scale(38),w-2*pad,16) end
        HomeWidgets.button(canvas,_("Retry"),pad,h-scale(compact and 34 or 48),w-2*pad,scale(compact and 28 or 38),function() dispatch("retry") end)
    elseif compact then
        local b=snapshot.items[1]
        HomeWidgets.button(canvas,b.title or _("Untitled"),pad,h-scale(34),w-2*pad,scale(28),function() dispatch(p.widget == "lists" and "list" or "book",b) end)
    elseif hero then
        local b=snapshot.items[1]; local coverW=math.min(scale(110),math.floor(w*.23))
        local tx=pad+coverW+scale(18); local tw=w-tx-pad
        -- A typographic cover placeholder until the adapter advertises cached covers.
        local coverH=math.min(h-2*pad-scale(32),math.floor(coverW*1.5))
        local cover=HomeWidgets.canvas(coverW,coverH)
        HomeWidgets.text(cover,"BOOK",scale(8),scale(12),coverW-scale(16),14,true,true)
        HomeWidgets.put(canvas,u.Frame:new{padding=0,margin=0,bordersize=1,color=u.BB.COLOR_WHITE,cover},pad,math.floor((h-coverH)/2))
        local short=h<scale(220)
        HomeWidgets.text(canvas,b.title or _("Untitled"),tx,pad+scale(35),tw,short and 18 or 25,true,true)
        if not short then HomeWidgets.text(canvas,b.authors and b.authors[1] or "",tx,pad+scale(73),tw,16,true) end
        local pct=math.max(0,math.min(100,tonumber(b.progress) or 0))
        if not short then HomeWidgets.text(canvas,string.format("%d%%",pct),tx,h-scale(102),tw,26,true,true) end
        HomeWidgets.put(canvas,u.Progress:new{width=tw,height=scale(9),percentage=pct/100,radius=0,margin_h=0,margin_v=0,
            bordercolor=u.BB.COLOR_WHITE,bgcolor=u.BB.COLOR_DARK_GRAY,fillcolor=u.BB.COLOR_WHITE},tx,h-scale(65))
        HomeWidgets.button(canvas,b.local_path and _("Resume") or _("Book details"),tx,h-scale(47),tw,scale(34),function() dispatch("book",b) end)
    elseif p.widget == "booklist" and (p.settings.style or 0) == 0 then
        local count=math.min(snapshot.count,p.w >= 4 and 4 or 3)
        local cw=math.floor((w-2*pad)/math.max(1,count))
        local coverH=math.max(scale(30),h-2*pad-scale(70))
        for i=1,count do
            local b=snapshot.items[i]; local x=pad+(i-1)*cw
            local cover=HomeWidgets.canvas(cw-scale(8),coverH)
            HomeWidgets.text(cover,"BOOK",scale(6),scale(8),cw-scale(20),12)
            HomeWidgets.button(cover,_("Open"),0,math.max(0,coverH-scale(32)),cw-scale(8),scale(32),function() dispatch("book",b) end)
            HomeWidgets.put(canvas,u.Frame:new{padding=0,margin=0,bordersize=1,cover},x,pad+scale(30))
            HomeWidgets.text(canvas,b.title or _("Untitled"),x,h-pad-scale(30),cw-scale(8),14,false,true)
            HomeWidgets.text(canvas,b.authors and b.authors[1] or "",x,h-pad-scale(12),cw-scale(8),11)
        end
    else
        local rowH=scale(48); local count=math.min(snapshot.count,math.max(0,math.floor((h-2*pad-scale(30))/rowH)))
        for i=1,count do
            local b=snapshot.items[i]
            local label=b.title or b.name or _("Untitled")
            if b.group and b.group ~= "" then label=b.group.." · "..label end
            if p.widget == "lists" and b.count ~= nil then label=label.."  ·  "..tostring(b.count) end
            local y=pad+scale(30)+(i-1)*rowH
            local progress=p.widget == "booklist" and tonumber(b.progress)
            if progress then label=label.."  ·  "..string.format("%d%%",math.max(0,math.min(100,progress))) end
            HomeWidgets.button(canvas,label,pad,y,w-2*pad,progress and rowH-scale(8) or rowH,function()
                dispatch(p.widget == "lists" and "list" or "book",b)
            end)
            if progress then HomeWidgets.put(canvas,u.Progress:new{width=w-2*pad,height=scale(3),radius=0,margin_h=0,margin_v=0,
                percentage=math.max(0,math.min(100,progress))/100},pad,y+rowH-scale(6)) end
        end
    end
    return u.Frame:new{padding=0,margin=0,bordersize=1,radius=scale(10),background=hero and u.BB.COLOR_BLACK or u.BB.COLOR_WHITE,canvas}
end
for _,id in ipairs({"continue-reading","booklist","lists"}) do HomeWidgets.register(id,HomeWidgets.card) end

-- Register the existing stats renderer against the host snapshot contract. The host
-- reads one materialized reading.stats row for all Stats cards in a paint.
HomeWidgets.stats={}
for _,id in ipairs({"year-in-reading","this-week","when-you-read","reading-records"}) do
    local name=id
    HomeWidgets.stats[name]=true
    HomeWidgets.register(name,function(p,snapshot,dispatch,rect)
        return ReadingStatsWidgets.render(name,snapshot.data,{w=rect.w-2,h=rect.h-2,rows=p.h,snapshotBytes=snapshot.bytes})
    end,function() return {op="reading.stats",limit=1} end)
end
HomeWidgets.register("library",function(p,snapshot,dispatch,rect)
    local c=HomeWidgets.canvas(rect.w-2,rect.h-2)
    local scale=function(n) return Device.screen:scaleBySize(n) end
    HomeWidgets.button(c,_("Library").."  ›",scale(8),scale(8),rect.w-scale(16),scale(30),function() dispatch("all") end)
    local d=snapshot.data or {}
    local saved=d.freshness and d.freshness.saved
    local wide=rect.h>=scale(144)
    local half=math.floor((rect.w-scale(16))/2)
    HomeWidgets.text(c,saved and tostring(d.total or 0).." books" or _("Not saved yet"),scale(8),scale(44),wide and half or rect.w-scale(16),20,false,true)
    if wide then
        HomeWidgets.button(c,(d.on_device~=nil and tostring(d.on_device) or "—").._(" on device").." ›",
            scale(8)+half,scale(40),half,scale(50),function() dispatch("device") end)
        for i,group in ipairs({"author","series"}) do
            HomeWidgets.button(c,group=="author" and _("Authors ›") or _("Series ›"),scale(8)+(i-1)*half,
                rect.h-scale(52),half,scale(50),function() dispatch("group",{group=group}) end)
        end
    end
    return HomeWidgets.ui().Frame:new{padding=0,margin=0,bordersize=1,c}
end,function() return {op="library.summary",limit=1} end)
-- Battery history is a library-owned not-saved state until the battery slice lands.
HomeWidgets.register("battery",function(p,snapshot,dispatch,rect)
    local c=HomeWidgets.canvas(rect.w-2,rect.h-2)
    HomeWidgets.text(c,_("Battery"),8,8,rect.w-16,18,false,true)
    HomeWidgets.text(c,_(snapshot.data and snapshot.data.message or "Battery history not recorded yet"),8,44,rect.w-16,14)
    return HomeWidgets.ui().Frame:new{padding=0,margin=0,bordersize=1,c}
end,function() return {op="battery.stats",limit=1} end)

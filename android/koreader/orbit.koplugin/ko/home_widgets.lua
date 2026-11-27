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
    local u={Overlap=require("ui/widget/overlapgroup"),Frame=require("ui/widget/container/framecontainer"),
        Text=require("ui/widget/textwidget"),Button=require("ui/widget/button"),Progress=require("ui/widget/progresswidget")}
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
function HomeWidgets.button(canvas,text,x,y,w,h,callback,enabled)
    return HomeWidgets.put(canvas,HomeWidgets.ui().Button:new{text=text,width=w,height=h,padding=0,bordersize=0,
        text_font_size=16,avoid_text_truncation=false,callback=callback,enabled=enabled~=false},x,y)
end
-- First paint is a placeholder. Native bitmap decoding is deferred and its resource
-- belongs to this node: freeing/rebuilding the host cancels late delivery.
function HomeWidgets.cover(canvas,book,x,y,w,h,ink)
    local u=HomeWidgets.ui()
    local placeholder=HomeWidgets.canvas(w,h)
    HomeWidgets.text(placeholder,"BOOK",4,8,w-8,12,ink,true)
    local node=u.Frame:new{padding=0,margin=0,bordersize=1,placeholder}
    local basePaint,baseFree=node.paintTo,node.free
    function node:paintTo(bb,px,py)
        if not self.started then
            self.started=true
            self.cancel=Library.prepareCardCover(book,function(path)
                if self.released then return end
                local finish=Budgets.span("card.cover.decode",now_s,log)
                local image
                local ok=pcall(function()
                    image=require("ui/widget/imagewidget"):new{file=path,width=w,height=h,scale_factor=0}
                    image:_render()
                end)
                if ok then
                    self[1]:free(); self[1]=image
                    UIManager:setDirty(nil,"ui",self.dimen)
                elseif image then image:free() end
                finish()
            end,function() return not self.released and HomeHost.active and UIManager:getTopmostVisibleWidget()==HomeHost.active end)
        end
        return basePaint(self,bb,px,py)
    end
    function node:free()
        self.released=true
        if self.cancel then self.cancel(); self.cancel=nil end
        if baseFree then baseFree(self) end
    end
    return HomeWidgets.put(canvas,node,x,y)
end
function HomeWidgets.more(canvas,b,dispatch,x,y,w,h)
    HomeWidgets.button(canvas,"⋯",x,y,w,h,function() dispatch("more",b) end)
end
function HomeWidgets.caption(settings, book)
    local cap=settings.cap or 0
    if cap==1 then return book.added and tostring(book.added):sub(1,10) or "—" end
    if cap==2 then return book.status=="finished" and _("Finished") or book.progress and string.format("%d%%",book.progress) or _("Not started") end
    if cap==3 then return book.authors and book.authors[1] or "" end
    return ""
end
function HomeWidgets.card(p, snapshot, dispatch, rect)
    local u=HomeWidgets.ui(); local scale=function(n) return Device.screen:scaleBySize(n) end
    local geometry=HomeHostPlan.cardGeometry(p,rect,scale)
    local w,h,compact,pad=geometry.w,geometry.h,geometry.compact,geometry.pad
    local canvas=HomeWidgets.canvas(w,h)
    local ready=snapshot.state == "ready" or snapshot.state == "offline-with-data"
    local hero=p.widget == "continue-reading" and ready
    local title=type((p.settings or {}).title) == "string" and p.settings.title or (p.widget == "continue-reading" and "Continue reading" or p.widget == "lists" and "Lists" or "Shelf")
    if compact then
        -- One horizontal band keeps both actions large in a one-row tile.
        HomeWidgets.button(canvas,_(title).." ›",pad,math.floor((h-scale(50))/2),math.floor((w-3*pad)/2),scale(50),function() dispatch("all") end)
    elseif hero or p.widget == "lists" then HomeWidgets.text(canvas,_(title),pad,pad,w-2*pad-(hero and scale(50) or 0),18,hero,true)
    else HomeWidgets.button(canvas,_(title).."  ›",pad,pad,w-2*pad,scale(52),function() dispatch("all") end) end
    if not ready then
        local labels={loading="Loading…",empty=p.widget == "continue-reading" and "Open a book to start reading" or p.widget == "lists" and "No lists yet" or "No books here yet",["offline-without-data"]="Not saved yet",error="Couldn't load this widget"}
        if not compact then HomeWidgets.text(canvas,_(snapshot.setup and "Sign in to load your library" or labels[snapshot.state] or "Unavailable"),pad,pad+scale(58),w-2*pad,16) end
        local rx=compact and math.floor((w+pad)/2) or pad
        local rw=compact and math.floor((w-3*pad)/2) or w-2*pad
        local ry=compact and math.floor((h-scale(50))/2) or h-pad-scale(50)
        if snapshot.setup then
            HomeWidgets.button(canvas,_("Sign in"),rx,ry,rw,scale(50),function() dispatch("setup") end)
        elseif snapshot.state ~= "empty" then
            HomeWidgets.button(canvas,_(compact and (labels[snapshot.state] or "Unavailable") or "Retry"),rx,ry,rw,scale(50),function() dispatch("retry") end)
        elseif compact then
            HomeWidgets.text(canvas,_(p.widget == "lists" and "No lists yet" or "No books yet"),rx,math.floor((h-scale(20))/2),rw,16)
        end
    elseif compact then
        local b=snapshot.items[1]
        local more=p.widget~="lists" and scale(50) or 0
        HomeWidgets.button(canvas,b.title or _("Untitled"),math.floor((w+pad)/2),math.floor((h-scale(50))/2),math.floor((w-3*pad)/2)-more,scale(50),function() dispatch(p.widget == "lists" and "list" or "book",b) end)
        if more>0 then HomeWidgets.more(canvas,b,dispatch,w-pad-more,math.floor((h-scale(50))/2),more,scale(50)) end
    elseif hero then
        local b=snapshot.items[1]; local coverW=math.min(scale(110),math.floor(w*.23))
        local tx=pad+coverW+scale(18); local tw=w-tx-pad
        local coverH=math.min(h-2*pad-scale(32),math.floor(coverW*1.5))
        HomeWidgets.cover(canvas,b,pad,math.floor((h-coverH)/2),coverW,coverH,true)
        HomeWidgets.more(canvas,b,dispatch,w-pad-scale(50),0,scale(50),scale(50))
        local short=h<scale(220)
        HomeWidgets.text(canvas,b.title or _("Untitled"),tx,pad+scale(35),tw,short and 18 or 25,true,true)
        if not short then HomeWidgets.text(canvas,b.authors and b.authors[1] or "",tx,pad+scale(73),tw,16,true) end
        if h>=scale(290) and b.series_line then HomeWidgets.text(canvas,b.series_line,tx,pad+scale(98),tw,14,true) end
        local percentW=scale(short and 48 or 70)
        HomeWidgets.text(canvas,b.time_left or _("Not enough reading yet"),tx+percentW,h-scale(short and 102 or 121),tw-percentW,12,true)
        if h>=scale(290) then HomeWidgets.text(canvas,b.finish_forecast or _("Finish date unavailable"),tx,h-scale(146),tw,13,true) end
        local pct=math.max(0,math.min(100,tonumber(b.progress) or 0))
        HomeWidgets.text(canvas,string.format("%d%%",pct),tx,h-scale(short and 105 or 128),percentW,short and 16 or 26,true,true)
        HomeWidgets.put(canvas,u.Progress:new{width=tw,height=scale(9),percentage=pct/100,radius=0,margin_h=0,margin_v=0,
            bordercolor=u.BB.COLOR_WHITE,bgcolor=u.BB.COLOR_DARK_GRAY,fillcolor=u.BB.COLOR_WHITE},tx,h-scale(78))
        HomeWidgets.button(canvas,b.local_path and _("Resume") or _("Book details"),tx,h-pad-scale(50),tw,scale(50),function() dispatch("book",b) end)
    elseif geometry.shelf then
        local count=math.min(snapshot.count,geometry.capacity)
        local cw=math.floor((w-2*pad)/math.max(1,count))
        local rich=h>=scale(260)
        local coverH=math.max(scale(30),h-2*pad-scale(rich and 144 or 112))
        for i=1,count do
            local b=snapshot.items[i]; local x=pad+(i-1)*cw
            local bw=cw-scale(8)
            HomeWidgets.cover(canvas,b,x,pad+scale(56),bw,coverH)
            -- A blank button preserves the cover underneath; title opens the book.
            local tap=HomeWidgets.button(canvas,"",x,pad+scale(56),bw,math.max(scale(50),coverH),function() dispatch("book",b) end)
            tap.paintTo=function() end
            HomeWidgets.more(canvas,b,dispatch,x+math.max(0,bw-scale(50)),h-pad-scale(50),scale(50),scale(50))
            HomeWidgets.text(canvas,b.title or _("Untitled"),x,h-pad-scale(rich and 74 or 30),math.max(1,cw-scale(60)),14,false,true)
            HomeWidgets.text(canvas,HomeWidgets.caption(p.settings,b),x,h-pad-scale(rich and 56 or 12),math.max(1,cw-scale(60)),11)
            if rich then
                HomeWidgets.text(canvas,b.time_left or _("Not enough reading yet"),x,h-pad-scale(38),math.max(1,cw-scale(60)),11)
                HomeWidgets.text(canvas,b.finish_forecast or _("Finish date unavailable"),x,h-pad-scale(20),math.max(1,cw-scale(60)),11)
            end
        end
    else
        local rowH=geometry.rowH; local count=math.min(snapshot.count,geometry.capacity)
        local dense=rowH<scale(96)
        for i=1,count do
            local b=snapshot.items[i]
            local label=b.title or b.name or _("Untitled")
            if b.group and b.group ~= "" then label=b.group.." · "..label end
            if p.widget == "lists" and b.count ~= nil then label=label.."  ·  "..tostring(b.count) end
            local y=pad+scale(52)+(i-1)*rowH
            local progress=p.widget == "booklist" and tonumber(b.progress)
            if progress then label=label.."  ·  "..string.format("%d%%",math.max(0,math.min(100,progress))) end
            local caption=p.widget=="booklist" and HomeWidgets.caption(p.settings,b) or ""
            if caption~="" and (p.settings.cap~=2 or not progress) then label=label.." · "..caption end
            local books=p.widget=="booklist"
            local bx=books and pad+scale(42) or pad
            if books then HomeWidgets.cover(canvas,b,pad,y+scale(4),scale(34),math.min(scale(51),rowH-scale(8))) end
            HomeWidgets.button(canvas,books and "" or label,bx,y,w-pad-bx-(books and scale(50) or 0),rowH,function()
                dispatch(p.widget == "lists" and "list" or "book",b)
            end)
            if books then
                HomeWidgets.text(canvas,b.title or _("Untitled"),bx,y+scale(4),w-bx-pad-scale(50),14,false,true)
                if not dense then HomeWidgets.text(canvas,caption~="" and caption or b.series_line or (b.authors and b.authors[1]) or "",bx,y+scale(25),w-bx-pad-scale(50),11) end
                local pace=(progress and string.format("%d%% · ",progress) or "")..(b.time_left or _("Not enough reading yet"))
                if dense and caption~="" and not (p.settings.cap==2 and progress and b.status~="finished") then pace=pace.." · "..caption end
                HomeWidgets.text(canvas,pace,bx,y+scale(dense and 25 or 44),w-bx-pad-scale(50),11)
                if not dense then HomeWidgets.text(canvas,b.finish_forecast or _("Finish date unavailable"),bx,y+scale(63),w-bx-pad-scale(50),11) end
                HomeWidgets.more(canvas,b,dispatch,w-pad-scale(50),y,scale(50),rowH)
            end
            if progress then HomeWidgets.put(canvas,u.Progress:new{width=w-2*pad,height=scale(3),radius=0,margin_h=0,margin_v=0,
                percentage=math.max(0,math.min(100,progress))/100},pad,y+rowH-scale(3)) end
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
    return StorageUI.widget(p,snapshot,dispatch,rect)
end,function() return {op="library.summary",limit=1} end)
-- F12-O extends the existing Battery registration with the snapshot-only page renderer.
HomeWidgets.register("battery",function(p,snapshot,dispatch,rect)
    assert(Budgets.check(Budgets.get("widgets","battery"),{rows=1,bytes=snapshot.bytes,
        snapshotBytes=snapshot.bytes,spawns=0,network=0,roundTrips=0}))
    return BatteryUI.widget(p,snapshot,dispatch,rect)
end,function() return {op="battery",limit=1} end)

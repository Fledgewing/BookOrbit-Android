-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Series and grouped lists belong to the existing Home host, not a second screen stack.
SeriesUI = {}
local function scale(n) return Device.screen:scaleBySize(n) end
function SeriesUI.dots(canvas,dots,x,y,w)
    local n=math.min(#dots,24)
    if n==0 then return end
    local gap=scale(5); local width=math.max(1,math.floor((w-gap*(n-1))/n))
    for i=1,n do
        HomeWidgets.put(canvas,HomeWidgets.ui().Progress:new{width=width,height=scale(10),percentage=SeriesPlan.dot(dots[i]),
            radius=scale(5),margin_h=0,margin_v=0},x+(i-1)*(width+gap),y)
    end
end
function SeriesUI.install(host,canvas,metrics)
    local old=host[1]
    host[1]=HomeWidgets.ui().Frame:new{padding=0,margin=0,bordersize=0,background=HomeWidgets.ui().BB.COLOR_WHITE,canvas}
    host.metrics=metrics
    host.changed_rects={{x=0,y=0,w=host.dimen.w,h=host.dimen.h}}
    if old then old:free() end
end
local function header(host,c,title)
    local w=host.dimen.w; local gap=scale(18)
    HomeWidgets.button(c,"‹ Back",gap,scale(12),scale(100),scale(50),function() host:onClose() end)
    HomeWidgets.text(c,title,scale(130),scale(25),w-scale(270),24,false,true)
    HomeWidgets.button(c,"Search",w-scale(118),scale(12),scale(100),scale(50),function() host:search() end)
end
local function message(host,c,result,y)
    local state,label=SeriesPlan.state(result)
    host.catalog_state=state
    if label then HomeWidgets.text(c,label,scale(18),y,host.dimen.w-scale(36),18) end
    if state=="error" or state=="offline-without-data" then
        HomeWidgets.button(c,"Retry",scale(18),y+scale(42),scale(120),scale(50),function()
            Library.retry(); host:rebuild(); UIManager:setDirty(host,"ui")
        end)
    end
    return state=="ready" or state=="offline-with-data"
end
function SeriesUI.book(host,c,b,x,y,w,h)
    -- One target covers number, title, author and status; secondary text never adds a dead action.
    HomeWidgets.button(c,"",x,y,w,h,function() host:dispatch("book",b) end)
    HomeWidgets.text(c,b.number or "",x,y+scale(14),scale(30),16,false,true)
    local cover=HomeWidgets.canvas(scale(48),scale(72))
    HomeWidgets.text(cover,"BOOK",scale(4),scale(28),scale(40),11)
    HomeWidgets.put(c,HomeWidgets.ui().Frame:new{padding=0,margin=0,bordersize=1,cover},x+scale(34),y+scale(8))
    HomeWidgets.text(c,b.title or "Untitled",x+scale(96),y+scale(8),w-scale(104),20,false,true)
    HomeWidgets.text(c,b.authors and b.authors[1] or "",x+scale(96),y+scale(35),w-scale(104),14)
    HomeWidgets.text(c,b.status_text or "",x+scale(96),y+scale(60),w-scale(104),14)
    if b.dot=="reading" and type(b.progress)=="number" then
        HomeWidgets.put(c,HomeWidgets.ui().Progress:new{width=scale(70),height=scale(4),percentage=b.progress/100,
            radius=0,margin_h=0,margin_v=0},x+scale(96),y+scale(84))
    end
end
function SeriesUI.paint(host)
    local w,h=host.dimen.w,host.dimen.h
    local g=SeriesPlan.geometry(w,h,scale)
    local paint=Library.paint("series")
    host.caps=paint:read("capabilities",{limit=1})
    local result
    if host.caps.series and host.caps.series.read==false then result={error="unsupported"}
    else result=paint:series(host.series_key,host.series_offset,g.limit) end
    host.series_result,host.series_limit=result,g.limit-4
    local c=HomeWidgets.canvas(w,h)
    header(host,c,"Series")
    if message(host,c,result,scale(74)) then
        HomeWidgets.text(c,result.title or "Series",g.gap,scale(112),w-2*g.gap,28,false,true)
        HomeWidgets.text(c,result.subtitle or "",g.gap,scale(154),w-2*g.gap,16)
        SeriesUI.dots(c,result.dots or {},g.gap,scale(190),w-2*g.gap)
        if result.dot_caption then HomeWidgets.text(c,result.dot_caption,g.gap,scale(204),w-2*g.gap,12) end
        local y=scale(228)
        local nextBooks=result.next_books or {}
        if #nextBooks>0 then
            HomeWidgets.text(c,"Download the next "..#nextBooks,g.gap,y,w-2*g.gap,18,false,true)
            -- No fabricated size/free-space figure or unavailable transport action.
            HomeWidgets.text(c,"Keeps the series ready offline",g.gap,y+scale(28),w-2*g.gap,14)
            for i,b in ipairs(nextBooks) do
                HomeWidgets.text(c,tostring(b.number or "").."  "..(b.title or "Untitled"),g.gap,y+scale(54+(i-1)*27),w-2*g.gap,15)
            end
            HomeWidgets.text(c,"Downloads unavailable for this source",g.gap,scale(376),w-2*g.gap,14)
        else
            HomeWidgets.text(c,result.remaining_saved and "Every remaining book is on this device." or
                result.local_known and "No remaining books." or "Device state not saved",g.gap,y,w-2*g.gap,16)
        end
        for i,b in ipairs(result.items or {}) do SeriesUI.book(host,c,b,g.gap,g.top+(i-1)*g.row,w-2*g.gap,g.row) end
    end
    if (result.offset or 0)>0 then HomeWidgets.button(c,"‹",g.gap,h-g.bottom,scale(80),scale(50),function() SeriesUI.page(host,-1) end) end
    if result.next then HomeWidgets.button(c,"›",w-g.gap-scale(80),h-g.bottom,scale(80),scale(50),function() SeriesUI.page(host,1) end) end
    SeriesUI.install(host,c,paint:flush())
end
function SeriesUI.page(host,delta)
    local result=host.series_result or {}
    if delta>0 and not result.next then return true end
    host.series_offset=delta>0 and result.next or math.max(0,host.series_offset-(host.series_limit or 1))
    host:rebuild(); UIManager:setDirty(host,"ui"); return true
end
function SeriesUI.groups(host)
    local paint=Library.paint(host.filter.model.source=="search" and "search" or "library")
    host.caps=paint:read("capabilities",{limit=1})
    local settings=host.list_layout.pages[1].placements[1].settings
    local w,h=host.dimen.w,host.dimen.h
    local g=SeriesPlan.geometry(w,h,scale)
    local result=paint:groups(settings.source,settings.query,settings.offset,math.min(24,g.groups*(g.covers+1)),settings.exclude_current,g.covers,g.groups)
    host.list_result,host.list_limit=result,#(result.items or {})
    local c=HomeWidgets.canvas(w,h)
    header(host,c,host.list_title)
    local f=host.filter:header(result.total)
    HomeWidgets.button(c,f.active and "Filter ●" or "Filter",g.gap,scale(74),scale(130),scale(50),f.callback)
    local x=g.gap+scale(140)
    for _,chip in ipairs(f.chips) do
        if x+scale(140)>w-g.gap then break end
        HomeWidgets.button(c,chip.label.." ×",x,scale(74),scale(136),scale(50),chip.callback); x=x+scale(140)
    end
    if message(host,c,result,scale(132)) then
        if host.catalog_state=="ready" then HomeWidgets.text(c,tostring(result.total or 0).." books",g.gap,scale(132),w-2*g.gap,16) end
        for i,row in ipairs(result.items or {}) do
            local y=scale(170)+(i-1)*scale(168)
            local clickable=row.series_key or row.partial
            local title=(row.title or "").." · "..(row.count_text or "")..(clickable and " ›" or "")
            local go=function()
                if row.series_key then host:showSeries(row.series_key)
                else host:showList(row.title,settings.source,SeriesPlan.groupQuery(settings.query,row),settings.exclude_current) end
            end
            if clickable then HomeWidgets.button(c,title,g.gap,y,w-2*g.gap,scale(50),go)
            else HomeWidgets.text(c,title,g.gap,y+scale(14),w-2*g.gap,18,false,true) end
            SeriesUI.dots(c,row.dots or {},w-g.gap-scale(125),y+scale(51),scale(110))
            if row.dot_caption then HomeWidgets.text(c,row.dot_caption,g.gap,y+scale(51),w-2*g.gap-scale(140),11) end
            local books=row.books or {}; local cw=scale(72)
            for j,b in ipairs(books) do
                local bx=g.gap+(j-1)*cw
                HomeWidgets.button(c,"BOOK",bx,y+scale(66),scale(62),scale(93),function() host:dispatch("book",b) end)
                HomeWidgets.text(c,b.title or "Untitled",bx,y+scale(125),cw-scale(14),11,false,true)
                HomeWidgets.text(c,b.status_text or "",bx,y+scale(143),cw-scale(14),10)
            end
        end
    end
    if settings.offset>0 then HomeWidgets.button(c,"‹",g.gap,h-g.bottom,scale(80),scale(50),function() host:listPage(-1) end) end
    if result.next then HomeWidgets.button(c,"›",w-g.gap-scale(80),h-g.bottom,scale(80),scale(50),function() host:listPage(1) end) end
    SeriesUI.install(host,c,paint:flush())
end
-- Group pages consume variable numbers of preview rows; retain actual cursors for Back.
function SeriesUI.groupPage(host,delta)
    local settings=host.list_layout.pages[1].placements[1].settings
    local result=host.list_result or {}
    host.group_offsets=host.group_offsets or {}
    if delta>0 then
        if not result.next then return true end
        host.group_offsets[#host.group_offsets+1]=settings.offset
        settings.offset=result.next
    else
        settings.offset=table.remove(host.group_offsets) or 0
    end
    host:rebuild(); UIManager:setDirty(host,"ui"); return true
end
-- Public entry for Details/Book info and the later end sheet, with no end transport dependency.
function SeriesUI.show(key)
    if not key then return false end
    if not HomeHost.foreground() and not HomeHost.show() then return false end
    HomeHost.active:showSeries(key)
    return true
end

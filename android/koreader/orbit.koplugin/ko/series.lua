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
    if result.membership_incomplete then label="Saved membership incomplete" end
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
    HomeWidgets.cover(c,b,x+scale(34),y+scale(8),scale(48),scale(72))
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
            local enabled=host.caps.series and host.caps.series.downloadNext==true and not result.membership_incomplete
            HomeWidgets.button(c,result.membership_incomplete and "Saved membership incomplete" or enabled and "Download next…" or "Downloads unavailable for this source",
                g.gap,scale(366),w-2*g.gap,scale(50),function() SeriesUI.download(host) end,enabled)
        else
            HomeWidgets.text(c,result.earlier_pending and "Earlier unread books available." or result.remaining_saved and "Every remaining book is on this device." or
                result.local_known and "No remaining books." or "Device state not saved",g.gap,y,w-2*g.gap,16)
        end
        if #nextBooks==0 and host.caps.series and host.caps.series.downloadNext==true then
            HomeWidgets.button(c,result.membership_incomplete and "Saved membership incomplete" or "Series downloads…",g.gap,scale(366),w-2*g.gap,scale(50),function() SeriesUI.download(host) end,not result.membership_incomplete)
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
        if host.catalog_state=="ready" and not result.membership_incomplete then HomeWidgets.text(c,result.context and result.context.coverage or tostring(result.total or 0).." books",g.gap,scale(132),w-2*g.gap,16) end
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
function SeriesUI.show(key,onBack)
    if not key then return false end
    local wasHome=HomeHost.foreground()
    if not wasHome and not HomeHost.show() then return false end
    local host=HomeHost.active
    host:showSeries(key,function()
        if not wasHome then UIManager:close(host)
        else host:rebuild(); UIManager:setDirty(host,"ui") end
        if onBack then onBack() end
    end)
    return true
end

-- Every dialog below follows an explicit Series download action. Async callbacks
-- retain the originating host and never open a book or resurrect a departed sheet.
function SeriesUI.download(host)
    local seriesKey=host.series_key
    local function wanted() return HomeHost.active==host and host.series_key==seriesKey and not reading() end
    local function visible(dialog) return wanted() and UIManager:getTopmostVisibleWidget()==dialog end
    local function show(title,buttons)
        assert(#buttons+1<=Budgets.get("screens","series-downloads").displayRows,"Series display row budget exceeded")
        local finish=Budgets.span("series-downloads.paint",now_s,log)
        local dialog=require("ui/widget/buttondialog"):new{title=title,buttons=buttons}
        UIManager:show(dialog) -- gate: user action (approved Series preview and queue)
        finish();return dialog
    end
    local function notice(text)
        local dialog
        dialog=show(text,{{{text="Back",callback=function() UIManager:close(dialog) end}}})
    end
    local function monitor(result)
        if not wanted() then return end
        if result.error or not result.id then notice("Series downloads unavailable · Try again");return end
        local dialog,closed,pending=nil,false,false
        local function paint(value)
            local buttons={}
            for _,row in ipairs(value.items or {}) do
                local item=row
                buttons[#buttons+1]={{text=(item.title or "Book").." · "..(item.progress_text or item.state or "")..(item.state~="complete" and item.id and " · Cancel" or ""),enabled=item.id~=nil and item.state~="complete" and item.state~="canceled",callback=function()
                    pending=true
                    Library.catalogAction("download.cancel",{id=item.id},function()
                        Library.seriesCommand("status",{id=value.id},function(nextValue) pending=false;if visible(dialog) then UIManager:close(dialog);closed=true;monitor(nextValue) end end)
                    end)
                end}}
            end
            if value.state=="paused" then buttons[#buttons+1]={{text=NetworkMgr:isConnected() and "Resume remaining" or "Connect and resume remaining",callback=function()
                if pending then return end
                pending=true
                local function resume(ready)
                    if not visible(dialog) then return end
                    if not ready then pending=false;return end
                    Library.seriesCommand("resume",{id=value.id},function(nextValue) pending=false;if visible(dialog) then UIManager:close(dialog);closed=true;monitor(nextValue) end end)
                end
                if NetworkMgr:isConnected() then resume(true) else Library.downloadConnect(resume) end
            end}} end
            if value.state~="complete" then buttons[#buttons+1]={{text="Cancel remaining",callback=function()
                pending=true;Library.seriesCommand("cancel",{id=value.id},function(nextValue) pending=false;if visible(dialog) then UIManager:close(dialog);closed=true;monitor(nextValue) end end)
            end}} end
            buttons[#buttons+1]={{text="Back",callback=function() closed=true;UIManager:close(dialog);DownloadUI.update(host) end}}
            dialog=show(value.summary or "Series downloads",buttons)
            dialog.tap_close_callback=function() closed=true end
        end
        paint(result)
        local function poll()
            if closed or not visible(dialog) or result.state=="complete" then return end
            if pending then UIManager:scheduleIn(1,poll);return end
            pending=true
            Library.seriesCommand("status",{id=result.id},function(value)
                pending=false
                if closed or not visible(dialog) then return end
                if not value.error and (tonumber(value.sequence) or 0)>=(tonumber(result.sequence) or 0) then
                    if UIUtil.encode(value)~=UIUtil.encode(result) then UIManager:close(dialog);result=value;paint(value) end
                end
                UIManager:scheduleIn(1,poll)
            end)
        end
        UIManager:scheduleIn(1,poll)
    end
    local params={key=host.series_key,count=3,root=Library.downloadRoot()}
    local function arguments()
        local result={};for key,value in pairs(params) do result[key]=value end;return result
    end
    local preview
    local function resolve(plan)
        local choices,labels={},{}
        local function file(index)
            if not wanted() then return end
            local row=(plan.items or {})[index]
            if not row then
                local buttons={}
                for _,line in ipairs(labels) do if line~="" then buttons[#buttons+1]={{text=line,enabled=false}} end end
                local dialog
                buttons[#buttons+1]={{text="Start downloads",callback=function()
                    UIManager:close(dialog)
                    local args=arguments();args.token=plan.token;args.choices=choices
                    Library.seriesCommand("start",args,function(value) if wanted() and UIManager:getTopmostVisibleWidget()==host then monitor(value) end end)
                end},{text="Back",callback=function() UIManager:close(dialog);preview() end}}
                dialog=show("Download "..#plan.items.." books?",buttons)
                return
            end
            Library.seriesFile(row,params.root,function(options)
                if not wanted() or UIManager:getTopmostVisibleWidget()~=host then return end
                if options.error then notice((row.title or "Book").." · File choices unavailable · Try again");return end
                if #(options.items or {})==0 then
                    labels[#labels+1]=(row.title or "Book").." · No supported file · will fail"
                    file(index+1);return
                end
                local function selected(choice)
                    choices[row.key]={file_reference=choice.file_reference,variant=choice.variant}
                    labels[#labels+1]=(row.title or "Book").." · "..(choice.label or "File").." · "..(choice.bytes and tostring(choice.bytes).." bytes" or "size unknown")
                    params.root=params.root or options.root or Library.downloadRoot()
                    if index==1 then labels[#labels+1]=options.items[1].destination_label or "" end
                    file(index+1)
                end
                if #options.items==1 then selected(options.items[1]);return end
                local buttons,dialog={}
                for _,choice in ipairs(options.items) do
                    local item=choice
                    buttons[#buttons+1]={{text=(item.label or "File").." · "..(item.bytes and tostring(item.bytes).." bytes" or "size unknown"),callback=function() UIManager:close(dialog);selected(item) end}}
                end
                buttons[#buttons+1]={{text="Cancel",callback=function() UIManager:close(dialog) end}}
                dialog=show("Choose file · "..(row.title or "Book"),buttons)
            end)
        end
        file(1)
    end
    preview=function()
        Library.seriesCommand("preview",arguments(),function(plan)
            if not wanted() or UIManager:getTopmostVisibleWidget()~=host then return end
            if plan.error then notice(plan.error=="incomplete" and "Saved membership incomplete · Refresh the catalog before downloading" or "Series preview unavailable");return end
            if #(plan.items or {})==0 and not plan.earlier_key then notice("No eligible books after this position. Nothing will wrap to the beginning.");return end
            local title="Download next "..params.count.." · "..#plan.items.." available"
            local buttons={}
            for _,row in ipairs(plan.items) do buttons[#buttons+1]={{text=(row.number and tostring(row.number).." · " or "")..(row.title or "Book").." · "..(row.bytes and tostring(row.bytes).." bytes" or "size unknown"),enabled=false}} end
            local dialog
            buttons[#buttons+1]={{text=NetworkMgr:isConnected() and "Review files" or "Connect and download "..#plan.items,enabled=#plan.items>0,callback=function()
                UIManager:close(dialog)
                if NetworkMgr:isConnected() then resolve(plan) else Library.downloadConnect(function(ready)
                    if wanted() and UIManager:getTopmostVisibleWidget()==host then if ready then resolve(plan) else notice("Could not connect · Try again") end end
                end) end
            end}}
            buttons[#buttons+1]={{text="Change number (1–10)",callback=function()
                UIManager:close(dialog)
                local input
                input=require("ui/widget/inputdialog"):new{title="Download how many? (1–10)",input=tostring(params.count),input_type="number",buttons={{{text="Cancel",callback=function() UIManager:close(input) end},{text="Review",callback=function()
                    local n=tonumber(input:getInputText())
                    if n and n==math.floor(n) and n>=1 and n<=10 then params.count=n;UIManager:close(input);preview() end
                end}}}}
                UIManager:show(input) -- gate: user action (approved Series count editor)
                input:onShowKeyboard()
            end}}
            if plan.earlier_key then buttons[#buttons+1]={{text="Start at earlier gap · "..(plan.earlier_title or "Book"),callback=function() params.start_key=plan.earlier_key;UIManager:close(dialog);preview() end}} end
            buttons[#buttons+1]={{text="Cancel",callback=function() UIManager:close(dialog) end}}
            dialog=show(title,buttons)
        end)
    end
    Library.seriesCommand("find",{key=host.series_key},function(result)
        if not wanted() or UIManager:getTopmostVisibleWidget()~=host then return end
        if result.id and result.state~="complete" then monitor(result) else preview() end
    end)
end

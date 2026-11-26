-- SPDX-License-Identifier: AGPL-3.0-or-later
-- One screen owner; widgets receive only an immutable snapshot and a dispatch handle.
HomeHost = {}
-- Reuse the central visible stack: owned dialogs remain above Home, and a reader
-- placed above Home restores the reading gate. No separate dialog-specific gate.
function HomeHost.foreground()
    if not HomeHost.active then return false end
    local reader=liveUI()
    for _,widget in ipairs(visibleStack()) do
        if reader and widget==reader then return false end
        if widget==HomeHost.active then return true end
    end
    return false
end
function HomeHost.document()
    -- Layout editor publishes the same validated layout-as-data in reader settings.
    HomeEditor.load()
    local d=S.home_layout
    if d and Layout.validate(d) then return d end
    return Layout.default()
end
function HomeHost.installed()
    local registry={}
    for id in pairs(HomeWidgets.renderers) do registry[id]=WidgetRegistry[id] end
    return registry
end
function HomeHost.create()
    local Input=require("ui/widget/container/inputcontainer")
    local Geom=require("ui/geometry")
    local GestureRange=require("ui/gesturerange")
    local Host=Input:extend{name="booksync_home",covers_fullscreen=true}
    function Host:init()
        self.index=1
        self.dimen=Geom:new{w=Device.screen:getWidth(),h=Device.screen:getHeight()}
        self.ges_events={HomeSwipe={GestureRange:new{ges="swipe",range=self.dimen}}}
        self.key_events={Close={{"Back"}},Next={{"PgFwd"}},Previous={{"PgBack"}}}
        self.unsubscribe=Library.subscribe(function(ev) self:invalidate(ev) end)
        self:rebuild()
    end
    function Host:rebuild()
        if self.widgetRefresh then UIManager:unschedule(self.widgetRefresh); self.widgetRefresh=nil end
        if self.series_key then return SeriesUI.paint(self) end
        if self.list_layout and self.filter.model.query.group~="none" and self.filter.model.query.group~=nil then return SeriesUI.groups(self) end
        local refreshDelay
        local paint=Library.paint(self.list_layout and (self.filter.model.source=="search" and "search" or "library") or "home")
        local ready,caps=pcall(paint.capabilities,paint)
        caps=ready and caps or {}
        self.caps=caps
        local account=caps.account or {}
        self.account=account
        local previous=self.signatures or {}
        self.signatures,self.changed_rects={},{}
        local registry=HomeHost.installed()
        if type(caps.lists) == "table" and not caps.lists.read then registry.lists=nil end
        local resolved=assert(HomeHostPlan.resolve((self.list_layout or HomeHost.document()),registry,caps))
        self.index=HomeHostPlan.page(self.index,0,#resolved.pages)
        local page=resolved.pages[self.index]
        local scale=function(n) return Device.screen:scaleBySize(n) end
        local gap,top,bottom=scale(12),scale(self.list_layout and 178 or 120),scale((self.list_layout or #resolved.pages>1) and 52 or 12)
        local w,h=self.dimen.w,self.dimen.h
        local canvas=HomeWidgets.canvas(w,h)
        HomeWidgets.text(canvas,self.list_title or page.name or page.tab or "Home",gap,gap,w-scale(self.list_layout and 120 or 220),24,false,true)
        local status,kind=AccountPlan.sync(account,true)
        if status~=self.account_status then
            self.changed_rects[#self.changed_rects+1]={x=0,y=0,w=w,h=top}
            self.account_status=status
        end
        if status and caps.account and not self.list_layout then HomeWidgets.button(canvas,status,gap+scale(220),scale(66),w-2*gap-scale(220),scale(50),function() AccountView.open(kind=="sync" and "sync" or nil) end) end
        HomeWidgets.button(canvas,_("Close"),w-scale(100),gap,scale(88),scale(50),function() self:onClose() end)
        HomeWidgets.button(canvas,_("Search"),gap,scale(66),scale(100),scale(50),function() self:search() end)
        if self.list_layout then
            local header=self.filter:header(self.list_result and self.list_result.total)
            HomeWidgets.button(canvas,header.active and _("Filter ●") or _("Filter"),gap+scale(110),scale(66),scale(100),scale(50),header.callback)
            local x=gap
            for _,chip in ipairs(header.chips) do
                if x+scale(140)>w-gap then break end
                HomeWidgets.button(canvas,chip.label.." ×",x,scale(118),scale(136),scale(50),chip.callback)
                x=x+scale(140)
            end
        end
        local sharedStats
        if not self.list_layout then
            HomeWidgets.button(canvas,"⋯",gap+scale(110),scale(66),scale(100),scale(50),function() self:menu() end)
        end
        if not self.list_layout then
            HomeWidgets.button(canvas,_("Edit"),w-scale(190),gap,scale(80),scale(50),function() HomeEditor.show(self) end)
        end
        for _,p in ipairs(page.placements) do
            local rect=HomeHostPlan.rect(p,resolved.grid,w-2*gap,h-top-bottom,gap)
            rect.x,rect.y=rect.x+gap,rect.y+top
            local context=paint:widget(p.widget,p.instance)
            local ok,result=pcall(function()
                local need=(HomeWidgets.needs[p.widget] or HomeHostPlan.need)(p)
                if p.widget == "lists" or p.widget == "booklist" and (p.settings.style or 0) == 1 then
                    local pad=scale(rect.h-2<scale(132) and 8 or 14)
                    need.limit=math.min(need.limit,math.max(1,math.floor((rect.h-2-2*pad-scale(52))/scale(52))))
                elseif p.widget == "booklist" then
                    -- Cover shelves are columns, so a row-height limit must not collapse them.
                    need.limit=math.min(need.limit,rect.h-2<scale(132) and 1 or p.w>=4 and 4 or 3)
                end
                if HomeWidgets.stats[p.widget] then
                    if not sharedStats then sharedStats=context:read(need.op,need) end
                    return sharedStats
                end
                if self.list_layout then self.list_limit=need.limit end
                local data=context:read(need.op,need)
                if p.widget=="library" then
                    local merged={}; for k,v in pairs(data) do merged[k]=v end
                    -- This widget owns a summary record, including when the catalog is unsaved.
                    merged.items=nil
                    merged.storage=context:storage()
                    merged.collections_available=caps.collections==true
                    return merged
                end
                return data
            end)
            result=ok and result or {error="Unavailable"}
            local signature=Cache.encode(result)
            self.signatures[p.instance]=signature
            if previous[p.instance] ~= signature then self.changed_rects[#self.changed_rects+1]=rect end
            if self.list_layout then self.list_result=result end
            local snapshot=HomeHostPlan.snapshot(result)
            local interval=WidgetRegistry[p.widget].refreshSeconds
            if interval then refreshDelay=math.min(refreshDelay or interval,interval) end
            local dispatch=function(action,row) self:dispatch(action,row,p) end
            local rendered,card=pcall(HomeWidgets.renderers[p.widget],HomeHostPlan.immutable(p),snapshot,dispatch,rect)
            if not rendered then card=HomeWidgets.card(p,HomeHostPlan.snapshot({error="Render failed"}),dispatch,rect) end
            -- Catch deferred KOReader painting too, not only widget construction.
            local Boundary=WidgetContainer:extend{}
            local boundary=Boundary:new{card}
            function boundary:paintTo(bb,x,y)
                local done=Budgets.span("widget."..p.widget,now_s,log)
                local painted=pcall(self[1].paintTo,self[1],bb,x,y)
                if not painted then
                    self[1]:free()
                    self[1]=HomeWidgets.card(p,HomeHostPlan.snapshot({error="Render failed"}),dispatch,rect)
                    self[1]:paintTo(bb,x,y)
                end
                done()
            end
            HomeWidgets.put(canvas,boundary,rect.x,rect.y)
        end
        if self.list_layout then
            local result=self.list_result or {}
            HomeWidgets.button(canvas,"‹",gap,h-bottom,scale(80),bottom,function() self:listPage(-1) end)
            HomeWidgets.text(canvas,result.pending and _("Loading…") or (tostring(result.total or "—").._(" books")),scale(110),h-bottom+gap,w-scale(220),16)
            if result.next then HomeWidgets.button(canvas,"›",w-gap-scale(80),h-bottom,scale(80),bottom,function() self:listPage(1) end) end
        elseif #resolved.pages>1 then
            HomeWidgets.text(canvas,(page.name or page.tab).."  ·  "..self.index.." / "..#resolved.pages,scale(110),h-bottom+gap,w-scale(220),16)
            HomeWidgets.button(canvas,"‹",gap,h-bottom,scale(80),bottom,function() self:turn(-1) end)
            HomeWidgets.button(canvas,"›",w-gap-scale(80),h-bottom,scale(80),bottom,function() self:turn(1) end)
        end
        self.metrics=paint:flush()
        if refreshDelay then
            self.widgetRefresh=function()
                if HomeHost.active~=self then self.widgetRefresh=nil; return end
                -- Keep the heartbeat until rebuild replaces it: a panel may cover Home
                -- between this check and the queued redraw. Back must still refresh Clock.
                UIManager:scheduleIn(refreshDelay,self.widgetRefresh)
                if HomeHost.foreground() and topWidget()==self and not reading() then self:invalidate() end
            end
            UIManager:scheduleIn(refreshDelay,self.widgetRefresh)
        end
        local old=self[1]
        self[1]=HomeWidgets.ui().Frame:new{padding=0,margin=0,bordersize=0,background=HomeWidgets.ui().BB.COLOR_WHITE,canvas}
        if old then old:free() end
    end
    function Host:menu()
        local menu
        menu=require("ui/widget/buttondialog"):new{title=_("Home"),buttons={
            {{text=_("Edit Home"),callback=function() UIManager:close(menu); HomeEditor.show(self) end}},
            {{text=_("BookSync settings"),callback=function()
                UIManager:close(menu)
                assert(state.module,"BookSync module unavailable"):showSettings()
            end}},
            {{text=_("Cancel"),callback=function() UIManager:close(menu) end}},
        }}
        UIManager:show(menu) -- gate: user action (Home menu)
    end
    function Host:turn(delta)
        if self.series_key then return SeriesUI.page(self,delta) end
        if self.list_layout then return self:listPage(delta) end
        local resolved=HomeHostPlan.resolve((self.list_layout or HomeHost.document()),HomeHost.installed(),self.caps)
        local index=HomeHostPlan.page(self.index,delta,#resolved.pages)
        if index ~= self.index then self.index=index; self:rebuild(); UIManager:setDirty(self,"ui") end
        return true
    end
    function Host:onHomeSwipe(_,ges)
        if ges.direction == "west" then return self:turn(1) end
        if ges.direction == "east" then return self:turn(-1) end
    end
    function Host:onNext() return self:turn(1) end
    function Host:onPrevious() return self:turn(-1) end
    function Host:invalidate()
        self.invalid=true
        if self.redraw then return end
        self.redraw=function()
            self.redraw=nil
            -- Never show/focus Home on an event; only update an already visible Home.
            if HomeHost.active == self and topWidget() == self and not reading() then
                self.invalid=nil; self:rebuild()
                for _,r in ipairs(self.changed_rects) do UIManager:setDirty(self,"ui",Geom:new(r)) end
            end
        end
        UIManager:nextTick(self.redraw)
    end
    function Host:dispatch(action,row,p)
        if action == "retry" then Library.retry(); self:rebuild(); UIManager:setDirty(self,"ui")
        elseif action == "battery" then BatteryUI.show()
        elseif action == "storage" then StorageUI.show()
        elseif action == "collections" then StorageUI.show("collections",function(row)
            self:showList(row.title,{kind="collection",key=row.key})
        end)
        elseif action == "book" then
            if self.caps.account and not row.local_path and not AccountPlan.login(self.account or {},"opds").available then
                local prompt=require("ui/widget/buttondialog"):new{title="No OPDS login, so it can't download",buttons={{{text="Keep browsing",callback=function() UIManager:close(self.download_prompt) end},{text="Set up",callback=function() UIManager:close(self.download_prompt); AccountView.open("opds") end}}}}
                self.download_prompt=prompt
                UIManager:show(prompt) -- gate: user action (server-only book)
                return
            end
            if Library.open(row) then
                if HomeHost.active==self then UIManager:close(self) end
            elseif not (ReaderPanel and row.key and ReaderPanel.details(row.key)) then
                UIManager:show(TextViewer:new{title=row.title or _("Book details"),text=_("This book is not saved on this reader.")}) -- gate: user action (widget book)
            end
        elseif action == "list" then self:showList(row.title,{kind="list",key=row.key})
        elseif action == "all" or action == "device" or action == "group" then
            local need=HomeHostPlan.need(p)
            self:showList((p.settings or {}).title or (action=="device" and "On device" or "Library"),
                action=="device" and "on-device" or p.widget=="library" and "library/all" or need.source,
                action=="group" and {group=row.group} or need.query,need.exclude_current)
        end
    end
    function Host:showSeries(key,onBack)
        if self.series_key then return end
        self.series_key,self.series_offset,self.series_return=key,0,onBack
        self:rebuild(); UIManager:setDirty(self,"ui")
    end
    function Host:showList(title,source,query,exclude_current)
        if self.series_key or self.list_layout then
            self.catalog_history=self.catalog_history or {}
            self.catalog_history[#self.catalog_history+1]={series_key=self.series_key,series_offset=self.series_offset,
                list_layout=self.list_layout,list_title=self.list_title,filter=self.filter,index=self.index,group_offsets=self.group_offsets,series_return=self.series_return}
        end
        self.series_key=nil; self.series_return=nil; self.group_offsets={}
        if not self.list_layout then self.home_index=self.index end
        self.list_title=title or "Library"
        self.list_layout=Layout.default()
        self.list_layout.grids["android-tablet"].rows=3
        self.list_layout.pages={{id="list",tab="Library",name=self.list_title,placements={{instance="list-books",widget="booklist",version=1,
            x=0,y=0,w=4,h=3,settings={title=self.list_title,source=source,query=query or {},exclude_current=exclude_current,offset=0,limit=8,style=1}}}}}
        local settings=self.list_layout.pages[1].placements[1].settings
        self.filter=FilterView.new{title=self.list_title,source=source,query=query,exclude_current=exclude_current,
            onChange=function(q) settings.query=q; settings.offset=0; self.group_offsets={}; self:rebuild(); UIManager:setDirty(self,"ui") end,
            onApply=function(q) settings.query=q; settings.offset=0; self.group_offsets={}; self:rebuild(); UIManager:setDirty(self,"ui") end,
            onSave=function(saved) self:saveFilter(saved) end}
        self.index=1; self:rebuild(); UIManager:setDirty(self,"ui")
    end
    function Host:listPage(delta)
        if self.filter.model.query.group and self.filter.model.query.group~="none" then return SeriesUI.groupPage(self,delta) end
        local settings=self.list_layout.pages[1].placements[1].settings
        local result=self.list_result or {}
        if delta>0 and not result.next then return true end
        settings.offset=delta>0 and result.next or math.max(0,settings.offset-(self.list_limit or 8))
        self:rebuild(); UIManager:setDirty(self,"ui"); return true
    end
    function Host:search()
        local dialog
        dialog=require("ui/widget/inputdialog"):new{title=_("Search library"),input="",buttons={{
            {text=_("Cancel"),callback=function() UIManager:close(dialog) end},
            {text=_("Search"),callback=function()
                local q=dialog:getInputText()
                UIManager:close(dialog)
                self:showList(_("Search"),"search",{q=q,sort="match"})
            end}}}}
        UIManager:show(dialog) -- gate: user action (owned Home search)
        dialog:onShowKeyboard()
    end
    function Host:saveFilter(saved)
        local document,page=HomeHostPlan.saveFilter(HomeHost.document(),saved,self.list_title)
        if not document then
            UIManager:show(InfoMessage:new{text=_("No room on Home")}) -- gate: user action (save filter)
            return false
        end
        local saved,err=HomeEditor.save(document)
        if not saved then
            UIManager:show(InfoMessage:new{text=err or _("Could not save Home")}) -- gate: user action (save filter)
            return false
        end
        -- gate: user action (save filter)
        UIManager:show(require("ui/widget/buttondialog"):new{title=_("Book list saved on Home").." · "..(function() for _,pg in ipairs(document.pages) do if pg.id==page then return pg.name or pg.tab end end return "Home" end)(),buttons={{{text=_("Go to Home"),callback=function()
            -- Close this toast before rebuilding the initiating host.
            local toast=topWidget(); UIManager:close(toast)
            self.list_layout=nil; self.list_title=nil; self.filter=nil
            local visible=HomeHostPlan.resolve(document,HomeHost.installed(),self.caps)
            for i,p in ipairs(visible.pages) do if p.id==page then self.index=i end end
            self:rebuild(); UIManager:setDirty(self,"ui")
        end}}}}) -- gate: user action (save filter)
        return true
    end
    function Host:onClose()
        if self.series_key then
            local back=self.series_return
            self.series_key=nil; self.series_return=nil
            if back then back(); return true end
            self:rebuild(); UIManager:setDirty(self,"ui"); return true
        end
        if self.catalog_history and #self.catalog_history>0 then
            if self.filter then self.filter:close(false) end
            local previous=table.remove(self.catalog_history)
            self.series_key,self.series_offset=previous.series_key,previous.series_offset
            self.list_layout,self.list_title,self.filter,self.index=previous.list_layout,previous.list_title,previous.filter,previous.index
            self.group_offsets=previous.group_offsets; self.series_return=previous.series_return
            self:rebuild(); UIManager:setDirty(self,"ui"); return true
        end
        if self.list_layout then
            self.list_layout=nil; self.list_title=nil; self.filter=nil; self.index=self.home_index or 1; self.home_index=nil; self:rebuild(); UIManager:setDirty(self,"ui"); return true
        end
        UIManager:close(self)
        return true
    end
    function Host:onCloseWidget()
        if self.widgetRefresh then UIManager:unschedule(self.widgetRefresh); self.widgetRefresh=nil end
        for _,entry in ipairs(self.catalog_history or {}) do if entry.filter then entry.filter:close(false) end end
        self.catalog_history=nil
        if self.filter then self.filter:close(false); self.filter=nil end
        if self.unsubscribe then self.unsubscribe(); self.unsubscribe=nil end
        if self.redraw then UIManager:unschedule(self.redraw); self.redraw=nil end
        if HomeHost.active == self then HomeHost.active=nil end
    end
    return Host:new{}
end
function HomeHost.show()
    local problem=Companion.workerProblem(_("for BookSync Home"))
    if problem then
        UIManager:show(InfoMessage:new{text=problem}) -- gate: user action (Home)
        return false
    end
    if HomeHost.active then UIManager:close(HomeHost.active) end
    -- The explicit Home action is leaving the reading foreground. Permit its bounded
    -- cached reads during construction, before UIManager has pushed the new screen.
    HomeHost.opening=true
    local ok,host=pcall(HomeHost.create)
    HomeHost.opening=nil
    if not ok then error(host) end
    HomeHost.active=host
    UIManager:show(host) -- gate: user action (Home command or menu)
    return true
end

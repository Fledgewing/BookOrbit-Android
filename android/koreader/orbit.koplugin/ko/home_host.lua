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
        local paint=Library.paint(self.list_layout and (self.filter.model.source=="search" and "search" or "library") or "home")
        local ready,caps=pcall(paint.capabilities,paint)
        caps=ready and caps or {}
        self.caps=caps
        local previous=self.signatures or {}
        self.signatures,self.changed_rects={},{}
        local registry=HomeHost.installed()
        if type(caps.lists) == "table" and not caps.lists.read then registry.lists=nil end
        local resolved=assert(HomeHostPlan.resolve((self.list_layout or HomeHost.document()),registry,caps))
        self.index=HomeHostPlan.page(self.index,0,#resolved.pages)
        local page=resolved.pages[self.index]
        local scale=function(n) return Device.screen:scaleBySize(n) end
        local gap,top,bottom=scale(12),scale(self.list_layout and 158 or 108),scale((self.list_layout or #resolved.pages>1) and 52 or 12)
        local w,h=self.dimen.w,self.dimen.h
        local canvas=HomeWidgets.canvas(w,h)
        HomeWidgets.text(canvas,self.list_title or "BookSync",gap,gap,w-scale(120),24,false,true)
        HomeWidgets.button(canvas,_("Close"),w-scale(100),gap,scale(88),scale(36),function() self:onClose() end)
        HomeWidgets.button(canvas,_("Search"),gap,scale(54),scale(100),scale(50),function() self:search() end)
        if self.list_layout then
            local header=self.filter:header(self.list_result and self.list_result.total)
            HomeWidgets.button(canvas,header.active and _("Filter ●") or _("Filter"),gap+scale(110),scale(54),scale(100),scale(50),header.callback)
            local x=gap
            for _,chip in ipairs(header.chips) do
                if x+scale(140)>w-gap then break end
                HomeWidgets.button(canvas,chip.label.." ×",x,scale(106),scale(136),scale(46),chip.callback)
                x=x+scale(140)
            end
        end
        local sharedStats
        if not self.list_layout then
            HomeWidgets.button(canvas,_("Edit"),w-scale(190),gap,scale(80),scale(36),function() HomeEditor.show(self) end)
        end
        for _,p in ipairs(page.placements) do
            local rect=HomeHostPlan.rect(p,resolved.grid,w-2*gap,h-top-bottom,gap)
            rect.x,rect.y=rect.x+gap,rect.y+top
            local context=paint:widget(p.widget,p.instance)
            local ok,result=pcall(function()
                local need=(HomeWidgets.needs[p.widget] or HomeHostPlan.need)(p)
                if p.widget ~= "continue-reading" and need.limit then
                    local pad=scale(rect.h-2<scale(120) and 8 or 14)
                    need.limit=math.min(need.limit,math.max(1,math.floor((rect.h-2-2*pad-scale(30))/scale(48))))
                end
                if HomeWidgets.stats[p.widget] then
                    if not sharedStats then sharedStats=context:read(need.op,need) end
                    return sharedStats
                end
                if self.list_layout then self.list_limit=need.limit end
                return context:read(need.op,need)
            end)
            result=ok and result or {error="Unavailable"}
            local signature=Cache.encode(result)
            self.signatures[p.instance]=signature
            if previous[p.instance] ~= signature then self.changed_rects[#self.changed_rects+1]=rect end
            if self.list_layout then self.list_result=result end
            local snapshot=HomeHostPlan.snapshot(result)
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
        local old=self[1]
        self[1]=HomeWidgets.ui().Frame:new{padding=0,margin=0,bordersize=0,background=HomeWidgets.ui().BB.COLOR_WHITE,canvas}
        if old then old:free() end
    end
    function Host:turn(delta)
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
        elseif action == "book" then
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
    function Host:showList(title,source,query,exclude_current)
        self.list_title=title or "Library"
        self.list_layout=Layout.default()
        self.list_layout.grids["android-tablet"].rows=3
        self.list_layout.pages={{id="list",tab="Library",name=self.list_title,placements={{instance="list-books",widget="booklist",version=1,
            x=0,y=0,w=4,h=3,settings={title=self.list_title,source=source,query=query or {},exclude_current=exclude_current,offset=0,limit=8,style=1}}}}}
        local settings=self.list_layout.pages[1].placements[1].settings
        self.filter=FilterView.new{title=self.list_title,source=source,query=query,
            onChange=function(q) settings.query=q; settings.offset=0; self:rebuild(); UIManager:setDirty(self,"ui") end,
            onApply=function(q) settings.query=q; settings.offset=0; self:rebuild(); UIManager:setDirty(self,"ui") end,
            onSave=function(saved) self:saveFilter(saved) end}
        self.index=1; self:rebuild(); UIManager:setDirty(self,"ui")
    end
    function Host:listPage(delta)
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
            for i,p in ipairs(document.pages) do if p.id==page then self.index=i end end
            self:rebuild(); UIManager:setDirty(self,"ui")
        end}}}}) -- gate: user action (save filter)
        return true
    end
    function Host:onClose()
        if self.list_layout then
            self.list_layout=nil; self.list_title=nil; self.filter=nil; self.index=1; self:rebuild(); UIManager:setDirty(self,"ui"); return true
        end
        UIManager:close(self)
        return true
    end
    function Host:onCloseWidget()
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

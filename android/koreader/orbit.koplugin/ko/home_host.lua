-- SPDX-License-Identifier: AGPL-3.0-or-later
-- One screen owner; widgets receive only an immutable snapshot and a dispatch handle.
HomeHost = {}
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
        local paint=Library.paint("home")
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
        local gap,top,bottom=scale(12),scale(58),scale(#resolved.pages>1 and 52 or 12)
        local w,h=self.dimen.w,self.dimen.h
        local canvas=HomeWidgets.canvas(w,h)
        HomeWidgets.text(canvas,"BookSync",gap,gap,w/2,24,false,true)
        HomeWidgets.button(canvas,_("Close"),w-scale(100),gap,scale(88),scale(36),function() self:onClose() end)
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
                    need.limit=math.min(need.limit,math.max(1,math.floor((rect.h-scale(58))/scale(48))))
                end
                return context:read(need.op,need)
            end)
            result=ok and result or {error="Unavailable"}
            local signature=Cache.encode(result)
            self.signatures[p.instance]=signature
            if previous[p.instance] ~= signature then self.changed_rects[#self.changed_rects+1]=rect end
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
        if #resolved.pages>1 then
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
            UIManager:close(self)
            if not Library.open(row) and not (ReaderPanel and row.key and ReaderPanel.details(row.key)) then
                UIManager:show(TextViewer:new{title=row.title or _("Book details"),text=_("This book is not saved on this reader.")}) -- gate: user action (widget book)
            end
        elseif action == "list" then
            -- A Lists card opens a bounded Shelf in the same host, never a backend UI.
            self.list_layout=Layout.default()
            self.list_layout.pages={{id="list",tab="Library",name=row.title,placements={{instance="list-books",widget="booklist",version=1,
                x=0,y=0,w=4,h=3,settings={title=row.title,source={kind="list",key=row.key},limit=8}}}}}
            self.index=1; self:rebuild(); UIManager:setDirty(self,"ui")
        end
    end
    function Host:onClose()
        if self.list_layout then
            self.list_layout=nil; self.index=1; self:rebuild(); UIManager:setDirty(self,"ui"); return true
        end
        UIManager:close(self)
        return true
    end
    function Host:onCloseWidget()
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

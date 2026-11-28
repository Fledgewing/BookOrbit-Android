-- SPDX-License-Identifier: AGPL-3.0-or-later
-- User-opened settings over the editor's draft. One bounded source window per paint.
BookListConfig = {}
function BookListConfig.new(context)
    return setmetatable({cfg=Layout.copy(context.cfg),onDone=context.onDone,onSave=context.onSave,
        caps=context.caps or {},classic=context.classic,category="builtin",offset=0,alive=true}, {__index=BookListConfig})
end
function BookListConfig:close()
    self.alive=false
    if self.unobserve then self.unobserve();self.unobserve=nil end
    if self.eventPaint then UIManager:unschedule(self.eventPaint);self.eventPaint=nil end
    if self.retry then UIManager:unschedule(self.retry); self.retry=nil end
    if self.filter then self.filter:close(false); self.filter=nil end
    if self.dialog then UIManager:close(self.dialog); self.dialog=nil end
end
function BookListConfig:back()
    if self.sources then self.sources=nil; self:paint() else self:close() end
end
function BookListConfig:choose(option)
    self.cfg=BookList.choose(self.cfg,option); self.sources=nil; self.offset=0
    self:paint()
    if option.src=="custom" then self:filterSheet() end
end
function BookListConfig:filterSheet()
    if self.dialog then UIManager:close(self.dialog); self.dialog=nil end
    self.filter=FilterView.new{source=BookList.source(self.cfg),query=self.cfg.query,title=self.cfg.title,exclude_current=self.cfg.exclude_current,
        onApply=function(q)
            self.cfg.query=q; self.filter=nil
            if self.alive then self:paint() end
        end,onSave=self.onSave}
    self.filter:show()
end
function BookListConfig:rename()
    if self.classic then self.cfg=BookList.suggest(self.cfg); return self:paint() end
    local dialog
    dialog=require("ui/widget/inputdialog"):new{title=_("Book list title"),input=self.cfg.title,buttons={{
        {text=_("Cancel"),callback=function() UIManager:close(dialog) end},
        {text=_("Done"),callback=function()
            self.cfg=BookList.title(self.cfg,dialog:getInputText()); UIManager:close(dialog); self:paint()
        end}}}}
    UIManager:show(dialog) -- gate: user action (Book list title)
    dialog:onShowKeyboard()
end
function BookListConfig:paint(attempt)
    if not self.alive then return end
    if self.retry then UIManager:unschedule(self.retry); self.retry=nil end
    local finish=Budgets.span(self.sources and "booklist-sources.draw" or "booklist-config.draw",now_s,log)
    local buttons={}
    local function row(text,fn,id) buttons[#buttons+1]={{text=text,callback=fn,id=id,align="left"}} end
    local result
    local focus=1
    if self.sources then
        if not self.unobserve then
            self.unobserve=Library.observe(function()
                if not self.alive or not self.sources or self.eventPaint then return end
                self.eventPaint=function()
                    if not self.alive or not self.sources then self.eventPaint=nil;return end
                    if self.dialog and topWidget()==self.dialog and not reading() then
                        self.eventPaint=nil;self:paint()
                    else UIManager:scheduleIn(.5,self.eventPaint) end
                end
                UIManager:nextTick(self.eventPaint)
            end)
        end
        local paint=Library.paint("booklist-sources")
        result=paint:sources(self.category,self.offset,BookList.PAGE_SIZE,self.caps)
        self.metrics=paint:flush()
        local categories={}
        for i,id in ipairs(BookList.categories) do
            local name=({builtin="Built in",lists="Your lists",series="Series",authors="Authors",collections="Collections",libraries="Libraries"})[id]
            categories[#categories+1]={text=(id==self.category and "● " or "").._(name),
                enabled=(id~="lists" or not (self.caps.lists and self.caps.lists.read==false)) and (id~="collections" or self.caps.collections~=false) and (id~="libraries" or self.caps.libraries~=false),
                callback=function() self.category=id; self.offset=0; self:paint() end}
            if i%2==0 then buttons[#buttons+1]=categories; categories={} end
        end
        for i,option in ipairs(result.items or {}) do
            local chosen=option.src==self.cfg.src
            if chosen then focus=i+math.ceil(#BookList.categories/2) end
            row((chosen and "● " or "○ ")..option.title..(option.count~=nil and " · "..option.count or " · —"),
                function() self:choose(option) end,"source-"..i)
        end
        if result.pending or result.error or #(result.items or {})==0 then
            row(result.pending and _("Loading sources…") or result.error and _("Sources unavailable · Retry") or _("No sources"),function() self:paint() end)
        end
        local nav={{text=_("‹ Settings"),callback=function() self:back() end}}
        if self.offset>0 or result.next then
            nav[#nav+1]={text="‹",enabled=self.offset>0,callback=function() self.offset=math.max(0,self.offset-BookList.PAGE_SIZE); self:paint() end}
            nav[#nav+1]={text=string.format("%d / %d",math.floor(self.offset/BookList.PAGE_SIZE)+1,
                math.max(1,math.ceil((result.total or 0)/BookList.PAGE_SIZE))),enabled=false}
            nav[#nav+1]={text="›",enabled=result.next~=nil,callback=function() self.offset=result.next or self.offset; self:paint() end}
        end
        buttons[#buttons+1]=nav
    else
        local cfg=self.cfg
        row(_("Title")..": "..cfg.title,function() self:rename() end)
        row(_("Source")..": "..BookList.name(cfg).." ›",function() self.sources=true; self.offset=0
            self.category=({list="lists",series="series",author="authors"})[cfg.src:match("^(%a+):")] or "builtin"
            self:paint() end)
        if cfg.src=="custom" then row(_("Filter").." ›",function() self:filterSheet() end) end
        for _i,field in ipairs({{key="style",label="Style",values=BookList.styles},{key="sort",label="Sort",values=BookList.sorts},{key="cap",label="Caption",values=BookList.captions}}) do
            row(_(field.label)..": ".._(field.values[(cfg[field.key] or 0)+1]),function()
                cfg[field.key]=((cfg[field.key] or 0)+1)%#field.values; self:paint()
            end)
        end
        buttons[#buttons+1]={{text=_("Cancel"),callback=function() self:close() end},
            {text=_("Done"),callback=function()
                local valid,err=BookList.valid(self.cfg)
                if valid then valid,err=self.onDone(Layout.copy(self.cfg)) end
                if valid then self:close() else self.error=err; self:paint() end
            end}}
        if self.error or self.notice then row(self.error or self.notice,function() end) end
        self.metrics={rows=0,bytes=0,spawns=0,roundTrips=0,network=0,snapshotBytes=0}
        assert(Budgets.check(Budgets.get("screens","booklist-config"),self.metrics))
    end
    local screen=Device.screen
    local padding=require("ui/size").padding.buttontable
    local height=math.min(screen:scaleBySize(60),math.floor((screen:getHeight()-screen:scaleBySize(160))/#buttons)-2*padding-2)
    for _i,line in ipairs(buttons) do for _i,b in ipairs(line) do b.height=height; b.font_size=16 end end
    local dialog=require("ui/widget/buttondialog"):new{title=_(self.sources and "Choose a source" or "Configure Book list"),
        buttons=buttons,width=math.min(screen:getWidth()-screen:scaleBySize(24),screen:scaleBySize(640)),
        tap_close_callback=function() self:back() end}
    dialog.onClose=function() self:back(); return true end
    dialog:moveFocusTo(1,focus)
    if self.dialog then UIManager:close(self.dialog) end
    self.dialog=dialog
    Gate.show("Book list settings",function()
        if self.alive and self.dialog==dialog then UIManager:show(dialog) end -- gate: Gate.show, explicit Configure
    end)
    if result and result.pending and (attempt or 0)<20 then
        self.retry=function()
            self.retry=nil
            if self.alive and not reading() then self:paint((attempt or 0)+1) end
        end
        UIManager:scheduleIn(.5,self.retry)
    end
    finish()
end

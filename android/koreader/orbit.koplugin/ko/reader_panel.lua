-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Reuse EndSheet's measured rows and SheetLayout; every datum comes from Library.
ReaderPanel = {}
local ReaderSheet = EndSheet:extend{ name="booksync_reader_panel", min_button=50 }

function ReaderSheet:init()
    EndSheet.init(self)
    self.key_events={Close={{"Back"}},Select={{"Press"}},StepMore={{"Right"}},StepLess={{"Left"}}}
end
function ReaderSheet:focusStep(delta)
    local controls=self.focus_controls or {}
    if #controls==0 then return false end
    local old=controls[self.focus_index or 1]
    if old and old.onUnfocus then old:onUnfocus() end
    self.focus_index=((self.focus_index or 1)-1+delta)%#controls+1
    self.keyboard_focus=true
    local current=controls[self.focus_index]
    if current.onFocus then current:onFocus() end
    UIManager:setDirty(self,"ui")
    return true
end
function ReaderSheet:onSelect()
    local current=(self.focus_controls or {})[self.focus_index or 1]
    if current and current.callback then current.callback(); return true end
    return false
end
function ReaderSheet:onStepMore()
    if self.scrub_focus then Library.readerAction(self.ui,"next-chapter"); ReaderPanel.show(self.ui,self.screen,nil,self); return true end
    return self:focusStep(1)
end
function ReaderSheet:onStepLess()
    if self.scrub_focus then Library.readerAction(self.ui,"previous-chapter"); ReaderPanel.show(self.ui,self.screen,nil,self); return true end
    return self:focusStep(-1)
end
function ReaderSheet:control(widget,callback,scrubber)
    if widget.enabled==false then return widget end
    self.focus_controls[#self.focus_controls+1]=widget
    if callback then widget.callback=callback end
    if scrubber and not self.focus_index then self.focus_index=#self.focus_controls end
    return widget
end
function ReaderSheet:buttonTable(options)
    for _,row in ipairs(options.buttons) do for _,cell in ipairs(row) do
        cell.height=math.max(self.metrics.button,cell.height or 0)
        cell.font_size=cell.font_size or 14; cell.font_bold=false
    end end
    local buttons={}
    for _,row in ipairs(options.buttons) do
        local cells={}
        for _,cell in ipairs(row) do
            local copy={}; for key,value in pairs(cell) do copy[key]=value end
            copy.text=cell.display_text or cell.text; cells[#cells+1]=copy
        end
        buttons[#buttons+1]=cells
    end
    options.buttons=buttons
    local table=require("ui/widget/buttontable"):new(options)
    for _,row in ipairs(table.buttons_layout or {}) do for _,button in ipairs(row) do self:control(button) end end
    return table
end
function ReaderSheet:touchControl(area,callback)
    self:control(area,callback)
    area.onFocus=function(self) self.focused=true end
    area.onUnfocus=function(self) self.focused=false end
    local stock=area.paintTo
    function area:paintTo(bb,x,y)
        if stock then stock(self,bb,x,y) end
        if self.focused then
            local width,height=self.dimen.w,self.dimen.h
            local ink=require("ffi/blitbuffer").COLOR_BLACK
            bb:paintRect(x,y,width,2,ink); bb:paintRect(x,y+height-2,width,2,ink)
        end
    end
end
function ReaderSheet:rows()
    if not self.scrub_focus then return self.display_rows end
    local rows={}
    for _,row in ipairs(self.display_rows) do
        rows[#rows+1]=row
        if row.kind=="scrubber" then
            rows[#rows+1]={kind="label",text="Prev/Next: one chapter · Select or Back: done"}
        end
    end
    return rows
end
function ReaderSheet:rowWidget(block,w,h,mt)
    if block.kind=="reader-tiles" then
        local group=require("ui/widget/horizontalgroup"):new{}
        local width=math.floor(w/#block.row.choices)
        for _,cell in ipairs(block.row.choices) do
            local Geom=require("ui/geometry")
            local area=require("ui/widget/container/inputcontainer"):new{
                dimen=Geom:new{w=width,h=h},
                require("ui/widget/container/centercontainer"):new{dimen=Geom:new{w=width,h=h},
                    require("ui/widget/verticalgroup"):new{align="center",
                        require("ui/widget/iconwidget"):new{icon=cell.icon,width=math.floor(mt.button*.48),height=math.floor(mt.button*.48)},
                        require("ui/widget/textboxwidget"):new{text=cell.text,width=width-8,
                            face=require("ui/font"):getFace("cfont",14),alignment="center"}}}}
            area.ges_events={Tap={require("ui/gesturerange"):new{ges="tap",range=function() return area.dimen end}}}
            area.onTap=function() cell.callback(); return true end
            self:touchControl(area,cell.callback)
            table.insert(group,area)
        end
        return group
    elseif block.kind=="reading-choices" or block.kind=="reader-actions" then
        local cells=block.row.choices
        for _,cell in ipairs(cells) do cell.height=mt.button; cell.text_font_size=14; cell.text_font_bold=false end
        if block.kind=="reader-actions" then
            for _,cell in ipairs(cells) do cell.icon=nil end
        end
        local choices=self:buttonTable{width=w,buttons={cells},zero_sep=true}
        if block.row.group_label then
            return require("ui/widget/verticalgroup"):new{align="left",
                require("ui/widget/textwidget"):new{text=block.row.group_label,max_width=w,
                    face=require("ui/font"):getFace("cfont",14),bold=true},choices}
        end
        return choices
    elseif block.kind=="reader-header" then
        local row=block.row
        local group=require("ui/widget/horizontalgroup"):new{}
        local Button=require("ui/widget/button")
        local reserved=0
        for _,cell in ipairs(row.choices) do reserved=reserved+(cell.width or mt.button) end
        local titleWidth=w-reserved
        local title=require("ui/widget/verticalgroup"):new{align="center",
            require("ui/widget/textwidget"):new{text=row.text,
                face=require("ui/font"):getFace("cfont",18),max_width=titleWidth,bold=true},
            require("ui/widget/textwidget"):new{text=row.author or "",
                face=require("ui/font"):getFace("cfont",12),max_width=titleWidth}}
        for i,cell in ipairs(row.choices) do
            if i==2 then
                table.insert(group,require("ui/widget/container/centercontainer"):new{
                    dimen=require("ui/geometry"):new{w=titleWidth,h=mt.button},title})
            end
            if cell.keep_label then
                local Geom=require("ui/geometry")
                local width=cell.width or mt.button
                local home=require("ui/widget/container/inputcontainer"):new{text=cell.text,dimen=Geom:new{w=width,h=mt.button},
                    require("ui/widget/container/centercontainer"):new{dimen=Geom:new{w=width,h=mt.button},
                        require("ui/widget/horizontalgroup"):new{
                            require("ui/widget/iconwidget"):new{icon=cell.icon,width=math.floor(mt.button*.36),height=math.floor(mt.button*.36)},
                            require("ui/widget/horizontalspan"):new{width=math.floor(mt.button*.08)},
                            require("ui/widget/textwidget"):new{text=cell.text,face=require("ui/font"):getFace("cfont",14)}}}}
                home.ges_events={Tap={require("ui/gesturerange"):new{ges="tap",range=function() return home.dimen end}}}
                home.onTap=function() cell.callback(); return true end
                self:touchControl(home,cell.callback); table.insert(group,home)
            else
                table.insert(group,self:control(Button:new{text=not cell.icon and cell.text or nil,icon=cell.icon,tooltip=cell.text,callback=cell.callback,
                    width=cell.width or mt.button,height=mt.button,bordersize=cell.marked and 2 or 0,text_font_size=14}))
            end
        end
        return group
    elseif block.kind=="reader-grid" then
        local group=require("ui/widget/horizontalgroup"):new{}
        for _,row in ipairs(block.row.groups) do
            local width=math.floor(w/2)
            table.insert(group,require("ui/widget/verticalgroup"):new{align="left",
                require("ui/widget/textwidget"):new{text=row.group_label or "",max_width=width,
                    face=require("ui/font"):getFace("cfont",14),bold=true},
                self:buttonTable{width=width,buttons={row.choices},zero_sep=true}})
        end
        return group
    elseif block.kind=="reader-position" then
        local group=require("ui/widget/horizontalgroup"):new{}
        for i,text in ipairs({block.row.text,block.row.position}) do
            local width=i==1 and math.floor(w/2) or w-math.floor(w/2)
            local Align=i==1 and require("ui/widget/container/leftcontainer") or require("ui/widget/container/rightcontainer")
            table.insert(group,Align:new{
                dimen=require("ui/geometry"):new{w=width,h=h},
                require("ui/widget/textwidget"):new{text=text,
                    face=require("ui/font"):getFace("cfont",14),max_width=width}})
        end
        return group
    elseif block.kind=="reader-lights" then
        local group=require("ui/widget/horizontalgroup"):new{}
        for _,r in ipairs(block.row.controls) do
            local width=math.floor(w/#block.row.controls)
            local inset=math.floor(mt.button*.24)
            local Geom=require("ui/geometry")
            local area=require("ui/widget/container/inputcontainer"):new{dimen=Geom:new{w=width,h=h},
                require("ui/widget/verticalgroup"):new{align="center",
                    require("ui/widget/textwidget"):new{text=r.text,face=require("ui/font"):getFace("cfont",14)},
                    require("ui/widget/progresswidget"):new{width=width-2*inset,height=math.max(4,math.floor(mt.button*.2)),percentage=r.value/100,
                        ticks={},bordersize=0,radius=0,margin_h=0,margin_v=0}}}
            area.ges_events={Tap={require("ui/gesturerange"):new{ges="tap",range=function() return area.dimen end}}}
            area.onTap=function(_,_,ges)
                if ges and ges.pos then r.set(math.floor(math.max(0,math.min(1,(ges.pos.x-area.dimen.x-inset)/(width-2*inset)))*100+.5)) end
                return true
            end
            self:touchControl(area,function() r.set(math.min(100,r.value+10)) end)
            table.insert(group,area)
        end
        return require("ui/widget/verticalgroup"):new{align="left",
            require("ui/widget/textwidget"):new{text=#block.row.controls>1 and "Front light & warmth" or "Front light",max_width=w,
                face=require("ui/font"):getFace("cfont",14),bold=true},group}
    elseif block.kind=="scrubber" then
        local r=block.row
        local owner=self
        w=w-2*mt.button
        local Geom=require("ui/geometry")
        local area=require("ui/widget/container/inputcontainer"):new{
            dimen=Geom:new{w=w,h=mt.button},
            require("ui/widget/container/centercontainer"):new{dimen=Geom:new{w=w,h=mt.button},
                require("ui/widget/progresswidget"):new{width=w,height=math.max(4,math.floor(mt.button*.2)),percentage=r.value or 0,
                    ticks=r.chapters,last=1,bordersize=0,radius=0,margin_h=0,margin_v=0}}}
        -- Bookmarks use a second, separate marker track so they remain distinguishable.
        area.bookmarks=r.bookmarks
        local paint=area.paintTo
        function area:paintTo(bb,x,y)
            if paint then paint(self,bb,x,y) end
            local thumbWidth,thumbHeight=math.floor(mt.button*.16),math.floor(mt.button*.36)
            local markWidth,markHeight=math.floor(mt.button*.08),math.floor(mt.button*.2)
            if r.value then
                local px=x+math.floor(r.value*(w-thumbWidth))
                local py=y+math.floor((mt.button-thumbHeight)/2)
                if owner.scrub_focus then
                    local border=math.max(2,math.floor(mt.button*.04))
                    bb:paintRect(px-2*border,py-2*border,thumbWidth+4*border,thumbHeight+4*border,require("ffi/blitbuffer").COLOR_BLACK)
                    bb:paintRect(px-border,py-border,thumbWidth+2*border,thumbHeight+2*border,require("ffi/blitbuffer").COLOR_WHITE)
                end
                bb:paintRect(px,py,thumbWidth,thumbHeight,require("ffi/blitbuffer").COLOR_BLACK)
            end
            for _,fraction in ipairs(self.bookmarks or {}) do
                bb:paintRect(x+math.floor(fraction*(w-markWidth)),y+math.floor(mt.button*.2),
                    markWidth,markHeight,require("ffi/blitbuffer").COLOR_BLACK)
            end
        end
        area.ges_events={Tap={require("ui/gesturerange"):new{ges="tap",range=function() return area.dimen end}}}
        area.onTap=function(_,_,ges)
            if ges and ges.pos then r.seek(math.max(0,math.min(1,(ges.pos.x-area.dimen.x)/w))*100) end
            return true
        end
        local previous
        if r.previous then
            previous=self:control(require("ui/widget/button"):new{icon="chevron.first",width=mt.button,height=mt.button,callback=r.previous})
        end
        self:touchControl(area,function()
            self.scrub_focus=not self.scrub_focus; self.keyboard_focus=true
            self:build(); UIManager:setDirty(self,"ui")
        end)
        if not self.focus_index then self.focus_index=#self.focus_controls end
        if previous then
            return require("ui/widget/horizontalgroup"):new{
                previous,area,
                self:control(require("ui/widget/button"):new{icon="chevron.last",width=mt.button,height=mt.button,callback=r.next})}
        end
        return area
    end
    if block.kind=="footer" then
        local cells={}
        for _,row in ipairs(block.items) do cells[#cells+1]={text=row.text,callback=row.action,height=mt.button} end
        return self:buttonTable{width=w,buttons={cells},zero_sep=true}
    end
    local widget=EndSheet.rowWidget(self,block,w,h,mt)
    if block.kind=="button" then self:control(widget) end
    return widget
end
function ReaderSheet:onClose()
    if self.scrub_focus then
        self.scrub_focus=false; self:build(); UIManager:setDirty(self,"ui")
    else ReaderPanel.close() end
    return true
end
function ReaderSheet:onTapAnywhere(_arg, ges)
    if ges and ges.pos and (self.screen=="reader-bottom-panel"
        and ges.pos.y < self.screen_h-(self.sheet_h or 0)
        or self.screen~="reader-bottom-panel" and ges.pos.y > (self.sheet_h or 0)) then
        ReaderPanel.close(); return true
    end
    return false
end
function ReaderSheet:build()
    local finish = Budgets.span(self.screen .. ".draw", now_s, log)
    if self.screen=="reader-bottom-panel" then self.metrics.gap=math.floor(self.metrics.button*.08); self.metrics.pad=math.floor(self.metrics.button*.24) end
    self.focus_controls={}
    EndSheet.build(self)
    if self.keyboard_focus then
        local current=self.focus_controls[self.focus_index or 1]
        if current and current.onFocus then current:onFocus() end
    end
    assert(self.plan.h<=self.screen_h,"Reader panel controls exceed display")
    -- Native scale follows physical display dimensions. EndSheet retains measured
    -- geometry; never silently crop controls to its default 90% sheet cap.
    self.sheet_h=self.plan.h
    self.frame.height=self.sheet_h
    local Container=self.screen=="reader-bottom-panel" and require("ui/widget/container/bottomcontainer")
        or require("ui/widget/container/topcontainer")
    self[1] = Container:new{
        dimen=require("ui/geometry"):new{w=self.screen_w, h=self.screen_h}, self.frame }
    finish()
end
function ReaderPanel.close()
    local sheet = ReaderPanel.sheet
    ReaderPanel.sheet = nil
    if sheet then UIManager:close(sheet) end
end
local function button(text, action) return {kind="button", text=text, action=action} end

function ReaderPanel.show(ui, screen, key, reuse, attempt)
    if not (ui and ui.document) and screen ~= "details" then return false end
    local paint = Library.paint(screen)
    local book = paint:widget("reader-progress")
    local result = key and book:book(key) or book:reader(ui.document.file)
    local battery = screen == "reader-top-panel" and paint:battery() or nil
    local bottom=screen=="reader-bottom-panel"
    local controls=(screen=="reader-top-panel" or bottom) and paint:widget("reader-controls"):readerControls(ui) or nil
    local native=controls and controls.items and controls.items[1] or {}
    local caps = not bottom and paint:read("capabilities", {limit=1}) or {}
    local account=caps.account or {}
    local m = ReaderPanelPlan.model(result, battery)
    paint:flush()
    local rows = {
        {kind="title", text=m.title}, {kind="label", text=m.author},
        {kind="label", text=m.progress_text}, {kind="progress", value=m.progress},
    }
    local function back() ReaderPanel.close() end
    local function refresh() ReaderPanel.show(ui,screen,key,ReaderPanel.sheet) end
    local function action(name,value,stay)
        return function()
            if not stay then back() end
            Library.readerAction(ui,name,value)
            if stay and ReaderPanel.sheet then refresh() end
        end
    end
    if bottom then
        rows={
            {kind="reader-position",text=native.chapter_title or native.chapter or "Chapters not available yet",
                position=native.position or "Position not available yet"},
            {kind="scrubber",value=native.progress,chapters=native.chapters or {},bookmarks=native.bookmarks or {},
                previous=action("previous-chapter",nil,true),next=action("next-chapter",nil,true),
                seek=function(value) action("seek",value,true)() end},
        }
        local quick=CustomReading and CustomReading.panelRows(ui,refresh,screen) or {}
        local settings=Library.readerSettings(ui)
        local size={kind="reading-choices",group_label="Size · "..settings.size.." pt",choices={
            {text="A−",font_size=14,callback=action("size",ReaderPanelPlan.fontSize(settings.size,-1),true)},
            {text=ReaderPanelPlan.sizeDots(settings.size),font_size=12,enabled=false,callback=function() end},
            {text="A+",font_size=24,callback=action("size",ReaderPanelPlan.fontSize(settings.size,1),true)}}}
        local toggles={kind="reading-choices",group_label="Status bar",choices={
            {text=(settings.status and "✓ " or "").."Bottom bar",callback=action("status",nil,true),height=50},
            {text=(settings.clock and "✓ " or "").."Clock",callback=action("clock",nil,true),height=50}}}
        if #quick>0 then
            table.insert(rows,{kind="reader-grid",groups={quick[1],size}})
            table.insert(rows,{kind="reader-grid",groups={quick[2],quick[3]}})
            table.insert(rows,{kind="reader-grid",groups={quick[4],toggles}})
        else
            table.insert(rows,toggles)
        end
        local lights={}
        for _,name in ipairs({"light","warmth"}) do
            if type(settings[name])=="number" then
                lights[#lights+1]={text=(name=="light" and "Light · " or "Warmth · ")..settings[name],value=settings[name],
                    set=function(value) action(name,value,true)() end}
            end
        end
        if #lights>0 then table.insert(rows,{kind="reader-lights",controls=lights}) end
        table.insert(rows,{kind="reader-actions",choices={
            {text="More reading settings…",callback=function() back(); Library.readerAction(ui,"more-settings") end},
            {text="Edit presets",callback=function() back(); if Library.controller() then Library.controller():showSettings("reading") end end}}})
    elseif screen == "reader-top-panel" then
        table.insert(rows, button(m.battery, function() BatteryUI.show() end))
        local text,go
        if caps.account then text,go=AccountView.syncAction(account) end
        if text then table.insert(rows,button(text,function() back(); go() end))
        elseif caps.progress and caps.progress.syncCurrent then
            local sync = button("Sync", function() end)
            local busy = false
            sync.action = function()
                if busy then return end
                busy = true
                local sheet = ReaderPanel.sheet
                sheet.syncing = true
                sync.text = "Syncing…"
                sheet:build(); UIManager:setDirty(sheet, "ui")
                Library.syncCurrent(function(_, message)
                    busy = false
                    sheet.syncing = false
                    -- Never reopen or repaint a dismissed panel over the reading page.
                    if ReaderPanel.sheet ~= sheet or UIManager:getTopmostVisibleWidget() ~= sheet then return end
                    sync.text = message
                    sheet:build(); UIManager:setDirty(sheet, "ui")
                end)
            end
            table.insert(rows, sync)
        end
        table.insert(rows, button("BookSync settings", function()
            back(); if Library.controller() then Library.controller():showSettings() end
        end))
        table.insert(rows, button("Book info", function() ReaderPanel.show(ui, "book-info") end))
        table.insert(rows, {kind="footer", text="Home", action=function()
            back(); if Library.controller() then Library.controller():onOrbitGoHome() end
        end})
        table.insert(rows, {kind="footer", text="KOReader menu", action=function()
            back(); Library.readerAction(ui,"native-menu")
        end})
        local home,settings,info,stock,sync
        for _,r in ipairs(rows) do
            if r.text=="Home" then home=r elseif r.text=="BookSync settings" then settings=r
            elseif r.text=="Book info" then info=r elseif r.text=="KOReader menu" then stock=r
            elseif r.kind=="button" and r.text~=m.battery then sync=r end
        end
        local function cell(r,icon) return {text=r.text,icon=icon,callback=r.action} end
        local header={cell(home,"home")}
        if sync then header[#header+1]=cell(sync,sync.text=="Sync" and "cre.render.reload" or nil) end
        header[#header+1]=cell(settings,"appbar.settings")
        header[#header+1]={text=native.marked and "Remove bookmark" or "Add bookmark",
            icon="bookmark",marked=native.marked,callback=action("bookmark",nil,true)}
        header[1].width=math.floor(1.6*require("device").screen:scaleBySize(50)); header[1].text="Home"; header[1].keep_label=true
        if sync and sync.text~="Sync" then header[2].width=math.floor(2.8*require("device").screen:scaleBySize(50)) end
        rows={
            {kind="reader-header",text=m.title,author=m.author,choices=header},
            {kind="reader-tiles",choices={
                {text="Contents",icon="book.opened",callback=action("contents")},
                {text="Bookmarks",icon="bookmark",callback=action("annotations")},
                {text="Search",icon="appbar.search",callback=action("search")},
                {text="Go to",icon="position.marker",callback=action("goto")},cell(info,"info"),cell(stock,"appbar.menu")}},
            {kind="label",text=(native.chapter or "Chapters not available yet").." · "..m.progress_text},
            {kind="progress",value=m.progress},
            button(m.battery,function() BatteryUI.show() end),
            button("Reading settings",function() ReaderPanel.show(ui,"reader-bottom-panel") end),
        }
        -- Keep the mutable sync status row: the header uses its callback and status remains visible.
        if sync then sync.kind="label"; table.insert(rows,sync) end
    else
        local summary=result.items and result.items[1]
        if summary and summary.series_key and not (caps.series and caps.series.read==false) then
            table.insert(rows, button("View series", function()
                local document=ui and ui.document
                back()
                SeriesUI.show(summary.series_key,function()
                    if not ui or ui.document==document then ReaderPanel.show(ui,screen,key) end
                end)
            end))
        end
        table.insert(rows, {kind="label", text=m.days})
        table.insert(rows, {kind="label", text=m.time})
        table.insert(rows, {kind="label", text=m.pages})
        if screen == "book-info" and m.key then
            table.insert(rows, button("Details", function() ReaderPanel.show(ui, "details") end))
        end
    end
    if not bottom then table.insert(rows, {kind="footer", text=ui and ui.document and "Back to book" or "Back", action=back}) end
    local sheet
    if reuse then
        sheet = reuse
        sheet.model, sheet.display_rows = m, rows
        sheet:build()
        UIManager:setDirty(sheet, "ui")
    else
        ReaderPanel.close()
        sheet = ReaderSheet:new{ui=ui, screen=screen, model=m, display_rows=rows}
        ReaderPanel.sheet = sheet
        UIManager:show(sheet) -- gate: user action (reader top panel, Book info or Details)
    end
    -- A cold projection completes quietly, only while the user-opened surface is still on top.
    if (result.pending or caps.pending or (controls and controls.pending) or (battery and battery.pending)) and (attempt or 0) < 5 then
        local document = ui and ui.document
        UIManager:scheduleIn(0.5, function()
            if ReaderPanel.sheet == sheet and not sheet.syncing and UIManager:getTopmostVisibleWidget() == sheet
                and (not ui or ui.document == document) then
                ReaderPanel.show(ui, screen, key, sheet, (attempt or 0)+1)
            end
        end)
    end
    return true
end
function ReaderPanel.details(key, ui) return ReaderPanel.show(ui, "details", key) end

-- Replace only the visible reader menu. Menu-search construction keeps its native seam.
local okMenu, ReaderMenu = pcall(require, "apps/reader/modules/readermenu")
if okMenu and type(ReaderMenu.onShowMenu) == "function" then
    ReaderPanel.stockMenu = ReaderMenu.onShowMenu
    wrap(ReaderMenu, "onShowMenu", function(stock) return function(self, tab, hidden)
        if hidden or not (self.ui and self.ui.document) then return stock(self, tab, hidden) end
        if self.menu_container then self:onCloseReaderMenu() end
        return ReaderPanel.show(self.ui, "reader-top-panel")
    end end, "reader-panel")
end

local okConfig,ReaderConfig=pcall(require,"apps/reader/modules/readerconfig")
if okConfig and type(ReaderConfig.onShowConfigMenu)=="function" then
    ReaderPanel.stockConfig=ReaderConfig.onShowConfigMenu
    wrap(ReaderConfig,"onShowConfigMenu",function(stock) return function(self)
        if not (self.ui and self.ui.document) then return stock(self) end
        if self.config_dialog then self:onCloseConfigMenu() end
        return ReaderPanel.show(self.ui,"reader-bottom-panel")
    end end,"reader-bottom-panel")
end
-- Native tap handlers normally open both menus. Select exactly one owned panel.
if okMenu and type(ReaderMenu.onTapShowMenu)=="function" then
    wrap(ReaderMenu,"onTapShowMenu",function(stock) return function(self,ges)
        if not (self.ui and self.ui.document) then return stock(self,ges) end
        if self.activation_menu~="swipe" then return ReaderPanel.show(self.ui,"reader-top-panel") end
    end end,"reader-top-tap")
end

if okMenu and type(ReaderMenu.onSwipeShowMenu)=="function" then
    wrap(ReaderMenu,"onSwipeShowMenu",function(stock) return function(self,ges)
        if not (self.ui and self.ui.document) then return stock(self,ges) end
        if self.activation_menu~="tap" and ges.direction=="south" then
            return ReaderPanel.show(self.ui,"reader-top-panel")
        end
    end end,"reader-top-swipe")
end
-- Also reachable from the plugin's existing Tools entry when a native menu is open.
local baseMenu = OrbitAndroid.menuItems
function OrbitAndroid:menuItems(...)
    local rows = baseMenu(self, ...)
    if self.ui and self.ui.document then
        table.insert(rows, 1, {text="Book info", callback=function() ReaderPanel.show(self.ui, "book-info") end})
    end
    return rows
end
local baseClose = OrbitAndroid.onCloseWidget
function OrbitAndroid:onCloseWidget(...)
    if CustomReading and CustomReading.editor then
        CustomReading.editor.return_to=nil
        CustomReading.close()
    end
    if CustomReading and CustomReading.copy_toast then
        UIManager:close(CustomReading.copy_toast)
        CustomReading.copy_toast=nil
    end
    ReaderPanel.close()
    return baseClose(self, ...)
end

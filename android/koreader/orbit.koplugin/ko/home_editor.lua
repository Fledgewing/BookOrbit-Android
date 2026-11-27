-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Explicit Home action. Editor draws geometry only; no widget queries or catalog work.
HomeEditor = {}
function HomeEditor.load() return Library.layout.load() end
function HomeEditor.save(document) return Library.layout.save(document) end
function HomeEditor.available(caps)
    local out={}
    for id,contract in pairs(HomeHost.installed()) do
        local size=contract.sizes["android-tablet"][1]
        local d=Layout.default()
        d.pages={{id="picker",tab="Home",placements={{instance="picker",widget=id,version=contract.version,
            x=0,y=0,w=size[1],h=size[2],settings={}}}}}
        d.overrides["android-tablet"]={}
        if #HomeHostPlan.resolve(d,{[id]=contract},caps).pages[1].placements>0 then out[#out+1]=id end
    end
    table.sort(out)
    return out
end
function HomeEditor.create(host)
    local Input=require("ui/widget/container/inputcontainer")
    local Geom=require("ui/geometry")
    local Editor=Input:extend{name="booksync_home_editor",covers_fullscreen=true}
    function Editor:init()
        self.dimen=Geom:new{w=Device.screen:getWidth(),h=Device.screen:getHeight()}
        local document=HomeHost.document()
        local resolved=HomeHostPlan.resolve(document,HomeHost.installed(),host.caps)
        local id=resolved.pages[host.index].id
        local index=1; for i,p in ipairs(document.pages) do if p.id==id then index=i end end
        self.model=HomeEditorPlan.new(document,index)
        self.key_events={Close={{"Back"}},More={{"Menu"}}}
        self.message=Library.layout.notice
        self:rebuild()
    end
    function Editor:action(fn)
        local done=Budgets.span("editor.operation",now_s,log)
        local ok,err=fn()
        self.message=ok and nil or err
        self:rebuild(); UIManager:setDirty(self,"ui"); done()
        return ok,err
    end
    function Editor:rebuild()
        local done=Budgets.span(self.picker and "editor-picker.draw" or "editor.draw",now_s,log)
        local m=self.model
        local scale=function(n) return Device.screen:scaleBySize(n) end
        local w,h=self.dimen.w,self.dimen.h
        local gap,bh=scale(10),scale(50)
        local canvas=HomeWidgets.canvas(w,h)
        local count=0
        local function button(text,x,y,width,callback)
            return HomeWidgets.button(canvas,_(text),x,y,width,bh,callback)
        end
        local function bar(labels,y)
            local cw=(w-2*gap)/#labels
            for i,b in ipairs(labels) do button(b[1],gap+(i-1)*cw,y,cw-gap,b[2]) end
        end
        if self.picker then
            local ids=HomeEditor.available(host.caps)
            if not (host.caps and host.caps.catalog==false) then
                for _i,preset in ipairs({"also","recent","wtr","finished","ondevice"}) do
                    if not (preset=="wtr" and host.caps.wantToRead==false or preset=="ondevice" and host.caps.onDevice==false) then ids[#ids+1]=preset end
                end
            end
            local per=math.max(1,math.min(3,math.floor((h-scale(150))/scale(150))))
            local pages=math.max(1,math.ceil(#ids/per))
            self.picker=math.min(self.picker,pages)
            HomeWidgets.text(canvas,_("Add a widget"),gap,gap,w-gap*2,24,false,true)
            for i=(self.picker-1)*per+1,math.min(#ids,self.picker*per) do
                local id=ids[i]; local preset=BookList.presets[id]
                local contract=preset and {name=preset.title,description="Book list preset",sizes=WidgetRegistry.booklist.sizes} or WidgetRegistry[id]; local y=scale(60)+(i-1)%per*scale(150)
                count=count+1
                local sizes={}; for _i,s in ipairs(contract.sizes["android-tablet"]) do sizes[#sizes+1]=s[1].."×"..s[2] end
                HomeWidgets.text(canvas,_(contract.name),gap,y,w-2*gap,21,false,true)
                HomeWidgets.text(canvas,_(contract.description),gap,y+scale(30),w-2*gap,15)
                HomeWidgets.text(canvas,_("Sizes")..": "..table.concat(sizes," · "),gap,y+scale(58),w-2*gap,14)
                button("Add",gap,y+scale(83),scale(90),function()
                    self:action(function()
                        local ok,err=m:add(preset and "booklist" or id,self.slotX,self.slotY,preset)
                        if ok then self.picker=nil end
                        if ok and id=="booklist" then self:configure() end
                        return ok,err
                    end)
                end)
            end
            if self.message then HomeWidgets.text(canvas,self.message,gap,h-scale(100),w-2*gap,15) end
            bar({{"‹",function() self.picker=math.max(1,self.picker-1); self:action(function() return true end) end},
                {"Close",function() self.picker=nil; self:action(function() return true end) end},
                {"›",function() self.picker=math.min(pages,self.picker+1); self:action(function() return true end) end}},h-bh-gap)
        else
            button(m:page().name or m:page().tab,gap,gap,w-scale(290),function() self:rename() end)
            button("Add widget",w-scale(280),gap,scale(130),function() self:pick() end)
            button("Done",w-scale(140),gap,scale(130),function() self:done() end)
            local pg=Layout.editorPage(m.document,m.index)
            local grid=m.document.grids["android-tablet"]
            local top,bottom=scale(74),scale(280)
            local occupied={}
            for _i,p in ipairs(pg.placements) do
                count=count+1
                if not p.hidden then
                    for y=p.y,p.y+p.h-1 do for x=p.x,p.x+p.w-1 do occupied[y*grid.cols+x]=true end end
                    local rect=HomeHostPlan.rect(p,grid,w-2*gap,h-top-bottom,gap)
                    local contract=WidgetRegistry[p.widget]
                    local title=(p.settings or {}).title
                    if type(title) ~= "string" or #title>80 then title=contract and contract.name or p.widget end
                    local label=(m.selected==p.instance and "✓ " or "")..title.." · "..p.w.."×"..p.h
                    HomeWidgets.put(canvas,HomeWidgets.ui().Button:new{text=label,width=rect.w,height=rect.h,
                        bordersize=m.selected==p.instance and 3 or 1,text_font_size=16,avoid_text_truncation=false,
                        callback=function() m.selected=p.instance; self:action(function() return true end) end},rect.x+gap,rect.y+top)
                end
            end
            for y=0,grid.rows-1 do for x=0,grid.cols-1 do if not occupied[y*grid.cols+x] then
                local sx,sy=x,y
                local rect=HomeHostPlan.rect({x=x,y=y,w=1,h=1},grid,w-2*gap,h-top-bottom,gap)
                HomeWidgets.put(canvas,HomeWidgets.ui().Button:new{text="+",width=rect.w,height=rect.h,bordersize=1,
                    callback=function() self:pick(sx,sy) end},rect.x+gap,rect.y+top)
            end end end
            local function move(dx,dy) self:action(function() return m:move(dx,dy) end) end
            bar({{"←",function() move(-1,0) end},{"↑",function() move(0,-1) end},{"↓",function() move(0,1) end},
                {"→",function() move(1,0) end},{"Size",function() self:sizes() end},
                {"Remove",function() self:action(function() return m:remove() end) end}},h-scale(265))
            if m.selected then
                for _i,p in ipairs(pg.placements) do if p.instance==m.selected and p.widget=="booklist" then
                    HomeWidgets.button(canvas,_("Configure"),w-scale(140),h-scale(210),scale(130),scale(50),function() self:configure() end)
                end end
            end
            HomeWidgets.text(canvas,(self.message or (m:page().name or "Page").." · "..m.index.." / "..#m.document.pages),gap,h-scale(180),w-scale(170),15)
            bar({{"‹",function() self:turn(-1) end},{"Rename",function() self:rename() end},
                {"›",function() self:turn(1) end},{"+ Page",function() self:action(function() return m:pageAction("add") end) end}},h-scale(150))
            bar({{"Move ‹",function() self:reorder(-1) end},{"Move ›",function() self:reorder(1) end},
                {"Delete page",function() self:confirm("Delete this page and its widgets?",function() return m:pageAction("remove") end) end},
                {"Reset",function() self:reset() end}},h-scale(85))
        end
        self.metrics={drawNodes=#canvas,rows=count,bytes=0,spawns=0,roundTrips=0,network=0,snapshotBytes=0}
        assert(Budgets.check(Budgets.get("screens",self.picker and "editor-picker" or "editor"),self.metrics))
        local old=self[1]
        self[1]=HomeWidgets.ui().Frame:new{padding=0,margin=0,bordersize=0,background=HomeWidgets.ui().BB.COLOR_WHITE,canvas}
        if old then old:free() end
        done()
    end
    function Editor:paintTo(bb,x,y)
        local done=Budgets.span("editor.paint",now_s,log)
        Input.paintTo(self,bb,x,y); done()
    end
    function Editor:turn(delta)
        self.model.index=HomeHostPlan.page(self.model.index,delta,#self.model.document.pages)
        self.model.selected=nil; self:action(function() return true end)
    end
    function Editor:reorder(delta)
        self:action(function() return self.model:pageAction("reorder",self.model.index+delta) end)
    end
    function Editor:pick(x,y)
        self.picker=1; self.slotX,self.slotY=x,y; self:action(function() return true end)
    end
    function Editor:rename()
        local dialog
        dialog=require("ui/widget/inputdialog"):new{title=_("Rename page"),input=self.model:page().name or "",
            buttons={{{text=_("Cancel"),id="close",callback=function() UIManager:close(dialog) end},
                {text=_("Save"),is_enter_default=true,callback=function()
                    local value=dialog:getInputText():match("^%s*(.-)%s*$")
                    self:action(function() return self.model:pageAction("rename",value) end)
                    UIManager:close(dialog)
                end}}}}
        UIManager:show(dialog) -- gate: user action (editor rename)
        dialog:onShowKeyboard()
    end
    function Editor:configure(classic)
        local m=self.model
        for _i,p in ipairs(Layout.editorPage(m.document,m.index).placements) do
            if p.instance==m.selected and p.widget=="booklist" then
                self.config=BookListConfig.new{cfg=p.settings,caps=host.caps,classic=classic or (Device.isTouchDevice and not Device:isTouchDevice()),
                    onDone=function(cfg) return self:action(function() return m:configure(cfg) end) end,
                    onSave=function(saved)
                        local d,page=HomeHostPlan.saveFilter(m.document,saved,"Custom filter")
                        if not d then
                            Gate.show("save Book list",function()
                                UIManager:show(InfoMessage:new{text=_("No room on Home")}) -- gate: Gate.show, explicit save
                            end)
                            return false
                        end
                        m.document=d
                        local name
                        for i,pg in ipairs(d.pages) do if pg.id==page then name=pg.name or pg.tab end end
                        self.config.notice="Book list added to "..(name or "Home").." · Done saves your Home"
                        self:action(function() return true end)
                        return true
                    end}
                self.config:paint(); return self.config
            end
        end
    end
    -- Classic More shares the selected widget's Configure path; no keyboard required.
    function Editor:onMore() return self:configure(true) end
    function Editor:sizes()
        local selected
        for _i,p in ipairs(Layout.editorPage(self.model.document,self.model.index).placements) do if p.instance==self.model.selected then selected=p end end
        if not selected or not WidgetRegistry[selected.widget] then return end
        local buttons={}; local dialog
        for _i,size in ipairs(WidgetRegistry[selected.widget].sizes["android-tablet"]) do
            local sw,sh=size[1],size[2]
            buttons[#buttons+1]={{text=sw.."×"..sh,callback=function()
                self:action(function() return self.model:resize(sw,sh) end); UIManager:close(dialog)
            end}}
        end
        buttons[#buttons+1]={{text=_("Cancel"),callback=function() UIManager:close(dialog) end}}
        dialog=require("ui/widget/buttondialog"):new{title=_("Widget size"),buttons=buttons}
        UIManager:show(dialog) -- gate: user action (editor size)
    end
    function Editor:reset()
        self:confirm("Reset all Home pages to default?",function() return self.model:reset() end)
    end
    function Editor:confirm(text,fn)
        UIManager:show(ConfirmBox:new{text=_(text),ok_callback=function() self:action(fn) end}) -- gate: user action (editor destructive edit)
    end
    function Editor:done()
        local done=Budgets.span("editor.save",now_s,log)
        local ok,err=HomeEditor.save(self.model.document)
        done()
        if not ok then self.message=err; self:rebuild(); UIManager:setDirty(self,"ui"); return false end
        UIManager:close(self)
        host.index=1; host:rebuild(); UIManager:setDirty(host,"ui")
        return true
    end
    function Editor:onCloseWidget()
        if self.config then self.config:close(); self.config=nil end
    end
    function Editor:onClose()
        if self.picker then self.picker=nil; self:action(function() return true end); return true end
        if self.model.selected then self.model.selected=nil; self:action(function() return true end); return true end
        self:done(); return true
    end
    return Editor:new{}
end
function HomeEditor.show(host, action)
    local editor=HomeEditor.create(host)
    UIManager:show(editor) -- gate: user action (Home editor or Settings)
    if action == "rename" then editor:rename()
    elseif action == "reset" then editor:reset() end
    return editor
end
-- Settings uses the same host, draft and save boundary as Home's Edit button.
function HomeEditor.open(action)
    local host=HomeHost.active
    if not (host and topWidget()==host) then
        if not HomeHost.show() then return false end
        host=HomeHost.active
    end
    return HomeEditor.show(host, action)
end

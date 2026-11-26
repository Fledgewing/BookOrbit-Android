-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Small layout session, never catalog data. Input documents are validated by the host.
HomeEditorPlan = {}
function HomeEditorPlan.new(document, index)
    return setmetatable({document=document,index=index or 1}, {__index=HomeEditorPlan})
end
function HomeEditorPlan:page() return self.document.pages[self.index] end
function HomeEditorPlan:accept(document, err)
    if not document then return nil,err end
    self.document=document; self.index=math.min(self.index,#document.pages)
    return true
end
function HomeEditorPlan:id(prefix)
    -- Revision + bounded collision check; IDs remain unique after reset/import.
    local used={}
    for _,pg in ipairs(self.document.pages) do
        used[pg.id]=true
        for _,p in ipairs(pg.placements) do used[p.instance]=true end
    end
    for n=1,Layout.MAX_PLACEMENTS+Layout.MAX_PAGES+1 do
        local id=prefix..self.document.revision.."-"..n
        if not used[id] then return id end
    end
end
function HomeEditorPlan:move(dx,dy)
    return self:accept(Layout.move(self.document,self:page().id,self.selected,dx,dy))
end
function HomeEditorPlan:resize(w,h)
    return self:accept(Layout.resize(self.document,self:page().id,self.selected,w,h))
end
function HomeEditorPlan:remove()
    local ok,err=self:accept(Layout.remove(self.document,self:page().id,self.selected))
    if ok then self.selected=nil end
    return ok,err
end
function HomeEditorPlan:add(widget, x,y)
    local contract=WidgetRegistry[widget]
    if not contract then return nil,"unavailable widget" end
    local id=self:id("widget-")
    local function place(d,pg)
        for _,size in ipairs(contract.sizes["android-tablet"]) do
            local p={instance=id,widget=widget,version=contract.version,x=x or 0,y=y or 0,w=size[1],h=size[2],
                settings=widget == "booklist" and {title="Book list",src="recent",style=0,sort=0,cap=0} or {}}
            local result,err=Layout.add(d,pg.id,p)
            if result then return result end
            if err ~= "no room" then return nil,err end
        end
        return nil,"no room"
    end
    local result,err=place(self.document,self:page())
    local index=self.index
    if not result and err == "no room" then
        local added,why=Layout.page(self.document,"add",self:id("page-"))
        if not added then return nil,why end
        index=#added.pages; result,err=place(added,added.pages[index])
    end
    if not result then return nil,err end
    self.document=result; self.index=index; self.selected=id
    return true
end
function HomeEditorPlan:pageAction(op,value)
    local id=op == "add" and self:id("page-") or self:page().id
    local result,err=Layout.page(self.document,op,id,value)
    if not result then return nil,err end
    if op == "add" then
        result=assert(Layout.page(result,"reorder",id,self.index+1)); self.index=self.index+1
    elseif op == "reorder" then self.index=value end
    if op ~= "rename" then self.selected=nil end
    return self:accept(result)
end
function HomeEditorPlan:reset()
    self.document=Layout.reset(self.document); self.index=1; self.selected=nil
    return true
end

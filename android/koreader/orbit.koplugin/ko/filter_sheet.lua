-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Shared entry for owned lists, Search and Custom filter configuration. No catalog records.
FilterView = {}
function FilterView.new(context)
    context=context or {}
    local model=FilterSheet.new(context)
    return setmetatable({model=model,onApply=context.onApply,onChange=context.onChange,
        onSave=context.onSave,title=context.title or "Library",sorts=context.sorts or
            (model.defaults.sort=="match" and {"match","title","author","added","rating"} or
                model.defaults.sort=="series" and {"series","title","author","last","added","rating"} or {"order","title","author","last","added","rating"}),
        alive=false}, {__index=FilterView})
end
function FilterView:header(total)
    local p=self.model:presentation(total)
    for _,chip in ipairs(p.chips) do
        chip.callback=function() self.model:clear(chip.key,chip.value); self:changed() end
    end
    p.callback=function() self:show() end
    return p
end
function FilterView:changed()
    self.model.offset=0
    if self.onChange then self.onChange(Layout.copy(self.model.query)) end
    if self.alive then self:paint() end
end
function FilterView:close(apply)
    self.alive=false
    if self.retry then UIManager:unschedule(self.retry); self.retry=nil end
    if self.dialog then UIManager:close(self.dialog); self.dialog=nil end
    if apply and self.onApply then self.onApply(Layout.copy(self.model.query)) end
end
function FilterView:show()
    Gate.show("filter sheet", function()
        self.alive=true; self.model.pick=nil; self:paint()
    end) -- gate: Gate.show, explicit filter action
end
function FilterView:back()
    if self.model.pick then self.model.pick=nil; self.model.offset=0; self:paint()
    else self:close(true) end
end
-- One bounded cached read, followed by at most one worker batch. A miss never becomes zero.
function FilterView:read()
    local paint=Library.paint(self.model.pick and "filter-picker" or "filter")
    local result=paint:facets(self.model.source,self.model.query,self.model.pick~="gs" and self.model.pick or nil,
        self.model.offset,FilterSheet.PAGE_SIZE)
    paint:flush()
    return result
end
function FilterView:paint(attempt)
    if not self.alive then return end
    local finish=Budgets.span("filter.draw",now_s,log)
    if self.retry then UIManager:unschedule(self.retry); self.retry=nil end
    local result=self:read()
    local saved=result.freshness and result.freshness.saved
    self.total=saved and result.total or nil
    local buttons={}
    local focus
    local function row(text, action, bold, id)
        local b={text=text,callback=action,font_bold=bold or false,align="left",id=id}
        buttons[#buttons+1]={b}; return b
    end
    local m=self.model
    if m.pick=="gs" then
        local function choices(field, values, title)
            for _,value in ipairs(values) do
                local text=title .. ": " .. (m.query[field]==value and "● " or "○ ") ..
                    (field=="group" and (value=="none" and "Not grouped" or "By " .. value) or value)
                row(text,function() m.query[field]=value; self:changed() end,m.query[field]==value)
            end
        end
        choices("group",{"none","author","series"},"Group")
        choices("sort",self.sorts,"Sort by")
        choices("dir",{"asc","desc"},"Order")
    elseif m.pick then
        for i,option in ipairs(result.items or {}) do
            local display=FilterSheet.option(option,FilterSheet.MULTI[m.pick])
            if option.selected and not focus then focus=i end
            row(display.text,function()
                m:choose(m.pick,option)
                if not FilterSheet.MULTI[m.pick] then m.pick=nil; m.offset=0 end
                self:changed()
            end,option.selected,"option-" .. i)
        end
        if not saved or result.error then row(result.error and "Filter unavailable" or "Counting…",function() self:paint() end) end
        if FilterSheet.MULTI[m.pick] then
            local n=#(m.query[m.pick] or {})
            row("Clear " .. n,function() m:clear(m.pick); self:changed() end)
        end
    else
        for _,r in ipairs(m:rows()) do
            local b=row(r.label .. ": " .. (r.changed and "• " or "") .. r.value .. " ›",function()
                m.pick=r.key; m.offset=0; self:paint()
            end,r.changed)
            if r.divider then table.insert(buttons,#buttons,{}) end -- thin divider, no heading
        end
        local b=row("+ Save as a Book list on Home",function()
            if self.onSave then self.onSave({source="custom-filter",base_source=Layout.copy(m.source),query=Layout.copy(m.query)}); self:close(true) end
        end)
        b.enabled=self.onSave~=nil
        buttons[#buttons+1]={{text="Reset",callback=function() m:reset(); self:changed() end},
            {text=self.total~=nil and ("Show " .. self.total .. " books") or "Counting…",callback=function() self:close(true) end}}
    end
    local nav={{text=m.pick and "‹ Filter" or "Close",callback=function() self:back() end}}
    if m.pick and m.pick~="gs" and ((result.option_total or 0)>FilterSheet.PAGE_SIZE or m.offset>0) then
        nav[#nav+1]={text="‹",enabled=m.offset>0,callback=function() m.offset=math.max(0,m.offset-FilterSheet.PAGE_SIZE); self:paint() end}
        nav[#nav+1]={text="Page " .. (math.floor(m.offset/FilterSheet.PAGE_SIZE)+1) .. " of " .. math.ceil((result.option_total or 0)/FilterSheet.PAGE_SIZE),enabled=false,callback=function() end}
        nav[#nav+1]={text="›",enabled=result.next~=nil,callback=function() m.offset=result.next or m.offset; self:paint() end}
    end
    buttons[#buttons+1]=nav
    local screen=require("device").screen
    local size=require("ui/size")
    -- Budget the entire card before construction: no scrolling of the nine-row sheet.
    local height=math.floor((screen:getHeight()-screen:scaleBySize(160))/#buttons)-2*size.padding.buttontable-2
    for _,line in ipairs(buttons) do for _,b in ipairs(line) do b.height=math.max(16,height); b.font_size=16 end end
    local dialog=require("ui/widget/buttondialog"):new{title="Filter · " .. (m.pick and FilterSheet.LABELS[m.pick] or self.title) ..
        (self.total~=nil and (" · " .. self.total .. " books") or ""),buttons=buttons,width=math.min(screen:getWidth()-screen:scaleBySize(24),screen:scaleBySize(640)),
        tap_close_callback=function() self:back() end}
    -- ButtonDialog owns dismissal; our replacement is explicit so Back cannot close its successor.
    if focus then dialog:moveFocusTo(1,focus) end
    dialog.onClose=function() self:back(); return true end
    for i,option in ipairs(result.items or {}) do
        if option.count==0 then
            local b=dialog:getButtonById("option-" .. i)
            if b and b.label_widget then b.label_widget.fgcolor=require("ffi/blitbuffer").COLOR_DARK_GRAY end
        end
    end
    if self.dialog then UIManager:close(self.dialog) end
    self.dialog=dialog
    Gate.show("filter paint",function()
        if self.alive and self.dialog==dialog then UIManager:show(dialog) end -- gate: Gate.show; visible initiating filter only
    end)
    if result.pending and (attempt or 0)<20 then
        self.retry=function()
            self.retry=nil
            if self.alive and not reading() then self:paint((attempt or 0)+1) end
        end
        UIManager:scheduleIn(0.5,self.retry)
    end
    finish()
end

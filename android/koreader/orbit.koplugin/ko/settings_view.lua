-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Owned presentation over menu.lua's shared row owners. Small pages and native focus/Back.
SettingsView = {}
function SettingsView.open(title, make, screen, onBack)
    local v=setmetatable({title=title,make=make,screen=screen or "settings",offset=0,stack={},alive=true,onBack=onBack,parent=SettingsView.active}, {__index=SettingsView})
    SettingsView.active=v
    v:paint(); return v
end
function SettingsView:close()
    self.alive=false
    if SettingsView.active==self then SettingsView.active=self.parent and self.parent.alive and self.parent or nil end
    if self.retry then UIManager:unschedule(self.retry); self.retry=nil end
    if self.dialog then UIManager:close(self.dialog); self.dialog=nil end
    if self.onBack then local back=self.onBack; self.onBack=nil; back()
    elseif self.parent and self.parent.alive and UIManager:getTopmostVisibleWidget()==self.parent.dialog then
        self.parent:paint()
    end
end
function SettingsView:back()
    local parent=table.remove(self.stack)
    if parent then
        self.title,self.make,self.offset,self.focus=parent.title,parent.make,parent.offset,parent.focus
        self:paint()
    else self:close() end
end
function SettingsView:push(title,make,focus)
    self.stack[#self.stack+1]={title=self.title,make=self.make,offset=self.offset,focus=focus}
    self.title,self.make,self.offset,self.focus=title,make,0,1
    self.choiceFocus=true
    self:paint()
end
function SettingsView:paint(attempt)
    if not self.alive then return end
    if self.retry then UIManager:unschedule(self.retry); self.retry=nil end
    local finish=Budgets.span(self.screen .. ".draw",now_s,log)
    local items=self.make()
    assert(#items<=(Budgets.get("screens",self.screen).displayRows or Budgets.get("screens",self.screen).rows),"Settings display row budget exceeded")
    -- Reserve the title/navigation and a tall mode card. Every action is at least 50 px.
    local screen=Device.screen
    local pageSize=math.max(1,math.min(5,math.floor((screen:getHeight()-screen:scaleBySize(300))/screen:scaleBySize(74))))
    self.offset=math.min(self.offset,math.max(0,math.floor((#items-1)/pageSize)*pageSize))
    if self.choiceFocus then
        self.choiceFocus=nil
        for i,row in ipairs(items) do if row.checked_func and row.checked_func() then
            self.offset=math.floor((i-1)/pageSize)*pageSize; self.focus=i-self.offset; break
        end end
    end
    local buttons,pending={},false
    for i=self.offset+1,math.min(#items,self.offset+pageSize) do
        local row=items[i]
        local text=row.card_text and row.card_text() or row.text_func and row.text_func() or row.text or ""
        local note=row.note_func and row.note_func()
        if note then text=text.."\n"..note end
        if row.checked_func then text=(row.checked_func() and "● " or "○ ")..text end
        local enabled=row.enabled~=false and (not row.enabled_func or row.enabled_func())
        buttons[#buttons+1]={{text=row.card_text and SettingsUI.modeLabel(Library.settings.read(),Library.settings.mode()) or text,id=row.card_text and "mode-card" or row.id or "setting-"..i,align="left",enabled=enabled,
            height=screen:scaleBySize(row.card_text and 180 or row.height or 64),text_font_size=row.card_text and 15 or 16,bordersize=row.section and 0 or nil,text_font_bold=row.section or nil,
            callback=function()
                if not self.alive then return end
                self.focus=i-self.offset
                if row.card_action then row.card_action(); self:paint()
                elseif row.sub_item_table_func or row.sub_item_table then
                    self:push(row.text or text,function()
                        local choices=row.sub_item_table_func and row.sub_item_table_func() or row.sub_item_table
                        local out={}
                        for _,choice in ipairs(choices) do
                            local c={}; for k,v in pairs(choice) do c[k]=v end
                            if c.callback and not c.sub_item_table and not c.sub_item_table_func then
                                local call=c.callback
                                c.callback=function() call(); if not row.keep_choices then self:back() end end
                            end
                            out[#out+1]=c
                        end
                        return out
                    end,self.focus)
                elseif row.callback then
                    local before=self.dialog
                    row.callback()
                    if self.alive and self.dialog==before and UIManager:getTopmostVisibleWidget()==before then self:paint() end
                end
            end}}
        pending=pending or row.pending
    end
    local nav={{text=_("Back"),id="back",height=screen:scaleBySize(50),callback=function() self:back() end}}
    if #items>pageSize then
        nav[#nav+1]={text="‹",id="previous",height=screen:scaleBySize(50),enabled=self.offset>0,
            callback=function() self.offset=math.max(0,self.offset-pageSize); self.focus=1; self:paint() end}
        nav[#nav+1]={text=string.format("%d / %d",math.floor(self.offset/pageSize)+1,math.ceil(#items/pageSize)),enabled=false,height=screen:scaleBySize(50)}
        nav[#nav+1]={text="›",id="next",height=screen:scaleBySize(50),enabled=self.offset+pageSize<#items,
            callback=function() self.offset=self.offset+pageSize; self.focus=1; self:paint() end}
    end
    buttons[#buttons+1]=nav
    local dialog=require("ui/widget/buttondialog"):new{title=_(self.title)..(self.notice and "\n"..self.notice or ""),buttons=buttons,
        width=math.min(screen:getWidth()-screen:scaleBySize(24),screen:scaleBySize(760)),
        tap_close_callback=function() self:back() end}
    -- Button owns focus, border and tap geometry; a multiline label draws the full card.
    -- KOReader 9192014d button.lua:200-216 exposes the label container at a fixed height.
    local card=dialog:getButtonById("mode-card")
    if card then
        local full
        for _,row in ipairs(items) do if row.card_text then full=row.card_text(); break end end
        local label=require("ui/widget/textboxwidget"):new{text=full,width=card.label_container.dimen.w,
            height=card.label_container.dimen.h,face=require("ui/font"):getFace("cfont",15),
            alignment="left",height_adjust=false}
        card.label_widget:free()
        card.label_widget=label; card.label_container[1]=label
    end
    dialog.onClose=function() self:back(); return true end
    dialog:moveFocusTo(1,math.min(self.focus or 1,#buttons))
    if self.dialog then UIManager:close(self.dialog) end
    self.dialog=dialog
    UIManager:show(dialog) -- gate: user action (owned Settings and choice pages)
    if pending and (attempt or 0)<20 then
        self.retry=function()
            self.retry=nil
            if self.alive and UIManager:getTopmostVisibleWidget()==self.dialog then self:paint((attempt or 0)+1) end
        end
        UIManager:scheduleIn(.5,self.retry)
    end
    finish()
end

function SettingsView.sleepChoices(key, category, offset)
    category,offset=category or "lists",offset or 0
    local function make()
        local p=Library.paint("settings-sleep-choices")
        local result=p:sleepChoices(category,offset); p:flush()
        local rows={}
        local function add(text,fn) rows[#rows+1]={text=text,callback=fn} end
        add("Browse: "..category.." · "..tostring(result.total or "—").." choices",function()
            local nextCategory=({lists="collections",collections="libraries",libraries=key=="sleep_leave_out" and "tags" or "lists",tags="lists"})[category]
            category,offset=nextCategory,0
        end)
        for _,item in ipairs(result.items or {}) do
            local id=item.id
            rows[#rows+1]={text=item.title.." · "..(item.count~=nil and tostring(item.count).." books" or "Count not saved"),
                checked_func=function()
                    local values=key=="sleep_from" and SleepPool.sources(Library.settings.read(key)) or SleepPool.decodeRules(Library.settings.read(key))
                    for _,v in ipairs(values) do if v==id then return true end end
                    return false
                end,
                callback=function()
                    Library.settings.set(key,key=="sleep_from" and SleepPool.togglePick(Library.settings.read(key),id) or SettingsUI.toggleRule(Library.settings.read(key),id))
                end}
        end
        if #(result.items or {})==0 then
            rows[#rows+1]={text=result.pending and "Loading choices…" or result.error and "Choices unavailable · Retry" or
                (result.freshness and result.freshness.saved and "No choices" or "Choices not saved yet · Retry"),pending=result.pending,callback=function() Library.retry() end}
        end
        if offset>0 then add("Previous choices",function() offset=math.max(0,offset-6) end) end
        if result.next then add("More choices · "..tostring(result.total or ""),function() offset=result.next end) end
        return rows
    end
    return SettingsView.open(key=="sleep_from" and "Pick from" or "Never show",make,"settings-sleep-choices")
end

function SettingsView:deviceResult(result)
    if not self.alive or UIManager:getTopmostVisibleWidget()~=self.dialog then return end
    self.notice=result.error=="permission" and "Allow changing system settings, then choose Sleep after again."
        or result.error and "Sleep setting unavailable · try again" or nil
    self:paint()
end

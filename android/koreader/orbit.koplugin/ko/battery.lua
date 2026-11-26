-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Snapshot-only UI. Home owns widget reads; this user-opened screen owns one bounded read.
BatteryUI = {}
function BatteryUI.glyph(canvas,fraction,x,y,w,h)
    local u=HomeWidgets.ui()
    HomeWidgets.put(canvas,u.Progress:new{width=w,height=h,percentage=fraction,radius=0,margin_h=0,margin_v=0,
        fillcolor=u.BB.COLOR_BLACK,bgcolor=u.BB.COLOR_WHITE},x,y)
end
function BatteryUI.widget(p,snapshot,dispatch,rect)
    local finish=Budgets.span("battery.widget",now_s,log)
    local data=snapshot.data
    if snapshot.state=="loading" then data={pending=true}
    elseif snapshot.state=="error" then data={error=snapshot.error or "Unavailable"} end
    local plan=BatteryWidgetPlan.widget(data,p.w,p.h)
    local s=function(n) return Device.screen:scaleBySize(n) end
    local w,h=rect.w-2,rect.h-2
    local c=HomeWidgets.canvas(w,h)
    local narrow=p.w==1
    local short=p.h==1
    local x=short and math.floor(w*.30) or s(12)
    local y=short and s(8) or s(84)
    -- The title is also the navigation target; the glyph tracks the actual level.
    HomeWidgets.button(c,"Battery ›",s(8),s(4),short and x-s(12) or w-s(16),s(50),function() dispatch("battery") end)
    if not short then
        BatteryUI.glyph(c,plan.level_fraction,s(12),s(58),s(36),s(16))
        HomeWidgets.text(c,plan.level,s(56),s(54),w-s(68),24,false,true)
    else
        HomeWidgets.text(c,plan.level,s(8),s(34),x-s(12),18,false,true)
        BatteryUI.glyph(c,plan.level_fraction,s(8),h-s(12),math.min(s(36),x-s(16)),s(6))
    end
    local size=narrow and 11 or short and 12 or 13
    local step=math.min(s(narrow and 19 or short and 17 or 23),math.max(1,math.floor((h-y-s(8))/#plan.lines)))
    size=math.min(size,math.max(8,math.floor(step/s(1))-2))
    for i,line in ipairs(plan.lines) do
        HomeWidgets.text(c,line,x,y+(i-1)*step,w-x-s(8),size,false,i==1)
    end
    finish()
    return HomeWidgets.ui().Frame:new{padding=0,margin=0,bordersize=1,c}
end
function BatteryUI.create()
    local Input=require("ui/widget/container/inputcontainer")
    local Geom=require("ui/geometry")
    local Page=Input:extend{name="booksync_battery",covers_fullscreen=true}
    function Page:init()
        self.tab,self.page=1,1
        self.dimen=Geom:new{w=Device.screen:getWidth(),h=Device.screen:getHeight()}
        self.key_events={Close={{"Back"}}}
        self:rebuild()
    end
    function Page:rebuild()
        local finish=Budgets.span("battery.render",now_s,log)
        if self.refresh then UIManager:unschedule(self.refresh); self.refresh=nil end
        local paint=Library.paint("battery")
        local result=paint:battery()
        self.metrics=paint:flush()
        local plan=BatteryWidgetPlan.page(result,self.tab,self.page)
        local s=function(n) return Device.screen:scaleBySize(n) end
        local w,h=self.dimen.w,self.dimen.h
        local c=HomeWidgets.canvas(w,h)
        HomeWidgets.text(c,"Battery · "..plan.level,s(16),s(12),w-s(180),24,false,true)
        BatteryUI.glyph(c,(result.level or 0)/100,w-s(164),s(22),s(44),s(18))
        HomeWidgets.button(c,"Close",w-s(100),s(8),s(90),s(50),function() self:onClose() end)
        HomeWidgets.text(c,plan.estimate,s(16),s(52),w-s(32),16,false,true)
        for i,title in ipairs(BatteryWidgetPlan.tabs) do
            HomeWidgets.button(c,(self.tab==i and "• " or "")..title,(i-1)*w/4,s(84),w/4,s(50),function()
                self.tab,self.page=i,1; self:rebuild(); UIManager:setDirty(self,"ui")
            end)
        end
        local step=math.min(s(58),math.floor((h-s(200))/math.max(1,#plan.rows)))
        for i,row in ipairs(plan.rows) do
            local y=s(140)+(i-1)*step
            HomeWidgets.put(c,require("ui/widget/textboxwidget"):new{
                text=type(row)=="table" and row.text or row,width=w-s(32),
                face=HomeWidgets.ui().Font:getFace("cfont",14)},s(16),y)
            if type(row)=="table" then BatteryUI.glyph(c,row.fraction,s(16),y+step-s(12),w-s(32),s(6)) end
        end
        if plan.pages>1 then
            HomeWidgets.button(c,"‹",s(16),h-s(52),s(80),s(50),function() self:turn(1) end)
            HomeWidgets.button(c,"›",w-s(96),h-s(52),s(80),s(50),function() self:turn(2) end)
            HomeWidgets.text(c,self.page.." / 2",w/2-s(20),h-s(42),s(80),16)
        end
        local old=self[1]
        self[1]=HomeWidgets.ui().Frame:new{padding=0,margin=0,bordersize=0,background=HomeWidgets.ui().BB.COLOR_WHITE,c}
        if old then old:free() end
        finish()
        -- Cold data may arrive after the page opens. Never reopen or steal reading focus.
        if result.pending and (self.attempts or 0)<5 then
            self.attempts=(self.attempts or 0)+1
            self.refresh=function()
                self.refresh=nil
                if UIManager:getTopmostVisibleWidget()==self then self:rebuild(); UIManager:setDirty(self,"ui") end
            end
            UIManager:scheduleIn(0.5,self.refresh)
        end
    end
    function Page:turn(page) self.page=page; self:rebuild(); UIManager:setDirty(self,"ui") end
    function Page:onCloseWidget()
        if BatteryUI.active==self then BatteryUI.active=nil end
        if self.refresh then UIManager:unschedule(self.refresh); self.refresh=nil end
    end
    function Page:onClose() self:onCloseWidget(); UIManager:close(self); return true end
    return Page:new{}
end
function BatteryUI.show()
    local problem=Companion.workerProblem(_("for Battery"))
    if problem then
        UIManager:show(InfoMessage:new{text=problem}) -- gate: user action (Battery)
        return false
    end
    if BatteryUI.active then UIManager:close(BatteryUI.active) end
    BatteryUI.opening=true
    local ok,page=pcall(BatteryUI.create)
    BatteryUI.opening=nil
    if not ok then error(page) end
    BatteryUI.active=page
    UIManager:show(page) -- gate: user action (Battery widget or Settings)
    return page
end

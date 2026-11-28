-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Explicitly opened, bounded reader sheets; security and Android actions stay external.
ReaderCompanionView={}
local V=ReaderCompanionView
function V.open(page)
    if V.active then V.active:close() end
    local v=setmetatable({alive=true,page=page or "status",context=Library.companion.context()}, {__index=V})
    V.active=v
    v:paint()
    return v
end
function V:hide()
    if self.dialog then UIManager:close(self.dialog);self.dialog=nil end
end
function V:close()
    self:hide();self.alive=false
    if self.retire then self.retire();self.retire=nil end
    Library.companion.cancel(self.context)
    if V.active==self then V.active=nil end
end
function V:back()
    if self.page=="permission" then self.page="helpers";self:paint()
    elseif self.page=="helpers" then self.page="status";self:paint()
    else self:close() end
end
function V:external(action)
    if not self.alive or self.busy then return end
    self.returnPage=self.page=="permission" and "helpers" or self.page
    if self.page=="permission" then self.focus="screen" end
    if not Library.companion.departure(self.context) then self:close();return end
    self:hide()
    self.base=UIManager:getTopmostVisibleWidget()
    self.busy=true
    local _,retire=Library.companion.command({action=action},function(result)
        if not self.alive then return end
        self.busy=false
        if result.error and not self.context.departed and Library.isForeground() and Library.companion.current(self.context)
            and UIManager:getTopmostVisibleWidget()==self.base then
            Library.companion.cancel(self.context);self.base=nil
            self.error=result.error=="protected" and "Changes need the parent check. Open Protected settings." or "Action unavailable · try again"
            self.page=self.returnPage;self:paint()
        end
    end)
    self.retire=retire
end
function V:toggle(helper)
    if self.busy then return end
    self.focus=helper.id
    if self.snapshot.protected then self:external("protected");return end
    if helper.id=="screen" and not helper.permission and not helper.on then
        self.page="permission";self:paint();return
    end
    self.busy=true;self.error=nil
    local _,retire=Library.companion.command({action="set",helper=helper.id,on=not helper.on},function(result)
        if not self.alive then return end
        self.busy=false
        if result.error then self.error=result.error=="protected" and "Changes need the parent check. Open Protected settings." or "Change unavailable · review permissions and try again" end
        if Library.isForeground() and Library.companion.current(self.context) and UIManager:getTopmostVisibleWidget()==self.dialog then self:paint() end
    end)
    self.retire=retire
end
function V:paint()
    if not self.alive or not Library.companion.current(self.context) then self:close();return end
    local finish=Budgets.span("reader-"..self.page..".paint",now_s,log)
    Budgets.get("screens",self.page=="status" and "reader-status" or "reader-helpers")
    self.snapshot=Library.companion.snapshot()
    local s=self.snapshot
    local buttons={}
    local focus=1
    local function row(id,text,callback,enabled)
        if id==self.focus then focus=#buttons+1 end
        buttons[#buttons+1]={{id=id,text=text,align="left",callback=callback or function() end,enabled=enabled~=false and not self.busy}}
    end
    local title=self.page=="status" and "Reader Status" or "Reader Helpers"
    if s.unavailable then title=title.."\n"..s.problem
    elseif self.page=="permission" then
        title="Screen off after sync\nAndroid permission is needed to finish the sleep action. Your place is still saved on this reader.\nAndroid settings will open. Return here when finished; BookSync will check the permission again. Permission alone never turns a helper on."
        row("permission","Open Android settings",function() self:external("permission") end)
        row("later","Later",function() self:back() end)
    elseif self.page=="status" then
        title=title.."\n"..s.sync
        row("setup",s.setup,function() self:external("setup") end)
        for i=1,2 do local helper=s.helpers[i]
            row(helper.id,helper.label.." · "..(helper.on and "On" or "Off"),function() self.page="helpers";self:paint() end)
        end
        row("updates",s.updates,function() self:external("recovery") end)
        row("helpers","Helpers",function() self.page="helpers";self:paint() end)
    else
        title=title.."\n"..(s.mode=="full" and "Full mode includes Wi-Fi switching and Sleep sync. Change their policy in Sync settings." or "Permission alone never turns a helper on.")
        for _,helper in ipairs(s.helpers) do
            row(helper.id,helper.label.." · "..(helper.on and "On" or "Off").."\n"..helper.detail,
                function() self:toggle(helper) end,helper.mutable)
        end
        if not s.helpers[3].permission then row("review","Review screen-off permission",function() self.page="permission";self:paint() end) end
        row("protected","Protected settings ›",function() self:external("protected") end)
        row("back","Back",function() self:back() end)
    end
    if self.error then title=title.."\n"..self.error end
    if self.page~="permission" then
        row("recovery","Companion settings › · recovery route",function() self:external("recovery") end)
        row("close","Back to book",function() self:close() end)
    end
    assert(#buttons<=9,"Reader companion display budget exceeded")
    local dialog=require("ui/widget/buttondialog"):new{title=title,buttons=buttons,
        width=math.min(Device.screen:getWidth()-Device.screen:scaleBySize(24),Device.screen:scaleBySize(640)),
        tap_close_callback=function() self:close() end}
    dialog.onClose=function() self:back();return true end
    dialog:moveFocusTo(1,focus)
    self:hide();self.dialog=dialog
    UIManager:show(dialog) -- gate: user action (status/helpers or valid explicit system-action return only)
    finish()
end
function V.resume()
    local v=V.active
    if not v or not v.alive or not v.base or not v.context.departed then return end
    if not Library.companion.returned(v.context) or UIManager:getTopmostVisibleWidget()~=v.base then v:close();return end
    v.base=nil;v.busy=false;v.page=v.returnPage
    if v.retire then v.retire();v.retire=nil end
    v:paint()
end
local resume=OrbitAndroid.onResume
function OrbitAndroid:onResume(...)
    local result=resume(self,...)
    UIManager:scheduleIn(.4,V.resume)
    return result
end
local suspend=OrbitAndroid.onSuspend
function OrbitAndroid:onSuspend(...)
    Library.companion.suspended()
    return suspend(self,...)
end
for _,name in ipairs({"onReaderReady","onCloseDocument"}) do
    local old=OrbitAndroid[name]
    OrbitAndroid[name]=function(self,...)
        Library.companion.newSession()
        if V.active then V.active:close() end
        if old then return old(self,...) end
    end
end

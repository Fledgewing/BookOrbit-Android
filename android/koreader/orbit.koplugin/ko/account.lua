-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Owned Android forms reuse ButtonDialog, the native keyboard and Library's bounded worker port.
AccountView = {}
function AccountView.read(paint)
    local own=not paint
    paint=paint or Library.paint("account")
    local a=paint:accountState()
    if own then paint:flush() end
    return a
end
function AccountView.open(kind)
    Library.accountReturned()
    if AccountView.active then AccountView.active:close() end
    local v=setmetatable({alive=true,state=AccountView.read(),page="summary",focus=kind or "account"},{__index=AccountView})
    AccountView.active=v
    if kind then v:form(kind) else v:paint() end
    return v
end
function AccountView:close()
    self.alive=false; self:retireCommand(); self.password=nil
    if self.dialog then UIManager:close(self.dialog); self.dialog=nil end
    if AccountView.active==self then AccountView.active=nil end
    Library.changed({kind="account"})
end
function AccountView:form(kind)
    self.kind=kind; self.page="form"; self.error=nil
    local l=kind=="account" and self.state or AccountPlan.login(self.state,kind)
    self.server,self.username,self.password=l.server or "",l.username or "",nil
    self.focus="server"; self:paint()
end
function AccountView:retireCommand()
    if self.pending_cancel then self.pending_cancel();self.pending_cancel=nil end
end
function AccountView:back()
    self:retireCommand(); self.busy=false; self.password=nil; self.error=nil
    if self.page=="summary" then self:close(); return end
    if self.page=="signout" then self.focus="signout"

    else self.focus=self.kind or "account" end
    self.page="summary"; self:paint()
end
function AccountView:command(op,args)
    if self.busy then return end
    self:retireCommand()
    self.busy=true; self.error=nil
    local before=self.state
    self.password=nil
    self:paint()
    local accepted,retire=Library.accountCommand(op,args,function(result)
        if not self.alive then return end
        self.busy=false
        if result.error then
            self.error=AccountPlan.error(result.error); self.focus=self.error[3]
            if UIManager:getTopmostVisibleWidget()==self.dialog then self:paint() end
            return
        end
        self.state=result.state or self.state
        Library.retry()
        if op=="account.signIn" then
            self.result,self.returnFocus=AccountPlan.result(before,self.state); self.page="result"; self.focus="done"
        else self.page="summary"; self.focus=op=="account.signOut" and "account" or self.kind end
        -- Completion may update only the still-visible, explicitly opened form.
        if UIManager:getTopmostVisibleWidget()==self.dialog then self:paint() end
    end)
    self.pending_cancel=retire
    args.password=nil
end
function AccountView:edit(field)
    if self.busy then return end
    local dialog
    local function clear() dialog:setInputText(""); dialog.input=""; UIManager:close(dialog) end
    dialog=require("ui/widget/inputdialog"):new{title=({server="Server",username="User name",password="Password"})[field],
        input=field=="password" and "" or self[field],text_type=field=="password" and "password" or nil,
        buttons={{{text="Cancel",callback=clear},{text="Use",callback=function()
            local value=dialog:getInputText()
            local max=field=="server" and 2048 or field=="username" and 100 or 1024
            if #value<=max then self[field]=value; self.error=nil
            else self.error={"That entry is too long","Shorten it and try again.",field} end
            clear(); self.focus=field; self:paint()
        end}}}}
    UIManager:show(dialog) -- gate: user action (account keyboard)
    dialog:onShowKeyboard()
end
function AccountView:paint()
    if not self.alive then return end
    if self.page=="summary" and self.state.pending then self.state=AccountView.read() end
    local finish=Budgets.span("account." .. self.page .. ".paint",now_s,log)
    Budgets.get("screens","account-" .. self.page)
    local buttons={}
    local focus=1
    local function row(id,text,action,enabled)
        buttons[#buttons+1]={{id=id,text=text,align="left",enabled=enabled~=false,callback=action or function() end}}
        if id==self.focus then focus=#buttons end
    end
    local a=self.state
    local title="Your server"
    if self.page=="summary" then
        title=title .. "\n" .. AccountPlan.summary(a)
        if a.signedIn and a.server then row("address",a.server,nil,false) end
        row("account",a.signedIn and "Sign in again…" or "Sign in to your server",function() self:form("account") end)
        if a.signedIn then row("signout","Sign out · Also removes the logins your account set up",function() self.page="signout"; self.focus="keep"; self:paint() end) end
        row("logins","Logins",nil,false)
        for _,k in ipairs({"sync","opds"}) do
            row(k,AccountPlan.names[k] .. " · " .. AccountPlan.status(AccountPlan.login(a,k)),function() self:form(k) end)
        end
        row("close","Close",function() self:close() end)
    elseif self.page=="signout" or self.page=="remove" then
        local out=self.page=="signout"
        title=out and "Sign out of your server?\n" .. AccountPlan.signout(a) or
            "Remove the " .. AccountPlan.names[self.kind] .. "?\n" .. (self.kind=="sync" and "This reader stops syncing your place until a sync login is set again." or
            "This reader can't browse or download from your server until an OPDS login is set again. Downloaded books stay.") .. " Nothing changes on your server."
        row("keep",out and "Stay signed in" or "Keep it",function() self:back() end)
        row("confirm",out and "Sign out" or "Remove",function() self:command(out and "account.signOut" or "login.remove",{kind=self.kind}) end,not self.busy)
    elseif self.page=="result" then
        title="Signed in as " .. (a.username or "your account") .. "\n" .. table.concat(self.result,"\n")
        row("done","Done",function() self.page="summary"; self.focus=self.returnFocus; self:paint() end)
    else
        title=self.kind=="account" and "Sign in to your server" or AccountPlan.names[self.kind] .. " · " .. AccountPlan.status(AccountPlan.login(a,self.kind)) .. "\n" ..
            (self.kind=="sync" and "The sync login KOReader uses to send your place between devices." or "For catalog browsing and downloads.") .. " It works with or without your server account."
        title=title .. "\nEach row opens the keyboard."
        for _,f in ipairs({"server","username","password"}) do
            local label=({server="Server",username="User name",password="Password"})[f]
            local value=self[f]
            if f=="password" then value=value and value~="" and "••••••" or "Enter password"
            elseif value=="" then value=f=="server" and "Your server address" or "Your user name" end
            row(f,label .. ": " .. value,function() self:edit(f) end,not self.busy)
        end
        if self.kind~="account" and not self.busy then
            local l=AccountPlan.login(a,self.kind)
            if a.signedIn and l.origin=="user" then row("replace","Replace with the account's",function() self:command("login.replace",{kind=self.kind}) end) end
            if l.set then row("remove","Remove " .. AccountPlan.names[self.kind] .. "…",function() self.page="remove"; self.focus="keep"; self:paint() end) end
        end
        row("cancel","Cancel",function() self:back() end)
        row("save",self.busy and "Signing in…" or self.kind=="account" and "Sign in" or "Save",function()
            self:command(self.kind=="account" and "account.signIn" or "login.save",{kind=self.kind,server=self.server,username=self.username,password=self.password})
        end,not self.busy and self.server~="" and self.username~="" and self.password~=nil and self.password~="")
    end
    if self.error then
        title=title .. "\n" .. self.error[1] .. "\n" .. self.error[2]
        if self.error[3]=="phone" then row("phone","Phone setup · on the X4 build",function() end) end
    end
    assert(#buttons<=Budgets.get("screens","account-" .. self.page).displayRows,"Account display row budget exceeded")
    local dialog=require("ui/widget/buttondialog"):new{title=title,buttons=buttons,
        width=math.min(Device.screen:getWidth()-Device.screen:scaleBySize(24),Device.screen:scaleBySize(640)),
        tap_close_callback=function() self:back() end}
    dialog.onClose=function() self:back(); return true end
    dialog:moveFocusTo(1,focus)
    if self.dialog then UIManager:close(self.dialog) end
    self.dialog=dialog
    UIManager:show(dialog) -- gate: user action (account form; completion requires visible initiating form)
    if self.state.pending and (self.attempt or 0)<6 then
        self.attempt=(self.attempt or 0)+1
        UIManager:scheduleIn(0.5,function()
            if self.alive and self.page=="summary" and UIManager:getTopmostVisibleWidget()==self.dialog then self:paint() end
        end)
    end
    finish()
end
function AccountView.syncAction(a)
    local text,kind,note=AccountPlan.sync(a)
    return text, function() AccountView.open(kind) end, note
end

-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Immutable Library values and explicit intents only. No scheduling or storage in UI.
RemindersUI={}
local function copy(row)
    local draft={}
    for _,key in ipairs({"kind","id","revision","enabled","minuteOfDay","days","message","intervalMinutes","title","detail","editable","sourceLabel"}) do draft[key]=row[key] end
    return draft
end
local function visible(view)
    return view and view.alive and UIManager:getTopmostVisibleWidget()==view.dialog
end
function RemindersUI.open()
    local saved={items={},pending=true}
    local view
    local function reload(retry)
        Library.reminders.list(function(result)
            saved=result
            if visible(view) then view:paint() end
        end,retry)
    end
    local function editor(row,isNew)
        local draft=copy(row)
        local form,saveIntent,deleteIntent
        local saving,retrySave=false,false
        local function preview(nextDraft,inputTime,done)
            Library.reminders.draft(nextDraft,function(result)
                if result.error then form.notice="Check the time, days and message."
                else
                    for key,value in pairs(result) do draft[key]=value end
                    form.notice=nil
                    if done then done() end
                end
                if visible(form) then form:paint() end
            end,inputTime)
        end
        local function input(title,value,callback)
            local dialog
            dialog=require("ui/widget/inputdialog"):new{title=title,input=value or "",buttons={{{text="Cancel",callback=function() UIManager:close(dialog) end},
                {text="Done",callback=function() local text=dialog:getInputText();UIManager:close(dialog);callback(text) end}}}}
            UIManager:show(dialog) -- gate: user action (reminder draft field)
            dialog:onShowKeyboard()
        end
        local function days()
            local mask=draft.days
            local names={"Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday"}
            form:push("Days",function()
                local out={}
                for _,item in ipairs({{127,"Every day"},{31,"Weekdays"},{96,"Weekends"}}) do
                    out[#out+1]={text=item[2],checked_func=function() return mask==item[1] end,callback=function()
                        mask=item[1];local nextDraft=copy(draft);nextDraft.days=mask;preview(nextDraft,nil,function() form:back() end)
                    end}
                end
                out[#out+1]={text="Custom days",callback=function()
                    form:push("Custom days",function()
                        local choices={}
                        for i,name in ipairs(names) do
                            local bit=2^(i-1)
                            choices[#choices+1]={text=name,checked_func=function() return math.floor(mask/bit)%2==1 end,callback=function()
                                mask=mask+(math.floor(mask/bit)%2==1 and -bit or bit)
                            end}
                        end
                        choices[#choices+1]={text="Done",enabled=mask>0,callback=function()
                            local nextDraft=copy(draft);nextDraft.days=mask
                            preview(nextDraft,nil,function() form:back();form:back() end)
                        end}
                        return choices
                    end)
                end}
                return out
            end)
        end
        local function save()
            local args={}
            for _,key in ipairs({"kind","id","revision","enabled","minuteOfDay","days","message","intervalMinutes"}) do args[key]=draft[key] end
            if saving then return end
            saveIntent=saveIntent or args
            saving=true;form.notice="Saving…";form:paint()
            Library.reminders.mutate(isNew and "add" or "edit",saveIntent,function(result)
                saving=false
                if result.error then
                    retrySave=true
                    form.notice="Could not save reminder. Try again."
                    if visible(form) then form:paint() end
                else saved=result;if form.alive then form:close() end end
            end)
        end
        form=SettingsView.open(isNew and "Add bedtime reminder" or draft.kind=="interval" and "Rest your eyes" or draft.editable==false and "Reminder" or "Edit reminder",function()
            if draft.editable==false then return {{text="Managed by "..(draft.sourceLabel or "source"),enabled=false},{text=draft.title or "Reminder",enabled=false},{text=draft.message or draft.detail,enabled=false}} end
            local rows={{text=draft.enabled and "On" or "Off",callback=function() draft.enabled=not draft.enabled end}}
            if draft.kind=="interval" then
                rows[#rows+1]={text="Interval · "..(draft.detail or "Every 20 minutes of reading"),callback=function()
                    form:push("Interval",function()
                        local choices={}
                        for _,n in ipairs({20,30,45,60}) do choices[#choices+1]={text=n.." minutes",checked_func=function() return draft.intervalMinutes==n end,callback=function()
                            local nextDraft=copy(draft);nextDraft.intervalMinutes=n;preview(nextDraft,nil,function() form:back() end)
                        end} end
                        return choices
                    end)
                end}
            else
                rows[#rows+1]={text="Time · "..(draft.title or "21:00"),callback=function()
                    input("Time",draft.title,function(text) preview(draft,text) end)
                end}
                rows[#rows+1]={text="Days · "..(draft.detail or "Every day"),callback=days}
                rows[#rows+1]={text="Message · "..(draft.message and draft.message~="" and draft.message or "Time to stop reading"),height=84,multiline=true,callback=function()
                    input("Message · up to 60 characters",draft.message,function(text)
                        local nextDraft=copy(draft);nextDraft.message=text;preview(nextDraft)
                    end)
                end}
            end
            for _,r in ipairs(rows) do r.enabled=not saving and not retrySave end
            rows[#rows+1]={text="Save",enabled=not saving,callback=save}
            if not isNew and draft.kind=="time" then rows[#rows+1]={text="Delete",callback=function()
                local confirm
                confirm=require("ui/widget/buttondialog"):new{title="Delete reminder?",buttons={{{text="Cancel",callback=function() UIManager:close(confirm) end}},
                    {{text="Delete",callback=function()
                        UIManager:close(confirm)
                        deleteIntent=deleteIntent or {id=draft.id,revision=draft.revision}
                        Library.reminders.mutate("delete",deleteIntent,function(result)
                            if result.error then form.notice="Could not save reminder. Try again.";if visible(form) then form:paint() end
                            else saved=result;if form.alive then form:close() end end
                        end)
                    end}}}}
                confirm:moveFocusTo(1,1)
                UIManager:show(confirm) -- gate: user action (reminder delete confirmation; Cancel focused)
            end} end
            return rows
        end,"reminders-editor")
        return form
    end
    view=SettingsView.open("Reminders",function()
        if saved.pending then return {{text="Loading reminders…",enabled=false}} end
        if saved.error then return {{text=saved.problem or "Reminders could not be loaded",enabled=false},{text="Retry",callback=function() reload(true) end}} end
        local rows={}
        if saved.notice then rows[#rows+1]={text=saved.notice,enabled=false} end
        if saved.clockStatus=="unknown" then rows[#rows+1]={text="Reminders need the time. Connect to Wi-Fi once to set the clock.",enabled=false,height=96} end
        for _,row in ipairs(saved.items or {}) do
            rows[#rows+1]={text=(row.title or "Reminder").." — "..(row.enabled and "On" or "Off"),
                note_func=function() return row.kind=="interval" and saved.clockStatus=="unknown" and "Uses reading time; no clock needed" or row.detail end,callback=function() editor(row,false) end}
        end
        if saved.timeCount==0 then rows[#rows+1]={text="No bedtime reminders",enabled=false} end
        local full=(saved.timeCount or 0)>=8
        rows[#rows+1]={text=full and "8 bedtime reminders — limit reached" or "Add bedtime reminder",enabled=not full,callback=function()
            Library.reminders.draft({kind="time",enabled=true,minuteOfDay=1260,days=127,message=""},function(result)
                if result.error then view.notice="Could not save reminder. Try again.";if visible(view) then view:paint() end
                elseif visible(view) then editor(result,true) end
            end)
        end}
        return rows
    end,"reminders-list")
    reload();return view
end
function RemindersUI.closeSheet()
    local entry=RemindersUI.current
    if not entry then return end
    RemindersUI.current=nil;entry.alive=false
    Library.reminders.detach(entry.value)
    UIManager:close(entry.dialog)
end
function RemindersUI.due(value)
    if RemindersUI.current then return end
    local entry={value=value,alive=true,focus=1}
    local interval=value.kind=="interval"
    local actions=interval and {{"Done","done"},{"Turn off","turnOff"}} or {{"Got it","gotIt"},{"10 more minutes","snooze10"},{"Sleep","sleep"}}
    local function respond(action)
        if not entry.alive or entry.busy then return end
        entry.busy=true
        Library.reminders.respond(value,action,function(result)
            entry.busy=false
            if not entry.alive or RemindersUI.current~=entry then return end
            if result.error or result.accepted==false and not result.stale then
                entry.error=action=="turnOff" and "Could not turn off reminder. Try again." or action=="sleep" and "Could not sleep. Keep reading or try again." or "Could not save reminder. Try again."
                entry.focus=1;entry:paint()
            else RemindersUI.closeSheet();Library.reminders.dismissed() end
        end)
    end
    local function input(action)
        if action=="dismiss" then respond(interval and "done" or "gotIt")
        elseif action=="select" then
            local a=actions[entry.focus][2]
            if a~="sleep" or value.sleepAvailable then respond(a) end
        else
            entry.focus=math.max(1,math.min(#actions,entry.focus+(action=="up" and -1 or 1)))
            entry.dialog:moveFocusTo(1,entry.focus)
        end
    end
    function entry:paint()
        local finish=Budgets.span("reminders-sheet.draw",now_s,log)
        local buttons={}
        for _,action in ipairs(actions) do
            buttons[#buttons+1]={{text=action[1],enabled=not (action[2]=="sleep" and not value.sleepAvailable or action[2]=="turnOff" and value.editable==false),
                callback=function() if Library.reminders.actionAllowed() then respond(action[2]) end end}}
        end
        local title=(interval and "Rest your eyes" or "Reminder").."\n"..value.message
        if value.dueLabel then title=title.."\n"..value.dueLabel end
        if value.editable==false then title=title.."\nManaged by "..(value.sourceLabel or "source") end
        if not interval and not value.sleepAvailable then title=title.."\nSleep unavailable" end
        if self.error then title=title.."\n"..self.error end
        local dialog=require("ui/widget/buttondialog"):new{title=title,buttons=buttons,stop_events_propagation=true,tap_close_callback=function() input("dismiss") end}
        dialog.onClose=function() input("dismiss");return true end
        dialog.onSwipe=function() input("dismiss");return true end
        dialog.onPan=function() return true end
        -- Native gestures and Back/page turns always consume the input.
        if Device:isTouchDevice() then
            dialog.ges_events.ReminderSwipe={require("ui/gesturerange"):new{ges="swipe",range=require("ui/geometry"):new{x=0,y=0,w=Device.screen:getWidth(),h=Device.screen:getHeight()}}}
            dialog.onReminderSwipe=dialog.onSwipe
        end
        dialog:moveFocusTo(1,self.focus)
        if self.dialog then UIManager:close(self.dialog) end
        self.dialog=dialog
        if Library.reminders.attach(value,dialog,input) then
            Gate.reminder(value,function() UIManager:show(dialog) end) -- gate: claimed reminder only
        end
        finish()
    end
    RemindersUI.current=entry;entry:paint()
    if not entry.dialog or not Library.reminders.canDraw(value) then RemindersUI.closeSheet() end
end
Library.reminders.subscribe(function(kind,value)
    if kind=="due" then RemindersUI.due(value)
    elseif kind=="retired" and RemindersUI.current and RemindersUI.current.value==value then RemindersUI.closeSheet() end
end)

-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Bounded Settings presentation. Library owns dates, count, validation and persistence.
LocalReadingSettings={}
function LocalReadingSettings.open()
    local view,saved
    local function apply(result)
        if not result.error then saved=result end
        -- The mutation outlives its form; presentation never outlives visibility.
        if not view.alive or UIManager:getTopmostVisibleWidget()~=view.dialog then return end
        view.notice=result.error=="invalid" and "Enter a number from 1 to 999."
            or result.error and "Not available · try again" or nil
        view:paint()
    end
    local function edit(snapshot)
        local dialog
        dialog=require("ui/widget/inputdialog"):new{title="Local reading goal · "..tostring(snapshot.year or ""),
            input=snapshot.target and tostring(snapshot.target) or "",input_type="number",
            description="1–999 books · This reader only. Goal carries over each year.",buttons={{
                {text="Cancel",callback=function() UIManager:close(dialog) end},
                {text="Off",callback=function() UIManager:close(dialog);Library.localReadingGoal(nil,apply) end},
                {text="Save",callback=function()
                    local value=dialog:getInputText()
                    UIManager:close(dialog)
                    Library.localReadingGoal(value,apply)
                end}}}}
        UIManager:show(dialog) -- gate: user action (local reading goal input)
        dialog:onShowKeyboard()
    end
    view=SettingsView.open("Reading statistics",function()
        local p=Library.paint("settings-reading-statistics")
        local r=p:localReading();p:flush()
        if saved then r=saved end
        return {{text="Local reading goal",note_func=function() return r.goal_label or "Loading…" end,pending=r.pending,
            enabled=not r.pending and not r.error,callback=function() edit(r) end},
            {text="Finished this year",note_func=function() return r.count_label or "Not available" end,enabled=false},
            {text="Only books explicitly marked finished count.\nAccount totals remain separate when overlap is unknown.",enabled=false,height=96}}
    end,"settings-reading-statistics")
    return view
end

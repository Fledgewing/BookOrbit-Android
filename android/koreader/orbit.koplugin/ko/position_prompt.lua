-- SPDX-License-Identifier: AGPL-3.0-or-later
PositionPrompt={}
function PositionPrompt.close()
    if PositionPrompt.current then
        PositionPrompt.current.answered=true
        UIManager:close(PositionPrompt.current.widget)
        PositionPrompt.current=nil
    end
end
function PositionPrompt.present(result,ui)
    if not result or result.stale or not (ui and ui.document) or liveUI()~=ui then return end
    if result.applied~="ask" then return end
    local document=ui.document
    if Library.reminders and Library.reminders.deferPosition(function()
        if ui.document==document then PositionPrompt.present(result,ui) end
    end) then return end
    local remote=result.remote or {}
    if PositionPrompt.current and PositionPrompt.current.token==result.token then return end
    PositionPrompt.close()
    local span=Budgets.span("position-consent.paint",now_s,log)
    local entry={token=result.token,ui=ui,document=ui.document}
    local function answer(yes)
        if entry.answered then return end
        entry.answered=true
        if PositionPrompt.current==entry then PositionPrompt.current=nil end
        Library.position.answer(result,yes,ui,entry.document)
    end
    local args=Library.position.geometry({remote=remote},ui,"reading")
    local label=type(remote.label)=="string" and remote.label or _("another reader")
    entry.widget=ConfirmBox:new{text=string.format(_("Continue from %s, p. %s?"),label,tostring(args.remote_page or "?")),
        ok_text=_("Yes"),cancel_text=_("No"),ok_callback=function() answer(true) end,cancel_callback=function() answer(false) end}
    PositionPrompt.current=entry
    UIManager:show(entry.widget) -- gate: BookSync position sync's one-draw consent, maintainer exception
    span()
end

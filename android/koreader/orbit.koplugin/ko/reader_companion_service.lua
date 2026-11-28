-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Reader-local snapshot and return tickets: no UI, catalog work or protocol knowledge.
function Library.companion.snapshot()
    local finish=Budgets.span("library.reader-companion",now_s,log)
    local problem=Companion.workerProblem()
    if problem then finish();return {unavailable=true,problem=problem} end
    local reply=Jni.call(Companion.AUTHORITY,Companion.PACKAGE..".call.READER_COMPANION",{patch_version=PATCH_VERSION})
    local raw=reply and reply.ok=="1" and reply.body
    local bytes=type(raw)=="string" and #raw or 0
    local limits=Budgets.get("screens","reader-helpers")
    local within=Budgets.check(limits,{rows=4,bytes=bytes,snapshotBytes=bytes,roundTrips=1,network=0,spawns=0})
    local value=within and type(raw)=="string" and Cache.decode(raw) or nil
    finish()
    if type(value)~="table" or type(value.helpers)~="table" or #value.helpers~=3 then
        return {unavailable=true,problem="Reader status unavailable · try again"}
    end
    return value
end
function Library.companion.context()
    local ui=liveUI()
    return {ui=ui,document=ui and ui.document,epoch=Library.companion.session or 0}
end
function Library.companion.current(context)
    local ui=liveUI()
    return context and context.ui==ui and context.document==(ui and ui.document)
        and context.epoch==(Library.companion.session or 0)
end
function Library.companion.departure(context)
    if not Library.companion.current(context) then return nil end
    context.departed=nil
    Library.companion.ticket=context
    return context
end
function Library.companion.suspended()
    if Library.companion.ticket then Library.companion.ticket.departed=true end
end
function Library.companion.returned(context)
    if context~=Library.companion.ticket or not context.departed then return false end
    Library.companion.ticket=nil
    return Library.companion.current(context) and Library.isForeground() and Jni.isInteractive()~=false
end
function Library.companion.cancel(context)
    if Library.companion.ticket==context then Library.companion.ticket=nil end
end
function Library.companion.newSession()
    Library.companion.session=(Library.companion.session or 0)+1
    Library.companion.ticket=nil
end

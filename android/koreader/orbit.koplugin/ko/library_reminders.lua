-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Device-lifetime Library service. No catalog work or network; native input only updates
-- scalars. The existing asynchronous bridge evaluates at lifecycle changes/once a minute.
local R={serial=0,last=now_s(),generation=0,held={},blocked={},listeners={},started=false}
R.process=tostring(Db.pid())..":"..tostring(os.time())..":"..tostring(now_s())
Library.reminders=R
local function reminderElapsed()
    return (time.boottime and time.to_s(time.boottime()) or now_s())*1000
end
local function call(op,args,done)
    return Library.remindersCommand(op,args or {},done or function() end)
end
local function context()
    local ui=liveUI()
    local document=ui and ui.document
    if R.ui~=ui or R.document~=document then R.ui=ui;R.document=document;R.generation=R.generation+1 end
    local top=topWidget()
    local own=R.sheet and top==R.sheet
    local menu=ui and ui.menu and ui.menu.menu_container
    local home=HomeHost and HomeHost.foreground()
    local base=ui and top==ui or menu and top==menu or home and top==HomeHost.active
    local visible=Library.isForeground() and Jni.isInteractive()~=false and not R.asleep
    return {at=math.floor(reminderElapsed()),owner=R.process..":"..R.generation,visible=not not visible,sleeping=not not R.asleep,
        presenting=not not R.sheet,
        page=not not (ui and ui.document and R.closed~=ui and (top==ui or own and R.page) and not home),
        modal=not not (not base and not own),input=R.process..":"..R.serial,age=math.floor(math.max(0,now_s()-R.last)*1000)}
end
function R.subscribe(fn)
    R.listeners[fn]=true
    return function() R.listeners[fn]=nil end
end
local function publish(kind,value)
    for fn in pairs(R.listeners) do fn(kind,value) end
end
function R.draft(row,done,inputTime)
    if row.message and #row.message>240 or inputTime and #inputTime>16 then done({error="invalid"});return false end
    local args={}
    for _,key in ipairs({"kind","id","revision","enabled","minuteOfDay","days","message","intervalMinutes"}) do args[key]=row[key] end
    args.inputTime=inputTime
    return call("draft",args,done)
end
function R.list(done,retry)
    local problem=Companion.workerProblem("to use reminders")
    if problem then done({error="unavailable",problem=problem});return false end
    return call(retry and "retry" or "list",{},function(result) if result.revision then R.revision=result.revision end;done(result) end)
end
function R.mutate(op,args,done)
    if not args.mutation then
        R.mutation=(R.mutation or 0)+1
        local body=(R.process..":"..R.mutation):sub(-40)
        args.mutation=op=="add" and ("a:"..string.format("%.0f",R.revision or 0)..":"..body) or body
    end
    return call(op,args,function(result) if not result.error then R.revision=result.revision or R.revision;publish("changed",result) end;if done then done(result) end end)
end
function R.canDraw(value)
    if R.grant~=value or type(value)~="table" or not value.grant or value.source~="local" then return false end
    local c=context()
    if not R.sheet then
        local at=reminderElapsed()
        if value.expiresElapsed and at>value.expiresElapsed or value.grantExpiresElapsed and at>value.grantExpiresElapsed then return false end
    end
    return c.owner==value.owner and c.visible and not c.sleeping and not c.modal and
        (value.kind=="time" or value.kind=="interval" and c.page) and not (PositionPrompt and PositionPrompt.current)
end
-- Typed exception; never feeds ordinary Gate.show/drain or allows work to piggyback.
function Gate.reminder(value,draw)
    if not R.canDraw(value) then return false end
    draw();return true
end
function R.attach(value,sheet,input)
    if not R.canDraw(value) then return false end
    R.page=context().page;R.sheet=sheet;R.input=input;R.opened=now_s();R.touchFresh=false
    R.blocked={};for code in pairs(R.held) do R.blocked[code]=true end
    return true
end
function R.detach(value)
    if R.grant~=value then return end
    R.sheet=nil;R.input=nil;R.grant=nil;R.pressed=nil;R.sleepAccepted=nil
end
function R.presenting() return R.sheet~=nil end
function R.actionAllowed() return R.authorized==true end
function R.respond(value,action,done)
    if not R.canDraw(value) then done({stale=true});return false end
    local function sleep()
            -- The sole lifecycle owner checkpoints the current native position before the
            -- one-use sleep intent can reach the same SLEEP_NOW path as Sync and sleep.
            local ui=liveUI()
            local function dispatch()
                if not R.canDraw(value) then done({stale=true});return end
                call("sleep",{grant=value.grant,owner=value.owner},done)
            end
            if ui and ui.document then
                local ok,saved=pcall(function()
                    ui:handleEvent(Event:new("SaveSettings"))
                    return ui.doc_settings:flush(nil,true)
                end)
                if not ok or not saved then done({error="position"});return end
                if not AccountPlan.login(Library.cachedAccountState(),"sync").available then dispatch();return end
                local args=ReadingSync.capture(ui,"suspend");args.online=false
                ReadingSync.command("sync.capture",args,function(r)
                    if r.error then done({error="position"}) else dispatch() end
                end)
            else dispatch() end
    end
    local function answer()
        if R.sleepAccepted==value and action=="sleep" then sleep();return end
        call("respond",{grant=value.grant,owner=value.owner,action=action},function(result)
            if result.sleep then R.sleepAccepted=value;sleep()
            else if result.accepted then R.sleepAccepted=nil end;done(result) end
        end)
    end
    -- Sleep availability is a displayed capability, rechecked by the service. No setup
    -- Activity or automatic permission request is permitted from a reminder.
    if action=="sleep" and not value.sleepAvailable then done({error="unavailable"});return false end
    answer();return true
end
function R.tick()
    UIManager:unschedule(R.tick)
    UIManager:scheduleIn(60,R.tick)
    if R.busy then R.again=true;return end
    if Companion.workerProblem() then return end
    R.busy=true
    local current=context()
    current.previous=R.transition;R.transition=nil
    call("runtime",current,function(result)
        R.busy=nil
        local latest=context()
        if R.grant and (not R.canDraw(R.grant) or result.grantValid==false and not R.sleepAccepted) then
            local retired=R.grant;R.detach(retired);publish("retired",retired)
        end
        if not result.error and not R.grant and current.owner==latest.owner and latest.visible then
            local due=result.due and result.due[1]
            if due and next(R.listeners) then
                R.busy=true
                call("claimDue",{event=due.event,owner=latest.owner},function(value)
                    R.busy=nil
                    if value.grant then
                        R.grant=value
                        if R.canDraw(value) then publish("due",value)
                        else R.detach(value) end
                    end
                end)
            end
        end
        if R.again then R.again=nil;UIManager:nextTick(R.tick) end
    end)
end
function R.lifecycle()
    if R.grant and not R.canDraw(R.grant) then
        local retired=R.grant;R.detach(retired);publish("retired",retired)
    end
    if not R.started then return end
    local captured=context()
    local previous=R.transition
    local function active(c) return c.page and c.visible and not c.sleeping and not c.modal and not c.presenting end
    if not previous or active(previous) and not active(captured) then R.transition=captured end
    if R.queued then return end
    R.queued=true
    UIManager:nextTick(function() R.queued=nil;R.tick() end)
end
function R.start()
    if R.started then return end
    R.started=true;R.lifecycle()
end
function R.deferPosition(fn)
    if not R.sheet and not R.grant then return false end
    R.positionPending=fn;return true
end
function R.activity()
    if not R.sheet and R.positionPending then
        local fn=R.positionPending;R.positionPending=nil;UIManager:nextTick(fn)
    end
    R.last=now_s();R.serial=R.serial+1
    -- No companion call on a page turn. Only a newly waiting occurrence needs the
    -- next fresh interaction; a dismissal requests one evaluation after restoration.
    if R.waiting then R.waiting=nil;R.lifecycle() end
end
function R.dismissed()
    R.waiting=true
end
function R.rawKey(input,ev)
    if not ev or not ev.code then return false end
    local held=R.held[ev.code]
    if ev.value==1 then R.held[ev.code]=true elseif ev.value==0 then R.held[ev.code]=nil end
    if not R.sheet then return false end
    if R.blocked[ev.code] then if ev.value==0 then R.blocked[ev.code]=nil end;return true end
    if ev.value==2 or ev.value==1 and held then return true end
    local name=input and input.event_map and input.event_map[ev.code]
    local mapped=Clicks.map[ev.code]
    local page=mapped~=nil or name=="LPgFwd" or name=="RPgFwd" or name=="LPgBack" or name=="RPgBack" or name=="Left" or name=="Right"
    if ev.value==1 then R.pressed=ev.code;return true end
    if ev.value==0 and R.pressed==ev.code then
        R.pressed=nil
        local action=page and "dismiss" or name=="Up" and "up" or name=="Down" and "down" or
            (name=="Press" or name=="Enter") and "select" or "dismiss"
        if R.input then R.authorized=true;R.input(action);R.authorized=nil end
    end
    return true
end
-- Native lifecycle transitions are not page turns. Coalesce them independently from
-- ticks; a resume transition is reported before the wake input updates activity.
for _,name in ipairs({"init","onSuspend","onResume","onReaderReady","onCloseDocument","onCloseWidget"}) do
    local stock=OrbitAndroid[name]
    OrbitAndroid[name]=function(self,...)
        if name=="onSuspend" then R.asleep=true;R.lifecycle();call("runtime",context()) end
        if name=="onCloseDocument" or name=="onCloseWidget" then R.closed=self.ui end
        local result=stock and stock(self,...)
        if name=="onResume" then R.asleep=false end
        if name=="onReaderReady" then R.closed=nil end
        if name=="init" then R.start() else R.lifecycle() end
        return result
    end
end
if UIManager.handleInputEvent then
    local stock=UIManager.handleInputEvent
    function UIManager:handleInputEvent(ev)
        local physical=type(ev)=="table" and (ev.handler=="onKeyPress" or ev.handler=="onGesture")
        local counted=physical and not R.sheet and context().page
        if counted then R.activity() end
        if R.sheet and type(ev)=="table" and ev.handler=="onGesture" then
            local g=ev.args and ev.args[1]
            if g and g.ges=="touch" then R.touchFresh=true end
            if g and (g.ges=="pan" or g.ges=="hold" or g.ges=="swipe") then R.touchFresh=false end
            R.authorized=g and g.ges=="tap" and R.touchFresh
        end
        local result=stock(self,ev)
        R.authorized=nil
        if physical and not counted and not R.sheet and context().page then R.activity() end
        local c=context();local key=table.concat({c.owner,tostring(c.visible),tostring(c.sleeping),tostring(c.page),tostring(c.modal),tostring(c.presenting)},":")
        if key~=R.contextKey then R.contextKey=key;R.lifecycle() end
        return result
    end
end
-- Record presentation transitions with scalar reads only; callbacks never do IO on paint.
for _,name in ipairs({"show","close"}) do
    local stock=UIManager[name]
    UIManager[name]=function(self,...)
        local result=stock(self,...)
        local c=context();local key=table.concat({c.owner,tostring(c.visible),tostring(c.sleeping),tostring(c.page),tostring(c.modal),tostring(c.presenting)},":")
        if key~=R.contextKey then R.contextKey=key;R.lifecycle() end
        return result
    end
end

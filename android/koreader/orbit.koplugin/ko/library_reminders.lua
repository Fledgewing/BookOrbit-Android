-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Device-lifetime Library service. No catalog work or network; native input only updates
-- scalars. The existing asynchronous bridge evaluates at lifecycle changes/once a minute.
local R={serial=0,last=now_s(),generation=0,held={},blocked={},listeners={},started=false}
R.process=tostring(Db.pid())..":"..tostring(os.time())..":"..tostring(now_s())
Library.reminders=R
local function call(op,args,done)
    return Library.remindersCommand(op,args or {},done or function() end)
end
local function context()
    local ui=liveUI()
    if R.ui~=ui then R.ui=ui;R.generation=R.generation+1 end
    local top=topWidget()
    local own=R.sheet and top==R.sheet
    local menu=ui and ui.menu and ui.menu.menu_container
    local home=HomeHost and HomeHost.foreground()
    local base=ui and top==ui or menu and top==menu or home and top==HomeHost.active
    local visible=Library.isForeground() and Jni.isInteractive()~=false and not R.asleep
    return {owner=R.process..":"..R.generation,visible=not not visible,sleeping=not not R.asleep,
        presenting=not not R.sheet,
        page=not not (ui and ui.document and (top==ui or own and R.page) and not home),
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
    local args={}
    for _,key in ipairs({"kind","id","revision","enabled","minuteOfDay","days","message","intervalMinutes"}) do args[key]=row[key] end
    args.inputTime=inputTime
    return call("draft",args,done)
end
function R.list(done) return call("list",{},done) end
function R.mutate(op,args,done)
    if not args.mutation then
        R.mutation=(R.mutation or 0)+1
        args.mutation=R.process..":"..R.mutation
    end
    return call(op,args,function(result) if not result.error then publish("changed",result) end;if done then done(result) end end)
end
function R.canDraw(value)
    if R.grant~=value or type(value)~="table" or not value.grant or value.source~="local" then return false end
    local c=context()
    if not R.sheet and value.expiresElapsed and time.boottime and time.to_s(time.boottime())*1000>value.expiresElapsed then return false end
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
                ui:handleEvent(Event:new("SaveSettings"))
                local args=ReadingSync.capture(ui,"suspend");args.online=false
                ReadingSync.command("sync.capture",args,function(r)
                    if r.error then done({error="position"}) else dispatch() end
                end)
            else dispatch() end
    end
    local function answer()
        if R.sleepAccepted==value then
            if action=="sleep" then sleep() else done({accepted=true}) end
            return
        end
        call("respond",{grant=value.grant,owner=value.owner,action=action},function(result)
            if result.sleep then R.sleepAccepted=value;sleep() else done(result) end
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
    if not R.started then return end
    if R.queued then return end
    R.queued=true
    UIManager:nextTick(function() R.queued=nil;R.tick() end)
end
function R.start()
    if R.started then return end
    R.started=true;R.lifecycle()
end
function R.activity()
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
for _,name in ipairs({"init","onSuspend","onResume","onReaderReady","onCloseDocument"}) do
    local stock=OrbitAndroid[name]
    OrbitAndroid[name]=function(self,...)
        if name=="onSuspend" then R.asleep=true;call("runtime",context()) end
        local result=stock and stock(self,...)
        if name=="onResume" then R.asleep=false end
        if name=="init" then R.start() else R.lifecycle() end
        return result
    end
end
if UIManager.handleInputEvent then
    local stock=UIManager.handleInputEvent
    function UIManager:handleInputEvent(ev)
        if type(ev)=="table" and (ev.handler=="onKeyPress" or ev.handler=="onGesture") then
            if not R.sheet and context().page then R.activity() end
        end
        if R.sheet and type(ev)=="table" and ev.handler=="onGesture" then
            local g=ev.args and ev.args[1]
            if g and g.ges=="touch" then R.touchFresh=true end
            if g and (g.ges=="pan" or g.ges=="hold" or g.ges=="swipe") then R.touchFresh=false end
            R.authorized=g and g.ges=="tap" and R.touchFresh
        end
        local result=stock(self,ev)
        R.authorized=nil
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

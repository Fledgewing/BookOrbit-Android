-- SPDX-License-Identifier: MIT
return function(test,eq,ok,E,W,UI,Reader,Files)
    local function world(fn)
        local R=E.Library.reminders
        local saved={reader=Reader.instance,fm=Files.instance,shown=W.shown,queue=W.queue,
            command=E.Library.remindersCommand,foreground=E.Library.isForeground,interactive=E.Jni.isInteractive,
            home=E.HomeHost.active,position=E.PositionPrompt.current}
        local ui={document={file="/fixture/reminders.epub"}}
        Reader.instance=ui;Files.instance=nil;W.shown={ui};W.queue={};E.HomeHost.active=nil;E.PositionPrompt.current=nil
        E.Library.isForeground=function() return true end;E.Jni.isInteractive=function() return true end
        R.sheet=nil;R.grant=nil;R.asleep=false;R.held={};R.busy=nil;R.again=nil
        local x={ui=ui,calls={}}
        E.Library.remindersCommand=function(op,args,done)
            table.insert(x.calls,{op=op,args=args});if op=="runtime" then x.owner=args.owner end
            done({due={}});return true
        end
        R.tick()
        x.value={grant="one-use",owner=x.owner,source="local",kind="time",sleepAvailable=true}
        R.grant=x.value
        fn(R,x)
        R.grant=nil;R.sheet=nil;R.input=nil;R.asleep=false;R.busy=nil;R.waiting=nil
        Reader.instance=saved.reader;Files.instance=saved.fm;W.shown=saved.shown;W.queue=saved.queue
        E.Library.remindersCommand=saved.command;E.Library.isForeground=saved.foreground;E.Jni.isInteractive=saved.interactive
        E.HomeHost.active=saved.home;E.PositionPrompt.current=saved.position
    end
    test("reminder gate: only the current typed local grant can draw",function() world(function(R,x)
        local draws=0
        ok(E.Gate.reminder(x.value,function() draws=draws+1 end));eq(draws,1)
        eq(E.Gate.reminder({grant="one-use",owner=x.owner,source="local",kind="time"},function() draws=draws+1 end),false)
        x.value.source="family";eq(E.Gate.reminder(x.value,function() draws=draws+1 end),false);eq(draws,1)
    end) end)
    test("reminder gate: hidden sleeping and background always deny",function() world(function(R,x)
        E.Library.isForeground=function() return false end;eq(R.canDraw(x.value),false)
        E.Library.isForeground=function() return true end;E.Jni.isInteractive=function() return false end;eq(R.canDraw(x.value),false)
        E.Jni.isInteractive=function() return true end;R.asleep=true;eq(R.canDraw(x.value),false)
    end) end)
    test("reminder gate: position consent and other modals are never stacked",function() world(function(R,x)
        E.PositionPrompt.current={};eq(R.canDraw(x.value),false);E.PositionPrompt.current=nil
        W.shown[#W.shown+1]={};eq(R.canDraw(x.value),false)
    end) end)
    test("reminder gate: time may cover a native menu; interval requires page",function() world(function(R,x)
        x.ui.menu={menu_container={}};W.shown[#W.shown+1]=x.ui.menu.menu_container
        ok(R.canDraw(x.value));x.value.kind="interval";eq(R.canDraw(x.value),false)
    end) end)
    test("reminder gate: owner A to B to A never revives an old grant",function() world(function(R,x)
        Reader.instance={document={}};W.shown={Reader.instance};eq(R.canDraw(x.value),false)
        Reader.instance=x.ui;W.shown={x.ui};eq(R.canDraw(x.value),false)
    end) end)
    test("reminder input: held Select and repeats drain before fresh navigation",function() world(function(R,x)
        local actions={};R.held[1]=true;ok(R.attach(x.value,{},function(action) actions[#actions+1]=action end))
        local input={event_map={[1]="Enter",[2]="Down"}}
        for _,value in ipairs({2,0}) do ok(R.rawKey(input,{code=1,value=value})) end;eq(#actions,0)
        R.rawKey(input,{code=2,value=1});R.rawKey(input,{code=2,value=2});R.rawKey(input,{code=2,value=0});eq(actions[1],"down")
        R.rawKey(input,{code=1,value=1});R.rawKey(input,{code=1,value=0});eq(actions[2],"select")
    end) end)
    test("reminder input: every page key dismisses and consumes without focus traversal",function() world(function(R,x)
        local actions={};ok(R.attach(x.value,{},function(action) actions[#actions+1]=action end))
        for _,name in ipairs({"Left","Right","LPgFwd","RPgFwd","LPgBack","RPgBack","Back"}) do
            local input={event_map={[900]=name}}
            ok(R.rawKey(input,{code=900,value=1}));ok(R.rawKey(input,{code=900,value=0}));eq(actions[#actions],"dismiss")
        end
    end) end)
    test("reminder input: native page activity coalesces without IPC",function() world(function(R,x)
        local count=#x.calls;for _=1,10000 do R.activity() end;eq(#x.calls,count)
    end) end)
    test("reminder sleep: unavailable never requests permission or sends an intent",function() world(function(R,x)
        x.value.sleepAvailable=false;local result
        R.respond(x.value,"sleep",function(r) result=r end);eq(result.error,"unavailable");eq(#x.calls,1)
    end) end)
    test("reminder retirement: detach makes all late responses stale",function() world(function(R,x)
        R.detach(x.value);local result
        R.respond(x.value,"sleep",function(r) result=r end);eq(result.stale,true);eq(#x.calls,1)
    end) end)
end

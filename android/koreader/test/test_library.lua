-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Loaded by the existing logic harness. Runtime logic remains on the companion.
return function(test, eq, ok, here, Cache)
    local root = here .. "/../orbit.koplugin/"
    local function source(path)
        local f=assert(io.open(path,"rb")); local s=f:read("*a"); f:close(); return s
    end
    test("library: explicit refresh reuses the adapter command", function()
        local calls = 0
        local e = setmetatable({LibraryAdapter={fullRefresh=function() calls=calls+1; return true end},
            Budgets={span=function() return function() end end}}, {__index=_G})
        setfenv(assert(loadfile(root .. "ko/library.lua")),e)()
        eq(e.Library.fullRefresh(), true); eq(calls, 1)
    end)
    test("reader display: unknown values, clamp, and ready stats", function()
        local e=setmetatable({}, {__index=_G})
        setfenv(assert(loadfile(root .. "logic/reader_panel.lua")),e)()
        local model=e.ReaderPanelPlan.model
        eq(model({items={}},{}).progress,nil)
        eq(model({items={{progress=-5}}},{}).progress,0)
        eq(model({items={{progress=150}}},{}).progress,1)
        eq(model({items={{progress=math.huge}}},{}).progress,nil)
        eq(model({items={{progress=0}}},{}).progress_text,"0% read")
        eq(model({items={{stats={reading_seconds=0,pages_read=0}}}},{}).time,"0 min reading time")
    end)
    test("library: all screens and starter widgets declare strict budgets", function()
        local e = setmetatable({}, {__index=_G}); setfenv(assert(loadfile(root .. "logic/budgets.lua")), e)()
        for _, name in ipairs({"home","library","details","series","settings","battery","filter","editor","reader-top-panel","account"}) do
            local b=e.Budgets.get("screens",name); eq(b.spawns,0); eq(b.network,0); eq(b.roundTrips,name == "editor" and 0 or 1); ok(b.snapshotBytes<=16384)
        end
        for _, name in ipairs({"continue-reading","booklist","library","battery"}) do ok(e.Budgets.get("widgets",name)) end
        eq(pcall(e.Budgets.get,"widgets","undeclared"), false)
    end)
    test("library: bounded ready rows, one batch for a Home paint, no network/fork", function()
        local sends, reads, logs = 0, 0, 0
        local e = setmetatable({Cache=Cache, now_s=function() return 1 end, log=function() logs=logs+1 end,
            LibraryAdapter={ read=function() reads=reads+1; return {items={{key="opaque"}},freshness={saved=true}},128 end,
                request=function(batch) sends=sends+1; eq(#batch,5); return true end}}, {__index=_G})
        setfenv(assert(loadfile(root .. "logic/budgets.lua")),e)()
        setfenv(assert(loadfile(root .. "ko/library.lua")),e)()
        local paint=e.Library.paint("home")
        local shelf=paint:widget("booklist")
        eq(shelf:window("reading",{},0,4).items[1].key,"opaque")
        paint:widget("continue-reading"):book("opaque")
        paint:widget("library"):counts()
        paint:widget("year-in-reading"):readingStats()
        paint:widget("battery"):battery()
        eq(sends,0); eq(reads,5)
        local m=paint:flush(); eq(sends,1); eq(m.roundTrips,1); eq(m.spawns,0); eq(m.network,0)
        eq(m.bytes,640); eq(m.rows,5); eq(logs,6)
        eq(pcall(paint.flush,paint),false)
        eq(pcall(shelf.window,shelf,"all"),false)
    end)
    test("library: missing windows, caller row limits, byte failures and deduplication", function()
        local batch
        local e=setmetatable({Cache=Cache,now_s=function() return 0 end,log=function() end,
            LibraryAdapter={read=function() end,request=function(b) batch=b; return true end}}, {__index=_G})
        setfenv(assert(loadfile(root .. "logic/budgets.lua")),e)(); setfenv(assert(loadfile(root .. "ko/library.lua")),e)()
        local p=e.Library.paint("library")
        eq(p:window("all",{},0,999).pending,true); p:window("all",{},0,999); p:flush()
        eq(#batch,1); eq(Cache.decode(batch[1]).limit,24)
        e.LibraryAdapter.read=function() return {items={{},{}}},128 end
        eq(pcall(function() e.Library.paint("library"):window("all",{},0,1) end),false)
        e.LibraryAdapter.read=function() return {items={}},16385 end
        eq(pcall(function() e.Library.paint("library"):window("all",{},0,1) end),false)
        e.LibraryAdapter.read=function() return {items={}},9000 end
        local page=e.Library.paint("home")
        page:widget("booklist"):window("reading")
        eq(pcall(function() page:widget("booklist"):counts() end),false,"combined widget snapshot is bounded")
    end)
    test("library: facet request inherits the picker budget in one batch", function()
        local request, sends
        local e=setmetatable({Cache=Cache,now_s=function() return 0 end,log=function() end,
            LibraryAdapter={read=function(r) request=Cache.decode(r); return {items={{label="A",count=2}},total=3},128 end,
                request=function(batch) sends=#batch; return true end}}, {__index=_G})
        setfenv(assert(loadfile(root .. "logic/budgets.lua")),e)(); setfenv(assert(loadfile(root .. "ko/library.lua")),e)()
        local p=e.Library.paint("filter-picker")
        local r=p:facets("search",{q="stars",len={max=249}},"author",8,8)
        eq(r.total,3); eq(request.op,"facets"); eq(request.field,"author"); eq(request.offset,8)
        eq(request.query.q,"stars"); eq(request.query.len.max,249); eq(request.limit,8); eq(request.bytes,16384)
        local metrics=p:flush(); eq(sends,1); eq(metrics.roundTrips,1); eq(metrics.rows,1); eq(metrics.spawns,0); eq(metrics.network,0)
    end)
    test("library: registry row budgets aggregate per instance and across Home", function()
        local e=setmetatable({Cache=Cache,now_s=function() return 0 end,log=function() end,
            LibraryAdapter={read=function()
                local items={}; for i=1,12 do items[i]={key=tostring(i)} end
                return {items=items},128
            end,request=function() return true end}}, {__index=_G})
        setfenv(assert(loadfile(root .. "logic/budgets.lua")),e)(); setfenv(assert(loadfile(root .. "ko/library.lua")),e)()
        local p=e.Library.paint("home")
        p:widget("booklist","first"):window("all",{},0,12)
        p:widget("booklist","second"):window("all",{},12,12)
        eq(p.metrics.rows,24,"instances have independent allowances")
        eq(pcall(function() p:widget("booklist","first"):window("all",{},24,12) end),false,"one instance cannot multiply its allowance")
        local q=e.Library.paint("home")
        for i=1,10 do q:widget("booklist",i):window("all",{},i*12,12) end
        eq(pcall(function() q:widget("booklist",11):window("all",{},132,12) end),false,"Home aggregate row cap")
        e.LibraryAdapter.read=function() return {total=2},128 end
        local r=e.Library.paint("home"):widget("library")
        r:counts(); eq(r.usage.rows,1,"summary is a materialized row")
    end)
    test("library: battery widget uses one bounded local row and inherited timing", function()
        local logs=0
        local e=setmetatable({Cache=Cache,now_s=function() return 0 end,log=function() logs=logs+1 end,
            LibraryAdapter={read=function(request)
                local args=Cache.decode(request); eq(args.op,"battery"); eq(args.limit,1)
                return {level=78,hours_usual_use=54},1024
            end,request=function(batch) eq(#batch,1); return true end}}, {__index=_G})
        setfenv(assert(loadfile(root .. "logic/budgets.lua")),e)(); setfenv(assert(loadfile(root .. "ko/library.lua")),e)()
        local p=e.Library.paint("home"); eq(p:widget("battery"):battery().level,78)
        local m=p:flush(); eq(m.rows,1); eq(m.roundTrips,1); eq(m.spawns,0); eq(m.network,0); eq(logs,2)
        e.LibraryAdapter.read=function() return {level=78},16385 end
        eq(pcall(function() e.Library.paint("battery"):battery() end),false)
    end)
    test("library: settings mode lines inherit the caller's three-row budget", function()
        local e=setmetatable({Cache=Cache,now_s=function() return 0 end,log=function() end,
            LibraryAdapter={read=function(request)
                local args=Cache.decode(request); eq(args.op,"mode-estimates"); eq(args.limit,3)
                return {items={{id="saver"},{id="balanced"},{id="current"}}},512
            end,request=function(batch) eq(#batch,1); return true end}}, {__index=_G})
        setfenv(assert(loadfile(root .. "logic/budgets.lua")),e)(); setfenv(assert(loadfile(root .. "ko/library.lua")),e)()
        local p=e.Library.paint("settings"); eq(#p:modeEstimates().items,3)
        local m=p:flush(); eq(m.rows,3); eq(m.roundTrips,1); eq(m.spawns,0); eq(m.network,0)
    end)
    test("library: reopening and source events refresh the worker, publications do not loop", function()
        local e=setmetatable({Cache=Cache, now_s=function() return 10 end, log=function() end,
            OC={watchChecks=function() end},Library={changed=function() end}}, {__index=_G})
        setfenv(assert(loadfile(root .. "ko/server/bookorbit/library_bookorbit.lua")),e)()
        local a=e.LibraryAdapter
        a.owner=function() return "fixture" end
        a.sent={stale=1}; a.watch(true); eq(next(a.sent),nil)
        a.sent={materialized=10}; a.changed({kind="library",owner="fixture"}); eq(a.sent.materialized,10)
        a.changed({kind="checked",owner="other"}); eq(a.sent.materialized,10)
        a.changed({kind="checked",owner="fixture"}); eq(next(a.sent),nil)
        a.watch(false); eq(a.watching,false)
    end)
    test("library: ownership lookup never constructs a client or loads its ledger", function()
        local plugin={settings={username="fixture",server_url="https://library.invalid"},
            newClient=function() error("render constructed a backend client") end}
        local reads=0
        local e=setmetatable({serverPlugin=function() return plugin end, OC={
            client=function() error("render called the legacy client factory") end,
            owner=function(settings) eq(settings,plugin.settings); return "fixture-owner" end},
            Store={library=function(owner, request) reads=reads+1; eq(owner,"fixture-owner"); eq(request,"bounded"); return {items={}},32 end}}, {__index=_G})
        setfenv(assert(loadfile(root .. "ko/server/bookorbit/library_bookorbit.lua")),e)()
        eq(e.LibraryAdapter.owner(),"fixture-owner")
        local r,bytes=e.LibraryAdapter.read("bounded"); eq(#r.items,0); eq(bytes,32); eq(reads,1)
        plugin.settings=nil; eq(e.LibraryAdapter.owner(),nil)
        eq(e.LibraryAdapter.read("bounded"),nil); eq(reads,1)

    end)
    test("library: server boundary has no baselines or suppressions", function()
        local result = os.execute('python3 "' .. here .. '/../../../tools/test/test-server-boundary.py"')
        eq(result, 0, "server boundary guard")
    end)
    test("library: account launch gets the server only inside its adapter", function()
        local calls=0
        local e=setmetatable({Companion={AUTHORITY="trusted",PACKAGE="companion",workerProblem=function() end},
            serverPlugin=function() return {settings={server_url="https://library.invalid"}} end,
            Jni={call=function(_,method,args)
                eq(method,"companion.call.ACCOUNT_OPEN"); eq(args.server,"https://library.invalid")
                calls=calls+1; return {ok="1"}
            end}}, {__index=_G})
        setfenv(assert(loadfile(root .. "ko/server/bookorbit/library_bookorbit.lua")),e)()
        eq(e.LibraryAdapter.openAccount(),true); eq(calls,1)
    end)
    test("library: server lifecycle imports only an opaque owner, never credentials", function()
        local result={ok="1",owner="opaque-login"}
        local e=setmetatable({Companion={AUTHORITY="trusted",PACKAGE="companion",workerProblem=function() end},
            Jni={call=function(_,method,args) eq(method,"companion.call.SERVER_STATE"); eq(next(args),nil); return result end}}, {__index=_G})
        setfenv(assert(loadfile(root .. "ko/server/bookorbit/library_bookorbit.lua")),e)()
        eq(e.LibraryAdapter.accountReturned(),true); eq(e.LibraryAdapter.owner(),"opaque-login")
        eq(e.LibraryAdapter.accountReturned(),false)
        result.owner=nil
        eq(e.LibraryAdapter.accountReturned(),true); eq(e.LibraryAdapter.managed_owner,nil)
        local code=source(root .. "ko/server/bookorbit/library_bookorbit.lua")
        eq(code:find('result.userkey',1,true),nil)
        eq(code:find('result.secret',1,true),nil)
    end)

end

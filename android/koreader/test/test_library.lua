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
    test("library: cover acquisition is explicit and paints read one local snapshot", function()
        local commands, reads, batches = 0, 0, 0
        local e=setmetatable({Cache=Cache,now_s=function() return 1 end,log=function() end,
            LibraryAdapter={reset=function() end,command=function(op,args,done)
                commands=commands+1; eq(op,"covers.acquire"); eq(args.key,"opaque")
                done({local_path="/fixture/cover.jpg"}); return true
            end,read=function(request)
                local args=Cache.decode(request); eq(args.op,"cover"); eq(args.limit,1)
                reads=reads+1; return {local_path="/fixture/cover.jpg",freshness={saved=true}},96
            end,request=function(batch) batches=batches+1; eq(#batch,1); return true end}}, {__index=_G})
        setfenv(assert(loadfile(root.."logic/budgets.lua")),e)()
        setfenv(assert(loadfile(root.."ko/library.lua")),e)()
        local p=e.Library.paint("details")
        eq(p:cover("opaque").local_path,"/fixture/cover.jpg")
        eq(commands,0); eq(reads,1)
        local usage=p:flush(); eq(usage.network,0); eq(usage.spawns,0); eq(usage.roundTrips,1); eq(batches,1)
        local result
        eq(e.Library.acquireCover("opaque",function(r) result=r end),true)
        eq(commands,1); eq(result.local_path,"/fixture/cover.jpg")
    end)
    test("covers: cached references have zero round-trips and retain the one-row budget", function()
        local reads,exists,commands=0,true,0
        local e=setmetatable({Cache=Cache,now_s=function() return 1 end,log=function() end,
            Store={readFile=function(_,limit) eq(limit,1); return exists and "x" or nil end},
            LibraryAdapter={owner=function() return "fixture" end,reset=function() end,
                read=function(request) local q=Cache.decode(request); eq(q.op,"cover.reference"); eq(q.limit,1); reads=reads+1
                    return {local_path="/fixture/local.jpg"},100 end,
                request=function() error("paint must not dispatch") end,
                command=function(op,args,done) commands=commands+1; eq(op,"covers.acquire"); eq(args.reference,"/fixture/ref.jpg"); eq(args.refresh,true); eq(args.owner,"fixture"); done({error="offline"}); return true end}}, {__index=_G})
        setfenv(assert(loadfile(root.."logic/budgets.lua")),e)(); setfenv(assert(loadfile(root.."ko/library.lua")),e)()
        eq(e.Library.cachedCover("/fixture/ref.jpg"),"/fixture/local.jpg"); eq(commands,0); eq(reads,1)
        exists=false; eq(e.Library.cachedCover("/fixture/ref.jpg"),nil)
        local result; e.Library.acquireCoverReference("/fixture/ref.jpg",true,function(r) result=r end)
        eq(commands,1); eq(result.error,"offline")
        local owner,complete="fixture"
        e.LibraryAdapter.owner=function() return owner end
        e.LibraryAdapter.command=function(_,_,done) complete=done; return true end
        e.Library.acquireCoverReference("/fixture/ref.jpg",false,function(r) result=r end)
        owner="changed"; complete({local_path="/fixture/old-account.jpg"})
        eq(result.error,"canceled"); eq(result.local_path,nil)
        eq(e.Budgets.screens["cover-cache"].rows,1); eq(e.Budgets.screens["cover-cache"].roundTrips,0)
    end)
    test("covers: ownership races retry with a strict bound and stop after departure", function()
        local queue,calls,landed,completed={},0,0,0
        local valid=true
        local e=setmetatable({Cache=Cache,Library={acquireCoverReference=function(_,_,done) calls=calls+1; done({error="retryable"}); return true end},
            UIManager={scheduleIn=function(_,_,fn) queue[#queue+1]=fn end}}, {__index=_G})
        setfenv(assert(loadfile(root.."ko/covers.lua")),e)()
        e.CoverQueue.acquire({{reference="local"}},false,function() return valid end,function() landed=landed+1 end,function() completed=completed+1 end)
        for _=1,2 do table.remove(queue,1)() end
        eq(calls,3); eq(#queue,0); eq(landed,1); eq(completed,1)
        e.CoverQueue.acquire({{reference="local"}},false,function() return valid end,function() error("departed") end,function() completed=completed+1 end)
        valid=false; table.remove(queue,1)()
        eq(calls,4); eq(completed,2)
    end)
    test("covers: parent work windows are bounded and preserve remaining jobs", function()
        local q={head=1,tail=6,1,2,3,4,5,6,seen={kept=true}}
        local rows=Cache.takeWindow(q,4); eq(#rows,4); eq(rows[4],4); eq(q.head,5); eq(q.tail,6)
        eq(q.seen.kept,true)
        rows=Cache.takeWindow(q,4); eq(#rows,2); eq(rows[1],5); eq(q.head,1); eq(q.tail,0); eq(next(q.seen),nil)
        eq(pcall(Cache.takeWindow,q,25),false)
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
        for _, name in ipairs({"home","library","search","details","series","settings","battery","filter","editor","reader-top-panel","account","storage","collections"}) do
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
            UIManager={scheduleIn=function() end},Library={changed=function() end}}, {__index=_G})
        setfenv(assert(loadfile(root .. "ko/library.lua")),e)()
        local a=e.LibraryAdapter
        a.owner=function() return "fixture" end
        a.sent={stale=1}; a.watch(true); eq(next(a.sent),nil)
        a.sent={materialized=10}; a.changed({kind="library",owner="fixture"}); eq(a.sent.materialized,10)
        a.changed({kind="checked",owner="other"}); eq(a.sent.materialized,10)
        a.changed({kind="checked",owner="fixture"}); eq(next(a.sent),nil)
        a.watch(false); eq(a.watching,false)
    end)
    test("library: ownership lookup never constructs a client or loads its ledger", function()
        local reads=0
        local e=setmetatable({Cache=Cache,Library={},
            serverPlugin=function() error("render accessed a server plugin") end,
            Store={library=function(owner,request) reads=reads+1; eq(owner,"opaque-owner"); eq(request,"bounded"); return {items={}},32 end}}, {__index=_G})
        setfenv(assert(loadfile(root.."ko/library.lua")),e)()
        e.LibraryAdapter.managed_owner="opaque-owner"
        eq(e.LibraryAdapter.owner(),"opaque-owner")
        local r,bytes=e.LibraryAdapter.read("bounded"); eq(#r.items,0);eq(bytes,32);eq(reads,1)
        e.LibraryAdapter.managed_owner=nil
        eq(e.LibraryAdapter.read("bounded"),nil);eq(reads,1)

    end)
    test("storage: local IO and directory providers work without a backend", function()
        eq(Cache.normalize,nil); eq(Cache.listWindow,nil); eq(Cache.key,nil)
        local mkdirs=0
        local e=setmetatable({Db={pid=function() return 1 end},require=function(name)
            if name=="libs/libkoreader-lfs" then return {mkdir=function() mkdirs=mkdirs+1 end} end
            if name=="datastorage" then return {getSettingsDir=function() return "/fixture/settings" end} end
            error(name)
        end}, {__index=_G})
        setfenv(assert(loadfile(root .. "ko/store.lua")),e)()
        eq(e.OC,nil); eq(e.Store.directoryReady(),false); eq(e.Store.inChild(),false)
        eq(e.Store.dir(),"/fixture/settings/orbit-cache"); eq(e.Store.dir(),"/fixture/settings/orbit-cache")
        eq(mkdirs,2); eq(e.Store.directoryReady(),true)
        e.Store.directory=function() return "/alternate" end
        eq(e.Store.path(),"/alternate/orbit.db")
        local path=os.tmpname()
        local success,err=pcall(function()
            eq(e.Store.writeFile(path,"a\0b"),true)
            eq(e.Store.readFile(path,2),"a\0")
            eq(e.Store.readFile(path),"a\0b")
        end)
        os.remove(path)
        ok(success,err)
    end)
    test("library: server boundary has no baselines or suppressions", function()
        local result = os.execute('python3 "' .. here .. '/../../../tools/test/test-server-boundary.py"')
        eq(result, 0, "server boundary guard")
    end)
    test("library: account launch sends no server login from the plugin", function()
        local calls=0
        local e=setmetatable({Companion={AUTHORITY="trusted",PACKAGE="companion",workerProblem=function() end},
            serverPlugin=function() return {settings={server_url="https://library.invalid"}} end,
            Jni={call=function(_,method,args)
                eq(method,"companion.call.ACCOUNT_OPEN"); eq(next(args),nil)
                calls=calls+1; return {ok="1"}
            end}}, {__index=_G})
        setfenv(assert(loadfile(root .. "ko/library.lua")),e)()
        eq(e.LibraryAdapter.openAccount(),true); eq(calls,1)
    end)
    test("library: server lifecycle imports only an opaque owner, never credentials", function()
        local result={ok="1",owner="opaque-login"}
        local e=setmetatable({Companion={AUTHORITY="trusted",PACKAGE="companion",workerProblem=function() end},
            Jni={call=function(_,method,args) eq(method,"companion.call.SERVER_STATE"); eq(args.reload,"1"); return result end}}, {__index=_G})
        setfenv(assert(loadfile(root .. "ko/library.lua")),e)()
        eq(e.LibraryAdapter.accountReturned(),true); eq(e.LibraryAdapter.owner(),"opaque-login")
        eq(e.LibraryAdapter.accountReturned(),false)
        result.owner=nil
        eq(e.LibraryAdapter.accountReturned(),true); eq(e.LibraryAdapter.managed_owner,nil)
        local code=source(root .. "ko/library.lua")
        eq(code:find('result.userkey',1,true),nil)
        eq(code:find('result.secret',1,true),nil)
    end)

    test("account snapshot: signed-out UI reads one bounded lifecycle row without a catalog owner", function()
        local state={signedIn=false,sync={set=true,available=true,origin="user"},opds={set=false}}
        local body=Cache.encode(state)
        local e=setmetatable({Cache=Cache,ServerCache={encode=Cache.encode,decode=Cache.decode},Budgets={MAX_SNAPSHOT=16384},Companion={workerProblem=function() end,AUTHORITY="fixture",PACKAGE="fixture"},
            Jni={call=function() return {ok="1",body=body} end},serverPlugin=function() return nil end,
            Store={library=function() error("no catalog should be read") end}}, {__index=_G})
        setfenv(assert(loadfile(root .. "ko/library.lua")),e)()
        e.LibraryAdapter.accountReturned()
        local a,n=e.LibraryAdapter.read("opaque","account.state")
        eq(a.signedIn,false); eq(a.sync.origin,"user"); eq(n,#body)
        local caps,bytes=e.LibraryAdapter.read("opaque","capabilities")
        eq(caps.account.sync.available,true); ok(bytes<=16384)
    end)
    test("catalog: progress reads one local row with zero companion round-trips",function()
        local reads,trips=0,0
        local e=setmetatable({Cache=Cache,now_s=function() return 1 end,log=function() end,
            LibraryAdapter={read=function(request)
                local q=Cache.decode(request);eq(q.op,"catalog.state");eq(q.limit,1)
                reads=reads+1;return {row_count=1,pct=42,running=true},96
            end,request=function() trips=trips+1;error("progress is already materialized") end}}, {__index=_G})
        setfenv(assert(loadfile(root.."logic/budgets.lua")),e)()
        setfenv(assert(loadfile(root.."ko/library.lua")),e)()
        eq(e.Library.catalogSnapshot().pct,42);eq(reads,1);eq(trips,0)
        eq(e.Budgets.screens["catalog-refresh"].roundTrips,0)
    end)
    test("catalog: full refresh dispatches only an action and owner and keeps a running run",function()
        local commands,expanded,started,finished,released=0,0,0,0,0
        local nextPoll,owner,status
        owner="opaque";status={row_count=1,running=true,pct=0,beat=1}
        local e=setmetatable({Cache=Cache,now_s=function() return 1 end,log=function() end,reading=function() return false end,
            Store={now=function() return 1 end},Wifi={acquire=function() end,release=function() released=released+1 end},
            UIManager={scheduleIn=function(_,delay,fn) eq(delay,3);nextPoll=fn end},
            Badge={start=function() started=started+1 end,expand=function() expanded=expanded+1 end,update=function() end,finish=function() finished=finished+1 end},
            Companion={workerProblem=function() end},
            LibraryAdapter={owner=function() return owner end,fullRefresh=function() return true end,reset=function() end,
                request=function() error("progress must stay local") end,read=function() return status,96 end,
                command=function(op,args,done)
                    eq(op,"catalog.control");eq(args.owner,"opaque");eq(args.action,"full");eq(args.manual,true)
                    local n=0;for _ in pairs(args) do n=n+1 end;eq(n,3)
                    commands=commands+1;done(status);return true
                end}}, {__index=_G})
        setfenv(assert(loadfile(root.."logic/budgets.lua")),e)()
        setfenv(assert(loadfile(root.."ko/library.lua")),e)()
        eq(e.Library.refreshCatalog("full",true),true);eq(commands,1);eq(started,1)
        e.Badge.running=true
        e.Library.refreshCatalog("full",true);eq(commands,1);eq(expanded,1)
        status={row_count=1,running=false,pct=100,beat=1}
        nextPoll();eq(released,1);eq(finished,1);eq(e.Library.catalog_active,nil)
    end)
    test("catalog: a departed account cannot apply a queued refresh result",function()
        local callback,owner,released,starts
        owner="first";released=0;starts=0
        local e=setmetatable({Cache=Cache,now_s=function() return 1 end,log=function() end,
            Wifi={acquire=function() end,release=function() released=released+1 end},
            Badge={start=function() starts=starts+1 end},Companion={workerProblem=function() end},
            LibraryAdapter={owner=function() return owner end,command=function(_,_,done) callback=done;return true end}}, {__index=_G})
        setfenv(assert(loadfile(root.."logic/budgets.lua")),e)()
        setfenv(assert(loadfile(root.."ko/library.lua")),e)()
        e.Library.refreshCatalog("full",true);owner="second";callback({running=true})
        eq(released,1);eq(starts,0);eq(e.Library.catalog_active,nil)
    end)
    test("catalog: durable event batches dispatch once and retry a lost acknowledgement",function()
        local now,reads,acks,changes,reading=1,0,0,0,false
        local body=Cache.encode({id="durable",events={{kind="library",owner="opaque"}}})
        local e=setmetatable({Cache=Cache,now_s=function() return now end,log=function() end,
            reading=function() return reading end,Store={dir=function() return "/fixture" end,readFile=function(_,limit) eq(limit,65537);reads=reads+1;return body end},
            UIManager={unschedule=function() end,scheduleIn=function() end},
            Companion={ACTION={PATCH="patch"},workerProblem=function() end,send=function(_,args) eq(args.events_ack,"durable");acks=acks+1 end},
            LibraryAdapter={changed=function() changes=changes+1 end}}, {__index=_G})
        setfenv(assert(loadfile(root.."ko/library.lua")),e)()
        e.Library.pollEvents();e.Library.pollEvents();eq(reads,2);eq(acks,1);eq(changes,1)
        now=12;e.Library.pollEvents();eq(acks,2);eq(changes,1)
        reading=true;e.Library.pollEvents();eq(reads,3)
        reading=false;body=string.rep("x",65537);e.Library.pollEvents();eq(acks,2);eq(changes,1)
    end)
    test("catalog: native getters use neutral windows and fetch never forks or calls HTTP",function()
        local calls,flushes,stock=0,0,0
        local last
        local e=setmetatable({Compat={callable=function(v) return type(v)=="function" end,missingOn=function(obj,required)
            local missing={};for k,v in pairs(required) do if type(obj[k])~=v then missing[#missing+1]=k end end;return missing
        end},wrap=function(obj,key,factory) obj[key]=factory(obj[key]) end}, {__index=_G})
        setfenv(assert(loadfile(root.."ko/server/bookorbit.lua")),e)()
        e.Library={compatEvent=function() end,paint=function(screen)
            return {read=function(_,op,args)
                calls=calls+1;last=args
                if op=="connector.home" then return {shelves={reading={{reference=7,title="Ready",authors={}}}},row_count=2} end
                eq(op,"connector.catalog");eq(screen,"library")
                return {items={{reference=7,title="Ready",authors={"Fixture"},cover_available=true}},total=100,more=true}
            end,flush=function() flushes=flushes+1 end}
        end}
        local Api={request=function() stock=stock+1;error("HTTP called") end,requestBlocking=function() error("HTTP called") end,
            runInSubprocess=function() error("fork called") end,query=function() error("route constructed") end}
        local Catalog={fetch=function() error("stock fetch called") end,dashboardRootFetch=function() error("stock dashboard called") end,
            dashboardContext=function(_,body) return body end}
        eq(e.Server.installCatalogApi(Api,Catalog),true)
        local client=setmetatable({},{__index=Api})
        local cat=setmetatable({boardSources=function() return {reading={source="in-progress"}},{} end},{__index=Catalog})
        local body=cat:fetch("Catalog",function() return client:catalogBooks({size=999,page=2,author="Fixture"}) end)
        eq(calls,1);eq(flushes,1);eq(last.limit,24);eq(last.offset,24);eq(last.selection.author,"Fixture")
        eq(body.items[1].id,7);eq(body.items[1].title,"Ready");eq(body.size,24);eq(stock,0)
        local value,err=cat:fetch("Catalog",function() return client:request("GET","forbidden") end)
        eq(value,nil);eq(err,"cancelled");eq(stock,0);eq(e.Server.catalog_paint,nil)
        local home=cat:dashboardRootFetch();eq(home.boardShelves.reading[1].id,7)
        eq(calls,2);eq(flushes,2,"one batched Home read")
    end)

end

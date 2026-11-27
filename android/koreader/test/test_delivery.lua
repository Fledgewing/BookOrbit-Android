-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Library feature interfaces + production tickets, with deterministic JNI/time/scheduler.
return function(test,eq,ok,here,Cache)
    local root=here.."/../orbit.koplugin/"
    local function harness()
        local h={time=0,q={},results={},sent={},polls=0,changed=0,reading=false,visible=true,
            current={owner="A",signedIn=true},status={pending=true},leases=0}
        local function schedule(_,delay,fn) h.q[#h.q+1]={at=h.time+delay,fn=fn} end
        local e=setmetatable({Cache=Cache,now_s=function() return h.time end,log=function() end,
            reading=function() return h.reading end,liveUI=function() return h.ui end,
            S={keep_copies_current=false,sleep_cap=20},Store={now=function() return h.time end},
            Companion={AUTHORITY="fixture",PACKAGE="fixture",workerProblem=function() return h.problem end},
            Wifi={acquire=function() h.leases=h.leases+1 end,release=function() h.leases=h.leases-1;ok(h.leases>=0) end},
            Badge={start=function() end,update=function() h.updates=(h.updates or 0)+1 end,finish=function() end},
            UIManager={scheduleIn=schedule,nextTick=function(self,fn) schedule(self,0,fn) end,
                unschedule=function(_,fn) for i=#h.q,1,-1 do if h.q[i].fn==fn then table.remove(h.q,i) end end end,
                close=function() end,getTopmostVisibleWidget=function() return h.top end},
            G_reader_settings={saveSetting=function(_,key,value) h[key]=value end},
            Jni={call=function(_,method,args)
                if method:match('SERVER_COMMAND$') then
                    if h.reject then return {ok="0"} end
                    local id=tostring(#h.sent+1); h.sent[#h.sent+1]={op=args.op,args=Cache.decode(args.args),id=id}
                    return {ok="1",id=id}
                elseif method:match('SERVER_RESULT$') then
                    h.polls=h.polls+1
                    if h.body~=nil then return {body=h.body} end
                    if h.missing then return {} end
                    return {body=Cache.encode(h.results[args.id] or {pending=true})}
                elseif method:match('SERVER_STATE$') then
                    h.reloads=(h.reloads or 0)+1
                    return {ok="1",pending=h.state_pending and "1" or "0",owner=h.current.owner,body=Cache.encode(h.current)}
                end
                error("unexpected JNI method")
            end}}, {__index=_G})
        function h:load(path) setfenv(assert(loadfile(root..path)),e)() end
        h:load("logic/budgets.lua");h:load("ko/library.lua")
        e.LibraryAdapter.managed_owner="A";e.LibraryAdapter.account_snapshot=h.current
        e.Library.changed=function() h.changed=h.changed+1 end
        e.Library.catalogSnapshot=function() return h.status end
        function h:step()
            table.sort(self.q,function(a,b) return a.at<b.at end)
            local item=table.remove(self.q,1);ok(item,"expected scheduled work")
            self.time=math.max(self.time,item.at);item.fn();return item.fn
        end
        function h:ready(value,id) self.results[id or tostring(#self.sent)]=value end
        function h:owner(owner)
            self.current={owner=owner,signedIn=true}
            e.Library.accountReturned()
        end
        function h:account()
            self:load("logic/account.lua");self:load("ko/account.lua")
            local v=setmetatable({alive=true,state={},page="form",kind="account",paints=0,
                paint=function(v) v.paints=v.paints+1 end},{__index=e.AccountView})
            self.top=v.dialog;return v
        end
        h.e=e;return h
    end
    local function download(h,done) return h.e.Library.downloadCard({key="book"},done) end
    for _,case in ipairs({{"dispatch rejection","reject","unavailable"},{"missing reply","missing","unavailable"},
        {"invalid reply","body","invalid","false"},{"oversize reply","body","unavailable",string.rep("x",16385)}}) do
        test("delivery: "..case[1].." settles once",function()
            local h=harness();local calls,result=0
            h[case[2]]=case[4] or true
            local accepted,retire=download(h,function(r) calls=calls+1;result=r end)
            eq(accepted,not h.reject)
            if accepted then h:step() end
            eq(result.error,case[3]);eq(calls,1);eq(#h.q,0);retire();retire();eq(calls,1)
        end)
    end
    test("delivery: unavailable companion rejects synchronously without a dispatch",function()
        local h=harness();h.problem="missing";local calls=0
        local accepted,retire=download(h,function(r) eq(r.error,"unavailable");calls=calls+1 end)
        eq(accepted,false);eq(calls,1);eq(#h.sent,0);retire();eq(#h.q,0)
    end)
    test("delivery: pending to ready settles once and retire after success is harmless",function()
        local h=harness();local calls=0
        local accepted,retire=download(h,function(r) eq(r.local_path,"/fixture/book.epub");calls=calls+1 end)
        eq(accepted,true);local stale=h:step();eq(calls,0);eq(#h.q,1)
        h:ready({local_path="/fixture/book.epub"});h:step();stale();retire()
        eq(calls,1);eq(#h.q,0);eq(h.polls,2)
    end)
    for _,seconds in ipairs({120,121}) do
        test("delivery: ready reply at "..seconds.." seconds still counts",function()
            local h=harness();local calls=0
            download(h,function(r) eq(r.error,nil);calls=calls+1 end)
            h.time=seconds;h:ready({local_path="/fixture/book.epub"});h:step()
            eq(calls,1);eq(#h.q,0)
        end)
        test("delivery: pending reply at "..seconds.." seconds times out permanently",function()
            local h=harness();local calls=0
            download(h,function(r) eq(r.error,"unavailable");calls=calls+1 end)
            h.time=seconds;local stale=h:step();h:ready({local_path="/fixture/late.epub"});stale()
            eq(calls,1);eq(#h.q,0);eq(h.polls,1)
        end)
    end
    for _,action in ipairs({"close","back"}) do
        test("delivery: account "..action.." retires polls but durable completion reconciles",function()
            local h=harness();local v=h:account();local args={password="transient"}
            v:command("account.signIn",args);eq(args.password,nil)
            h:step();v[action](v);local paints=v.paints;eq(#h.q,0)
            h:owner("B");h:ready({state={owner="A",signedIn=true}})
            eq(h.e.LibraryAdapter.owner(),"B");eq(v.paints,paints)
            -- The companion's durable account event survives the retired form.
            h.current={owner="C",signedIn=true};h.e.Library.applyEvents({{kind="account"}})
            eq(h.e.LibraryAdapter.owner(),"C");eq(v.paints,paints);eq(h.polls,1);eq(#h.q,0)
        end)
    end
    test("delivery: account reply uses current state rather than its historical snapshot",function()
        local h=harness();local result
        h.e.Library.accountCommand("login.remove",{},function(r) result=r end)
        h.current={owner="B",signedIn=true};h:ready({state={owner="A",signedIn=true}});h:step()
        eq(result.state.owner,"B");eq(h.e.LibraryAdapter.owner(),"B");eq(#h.q,0)
    end)
    test("delivery: new account attempt replaces old ticket through A to B to A",function()
        local h=harness();local v=h:account()
        v:command("account.signIn",{});local old=h.q[1].fn
        v:back();v:command("login.remove",{});local paints=v.paints
        h:owner("B");h:owner("A");h:ready({state={owner="B"}},"1");old()
        eq(v.paints,paints);eq(v.busy,true)
        h:ready({state={owner="B"}},"2");h:step()
        eq(v.busy,false);eq(v.state.owner,"A");eq(v.page,"summary");eq(#h.q,0)
    end)
    test("delivery: reload retries are ordered and coalesce waiting account deliveries",function()
        local h=harness();local result
        h.e.Library.accountCommand("login.remove",{},function(r) result=r end)
        h.state_pending=true;h:ready({state={owner="old"}});h:step()
        local old=h.q[1].fn;eq(result,nil)
        h.e.Library.accountReturned();eq(#h.q,1)
        h.current={owner="B"};h.state_pending=false;old();eq(result,nil)
        h:step();eq(result.state.owner,"B");eq(h.e.LibraryAdapter.owner(),"B");eq(#h.q,0)
    end)
    test("delivery: retiring during state reconciliation drops presentation only",function()
        local h=harness();local calls=0
        local _,retire=h.e.Library.accountCommand("login.remove",{},function() calls=calls+1 end)
        h.state_pending=true;h:ready({state={owner="old"}});h:step();retire()
        h.current={owner="B"};h.state_pending=false;h:step()
        eq(calls,0);eq(h.e.LibraryAdapter.owner(),"B");eq(#h.q,0)
    end)
    test("delivery: pending state retries are bounded and never install a pending owner",function()
        local h=harness();local result
        h.e.Library.accountCommand("login.remove",{},function(r) result=r end)
        h.current={owner="B"};h.state_pending=true;h:ready({state={owner="old"}})
        for _=1,4 do h:step() end
        eq(result.error,"unavailable");eq(result.state,nil);eq(h.e.LibraryAdapter.owner(),"A");eq(#h.q,0)
    end)
    test("delivery: hidden live account gets its model without repaint",function()
        local h=harness();local v=h:account();v.dialog={};h.top={}
        v:command("login.remove",{});local paints=v.paints
        h.current={owner="B"};h:ready({state={owner="old"}});h:step()
        eq(v.state.owner,"B");eq(v.busy,false);eq(v.paints,paints)
    end)
    for _,when in ipairs({"before dispatch","during request"}) do
        test("delivery: cancel card "..when.." retires all its work",function()
            local h=harness();local cancel=h.e.Library.prepareCardCover({key="book"},function() error("unexpected bitmap") end,function() return true end)
            if when=="during request" then h:step();h:step() end
            local polls=h.polls;cancel();cancel();eq(#h.q,0);eq(h.polls,polls)
        end)
    end
    for _,invalidation in ipairs({"owner","reading","hidden"}) do
        test("delivery: card "..invalidation.." invalidation suppresses notification and bitmap",function()
            local h=harness();local deliveries=0
            h.e.Library.prepareCardCover({key="book"},function() deliveries=deliveries+1 end,function() return h.visible end)
            h:step();h:ready({local_path="/fixture/cover.jpg"})
            if invalidation=="owner" then h:owner("B") elseif invalidation=="reading" then h.reading=true else h.visible=false end
            local changed=h.changed;h:step();eq(h.changed,changed);eq(deliveries,0);eq(#h.q,0);eq(h.polls,0)
        end)
    end
    test("delivery: card cover input retains its file and byte bounds",function()
        for _,case in ipairs({{mode="file",size=524288,expected=1},{mode="file",size=524289,expected=0},
            {mode="directory",size=1,expected=0},{expected=0}}) do
            local h=harness();local delivered=0
            h.e.require=function(name)
                eq(name,"lfs");return {attributes=function() return case end}
            end
            h.e.Library.prepareCardCover({cover_path="/fixture/cover.jpg"},function(path)
                eq(path,"/fixture/cover.jpg");delivered=delivered+1
            end,function() return true end)
            h:step();eq(delivered,case.expected);eq(#h.sent,0);eq(#h.q,0)
        end
    end)
    test("delivery: cover retry stops after its consumer disappears",function()
        local h=harness();h:load("ko/covers.lua");local valid=true;local completed=0
        h.e.CoverQueue.acquire({{reference="/fixture/ref"}},false,function() return valid end,
            function() error("unexpected cover") end,function(success) eq(success,false);completed=completed+1 end)
        h:ready({error="retryable"});h:step();eq(#h.q,1)
        valid=false;h:step();eq(#h.sent,1);eq(completed,1);eq(#h.q,0)
    end)
    test("delivery: owner-bound cover reference and download cannot revive across A to B to A",function()
        local h=harness();local results={}
        h.e.Library.acquireCoverReference("/fixture/ref",false,function(r) results[#results+1]=r end)
        download(h,function(r) results[#results+1]=r end)
        h:ready({local_path="/fixture/old.jpg"},"1");h:ready({local_path="/fixture/old.epub"},"2")
        h:owner("B");h:owner("A");local changed=h.changed
        h:step();h:step();eq(#results,2);eq(results[1].error,"canceled");eq(results[2].error,"canceled")
        eq(h.changed,changed);eq(h.polls,0);eq(#h.q,0)
    end)
    for _,stage in ipairs({"command","watcher"}) do
        test("delivery: superseded catalog "..stage.." releases exactly its own lease",function()
            local h=harness();local L=h.e.Library
            L.refreshCatalog("resume",true);eq(h.leases,1)
            if stage=="watcher" then h:ready({run="old"});h:step() end
            local old=h.q[1].fn
            L.refreshCatalog("full",true);eq(h.leases,1);eq(#h.q,1)
            old();eq(L.catalog_active,true);eq(h.leases,1)
            L.refreshCatalog("full",true);eq(h.leases,1);eq(#h.sent,2)
            h:ready({error="unavailable"});h:step();eq(h.leases,0);eq(L.catalog_active,nil);eq(#h.q,0)
            old();eq(h.leases,0)
        end)
    end
    test("delivery: catalog ignores another run and retains a healthy long run",function()
        local h=harness();local L=h.e.Library;h.e.Badge.running=true
        L.refreshCatalog("full",true);h:ready({run="wanted"});h:step()
        h.status={run="other",running=false};h:step();eq(h.updates,nil);eq(h.leases,1)
        h.time=121;h.status={run="wanted",running=true,beat=121};h:step();eq(h.updates,1);eq(h.leases,1)
        h.status={run="wanted",running=false,beat=121};h:step();eq(h.leases,0);eq(#h.q,0)
    end)
    for _,depart in ipairs({"owner","closed","replaced"}) do
        test("delivery: end-sheet download cannot open after "..depart, function()
            local h=harness();local e=h.e;local opened=0
            e.OrbitAndroid={};e.wrap=function() end
            e.require=function(name) if name=="apps/reader/modules/readerstatus" then return {} end;return require(name) end
            h:load("ko/finish.lua")
            e.ReadingSync={run=function(_,done) done(true) end}
            e.FinishUI.onLeave=function() end;e.FinishUI.refreshSheet=function() end
            e.Library.open=function() opened=opened+1 end;e.FinishUI.sheet={}
            e.FinishUI.actions.book({}, {file="/fixture/current",digest="document"},"key","Title")
            eq(h.sent[1].args.action,"finish.drain");h:ready({});h:step()
            eq(h.sent[2].args.action,"finish.download")
            if depart=="owner" then h:owner("B") elseif depart=="closed" then e.FinishUI.sheet=nil else e.FinishUI.sheet={} end
            h:ready({local_path="/fixture/old.epub"});h:step();eq(opened,0);eq(#h.q,0)
        end)
    end
    test("delivery: position run success retires completion timer",function()
        local h=harness();h:load("ko/position_sync.lua");local R=h.e.ReadingSync;local calls=0
        R.ready=true;R.capture=function() return {} end
        R.run("manual",function(okay) eq(okay,true);calls=calls+1 end)
        h:ready({remaining=0});h:step();eq(calls,1);eq(#h.q,0)
    end)
    for _,replace in ipairs({false,true}) do
        test("delivery: position timeout suppresses late consent, document replaced="..tostring(replace),function()
            local h=harness();h:load("ko/position_sync.lua");local R=h.e.ReadingSync;local calls,presents,verified=0,0,0
            h.ui={document={file="/fixture/current"}}
            R.ready=true;R.on=function() return true end
            R.capture=function() return {path="/fixture/current",online=true,automatic=true} end
            R.geometry=function() return {} end
            R.present=function() presents=presents+1 end;R.verify=function() verified=verified+1 end
            R.run("manual",function(okay,why) eq(okay,false);ok(why);calls=calls+1 end)
            h:ready({snapshot={},document="document"});h:step();eq(h.sent[2].op,"sync.decide")
            -- Run the independent completion timeout, leaving durable command polling live.
            h.time=21
            local timeout
            for _,item in ipairs(h.q) do if item.at==20 then timeout=item.fn end end
            ok(timeout);timeout();eq(calls,1)
            if replace then h.ui.document={file="/fixture/replacement"} end
            h:ready({applied="ask",remaining=0});h:step()
            eq(presents,0);eq(calls,1);eq(verified,replace and 0 or 1);eq(#h.q,0)
        end)
    end
    for _,op in ipairs({"folder","sleep"}) do
        test("delivery: retired "..op.." presentation still adopts durable device change",function()
            local h=harness();local calls=0;local accepted,retire
            if op=="folder" then accepted,retire=h.e.Library.storageCommand("storage.folder",{},function() calls=calls+1 end)
            else accepted,retire=h.e.Library.sleepAfter(60000,function() calls=calls+1 end) end
            eq(accepted,true);retire();retire();h:owner("B")
            h:ready({download_path="/fixture/new",device={sleep_ms=60000}});h:step()
            eq(calls,0);eq(#h.q,0)
            if op=="folder" then eq(h.download_dir,"/fixture/new") else eq(h.e.Library.device_snapshot.sleep_ms,60000) end
        end)
    end
    test("delivery: recommendations remain device scoped after account departure",function()
        local h=harness();local result
        h.e.Library.recommendations({},function(r) result=r end);h:owner("B")
        h:ready({items={{id="fixture"}}});h:step()
        eq(result.items[1].id,"fixture");eq(h.e.LibraryAdapter.recommendations,result);eq(#h.q,0)
    end)
end

-- The native half never simulates policy: responses come from a deliberately neutral port.
return function(test,eq,ok,E,W,UIManager,run,newUI,ReaderUI,FileManager)
    local function world(fn)
        local saved={reader=ReaderUI.instance,fm=FileManager.instance,shown=W.shown,queue=W.queue,
            command=E.Library.positionCommand,cached=E.Library.positionCached,preview=E.Library.positionPreview,
            problem=E.Companion.workerProblem,mode=E.S.sync_mode,schedule=E.S.reading_schedule}
        local x={page=120,commands={},moves={},callbacks={},snapshot={document="toy:one",token="place-one",
            remote={position="/p214",percentage=214/300,at=900,label="fixture reader"},marker={position="/p100",percentage=100/300,at=800}}}
        local doc={file="/fixture/one.epub",info={has_pages=false},getPageCount=function() return 300 end,
            getCurrentPage=function() return x.page end,getPageFromXPointer=function(_,p) return tonumber(p:match("%d+")) end}
        local ui={document=doc,view={footer={percent_finished=.4}},rolling={getLastProgress=function() return "/p"..x.page end},
            doc_settings={readSetting=function() return {status="reading"} end},
            toc={isChapterStart=function(_,p) return p%10==1 end,getPreviousChapter=function(_,p) return p-(p-1)%10 end}}
        function ui:handleEvent(event) table.insert(x.moves,event); if event.name=="GotoXPointer" then x.page=tonumber(event.args[1]:match("%d+")) end end
        x.ui=ui; ReaderUI.instance=ui; FileManager.instance=nil; W.shown={ui}; W.queue={}
        E.Companion.workerProblem=function() return nil end
        E.S.sync_mode="orbismart"; E.S.reading_schedule="off"
        E.ReadingSync.ready=true; E.ReadingSync.running=0; E.ReadingSync.busy=false; E.ReadingSync.prompt=nil
        E.Library.positionCached=function(path) return path==ui.document.file and x.snapshot or nil end
        E.Library.positionPreview=function(args) x.preview_args=args; return x.preview_result end
        E.Library.positionCommand=function(op,args,done)
            table.insert(x.commands,{op=op,args=args})
            local function response()
                if op=="sync.activate" then done({ok=true})
                elseif op=="sync.capture" or op=="sync.override" then done({document="toy:one",snapshot=x.snapshot})
                elseif op=="sync.answer" then done({move=args.yes,remote=x.snapshot.remote,token=args.token})
                else done(x.decision or {decision="take",applied="ask",document="toy:one",token=x.snapshot.token,remote=x.snapshot.remote,remaining=0}) end
            end
            if x.delay then table.insert(x.callbacks,response) else UIManager:nextTick(response) end
            return true
        end
        local success,err=pcall(fn,x)
        E.ReadingSync.closePrompt()
        ReaderUI.instance,FileManager.instance,W.shown,W.queue=saved.reader,saved.fm,saved.shown,saved.queue
        E.Library.positionCommand,E.Library.positionCached,E.Library.positionPreview=saved.command,saved.cached,saved.preview
        E.Companion.workerProblem,E.S.sync_mode,E.S.reading_schedule=saved.problem,saved.mode,saved.schedule
        E.ReadingSync.running=0; E.ReadingSync.busy=false
        ok(success,err)
    end
    test("sync retirement: legacy class and API are disarmed before instance init",function()
        local writes=0
        local function writer() writes=writes+1 end
        local legacy={name="bookorbit",requestProgressPull=writer,enqueueLifecycleSnapshot=writer}
        local api={updateProgress=writer,request=writer}
        local loader={enabled_plugins={legacy},loaded_plugins={},createPluginInstance=function(_,plugin)
            plugin:requestProgressPull(); plugin:enqueueLifecycleSnapshot(); api:updateProgress(); return plugin
        end}
        local env=setmetatable({PluginLoader=loader,package={loaded={bookorbit_api=api}}},{__index=_G})
        local chunk=assert(loadfile(E.SOURCE_DIR.."/ko/server/bookorbit/quiesce.lua")); setfenv(chunk,env); chunk()
        ok(env.SyncRetirement.safe); loader:createPluginInstance(legacy); eq(writes,0)
        loader.loaded_plugins.bookorbit=legacy
        chunk(); eq(env.SyncRetirement.safe,false,"late activation retains source and refuses a second writer")
    end)
    test("startup smoke: last document remains the top reader through a yielding progress pull",function() world(function(x)
        x.delay=true
        E.ReadingSync.run("open")
        eq(#x.commands,1); eq(x.commands[1].op,"sync.capture")
        eq(W.shown[1],x.ui); eq(ReaderUI.instance,x.ui); eq(#x.moves,0)
        x.callbacks[1](); eq(x.commands[2].op,"sync.decide")
        eq(W.shown[1],x.ui,"yielding companion never clears the reader")
        eq(#x.moves,0,"no silent jump after render")
    end) end)
    test("position consent: one popup, Yes uses the companion answer, No never moves",function() world(function(x)
        E.ReadingSync.run("open"); run(1)
        local prompt=E.ReadingSync.prompt; ok(prompt)
        eq(prompt.widget.text,"Continue from fixture reader, p. 214?")
        E.ReadingSync.present({applied="ask",token=x.snapshot.token,document="toy:one",remote=x.snapshot.remote},x.ui)
        eq(E.ReadingSync.prompt,prompt,"same remote place draws only once")
        prompt.widget.cancel_callback(); run(1)
        eq(#x.moves,0); eq(x.commands[#x.commands].op,"sync.answer"); eq(x.commands[#x.commands].args.yes,false)
        E.ReadingSync.present({applied="ask",token="new-place",document="toy:one",remote=x.snapshot.remote},x.ui)
        E.ReadingSync.prompt.widget.ok_callback(); run(1)
        eq(#x.moves,1); eq(x.page,214)
        eq(x.commands[#x.commands].args.yes,true)
    end) end)
    test("position consent: a cancelled or different document rejects late results",function() world(function(x)
        E.ReadingSync.run("open"); run(1)
        x.delay=true; E.ReadingSync.prompt.widget.ok_callback()
        x.ui.document={file="/fixture/other.epub"}
        x.callbacks[1](); eq(#x.moves,0,"accepted old-document result cannot move the new document")
    end) end)
    test("position preview: known forward placement moves before draw; worker owns the decision",function() world(function(x)
        x.preview_result={applied="now",document="toy:one",token=x.snapshot.token,remote=x.snapshot.remote}
        E.ReadingSync.preview(x.ui)
        eq(x.page,214); eq(E.ReadingSync.prompt,nil)
        eq(x.preview_args.remote_page,214); eq(x.preview_args.marker_page,100)
        eq(x.commands[1].op,"sync.answer","marker acknowledgment goes back to the owner")
        eq(x.commands[1].args.yes,true)
    end) end)
    test("position wake: a sleep-deferred move is asked from local state before network work",function() world(function(x)
        x.snapshot.pending=true
        E.ReadingSync.resume(x.ui); run(1)
        eq(x.commands[1].op,"sync.decide"); eq(x.commands[1].args.moment,"wake-local")
        ok(E.ReadingSync.prompt); eq(#x.moves,0)
    end) end)
    test("position decision: replacing the native document rejects delayed consent and verification",function() world(function(x)
        x.delay=true
        E.ReadingSync.run("open"); x.callbacks[1]()
        eq(x.commands[2].op,"sync.decide")
        x.ui.document={file="/fixture/other.epub"}
        x.callbacks[2]()
        eq(E.ReadingSync.prompt,nil); eq(#x.commands,2); eq(#x.moves,0)
    end) end)
    test("position decision: changing mode rejects the old in-flight decision",function() world(function(x)
        x.delay=true
        E.ReadingSync.run("open"); x.callbacks[1]()
        E.S.sync_mode="custom"; E.ReadingSync.modeChanged()
        x.callbacks[2]()
        eq(E.ReadingSync.prompt,nil); eq(#x.commands,2); eq(#x.moves,0)
    end) end)
    test("position capture: a close arriving during another sync is not dropped",function() world(function(x)
        x.delay=true
        E.ReadingSync.run("open"); E.ReadingSync.run("close")
        eq(#x.commands,2); eq(x.commands[1].op,"sync.capture"); eq(x.commands[2].op,"sync.capture")
        eq(x.commands[2].args.moment,"close")
        eq(x.commands[2].args.position,"/p120")
    end) end)
    test("position command: companion restart reactivates before retrying immutable capture",function() world(function(x)
        local command=E.Library.positionCommand
        local attempts=0
        E.Library.positionCommand=function(op,args,done)
            if op=="sync.capture" then
                attempts=attempts+1
                if attempts==1 then table.insert(x.commands,{op=op,args=args}); done({error="writer-active"}); return true end
            end
            return command(op,args,done)
        end
        E.ReadingSync.command("sync.capture",{path="/fixture/one.epub",percentage=.4,online=false},function() end)
        run(1)
        eq(x.commands[1].op,"sync.capture"); eq(x.commands[2].op,"sync.activate"); eq(x.commands[3].op,"sync.capture")
        eq(x.commands[1].args,x.commands[3].args,"same immutable native capture is retried")
    end) end)
    test("position close: native locator is captured before ReaderUI clears the document",function() world(function(x)
        local m=setmetatable({ui=x.ui},{__index=E.OrbitAndroid})
        m:onCloseDocument()
        x.ui.document=nil
        run(1)
        eq(x.commands[1].op,"sync.capture"); eq(x.commands[1].args.position,"/p120")
        eq(x.commands[1].args.online,false); eq(m.closed_file,"/fixture/one.epub")
    end) end)
    test("position verification: one row resolves at most two native locators without moving",function() world(function(x)
        local command=E.Library.positionCommand
        local requested=false
        E.Library.positionCommand=function(op,args,done)
            if op=="sync.verify.next" then
                if not requested then requested=true; done({row={key="fixture",start="/p10",["end"]="/p11"}})
                else done({}) end
                return true
            end
            return command(op,args,done)
        end
        E.ReadingSync.verify(x.ui,"toy:one"); run(1)
        eq(x.commands[1].op,"sync.verify.result"); eq(x.commands[1].args.valid,true); eq(x.commands[1].args.page,10)
        eq(#x.moves,0)
    end) end)
    test("settings: Off reading cadence adds no hidden position-sync pause timer",function() world(function(x)
        local m=setmetatable({ui=x.ui,schedule=E.Schedule.new("off",E.now_s())},{__index=E.OrbitAndroid})
        for page=1,60 do m:onPageUpdate(page) end
        run(121); eq(#x.commands,0)
    end) end)
    test("position sync: no old marker/override/decline table is mutated in the reader",function() world(function(x)
        local old=E.S.orbismart; local before=old and E.Cache.encode(old)
        E.ReadingSync.readFromHere("test"); run(1)
        eq(x.commands[1].op,"sync.override")
        eq(old and E.Cache.encode(old),before)
        local b=E.Budgets.get("screens","position-consent")
        eq(b.rows,1); eq(b.bytes,16384); eq(b.roundTrips,1); eq(b.spawns,0); eq(b.network,0)
    end) end)
end

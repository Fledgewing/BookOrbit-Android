-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Only native locator/geometry captures and consent UI. Policy and durable state are companion-owned.
ReadingSync = { ready=false, busy=false, turn_at=0, generation=0 }
function ReadingSync.on() return S.sync_mode ~= "custom" end
function ReadingSync.closePrompt()
    if ReadingSync.prompt then
        ReadingSync.prompt.answered=true
        UIManager:close(ReadingSync.prompt.widget)
        ReadingSync.prompt=nil
    end
end
function ReadingSync.capture(ui, moment)
    ui=ui or liveUI()
    if not (ui and ui.document) then return {moment=moment,online=NetworkMgr:isConnected()} end
    local doc=ui.document
    local fraction=Library.nativeReaderPosition(doc.file)
    if fraction==nil then
        local engine=doc.info and doc.info.has_pages and ui.paging or ui.rolling
        if engine and engine.getLastPercent then local ok,p=pcall(engine.getLastPercent,engine); if ok then fraction=p end end
    end
    local engine=doc.info and doc.info.has_pages and ui.paging or ui.rolling
    local ok,position=pcall(function() return engine:getLastProgress() end)
    local _,page=pcall(function() return doc:getCurrentPage() end)
    local summary=ui.doc_settings and ui.doc_settings:readSetting("summary") or {}
    if type(summary)~="table" then summary={} end
    return {automatic=ReadingSync.on(),path=doc.file,document=ui.doc_settings and ui.doc_settings:readSetting("partial_md5_checksum"),position=ok and position or nil,percentage=fraction,page=type(page)=="number" and page or nil,
        summary={status=summary.status,rating=summary.rating,modified=summary.modified},
        finished=summary.status=="complete",released=(ReadingSync.forward or 0)>=10,turn_at=ReadingSync.turn_at,
        stats_id=ui.statistics and ui.statistics.id_curr_book,captured_at=os.time(),moment=moment,online=NetworkMgr:isConnected()}
end
function ReadingSync.geometry(snapshot, ui, moment)
    local args=ReadingSync.capture(ui,moment)
    local doc=ui.document
    local ok,n=pcall(doc.getPageCount,doc)
    local pages=ok and tonumber(n) or 100
    local function place(record)
        record=record or {}
        local pos=record.position
        if type(pos)=="string" and pos~="" then
            if doc.info and doc.info.has_pages then local p=tonumber(pos); if p then return p,false end
            else local success,p=pcall(doc.getPageFromXPointer,doc,pos); if success and type(p)=="number" then return p,false end end
        end
        if type(record.percentage)=="number" then return math.floor(record.percentage*pages+0.5),true end
    end
    args.remote_page,args.percent_only=place(snapshot.remote)
    args.marker_page=place(snapshot.marker)
    args.tolerance=args.percent_only and math.max(1,pages*0.02) or 1
    local toc=ui.toc
    local function chapter(page)
        if not (toc and page) then return nil end
        local success,c=pcall(function() return toc:isChapterStart(page) and page or toc:getPreviousChapter(page) end)
        return success and c or nil
    end
    local a,b=chapter(args.remote_page),chapter(args.marker_page)
    args.same_chapter=a~=nil and a==b
    args.document,args.token=snapshot.document,snapshot.token
    return args
end
local function jump(ui,remote)
    local doc=ui.document
    if remote.position and remote.position~="" then
        ui:handleEvent(Event:new(doc.info and doc.info.has_pages and "GotoPage" or "GotoXPointer",
            doc.info and doc.info.has_pages and tonumber(remote.position) or remote.position))
    elseif type(remote.percentage)=="number" then
        ui:handleEvent(Event:new("GotoPercent",remote.percentage*100))
    end
end
function ReadingSync.present(result,ui)
    if not result or result.stale or not (ui and ui.document) or liveUI()~=ui then return end
    if result.applied~="ask" then return end
    local remote=result.remote or {}
    if ReadingSync.prompt and ReadingSync.prompt.token==result.token then return end
    ReadingSync.closePrompt()
    local span=Budgets.span("position-consent.paint",now_s,log)
    local entry={token=result.token,ui=ui,document=ui.document}
    local function answer(yes)
        if entry.answered then return end
        entry.answered=true
        if ReadingSync.prompt==entry then ReadingSync.prompt=nil end
        ReadingSync.command("sync.answer",{document=result.document,token=result.token,yes=yes},function(reply)
            if yes and reply.move and not reply.stale and liveUI()==ui and ui.document==entry.document then jump(ui,reply.remote or {}) end
        end)
    end
    local args=ReadingSync.geometry({remote=remote},ui,"reading")
    local label=type(remote.label)=="string" and remote.label or _("another reader")
    entry.widget=ConfirmBox:new{text=string.format(_("Continue from %s, p. %s?"),label,tostring(args.remote_page or "?")),
        ok_text=_("Yes"),cancel_text=_("No"),ok_callback=function() answer(true) end,cancel_callback=function() answer(false) end}
    ReadingSync.prompt=entry
    UIManager:show(entry.widget) -- gate: BookSync position sync's one-draw consent, maintainer exception
    span()
end
function ReadingSync.activate(done)
    if Companion.workerProblem() or not (SyncRetirement and SyncRetirement.safe) then if done then done(false) end; return false end
    local ui=liveUI()
    Library.positionCommand("sync.activate",{quiesced=true,epoch=tostring(Db.pid()),path=ui and ui.document and ui.document.file},function(result)
        ReadingSync.ready=not result.error
        if done then done(ReadingSync.ready) end
    end)
    return true
end
-- A companion process restart loses only the activation handshake, never its journal.
function ReadingSync.command(op,args,done)
    done=done or function() end
    return Library.positionCommand(op,args,function(result)
        if result.error=="writer-active" then
            ReadingSync.ready=false
            return ReadingSync.activate(function(ok)
                if ok then Library.positionCommand(op,args,done) else done({error="unavailable"}) end
            end)
        end
        done(result)
    end)
end
function ReadingSync.run(moment,done,override)
    done=done or function() end
    local ui=liveUI()
    local args=ReadingSync.capture(ui,moment)
    local native=ui and ui.document
    local function run()
        ReadingSync.running=(ReadingSync.running or 0)+1
        ReadingSync.busy=true
        local finished=false
        local function finish(ok,why) if finished then return end; finished=true; ReadingSync.running=math.max(0,(ReadingSync.running or 1)-1); ReadingSync.busy=ReadingSync.running>0; done(ok,why) end
        UIManager:scheduleIn(S.sleep_cap or 20,function() finish(false,"Saved · delivery still pending") end)
        if not args.path then
            return ReadingSync.command("sync.drain",{},function(r) finish(not r.error and (r.remaining or 0)==0,r.error) end)
        end
        ReadingSync.command(override and "sync.override" or "sync.capture",args,function(r)
            if r.error then return finish(false,r.error) end
            if not args.online then return finish(false,"Offline · saved on this device") end
            if not r.snapshot then return finish(false,"Saved · awaiting remote place") end
            r.snapshot.document=r.document
            -- The worker sees geometry only while it still belongs to this native document.
            if liveUI()~=ui or ui.document~=native or not ui.document or ui.document.file~=args.path then
                return ReadingSync.command("sync.drain",{},function(d) finish(not d.error and (d.remaining or 0)==0,d.error) end)
            end
            local mapped=ReadingSync.geometry(r.snapshot,ui,moment)
            ReadingSync.command("sync.decide",mapped,function(d)
                local current=liveUI()==ui and ui.document==native and args.automatic==ReadingSync.on()
                if current and moment~="close" and moment~="sleep" then ReadingSync.present(d,ui) end
                if current and moment~="sleep" and moment~="close" then ReadingSync.verify(ui,r.document) end
                finish(not d.error and (d.remaining or 0)==0,d.error)
            end)
        end)
    end
    if ReadingSync.ready then run() else ReadingSync.activate(function(ok) if ok then run() else done(false,"Companion sync unavailable") end end) end
end
function ReadingSync.readFromHere(why) return ReadingSync.run("manual",nil,true) end
function ReadingSync.preview(ui)
    if not (SyncRetirement and SyncRetirement.safe) or not (ui and ui.document) then return end
    local snapshot=Library.positionCached(ui.document.file)
    if not snapshot or not snapshot.remote then return end
    local args=ReadingSync.geometry(snapshot,ui,"prerender")
    local result=Library.positionPreview(args)
    if result and result.applied=="now" and result.remote and liveUI()==ui then
        jump(ui,result.remote)
        ReadingSync.command("sync.answer",{document=result.document,token=result.token,yes=true},function() end)
    end
end
function ReadingSync.modeChanged() ReadingSync.closePrompt() end

function ReadingSync.queue(moment,ui)
    local args=ReadingSync.capture(ui,moment)
    if not args.path then return end
    args.online=false
    local annotations=ui and ui.annotation and ui.annotation.annotations
    local signature=table.concat({args.path,tostring(args.position),tostring(args.percentage),tostring(ReadingSync.last_page),tostring(annotations and #annotations or 0),tostring(args.summary and args.summary.status)},"|")
    if moment=="suspend" and Jni.isInteractive()==true and signature==ReadingSync.last_snapshot then return end
    ReadingSync.last_snapshot=signature
    local function enqueue()
        ReadingSync.command("sync.capture",args,function(r) if r.error=="writer-active" then ReadingSync.ready=false end end)
    end
    if ReadingSync.ready then enqueue() else ReadingSync.activate(function(ok) if ok then enqueue() end end) end
end

function ReadingSync.resume(ui)
    if not ReadingSync.on() or not (ui and ui.document) then return end
    local snapshot=Library.positionCached(ui.document.file)
    if not (snapshot and snapshot.pending and snapshot.remote) then return end
    local function decide()
        ReadingSync.command("sync.decide",ReadingSync.geometry(snapshot,ui,"wake-local"),function(result) ReadingSync.present(result,ui) end)
    end
    if ReadingSync.ready then decide() else ReadingSync.activate(function(ok) if ok then decide() end end) end
end

-- One bounded native locator-verification capture per callback. The companion stores the
-- work and performs acknowledgments; no sidecar, server JSON or annotation scan enters Lua.
function ReadingSync.verify(ui,document,left)
    left=left or 8
    if left<=0 or liveUI()~=ui or not ui.document then return end
    local native=ui.document
    ReadingSync.command("sync.verify.next",{document=document,path=native.file},function(result)
        if liveUI()~=ui or ui.document~=native or not result.row then return end
        local row=result.row
        local finish=Budgets.span("position-verification.capture",now_s,log)
        local budget=Budgets.get("screens","position-verification")
        local bytes=#Cache.encode(row)
        assert(Budgets.check(budget,{rows=1,bytes=bytes,spawns=0,network=0,roundTrips=0,snapshotBytes=bytes}))
        local function page(position)
            if type(position)~="string" or #position>4096 then return nil end
            if native.info and native.info.has_pages then return tonumber(position) end
            local success,p=pcall(native.getPageFromXPointer,native,position)
            return success and type(p)=="number" and p>0 and p or nil
        end
        local a,b=page(row.start),page(row["end"])
        finish()
        ReadingSync.command("sync.verify.result",{document=document,path=native.file,key=row.key,valid=a~=nil and b~=nil and b>=a,page=a},function()
            UIManager:scheduleIn(0.2,function() if ui.document==native then ReadingSync.verify(ui,document,left-1) end end)
        end)
    end)
end

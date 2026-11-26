-- SPDX-License-Identifier: AGPL-3.0-or-later
return function(t)
local E,W,test,eq,ok=t.E,t.W,t.test,t.eq,t.ok
local function isolated(fn)
    local action,native,position,reading=E.Library.catalogAction,E.Library.nativeReader,E.Library.syncCurrent,E.reading
    E.Library.syncCurrent=function(done) done(true) end
    local oldsheet=E.FinishUI.sheet
    E.FinishUI.sheet=nil
    local success,why=pcall(fn)
    E.FinishUI.closeSheet();E.FinishUI.sheet=oldsheet
    E.Library.catalogAction,E.Library.nativeReader,E.Library.syncCurrent,E.reading=action,native,position,reading
    if not success then error(why) end
end
local function fixture()
    local ui,m=t.newUI(true)
    ui.doc_settings={readSetting=function(self,k) return self[k] end,saveSetting=function(self,k,v) self[k]=v end}
    local b={digest=string.rep("a",32),file="/books/synthetic.epub",key=true,summary={},doc_settings=ui.doc_settings}
    E.Library.nativeReader=function() return b end
    return ui,m,b
end
test("catalog actions: mark, rate, undo and leave dispatch neutral commands",function() isolated(function()
    local ui,m,b=fixture();local calls={}
    E.Library.catalogAction=function(op,args,done) calls[#calls+1]={op,args};if done then done({ok=true}) end end
    b.summary.status="complete";E.FinishUI.onMarked(ui)
    eq(calls[1][1],"finish.mark");eq(calls[1][2].complete,true);eq(calls[1][2].path,b.file)
    ok(calls[1][2].server==nil and calls[1][2].userkey==nil)
    E.FinishUI.actions.star(ui,b,4);eq(calls[2][1],"finish.rate");eq(calls[2][2].rating,4)
    E.FinishUI.actions.star(ui,b,4);eq(calls[3][2].rating,nil)
    E.FinishUI.onLeave(ui);eq(calls[4][1],"finish.leave")
    b.summary.status="reading";E.FinishUI.onMarked(ui);eq(calls[5][2].complete,false)
end) end)
test("catalog actions: finish snapshot paint is bounded and contains no catalog algorithms",function() isolated(function()
    local ui,m,b=fixture();local adapter=E.LibraryAdapter;local requests={}
    E.LibraryAdapter={read=function(raw)
        local args=E.Cache.decode(raw);eq(args.op,"reader.finish");eq(args.limit,3)
        return {title="Synthetic",status="Saved",row_count=3,next={book_id="opaque-next"},suggestion={book_id="opaque-suggestion"}},300
    end,request=function(batch) requests[#requests+1]=batch;return true end}
    local success,why=pcall(function()
        local model=E.FinishUI.model(b);eq(model.title,"Synthetic");eq(#requests,1);eq(#requests[1],1)
    end)
    E.LibraryAdapter=adapter;if not success then error(why) end
end) end)
test("catalog actions: queued copies dispatch once outside reading with open path protection",function() isolated(function()
    local ui,m,b=fixture();local calls={};local enabled=E.S.keep_copies_current
    E.S.keep_copies_current=true;E.Library.copies_at=nil;E.Library.copies_pending=nil
    E.Library.catalogAction=function(op,args,done) calls[#calls+1]={op,args};done({ok=true});return true end
    E.reading=function() return true end;E.Library.copiesTick("full refresh");eq(#calls,0)
    E.reading=function() return false end;E.Library.copiesTick("full refresh");eq(#calls,1)
    eq(calls[1][1],"copies.check");eq(calls[1][2].open_path,ui.document.file)
    E.Library.copiesTick("background");eq(#calls,1)
    E.S.keep_copies_current=false;E.Library.copiesTick("full refresh");eq(#calls,1)
    E.S.keep_copies_current=enabled
end) end)
test("catalog actions: page turns release stale-push hold without any library read",function() isolated(function()
    local ui,m,b=fixture()
    E.FinishUI.jobs[b.digest]={final_pos={percentage=1}}
    E.FinishUI.session[b.digest]={forward=0}
    E.FinishUI.page_digests[ui]={file=ui.document.file,digest=b.digest}
    E.Library.catalogAction=function() error("page turn dispatched") end
    ok(E.FinishUI.hold(b.digest,.5,"complete"))
    for page=1,11 do E.FinishUI.onPage(ui,page) end
    ok(not E.FinishUI.hold(b.digest,.5,"complete"))
    E.FinishUI.session[b.digest].released=true
    ok(not E.FinishUI.hold(b.digest,.1,"complete"))
end) end)
test("catalog actions: failed or departed download never reopens a book",function() isolated(function()
    local ui,m,b=fixture();local pending;local opened=0;local open=E.Library.open
    E.Library.open=function() opened=opened+1 end
    E.Library.catalogAction=function(op,args,done) pending=done;return true end
    local sheet={ui=ui,book=b,update=function() end};E.FinishUI.sheet=sheet
    E.FinishUI.actions.book(ui,b,"opaque","Synthetic")
    E.FinishUI.sheet=nil;pending({local_path="/books/next.epub"});eq(opened,0)
    E.Library.open=open
end) end)
test("catalog actions: finish leaves and drains the existing writer before a remote download",function() isolated(function()
    local ui,m,b=fixture();local order={}
    E.Library.catalogAction=function(op,args,done) order[#order+1]=op;if done then done({error="offline"}) end end
    E.Library.syncCurrent=function(done) order[#order+1]="existing-writer";done(true) end
    E.FinishUI.sheet={ui=ui,book=b,update=function() end}
    E.FinishUI.actions.book(ui,b,"opaque","Synthetic")
    eq(order[1],"finish.leave");eq(order[2],"existing-writer");eq(order[3],"finish.download")
end) end)
test("catalog actions: a saved next book opens offline without a network command",function() isolated(function()
    local ui,m,b=fixture();local opened;local open=E.Library.open
    E.Library.open=function(row) opened=row.local_path;return true end
    E.Library.syncCurrent=function() error("local book requested sync") end
    E.Library.catalogAction=function(op) eq(op,"finish.leave") end
    E.FinishUI.actions.book(ui,b,"opaque","Synthetic","/books/local.epub")
    eq(opened,"/books/local.epub");E.Library.open=open
end) end)
test("catalog actions: native grouping opens an owned scoped projection without reading the list",function()
    local old=package.loaded.bookorbit_catalog;local open=E.Library.openGrouped
    local cat={listKind=function() return "books" end,listSortSheetModel=function() return {rows={}} end,listRun=function() error("unexpected native list action") end}
    package.loaded.bookorbit_catalog=cat
    local called
    E.Library.openGrouped=function(title,source,query) called={title,source,query} end
    local success,why=pcall(function()
        ok(E.Server.installGroupViews())
        local instance=setmetatable({current_context={title="Synthetic list",params={smartScopeId=9,ids="2,4"}}},{__index=cat})
        local model=instance:listSortSheetModel();eq(#model.rows,2)
        instance:listRun(model.rows[1].action)
        eq(called[2].kind,"selection");eq(called[2].selection.list,"9");eq(called[2].selection.ids,"2,4");eq(called[3].group,"series")
    end)
    package.loaded.bookorbit_catalog=old;E.Library.openGrouped=open
    if not success then error(why) end
end)
test("catalog actions: end sheet uses only the library action dispatcher",function() isolated(function()
    local ui,m,b=fixture();local endAction=E.Library.endAction;local calls={}
    E.Library.endAction=function(name) calls[#calls+1]=name end
    local sheet=E.EndSheet:new{ui=ui,book=b,model={title="Synthetic",status="Saved",can_mark=true}}
    for _,row in ipairs(sheet:rows()) do if row.kind=="status" then row.action() end end
    eq(calls[1],"mark");sheet:onClose();eq(calls[2],"back")
    E.Library.endAction=endAction
end) end)
test("catalog actions: every added screen and widget has strict deterministic budgets",function()
    for _,id in ipairs({"end-of-book","settings-recommendations","copies-state"}) do
        local b=E.Budgets.get("screens",id);eq(b.network,0);eq(b.spawns,0);ok(b.roundTrips<=1);ok(b.snapshotBytes<=16384)
        ok(not E.Budgets.check(b,{rows=b.rows+1,bytes=0,spawns=0,roundTrips=0,network=0,snapshotBytes=0}))
    end
    for _,id in ipairs({"end-of-book","recommendations"}) do E.Budgets.get("widgets",id) end
end)
end

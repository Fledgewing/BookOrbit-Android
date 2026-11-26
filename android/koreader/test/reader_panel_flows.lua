-- SPDX-License-Identifier: AGPL-3.0-or-later
return function(here, test, ok, eq)
    local function world()
        local W = {shown={}, logs={}, trips=0, syncs=0, reads={}}
        local function class(base)
            local c=setmetatable({}, {__index=base})
            c.__index=c
            function c:extend(t) return setmetatable(t or {}, {__index=self, __call=self.new}) end
            function c:new(t) t=setmetatable(t or {}, {__index=self}); if t.init then t:init() end; return t end
            return c
        end
        local Widget=class()
        local ui={document={file="/books/fixture.epub"},menu={}}
        local Menu={onShowMenu=function() W.stock=(W.stock or 0)+1; return "native" end}
        ui.menu=setmetatable({ui=ui},{__index=Menu})
        W.book={items={{key="opaque",title="The Moon",authors={"A"},progress=62,
            stats={days_start_to_finish=3,reading_seconds=3660,pages_read=120}}}}
        W.caps={progress={syncCurrent=true}}
        W.battery={hours_usual_use=54}
        local E=setmetatable({now_s=function() return 1 end, log=function(s) W.logs[#W.logs+1]=s end,
            state={}, OrbitAndroid={menuItems=function() return {} end,onCloseWidget=function() end},
            LibraryAdapter={readerPosition=function() return W.native end,read=function(request)
                local a=W.E.Cache.decode(request); W.reads[#W.reads+1]=a.op
                if a.op=="reader" then W.native_input=a.native_progress end
                if W.oversize then return {items={{},{}}},100 end
                if W.missing then return nil end
                return a.op=="capabilities" and W.caps or a.op=="battery" and W.battery or W.book,256
            end,request=function(batch) W.trips=W.trips+1; W.batch=batch; return true end,
                syncCurrent=function(done) W.syncs=W.syncs+1; W.done=done; return true end}}, {__index=_G})
        W.E=E
        E.UIManager={scheduleIn=function(_,_,fn) W.poll=fn end, show=function(_,s) W.shown[#W.shown+1]=s; W.top=s end,
            close=function(_,s) if W.top==s then W.top=nil end end,
            setDirty=function() W.dirty=(W.dirty or 0)+1 end,
            getTopmostVisibleWidget=function() return W.top end}
        E.wrap=function(t,k,f) t[k]=f(t[k]) end
        E.require=function(name)
            if name=="device" then return {screen={getWidth=function() return 600 end,getHeight=function() return 800 end,scaleBySize=function(_,n) return n end}} end
            if name=="apps/reader/modules/readermenu" then return Menu end
            if name=="ui/geometry" or name=="ui/gesturerange" then return {new=function(_,t) return t end} end
            if name=="ui/font" then return {getFace=function() return {} end} end
            if name=="ffi/blitbuffer" then return {COLOR_BLACK=0,COLOR_WHITE=1,COLOR_LIGHT_GRAY=2} end
            if name:match("^ui/widget/") then return Widget end
            return require(name)
        end
        local function load(name) local fn=assert(loadfile(here.."/../orbit.koplugin/"..name)); setfenv(fn,E); fn() end
        for _,name in ipairs({"logic/cache.lua","logic/budgets.lua","logic/sheet_layout.lua","logic/reader_panel.lua","ko/library.lua","ko/endsheet.lua","ko/reader_panel.lua"}) do load(name) end
        W.ui=ui
        return W,E
    end
    local function row(E,text)
        for _,r in ipairs(E.ReaderPanel.sheet:rows()) do if r.text==text then return r end end
        error("missing reader row "..text)
    end
    test("reader panel: bounded cached data, plain bar and one companion batch",function()
        local W,E=world()
        W.native=0.73
        eq(W.ui.menu:onShowMenu(),true)
        eq(W.native_input,0.73,"cached native position goes through the library request")
        eq(W.trips,1); eq(#W.batch,3); eq(W.syncs,0)
        eq(table.concat(W.reads,","),"reader,battery,capabilities")
        ok(row(E,"≈ 2 d 6 h left at your usual use"))
        eq(E.ReaderPanel.sheet.metrics.button,50)
        local bars=0
        for _,r in ipairs(E.ReaderPanel.sheet:rows()) do
            if r.kind=="progress" then bars=bars+1; eq(r.value,0.62) end
        end
        eq(bars,1)
        local sheet=E.ReaderPanel.sheet
        local bar=sheet:rowWidget({kind="progress",row={value=0.62}},500,26,sheet.metrics)
        eq(bar.percentage,0.62); eq(#bar.ticks,0); eq(bar.bordersize,0); eq(bar.radius,0)
        eq(bar.margin_h,0); eq(bar.margin_v,0)
        ok(#W.logs>=5,"call, paint and draw timing spans")
        row(E,"Book info").action()
        ok(row(E,"3 days start to finish")); ok(row(E,"61 min reading time")); ok(row(E,"120 pages read"))
        row(E,"Details").action(); eq(E.ReaderPanel.sheet.screen,"details"); eq(W.reads[#W.reads-1],"reader","in-book Details keeps the native reader context")
        row(E,"Back to book").action(); eq(E.ReaderPanel.sheet,nil); eq(W.ui.document.file,"/books/fixture.epub")
    end)
    test("reader panel: capabilities, missing data and asynchronous Sync never reopen a dismissed panel",function()
        local W,E=world(); W.caps={}; W.battery={}
        E.ReaderPanel.show(W.ui,"reader-top-panel")
        for _,r in ipairs(E.ReaderPanel.sheet:rows()) do ok(r.text~="Sync") end
        ok(row(E,"Battery estimate not available yet"))
        W.caps={progress={syncCurrent=true}}
        E.ReaderPanel.show(W.ui,"reader-top-panel")
        local sync=row(E,"Sync"); sync.action()
        ok(W.logs[#W.logs]:find("library.progress.sync",1,true),"explicit Sync dispatch has a timing span")
        sync.action(); eq(W.syncs,1)
        eq(sync.text,"Syncing…")
        W.done(false,"Offline · will sync when connected")
        eq(sync.text,"Offline · will sync when connected")
        sync.action(); eq(W.syncs,2)
        E.ReaderPanel.close(); local shown=#W.shown; local dirty=W.dirty
        W.done(true,"Synced"); eq(#W.shown,shown); eq(W.dirty,dirty)
        W.missing=true; E.ReaderPanel.show(W.ui,"book-info")
        ok(row(E,"Progress not saved yet")); ok(row(E,"Reading time: not saved yet"))
        eq(E.ReaderPanel.sheet.model.progress,nil)
        local poll=W.poll; E.ReaderPanel.close(); shown=#W.shown
        poll(); eq(#W.shown,shown,"cold completion never reopens the book overlay")
        E.ReaderPanel.show(W.ui,"book-info"); local sheet=E.ReaderPanel.sheet
        W.missing=false; W.poll(); eq(E.ReaderPanel.sheet,sheet)
        ok(row(E,"61 min reading time"),"cold projection updates the existing user-opened surface")
    end)
    test("reader panel: native escape, close lifecycle and enforced surface/widget budgets",function()
        local W,E=world()
        eq(W.ui.menu:onShowMenu(nil,true),"native")
        E.ReaderPanel.show(W.ui,"reader-top-panel")
        row(E,"KOReader menu").action(); eq(W.stock,2); eq(E.ReaderPanel.sheet,nil)
        E.ReaderPanel.show(W.ui,"reader-top-panel"); E.OrbitAndroid:onCloseWidget(); eq(E.ReaderPanel.sheet,nil)
        for _,s in ipairs({"reader-top-panel","book-info","details"}) do
            local b=E.Budgets.get("screens",s); eq(b.rows,3); eq(b.spawns,0); eq(b.network,0); eq(b.roundTrips,1)
        end
        eq(E.Budgets.get("widgets","reader-progress").snapshotBytes,16384)
        W.oversize=true
        eq(pcall(E.ReaderPanel.show,W.ui,"reader-top-panel"),false)
        local m=E.ReaderPanelPlan.model({items={{progress=200}}},{}); eq(m.progress,1)
        eq(E.ReaderPanelPlan.model({items={{progress=0/0}}},{}).progress,nil)
    end)
    test("reader Sync adapter: existing writer, offline, document change and late timeout",function()
        local ui={document={file="fixture.epub"},view={footer={percent_finished=0.73}}}
        local up, reply, timeout, done, message, sent, released
        sent,released=0,0
        local E={liveUI=function() return ui end, bookorbit=function() return {} end,
            hasHandler=function() return true end,
            Wifi={acquire=function() end,release=function() released=released+1 end},
            Net={up=function(_,_,cb) up=cb end},
            UIManager={scheduleIn=function(_,_,cb) timeout=cb end},
            pluginEvent=function(_,_,event,options)
                eq(event,"BookOrbitSyncBook"); eq(options.quiet,true)
                sent=sent+1; reply=options.on_done
            end}
        setfenv(assert(loadfile(here.."/../orbit.koplugin/ko/library_bookorbit.lua")),setmetatable(E,{__index=_G}))()
        eq(E.LibraryAdapter.readerPosition("fixture.epub"),0.73)
        eq(E.LibraryAdapter.readerPosition("other.epub"),nil)
        ui.view.footer.percent_finished=0/0
        eq(E.LibraryAdapter.readerPosition("fixture.epub"),nil)
        ui.view.footer.percent_finished=0
        eq(E.LibraryAdapter.readerPosition("fixture.epub"),0)
        local function complete(ok,text) done,message=ok,text end
        E.LibraryAdapter.syncCurrent(complete); up(false)
        eq(sent,0); eq(released,1); eq(done,false); eq(message,"Offline · will sync when connected")
        E.LibraryAdapter.syncCurrent(complete); ui.document={file="other.epub"}; up(true)
        eq(sent,0); eq(released,2); eq(done,false)
        E.LibraryAdapter.syncCurrent(complete); up(true)
        eq(sent,1); reply(nil); eq(done,true); eq(message,"Synced"); eq(released,3)
        timeout(); eq(released,3,"late timer cannot complete twice")
        E.LibraryAdapter.syncCurrent(complete); up(true); timeout()
        eq(done,false); eq(released,4); reply(nil); eq(released,4)
    end)

end

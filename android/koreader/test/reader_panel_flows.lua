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
        W.face={hash="fixture",ftsize={getEmboldenHalfStrength=function(_,factor) return factor end}}
        local ui={document={file="/books/fixture.epub"},menu={}}
        local Menu={onShowMenu=function() W.stock=(W.stock or 0)+1; return "native" end}
        ui.menu=setmetatable({ui=ui},{__index=Menu})
        W.book={items={{key="opaque",title="The Moon",authors={"A"},progress=62,
            stats={days_start_to_finish=3,reading_seconds=3660,pages_read=120}}}}
        W.caps={progress={syncCurrent=true}}
        W.battery={hours_usual_use=54}
        local E=setmetatable({now_s=function() return 1 end, log=function(s) W.logs[#W.logs+1]=s end,
            S={}, G_reader_settings={readSetting=function() return nil end}, saveSettings=function() end,
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
            close=function(_,s)
                for i=#W.shown,1,-1 do if W.shown[i]==s then table.remove(W.shown,i); break end end
                W.top=W.shown[#W.shown]
            end,
            setDirty=function() W.dirty=(W.dirty or 0)+1 end,
            getTopmostVisibleWidget=function() return W.top end}
        E.wrap=function(t,k,f) t[k]=f(t[k]) end
        E.require=function(name)
            if name=="device" then return {screen={getWidth=function() return 600 end,getHeight=function() return 800 end,scaleBySize=function(_,n) return math.ceil(n*(W.scale or 1)) end}} end
            if name=="document/credocument" then return {engineInit=function() return {getFontFaceFilenameAndFaceIndex=function(face) return face .. ".ttf",0 end} end} end
            if name=="ui/event" then return {new=function(_,name) return {name=name} end} end
            if name=="apps/reader/modules/readermenu" then return Menu end
            if name=="ui/geometry" or name=="ui/gesturerange" then return {new=function(_,t) return t end} end
            if name=="ui/font" then return {getFace=function() return W.face end} end
            if name=="ffi/blitbuffer" then return {COLOR_BLACK=0,COLOR_WHITE=1,COLOR_LIGHT_GRAY=2,Color8=function(n) return n end} end
            if name:match("^ui/widget/") then return Widget end
            return require(name)
        end
        local function load(name) local fn=assert(loadfile(here.."/../orbit.koplugin/"..name)); setfenv(fn,E); fn() end
        for _,name in ipairs({"logic/cache.lua","logic/budgets.lua","logic/reading_style.lua","logic/settings_ui.lua","logic/sheet_layout.lua","logic/reader_panel.lua","ko/library.lua","ko/endsheet.lua","ko/reading_style.lua","ko/custom_reading.lua","ko/reader_panel.lua"}) do load(name) end
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
        E.ReaderPanel.details("opaque"); eq(W.reads[#W.reads-1],"book")
        row(E,"Back").action(); eq(E.ReaderPanel.sheet,nil)
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
            local b=E.Budgets.get("screens",s); eq(b.rows,3); eq(b.bytes,3*16384); eq(b.spawns,0); eq(b.network,0); eq(b.roundTrips,1)
        end
        eq(E.Budgets.get("widgets","reader-progress").snapshotBytes,16384)
        W.oversize=true
        eq(pcall(E.ReaderPanel.show,W.ui,"reader-top-panel"),false)
        local m=E.ReaderPanelPlan.model({items={{progress=200}}},{}); eq(m.progress,1)
        eq(E.ReaderPanelPlan.model({items={{progress=0/0}}},{}).progress,nil)
    end)
    test("reader Sync adapter: explicit sync uses the companion owner",function()
        local ui={document={file="fixture.epub"},view={footer={percent_finished=0.73}}}
        local called,reply,done,message
        local E={liveUI=function() return ui end,ReadingSync={run=function(moment,callback) called=moment; reply=callback; return true end}}
        setfenv(assert(loadfile(here.."/../orbit.koplugin/ko/server/bookorbit/library_bookorbit.lua")),setmetatable(E,{__index=_G}))()
        eq(E.LibraryAdapter.readerPosition("fixture.epub"),0.73)
        eq(E.LibraryAdapter.readerPosition("other.epub"),nil)
        ui.view.footer.percent_finished=0/0; eq(E.LibraryAdapter.readerPosition("fixture.epub"),nil)
        E.LibraryAdapter.syncCurrent(function(ok,text) done,message=ok,text end)
        eq(called,"manual"); reply(false,"Offline · saved"); eq(done,false); eq(message,"Offline · saved")
        E.LibraryAdapter.syncCurrent(function(ok,text) done,message=ok,text end)
        reply(true); eq(done,true); eq(message,"Synced")
    end)

    local function styleReader(W)
        local ui=W.ui
        ui.rolling={}; ui.font={font_face="Fixture Serif",configurable={font_base_weight=0,line_spacing=130,font_gamma=18}}
        ui.typeset={configurable={},unscaled_margins={40,20,40,30},onSetPageMargins=function(_,m) W.margins=m end}
        ui.doc_settings={readSetting=function() end,saveSetting=function(_,k,v) W.saved=W.saved or {}; W.saved[k]=v end}
        ui.handleEvent=function(_,event) W.event=event; W.events=(W.events or 0)+1 end
        for _,method in ipairs({"setFontFace","setFontBaseWeight","setEmbeddedFonts","setInterlineSpacePercent","setGammaIndex"}) do
            ui.document[method]=function(_,v) W[method]=v end
        end
        ui.document.default_font="Book Face"
        return ui
    end
    test("Custom panel: every Custom choice applies first, edits second and returns with panel open",function()
        local W,E=world(); local ui=styleReader(W)
        E.ReaderPanel.show(ui,"reader-top-panel")
        for _,key in ipairs(E.ReadingStyle.keys) do
            local function cell()
                for _,r in ipairs(E.ReaderPanel.sheet:rows()) do
                    if r.choices and r.choices[3].text:find(E.ReadingStyle.names[key] .. "\n",1,true) then return r.choices[3] end
                end
            end
            local old=E.ReaderPanel.sheet
            cell().callback(); eq(E.CustomReading.editor,nil); eq(E.Library.readingChoices(ui)[key],"custom")
            eq(E.ReaderPanel.sheet,old); ok(cell().text:find("✎",1,true))
            cell().callback(); local editor=E.CustomReading.editor; eq(editor.key,key); eq(editor.focus_action,"+")
            local b=E.Budgets.get("screens","reading-custom-"..key); eq(b.bytes,0); eq(b.roundTrips,0)
            local before=E.Library.readingCustom(); editor:onSelect()
            local field=key=="font" and "weight" or key
            ok(E.Library.readingCustom()[field]>before[field]); eq(E.ReaderPanel.sheet,old)
            editor:onClose(); eq(E.CustomReading.editor,nil); eq(E.ReaderPanel.sheet,old); eq(W.top,old)
        end
        eq(W.setInterlineSpacePercent,144,"selected Custom spacing updates the engine")
        ok(W.setFontFace); ok(W.setGammaIndex); ok(W.margins)
    end)
    test("Custom Settings: each row returns to its originating menu; font radio and one-time copy Undo",function()
        local W,E=world(); local ui=styleReader(W)
        local rows=E.CustomReading.settingsRows(ui)
        eq(#rows,9)
        local updates=0; local menu={updateItems=function() updates=updates+1 end}
        for i,key in ipairs(E.ReadingStyle.keys) do
            local r=rows[i*2]; ok(r.text_func():find("Custom " .. E.ReadingStyle.names[key]:lower(),1,true))
            r.callback(menu); local editor=E.CustomReading.editor; eq(editor.key,key)
            for _,er in ipairs(editor:rows()) do
                if er.fontIndex==4 then er.action(); eq(E.Library.readingCustom().fontIndex,4) end
                if er.text=="Done" then er.action() end
            end
            eq(E.CustomReading.editor,nil); eq(updates,i)
        end
        local previous=E.Library.readingCustom()
        rows[9].callback(); local toast=W.top
        eq(toast.title,"Copied once from KOReader into Custom")
        eq(E.Library.readingCustom().face,"Fixture Serif"); eq(E.Library.readingCustom().margins,40)
        ui.font.configurable.line_spacing=180; eq(E.Library.readingCustom().spacing,1.3,"copy never follows native edits")
        toast.buttons[1][1].callback()
        for k,v in pairs(previous) do eq(E.Library.readingCustom()[k],v,"Undo " .. k) end
        local all={}; for _,r in ipairs(rows) do all[#all+1]=r.text or r.text_func() end
        ok(not table.concat(all):find("From KOReader",1,true))
    end)
    test("Custom native adapter: preserves vertical margins, permits book fonts, isolates PDF and closed reader",function()
        local W,E=world(); local ui=styleReader(W)
        E.Library.readingApply(ui,"margins","custom"); eq(W.margins[1],46); eq(W.margins[2],20); eq(W.margins[4],30)
        E.Library.readingApply(ui,"font",1); eq(W.setFontFace,"Book Face"); eq(W.setEmbeddedFonts,1)
        E.Library.readingApply(ui,"font","custom"); eq(W.setEmbeddedFonts,0); eq(W.setFontBaseWeight,1)
        E.Library.readingApply(ui,"contrast","custom"); eq(W.setGammaIndex,20)
        ui.rolling=nil; eq(E.Library.readingApply(ui,"font","custom"),false)
        eq(#E.CustomReading.panelRows(ui,function() end),0)
        E.Library.readingSave({margins=80}); eq(E.Library.readingCustom().margins,80)
        ok(#W.logs>0)
    end)

    test("Custom styles: physical margins, changed-only apply, reopen and close lifecycle",function()
        local W,E=world(); local ui=styleReader(W); W.scale=2
        E.Library.readingApply(ui,"margins","custom"); eq(W.margins[1],23); eq(W.margins[3],23)
        E.Library.readingApply(ui,"spacing","custom")
        W.setInterlineSpacePercent=nil
        local s=E.Library.readingCustom(); s.contrast=.3
        E.Library.readingSave(s,ui,"reading-custom-contrast")
        eq(W.setInterlineSpacePercent,nil,"an unselected edit does not reapply selected styles")
        s.spacing=1.6; E.Library.readingSave(s,nil)
        eq(W.setInterlineSpacePercent,nil,"closed-book edit only saves the record")
        E.Library.readingRestore(ui); eq(W.setInterlineSpacePercent,160)
        E.ReaderPanel.show(ui,"reader-top-panel")
        E.CustomReading.open("spacing",ui,function() error("closed reader must not reopen a panel") end)
        E.OrbitAndroid:onCloseWidget(); eq(E.CustomReading.editor,nil); eq(E.ReaderPanel.sheet,nil)
        eq(pcall(E.Library.readingCustom,"missing-screen"),false)
        E.Budgets.screens["reading-custom-spacing"].rows=0
        eq(pcall(E.Library.readingCustom,"reading-custom-spacing"),false)
    end)

    test("Custom previews: distinct weight/contrast steps and bounded page-scale gutters",function()
        local W,E=world()
        local function preview(key,value)
            local s=E.Library.readingCustom(); s[key=="font" and "weight" or key]=value
            E.Library.readingSave(s,nil)
            E.CustomReading.open(key,nil)
            local editor=E.CustomReading.editor
            local frame=editor:rowWidget({row={preview=true}},500,100,editor.metrics)
            E.CustomReading.close()
            return frame[1][1],frame
        end
        local lighter=preview("contrast",-.5); local light=preview("contrast",-.4)
        ok(lighter.fgcolor>light.fgcolor)
        local dark=preview("contrast",.2); local darker=preview("contrast",.3)
        ok(darker.face.embolden_half_strength>dark.face.embolden_half_strength)
        local medium=preview("font",1); local heavy=preview("font",2)
        ok(heavy.face.embolden_half_strength>medium.face.embolden_half_strength)
        eq(heavy.face.getFallbackFont(0),heavy.face,"native shaped glyphs use the private preview strength")
        eq(W.face.hash,"fixture"); eq(W.face.embolden_half_strength,nil,"shared UI face stays immutable")
        local text,frame=preview("margins",60); eq(frame.padding_left,50); eq(frame.padding_right,50)
        eq(text.width+2*frame[1].padding+2*frame.bordersize+frame.padding_left+frame.padding_right,500,"preview paper and gutters fit the row")
    end)

    test("Custom margins: physical pixels roundtrip at fractional native screen scales",function()
        local W,E=world(); local ui=styleReader(W)
        for _,factor in ipairs({1.25,1.5,1.8,2.34}) do
            W.scale=factor
            for _,pixels in ipairs({10,46,80}) do
                local s=E.Library.readingCustom(); s.margins=pixels; E.Library.readingSave(s,nil)
                E.Library.readingApply(ui,"margins","custom")
                eq(math.ceil(ui.typeset.unscaled_margins[1]*factor),pixels,"native margin in physical pixels")
                E.Library.readingCopy(ui)
                eq(E.Library.readingCustom().margins,pixels,"one-time copy keeps the applied margin")
            end
        end
    end)

    test("Custom contrast: native redraw only; mixed layout changes update position once",function()
        local W,E=world(); local ui=styleReader(W)
        E.Library.readingApply(ui,"contrast","custom"); eq(W.event.name,"RedrawCurrentView")
        local n=W.events; local s=E.Library.readingCustom(); s.contrast=.3
        E.Library.readingSave(s,ui,"reading-custom-contrast")
        eq(W.event.name,"RedrawCurrentView"); eq(W.events,n+1)
        E.Library.readingRestore(ui); eq(W.event.name,"RedrawCurrentView")
        E.Library.readingApply(ui,"spacing","custom"); eq(W.event.name,"UpdatePos")
        n=W.events; s=E.Library.readingCustom(); s.spacing=1.6; s.contrast=.4
        E.Library.readingSave(s,ui,"reading-custom-spacing")
        eq(W.event.name,"UpdatePos"); eq(W.events,n+1,"one update for mixed changes")
    end)

    test("Custom font copy: matching preset is selected; an outside face remains a visible choice",function()
        local W,E=world(); local ui=styleReader(W)
        for index,font in ipairs(E.ReadingStyle.fonts) do
            ui.font.font_face=font.face
            E.Library.readingCopy(ui)
            local s=E.Library.readingCustom(); eq(s.fontIndex,index); eq(s.face,nil)
            E.CustomReading.open("font",ui)
            local selected=false
            for _,r in ipairs(E.CustomReading.editor:rows()) do
                if r.fontIndex==index and r.text:find("● ",1,true)==1 then selected=true end
            end
            ok(selected,"copied preset selected"); E.CustomReading.close()
        end
        ui.font.font_face="Fixture Serif"; local previous=E.Library.readingCopy(ui)
        E.CustomReading.open("font",ui)
        local rows=E.CustomReading.editor:rows(); eq(#rows,12,"copied face fits the editor budget")
        eq(rows[3].face,"Fixture Serif"); eq(rows[3].text,"● Fixture Serif (copied)")
        E.CustomReading.close(); E.Library.readingSave(previous,ui)
        eq(E.Library.readingCustom().face,nil); eq(E.Library.readingCustom().fontIndex,4,"Undo keeps the previous font index")
    end)

end

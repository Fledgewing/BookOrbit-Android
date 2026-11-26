-- SPDX-License-Identifier: AGPL-3.0-or-later
return function(test,eq,ok,E,W,Widget)
    local function withHost(fn)
        local saved={adapter=E.LibraryAdapter,ui=E.HomeWidgets._ui,layout=E.S.home_layout,screen=E.S.home_screen,
            problem=E.Companion.workerProblem,scale=E.Device.screen.scaleBySize,shown=W.shown,free=Widget.free,paint=Widget.paintTo,require=E.require,codec=E.HomeEditor.codec,path=E.HomeEditor.path,loaded=E.HomeEditor.loaded,save=E.HomeEditor.save,liveUI=E.liveUI,pin=E.Shared.pin_locked,refresh=E.Shared.refresh,wifiState=E.Wifi.state,eobSheet=E.EOB.sheet,open=E.Library.open,panel=E.ReaderPanel,readFile=E.Store.readFile,writeFile=E.Store.writeFile}
        local batches,reads={},{}
        E.Device.screen.scaleBySize=function(_,n) return n end
        E.Companion.workerProblem=function() end
        Widget.free=function() end
        local U={Font={getFace=function() return {} end},BB={COLOR_BLACK=0,COLOR_WHITE=1,COLOR_DARK_GRAY=.3,COLOR_GRAY=.5,COLOR_LIGHT_GRAY=.8}}
        for _,k in ipairs({"Overlap","Frame","Text","Button","Progress"}) do U[k]=Widget:extend{} end
        Widget.paintTo=function(self,bb,x,y)
            for _,child in ipairs(self) do if child.paintTo then child:paintTo(bb,x,y) end end
        end
        E.require=function(name)
            if name=="ffi/blitbuffer" then return U.BB end
            if name=="ui/size" then return {padding={buttontable=0}} end
            if name=="ui/widget/touchmenu" then return Widget:extend{} end
            if name=="ui/widget/buttondialog" then
                return Widget:extend{moveFocusTo=function(self,x,y) self.focus={x,y} end,getButtonById=function() end,
                    -- Pinned ButtonDialog:onClose uses tap_close_callback, not dismiss_callback.
                    onClose=function(self)
                        if self.tap_close_callback then self.tap_close_callback() end
                        E.UIManager:close(self)
                        return true
                    end}
            end
            if name=="ui/widget/inputdialog" then
                return Widget:extend{getInputText=function() return "Moon" end,onShowKeyboard=function() end}
            end
            return require(name)
        end
        E.HomeWidgets._ui=U
        E.LibraryAdapter={watch=function() end,read=function(raw)
            local a=E.Cache.decode(raw); reads[#reads+1]=a
            if a.op == "capabilities" then return {lists={read=true}},80 end
            if a.op == "library.summary" then return {total=7,on_device=2,freshness={saved=true}},100 end
            if a.op == "battery" then return {level=78,hours_usual_use=54,screen_on={pct_per_hour=4.1},
                standby={pct_per_hour=.6},recent_charges={{from_pct=12,to_pct=100}},freshness={saved=true},
                display={level="78%",estimate="≈ 2 d 6 h at your usual use",narrow_estimate="≈ 2 d 6 h · usual use",
                    reading="12 h reading non-stop",standby="10 d standby only"}},500 end
            if a.op == "reading.stats" then
                local d={state="ready",year={intensity={},days_read=1,start="2026-01-01"},
                    week={seconds={0,0,0,0,0,0,60},levels={0,0,0,0,0,0,1},total_seconds=60},
                    hour_levels={},hour_intensity={},peak_hour=22,after_18_percent=100,
                    records={recorded_pages=3,longest_session_seconds=60,streak=1,best_streak=1},
                    sources={days="server",hours="this reader",records="this reader",streak="server"},local_today_seconds=60}
                for i=1,365 do d.year.intensity[i]=0 end
                for i=1,24 do d.hour_levels[i]=0; d.hour_intensity[i]=0 end
                return d,#E.Cache.encode(d)
            end
            if a.op == "facets" then return {items=a.field and {{value="unread",label="Unread",count=2}} or {},total=2,freshness={saved=true}},150 end
            if a.op == "lists" then return {items={{key="opaque-list",title="Favourites",count=3}},freshness={saved=true}},150 end
            return {items={{key="opaque-book",title="The Moon",authors={"A"},progress=25,local_path="/fixture/book.epub"}},freshness={saved=true}},200
        end,request=function(batch) batches[#batches+1]=batch; return true end}
        local records,files={},{}; local seq=0
        E.HomeEditor.loaded=true
        E.HomeEditor.path=function() return "home-layout-fixture" end
        E.HomeEditor.codec=function() return {encode=function(d)
            seq=seq+1; records[tostring(seq)]=E.Layout.copy(d); return tostring(seq)
        end,decode=function(raw) return E.Layout.copy(records[raw]) end} end
        E.Store.readFile=function(path) return files[path] end
        E.Store.writeFile=function(path,raw) files[path]=raw; return true end
        W.shown={}
        local success,err=pcall(fn,batches,reads,U)
        if E.HomeHost.active then E.HomeHost.active:onCloseWidget() end
        E.LibraryAdapter,E.HomeWidgets._ui,E.S.home_layout,E.S.home_screen=saved.adapter,saved.ui,saved.layout,saved.screen
        E.Device.screen.scaleBySize,W.shown,Widget.free,Widget.paintTo,E.require=saved.scale,saved.shown,saved.free,saved.paint,saved.require
        E.HomeEditor.codec,E.HomeEditor.path,E.HomeEditor.loaded=saved.codec,saved.path,saved.loaded
        E.Library.open,E.ReaderPanel=saved.open,saved.panel
        E.HomeEditor.save=saved.save
        E.liveUI,E.Wifi.state,E.EOB.sheet=saved.liveUI,saved.wifiState,saved.eobSheet
        E.Shared.pin_locked,E.Shared.refresh=saved.pin,saved.refresh
        E.Store.readFile,E.Store.writeFile=saved.readFile,saved.writeFile
        E.Companion.workerProblem=saved.problem
        ok(success,err)
    end
    dofile((arg[0]:match("^(.*)/") or ".").."/series_flows.lua")(test,eq,ok,E,W,withHost)
    dofile((arg[0]:match("^(.*)/") or ".").."/booklist_flows.lua")(test,eq,ok,E,W,Widget,withHost)
    dofile((arg[0]:match("^(.*)/") or ".").."/home_editor_flows.lua")(test,eq,ok,E,W,Widget,withHost)
    dofile((arg[0]:match("^(.*)/") or ".").."/battery_flows.lua")(test,eq,ok,E,W,withHost)
    test("First run: upgrade news appears once on Home, with a static budget",function()
        withHost(function(batches)
            local pending=E.S.news_012_pending
            local saved=E.saveSettings
            local saves=0
            E.saveSettings=function() saves=saves+1 end
            E.S.news_012_pending=true
            ok(E.HomeHost.show())
            local dialog=W.shown[#W.shown]
            eq(dialog.title,"What's new in 0.12"); eq(#dialog.buttons,5)
            ok(dialog.buttons[5][1].height>=50,"upgrade acknowledgement meets the touch minimum")
            eq(#batches,1,"news adds no read-model batch")
            dialog.buttons[5][1].callback()
            eq(E.S.news_012_pending,false); eq(saves,1)
            ok(E.HomeHost.show())
            eq(W.shown[#W.shown],E.HomeHost.active,"already seen")
            E.S.news_012_pending=true
            local dismissed=E.HomeHost.whatsNew()
            eq(dismissed.dismiss_callback,nil,"ButtonDialog does not support InfoMessage's dismissal hook")
            dismissed:onClose() -- native Back and outside taps take this same path
            eq(E.S.news_012_pending,false); eq(saves,2)
            E.S.news_012_pending=false
            ok(E.HomeHost.show())
            eq(W.shown[#W.shown],E.HomeHost.active,"fresh install has no news")
            E.saveSettings=saved; E.S.news_012_pending=pending
            eq(E.Budgets.screens["whats-new"].roundTrips,0)
        end)
    end)
    test("First run: empty reading and shelves give guidance without a dead Retry",function()
        withHost(function()
            for _,widget in ipairs({"continue-reading","booklist","lists"}) do
                local p={widget=widget,settings={title="Want to read"}}
                local card=E.HomeWidgets.card(p,E.HomeHostPlan.snapshot({items={},freshness={saved=true}}),function() error("no action") end,{w=400,h=300})[1]
                local guidance=false
                for _,child in ipairs(card) do
                    ok(child.text~="Retry")
                    if child.text==(widget=="continue-reading" and "Open a book to start reading" or widget=="lists" and "No lists yet" or "No books here yet") then guidance=true end
                end
                ok(guidance)
            end
        end)
    end)
    test("First run: missing catalog uses actionable signed-out cards, cached rows survive",function()
        withHost(function()
            local a={signedIn=false,opds={available=false}}
            local missing=E.HomeHostPlan.snapshot({items={},pending=true},a)
            eq(missing.state,"error"); eq(missing.setup,true)
            local declared=false
            for _,state in ipairs(E.WidgetRegistry.booklist.states) do if state==missing.state then declared=true end end
            ok(declared,"setup cards retain the declared widget state contract")
            local action
            local card=E.HomeWidgets.card({widget="booklist",settings={}},missing,function(id) action=id end,{w=400,h=300})[1]
            eq(card[#card].text,"Sign in"); card[#card].callback(); eq(action,"setup")
            local cached=E.HomeHostPlan.snapshot({items={{key="b"}},freshness={saved=true}},a)
            eq(cached.state,"ready")
            a.opds.available=true
            eq(E.HomeHostPlan.snapshot({items={},pending=true},a).state,"loading","own catalog login needs no account")
            a.opds.available=false; a.sync={available=true}
            eq(E.HomeHostPlan.snapshot({items={},pending=true},a).state,"loading","own sync login can still materialize local windows")
            a.signedIn=true; a.sync.available=false
            eq(E.HomeHostPlan.snapshot({items={},pending=true},a).state,"loading","signed in projection can complete")
        end)
    end)
    test("Home host: paint batches only installed visible widgets and page swipe",function()
        withHost(function(batches,reads)
            E.S.home_layout=E.Layout.default()
            table.insert(E.S.home_layout.pages,2,{id="second",tab="Home",name="More books",placements={{instance="more",widget="booklist",version=1,x=0,y=0,w=4,h=2,settings={src="wtr"}}}})
            local h=E.HomeHost.create(); E.HomeHost.active=h; W.shown={h}
            eq(#batches,1); eq(#batches[1],7) -- capabilities + six installed placements
            eq(h.metrics.spawns,0); eq(h.metrics.network,0); eq(h.metrics.roundTrips,1)
            eq(h.metrics.rows,7); ok(h.metrics.bytes<=E.Budgets.screens.home.bytes)
            eq(h.index,1)
            h:onHomeSwipe(nil,{direction="west"}); eq(h.index,2)
            eq(#batches,2); eq(#batches[2],2,"future-only page is skipped; second Shelf still reads")
            h:onHomeSwipe(nil,{direction="east"}); eq(h.index,1)
            h:onPrevious(); eq(h.index,1)
            h:onClose(); h:onCloseWidget(); eq(E.Library.listener,nil)
        end)
    end)
    test("Home design: page title, menu settings and Back restore the originating page",function()
        withHost(function()
            local h=E.HomeHost.create(); E.HomeHost.active=h; W.shown={h}
            h:turn(2); local index=h.index
            eq(h[1][1][1].text,"Stats")
            ok(h[1][1][1].max_width<=h.dimen.w-220,"page title leaves room for Edit and Close")
            h:showList("Want to read","want-to-read")
            h:onClose(); eq(h.index,index); eq(h[1][1][1].text,"Stats")
            local old=E.state.module
            local opened=0
            E.state.module={showSettings=function() opened=opened+1 end}
            local success,err=pcall(function()
                h:menu(); local menu=W.shown[#W.shown]
                eq(menu.buttons[2][1].text,"BookSync settings")
                menu.buttons[2][1].callback(); eq(opened,1); eq(W.shown[#W.shown],h)
            end)
            E.state.module=old
            ok(success,err)
        end)
    end)
    test("Home design: all installed widget sizes keep touch controls at least 50 logical pixels",function()
        withHost(function()
            local data={items={{key="a",title="The Moon",authors={"A"},progress=25,local_path="book.epub"},
                {key="b",title="Glasswater",progress=62},{key="c",title="Lantern"},{key="d",title="Sea"}},freshness={saved=true}}
            local function controls(node,ox,oy,bounds,found)
                ox,oy=ox or 0,oy or 0
                local at=node.overlap_offset or {0,0}; ox,oy=ox+at[1],oy+at[2]
                if node.callback and node.width and node.height then
                    ok(node.width>=50 and node.height>=50,"small target: "..tostring(node.text).." "..node.width.."×"..node.height)
                    ok(ox>=0 and oy>=0 and ox+node.width<=bounds.w and oy+node.height<=bounds.h,
                        "target outside card: "..tostring(node.text))
                    for _,r in ipairs(found) do
                        ok(not (ox<r.x+r.w and r.x<ox+node.width and oy<r.y+r.h and r.y<oy+node.height),
                            "overlapping targets: "..tostring(node.text).." / "..r.text)
                    end
                    found[#found+1]={x=ox,y=oy,w=node.width,h=node.height,text=node.text}
                end
                for _,child in ipairs(node) do controls(child,ox,oy,bounds,found) end
            end
            for _,id in ipairs({"continue-reading","booklist","lists","library","battery"}) do
                for _,size in ipairs(E.WidgetRegistry[id].sizes["android-tablet"]) do
                    local rect=E.HomeHostPlan.rect({x=0,y=0,w=size[1],h=size[2]},{cols=4,rows=8},678,764,12)
                    local p={widget=id,w=size[1],h=size[2],settings={style=1}}
                    for _,state in ipairs({"ready","empty","loading","error","offline-without-data","offline-with-data","setup"}) do
                        local snap=E.HomeHostPlan.snapshot(data)
                        if id=="library" then snap=E.HomeHostPlan.snapshot({total=7,on_device=2,freshness={saved=true}}) end
                        if id=="battery" then snap=E.HomeHostPlan.snapshot({level=78,display={level="78%"},freshness={saved=true}}) end
                        local plain={state=state=="setup" and "error" or state,setup=state=="setup",items=snap.items,count=snap.count,data=snap.data,bytes=snap.bytes}
                        local card=E.HomeWidgets.renderers[id](p,plain,function() end,rect)
                        controls(card,0,0,{w=rect.w,h=rect.h},{})
                        if id=="continue-reading" and (state=="ready" or state=="offline-with-data") then
                            local percent=false
                            for _,child in ipairs(card[1]) do if child.text=="25%" then percent=true end end
                            ok(percent,"every hero size retains the percentage label")
                        end
                        if id=="booklist" then
                            p.settings.style=0
                            controls(E.HomeWidgets.renderers[id](p,plain,function() end,rect),0,0,{w=rect.w,h=rect.h},{})
                            p.settings.style=1
                        end
                    end
                end
            end
        end)
    end)
    test("Home Settings: standalone menu uses native tab rows and the current PIN policy",function()
        withHost(function()
            local owner=setmetatable({}, {__index=E.OrbitAndroid})
            local normal,locked=0,0
            owner.menuItems=function() normal=normal+1; return {{text="Book info"},{text="Your server",settings_group="account"}} end
            owner.lockedMenuItems=function(_,items) locked=locked+1; eq(#items,1); eq(items[1].settings_group,"account"); return {{text="Locked"}} end
            E.Shared.refresh=function() end
            E.Shared.pin_locked=false
            local menu=owner:showSettings()
            eq(menu.tab_item_table[1][1].text,"Your server"); eq(#menu.tab_item_table[1],1); eq(normal,1); eq(locked,0)
            E.Shared.pin_locked=true
            menu=owner:showSettings()
            eq(menu.tab_item_table[1][1].text,"Locked"); eq(normal,2); eq(locked,1)
        end)
    end)
    test("Home design: wide cover shelves read columns rather than a text-row limit",function()
        withHost(function(_,reads)
            local layout=E.Layout.default()
            layout.pages={{id="shelf",tab="Home",placements={{instance="wide",widget="booklist",version=1,
                x=0,y=0,w=4,h=2,settings={title="Recently added",src="recent",style=0}}}}}
            E.S.home_layout=layout
            local h=E.HomeHost.create(); E.HomeHost.active=h
            eq(reads[#reads].op,"window"); eq(reads[#reads].limit,4)
            eq(h.metrics.roundTrips,1); eq(h.metrics.spawns,0); eq(h.metrics.network,0)
        end)
    end)
    test("Home host: immutable snapshots isolate query and renderer errors",function()
        withHost(function(batches,reads,U)
            local render=E.HomeWidgets.renderers.booklist
            local errors=0
            E.HomeWidgets.renderers.booklist=function(p,snapshot)
                eq(pcall(function() snapshot.items[1].title="changed" end),false)
                errors=errors+1; error("broken renderer")
            end
            local success,err=pcall(function()
                local h=E.HomeHost.create(); E.HomeHost.active=h
                ok(errors>0); eq(h.metrics.roundTrips,1); eq(#batches,1)
                -- Query budget errors produce cards and do not poison the host flush.
                local read=E.LibraryAdapter.read
                E.LibraryAdapter.read=function(raw)
                    if E.Cache.decode(raw).op=="window" then error("unavailable read") end
                    return read(raw)
                end
                h:rebuild(); eq(h.metrics.rows,3); eq(#batches,2)
            end)
            E.HomeWidgets.renderers.booklist=render
            ok(success,err)
        end)
    end)
    test("Home host: deferred drawing errors and malformed settings stay inside cards",function()
        withHost(function()
            E.S.home_layout=E.Layout.default()
            E.S.home_layout.pages[1].placements[2].settings.limit="invalid"
            local old=E.HomeWidgets.renderers["continue-reading"]
            E.HomeWidgets.renderers["continue-reading"]=function()
                return {paintTo=function() error("deferred render error") end,free=function() end}
            end
            local success,err=pcall(function()
                local h=E.HomeHost.create(); E.HomeHost.active=h
                local canvas=h[1][1]
                local boundary=canvas[6] -- header, Close, Search, menu, Edit, first widget
                local failed=boundary[1]
                local Frame=E.HomeWidgets.ui().Frame
                Frame.paintTo=function() end
                boundary:paintTo({},0,0)
                ok(boundary[1] ~= failed,"replaced only the broken card")
                ok(h.metrics.rows>=2,"siblings still have data")
                Frame.paintTo=nil
            end)
            E.HomeWidgets.renderers["continue-reading"]=old
            ok(success,err)
        end)
    end)
    test("Home host: read-model invalidation redraws only an already visible Home",function()
        withHost(function(batches)
            local h=E.HomeHost.create(); E.HomeHost.active=h; W.shown={h}
            E.Library.changed({kind="library"}); E.Library.changed({kind="library"})
            local callback=h.redraw; ok(callback); callback(); eq(#batches,2)
            W.shown={}; E.Library.changed({kind="library"}); h.redraw(); eq(#batches,2)
            h:onCloseWidget(); eq(E.Library.listener,nil)
        end)
    end)
    test("Home wiring: all three required default pages draw and Stats shares one bounded row",function()
        withHost(function(batches,reads)
            E.S.home_layout=nil
            local h=E.HomeHost.create(); E.HomeHost.active=h; W.shown={h}
            local rectangles=0
            local bb={paintRect=function(_,x,y,w,h,color) ok(w>=0 and h>=0); ok(color~=nil); rectangles=rectangles+1 end}
            for page=1,3 do
                eq(h.index,page)
                h[1]:paintTo(bb,0,0)
                ok(E.Budgets.check(E.Budgets.screens.home,h.metrics))
                eq(h.metrics.spawns,0); eq(h.metrics.network,0); eq(h.metrics.roundTrips,1)
                if page<3 then h:onNext() end
            end
            local stats=0
            for _,a in ipairs(reads) do if a.op=="reading.stats" then stats=stats+1 end end
            eq(stats,1); eq(#batches,3)
            ok(rectangles>=400,"real Year, weekly and hourly renderers painted")
        end)
    end)
    test("Home wiring: measured Battery paints its true level in the shared batch",function()
        withHost(function(batches,reads)
            E.S.home_layout=nil
            local h=E.HomeHost.create(); E.HomeHost.active=h; W.shown={h}
            h:onNext(); h:onNext()
            local card=h[1][1][7][1][1]
            local level,estimate,glyph
            for _,child in ipairs(card) do
                if child.text=="78%" then level=true end
                if child.text=="≈ 2 d 6 h at your usual use" then estimate=true end
                if child.percentage==.78 then glyph=true end
            end
            ok(level and estimate and glyph)
            local count=0
            for _,a in ipairs(reads) do if a.op=="battery" then count=count+1 end end
            eq(count,1); eq(h.metrics.roundTrips,1); eq(h.metrics.spawns,0); eq(h.metrics.network,0)
        end)
    end)
    test("Home wiring: Battery compact and large cards keep progress in bounds",function()
        withHost(function()
            local snapshot=E.HomeHostPlan.snapshot({level=78,hours_usual_use=54,freshness={saved=true}})
            for _,case in ipairs({{w=280,h=69,cols=2,rows=1},{w=130,h=149,cols=1,rows=2},{w=580,h=230,cols=4,rows=2}}) do
                local rect=case
                local card=E.HomeWidgets.renderers.battery({w=case.cols,h=case.rows},snapshot,function() end,rect)[1]
                for _,child in ipairs(card) do
                    if child.percentage then
                        eq(child.percentage,.78)
                        ok(child.overlap_offset[1]+child.width<=card.dimen.w)
                        ok(child.overlap_offset[2]+child.height<=card.dimen.h)
                    end
                end

            end
        end)
    end)
    test("Home wiring: configured Library tile exposes bounded device and group links",function()
        withHost(function()
            E.S.home_layout=E.Layout.default()
            E.S.home_layout.pages[2].placements={{instance="summary",widget="library",version=1,x=0,y=0,w=2,h=2,settings={}}}
            local h=E.HomeHost.create(); E.HomeHost.active=h; W.shown={h}
            h:onNext()
            local tile=h[1][1][6][1][1]
            eq(tile[3].text,"2 on device ›")
            eq(tile[4].text,"Authors ›"); eq(tile[5].text,"Series ›")
            for _,child in ipairs(tile) do if child.height then
                ok(child.overlap_offset[2]+child.height<=tile.dimen.h)
            end end
            tile[5].callback()
            eq(h.filter.model.source,"library/all"); eq(h.filter.model.query.group,"series")
        end)
    end)
    test("Home wiring: list and search filter buttons save a reusable tile",function()
        withHost(function(batches,reads)
            E.S.home_layout=E.Layout.default()
            local h=E.HomeHost.create(); E.HomeHost.active=h; W.shown={h}
            h:dispatch("all",nil,E.S.home_layout.pages[1].placements[5])
            eq(h.filter.model.source,"recently-added")
            local canvas=h[1][1]
            eq(canvas[3].text,"Search"); eq(canvas[4].text,"Filter")
            canvas[4].callback()
            local filter=h.filter
            ok(filter.alive)
            filter.dialog.buttons[1][1].callback() -- Show picker
            eq(filter.model.pick,"show")
            filter.dialog.buttons[1][1].callback() -- Unread
            eq(filter.model.query.show,"unread")
            filter.dialog.buttons[11][1].callback() -- Save footer after nine rows + divider
            eq(filter.alive,false)
            local found
            for _,page in ipairs(E.S.home_layout.pages) do for _,p in ipairs(page.placements) do
                if p.settings.src=="custom" then found=p end
            end end
            ok(found); eq(found.settings.source,"recently-added"); eq(found.settings.query.show,"unread")
            E.S.home_layout=nil; E.HomeEditor.loaded=false
            local reloaded=E.HomeHost.document()
            local restored
            for _,page in ipairs(reloaded.pages) do for _,p in ipairs(page.placements) do
                if p.instance==found.instance then restored=p end
            end end
            ok(restored); eq(restored.settings.query.show,"unread")
            local toast=W.shown[#W.shown]
            toast.buttons[1][1].callback()
            eq(h.list_layout,nil)
            h:dispatch("all",nil,found)
            eq(h.filter.model.query.show,"unread")
            eq(h.filter.model.source,"recently-added")
            ok(E.Budgets.check(E.Budgets.screens.library,h.metrics))
            h:search()
            local input=W.shown[#W.shown]; input.buttons[1][2].callback()
            eq(h.filter.model.source,"search"); eq(h.filter.model.query.q,"Moon")
            eq(h.filter.model.query.sort,"match")
            eq(h[1][1][4].text,"Filter")
        end)
    end)
    test("Home wiring: filter dialogs over Home keep cached reads available above an open book",function()
        withHost(function()
            local h=E.HomeHost.create(); E.HomeHost.active=h
            local reader={document={}}
            E.liveUI=function() return reader end
            E.Wifi.state=function() return {foreground=true} end
            E.EOB.sheet=nil
            W.shown={reader,h}
            eq(E.reading(),false)
            local read=E.LibraryAdapter.read
            E.LibraryAdapter.read=function(raw)
                eq(E.reading(),false,"owned Home dialog is browsing, not foreground reading")
                return read(raw)
            end
            h:showList("Library","library/all")
            h.filter:show()
            eq(E.reading(),false,"filter sheet above Home")
            h.filter.dialog.buttons[1][1].callback()
            eq(h.filter.model.pick,"show"); eq(h.filter.total,2)
            eq(E.reading(),false,"picker above Home")
            h.filter.dialog.buttons[1][1].callback()
            eq(h.filter.model.query.show,"unread")
            W.shown={h,reader}
            eq(E.reading(),true,"reader placed above Home remains protected")
            W.shown={reader}
            eq(E.reading(),true,"stale active Home cannot open the gate")
            local filter=h.filter
            h:onCloseWidget()
            eq(filter.alive,false); eq(filter.dialog,nil); eq(filter.retry,nil)
        end)
    end)
    test("Home wiring: nonlocal Details retain Home above the open book",function()
        withHost(function()
            local h=E.HomeHost.create(); E.HomeHost.active=h
            local reader={document={}}
            E.liveUI=function() return reader end
            E.Wifi.state=function() return {foreground=true} end
            E.EOB.sheet=nil
            W.shown={reader,h}
            E.Library.open=function() return false end
            E.ReaderPanel={details=function(key)
                eq(key,"opaque-book"); eq(E.reading(),false)
                W.shown[#W.shown+1]={name="booksync_details"}
                return true
            end}
            h:dispatch("book",{key="opaque-book"})
            eq(W.shown[2],h,"Details Back returns to Home")
            eq(E.reading(),false)
            table.remove(W.shown)
            h:onClose(); h:onCloseWidget()
            eq(E.reading(),true,"closing Home restores foreground reading")
            local resumed=E.HomeHost.create(); E.HomeHost.active=resumed; W.shown={reader,resumed}
            E.Library.open=function() return true end
            E.ReaderPanel={details=function() error("local Resume must not open Details") end}
            resumed:dispatch("book",{key="local-book",local_path="/fixture/book.epub"})
            eq(W.shown[#W.shown],reader)
            eq(E.reading(),true,"local Resume closes Home")
        end)
    end)
    test("Home wiring: failed filter save preserves the published layout",function()
        withHost(function()
            E.S.home_layout=E.Layout.default()
            local h=E.HomeHost.create(); E.HomeHost.active=h; W.shown={h}
            local published=E.S.home_layout
            E.HomeEditor.save=function() return nil,"layout write failed" end
            eq(h:saveFilter({base_source="search",query={q="Moon"}}),false)
            eq(E.S.home_layout,published)
            eq(W.shown[#W.shown].text,"layout write failed")
        end)
    end)
    test("Home wiring: bounded list paging returns to the prior full window",function()
        withHost(function()
            local adapterRead=E.LibraryAdapter.read
            E.LibraryAdapter.read=function(raw)
                local a=E.Cache.decode(raw)
                if a.op~="window" then return adapterRead(raw) end
                local rows={}
                local limit=a.limit
                for i=1,math.min(limit,limit+1-a.offset) do rows[i]={key="book-"..(a.offset+i),title="Book"} end
                return {items=rows,total=limit+1,next=a.offset==0 and limit or nil,freshness={saved=true}},400
            end
            local h=E.HomeHost.create(); E.HomeHost.active=h; W.shown={h}
            h:showList("Library","library/all")
            local settings=h.list_layout.pages[1].placements[1].settings
            local n=h.list_limit
            eq(#h.list_result.items,n)
            h:onNext(); eq(settings.offset,n); eq(#h.list_result.items,1)
            h:onPrevious(); eq(settings.offset,0); eq(#h.list_result.items,n)
            local snapshot=E.HomeHostPlan.snapshot({items={{title=string.rep("x",16384)}},freshness={saved=true}})
            eq(snapshot.state,"error"); eq(snapshot.count,0)
        end)
    end)
    test("Home wiring: full pages grow a named page without changing the original",function()
        local d=E.Layout.default()
        d.pages={{id="full",tab="Home",placements={{instance="fill",widget="future",version=1,x=0,y=0,w=4,h=8,settings={}}}}}
        local out,page=E.HomeHostPlan.saveFilter(d,{base_source={kind="list",key="opaque"},query={q="Moon"}},"Short books")
        ok(out); eq(#d.pages,1); eq(#out.pages,2); eq(out.pages[2].name,"Short books")
        eq(out.pages[2].id,page); eq(out.pages[2].placements[1].settings.source.key,"opaque")
        ok(E.Layout.validate(out))
    end)
    test("Home host: grid projection, immutable contract and strict budgets",function()
        local p={x=2,y=3,w=2,h=3}
        local r=E.HomeHostPlan.rect(p,{cols=4,rows=8},580,680,12)
        ok(r.x>0 and r.y>0 and r.x+r.w<=580 and r.y+r.h<=680)
        local b=E.Budgets.widgets.lists
        for _,field in ipairs({"rows","bytes","spawns","roundTrips","network","snapshotBytes"}) do
            local counts={rows=0,bytes=0,spawns=0,roundTrips=0,network=0,snapshotBytes=0}
            counts[field]=b[field]+1; eq(E.Budgets.check(b,counts),nil,field)
        end
        eq(E.HomeHostPlan.need({widget="booklist",settings={src="wtr"}}).source,"want-to-read")
        eq(E.HomeHostPlan.need({widget="booklist",settings={src="recent"}}).source,"recently-added")
        local also=E.HomeHostPlan.need({widget="booklist",settings={src="reading",sort=3}})
        eq(also.offset,0); eq(also.exclude_current,true); eq(also.query.sort,"last"); eq(also.query.dir,"desc")
        eq(E.HomeHostPlan.snapshot({items={},freshness={saved=true}}).state,"empty")
        eq(E.HomeHostPlan.snapshot({items={},pending=true}).state,"loading")
        eq(E.HomeHostPlan.snapshot({items={}}).state,"offline-without-data")
        eq(E.HomeHostPlan.snapshot({items={{key="b"}},freshness={saved=true,offline=true}}).state,"offline-with-data")
        local registry=E.HomeHost.installed()
        eq(#E.HomeHostPlan.resolve(E.Layout.default(),registry,{}).pages,3)
        local projected=E.HomeHostPlan.resolve(E.Layout.default(),registry,{wantToRead=false,lists={read=false},battery=false})
        for _,p in ipairs(projected.pages[1].placements) do ok(p.widget ~= "lists" and p.instance ~= "want") end
    end)
    test("Home host: server-only book cards open the owned Details surface",function()
        withHost(function()
            local open,panel=E.Library.open,E.ReaderPanel
            local target
            local success,err=pcall(function()
                E.Library.open=function() return false end
                E.ReaderPanel={details=function(key) target=key; return true end}
                local h=E.HomeHost.create(); E.HomeHost.active=h
                h:dispatch("book",{key="opaque-book"})
                eq(target,"opaque-book")
            end)
            E.Library.open,E.ReaderPanel=open,panel
            ok(success,err)
        end)
    end)

    test("Home host: account setup actions use the right form and invalidate the subtitle region",function()
        withHost(function()
            local read,open=E.LibraryAdapter.read,E.AccountView.open
            local state={signedIn=false,sync={available=false},opds={available=false}}
            local kind
            E.AccountView.open=function(k) kind=k or "summary" end
            E.LibraryAdapter.read=function(raw)
                if E.Cache.decode(raw).op=="capabilities" then return {account=state},256 end
                return read(raw)
            end
            local success,err=pcall(function()
                local h=E.HomeHost.create(); E.HomeHost.active=h
                local canvas=h[1][1]
                eq(canvas[2].text,"Not signed in · Sign in"); canvas[2].callback(); eq(kind,"summary")
                for _,control in ipairs(canvas) do if control.text=="Search" then
                    ok(canvas[2].overlap_offset[1]>=control.overlap_offset[1]+control.width,"setup subtitle does not overlap Search")
                end end
                state={signedIn=true,sync={available=false},opds={available=false}}
                h:rebuild(); canvas=h[1][1]
                eq(canvas[2].text,"No sync login · Set up"); canvas[2].callback(); eq(kind,"sync")
                eq(h.changed_rects[1].y,0); ok(h.changed_rects[1].h>0)
                h:dispatch("book",{key="remote-only"})
                eq(h.download_prompt.title,"No OPDS login, so it can't download")
                h.download_prompt.buttons[1][2].callback(); eq(kind,"opds")
                state={signedIn=true,sync={available=true},opds={available=true}}
                h:rebuild()
                eq(h.account_status,nil)
                ok(h.changed_rects[1].h>=104 and h.changed_rects[1].h<h.dimen.h,"removing setup action invalidates its header region")
            end)
            E.LibraryAdapter.read,E.AccountView.open=read,open
            ok(success,err)
        end)
    end)

end

-- SPDX-License-Identifier: AGPL-3.0-or-later
return function(test,eq,ok,E,W,Widget)
    local function withHost(fn)
        local saved={adapter=E.LibraryAdapter,ui=E.HomeWidgets._ui,layout=E.S.home_layout,screen=E.S.home_screen,
            scale=E.Device.screen.scaleBySize,shown=W.shown,free=Widget.free,paint=Widget.paintTo,require=E.require,codec=E.HomeEditor.codec,path=E.HomeEditor.path,loaded=E.HomeEditor.loaded,save=E.HomeEditor.save,liveUI=E.liveUI,wifiState=E.Wifi.state,eobSheet=E.EOB.sheet,open=E.Library.open,panel=E.ReaderPanel,readFile=E.OC.readFile,writeFile=E.OC.writeFile}
        local batches,reads={},{}
        E.Device.screen.scaleBySize=function(_,n) return n end
        Widget.free=function() end
        local U={Font={getFace=function() return {} end},BB={COLOR_BLACK=0,COLOR_WHITE=1,COLOR_DARK_GRAY=.3,COLOR_GRAY=.5,COLOR_LIGHT_GRAY=.8}}
        for _,k in ipairs({"Overlap","Frame","Text","Button","Progress"}) do U[k]=Widget:extend{} end
        Widget.paintTo=function(self,bb,x,y)
            for _,child in ipairs(self) do if child.paintTo then child:paintTo(bb,x,y) end end
        end
        E.require=function(name)
            if name=="ffi/blitbuffer" then return U.BB end
            if name=="ui/size" then return {padding={buttontable=0}} end
            if name=="ui/widget/buttondialog" then
                return Widget:extend{moveFocusTo=function(self,x,y) self.focus={x,y} end,getButtonById=function() end}
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
                standby={pct_per_hour=.6},recent_charges={{from_pct=12,to_pct=100}},freshness={saved=true}},200 end
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
        E.OC.readFile=function(path) return files[path] end
        E.OC.writeFile=function(path,raw) files[path]=raw; return true end
        W.shown={}
        local success,err=pcall(fn,batches,reads,U)
        if E.HomeHost.active then E.HomeHost.active:onCloseWidget() end
        E.LibraryAdapter,E.HomeWidgets._ui,E.S.home_layout,E.S.home_screen=saved.adapter,saved.ui,saved.layout,saved.screen
        E.Device.screen.scaleBySize,W.shown,Widget.free,Widget.paintTo,E.require=saved.scale,saved.shown,saved.free,saved.paint,saved.require
        E.HomeEditor.codec,E.HomeEditor.path,E.HomeEditor.loaded=saved.codec,saved.path,saved.loaded
        E.Library.open,E.ReaderPanel=saved.open,saved.panel
        E.HomeEditor.save=saved.save
        E.liveUI,E.Wifi.state,E.EOB.sheet=saved.liveUI,saved.wifiState,saved.eobSheet
        E.OC.readFile,E.OC.writeFile=saved.readFile,saved.writeFile
        ok(success,err)
    end
    dofile((arg[0]:match("^(.*)/") or ".").."/booklist_flows.lua")(test,eq,ok,E,W,Widget,withHost)
    dofile((arg[0]:match("^(.*)/") or ".").."/home_editor_flows.lua")(test,eq,ok,E,W,Widget,withHost)
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
                local boundary=canvas[5] -- header, Close, Search, Edit, first widget
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
    test("Home wiring: all three default pages draw and Stats shares one bounded row",function()
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
            local card=h[1][1][6][1][1]
            eq(card[2].text,"78%"); eq(card[3].text,"≈ 2 d 6 h at your usual use")
            eq(card[4].percentage,.78)
            local count=0
            for _,a in ipairs(reads) do if a.op=="battery" then count=count+1 end end
            eq(count,1); eq(h.metrics.roundTrips,1); eq(h.metrics.spawns,0); eq(h.metrics.network,0)
        end)
    end)
    test("Home wiring: Battery compact and large cards keep progress in bounds",function()
        withHost(function()
            local snapshot=E.HomeHostPlan.snapshot({level=78,hours_usual_use=54,freshness={saved=true}})
            for _,rect in ipairs({{w=130,h=69},{w=280,h=149},{w=580,h=230}}) do
                local card=E.HomeWidgets.renderers.battery({},snapshot,function() end,rect)[1]
                for _,child in ipairs(card) do
                    if child.percentage then
                        eq(child.percentage,.78)
                        ok(child.overlap_offset[1]+child.width<=card.dimen.w)
                        ok(child.overlap_offset[2]+child.height<=card.dimen.h)
                    end
                end
                if rect.h<120 then ok(card[1].overlap_offset[1]+card[1].max_width<=card[2].overlap_offset[1]) end
            end
        end)
    end)
    test("Home wiring: default Library tile exposes bounded device and group links",function()
        withHost(function()
            E.S.home_layout=nil
            local h=E.HomeHost.create(); E.HomeHost.active=h; W.shown={h}
            h:onNext()
            local tile=h[1][1][5][1][1]
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
        local projected=E.HomeHostPlan.resolve(E.Layout.default(),registry,{wantToRead=false,lists={read=false}})
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

end

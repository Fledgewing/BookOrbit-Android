-- SPDX-License-Identifier: AGPL-3.0-or-later
return function(test,eq,ok,E,W,Widget)
    local function withHost(fn)
        local saved={adapter=E.LibraryAdapter,ui=E.HomeWidgets._ui,layout=E.S.home_layout,screen=E.S.home_screen,
            scale=E.Device.screen.scaleBySize,shown=W.shown,free=Widget.free}
        local batches,reads={},{}
        E.Device.screen.scaleBySize=function(_,n) return n end
        Widget.free=function() end
        local U={Font={getFace=function() return {} end},BB={COLOR_BLACK=0,COLOR_WHITE=1,COLOR_DARK_GRAY=.3}}
        for _,k in ipairs({"Overlap","Frame","Text","Button","Progress"}) do U[k]=Widget:extend{} end
        E.HomeWidgets._ui=U
        E.LibraryAdapter={watch=function() end,read=function(raw)
            local a=E.Cache.decode(raw); reads[#reads+1]=a
            if a.op == "capabilities" then return {lists={read=true}},80 end
            if a.op == "lists" then return {items={{key="opaque-list",title="Favourites",count=3}},freshness={saved=true}},150 end
            return {items={{key="opaque-book",title="The Moon",authors={"A"},progress=25,local_path="/fixture/book.epub"}},freshness={saved=true}},200
        end,request=function(batch) batches[#batches+1]=batch; return true end}
        W.shown={}
        local success,err=pcall(fn,batches,reads,U)
        if E.HomeHost.active then E.HomeHost.active:onCloseWidget() end
        E.LibraryAdapter,E.HomeWidgets._ui,E.S.home_layout,E.S.home_screen=saved.adapter,saved.ui,saved.layout,saved.screen
        E.Device.screen.scaleBySize,W.shown,Widget.free=saved.scale,saved.shown,saved.free
        ok(success,err)
    end
    dofile((arg[0]:match("^(.*)/") or ".").."/home_editor_flows.lua")(test,eq,ok,E,W,Widget,withHost)
    test("Home host: paint batches only installed visible widgets and page swipe",function()
        withHost(function(batches,reads)
            E.S.home_layout=E.Layout.default()
            table.insert(E.S.home_layout.pages,2,{id="second",tab="Home",name="More books",placements={{instance="more",widget="booklist",version=1,x=0,y=0,w=4,h=2,settings={src="wtr"}}}})
            local h=E.HomeHost.create(); E.HomeHost.active=h; W.shown={h}
            eq(#batches,1); eq(#batches[1],6) -- capabilities + five installed placements
            eq(h.metrics.spawns,0); eq(h.metrics.network,0); eq(h.metrics.roundTrips,1)
            eq(h.metrics.rows,6); ok(h.metrics.bytes<=E.Budgets.screens.home.bytes)
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
                h:rebuild(); eq(h.metrics.rows,2); eq(#batches,2)
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
                local boundary=canvas[4] -- header, Close, Edit, first widget
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
        eq(also.offset,1); eq(also.query.sort,"last"); eq(also.query.dir,"desc")
        eq(E.HomeHostPlan.snapshot({items={},freshness={saved=true}}).state,"empty")
        eq(E.HomeHostPlan.snapshot({items={},pending=true}).state,"loading")
        eq(E.HomeHostPlan.snapshot({items={}}).state,"offline-without-data")
        eq(E.HomeHostPlan.snapshot({items={{key="b"}},freshness={saved=true,offline=true}}).state,"offline-with-data")
        local registry=E.HomeHost.installed()
        eq(#E.HomeHostPlan.resolve(E.Layout.default(),registry,{}).pages,1)
        local projected=E.HomeHostPlan.resolve(E.Layout.default(),registry,{wantToRead=false,lists={read=false}})
        for _,p in ipairs(projected.pages[1].placements) do ok(p.widget ~= "lists" and p.instance ~= "want") end
    end)
end

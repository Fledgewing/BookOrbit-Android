-- SPDX-License-Identifier: AGPL-3.0-or-later
return function(test,eq,ok,E,W,withHost)
    local function click(node,label)
        if node.text==label and node.callback then node.callback(); return true end
        for _,child in ipairs(node) do if type(child)=='table' and click(child,label) then return true end end
        return false
    end
    local function model()
        local daily={}
        for i=1,14 do daily[i]={text='Day '..i..' · 4% used',fraction=.04} end
        return {level=78,display={level='78%',estimate='≈ 2 d 6 h at your usual use',
            narrow_estimate='≈ 2 d 6 h · usual use',page_estimate='≈ 2 d 6 h left at your usual use',
            reading='19 h reading non-stop',standby='5 d standby only',
            overview={'Your usual use: screen on 25% of the time, last 7 days'},overview_count=1,
            rates={'Reading · 4.1 ± 0.3 %/h'},rates_count=1,daily=daily,daily_count=14,
            charges={'Sun 21:10 · 12% → 100% in 2 h 20 m'},charges_count=1}}
    end
    test('battery: every approved Home size reads one row in the host batch and opens the page',function()
        withHost(function(batches,reads)
            local read=E.LibraryAdapter.read
            E.LibraryAdapter.read=function(raw)
                if E.Cache.decode(raw).op=='battery' then return model(),2500 end
                return read(raw)
            end
            for _,size in ipairs(E.WidgetRegistry.battery.sizes['android-tablet']) do
                local layout=E.Layout.default()
                layout.pages={{id='battery',tab='Insights',placements={{instance='bat',widget='battery',version=1,
                    x=0,y=0,w=size[1],h=size[2],settings={}}}}}
                E.S.home_layout=layout
                local h=E.HomeHost.create(); E.HomeHost.active=h
                eq(#batches[#batches],2); eq(h.metrics.roundTrips,1); eq(h.metrics.spawns,0); eq(h.metrics.network,0)
                local request=E.Cache.decode(batches[#batches][2])
                eq(request.op,'battery'); eq(request.limit,1)
                ok(click(h,'Battery ›'),'registered battery renderer must succeed')
                local page=W.shown[#W.shown]
                eq(page.name,'booksync_battery'); eq(page.metrics.rows,1); eq(page.metrics.roundTrips,1)
                for _,control in ipairs(page[1][1]) do if control.callback then
                    ok(control.width>=50 and control.height>=50,'Battery touch minimum: '..control.text)
                    ok(control.overlap_offset[2]+control.height<=page.dimen.h,'Battery control in bounds')
                end end
                ok(click(page,'Daily')); eq(page.tab,3)
                ok(click(page,'›')); eq(page.page,2)
                ok(click(page,'Charges')); eq(page.tab,4)
                page:onClose(); eq(E.BatteryUI.active,nil); h:onCloseWidget()
            end
        end)
    end)
    test('battery: user-opened page lifts the book gate only while opening or visible',function()
        local live,top,state=E.liveUI,E.topWidget,E.Wifi.state
        local success,err=pcall(function()
            E.liveUI=function() return {document={}} end
            E.Wifi.state=function() return {foreground=true} end
            local page={}; local visible={}
            E.topWidget=function() return visible end
            E.BatteryUI.active=page
            eq(E.reading(),true)
            visible=page; eq(E.reading(),false)
            E.BatteryUI.active=nil; eq(E.reading(),true)
            E.BatteryUI.opening=true; eq(E.reading(),false)
            E.BatteryUI.opening=nil; eq(E.reading(),true)
        end)
        E.liveUI,E.topWidget,E.Wifi.state=live,top,state
        E.BatteryUI.active,E.BatteryUI.opening=nil,nil
        ok(success,err)
    end)
    test('battery: missing or mismatched companion stops the screen before reading',function()
        withHost(function(_,reads)
            E.Companion.workerProblem=function() return 'Update BookSync Companion' end
            eq(E.BatteryUI.show(),false); eq(#reads,0)
            eq(W.shown[#W.shown].text,'Update BookSync Companion')
        end)
    end)
    test('battery: cold and oversized snapshots remain bounded and late callbacks never reopen a page',function()
        withHost(function()
            E.LibraryAdapter.read=function() return nil end
            local card=E.HomeWidgets.renderers.battery({w=2,h=2},E.HomeHostPlan.snapshot({items={},pending=true}),function() end,{w=280,h=220})
            local loading=false
            for _,child in ipairs(card[1]) do if child.text=='Loading battery…' then loading=true end end
            ok(loading,'host loading state remains distinct from learning')
            local page=E.BatteryUI.show()
            eq(page.metrics.rows,0); eq(page.metrics.spawns,0); eq(page.metrics.network,0)
            eq(E.reading(),false); local refresh=page.refresh; ok(refresh)
            page:onClose(); eq(page.refresh,nil)
            local shown=#W.shown
            refresh(); eq(#W.shown,shown)
            E.LibraryAdapter.read=function() return model(),16385 end
            eq(pcall(E.BatteryUI.create),false)
            eq(E.Budgets.screens.battery.rows,1); eq(E.Budgets.widgets.battery.snapshotBytes,16384)
        end)
    end)
end

-- SPDX-License-Identifier: AGPL-3.0-or-later
return function(test,eq,ok,E,W,withHost)
    test('local decor: bounded immutable cards use the real font probe and explicit missing state',function()
        withHost(function()
            local requireSaved=E.require;local probes=0;local present=true
            E.require=function(name)
                if name=='ui/font' then return {getFace=function() return {ftsize={hasGlyph=function(_,cp) probes=probes+1;eq(cp,65);return present end,getInfo=function() return {name='Fixture UI'} end}} end} end
                return requireSaved(name)
            end
            local records={moon={state='ready',phase='Waning gibbous',illumination=73,next='Next: Last quarter · ≈ 2 Dec',source='Approximate · local date'},
                glyph={state='ready',sample='A',codepoint=65,code='U+0041',name='Latin capital letter A',source='KOReader interface font'}}
            local function labels(node,result)
                result=result or {};if node.text then result[node.text]=true end
                for _,child in ipairs(node) do if type(child)=='table' then labels(child,result) end end;return result
            end
            for id,data in pairs(records) do
                for _,size in ipairs(E.WidgetRegistry[id].sizes['android-tablet']) do
                    local p={widget=id,w=size[1],h=size[2]}
                    local snapshot=E.HomeHostPlan.immutable({data=data,state='ready',bytes=300})
                    local card=E.LocalWidgets.render(p,snapshot,function() end,{w=282*size[1]/2,h=156*size[2]/2})
                    local text=labels(card)
                    ok(text[E.WidgetRegistry[id].name]);if id=='glyph' then ok(text['A']);ok(text['U+0041 · Fixture UI']) else ok(text['≈ 73% lit']);ok(text['Approximate · local date']) end
                end
            end
            eq(probes,3)
            present=false
            local card=E.LocalWidgets.render({widget='glyph',w=2,h=2},{data=records.glyph,state='ready',bytes=300},function() end,{w=282,h=156})
            ok(labels(card)['Glyph unavailable in the interface font']);eq(probes,4)
            eq(E.Library.glyphFace(0,60),nil);eq(probes,4)
            local missing=E.LocalWidgetPlan.build('moon',{data={state='unavailable',reason='Set the reader date'}})
            eq(missing.message,'Set the reader date');eq(missing.ready,false)
            E.require=requireSaved
        end)
    end)
    test('quick controls: helper opt-in and active holds guard native writes',function()
        local oldInput=E.Library.controlInput;local oldOff=E.Companion.wifiOff;local oldUp=E.Companion.netUp
        local oldSync=E.Library.syncNow;local oldController=E.Library.controller;local oldRetry=E.Library.retry
        local off,up,sync=0,0,0
        local n={wifi_available=false,wifi_on=true,sync_available=true}
        E.Library.controlInput=function() return n end;E.Library.retry=function() end
        E.Companion.wifiOff=function(_,auto) eq(auto,false);off=off+1 end
        E.Companion.netUp=function(_,opts) eq(opts.owner,"manual");up=up+1 end
        E.Library.syncNow=function() sync=sync+1;return true end;E.Library.controller=function() return {} end
        eq(E.Library.controlAction('control-wifi'),false);eq(off,0)
        n.wifi_available=true;n.wifi_busy=true;eq(E.Library.controlAction('control-wifi'),false)
        n.wifi_busy=false;ok(E.Library.controlAction('control-wifi'));eq(off,1)
        n.wifi_on=false;ok(E.Library.controlAction('control-wifi'));eq(up,1)
        n.sync_busy=true;eq(E.Library.controlAction('control-sync'),false);eq(sync,0)
        n.sync_busy=false;ok(E.Library.controlAction('control-sync'));eq(sync,1)
        E.Library.controlInput=oldInput;E.Companion.wifiOff=oldOff;E.Companion.netUp=oldUp
        E.Library.syncNow=oldSync;E.Library.controller=oldController;E.Library.retry=oldRetry
    end)
    test('local widgets: Home owns one batch for all three local projections and Back',function()
        withHost(function(batches)
            local ops={}
            E.LibraryAdapter.read=function(raw)
                local args=E.Cache.decode(raw); ops[#ops+1]=args.op
                if args.op=='capabilities' then return {},2 end
                eq(args.limit,1); ok(args.bytes<=16384)
                if args.op=='local.light' then ok(type(args.native)=='table') end
                return {state='empty',row_count=1,freshness={saved=true}},100
            end
            E.S.home_layout=E.Layout.default()
            E.S.home_layout.pages={{id='local',tab='Home',name='Local',placements={}}}
            for i,id in ipairs({'word','light','buddy'}) do
                table.insert(E.S.home_layout.pages[1].placements,{instance=id,widget=id,version=1,x=0,y=(i-1)*2,w=2,h=2,settings={}})
            end
            local host=E.HomeHost.create(); E.HomeHost.active=host; W.shown={host}
            eq(#ops,4); eq(#batches,1); eq(#batches[1],4)
            eq(host.metrics.roundTrips,1); eq(host.metrics.spawns,0); eq(host.metrics.network,0); eq(host.metrics.rows,4)
            host:onClose(); host:onCloseWidget(); eq(E.Library.listener,nil)
        end)
    end)
    test('personal widgets: Home batches both neutral kinds with no source selection',function()
        withHost(function(batches)
            local kinds={}
            E.LibraryAdapter.read=function(raw)
                local args=E.Cache.decode(raw)
                if args.op=='capabilities' then return {},2 end
                eq(args.op,'personal.reading'); eq(args.limit,1); eq(args.source,nil)
                kinds[args.kind]=true
                return {state='empty',row_count=1,freshness={saved=true}},100
            end
            E.S.home_layout=E.Layout.default()
            E.S.home_layout.pages={{id='personal',tab='Home',name='Personal',placements={
                {instance='h',widget='highlight',version=1,x=0,y=0,w=2,h=2,settings={}},
                {instance='y',widget='yearago',version=1,x=2,y=0,w=2,h=2,settings={}}}}}
            local host=E.HomeHost.create(); E.HomeHost.active=host; W.shown={host}
            ok(kinds.highlight and kinds.yearago); eq(#batches,1); eq(#batches[1],3)
            eq(host.metrics.roundTrips,1); eq(host.metrics.spawns,0); eq(host.metrics.network,0)
        end)
    end)
    test('recommend/discover: one neutral batch and Another changes only interface pick',function()
        withHost(function(batches)
            local picks={}
            E.LibraryAdapter.read=function(raw)
                local args=E.Cache.decode(raw)
                if args.op=='capabilities' then return {},2 end
                eq(args.op,'personal.reading'); eq(args.limit,1); eq(args.source,nil)
                picks[args.kind]=args.pick
                return {state='ready',book={title='The Moon',local_path='/Books/moon.epub'},row_count=1,freshness={saved=true}},100
            end
            E.S.home_discover_pick=0
            E.S.home_layout=E.Layout.default()
            E.S.home_layout.pages={{id='picks',tab='Home',name='Picks',placements={
                {instance='r',widget='recommended',version=1,x=0,y=0,w=2,h=2,settings={}},
                {instance='d',widget='discover',version=1,x=2,y=0,w=2,h=2,settings={}}}}}
            local host=E.HomeHost.create(); E.HomeHost.active=host; W.shown={host}
            eq(picks.discover,0); eq(#batches,1); eq(#batches[1],3)
            eq(host.metrics.roundTrips,1); eq(host.metrics.rows,3)
            host:dispatch('discover-another',nil,{widget='discover'})
            eq(E.S.home_discover_pick,1); eq(picks.discover,1)
            eq(E.Library.localWidgetNeed('discover').pick,1)
            eq(E.Library.localWidgetNeed('recommended').pick,nil)
            eq(host.metrics.spawns,0); eq(host.metrics.network,0)
        end)
    end)
    test('local widgets: signed-out pending snapshots keep local loading, not account setup',function()
        withHost(function()
            E.LibraryAdapter.read=function(raw)
                if E.Cache.decode(raw).op=='capabilities' then return {account={signedIn=false}},60 end
                return nil
            end
            E.S.home_layout=E.Layout.default()
            E.S.home_layout.pages={{id='local',tab='Home',name='Local',placements={{instance='word',widget='word',version=1,x=0,y=0,w=2,h=2,settings={}}}}}
            local host=E.HomeHost.create(); E.HomeHost.active=host; W.shown={host}
            local loading=false
            local function scan(node)
                if node.text=='Loading…' then loading=true end
                ok(node.text~="Couldn't load this widget",'no account dependency on local widgets')
                for _,child in ipairs(node) do if type(child)=='table' then scan(child) end end
            end
            scan(host); ok(loading)
        end)
    end)
    test('local widgets: every size/state paints immutable data without reads; 50px actions',function()
        withHost(function()
            for _,id in ipairs({'word','light','buddy','highlight','yearago','recommended','discover'}) do
                ok(E.HomeWidgets.renderers[id])
                local offered=false
                for _,name in ipairs(E.HomeEditor.available({})) do if name==id then offered=true end end
                ok(offered,id..' offered by installed picker')
                for _,size in ipairs(E.WidgetRegistry[id].sizes['android-tablet']) do
                    for _,state in ipairs({'ready','empty','loading','error','offline-with-data','offline-without-data','unavailable'}) do
                        local result={state=state,passage='A saved passage',book_title='The Moon',summary='12 min · 1 day · stopped at p. 9',book={title='The Moon',local_path='/Books/moon.epub'},word='lantern',context='the lantern room',source='The Moon',message='Light · 40%',level=40,
                            freshness={saved=state~='offline-without-data'}}
                        if state=='loading' then result.pending=true end
                        if state=='error' then result.error='unavailable' end
                        local snapshot=E.HomeHostPlan.snapshot(result)
                        local before=E.Cache.encode(result)
                        local p={widget=id,w=size[1],h=size[2],settings={}}
                        local actions={}
                        local height=size[2]==1 and 110 or 220
                        local card=E.HomeWidgets.renderers[id](p,snapshot,function(a,value) actions[#actions+1]={a,value} end,{w=340,h=height})
                        for _,node in ipairs(card[1]) do
                            if node.callback then
                                ok(node.height>=50); ok(node.width>=50)
                                local x,y=unpack(node.overlap_offset)
                                ok(x>=0 and y>=0 and x+node.width<=338 and y+node.height<=height-2)
                                node.callback()
                            end
                        end
                        eq(E.Cache.encode(result),before)
                        if state=='ready' or state=='offline-with-data' then
                            if id=='recommended' or id=='discover' then eq(actions[1][1],'book'); eq(actions[1][2].title,'The Moon') end
                            if id=='discover' then eq(actions[2][1],'discover-another') end
                            if id=='word' then eq(actions[1][1],'word-lookup'); eq(actions[1][2],'lantern') end
                            if id=='light' then eq(actions[1][1],'light-down'); eq(actions[2][1],'light-up') end
                        end
                    end
                end
            end
        end)
    end)
    test('local widgets: native light actions use Library and clamp; dictionary dispatch returns to host',function()
        withHost(function()
            local oldRequire,oldControl,oldLive=E.require,E.Library.readerControl,E.liveUI
            local level,received=95
            E.require=function(name)
                if name=='device' then return {hasFrontlight=function() return true end,getPowerDevice=function()
                    return {frontlightIntensity=function() return level end}
                end} end
                return oldRequire(name)
            end
            E.Library.readerControl=function(_,action,value) eq(action,'light'); received=value; return true end
            ok(E.Library.localWidgetAction('light-up')); eq(received,100)
            level=5; ok(E.Library.localWidgetAction('light-down')); eq(received,0)
            E.liveUI=function() return {dictionary={onLookupWord=function(_,word,sane) eq(word,'lantern'); eq(sane,true); received=word end}} end
            ok(E.Library.localWidgetAction('word-lookup','lantern')); eq(received,'lantern')
            ok(not E.Library.localWidgetAction('word-lookup',string.rep('x',385)))
            E.require,E.Library.readerControl,E.liveUI=oldRequire,oldControl,oldLive
        end)
    end)
end

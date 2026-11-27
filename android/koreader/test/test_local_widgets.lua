-- SPDX-License-Identifier: AGPL-3.0-or-later
return function(test,eq,ok,here,Cache)
    local e=setmetatable({Cache=Cache},{__index=_G})
    for _,file in ipairs({'logic/budgets.lua','logic/widget_registry.lua','logic/local_widgets.lua'}) do
        setfenv(assert(loadfile(here..'/../orbit.koplugin/'..file)),e)()
    end
    for _,id in ipairs({'word','light','buddy'}) do
        test('local widget: '..id..' state and contract',function()
            eq(#e.WidgetRegistry[id].sizes['android-tablet'],2)
            for _,state in ipairs({'ready','empty','loading','error','offline-with-data','offline-without-data','unavailable'}) do
                local p=e.LocalWidgetPlan.build(id,{state=state,data={state=state,word='lantern',message='Local message'}})
                eq(p.ready,state=='ready' or state=='offline-with-data'); ok(#p.message>0)
                eq(p.word,p.ready and 'lantern' or false)
            end
            if id=='light' then
                eq(e.LocalWidgetPlan.build(id,{state='empty'}).message,'Frontlight unavailable on this reader')
            end
            local b=e.Budgets.get('widgets',id)
            ok(e.Budgets.check(b,{rows=1,bytes=16384,snapshotBytes=16384,network=0,spawns=0,roundTrips=0}))
            ok(not e.Budgets.check(b,{rows=2,bytes=1,snapshotBytes=1,network=0,spawns=0,roundTrips=0}))
            ok(not e.Budgets.check(b,{rows=1,bytes=16385,snapshotBytes=16385,network=0,spawns=0,roundTrips=0}))
        end)
    end
end

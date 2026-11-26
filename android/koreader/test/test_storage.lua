-- SPDX-License-Identifier: AGPL-3.0-or-later
return function(test,eq,ok,here)
    local e=setmetatable({},{__index=_G}); setfenv(assert(loadfile(here..'/../orbit.koplugin/logic/storage.lua')),e)()
    test('storage plan: pending, unavailable and empty data never invent figures',function()
        local p=e.StoragePlan
        eq(p.page({pending=true}).message,'Loading…')
        eq(p.page({error='unavailable'}).message,'Storage unavailable · Retry')
        eq(p.page({}).caption,'Space unavailable'); eq(#p.page({}).parts,0); eq(#p.page({}).actions,0)
    end)
    test('storage plan: ready and offline projections retain companion labels and warnings',function()
        local d={caption='1.2 GB free of 32 GB',warning='Low space: downloads still work',parts={{label='Books',display='4 MB'}},actions={{id='old'}},folder_label='/Books'}
        local p=e.StoragePlan.page(d)
        eq(p.caption,d.caption); eq(p.warning,d.warning); eq(p.parts,d.parts); eq(p.actions,d.actions); eq(p.folder,'/Books')
        d.offline=true; eq(e.StoragePlan.page(d).caption,d.caption)
    end)
    test('storage plan: both book removals and cover clearing explain what survives',function()
        for _,id in ipairs({'old','finished','covers'}) do
            local title,body=e.StoragePlan.confirm({id=id,detail='Frees 4 MB'})
            ok(#title>0); ok(body:find('progress',1,true)); ok(body:find('server',1,true)); ok(body:find('Frees 4 MB',1,true))
        end
    end)
end

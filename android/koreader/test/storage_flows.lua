-- SPDX-License-Identifier: AGPL-3.0-or-later
return function(test,eq,ok,E,W,withHost)
    local function click(node,text)
        if node.text==text and node.callback then node.callback(); return true end
        for _,child in ipairs(node) do if type(child)=='table' and click(child,text) then return true end end
        return false
    end
    local function data()
        return {caption='1.2 GB free of 32 GB',widget_label='Low space · 1.2 GB free',on_device=2,
            warning='Low space: 1.2 GB free. Downloads still work.',parts={{label='Books',display='100 MB',fraction=.1,pattern='solid'},
            {label='Free',display='1.2 GB',fraction=.9,pattern='white'}},
            actions={{id='finished',label='Remove finished books from device',detail='Frees 10 MB · 1 book',token='preview'}},
            folders={{id='Books',label='/Books'},{id='BookSync',label='/BookSync'}},folder='Books',freshness={saved=true}}
    end
    test('storage: Home adds one bounded local row to the existing batch and has no paint IO',function()
        withHost(function(batches)
            local read=E.LibraryAdapter.read
            E.LibraryAdapter.read=function(raw) if E.Cache.decode(raw).op=='storage.summary' then return data(),700 end; return read(raw) end
            local h=E.HomeHost.create(); E.HomeHost.active=h; W.shown={h}
            local n=0; for _,raw in ipairs(batches[1]) do local a=E.Cache.decode(raw); if a.op=='storage.summary' then n=n+1; eq(a.limit,1) end end
            eq(n,1); eq(h.metrics.roundTrips,1); eq(h.metrics.spawns,0); eq(h.metrics.network,0)
            local page=E.StorageUI.show(); eq(page.name,'booksync_storage'); eq(page.metrics.rows,1)
            eq(page.metrics.roundTrips,1)
            local removed=0
            E.LibraryAdapter.command=function(op,args,done) eq(op,'storage.free'); eq(args.token,'preview'); removed=removed+1; local d=data(); d.actions={}; done(d) end
            ok(click(page,'Remove finished books from device\nFrees 10 MB · 1 book'))
            local dialog=W.shown[#W.shown]; eq(dialog.focus[2],1); eq(removed,0)
            eq(dialog.buttons[1][1].text,'Cancel'); ok(dialog.title:find('progress, highlights and notes are kept',1,true))
            dialog.buttons[1][1].callback(); eq(removed,0)
            ok(click(page,'Remove finished books from device\nFrees 10 MB · 1 book'))
            dialog=W.shown[#W.shown]; dialog.buttons[1][2].callback(); eq(removed,1); eq(#page.data.actions,0)
            for _,control in ipairs(page.controls) do ok(control.width>=50 and control.height>=50); ok(control.overlap_offset[2]+control.height<=page.dimen.h) end
            page:onClose(); eq(E.StorageUI.active,nil)
        end)
    end)
    test('storage: pending, unavailable, empty, low and cached offline states remain bounded',function()
        withHost(function()
            for _,state in ipairs({{pending=true},{error='unavailable'},{caption='Space unavailable',parts={},actions={}},data()}) do
                E.LibraryAdapter.read=function() return state,400 end
                local page=E.StorageUI.create(); E.StorageUI.active=page; W.shown={page}
                eq(page.metrics.rows,1); ok(page.metrics.bytes<=16384)
                for _,control in ipairs(page.controls) do ok(control.height>=50) end
                page:onClose()
            end
            E.Companion.workerProblem=function() return 'Update BookSync Companion' end
            eq(E.StorageUI.show(),false)
        end)
    end)
    test('storage: folder selection dispatches once; late results cannot redraw a closed page',function()
        withHost(function()
            E.LibraryAdapter.read=function() return data(),700 end
            local callback,op,args
            E.LibraryAdapter.command=function(o,a,done) op,args,callback=o,a,done end
            local returned=0
            local page=E.StorageUI.show('folder',nil,function() returned=returned+1 end)
            page:onNext(); eq(page.focus,2); page:onPrevious(); eq(page.focus,1)
            ok(click(page,'/BookSync')); eq(op,'storage.folder'); eq(args.folder,'BookSync'); eq(page.busy,true)
            page:onClose(); eq(returned,1); local before=page[1]
            callback({folder='BookSync',freshness={saved=true}}); eq(page[1],before); eq(E.StorageUI.active,nil)
        end)
    end)
    test('collections: bounded pages open opaque source and Back restores Home',function()
        withHost(function()
            local read=E.LibraryAdapter.read
            E.LibraryAdapter.read=function(raw)
                local a=E.Cache.decode(raw)
                if a.op=='collections' then eq(a.limit,6); return {items={{key='opaque',title='Saved collection',count=3}},next=a.offset==0 and 6 or nil,freshness={saved=true}},400 end
                return read(raw)
            end
            local h=E.HomeHost.create(); E.HomeHost.active=h; W.shown={h}
            h:dispatch('collections',nil,{})
            local page=W.shown[#W.shown]; eq(page.metrics.rows,1)
            ok(click(page,'Next')); eq(page.offset,6); ok(click(page,'Previous')); eq(page.offset,0)
            ok(click(page,'Saved collection · 3 ›')); eq(h.filter.model.source.kind,'collection'); eq(h.filter.model.source.key,'opaque')
            h:onClose(); eq(h.list_layout,nil)
        end)
    end)
end

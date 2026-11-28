-- SPDX-License-Identifier: AGPL-3.0-or-later
return function(test,eq,ok,here,Cache)
    local root=here..'/../orbit.koplugin/'
    test('local completion: durable native revision replay and Undo use only Library commands',function()
        local saved,events={},{}
        local e=setmetatable({Cache=Cache,os={time=function() return 1800000000 end},now_s=function() return 1800000000 end,log=function() end},{__index=_G})
        e.LibraryAdapter={command=function(op,args,done,policy)
            eq(policy.kind,'device');events[#events+1]={op=op,args=Cache.copy(args)};done({revision=args.revision or 0});return true
        end,reset=function() end}
        setfenv(assert(loadfile(root..'logic/budgets.lua')),e)()
        setfenv(assert(loadfile(root..'ko/library.lua')),e)()
        local ui={doc_settings={readSetting=function(_,key) return saved[key] end,saveSetting=function(_,key,value) saved[key]=value end}}
        local status='complete'
        e.Library.nativeReader=function() return {digest=string.rep('a',32),summary={status=status}} end
        e.Library.localCompletion(ui,true);eq(#events,0)
        e.Library.localCompletion(ui);eq(#events,1);eq(events[1].op,'reading.local.event');ok(events[1].args.complete)
        local revision=events[1].args.revision
        e.Library.prepareLocalCompletion(ui);eq(#events,2);eq(events[2].args.revision,revision)
        status='reading';e.Library.localCompletion(ui);eq(events[3].args.revision,revision+1);eq(events[3].args.complete,false)
    end)
    test('local completion settings: one materialized local row within settings batch',function()
        local e=setmetatable({Cache=Cache,now_s=function() return 0 end,log=function() end},{__index=_G})
        local calls=0
        e.LibraryAdapter={read=function(request) local args=Cache.decode(request);eq(args.op,'reading.local');eq(args.limit,1);return {target=12,books_this_year=3},128 end,
            request=function(batch) eq(#batch,1);calls=calls+1;return true end}
        setfenv(assert(loadfile(root..'logic/budgets.lua')),e)()
        setfenv(assert(loadfile(root..'ko/library.lua')),e)()
        local p=e.Library.paint('settings-reading-statistics');eq(p:localReading().target,12)
        local m=p:flush();eq(calls,1);eq(m.rows,1);eq(m.bytes,128);eq(m.spawns,0);eq(m.network,0)
    end)
end

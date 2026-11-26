-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Loaded by the existing logic harness. Runtime logic remains on the companion.
return function(test, eq, ok, here, Cache)
    local root = here .. "/../orbit.koplugin/"
    local function source(path)
        local f=assert(io.open(path,"rb")); local s=f:read("*a"); f:close(); return s
    end
    test("reader display: unknown values, clamp, and ready stats", function()
        local e=setmetatable({}, {__index=_G})
        setfenv(assert(loadfile(root .. "logic/reader_panel.lua")),e)()
        local model=e.ReaderPanelPlan.model
        eq(model({items={}},{}).progress,nil)
        eq(model({items={{progress=-5}}},{}).progress,0)
        eq(model({items={{progress=150}}},{}).progress,1)
        eq(model({items={{progress=math.huge}}},{}).progress,nil)
        eq(model({items={{progress=0}}},{}).progress_text,"0% read")
        eq(model({items={{stats={reading_seconds=0,pages_read=0}}}},{}).time,"0 min reading time")
    end)
    test("library: all screens and starter widgets declare strict budgets", function()
        local e = setmetatable({}, {__index=_G}); setfenv(assert(loadfile(root .. "logic/budgets.lua")), e)()
        for _, name in ipairs({"home","library","details","series","settings","filter","editor","reader-top-panel"}) do
            local b=e.Budgets.get("screens",name); eq(b.spawns,0); eq(b.network,0); eq(b.roundTrips,1); ok(b.snapshotBytes<=16384)
        end
        for _, name in ipairs({"continue-reading","booklist","library"}) do ok(e.Budgets.get("widgets",name)) end
        eq(pcall(e.Budgets.get,"widgets","undeclared"), false)
    end)
    test("library: bounded ready rows, one batch for a Home paint, no network/fork", function()
        local sends, reads, logs = 0, 0, 0
        local e = setmetatable({Cache=Cache, now_s=function() return 1 end, log=function() logs=logs+1 end,
            LibraryAdapter={ read=function() reads=reads+1; return {items={{key="opaque"}},freshness={saved=true}},128 end,
                request=function(batch) sends=sends+1; eq(#batch,3); return true end}}, {__index=_G})
        setfenv(assert(loadfile(root .. "logic/budgets.lua")),e)()
        setfenv(assert(loadfile(root .. "ko/library.lua")),e)()
        local paint=e.Library.paint("home")
        local shelf=paint:widget("booklist")
        eq(shelf:window("reading",{},0,4).items[1].key,"opaque")
        paint:widget("continue-reading"):book("opaque")
        paint:widget("library"):counts()
        eq(sends,0); eq(reads,3)
        local m=paint:flush(); eq(sends,1); eq(m.roundTrips,1); eq(m.spawns,0); eq(m.network,0)
        eq(m.bytes,384); eq(m.rows,3); eq(logs,4)
        eq(pcall(paint.flush,paint),false)
        eq(pcall(shelf.window,shelf,"all"),false)
    end)
    test("library: missing windows, caller row limits, byte failures and deduplication", function()
        local batch
        local e=setmetatable({Cache=Cache,now_s=function() return 0 end,log=function() end,
            LibraryAdapter={read=function() end,request=function(b) batch=b; return true end}}, {__index=_G})
        setfenv(assert(loadfile(root .. "logic/budgets.lua")),e)(); setfenv(assert(loadfile(root .. "ko/library.lua")),e)()
        local p=e.Library.paint("library")
        eq(p:window("all",{},0,999).pending,true); p:window("all",{},0,999); p:flush()
        eq(#batch,1); eq(Cache.decode(batch[1]).limit,24)
        e.LibraryAdapter.read=function() return {items={{},{}}},128 end
        eq(pcall(function() e.Library.paint("library"):window("all",{},0,1) end),false)
        e.LibraryAdapter.read=function() return {items={}},16385 end
        eq(pcall(function() e.Library.paint("library"):window("all",{},0,1) end),false)
        e.LibraryAdapter.read=function() return {items={}},9000 end
        local page=e.Library.paint("home")
        page:widget("booklist"):window("reading")
        eq(pcall(function() page:widget("booklist"):counts() end),false,"combined widget snapshot is bounded")
    end)
    test("library: registry row budgets aggregate per instance and across Home", function()
        local e=setmetatable({Cache=Cache,now_s=function() return 0 end,log=function() end,
            LibraryAdapter={read=function()
                local items={}; for i=1,12 do items[i]={key=tostring(i)} end
                return {items=items},128
            end,request=function() return true end}}, {__index=_G})
        setfenv(assert(loadfile(root .. "logic/budgets.lua")),e)(); setfenv(assert(loadfile(root .. "ko/library.lua")),e)()
        local p=e.Library.paint("home")
        p:widget("booklist","first"):window("all",{},0,12)
        p:widget("booklist","second"):window("all",{},12,12)
        eq(p.metrics.rows,24,"instances have independent allowances")
        eq(pcall(function() p:widget("booklist","first"):window("all",{},24,12) end),false,"one instance cannot multiply its allowance")
        local q=e.Library.paint("home")
        for i=1,10 do q:widget("booklist",i):window("all",{},i*12,12) end
        eq(pcall(function() q:widget("booklist",11):window("all",{},132,12) end),false,"Home aggregate row cap")
        e.LibraryAdapter.read=function() return {total=2},128 end
        local r=e.Library.paint("home"):widget("library")
        r:counts(); eq(r.usage.rows,1,"summary is a materialized row")
    end)
    test("library: backend references cannot spread beyond adapters and frozen legacy seam", function()
        local baseline={}
        for line in io.lines(here .. "/library-legacy-boundary.txt") do baseline[line]=(baseline[line] or 0)+1 end
        local function backend(line)
            return line:find("/koreader/",1,true) or line:find("/api/",1,true)
                or line:find("bookorbit",1,true) or line:find("BookOrbit",1,true)
                or line:find("OC.client",1,true) or line:find("OC.owner",1,true)
                or line:find("client:request",1,true) or line:find("client:query",1,true)
                or line:find("require.*[\"']net[\"']")
                or line:find("readStatus",1,true) or line:find("progressPercentage",1,true)
                or line:find("smartScopeId",1,true) or line:find("seriesName",1,true)
                or line:find("thumbnailUrl",1,true) or line:find("detailUrl",1,true)
                or line:find("addedAt",1,true) or line:find("updatedAt",1,true)
                or line:find("lastReadAt",1,true) or line:find("libraryId",1,true)
                or line:find("collectionId",1,true) or line:find("seriesId",1,true)
                or line:find("seriesIndex",1,true) or line:find("downloadUrl",1,true)
                or line:find("userkey",1,true) or line:find("server_url",1,true)
        end
        local p=assert(io.popen('find "' .. root .. 'ko" -type f -name "*.lua"'))
        for path in p:lines() do
            local name=path:sub(#(root .. "ko/")+1)
            if name~="library_bookorbit.lua" and name~="bookorbit.lua" and name~="net.lua" then
                for line in io.lines(path) do
                    local code=line:gsub("%-%-.*$",""):match("^%s*(.-)%s*$")
                    if backend(code) then
                        local signature=name .. "\t" .. code
                        ok((baseline[signature] or 0)>0,"backend reference outside adapter: " .. name .. ": " .. code)
                        baseline[signature]=baseline[signature]-1
                    end
                end
            end
        end
        p:close()
        -- Removing legacy references is always allowed; adding another identical one is not.
    end)
end

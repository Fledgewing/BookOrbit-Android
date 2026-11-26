-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Included by the existing test_logic.lua harness.
return function(M, test, ok, eq, JSON)
local L,R,B=M.Layout,M.WidgetRegistry,M.Budgets
local codec={decode=function(s) return JSON.decode(s,true) end}
function codec.encode(v)
    if type(v) ~= "table" then return M.SleepPool.json(v) end
    local kind=(getmetatable(v) or {}).__jsontype
    if kind == "null" then return "null" end
    local parts={}
    if kind == "array" or v[1] ~= nil then
        for i,x in ipairs(v) do parts[i]=codec.encode(x) end
        return "["..table.concat(parts,",").."]"
    end
    local keys={}; for k in pairs(v) do keys[#keys+1]=k end; table.sort(keys)
    for _,k in ipairs(keys) do parts[#parts+1]=M.SleepPool.json(k)..":"..codec.encode(v[k]) end
    return "{"..table.concat(parts,",").."}"
end
local function valid(d) local v,e=L.validate(d); ok(v,e); return d end
local function round(d) return assert(L.parse(assert(L.serialize(d,codec)),codec)) end
local function bad(change)
    local d=L.default(); change(d); eq(L.validate(d),nil)
end
local function tile(id,w,x,y,c,r)
    return {instance=id,widget=w,version=1,x=x,y=y,w=c,h=r,settings={}}
end
local function empty()
    local d=L.default(); d.pages={ {id="one",tab="Home",name="Page 1",placements={}} }; return d
end
local function projected(d,page)
    local resolved=assert(L.resolve(d,"android-tablet",R)); return resolved.pages[page or 1]
end

test("layout: approved M8C Home and Stats defaults are exact, independent copies",function()
    local d=valid(L.default()); eq(#d.pages,2); eq(d.grids["android-tablet"].cols,4); eq(d.grids["android-tablet"].rows,8)
    eq(d.pages[1].name,"Home"); eq(d.pages[2].name,"Stats")
    local expected={{"continue-reading",0,0,4,3},{"booklist",0,3,2,2},{"lists",2,3,2,3},{"library",0,5,2,1},{"booklist",0,6,2,2},{"booklist",2,6,2,2}}
    for i,e in ipairs(expected) do local p=d.pages[1].placements[i]
        eq(p.widget,e[1]); eq(p.x,e[2]); eq(p.y,e[3]); eq(p.w,e[4]); eq(p.h,e[5])
    end
    eq(d.pages[1].placements[2].settings.sort,3); eq(d.pages[1].placements[2].settings.title,"Also reading"); eq(d.pages[1].placements[6].settings.src,"wtr")
    eq(d.pages[2].placements[1].w,4); eq(d.pages[2].placements[1].h,3)
    local stats={{"year-in-reading",0,0,4,3},{"battery",0,3,2,2},{"when-you-read",2,3,2,2},
        {"this-week",0,5,2,3},{"reading-records",2,5,2,3}}
    for i,e in ipairs(stats) do local p=d.pages[2].placements[i]
        eq(p.widget,e[1]); eq(p.x,e[2]); eq(p.y,e[3]); eq(p.w,e[4]); eq(p.h,e[5])
    end
    d.pages[1].placements[1].x=9; eq(L.default().pages[1].placements[1].x,0)
    valid(round(L.default()))
end)

test("layout: schema, types, IDs, cardinalities and resource bounds",function()
    bad(function(d) d.schemaVersion=2 end); bad(function(d) d.revision=0 end)
    bad(function(d) d.pages={} end); bad(function(d) d.pages[2].id=d.pages[1].id end)
    bad(function(d) d.pages[2].placements[1].instance="resume" end)
    bad(function(d) d.pages[1].tab="Stats" end); bad(function(d) d.pages[1].named="true" end)
    bad(function(d) d.pages[1].id=string.rep("x",81) end)
    for _,k in ipairs({"x","y","w","h","version"}) do
        bad(function(d) d.pages[1].placements[1][k]="1" end)
        bad(function(d) d.pages[1].placements[1][k]=1.5 end)
    end
    bad(function(d) d.pages[1].placements[1].settings=false end)
    bad(function(d) d.grids.x3.rows=13 end); bad(function(d) d.grids["android-tablet"].cols=2 end)
    bad(function(d) d.grids.x4=nil end); bad(function(d) d.pages[1].placements[1].w=0 end)
    bad(function(d) d.pages[1].placements[1].settings.fn=function() end end)
    bad(function(d) d.cycle=d end)
    bad(function(d) for i=3,17 do d.pages[i]={id="p"..i,tab="More",placements={}} end end)
    bad(function(d) d.pages[1].placements={}; for i=1,129 do d.pages[1].placements[i]=tile("t"..i,"future",0,0,1,1) end end)
    eq(L.parse(string.rep(" ",131073),codec),nil)
    eq(L.parse('{"schemaVersion":1} trailing',codec),nil)
    local d=L.default(); d.unknown=string.rep("x",131072); eq(L.serialize(d,codec),nil)
    local raw=codec.encode(L.default())
    eq(L.parse(raw:gsub('"settings":{}','"settings":[]',1),codec),nil)
    eq(L.parse(raw:gsub('"settings":{}','"settings":null',1),codec),nil)
    eq(L.parse(raw:gsub('"placements":%[.-%]','"placements":{}',1),codec),nil)
end)

test("layout: class bounds, overlap, installed spans, hidden and unknown versions",function()
    bad(function(d) d.pages[1].placements[1].x=1 end)
    bad(function(d) d.pages[1].placements[4].y=4 end)
    bad(function(d) d.pages[1].placements[1].w=3 end)
    bad(function(d) d.overrides["android-tablet"]={resume={h=2.5}} end)
    local d=L.default(); d.pages[1].placements[1].widget="future"; d.pages[1].placements[1].w=3
    valid(d); local out=assert(L.resolve(d,"android-tablet",R)); eq(#out.pages[1].placements,5)
    d.pages[1].placements[1].widget="continue-reading"; d.pages[1].placements[1].version=2
    valid(d); eq(#assert(L.resolve(d,"android-tablet",R)).pages[1].placements,5)
    d=L.default(); d.pages[1].placements[1].hidden="future field"; valid(d); eq(#projected(d).placements,6)
    d.overrides["android-tablet"].resume={hidden=true}
    eq(#assert(L.resolve(d,"android-tablet",R)).pages[1].placements,5)
    eq(L.resolve(d,"absent",R),nil)
end)

test("layout: resolution overlays settings, gates capabilities, never mutates base",function()
    local d=L.default(); d.overrides["android-tablet"].resume={h=2,settings={choice="new"}}
    d.pages[1].placements[1].settings.old="keep"
    local before=codec.encode(d); local registry=L.copy(R); registry["continue-reading"].capabilities={"progress.read"}
    local a=assert(L.resolve(d,"android-tablet",registry,{})); eq(#a.pages[1].placements,5)
    a=assert(L.resolve(d,"android-tablet",registry,{["progress.read"]=true}))
    eq(a.pages[1].placements[1].h,2); eq(a.pages[1].placements[1].settings.old,"keep")
    eq(a.pages[1].placements[1].settings.choice,"new"); a.pages[1].placements[1].settings.old="changed"
    eq(codec.encode(d),before)
    d.overrides.x4.resume={x=0,y=0,w=2,h=2,settings={future=true},unknown={1,2}}
    valid(d); eq(round(d).overrides.x4.resume.unknown[2],2)
end)

test("layout: round trip retains unknown widgets, versions, fields, nulls and settings",function()
    local d=assert(L.parse(codec.encode(L.default()),codec)); local p=d.pages[1].placements[1]
    p.widget="future-widget"; p.version=987; p.hidden="unknown base field"; p.extra=codec.decode('{"emptyArray":[],"emptyObject":{},"null":null,"flag":false}')
    p.settings=codec.decode('{"nested":{"preserve":[null,false,{},[]]}}')
    d.grids.future={cols=3,rows=12,custom="keep"}; d.overrides.future={resume={custom={a=1}}}
    local raw=assert(L.serialize(d,codec)); local saved=round(d)
    eq(codec.encode(saved),codec.encode(d)); ok(raw:find('"emptyArray":%[%]')); ok(raw:find('"emptyObject":{}')); ok(raw:find('"null":null')); eq(#saved.pages[1].placements[1].settings.nested.preserve,4)
end)

test("layout: minimal-band swap mirrors prototype and preserves base and unrelated page",function()
    local d=empty(); d.pages[1].placements={tile("hero","continue-reading",0,0,4,3),
        tile("records","reading-records",0,3,4,1),tile("also","booklist",0,4,2,2),
        tile("lists","lists",2,4,2,3),tile("lib","library",0,6,2,1)}
    valid(d); local before=codec.encode(d)
    local moved=assert(L.move(d,"one","records",0,1)); valid(moved)
    local pg=projected(moved); eq(pg.placements[2].y,6); eq(pg.placements[3].y,3); eq(pg.placements[4].y,3); eq(pg.placements[5].y,5)
    eq(codec.encode(d),before); eq(moved.pages[1],d.pages[1]); eq(moved.revision,d.revision+1)
    local back=assert(L.move(moved,"one","records",0,-1)); eq(projected(back).placements[2].y,3)
    eq(L.move(d,"one","hero",0,-1),nil); eq(L.move(d,"one","hero",1,1),nil)
end)

test("layout: blocked moves offer another page; resize relocates or rejects atomically",function()
    local d=empty(); d.pages[1].placements={tile("lib","library",0,0,1,1),tile("battery","battery",0,1,2,1),tile("clock","clock",1,0,1,2)}
    -- Clock overlaps battery, so use unknown 1x1 neighbour (valid reserved placement).
    d.pages[1].placements[3]=tile("other","future",1,0,1,1); valid(d)
    local before=codec.encode(d); local moved,why=L.move(d,"one","lib",0,1)
    eq(moved,nil); ok(why:find("move to page")); eq(codec.encode(d),before)
    local r=assert(L.resize(d,"one","lib",2,2)); valid(r)
    local p=projected(r).placements[1]; eq(p.w,2); ok(p.y >= 2)
    eq(L.resize(d,"one","lib",3,3),nil); eq(L.resize(d,"one","absent",2,2),nil)
    eq(L.resize(L.default(),"home","library",2,2),nil,"packed page has no alternate room")
end)

test("layout: add/remove/page operations, auto names, hand names, override cleanup and reset",function()
    local d=empty(); local p=tile("b","booklist",0,0,2,2); p.settings.title="My books"
    d=assert(L.add(d,"one",p)); eq(d.pages[1].name,"My books"); p.settings.title="outside"; eq(d.pages[1].placements[1].settings.title,"My books")
    eq(L.add(d,"one",p),nil)
    local collision=tile("collision","booklist",0,0,2,2)
    local added=assert(L.add(d,"one",collision)); eq(projected(added).placements[2].x,2)
    valid(added); eq(L.add(L.default(),"home",collision),nil)
    d=assert(L.page(d,"rename","one","Mine"))
    d=assert(L.remove(d,"one","b")); p.instance="c"; d=assert(L.add(d,"one",p)); eq(d.pages[1].name,"Mine")
    d=assert(L.page(d,"add","two")); eq(d.pages[2].name,"Page 2")
    d=assert(L.add(d,"two",tile("power","battery",0,0,2,2))); eq(d.pages[2].name,"Stats")
    d=assert(L.page(d,"reorder","two",1)); eq(d.pages[1].id,"two")
    d.overrides.x4.power={hidden=true}; d=assert(L.page(d,"remove","two")); eq(d.overrides.x4.power,nil)
    eq(L.page(d,"remove","one"),nil); eq(L.page(d,"rename","one",""),nil); eq(L.page(d,"add","one"),nil)
    d.overrides.x4.c={hidden=true}; d=assert(L.remove(d,"one","c")); eq(d.overrides.x4.c,nil)
    eq(L.remove(d,"one","missing"),nil); eq(L.page(d,"reorder","one",9),nil)
    local reset=L.reset(d); valid(reset); eq(reset.revision,d.revision+1); eq(reset.pages[1].name,"Home")
end)

test("layout: atomic storage failures keep previous valid primary/backup and explain fallback",function()
    local files={}; local fail; local writes={}
    local io={readFile=function(p,max) return files[p] and files[p]:sub(1,max) end,
        writeFile=function(p,s) writes[#writes+1]=p; if p == fail then return false end; files[p]=s; return true end}
    local d,why=L.load("layout",io,codec); eq(why,"No saved layout; using default"); valid(d)
    ok(L.save("layout",d,io,codec)); local old=files.layout
    d=L.reset(d); ok(L.save("layout",d,io,codec)); eq(files["layout.bak"],old)
    eq(writes[#writes-1],"layout.bak"); eq(writes[#writes],"layout")
    local current=files.layout; fail="layout.bak"; eq(L.save("layout",L.reset(d),io,codec),nil); eq(files.layout,current)
    fail="layout"; eq(L.save("layout",L.reset(d),io,codec),nil); eq(files.layout,current)
    local invalid=L.default(); invalid.schemaVersion=2; eq(L.save("layout",invalid,io,codec),nil); eq(files.layout,current)
    files.layout="bad JSON"; local recovered,reason=L.load("layout",io,codec); eq(recovered.revision,d.revision); ok(reason:find("Recovered"))
    fail=nil; ok(L.save("layout",L.reset(recovered),io,codec)); eq(files["layout.bak"],current,"corrupt primary never replaces valid backup")
    files.layout="bad"; files["layout.bak"]="bad"; local fallback,msg=L.load("layout",io,codec); eq(msg,"Invalid layout; using default"); valid(fallback)
end)

test("layout: deterministic fuzz moves/resizes retain invariants and validate only edited page",function()
    local d=L.default(); local seed=127; local calls=0; local original=L.pageValid
    local function rand(n) seed=(seed*16807)%2147483647; return seed%n+1 end
    local dirs={{1,0},{-1,0},{0,1},{0,-1}}
    for step=1,1200 do
        local pi=rand(#d.pages); local pg=projected(d,pi); local p=pg.placements[rand(#pg.placements)]
        local old=codec.encode(d); local result
        L.pageValid=function(page,...)
            eq(page.id,pg.id,"only edited page validated"); calls=calls+1; return original(page,...)
        end
        if rand(2) == 1 then local dir=dirs[rand(4)]; result=L.move(d,pg.id,p.instance,dir[1],dir[2])
        else local sizes=R[p.widget].sizes["android-tablet"]; local s=sizes[rand(#sizes)]; result=L.resize(d,pg.id,p.instance,s[1],s[2]) end
        L.pageValid=original
        eq(codec.encode(d),old,"pure edit"); if result then d=result end
        valid(d); local resolved=assert(L.resolve(d,"android-tablet",R)); for _,page in ipairs(resolved.pages) do ok(original(page,resolved.grid,"android-tablet",R)) end
    end
    ok(calls > 400)
end)

test("layout: save codec receives typed empty maps without changing input",function()
    local d=L.default()
    eq(getmetatable(d.pages[1].placements[1].settings),nil)
    local saw=false
    local strict={decode=codec.decode,encode=function(value)
        eq(getmetatable(value.pages[1].placements[1].settings).__jsontype,"object")
        eq(getmetatable(value.overrides.x3).__jsontype,"object")
        eq(getmetatable(value.pages).__jsontype,"array")
        saw=true; return codec.encode(value)
    end}
    ok(L.serialize(d,strict)); ok(saw)
    eq(getmetatable(d.pages[1].placements[1].settings),nil)
end)

test("editor session: pure page naming, bounded limits and unpublished failures",function()
    local d=empty(); local before=codec.encode(d)
    local session=M.HomeEditorPlan.new(d)
    ok(session:add("booklist",1,2)); eq(codec.encode(d),before)
    eq(session:page().name,"Book list"); eq(session:page().placements[1].x,1)
    ok(session:pageAction("rename","Chosen")); ok(session:remove())
    ok(session:add("continue-reading")); eq(session:page().name,"Chosen")
    ok(session:pageAction("add")); eq(session.index,2)
    ok(session:add("lists")); eq(session:page().name,"Lists")
    for i=3,L.MAX_PAGES do ok(session:pageAction("add")) end
    local full=session.document
    eq(session:pageAction("add"),nil); eq(session.document,full)
    eq(session:pageAction("reorder",17),nil); eq(session.document,full)
    eq(session:add("not-installed"),nil); eq(session.document,full)
    valid(session.document)
    ok(session:reset()); eq(session.index,1); eq(session.selected,nil)
end)

test("budgets: every screen/widget/query declares and enforces deterministic limits",function()
    local zero={rows=0,bytes=0,spawns=0,roundTrips=0,network=0,snapshotBytes=0}
    local function check(b,widget)
        local baseline=L.copy(zero); if b.drawNodes then baseline.drawNodes=0 end
        ok(B.check(b,baseline)); ok(b.targetMs > 0); ok(b.bytes <= (widget and 16384 or 131072)); ok(b.rows <= (widget and 12 or 128))
        for k,limit in pairs(zero) do
            local counts=L.copy(baseline); counts[k]=b[k]+1; eq(B.check(b,counts),nil,"exceeded "..k)
            counts=L.copy(baseline); counts[k]=nil; eq(B.check(b,counts),nil,"missing "..k)
        end
    end
    for _,id in ipairs({"home","library","details","series","settings","filter","editor","reader-top-panel"}) do check(B.screens[id]) end
    for _,b in pairs(B.screens) do check(b) end
    check(B.libraryWindow)
    for id,w in pairs(R) do
        eq(w.id,id); check(w.budget,true); eq(w.budget,B.widgets[id]); eq(#w.states,6)
        for _,need in ipairs(w.dataNeeds) do
            eq(need.budget,w.budget); ok(need.source:match("^[a-z]+%.[a-z]+$")); ok(need.params.limit.maximum <= w.budget.rows)
        end
    end
    eq(B.check(nil,zero),nil); local log; local now=1
    local finish=B.span("home.paint",function() return now end,function(line) log=line end)
    now=1.125; finish(); eq(log,"BookSync home.paint 125.0 ms")
end)
end

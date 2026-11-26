-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Versioned layout-as-data. Pure: codecs and atomic storage are injected at the boundary.
Layout = { MAX_BYTES=131072, MAX_PAGES=16, MAX_PLACEMENTS=128, MAX_ROWS=12 }
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}; for k, x in pairs(v) do out[k] = copy(x) end
    return setmetatable(out, getmetatable(v))
end
Layout.copy = copy
local function shallow(v)
    local out={}; for k,x in pairs(v) do out[k]=x end
    return setmetatable(out,getmetatable(v))
end
local function arr(v) return setmetatable(v or {},{__jsontype="array"}) end
local function object(v)
    if type(v) ~= "table" or ((getmetatable(v) or {}).__jsontype == "array" or (getmetatable(v) or {}).__jsontype == "null") then return false end
    for k in pairs(v) do if type(k) ~= "string" then return false end end
    return true
end
local function array(v)
    if type(v) ~= "table" or ((getmetatable(v) or {}).__jsontype == "object" or (getmetatable(v) or {}).__jsontype == "null") then return false end
    local n=0; for k in pairs(v) do
        if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then return false end; n=n+1
    end
    return n == #v
end
local function integer(n, lo, hi)
    return type(n) == "number" and n == math.floor(n) and n >= lo and n <= (hi or 2147483647)
end
local function text(s, max) return type(s) == "string" and #s > 0 and #s <= (max or 80) end
-- Bounded JSON-compatible values, including unknown fields. No functions or cycles, and no
-- unbounded settings trees. Full byte limit is checked by parse/serialize at the boundary.
local function tree(v, seen, depth, count)
    count.n=count.n+1
    if depth > 24 or count.n > 32768 then return false end
    local t=type(v)
    if t == "string" then return #v <= Layout.MAX_BYTES end
    if t == "number" then return v == v and math.abs(v) < math.huge end
    if t == "boolean" then return true end
    if t ~= "table" or seen[v] then return false end
    seen[v]=true
    for k,x in pairs(v) do
        if (type(k) ~= "string" and not integer(k,1)) or not tree(x,seen,depth+1,count) then return false end
    end
    seen[v]=nil; return true
end
local tabs={Home=true, Insights=true, Library=true, More=true}
local function coords(p, partial)
    for _,k in ipairs({"x","y","w","h"}) do
        if (not partial or p[k] ~= nil) and not integer(p[k], (k == "x" or k == "y") and 0 or 1, 12) then return false end
    end
    return (p.settings == nil and partial or object(p.settings))
        and (not partial or p.hidden == nil or type(p.hidden) == "boolean")
end
local function overlap(a,b)
    return a.x < b.x+b.w and b.x < a.x+a.w and a.y < b.y+b.h and b.y < a.y+a.h
end
local function supported(p, class, registry)
    local w=registry[p.widget]
    if not w or w.version ~= p.version then return true end
    for _,s in ipairs(w.sizes[class] or {}) do if s[1] == p.w and s[2] == p.h then return true end end
    return false
end
-- At most 12*12 occupied cells and 128 placements; no pairwise overlap scan.
function Layout.pageValid(page, grid, class, registry)
    local cells={}
    for _,p in ipairs(page.placements) do
        if not p.hidden then
            if p.x+p.w > grid.cols or p.y+p.h > grid.rows then return nil, "outside grid: " .. p.instance end
            if not supported(p,class,registry or WidgetRegistry) then return nil, "unsupported span: " .. p.instance end
            for y=p.y,p.y+p.h-1 do for x=p.x,p.x+p.w-1 do
                local key=y*12+x
                if cells[key] then return nil, "overlap: " .. p.instance end
                cells[key]=true
            end end
        end
    end
    return true
end
local function projection(page, overrides, geometryOnly)
    local out=shallow(page); out.placements=arr()
    for i,p in ipairs(page.placements) do out.placements[i]=geometryOnly and shallow(p) or copy(p) end
    for _,p in ipairs(out.placements) do
        -- hidden is defined only in class overrides. A same-named unknown base field
        -- remains in the saved document but cannot change projection semantics.
        p.hidden=nil
        for k,v in pairs(overrides[p.instance] or {}) do
            if k == "settings" and not geometryOnly then
                for sk,sv in pairs(v) do p.settings[sk]=copy(sv) end
            elseif k == "x" or k == "y" or k == "w" or k == "h" or k == "hidden" then p[k]=copy(v) end
        end
    end
    return out
end
-- Android is the only implemented projection. Unsupported class overrides are shape-checked
-- and preserved, not rejected for Android coordinates; future hosts opt into their classes.
function Layout.validate(d, registry, classes)
    if not object(d) or not tree(d,{},0,{n=0}) then return nil,"invalid document" end
    if d.schemaVersion ~= 1 or not integer(d.revision,1) then return nil,"unsupported schema/revision" end
    if not object(d.grids) or not object(d.overrides) or not array(d.pages)
        or #d.pages < 1 or #d.pages > 16 then return nil,"invalid grids/pages/overrides" end
    for _,c in ipairs({"android-tablet","x4","x3"}) do if not d.grids[c] then return nil,"missing grid: "..c end end
    for c,g in pairs(d.grids) do
        if not text(c) or not object(g) or not integer(g.cols,1,12) or not integer(g.rows,1,12) then return nil,"invalid grid: "..c end
    end
    if d.grids["android-tablet"].cols ~= 4 then return nil,"android-tablet requires four columns" end
    local pages, instances, n={},{},0
    for _,p in ipairs(d.pages) do
        if not object(p) or not text(p.id) or pages[p.id] or not tabs[p.tab] or not array(p.placements)
            or (p.name ~= nil and not text(p.name,80)) or (p.named ~= nil and type(p.named) ~= "boolean") then return nil,"invalid/duplicate page" end
        pages[p.id]=true
        for _,t in ipairs(p.placements) do
            n=n+1
            if n > 128 or not object(t) or not text(t.instance) or instances[t.instance] or not text(t.widget)
                or not integer(t.version,1) or not coords(t,false) then return nil,"invalid/duplicate placement" end
            instances[t.instance]=true
        end
    end
    for class,over in pairs(d.overrides) do
        if not text(class) or not object(over) then return nil,"invalid class override" end
        for id,o in pairs(over) do
            if not text(id) or not object(o) or not coords(o,true) then return nil,"invalid instance override" end
        end
    end
    for _,class in ipairs(classes or {"android-tablet"}) do
        local g=d.grids[class]; if not g then return nil,"missing class grid" end
        for _,p in ipairs(d.pages) do
            local ok,err=Layout.pageValid(projection(p,d.overrides[class] or {}),g,class,registry)
            if not ok then return nil,err end
        end
    end
    return true
end
function Layout.resolve(d, class, registry, capabilities)
    registry=registry or WidgetRegistry
    local g=d.grids[class]; if not g then return nil,"unknown class" end
    local out={grid=copy(g),pages={}}
    for _,page in ipairs(d.pages) do
        local p=projection(page,d.overrides[class] or {}); local visible={}
        for _,t in ipairs(p.placements) do
            local w=registry[t.widget]; local allowed=w and w.version == t.version and not t.hidden
            for _,need in ipairs(w and w.capabilities or {}) do
                if not (capabilities or {})[need] then allowed=false end
            end
            if allowed then visible[#visible+1]=t end
        end
        p.placements=visible
        local ok,err=Layout.pageValid(p,g,class,registry); if not ok then return nil,err end
        out.pages[#out.pages+1]=p
    end
    return out
end
-- codec.decode must be strict, retain JSON null and object/array distinctions (including
-- empty tables), and reject trailing input. codec.encode must retain those distinctions.
-- Production host supplies KOReader's JSON codec with those options, outside reading.
function Layout.parse(raw, codec, registry)
    if type(raw) ~= "string" or #raw > Layout.MAX_BYTES then return nil,"layout exceeds 128 KiB" end
    local ok,d=pcall(codec.decode,raw)
    if not ok then return nil,"invalid JSON" end
    local valid,err=Layout.validate(d,registry); if not valid then return nil,err end
    return d
end
function Layout.serialize(d, codec, registry)
    local valid,err=Layout.validate(d,registry); if not valid then return nil,err end
    local ok,raw=pcall(codec.encode,d)
    if not ok or type(raw) ~= "string" or #raw > Layout.MAX_BYTES then return nil,"invalid/oversized encoding" end
    -- Verify the exact encoded representation, including empty objects and arrays.
    local decoded,why=Layout.parse(raw,codec,registry); if not decoded then return nil,why end
    return raw
end
local function placement(id,w,x,y,c,r,settings)
    return {instance=id,widget=w,version=1,x=x,y=y,w=c,h=r,settings=settings or {}}
end
function Layout.default()
    local function books(id,title,src,x,y)
        return placement(id,"booklist",x,y,2,2,{title=title,src=src,style=src == "reading" and 1 or 0,sort=src == "reading" and 3 or 0,cap=src == "recent" and 1 or src == "reading" and 2 or 0})
    end
    return {schemaVersion=1,revision=1,grids={ ["android-tablet"]={cols=4,rows=8},x4={cols=2,rows=7},x3={cols=2,rows=7}},
        overrides={ ["android-tablet"]={},x4={},x3={} },pages=arr({
        {id="home",tab="Home",name="Home",placements=arr({
            placement("resume","continue-reading",0,0,4,3),books("also","Also reading","reading",0,3),
            placement("lists","lists",2,3,2,3),placement("library","library",0,5,2,1),
            books("recent","Recently added","recent",0,6),books("want","Want to read","wtr",2,6)})},
        {id="stats",tab="Insights",name="Stats",placements=arr({
            placement("year","year-in-reading",0,0,4,3),placement("battery","battery",0,3,2,2),
            placement("hours","when-you-read",2,3,2,2),placement("week","this-week",0,5,2,3),
            placement("records","reading-records",2,5,2,3)})}})}
end
-- Copy-on-write edits: trusted validated input; unchanged pages/settings are shared and MUST
-- be treated as immutable by callers. No full-layout validation/encoding on arrow presses.
local function edit(d, pageId, class)
    class=class or "android-tablet"
    if class ~= "android-tablet" then return nil,"class editor unavailable" end
    local out={}; for k,v in pairs(d) do out[k]=v end
    out.pages=arr({unpack(d.pages)}); out.revision=d.revision+1
    for i,p in ipairs(d.pages) do if p.id == pageId then
        local pg=projection(p,d.overrides[class] or {},true)
        out.pages[i]=pg
        -- Only changed class geometry is committed to overrides by finish().
        return out,pg,i
    end end
    return nil,"unknown page"
end
local function find(pg,id) for i,t in ipairs(pg.placements) do if t.instance == id then return t,i end end end
local function finish(d,out,pg,index,class,registry)
    class=class or "android-tablet"
    local ok,err=Layout.pageValid(pg,d.grids[class],class,registry); if not ok then return nil,err end
    -- Keep base semantic data/coordinates intact for existing instances. New/removal operations
    -- update the semantic list separately; spatial edits live in the current class override.
    out.pages[index]=d.pages[index]
    out.overrides={}; for c,v in pairs(d.overrides) do out.overrides[c]=v end
    local over=shallow(d.overrides[class] or {}); out.overrides[class]=over
    for _,p in ipairs(pg.placements) do
        local o=shallow(over[p.instance] or {}); over[p.instance]=o
        for _,k in ipairs({"x","y","w","h"}) do o[k]=p[k] end
    end
    return out
end
local function fits(pg,g,t,x,y,w,h)
    if x < 0 or y < 0 or x+w > g.cols or y+h > g.rows then return false end
    for _,u in ipairs(pg.placements) do
        if u ~= t and not u.hidden and overlap({x=x,y=y,w=w,h=h},u) then return false end
    end
    return true
end
function Layout.move(d,pageId,id,dx,dy,class,registry)
    if not ((dx == 0 and (dy == 1 or dy == -1)) or (dy == 0 and (dx == 1 or dx == -1))) then return nil,"one-cell direction required" end
    local out,pg,index=edit(d,pageId,class); if not out then return nil,pg end
    local t=find(pg,id); if not t or t.hidden then return nil,"unknown/hidden instance" end
    local g=d.grids[class or "android-tablet"]
    local vertical=dy ~= 0; local a=vertical and "y" or "x"; local s=vertical and "h" or "w"
    local c=vertical and "x" or "y"; local cs=vertical and "w" or "h"; local dir=vertical and dy or dx
    if t[a]+dir < 0 or t[a]+t[s]+dir > (vertical and g.rows or g.cols) then return nil,"page edge" end
    if fits(pg,g,t,t.x+dx,t.y+dy,t.w,t.h) then t.x=t.x+dx; t.y=t.y+dy
    else
        local b0=dir > 0 and t[a]+t[s] or t[a]-1; local b1=b0; local band
        -- Far edge expands at most grid extent (<=12), hence O(placements), not O(n²).
        for _=1,12 do
            band={}; local nb=b1
            for _,u in ipairs(pg.placements) do
                if u ~= t and not u.hidden and u[c] < t[c]+t[cs] and u[c]+u[cs] > t[c]
                    and u[a] <= math.max(b0,b1) and u[a]+u[s]-1 >= math.min(b0,b1) then
                    band[#band+1]=u
                    nb=dir > 0 and math.max(nb,u[a]+u[s]-1) or math.min(nb,u[a])
                end
            end
            if nb == b1 then break end; b1=nb
        end
        if #band == 0 then return nil,"move to page" end
        for _,u in ipairs(band) do u[a]=u[a]-dir*t[s] end
        t[a]=t[a]+dir*(math.abs(b1-b0)+1)
    end
    local result,err=finish(d,out,pg,index,class,registry)
    if not result then return nil,"move to page: "..err end
    return result
end
function Layout.resize(d,pageId,id,w,h,class,registry)
    local out,pg,index=edit(d,pageId,class); if not out then return nil,pg end
    local t=find(pg,id); if not t or t.hidden then return nil,"unknown/hidden instance" end
    if not integer(w,1,12) or not integer(h,1,12) then return nil,"invalid size" end
    local reg=registry or WidgetRegistry; local trial=copy(t); trial.w=w; trial.h=h
    if not supported(trial,class or "android-tablet",reg) then return nil,"unsupported span" end
    local g=d.grids[class or "android-tablet"]
    local x,y=t.x,t.y
    if not fits(pg,g,t,x,y,w,h) then
        x=nil
        -- Same x-major search as the prototype; bounded by 144 grid cells.
        for xx=0,g.cols-w do
            for yy=0,g.rows-h do if fits(pg,g,t,xx,yy,w,h) then x,y=xx,yy; break end end
            if x then break end
        end
    end
    if not x then return nil,"no room" end
    t.x=x; t.y=y; t.w=w; t.h=h
    return finish(d,out,pg,index,class,registry)
end
local function autoname(pg)
    if pg.named or not (pg.name or ""):match("^Page %d+$") or not pg.placements[1] then return end
    local t=pg.placements[1]
    local names={["continue-reading"]="Reading",lists="Lists",library="Library",battery="Stats",
        ["year-in-reading"]="Stats",["this-week"]="Stats",["when-you-read"]="Stats",["reading-records"]="Stats",clock="Clock"}
    local name=t.widget == "booklist" and t.settings.title or names[t.widget]
    if text(name,80) then pg.name=name end
end
function Layout.add(d,pageId,p,registry)
    local out,pg,index=edit(d,pageId); if not out then return nil,pg end
    if not object(p) or not text(p.instance) or not text(p.widget) or not integer(p.version,1) or not coords(p,false) or not tree(p,{},0,{n=0}) then return nil,"invalid placement" end
    local count=0
    for _,page in ipairs(d.pages) do for _,t in ipairs(page.placements) do
        count=count+1; if t.instance == p.instance then return nil,"duplicate instance" end
    end end
    if count >= 128 then return nil,"placement limit" end
    local placed=copy(p); local grid=d.grids["android-tablet"]
    if not supported(placed,"android-tablet",registry or WidgetRegistry) then return nil,"unsupported span" end
    if not fits(pg,grid,nil,placed.x,placed.y,placed.w,placed.h) then
        local found=false
        -- Add uses the requested slot first, then row-major free space as in the picker.
        for y=0,grid.rows-placed.h do
            for x=0,grid.cols-placed.w do
                if fits(pg,grid,nil,x,y,placed.w,placed.h) then placed.x=x; placed.y=y; found=true; break end
            end
            if found then break end
        end
        if not found then return nil,"no room" end
    end
    local geometry=shallow(placed); geometry.hidden=nil
    pg.placements[#pg.placements+1]=geometry
    local ok,err=Layout.pageValid(pg,grid,"android-tablet",registry); if not ok then return nil,err end
    pg=copy(d.pages[index]); pg.placements[#pg.placements+1]=placed; autoname(pg); out.pages[index]=pg
    return out
end
function Layout.remove(d,pageId,id)
    local out,pg,index=edit(d,pageId); if not out then return nil,pg end
    local _,i=find(pg,id); if not i then return nil,"unknown instance" end
    pg=copy(d.pages[index]); table.remove(pg.placements,i); out.pages[index]=pg
    out.overrides=copy(d.overrides); for _,over in pairs(out.overrides) do over[id]=nil end
    return out
end
function Layout.page(d,op,id,value)
    local out={}; for k,v in pairs(d) do out[k]=v end
    out.pages=arr({unpack(d.pages)}); out.revision=d.revision+1
    local index; for i,p in ipairs(d.pages) do if p.id == id then index=i end end
    if op == "add" then
        if index or not text(id) or #out.pages >= 16 then return nil,"invalid/new page limit" end
        out.pages[#out.pages+1]={id=id,tab="More",name="Page "..(#out.pages+1),placements=arr()}
    elseif not index then return nil,"unknown page"
    elseif op == "remove" then
        if #out.pages == 1 then return nil,"last page" end
        out.overrides=copy(d.overrides)
        for _,p in ipairs(out.pages[index].placements) do for _,over in pairs(out.overrides) do over[p.instance]=nil end end
        table.remove(out.pages,index)
    elseif op == "rename" then
        if not text(value,80) then return nil,"invalid page name" end
        out.pages[index]=copy(out.pages[index]); out.pages[index].name=value; out.pages[index].named=true
    elseif op == "reorder" then
        if not integer(value,1,#out.pages) then return nil,"invalid page position" end
        table.insert(out.pages,value,table.remove(out.pages,index))
    else return nil,"unknown page operation" end
    return out
end
function Layout.reset(d) local out=Layout.default(); out.revision=(d and d.revision or 0)+1; return out end
-- Storage callbacks read(path,maxBytes), writeFile(path,bytes)->boolean. Reuse OC.readFile /
-- OC.writeFile (ko/cache.lua:40-60) from a non-reading host, or companion equivalents.
-- writeFile MUST publish atomically. Backup is published before the new primary.
function Layout.load(path, io, codec, registry)
    local raw=io.readFile(path,Layout.MAX_BYTES+1)
    local d,err=Layout.parse(raw,codec,registry)
    if d then return d end
    local backup=Layout.parse(io.readFile(path..".bak",Layout.MAX_BYTES+1),codec,registry)
    if backup then return backup,"Recovered previous valid layout: "..tostring(err) end
    return Layout.default(), raw and "Invalid layout; using default" or "No saved layout; using default"
end
function Layout.save(path,d,io,codec,registry)
    local raw,err=Layout.serialize(d,codec,registry); if not raw then return nil,err end
    local old=io.readFile(path,Layout.MAX_BYTES+1)
    if Layout.parse(old,codec,registry) and not io.writeFile(path..".bak",old) then return nil,"backup write failed" end
    if not io.writeFile(path,raw) then return nil,"layout write failed" end
    return true
end

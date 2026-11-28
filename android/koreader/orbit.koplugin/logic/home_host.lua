-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Presentation planning only: no catalog work, IO, timers or backend vocabulary.
HomeHostPlan = {}
function HomeHostPlan.immutable(value)
    if type(value) ~= "table" then return value end
    local values = {}; for k,v in pairs(value) do values[k]=HomeHostPlan.immutable(v) end
    return setmetatable({}, {__index=values, __newindex=function() error("immutable widget snapshot",2) end,
        __metatable=false})
end
function HomeHostPlan.page(index, delta, total)
    return math.max(1, math.min(total, index + delta))
end
function HomeHostPlan.rect(p, grid, width, height, gap)
    local cw, ch = (width+gap)/grid.cols, (height+gap)/grid.rows
    return {x=math.floor(p.x*cw),y=math.floor(p.y*ch),
        w=math.floor((p.x+p.w)*cw)-math.floor(p.x*cw)-gap,
        h=math.floor((p.y+p.h)*ch)-math.floor(p.y*ch)-gap}
end
-- One display capacity for queries, pagination and drawing. Small tiles keep a
-- two-line row; larger rows can include series and the finish forecast.
function HomeHostPlan.cardGeometry(p,rect,scale)
    local w,h=rect.w-2,rect.h-2
    local compact=h<scale(132)
    local pad=scale(compact and 8 or 14)
    local shelf=p.widget=="booklist" and ((p.settings or {}).style or 0)==0 and h>=scale(190)
    local available=h-2*pad-scale(52)
    local rowH=scale(p.widget=="booklist" and available>=scale(96) and 96 or 52)
    local capacity=compact and 1 or shelf and ((p.w or 2)>=4 and 4 or 2)
        or math.max(0,math.floor(available/rowH))
    return {w=w,h=h,compact=compact,pad=pad,shelf=shelf,rowH=rowH,capacity=capacity}
end
local sources = {recent="recently-added",wtr="want-to-read",device="on-device",reading="reading",finished="finished",custom="library/all"}
function HomeHostPlan.need(p)
    local s=p.settings or {}
    if p.widget == "library" then return {op="library.summary",limit=1} end
    if p.widget == "battery" then return {op="battery",limit=1} end
    if p.widget == "lists" then return {op="lists",limit=8} end
    if p.widget == "continue-reading" then return {op="window",source="reading",query={},offset=0,limit=1} end
    local source = s.source or sources[s.src] or "recently-added"
    -- Neutral context keys only; adapters interpret their opaque identities.
    if type(s.src) == "string" and s.src:match("^(%a+):") then
        local kind,key=s.src:match("^(%a+):(.+)$")
        if kind=="list" or kind=="series" or kind=="author" then source={kind=kind,key=key} end
    end
    assert(s.query == nil or type(s.query) == "table", "Invalid widget query")
    assert(s.limit == nil or type(s.limit) == "number" and s.limit >= 1, "Invalid widget limit")
    local query=Layout.copy(s.query or {})
    local sorts={[1]="title",[2]="author",[3]="last",[4]="added"}
    if sorts[s.sort] then
        query.sort=sorts[s.sort]
        query.dir=(s.sort == 3 or s.sort == 4) and "desc" or "asc"
    end
    local offset=s.offset or 0
    -- Reading now shares the hero identity; exclusion belongs to the companion.
    local exclude=s.src == "reading" or s.exclude_current
    -- The companion removes the hero before applying the chosen query/sort.
    return {op="window",source=source,query=query,offset=offset,limit=s.limit or 4,exclude_current=exclude or nil}
end
function HomeHostPlan.snapshot(result, account)
    result=result or {error="Unavailable"}
    local state=result.error and "error" or result.pending and "loading"
        or not (result.freshness and result.freshness.saved) and "offline-without-data"
        or #(result.items or {}) == 0 and "empty"
        or (result.offline or result.freshness and result.freshness.offline) and "offline-with-data" or "ready"
    -- Missing catalog windows cannot finish before setup. Cached rows still draw,
    -- and a directly entered login works without a server account.
    local setup=result.pending and account and not account.signedIn
        and not AccountPlan.login(account,"sync").available and not AccountPlan.login(account,"opds").available
    -- Setup is an actionable error within the registry's existing six-state contract.
    if setup then state="error" end
    local snapshot={state=state,setup=setup or nil,items=result.items or {},count=#(result.items or {}),
        total=result.total, next=result.next, error=result.error, freshness=result.freshness,
        data=not result.items and result or nil, bytes=#UIUtil.encode(result)}
    if #UIUtil.encode(snapshot)>Budgets.MAX_SNAPSHOT then
        snapshot={state="error",items={},count=0,error="Snapshot budget exceeded",data={state="error"},bytes=64}
    end
    return HomeHostPlan.immutable(snapshot)
end
-- Empty projections of future-only default pages are retained in data, skipped in navigation.
function HomeHostPlan.resolve(document,registry,caps)
    local resolved,err=Layout.resolve(document,"android-tablet",registry,caps)
    if not resolved then return nil,err end
    local visible={}
    for i,page in ipairs(resolved.pages) do
        local placements={}
        for _,p in ipairs(page.placements) do
            local valid,need=pcall(HomeHostPlan.need,p)
            need=valid and need or {}
            local supported=true
            if (p.widget == "lists" or type(need.source)=="table" and need.source.kind=="list")
                and caps and type(caps.lists) == "table" and caps.lists.read == false then supported=false end
            if (p.widget == "booklist" or p.widget == "continue-reading") and caps and caps.catalog == false then supported=false end
            if p.widget == "battery" and caps and caps.battery == false then supported=false end
            if p.widget == "library" and caps and caps.catalog == false then supported=false end
            if WidgetRegistry[p.widget] and (WidgetRegistry[p.widget].dataNeeds[1].source == "reading.stats" or WidgetRegistry[p.widget].dataNeeds[1].source == "reading.metrics") and caps and caps.readingStats == false then supported=false end
            if need.source == "want-to-read" and caps and caps.wantToRead == false then supported=false end
            if need.source == "on-device" and caps and caps.onDevice == false then supported=false end
            if supported then placements[#placements+1]=p end
        end
        page.placements=placements
        if #placements>0 or #document.pages[i].placements==0 then visible[#visible+1]=page end
    end
    if #visible==0 then visible[1]=resolved.pages[1] end
    resolved.pages=visible
    return resolved
end

-- Reuse bounded placement and page operations, preserving every existing override.
function HomeHostPlan.saveFilter(document, saved, title)
    local id="filter-"..document.revision
    local used={}
    for _,page in ipairs(document.pages) do
        used[page.id]=true
        for _,p in ipairs(page.placements) do used[p.instance]=true end
    end
    while used[id] do id=id.."-new" end
    local p={instance=id,widget="booklist",version=1,x=0,y=0,w=2,h=2,
        settings={title=title or "Custom filter",source=Layout.copy(saved.base_source or "library/all"),
            src="custom",query=Layout.copy(saved.query or {}),exclude_current=saved.exclude_current,style=0,sort=0,cap=0}}
    for _,page in ipairs(document.pages) do
        local result=Layout.add(document,page.id,p)
        if result then return result,page.id end
    end
    local result,err=Layout.page(document,"add",id)
    if not result then return nil,err end
    return Layout.add(result,id,p),id
end

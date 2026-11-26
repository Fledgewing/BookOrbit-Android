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
local sources = {recent="recently-added",wtr="want-to-read",device="on-device",reading="reading",finished="finished",custom="library/all"}
function HomeHostPlan.need(p)
    local s=p.settings or {}
    if p.widget == "lists" then return {op="lists",limit=8} end
    if p.widget == "continue-reading" then return {op="window",source="reading",query={},offset=0,limit=1} end
    local source = s.source or sources[s.src] or "recently-added"
    -- Neutral context keys only; adapters interpret their opaque identities.
    if type(s.src) == "string" and s.src:match("^list:") then source={kind="list",key=s.src:sub(6)} end
    assert(s.query == nil or type(s.query) == "table", "Invalid widget query")
    assert(s.limit == nil or type(s.limit) == "number" and s.limit >= 1, "Invalid widget limit")
    local query=Layout.copy(s.query or {})
    local sorts={[1]="title",[2]="author",[3]="last",[4]="added"}
    if sorts[s.sort] and not query.sort then query.sort=sorts[s.sort] end
    return {op="window",source=source,query=query,offset=s.offset or 0,limit=s.limit or 4}
end
function HomeHostPlan.snapshot(result)
    result=result or {error="Unavailable"}
    local state=result.error and "error" or result.pending and "loading"
        or not (result.freshness and result.freshness.saved) and "offline-without-data"
        or #(result.items or {}) == 0 and "empty"
        or (result.offline or result.freshness and result.freshness.offline) and "offline-with-data" or "ready"
    return HomeHostPlan.immutable({state=state,items=result.items or {},count=#(result.items or {}),
        total=result.total, next=result.next, error=result.error, freshness=result.freshness})
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
            if p.widget == "lists" and caps and type(caps.lists) == "table" and caps.lists.read == false then supported=false end
            if (p.widget == "booklist" or p.widget == "continue-reading") and caps and caps.catalog == false then supported=false end
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

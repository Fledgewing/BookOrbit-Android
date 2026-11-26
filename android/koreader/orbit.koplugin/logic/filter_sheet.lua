-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Small selection state only. Catalog predicates, ordering and counts belong to the worker.
FilterSheet = { FIELDS={"show","where","author","series","tags","len","rating","added","gs"},
    LABELS={show="Show",where="Where",author="Author",series="Series",tags="Tags",len="Length",rating="Rating",added="Added",gs="Group & sort"},
    MULTI={author=true,series=true,tags=true}, PAGE_SIZE=8 }
local labels={all="All",unread="Unread",reading="Reading",finished="Finished",["want-to-read"]="Want to read",
    anywhere="Anywhere",["on-device"]="On this device",["server-only"]="Server only",none="Not grouped",
    order="List order",match="Best match",title="Title",author="Author",series="Series",last="Last read",added="Added",rating="Rating",asc="Ascending",desc="Descending"}
local function equal(a,b) return Cache.encode(a) == Cache.encode(b) end
function FilterSheet.new(context)
    context=context or {}
    local source=context.source or "library/all"
    local kind=type(source)=="table" and source.kind or source
    local defaults={show="all",where="anywhere",group="none",sort=kind=="search" and "match" or "order",dir="asc"}
    for k,v in pairs(context.defaults or {}) do defaults[k]=Layout.copy(v) end
    local query=Layout.copy(defaults)
    for k,v in pairs(context.query or {}) do query[k]=Layout.copy(v) end
    if query.length then query.len=query.length; query.length=nil end
    if query.wtr then query.show="want-to-read"; query.wtr=nil end
    if kind=="search" then defaults.q=query.q end
    return setmetatable({source=source,defaults=defaults,query=query,
        hideShow=kind=="reading",hideWhere=kind=="on-device",offset=0}, {__index=FilterSheet})
end
function FilterSheet:reset() self.query=Layout.copy(self.defaults); self.offset=0 end
function FilterSheet:changed(k)
    if k=="gs" then return self:changed("group") or self:changed("sort") or self:changed("dir") end
    local a,b=self.query[k],self.defaults[k]
    if FilterSheet.MULTI[k] then return not equal(a or {},b or {}) end
    return not equal(a,b)
end
function FilterSheet:value(k)
    local v=self.query[k]
    if k=="gs" then return (self.query.group=="author" and "By author" or self.query.group=="series" and "By series" or "Not grouped") .. " · " .. self:value("sort") .. " · " .. self:value("dir") end
    if FilterSheet.MULTI[k] then return (not v or #v==0) and "Any" or (#v==1 and v[1] or #v .. " chosen") end
    if type(v)=="table" then
        if k=="len" then return v.max==249 and "Short" or v.min==250 and v.max==450 and "Medium" or v.min==451 and "Long" or "Custom length" end
        if k=="rating" then return tostring(v.min or 0) .. "★ and up" end
        if k=="added" then return "Since " .. tostring(v.min or "…") end
    end
    return labels[v] or ({len="Any length",rating="Any rating",added="Any time"})[k] or tostring(v or "Any")
end
function FilterSheet:rows()
    local rows={}
    for _,k in ipairs(self.FIELDS) do
        if not (k=="show" and self.hideShow or k=="where" and self.hideWhere) then
            rows[#rows+1]={key=k,label=self.LABELS[k],value=self:value(k),changed=self:changed(k),divider=k=="gs"}
        end
    end
    return rows
end
function FilterSheet:choose(field, option)
    if self.MULTI[field] then
        local values=Layout.copy(self.query[field] or {}); local found
        for i,v in ipairs(values) do if v==option.value then table.remove(values,i); found=true; break end end
        if not found then assert(#values<100,"Too many selections"); values[#values+1]=option.value end
        self.query[field]=#values>0 and values or nil
    else
        self.query[field]=Layout.copy(option.value or (field=="show" and "all" or field=="where" and "anywhere" or nil))
        if field=="show" then self.query.wtr=nil end
        if field=="len" then self.query.length=nil end
    end
end
function FilterSheet:clear(field, value)
    if value~=nil then
        local values=Layout.copy(self.query[field] or {})
        for i,v in ipairs(values) do if v==value then table.remove(values,i); break end end
        self.query[field]=#values>0 and values or nil
    else self.query[field]=Layout.copy(self.defaults[field]) end
    if field=="sort" then self.query.dir=self.defaults.dir end
end
function FilterSheet:chips()
    local chips={}
    for _,k in ipairs({"show","where","author","series","tags","len","rating","added","group","sort"}) do
        if self:changed(k) or k=="sort" and self:changed("dir") then
            if self.MULTI[k] then
                for _,v in ipairs(self.query[k] or {}) do chips[#chips+1]={key=k,value=v,label=v} end
            else chips[#chips+1]={key=k,label=k=="group" and ("By " .. tostring(self.query[k])) or self:value(k)} end
        end
    end
    return chips
end
function FilterSheet:presentation(total)
    local chips=self:chips(); local parts={}
    for i=1,math.min(#chips,8) do parts[#parts+1]=chips[i].label end
    return {chips=chips,active=#chips>0,icon=#chips>0 and "filter.filled" or "filter",
        subtitle=(total~=nil and tostring(total) .. " books" or "Counting…") .. (#parts>0 and " · " .. table.concat(parts," · ") or "")}
end
function FilterSheet.option(row, multi)
    return {text=(multi and (row.selected and "☑ " or "☐ ") or (row.selected and "● " or "○ ")) .. tostring(row.label) ..
        ((row.count or 0)>0 and " · " .. row.count or ""), gray=row.count==0, selected=row.selected}
end

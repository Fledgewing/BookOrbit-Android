-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Small configuration values only; source catalogs and counts stay in the companion.
BookList = {PAGE_SIZE=6, categories={"builtin","lists","series","authors","collections","libraries"},
    captions={"None","Date added","Progress","Author"}, styles={"Cover shelf","Rows with progress"},
    sorts={"List order","Title","Author","Last read"},
    names={year="Finished this year",pickup="Pick back up",custom="Custom filter",recent="Recently added",wtr="Want to read",reading="Reading now",finished="All finished",device="On this device"},
    presets={
        year={title="Finished this year",src="year",style=0,sort=0,cap=0},
        pickup={title="Pick back up",src="pickup",style=0,sort=0,cap=3},
        also={title="Also reading",src="reading",style=1,sort=3,cap=2},
        recent={title="Recently added",src="recent",style=0,sort=0,cap=1},
        wtr={title="Want to read",src="wtr",style=0,sort=0,cap=0},
        finished={title="All finished",src="finished",style=0,sort=3,cap=3},
        ondevice={title="On device",src="device",style=1,sort=3,cap=0},
    }}
function BookList.preset(id)
    return Layout.copy(BookList.presets[id] or {title="Book list",src="recent",style=0,sort=0,cap=0})
end
function BookList.name(cfg) return cfg.source_title or BookList.names[cfg.src] or cfg.title or "Book list" end
function BookList.valid(cfg)
    if type(cfg)~="table" or type(cfg.title)~="string" or #cfg.title<1 or #cfg.title>80 then return nil,"invalid title" end
    if not BookList.names[cfg.src] and not (type(cfg.src)=="string" and cfg.src:match("^(%a+):.+") and
        ({list=true,series=true,author=true,collection=true,library=true,year=true})[cfg.src:match("^(%a+):")]) then return nil,"invalid source" end
    for key,max in pairs({style=1,sort=3,cap=3}) do
        local n=cfg[key] or 0
        if type(n)~="number" or n~=math.floor(n) or n<0 or n>max then return nil,"invalid "..key end
    end
    if cfg.query~=nil then
        if type(cfg.query)~="table" then return nil,"invalid filter" end
        -- The neutral sheet owns query semantics. Bound serialized configuration at the library boundary.
        local ok,raw=pcall(UIUtil.encode,cfg.query)
        if not ok or #raw>4096 then return nil,"filter exceeds budget" end
    end
    if cfg.source_title~=nil and (type(cfg.source_title)~="string" or #cfg.source_title>80) then return nil,"invalid source title" end
    return true
end
function BookList.choose(cfg, option)
    local next=Layout.copy(cfg)
    local automatic=not cfg.renamed and (cfg.title==BookList.name(cfg) or cfg.title=="Book list" or cfg.title=="Also reading" or cfg.title=="On device")
    next.src=option.src; next.source_title=option.title
    if option.default_sort~=nil then next.sort=option.default_sort end
    next.offset=nil
    if cfg.src~=option.src then next.source=nil; next.exclude_current=nil end
    if automatic then next.title=option.title end
    if cfg.src~=option.src and next.src~="custom" then next.query=nil end
    return next
end
function BookList.title(cfg, title)
    local next=Layout.copy(cfg)
    next.title=title:match("^%s*(.-)%s*$")
    if next.title=="" then next.title=BookList.name(cfg) end
    next.renamed=next.title~=BookList.name(cfg)
    return next
end
function BookList.suggest(cfg)
    local name=BookList.name(cfg)
    local ideas={name,"Up next","My "..name:lower(),"Shelf"}
    local index=0; for i,v in ipairs(ideas) do if cfg.title==v then index=i end end
    return BookList.title(cfg,ideas[index%#ideas+1])
end
function BookList.source(cfg)
    local kind,key=cfg.src:match("^(%a+):(.+)$")
    if kind then return {kind=kind=="year" and "finished-year" or kind,key=key} end
    return cfg.source or ({year={kind="finished-year",key="current"},pickup="pick-back-up",recent="recently-added",wtr="want-to-read",reading="reading",finished="finished",device="on-device",custom="library/all"})[cfg.src]
end

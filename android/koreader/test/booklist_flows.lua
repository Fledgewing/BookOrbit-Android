-- SPDX-License-Identifier: AGPL-3.0-or-later
return function(test,eq,ok,E,W,Widget,withHost)
    local function press(view,text)
        for _,line in ipairs(view.dialog.buttons) do for _,b in ipairs(line) do
            if b.text==text then return b.callback() end
        end end
        error("missing row "..text)
    end
    local function sources(reads)
        local fallback=E.LibraryAdapter.read
        E.LibraryAdapter.read=function(raw)
            local a=E.Cache.decode(raw)
            if a.op~="sources" then return fallback(raw) end
            if reads then reads[#reads+1]=a end
            local rows={}
            if a.category=="builtin" then
                for _,src in ipairs({"custom","recent","wtr","reading","finished","device"}) do
                    rows[#rows+1]={src=src,title=E.BookList.names[src],count=7}
                end
            else
                local kind=({lists="list",series="series",authors="author"})[a.category]
                for i=a.offset+1,math.min(a.offset+a.limit,13) do rows[#rows+1]={src=kind..":key-"..i,title=kind.." "..i,count=i} end
            end
            return {items=rows,total=a.category=="builtin" and 6 or 13,next=a.category~="builtin" and a.offset<12 and a.offset+6 or nil,freshness={saved=true}},900
        end
    end
    test("Book list editor: every source, paged counted windows and filter return",function()
        withHost(function(batches,reads)
            sources(reads)
            E.S.home_layout=E.Layout.default()
            local h=E.HomeHost.create(); E.HomeHost.active=h; W.shown={h}
            local e=E.HomeEditor.show(h); e.model.selected="also"
            local cfg=e:configure()
            local old=e.model.document
            for _,src in ipairs({"recent","wtr","reading","finished","device"}) do
                press(cfg,"Source: "..E.BookList.name(cfg.cfg).." ›")
                eq(#cfg.dialog.buttons,9); eq(cfg.metrics.rows,6); eq(cfg.metrics.roundTrips,1)
                press(cfg,"○ "..E.BookList.names[src].." · 7")
                eq(cfg.cfg.src,src); eq(e.model.document,old)
            end
            press(cfg,"Source: On this device ›")
            press(cfg,"○ Custom filter · 7")
            ok(cfg.filter); eq(cfg.dialog,nil)
            local filter=cfg.filter
            filter.model.query.show="unread"; filter:back()
            eq(cfg.cfg.query.show,"unread"); eq(cfg.cfg.title,"Custom filter"); eq(cfg.filter,nil)
            for _,cat in ipairs({{"lists","Your lists","list"},{"series","Series","series"},{"authors","Authors","author"}}) do
                press(cfg,"Source: "..E.BookList.name(cfg.cfg).." ›")
                if cfg.category~=cat[1] then press(cfg,cat[2]) end; eq(cfg.category,cat[1])
                press(cfg,"›"); eq(cfg.offset,6); eq(reads[#reads].offset,6); eq(reads[#reads].limit,6)
                press(cfg,"›"); eq(cfg.offset,12); eq(#cfg.dialog.buttons,4)
                press(cfg,"‹"); eq(cfg.offset,6)
                press(cfg,"○ "..cat[3].." 7 · 7"); eq(cfg.cfg.src,cat[3]..":key-7")
                eq(E.HomeHostPlan.need({widget="booklist",settings=cfg.cfg}).source.kind,cat[3])
            end
            press(cfg,"Caption: Progress"); eq(cfg.cfg.cap,3)
            press(cfg,"Done"); eq(cfg.alive,false)
            eq(e.model:page().placements[2].settings.src,"author:key-7")
            eq(E.S.home_layout.pages[1].placements[2].settings.src,"reading","unpublished until editor Done")
        end)
    end)
    test("Book list Reading now keeps list, filter counts and saved context consistent",function()
        withHost(function(batches,reads)
            E.S.home_layout=E.Layout.default()
            local h=E.HomeHost.create(); E.HomeHost.active=h; W.shown={h}
            local p=E.Layout.default().pages[1].placements[2]
            h:dispatch("all",nil,p)
            eq(h.list_layout.pages[1].placements[1].settings.exclude_current,true)
            eq(h.filter.exclude_current,true)
            h.filter:show()
            eq(reads[#reads].op,"facets"); eq(reads[#reads].exclude_current,true)
            local out,page=E.HomeHostPlan.saveFilter(E.S.home_layout,{base_source="reading",query={},exclude_current=true})
            for _,pg in ipairs(out.pages) do if pg.id==page then
                eq(pg.placements[#pg.placements].settings.exclude_current,true)
            end end
            h.filter:close(false)
        end)
    end)
    test("Book list Classic: More, title suggestions, focused source, Back and Cancel",function()
        withHost(function()
            sources(); E.S.home_layout=E.Layout.default()
            local h=E.HomeHost.create(); E.HomeHost.active=h; W.shown={h}
            local e=E.HomeEditor.show(h); e.model.selected="also"
            local original=e.model.document
            local cfg=e:onMore(); eq(cfg.classic,true); eq(cfg.dialog.focus[2],1)
            press(cfg,"Title: Also reading"); eq(cfg.cfg.title,"Reading now")
            press(cfg,"Source: Reading now ›"); eq(cfg.dialog.focus[2],6,"current source receives focus after category rows")
            cfg.dialog:onClose(); eq(cfg.sources,nil); ok(cfg.alive)
            press(cfg,"Cancel"); eq(cfg.alive,false); eq(e.model.document,original)
            cfg=e:onMore(); cfg.dialog:onClose(); eq(cfg.alive,false); eq(e.model.document,original)
        end)
    end)
    test("Book list filter save inside editor keeps selection and commits on editor Done",function()
        withHost(function()
            sources(); E.S.home_layout=E.Layout.default()
            local h=E.HomeHost.create(); E.HomeHost.active=h; W.shown={h}
            local e=E.HomeEditor.show(h); e.model.selected="also"
            local cfg=e:configure(); cfg:choose({src="custom",title="Custom filter"})
            local filter=cfg.filter
            filter.model.query.show="unread"
            local original=e.model.document
            local originalIndex=e.model.index
            local save
            for _,line in ipairs(filter.dialog.buttons) do for _,b in ipairs(line) do if b.text=="+ Save as a Book list on Home" then save=b.callback end end end
            ok(save); save()
            eq(e.model.index,originalIndex); eq(e.model.selected,"also")
            eq(#e.model.document.pages,#original.pages); eq(#e.model.document.pages[2].placements,#original.pages[2].placements+1); ok(cfg.notice:find("Library",1,true))
            eq(E.S.home_layout,original); eq(cfg.cfg.query.show,"unread")
            press(cfg,"Done"); eq(cfg.alive,false); ok(e:done())
            eq(#E.S.home_layout.pages[2].placements,#original.pages[2].placements+1)
            eq(E.S.home_layout.pages[1].placements[2].settings.src,"custom")
        end)
    end)
    test("Book list save: first fitting space, full-page naming, errors and captions",function()
        withHost(function()
            local d=E.Layout.default()
            d.pages={{id="one",tab="Home",name="First",placements={{instance="fill",widget="future",version=1,x=0,y=0,w=4,h=6,settings={}}}},
                {id="two",tab="Home",name="Second",placements=setmetatable({},{__jsontype="array"})}}
            local saved={base_source="library/all",query={show="unread"}}
            local out,page=E.HomeHostPlan.saveFilter(d,saved,"Custom filter")
            eq(page,"one"); eq(out.pages[1].placements[2].y,6); eq(#d.pages[1].placements,1)
            local p=out.pages[1].placements[2]; ok(E.BookList.valid(p.settings)); eq(p.widget,"booklist")
            eq(p.settings.query.show,"unread"); saved.query.show="finished"; eq(p.settings.query.show,"unread")
            E.S.home_layout=d
            local h=E.HomeHost.create(); E.HomeHost.active=h; W.shown={h}
            h:showList("Short books","library/all")
            local success=h:saveFilter(saved); ok(success,W.shown[#W.shown].text); ok(W.shown[#W.shown].title:find("First",1,true),W.shown[#W.shown].title)
            eq(E.HomeWidgets.caption({cap=0},{authors={"A"}}),"")
            eq(E.HomeWidgets.caption({cap=1},{added="2026-11-26T12:00:00"}),"2026-11-26")
            eq(E.HomeWidgets.caption({cap=2},{progress=42}),"42%")
            eq(E.HomeWidgets.caption({cap=3},{authors={"A"}}),"A")
        end)
    end)
end

-- SPDX-License-Identifier: AGPL-3.0-or-later
return function(M,test,ok,eq)
    local B,L=M.BookList,M.Layout
    test("Book list: presets share one widget schema and independent configs",function()
        for id,preset in pairs(B.presets) do
            local cfg=B.preset(id); ok(B.valid(cfg)); eq(cfg.src,preset.src)
            local m=M.HomeEditorPlan.new(L.default()); ok(m:add("booklist",nil,nil,cfg))
            local p=m:page().placements[1]; eq(p.widget,"booklist"); eq(p.settings.src,cfg.src)
            cfg.title="changed"; eq(B.presets[id].title,preset.title)
        end
        for _,bad in ipairs({{title="",src="recent"},{title="A",src="unknown"},{title="A",src="recent",sort=4},
            {title="A",src="recent",cap=-1},{title="A",src="recent",style=.5},{title="A",src="recent",query="json"},
            {title="A",src="recent",query={q=string.rep("x",4100)}}}) do eq(B.valid(bad),nil) end
        for _,src in ipairs({"custom","recent","wtr","reading","finished","device","list:opaque:key","series:opaque","author:A:B"}) do
            ok(B.valid({title="Title",src=src})); ok(B.source({src=src}))
        end
    end)
    test("Book list: automatic titles follow source; renamed titles and cancel drafts survive",function()
        local cfg=B.preset("also")
        cfg=B.choose(cfg,{src="custom",title="Custom filter"}); eq(cfg.title,"Custom filter")
        cfg.query={show="unread"}
        local renamed=B.title(cfg,"  Up next  "); eq(renamed.title,"Up next"); eq(renamed.renamed,true)
        local next=B.choose(renamed,{src="author:A",title="A"}); eq(next.title,"Up next"); eq(next.query,nil)
        eq(cfg.query.show,"unread"); eq(B.title(cfg,"  ").title,"Custom filter")
        eq(B.suggest(cfg).title,"Up next")
        local saved={title="My reading",src="custom",source="reading",query={q="Moon"},exclude_current=true}
        local same=B.choose(saved,{src="custom",title="Custom filter"})
        eq(same.source,"reading"); eq(same.exclude_current,true); eq(same.query.q,"Moon")
        same.query.q="Changed"; eq(saved.query.q,"Moon")
        local m=M.HomeEditorPlan.new(L.default()); m.selected="also"
        local original=m.document
        eq(m:configure({title="A",src="invalid"}),nil); eq(m.document,original)
        ok(m:configure(next)); eq(original.pages[1].placements[2].settings.title,"Also reading")
        eq(m.document.pages[1].placements[2].settings.src,"author:A"); ok(L.validate(m.document))
    end)
end

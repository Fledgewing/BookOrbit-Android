-- SPDX-License-Identifier: AGPL-3.0-or-later
return function(test,eq,ok,M)
    local P=M.SeriesPlan
    test("Series: every saved/loading/error/offline state has truthful copy",function()
        for _,case in ipairs({
            {{error="missing"},"error","Couldn't load this page"},{{pending=true},"loading","Loading…"},
            {{freshness={saved=false}},"offline-without-data","Not saved yet"},
            {{freshness={saved=true},items={}},"empty","No books"},
            {{freshness={saved=true},items={{}},offline=true},"offline-with-data","Offline · saved library"},
            {{freshness={saved=true},items={{}}},"ready"},
        }) do local state,label=P.state(case[1]); eq(state,case[2]); eq(label,case[3]) end
        eq(P.dot("read"),1); eq(P.dot("reading"),.5); eq(P.dot("unread"),0); eq(P.dot("future"),0)
    end)
    test("Series: M8C geometry stays bounded and group drills preserve filters",function()
        local g=P.geometry(702,936,function(n) return n end)
        eq(g.limit,9); eq(g.groups,4); eq(g.covers,9)
        ok(g.top+(g.limit-4)*g.row<=936-g.bottom)
        local original={group="series",q="calder",where="on-device",show="unread"}
        local q=P.groupQuery(original,{field="series",value=""})
        eq(q.without_series,true); eq(q.group,"none"); eq(q.q,"calder"); eq(q.where,"on-device")
        eq(original.group,"series"); eq(original.without_series,nil)
        eq(P.groupQuery(original,{field="author",value="A"}).author[1],"A")
        eq(P.groupQuery(original,{field="series",value="Orbit"}).series[1],"Orbit")
        local f=M.FilterSheet.new{query=q}; local chips=f:chips()
        eq(chips[#chips].label,"Not in a series")
        f:clear("without_series"); eq(f.query.without_series,nil)
    end)
end

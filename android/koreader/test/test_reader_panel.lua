-- SPDX-License-Identifier: AGPL-3.0-or-later
return function(test,eq,ok,here)
    local env=setmetatable({},{__index=_G})
    setfenv(assert(loadfile(here.."/../orbit.koplugin/logic/reader_panel.lua")),env)()
    local R=env.ReaderPanelPlan
    test("reader model: pending, empty, error and offline-without-data never invent saved progress",function()
        for _,result in ipairs({{items={},pending=true},{items={}},{items={},error="unavailable"},
            {items={},freshness={saved=false,offline=true}}}) do
            local m=R.model(result,{})
            eq(m.title,"Book info not saved yet"); eq(m.progress,nil)
            eq(m.progress_text,"Progress not saved yet")
            eq(m.battery,"Battery estimate not available yet")
            eq(m.days,"Days start to finish: not saved yet")
        end
    end)
    test("reader model: ready and offline cached rows keep companion display values",function()
        for _,offline in ipairs({false,true}) do
            local m=R.model({items={{title="Fixture",authors={"Fixture author"},progress=62,
                stats={pages_read=120,reading_seconds=3600,days_start_to_finish=3}}},freshness={saved=true,offline=offline}},
                {display={page_estimate="Learning your usual use"},hours_usual_use=999})
            eq(m.title,"Fixture"); eq(m.author,"Fixture author"); eq(m.progress,.62)
            eq(m.progress_text,"62% read"); eq(m.battery,"Learning your usual use")
            eq(m.pages,"120 pages read"); eq(m.time,"60 min reading time"); eq(m.days,"3 days start to finish")
        end
        eq(R.model({items={{progress=200}}},{}).progress,1)
        eq(R.model({items={{progress=-1}}},{}).progress,0)
        for _,n in ipairs({0/0,math.huge,-math.huge}) do eq(R.model({items={{progress=n}}},{}).progress,nil) end
    end)
    test("reader size choices: approved M8C steps wrap in both directions",function()
        local sizes={16,18,20,22,24,27}
        for i,size in ipairs(sizes) do
            eq(R.fontSize(size,1),sizes[i%#sizes+1])
            eq(R.fontSize(size,-1),sizes[(i-2)%#sizes+1])
        end
        eq(R.fontSize(23,1),24); eq(R.fontSize(100,-1),24)
    end)
end

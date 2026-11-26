return function(test,eq,ok,here,Cache)
    local e=setmetatable({Cache=Cache,now_s=function() return 0 end,log=function() end},{__index=_G})
    local root=here..'/../orbit.koplugin/'
    for _,p in ipairs({'logic/budgets.lua','logic/widget_registry.lua','logic/reading_stats.lua','ko/reading_stats.lua'}) do
        setfenv(assert(loadfile(root..p)),e)()
    end
    local data={state='ready',year={intensity={},days_read=7,start='2025-11-26'},
        week={seconds={1,2,3,4,5,6,7},levels={.1,.2,.3,.4,.5,.6,1},total_seconds=28},
        hour_levels={},hour_intensity={},peak_hour=19,after_18_percent=71,
        records={recorded_pages=8,longest_session_seconds=600,streak=3,best_streak=4}}
    for i=1,365 do data.year.intensity[i]=i%5 end
    for i=1,24 do data.hour_levels[i]=i/24; data.hour_intensity[i]=i%5 end
    test('stats: standalone registry widgets paint bounded snapshots and release text',function()
        local frees, paints, logs = 0, 0, 0
        local function class()
            local c={}
            function c:new(o) return setmetatable(o or {},{__index=self}) end
            function c:getSize() return self.dimen end
            function c:paintTo() paints=paints+1 end
            function c:free() frees=frees+1 end
            return c
        end
        local colors={COLOR_WHITE=0,COLOR_LIGHT_GRAY=1,COLOR_GRAY=2,COLOR_DARK_GRAY=3,COLOR_BLACK=4}
        local modules={['ui/widget/widget']=class(),['ui/geometry']=class(),
            ['ui/font']={getFace=function() return {} end},['ui/widget/textwidget']=class(),['ffi/blitbuffer']=colors}
        e.require=function(name) return assert(modules[name],name) end
        e.log=function() logs=logs+1 end
        local rects=0
        local bb={paintRect=function(_,x,y,w,h,color)
            ok(w>=0 and h>=0 and x>=10 and y>=10 and x+w<=610 and y+h<=310)
            ok(color~=nil); rects=rects+1
        end}
        for _,id in ipairs({'year-in-reading','this-week','when-you-read','reading-records'}) do
            local w=e.WidgetRegistry[id].renderers['android-tablet'](data,{w=600,h=300,rows=2})
            eq(w:getSize().w,600); w:paintTo(bb,10,10); w:free()
        end
        ok(rects>=400); ok(paints>4); eq(frees,paints); eq(logs,8)
    end)
    test('stats: fixed geometry, hour bars and short strip, immutable snapshot',function()
        local before=Cache.encode(data)
        for id,n in pairs({['year-in-reading']=366,['this-week']=7,['when-you-read']=24,['reading-records']=0}) do
            local p=e.ReadingStatsPlan.build(id,data,600,300,2)
            eq(#p.rects,n); ok(e.WidgetRegistry[id].renderers['android-tablet'])
            ok(e.Budgets.get('widgets',id))
            for _,r in ipairs(p.rects) do ok(r.x>=0 and r.y>=0 and r.x+r.w<=600 and r.y+r.h<=300) end
        end
        local p=e.ReadingStatsPlan.build('when-you-read',data,600,140,1)
        eq(p.rects[1].h,p.rects[24].h)
        eq(Cache.encode(data),before)
        eq(e.ReadingStatsPlan.build('this-week',{state='empty'},300,200,2).message,'No reading recorded')
        local b=e.Budgets.widgets['year-in-reading']
        eq(e.Budgets.check(b,{rows=1,bytes=16385,snapshotBytes=16385,spawns=0,network=0,roundTrips=0}),nil)
        eq(pcall(e.ReadingStatsWidgets.render,'this-week',{padding=string.rep('x',17000)},{w=400,h=300,rows=2}),false)
    end)
    test('stats: per-field sources label only reader data and keep overlapping today separate',function()
        data.sources={days='all your devices',hours='this reader',records='this reader',streak='all your devices'}
        data.local_today_seconds=600
        local year=e.ReadingStatsPlan.build('year-in-reading',data,600,300,2)
        eq(year.source,nil)
        local week=e.ReadingStatsPlan.build('this-week',data,600,300,2)
        eq(week.source,nil); eq(week.labels[#week.labels].text,'10m today · this reader (separate)')
        eq(e.ReadingStatsPlan.build('when-you-read',data,600,300,2).source,'This reader')
        local records=e.ReadingStatsPlan.build('reading-records',data,600,300,2)
        eq(records.source,'Pages and sessions · this reader')
        ok(not records.labels[3].text:find('this reader',1,true))
        data.sources.streak='this reader'
        ok(e.ReadingStatsPlan.build('reading-records',data,600,300,2).labels[3].text:find('this reader',1,true))
        data.hours_available=false
        eq(e.ReadingStatsPlan.build('when-you-read',data,600,300,2).message,'Enable KOReader statistics')
        data.records_available=false
        data.records.books_this_year=17
        local only=e.ReadingStatsPlan.build('reading-records',data,600,300,2)
        eq(only.labels[1].text,'Local records unavailable'); eq(only.labels[3].text,'17 books this year')
        data.year=nil
        eq(e.ReadingStatsPlan.build('year-in-reading',data,600,300,2).message,'Reading days unavailable')
    end)

end

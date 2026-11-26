return function(test,eq,ok,here,Cache)
    local e=setmetatable({Cache=Cache,now_s=function() return 0 end,log=function() end},{__index=_G})
    local root=here..'/../orbit.koplugin/'
    for _,p in ipairs({'logic/budgets.lua','logic/widget_registry.lua','logic/reading_stats.lua','logic/reader_panel.lua','ko/reading_stats.lua'}) do
        setfenv(assert(loadfile(root..p)),e)()
    end
    test('clock: library operation inherits one row and batches the host request',function()
        local env=setmetatable({Cache=Cache,now_s=function() return 0 end,log=function() end},{__index=_G})
        local calls,batches=0,0
        env.LibraryAdapter={read=function(request)
            local args=Cache.decode(request); eq(args.op,'device.clock'); eq(args.limit,1); eq(args.twelve_hour,true)
            calls=calls+1; return {state='ready',time='9:42 PM'},128
        end,request=function(batch) eq(#batch,1); batches=batches+1; return true end}
        setfenv(assert(loadfile(root..'logic/budgets.lua')),env)()
        setfenv(assert(loadfile(root..'ko/library.lua')),env)()
        local host=env.Library.paint('home')
        eq(host:widget('clock'):clock(true).time,'9:42 PM'); eq(calls,1); eq(batches,0)
        local usage=host:flush(); eq(usage.rows,1); eq(usage.bytes,128)
        eq(usage.spawns,0); eq(usage.network,0); eq(usage.roundTrips,1); eq(batches,1)
    end)
    local data={state='ready',year={intensity={},days_read=7,start='2025-11-26'},
        week={seconds={1,2,3,4,5,6,7},levels={.1,.2,.3,.4,.5,.6,1},total_seconds=28},
        hour_levels={},hour_intensity={},peak_hour=19,after_18_percent=71,
        records={recorded_pages=8,longest_session_seconds=600,best_day_pages=4,streak=3,best_streak=4},
        display={week_total='2 h 10 m',today_index=3,best_index=7,best_day='Sunday',best_duration='10 m',
            period='Evenings',peak='19:00',longest='10 m',months={{day=0,label='Nov'},{day=6,label='Dec'}}}}
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
        for id,n in pairs({['year-in-reading']=371,['this-week']=8,['when-you-read']=26,['reading-records']=1}) do
            local p=e.ReadingStatsPlan.build(id,data,600,300,2)
            eq(#p.rects,n); ok(e.WidgetRegistry[id].renderers['android-tablet'])
            ok(e.Budgets.get('widgets',id))
            for _,r in ipairs(p.rects) do ok(r.x>=0 and r.y>=0 and r.x+r.w<=600 and r.y+r.h<=300) end
        end
        for _,id in ipairs({'year-in-reading','this-week','when-you-read','reading-records'}) do
            for _,size in ipairs(e.WidgetRegistry[id].sizes['android-tablet']) do
                local w=math.floor(size[1]*690/4)-12
                local h=math.floor(size[2]*776/8)-12
                local plan=e.ReadingStatsPlan.build(id,data,w,h,size[2])
                for _,r in ipairs(plan.rects) do ok(r.x>=0 and r.y>=0 and r.x+r.w<=w and r.y+r.h<=h,id) end
                for _,t in ipairs(plan.labels) do ok(t.x>=0 and t.y>=0 and t.y+(t.size or 12)<=h,id..' clipped '..t.text) end
            end
        end
        local p=e.ReadingStatsPlan.build('when-you-read',data,600,140,1)
        eq(p.rects[1].h,p.rects[24].h)
        eq(Cache.encode(data),before)
        eq(e.ReadingStatsPlan.build('this-week',{state='empty'},300,200,2).message,'No reading recorded')
        local b=e.Budgets.widgets['year-in-reading']
        eq(e.Budgets.check(b,{rows=1,bytes=16385,snapshotBytes=16385,spawns=0,network=0,roundTrips=0}),nil)
        eq(pcall(e.ReadingStatsWidgets.render,'this-week',{padding=string.rep('x',17000)},{w=400,h=300,rows=2}),false)
    end)
    local function has(plan,text)
        for _,v in ipairs(plan.labels) do if v.text:find(text,1,true) then return true end end
        return false
    end
    test('stats: companion display, calendar legend, today, peak and record hierarchy',function()
        local week=e.ReadingStatsPlan.build('this-week',data,330,280,3)
        eq(week.rects[3].level,4); eq(week.rects[7].level,2)
        ok(has(week,'Best day Sunday')); ok(has(week,'2 h 10 m'))
        local year=e.ReadingStatsPlan.build('year-in-reading',data,680,280,3)
        ok(year.rects[365].outline); ok(has(year,'Today')); ok(has(year,'Less')); ok(has(year,'More')); ok(has(year,'Dec'))
        local peak=e.ReadingStatsPlan.build('when-you-read',data,330,180,2)
        ok(has(peak,'Evenings')); ok(has(peak,'19:00'))
        local strip=e.ReadingStatsPlan.build('when-you-read',data,680,85,1)
        ok(strip.rects[20].outline); eq(strip.rects[1].h,strip.rects[24].h)
        local records=e.ReadingStatsPlan.build('reading-records',data,330,280,3)
        eq(records.labels[1].size,40); ok(has(records,'recorded pages, all time')); ok(has(records,'best day')); ok(has(records,'Reading 3 days running'))
    end)
    test('stats: per-field provenance never labels remote sessions as local',function()
        data.sources={days='all your devices',hours='this reader',records='this reader',
            longest_session_seconds='all your devices',best_day_pages='this reader',streak='all your devices'}
        data.local_today_seconds=600; data.display.local_today='10 m today · this reader (separate)'
        eq(e.ReadingStatsPlan.build('year-in-reading',data,600,300,2).source,nil)
        local week=e.ReadingStatsPlan.build('this-week',data,600,300,2)
        eq(week.source,nil); ok(has(week,'10 m today · this reader (separate)'))
        eq(e.ReadingStatsPlan.build('when-you-read',data,600,300,2).source,'This reader only')
        local records=e.ReadingStatsPlan.build('reading-records',data,600,300,2)
        eq(records.source,'Pages · this reader')
        ok(has(records,'best day · this reader')); ok(not has(records,'longest session · this reader'))
        data.sources.streak='this reader'
        ok(has(e.ReadingStatsPlan.build('reading-records',data,600,300,2),'streak · best 4 · this reader'))
        data.hours_available=false
        eq(e.ReadingStatsPlan.build('when-you-read',data,600,300,2).message,'Enable KOReader statistics')
        data.records_available=false; data.records.books_this_year=17
        local only=e.ReadingStatsPlan.build('reading-records',data,600,300,2)
        ok(has(only,'Local records unavailable')); ok(has(only,'17'))
        data.year=nil
        eq(e.ReadingStatsPlan.build('year-in-reading',data,600,300,2).message,'Reading days unavailable')
    end)
    test('stats: every read state has explicit copy and no invented values',function()
        for _,id in ipairs({'year-in-reading','this-week','when-you-read','reading-records'}) do
            for _,state in ipairs({'empty','error','not-saved','offline-without-data','loading'}) do
                local plan=e.ReadingStatsPlan.build(id,{state=state},330,180,2)
                ok(plan.message); eq(#plan.rects,0); eq(#plan.labels,0)
            end
        end
    end)

    -- Battery presentation regressions live in test_battery.lua after the F12-O display projection.
    test('reader duration helper: measured and unavailable values',function()
        eq(e.ReaderPanelPlan.duration(.5,true),'30 min')
        eq(e.ReaderPanelPlan.duration(54),'2 d 6 h')
        eq(e.ReaderPanelPlan.duration(-1),nil); eq(e.ReaderPanelPlan.duration(math.huge),nil)
    end)
end

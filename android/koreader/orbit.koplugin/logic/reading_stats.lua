-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Bounded geometry only. Companion owns dates, maxima, totals and provenance.
ReadingStatsPlan = {}
local titles = {['year-in-reading']='Year in reading', ['this-week']='This week',
    ['when-you-read']='When you read', ['reading-records']='Reading records'}
function ReadingStatsPlan.build(id, data, w, h, rows)
    assert(titles[id] and w >= 64 and h >= 64)
    local p = {title=titles[id], rects={}, labels={}}
    local function rect(x,y,rw,rh,level,outline)
        p.rects[#p.rects+1]={x=x,y=y,w=rw,h=rh,level=level,outline=outline}
    end
    local function label(x,y,text,size,bold,width)
        if text ~= nil then p.labels[#p.labels+1]={x=x,y=y,text=tostring(text),size=size,bold=bold,width=width} end
    end
    local sources=data and data.sources or {}
    local source_field=({['year-in-reading']='days',['this-week']='days',
        ['when-you-read']='hours',['reading-records']='records'})[id]
    if sources[source_field] == 'this reader' then
        local r=data.records or {}
        local mixedYear=id=='year-in-reading' and (r.books_this_year~=nil and sources.finished=='all your devices'
            or r.best_streak~=nil and sources.streak=='all your devices')
        p.source=id=='reading-records' and 'Pages · this reader' or mixedYear and 'Days · this reader' or 'This reader only'
    end
    local states={empty='No reading recorded',error='Reading statistics unavailable',
        ['not-saved']='Enable KOReader statistics',['offline-without-data']='Not saved yet',loading='Loading reading statistics'}
    if not data or (data.state ~= 'ready' and data.state ~= 'offline-with-data') then
        p.message=data and states[data.state] or 'Loading reading statistics'
        return p
    end
    local d=data.display or {}
    p.sourceInline=p.source and rows==1 and w>=300
    local top=p.source and not p.sourceInline and 48 or 30
    if id == 'year-in-reading' and not data.year then
        p.message='Reading days unavailable'; return p
    elseif id == 'when-you-read' and data.hours_available == false then
        p.message='Enable KOReader statistics'; return p
    elseif id == 'this-week' and not data.week then
        p.message='Reading days unavailable'; return p
    end
    if id == 'year-in-reading' then
        assert(data.year.intensity[365] ~= nil and data.year.intensity[366] == nil)
        local r=data.records or {}
        local function stat(x,value,caption)
            label(x,top,value,30,true); label(x,top+34,caption,12)
        end
        local compact=rows==2
        if compact then label(8,top,tostring(data.year.days_read)..' days read',16,true)
        else stat(8,data.year.days_read,'days read') end
        if not compact and r.books_this_year ~= nil then stat(w/3,r.books_this_year,'books finished'..(sources.finished=='this reader' and ' · this reader' or '')) end
        if not compact and r.best_streak ~= nil then stat(w*2/3,r.best_streak,'longest streak'..(sources.streak=='this reader' and ' · this reader' or '')) end
        local offset=data.year.weekday or 0
        local columns=math.ceil((365+offset)/7)
        local summary=compact and 40 or 68
        local size=math.max(1,math.floor(math.min((w-16)/columns,(h-top-summary-36)/7)))
        local left=math.floor((w-columns*size)/2)
        local y0=math.max(top+summary,math.floor((top+summary+h-36-7*size)/2))
        for _,m in ipairs(d.months or {}) do
            label(left+math.floor((m.day+offset)/7)*size,y0-16,m.label,10)
        end
        for i=1,365 do
            local level=data.year.intensity[i]; assert(level>=0 and level<=4)
            rect(left+math.floor((i-1+offset)/7)*size,y0+((i-1+offset)%7)*size,
                math.max(1,size-2),math.max(1,size-2),level,i==365)
        end
        local x=math.max(8,w-238)
        label(x,h-20,'Less',11)
        for level=0,4 do rect(x+30+level*14,h-18,10,10,level) end
        label(x+104,h-20,'More',11)
        rect(x+142,h-18,10,10,2,true); label(x+158,h-20,'Today',11)
    elseif id == 'this-week' then
        assert(data.week.levels[7] ~= nil and data.week.levels[8] == nil)
        local short=rows==1
        label(short and w-90 or 8,short and 4 or top,d.week_total or '—',short and 16 or 24,true)
        if rows ~= 1 and d.best_day then label(8,top+30,(d.week_comparison and d.week_comparison..' · best day ' or 'Best day ')..d.best_day,12) end
        local separate=d.local_today
        local bottom=h-(separate and 42 or short and 8 or 22)
        local chartTop=short and 30 or top+68
        local height=math.max(1,bottom-chartTop-(short and 0 or 18))
        local width=(w-16)/7
        for i=1,7 do
            local bh=height*data.week.levels[i]
            local bw=math.min(26,width-6); local x=8+(i-.5)*width-bw/2
            rect(x,bottom-bh,bw,bh,i==d.today_index and 4 or 2)
            if rows ~= 1 then
                label(x,bottom+4,({'M','T','W','T','F','S','S'})[i],11,i==d.today_index,width)
                if i==d.best_index then label(math.max(8,x-10),bottom-bh-16,d.best_duration,10,true) end
            end
        end
        rect(8,bottom,w-16,1,4)
        if separate then label(8,h-18,separate,11) end
    elseif id == 'when-you-read' then
        assert(data.hour_levels[24] ~= nil and data.hour_levels[25] == nil and data.hour_intensity[24] ~= nil and data.hour_intensity[25] == nil)
        local strip=rows==1
        if not strip then label(8,top,d.period,22,true) end
        local peak=d.peak or (data.peak_hour and (data.peak_hour..':00'))
        label(8,strip and top or top+28,peak and ('Most at '..peak..(data.after_18_percent and ' · '..data.after_18_percent..'% after 18:00' or '')) or 'No reading recorded',12)
        local bottom=h-(strip and 16 or 24)
        local height=math.max(1,bottom-top-(strip and 16 or 72))
        local width=(w-16)/24
        for i=1,24 do
            local bh=strip and math.min(22,height) or height*data.hour_levels[i]
            rect(8+(i-1)*width,bottom-bh,width-(strip and 2 or 0),bh,
                strip and data.hour_intensity[i] or (i-1==data.peak_hour and 4 or 2),strip and i-1==data.peak_hour)
        end
        if not strip then
            rect(8,bottom,w-16,1,4)
            if data.peak_hour then
                local x=8+(data.peak_hour+.5)*width
                label(math.min(w-48,math.max(8,x-16)),bottom-height-22,peak,11,true)
                rect(x-2,bottom-height-7,4,5,4)
            end
        end
        for i=0,3 do label(8+i*6*width,bottom+4,string.format('%02d',i*6),10) end
    else
        local r=data.records or {}
        local function caption(text,field)
            return text..(sources[field]=='this reader' and ' · this reader' or '')
        end
        local function metric(x,y,value,caption,width)
            label(x,y,value or '—',h<220 and 16 or 20,true,width); label(x,y+(h<220 and 20 or 24),caption,11,false,width)
        end
        local short=rows==1
        local available=data.records_available~=false and r.recorded_pages~=nil
        local compact=h<220
        label(8,top,available and (d.pages or r.recorded_pages) or '—',short and 24 or compact and 30 or 40,true)
        label(8,top+(short and 26 or compact and 32 or 44),available and 'recorded pages, all time' or 'Local records unavailable',12)
        local y=short and top or top+(compact and 54 or 78)
        local cw=(w-24)/(short and 4 or 2)
        local sx=short and 8+cw or 8
        if not short then rect(8,y-12,w-16,1,1) end
        metric(sx,y,d.longest,caption(r.longest_session_period=='week' and 'longest · this week' or 'longest session','longest_session_seconds'),cw-8)
        metric(sx+cw,y,r.best_day_pages and (r.best_day_pages..' pp'),caption('best day'..(d.record_day and ' · '..d.record_day or ''),'best_day_pages'),cw-8)
        local second=short and y or y+(compact and 40 or 58)
        metric(short and sx+2*cw or sx,second,r.books_this_year,caption('books this year','finished'),cw-8)
        if not short then
            metric(sx+cw,second,r.streak and (r.streak..' days'),caption('streak · best '..tostring(r.best_streak or '—'),'streak'),cw-8)
            if rows>=3 and r.streak~=nil then label(8,h-22,caption('Reading '..r.streak..' days running','streak'),13,true) end
        end
    end
    return p
end

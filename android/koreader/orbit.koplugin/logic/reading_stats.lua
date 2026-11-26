-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Geometry only: all totals, levels, maxima and dates come from the companion.
ReadingStatsPlan = {}
local titles = {['year-in-reading']='Year in reading', ['this-week']='This week',
    ['when-you-read']='When you read', ['reading-records']='Reading records'}
function ReadingStatsPlan.build(id, data, w, h, rows)
    assert(titles[id] and w >= 64 and h >= 64)
    local p = {title=titles[id], rects={}, labels={}}
    if not data or data.state ~= 'ready' then
        p.message = data and ({empty='No reading recorded', error='Reading statistics unavailable',
            ['not-saved']='Enable KOReader statistics'})[data.state] or 'Loading reading statistics'
        return p
    end
    local function rect(x,y,rw,rh,level) p.rects[#p.rects+1]={x=x,y=y,w=rw,h=rh,level=level} end
    local function label(x,y,text) p.labels[#p.labels+1]={x=x,y=y,text=text} end
    local sources=data.sources or {}
    local source_field=({['year-in-reading']='days',['this-week']='days',
        ['when-you-read']='hours',['reading-records']='records'})[id]
    if sources[source_field] == 'this reader' then
        p.source=id == 'reading-records' and 'Pages and sessions · this reader' or 'This reader'
    end
    local header=p.source and 16 or 0
    if id == 'year-in-reading' and not data.year then
        p.message='Reading days unavailable'; return p
    elseif id == 'when-you-read' and data.hours_available == false then
        p.message='Enable KOReader statistics'; return p
    elseif id == 'this-week' and not data.week then
        p.message='Reading days unavailable'; return p
    end
    if id == 'year-in-reading' then
        assert(#data.year.intensity == 365)
        local size = math.max(1, math.floor(math.min((w-16)/53,(h-66)/7)))
        local offset=data.year.weekday or 0
        for i=1,365 do
            local level=data.year.intensity[i]; assert(level>=0 and level<=4)
            local x,y=8+math.floor((i-1+offset)/7)*size,42+((i-1+offset)%7)*size
            if i == 365 then rect(x-1,y-1,size+1,size+1,4) end
            rect(x,y,size-1,size-1,level)
        end
        label(8,h-20,tostring(data.year.days_read)..' days read · '..data.year.start)
    elseif id == 'this-week' then
        assert(#data.week.seconds == 7 and #data.week.levels == 7)
        local separate=data.local_today_seconds ~= nil
        if separate then header=header+20 end
        local width=(w-16)/7; local height=math.max(1,h-92-header)
        for i=1,7 do
            rect(8+(i-1)*width,h-40-height*data.week.levels[i],width-4,height*data.week.levels[i],4)
            label(8+(i-1)*width,h-36,({'M','T','W','T','F','S','S'})[i])
            if rows ~= 1 then label(8+(i-1)*width,h-20,tostring(math.floor(data.week.seconds[i]/60))..'m') end
        end
        label(8,28+(p.source and 16 or 0),tostring(math.floor(data.week.total_seconds/60))..' min this week')
        if separate then label(8,28+header,tostring(math.floor(data.local_today_seconds/60))..'m today · this reader (separate)') end
    elseif id == 'when-you-read' then
        assert(#data.hour_levels == 24 and #data.hour_intensity == 24)
        local strip=rows == 1; local height=math.max(1,h-100-header); local width=(w-16)/24
        for i=1,24 do
            local bh=strip and math.min(22,height) or height*data.hour_levels[i]
            rect(8+(i-1)*width,h-32-bh,width-(strip and 1 or 0),bh,
                strip and data.hour_intensity[i] or (i-1==data.peak_hour and 4 or 2))
        end
        label(8,28+header,data.peak_hour and ('Most at '..data.peak_hour..':00 · '..data.after_18_percent..'% after 18:00') or 'No reading recorded')
        for i=0,3 do label(8+i*6*width,h-24,string.format('%02d',i*6)) end
    else
        local r=data.records
        if data.records_available ~= false then
            label(8,30+header,tostring(r.recorded_pages)..' recorded pages')
            label(8,52+header,tostring(math.floor(r.longest_session_seconds/60))..' min longest session')
        else label(8,30+header,'Local records unavailable') end
        if r.streak ~= nil then label(8,74+header,tostring(r.streak)..' day streak · best '..r.best_streak..
            (sources.streak == 'this reader' and ' · this reader' or '')) end
        if r.books_this_year ~= nil then label(8,96+header,tostring(r.books_this_year)..' books this year') end
    end
    return p
end

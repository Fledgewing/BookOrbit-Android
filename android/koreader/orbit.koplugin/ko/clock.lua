-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Snapshot-only clock. Dates and battery values are companion formatted; no timers.
ClockWidgets = {}
function ClockWidgets.render(p,snapshot,dispatch,rect)
    local finish=Budgets.span('clock.render',now_s,log)
    assert(Budgets.check(Budgets.get('widgets','clock'),{rows=1,bytes=snapshot.bytes,
        snapshotBytes=snapshot.bytes,spawns=0,network=0,roundTrips=0}))
    local w,h=rect.w-2,rect.h-2
    local scale=function(n) return Device.screen:scaleBySize(n) end
    local pad=scale(12)
    local canvas=HomeWidgets.canvas(w,h)
    local d=snapshot.data or {}
    if d.state~='ready' then
        HomeWidgets.text(canvas,'Clock',pad,pad,w-2*pad,18,false,true)
        local state=d.state or snapshot.state
        local message=(state=='not-saved' or state=='empty' or state=='offline-without-data') and 'Time unavailable'
            or state=='error' and 'Clock unavailable' or 'Loading clock'
        HomeWidgets.text(canvas,message,pad,pad+scale(30),w-2*pad,14)
    else
        local short=p.h==1
        local longTime=#(d.time or "")>5
        local timeSize=short and (longTime and 26 or 34) or p.w==1 and (longTime and 32 or 44) or 34
        HomeWidgets.text(canvas,d.time,pad,pad,w-2*pad,timeSize,false,true)
        local x=short and math.floor(w*.40) or pad
        local y=short and pad or pad+scale(p.w==1 and 56 or 40)
        HomeWidgets.text(canvas,d.weekday,x,y,w-x-pad,short and 14 or 18,false,true)
        HomeWidgets.text(canvas,d.date,x,y+scale(short and 24 or p.w==1 and 24 or 18),w-x-pad,14)
        if not short and p.w>=2 then
            local cell=(w-2*pad)/7
            for i,day in ipairs(d.days or {}) do
                local cx=pad+(i-1)*cell
                if day.today then
                    local c=HomeWidgets.canvas(cell,scale(30))
                    HomeWidgets.text(c,day.label,scale(4),0,cell-scale(8),11,true,true)
                    HomeWidgets.text(c,day.date,scale(4),scale(15),cell-scale(8),12,true,true)
                    HomeWidgets.put(canvas,HomeWidgets.ui().Frame:new{padding=0,margin=0,bordersize=0,
                        background=HomeWidgets.ui().BB.COLOR_BLACK,c},cx,y+scale(36))
                else
                    HomeWidgets.text(canvas,day.label,cx+scale(4),y+scale(36),cell-scale(8),11)
                    HomeWidgets.text(canvas,day.date,cx+scale(4),y+scale(51),cell-scale(8),12)
                end
            end
        end
        -- One 50px minimum target; dispatch uses the existing host Battery page owner.
        local bw=short and math.floor(w*.26) or w-2*pad
        HomeWidgets.button(canvas,d.battery or 'Battery ›',short and w-pad-bw or pad,
            short and math.max(0,math.floor((h-scale(50))/2)) or h-pad-scale(50),bw,scale(50),function() dispatch('battery') end)
    end
    finish()
    return HomeWidgets.ui().Frame:new{padding=0,margin=0,bordersize=1,canvas}
end
HomeWidgets.register('clock',ClockWidgets.render,function() return {op='device.clock',limit=1,twelve_hour=G_reader_settings:isTrue('twelve_hour_clock')} end)
WidgetRegistry.clock.renderers=WidgetRegistry.clock.renderers or {}
WidgetRegistry.clock.renderers['android-tablet']=ClockWidgets.render


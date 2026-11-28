import sys,time,json
from pathlib import Path
sys.path.insert(0,'tools/e2e/android')
from run import Emulator
D=Emulator('emulator-5574')
out=Path(sys.argv[1]) if len(sys.argv)>1 else Path('/tmp/booksync-x3-evidence')
out.mkdir(parents=True,exist_ok=True)
D.wait_companion(); D.dismiss_color_notice()
D.command('local env=getfenv(BatteryUI.widget);for _,f in ipairs({"logic/reading_stats.lua","ko/reading_stats.lua","ko/battery.lua"}) do setfenv(assert(loadfile("/sdcard/koreader/plugins/orbit.koplugin/"..f)),env)() end;return true')
D.command('Library.companion.setupLater();return true')
D.command('Library.settings.write("home_layout",nil);HomeHost.show();HomeHost.active:turn(1);return true')
D.wait_projection();time.sleep(1);D.shot(out/'stats.png')
code=r'''
local T=require('ui/widget/textwidget')
local BB=require('ffi/blitbuffer')
local base=T.paintTo
local boxes={}
T.paintTo=function(self,bb,x,y)
    local s=self:getSize()
    boxes[#boxes+1]={x=x,y=y,w=s.w,h=s.h,text=self.text}
    return base(self,bb,x,y)
end
local results={}
local success,err=pcall(function()
local data={state='ready',year={intensity={},days_read=257},week={levels={.2,.5,.1,1,.8,.1,.4}},
    hour_levels={},hour_intensity={},peak_hour=22,after_18_percent=71,
    records={recorded_pages=48210,longest_session_seconds=11520,best_day_pages=412,books_this_year=41,streak=12,best_streak=31},
    display={pages='48,210',week_total='7 h 8 m',today_index=7,best_index=4,best_day='Saturday',best_duration='1 h 52 m',
        period='Evenings',peak='22:00',longest='3 h 12 m',record_day='Sat 8 Mar',months={}}}
data.metrics={today={state='ready',value='1 h 20 m',separate='10 m · this reader, separate'},
 ['reading-streak']={state='ready',value='7 days',best='Longest: 12 days',days={0,4,4,0,4,4,4},days_source='Last seven days · this reader'},
 ['reading-goal']={state='ready',value='8 / 24 books · 2026',fraction=1/3,pace='Need 0.5 books / week',status='On pace'},
 ['pages-read']={state='ready',today='17',lifetime='2,345',definition='Timed page visits'},
 ['monthly-reading']={state='ready',levels={0,.1,.2,.3,.4,.5,.6,.7,.8,.9,1,.5},labels={'D','J','F','M','A','M','J','J','A','S','O','N'},total='20 h 10 m',previous='Previous month: 2 h 10 m',period='Dec 2025 – Nov 2026'}}
for i=1,365 do data.year.intensity[i]=i%5 end
for i=1,24 do data.hour_levels[i]=i/24;data.hour_intensity[i]=i%5 end
for i=0,11 do data.display.months[i+1]={day=i*30,label=({'Dec','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov'})[i+1]} end
local battery={state='ready',data={level=78,display={level='78%',estimate='≈ 2 d 6 h at your usual use',narrow_estimate='≈ 2 d 6 h · usual use',reading='19 h reading non-stop',standby='5 d 22 h standby only',reading_rate='Reading · 4.1 %/h',standby_rate='Standby · 0.6 %/h',used_week='76% used this week',last_charge='Charged Sun 21:10 · 12% → 100%'}}}
local scale=Device.screen:scaleBySize(100)/100
for _,id in ipairs({'year-in-reading','this-week','when-you-read','reading-records','today','reading-streak','reading-goal','pages-read','monthly-reading','battery'}) do
local cases={}
for _,size in ipairs(WidgetRegistry[id].sizes['android-tablet']) do cases[#cases+1]=size end
local mock={['year-in-reading']={1332,585,3},battery={654,383,2},['when-you-read']={654,383,2},['this-week']={654,585,3},['reading-records']={654,585,3}}
local extra=mock[id];if extra then cases[#cases+1]={extra[1],extra[3],pixels=extra,cols=id=='year-in-reading' and 4 or 2,name='mockup'} end
for _,size in ipairs(cases) do
    local gap=Device.screen:scaleBySize(12)
    local rect=HomeHostPlan.rect({x=0,y=0,w=size[1],h=size[2]},{cols=4,rows=8},Device.screen:getWidth()-2*gap,Device.screen:getHeight()-Device.screen:scaleBySize(172),gap)
    local w,h=rect.w,rect.h
    if size.pixels then w,h=size.pixels[1],size.pixels[2] end
    local widget
    if id=='battery' then widget=BatteryUI.widget({w=size.cols or size[1],h=size[2]},battery,function() end,{w=w,h=h})
    else widget=ReadingStatsWidgets.render(id,data,{w=w,h=h,rows=size[2]}) end
    boxes={}
    local bb=BB.new(math.ceil(w),math.ceil(h),BB.TYPE_BB8)
    bb:fill(BB.COLOR_WHITE)
    widget:paintTo(bb,0,0)
    for i,b in ipairs(boxes) do
        assert(b.x>=0 and b.y>=0 and b.x+b.w<=w and b.y+b.h<=h,id..' out of bounds '..b.text)
        for j=1,i-1 do local a=boxes[j]
            assert(b.x>=a.x+a.w or a.x>=b.x+b.w or b.y>=a.y+a.h or a.y>=b.y+b.h,id..' overlap '..a.text..' / '..b.text)
        end
    end
    bb:writePNG('/sdcard/koreader/e2e-x3-'..id..'-'..(size.name or size[1]..'x'..size[2])..'.png')
    results[#results+1]={id=id,size={size[1],size[2]},boxes=boxes}
    widget:free();bb:free()
end
end
local env=getfenv(BatteryUI.widget)
env.X3VisualPrevious={}
for _,name in ipairs({'year-in-reading','this-week','when-you-read','reading-records','battery'}) do
    local id=name
    env.X3VisualPrevious[id]=HomeWidgets.renderers[id]
    HomeWidgets.renderers[id]=function(p,snapshot,dispatch,rect)
        if id=='battery' then return BatteryUI.widget(p,battery,dispatch,rect) end
        return ReadingStatsWidgets.render(id,data,{w=rect.w-2,h=rect.h-2,rows=p.h})
    end
end
HomeHost.active:rebuild();UI:setDirty(HomeHost.active,'full')
end)
T.paintTo=base
assert(success,err)
return UIUtil.encode(results)
'''
result=D.command(code,timeout=60)
(out/'native-bounds.lua').write_text(result)
time.sleep(1);D.shot(out/'stats-fixture.png')
D.command('for id,render in pairs(X3VisualPrevious) do HomeWidgets.renderers[id]=render end;return true')
for path in D.shell('ls','/sdcard/koreader/e2e-x3-*.png').splitlines():
 D.adb('pull',path,out/Path(path).name.replace('e2e-x3-',''))
print(result[:300])

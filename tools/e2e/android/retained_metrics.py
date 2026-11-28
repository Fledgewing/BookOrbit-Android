#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Retained read-only metrics on the disposable native emulator.

The first check crosses the real companion projection bridge. Rich and unavailable
presentation states then use a temporary Library snapshot double; production
renderers, layout, geometry and batching stay intact. Model precedence is JVM-tested.
"""
import argparse
import json
from pathlib import Path
import sys
import time
sys.dont_write_bytecode=True
from run import Emulator

def review(device,out):
    out.mkdir(parents=True,exist_ok=True);device.wait_companion()
    def wait(code):
        deadline=time.monotonic()+40
        while device.command(code)!="ready":
            if time.monotonic()>deadline: raise TimeoutError("metric projection not published")
            time.sleep(.2)
    device.command('Library.companion.setupLater();local w=top();if w and type(w.text)=="string" and w.text:find("setup step",1,true) then click("Later") end;ReaderPanel.close();Library._metricsReview={read=LibraryAdapter.read,layout=Library.settings.read("home_layout")};HomeHost.show();return true')
    def assert_rendered():
        device.command('local seen={};local function visit(w,depth) if type(w)~="table" or seen[w] or depth>20 then return end;seen[w]=true;assert(w.text~="Couldn\'t load this widget","native renderer fell back to an error card");for i=1,#w do visit(w[i],depth+1) end end;visit(HomeHost.active,0);return true')
    count=0
    try:
        wait('local h=Library.paint("home");local d=h:widget("today"):read("reading.metrics",{op="reading.metrics",limit=1});h:flush();return d.metrics and d.metrics.today and d.metrics["pages-read"] and "ready" or "pending"')
        count+=1
        device.command('local t=Library._metricsReview;t.data={state="ready",freshness={saved=true},row_count=1,metrics={today={state="ready",source="all your devices",value="1 h 20 m",separate="10 m · this reader, separate"},["reading-streak"]={state="ready",source="all your devices",value="7 days",best="Longest: 12 days",days={0,4,4,0,4,4,4},days_source="Last seven days · this reader"},["reading-goal"]={state="ready",source="all your devices",value="8 / 24 books · 2026",fraction=1/3,pace="Need 0.5 books / week",status="On pace"},["pages-read"]={state="ready",source="this reader",today="17",lifetime="2,345",definition="Timed page visits"},["monthly-reading"]={state="ready",source="all your devices",levels={0,.1,.2,.3,.4,.5,.6,.7,.8,.9,1,.5},labels={"D","J","F","M","A","M","J","J","A","S","O","N"},total="20 h 10 m",previous="Previous month: 2 h 10 m",period="Dec 2025 – Nov 2026"}}};LibraryAdapter.read=function(raw,...) local a=Cache.decode(raw);if a.op=="reading.metrics" then return t.data,#UIUtil.encode(t.data) end;return t.read(raw,...) end;return true')
        for widget in ('today','reading-streak','reading-goal','pages-read','monthly-reading','finish-forecast'):
            sizes=int(device.command('return #WidgetRegistry['+json.dumps(widget)+'].sizes["android-tablet"]'))
            for i in range(1,sizes+1):
                device.command('local id='+json.dumps(widget)+';local size=WidgetRegistry[id].sizes["android-tablet"]['+str(i)+'];local d=Layout.default();d.pages={{id="metrics",tab="Home",name="Metrics review",placements={{instance="preview",widget=id,version=1,x=0,y=0,w=size[1],h=size[2],settings={}}}}};Library.settings.write("home_layout",d);HomeHost.show();assert(HomeHost.active.metrics.spawns==0 and HomeHost.active.metrics.network==0 and HomeHost.active.metrics.roundTrips==1);return true')
                assert_rendered();time.sleep(.3);device.shot(out/(widget+'-'+str(i)+'.png'));count+=1
        device.command('local t=Library._metricsReview;t.data.metrics["reading-goal"]={state="ready",source="all your devices",value="Target 24 · 2026",status="Completion count unavailable"};local d=Layout.default();d.pages={{id="unknown",tab="Home",name="Unknown completion",placements={{instance="goal",widget="reading-goal",version=1,x=0,y=0,w=2,h=2,settings={}}}}};Library.settings.write("home_layout",d);HomeHost.show();return true')
        assert_rendered();device.shot(out/'unknown-completion.png');count+=1
        device.command('local t=Library._metricsReview;for _,m in pairs(t.data.metrics) do m.state="unavailable";m.reason="Reading statistics unavailable" end;HomeHost.show();return true')
        assert_rendered();device.shot(out/'unavailable.png');count+=1
        print(str(count)+' native retained metric checks passed',flush=True)
    except Exception:
        device.shot(out/'failure.png');raise
    finally:
        device.command('local t=Library._metricsReview;if t then LibraryAdapter.read=t.read;Library.settings.write("home_layout",t.layout);Library._metricsReview=nil;HomeHost.show() end;return true')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--serial',required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();review(Emulator(a.serial),a.out)

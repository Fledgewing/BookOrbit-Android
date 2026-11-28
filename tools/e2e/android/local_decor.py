#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Real local decor rows/font on the disposable emulator, plus explicit missing states."""
import argparse
import json
from pathlib import Path
import re
import sys
import time
sys.dont_write_bytecode=True
from run import Emulator

def review(device,out):
    out.mkdir(parents=True,exist_ok=True);device.wait_companion()
    def wait(code):
        end=time.monotonic()+40
        while device.command(code)!="ready":
            if time.monotonic()>end:raise TimeoutError('Local decor projection not published')
            time.sleep(.2)
    def rendered():
        device.command('local seen={};local function visit(w,depth) if type(w)~="table" or seen[w] or depth>20 then return end;seen[w]=true;assert(w.text~="Couldn\'t load this widget","decor renderer fell back");for i=1,#w do visit(w[i],depth+1) end end;visit(HomeHost.active,0);return true')
    device.command('Library.companion.setupLater();local w=top();if w and type(w.text)=="string" and w.text:find("setup step",1,true) then click("Later") end;ReaderPanel.close();Library._decorReview={layout=Library.settings.read("home_layout"),face=Library.glyphFace,read=LibraryAdapter.read};HomeHost.show();return true')
    checks=0
    try:
        wait('local h=Library.paint("home");local m=h:widget("moon"):read("local.moon",{limit=1});local g=h:widget("glyph"):read("local.glyph",{limit=1});h:flush();if m.pending or g.pending then return "pending" end;assert(m.state=="ready" and g.state=="ready");assert(m.illumination>=0 and m.illumination<=100 and m.next);assert(g.sample and g.name and g.code);local face,name=Library.glyphFace(g.codepoint,60);assert(face and name,"actual interface font/glyph unavailable");return "ready"')
        checks+=1
        for widget in ('moon','glyph'):
            sizes=int(device.command('return #WidgetRegistry['+json.dumps(widget)+'].sizes["android-tablet"]'))
            for i in range(1,sizes+1):
                device.command('local id='+json.dumps(widget)+';local size=WidgetRegistry[id].sizes["android-tablet"]['+str(i)+'];local d=Layout.default();d.pages={{id="decor",tab="Home",name="Local decor",placements={{instance="preview",widget=id,version=1,x=0,y=0,w=size[1],h=size[2],settings={}}}}};Library.settings.write("home_layout",d);HomeHost.show();assert(HomeHost.active.metrics.spawns==0 and HomeHost.active.metrics.network==0 and HomeHost.active.metrics.roundTrips<=1);return true')
                rendered();device.shot(out/(widget+'-'+str(i)+'.png'));checks+=1
        device.command('Library.glyphFace=function() return nil end;HomeHost.show();return true')
        rendered();device.shot(out/'missing-glyph.png');checks+=1
        device.command('local t=Library._decorReview;Library.glyphFace=t.face;LibraryAdapter.read=function(raw,...) local op=Cache.decode(raw).op;if op=="local.glyph" or op=="local.moon" then return {state="unavailable",reason="Set the reader\'s date",row_count=1},100 end;return t.read(raw,...) end;HomeHost.show();return true')
        rendered();device.shot(out/'unknown-date.png');checks+=1
        print(str(checks)+' native local decor checks passed',flush=True)
        pid=device.shell('pidof','org.koreader.launcher').split()[0]
        log=device.shell('logcat','-d','--pid',pid,'-t','1200')
        profile={}
        for name in ('moon','glyph'):
            values=[float(v) for v in re.findall(r'BookSync local-widget\.'+name+r' ([0-9.]+) ms',log)]
            if values:profile[name]={'samples':len(values),'min_ms':min(values),'max_ms':max(values)}
        (out/'profile.json').write_text(json.dumps(profile,indent=2)+'\n')
        print(json.dumps(profile),flush=True)
    except Exception:
        device.shot(out/'failure.png');raise
    finally:
        device.command('local t=Library._decorReview;if t then Library.glyphFace=t.face;LibraryAdapter.read=t.read;Library.settings.write("home_layout",t.layout);Library._decorReview=nil;HomeHost.show() end;return true')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--serial',required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();review(Emulator(a.serial),a.out)

#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Render every shared kit component using actual KOReader widgets on an emulator."""
import argparse
import json
from pathlib import Path
import sys
import time
sys.dont_write_bytecode = True
from run import Emulator


def review(device, out):
    out.mkdir(parents=True, exist_ok=True)
    device.wait_companion()
    device.dismiss_color_notice()
    device.command('Library.companion.setupLater();return true')
    fixtures = {
        "pill": 'K.button{text="Resume",w=400}',
        "pill-outline": 'K.button{text="Search · 59",w=400,variant="outline"}',
        "icon-tile": 'K.iconTile{text="Search",icon="search",w=200}',
        "card": 'K.card{title="Recently added",count=59,all=function() end,w=900,h=220}',
        "cover-image": 'K.cover{file=SOURCE_DIR.."/ko/ui/icons/books.svg",w=152}',
        "cover-placeholder": 'K.cover{title="Seedfall",author="A. Vale",w=152}',
        "progress": 'K.progress{w=700,value=.38}',
        "segments": 'K.segments{w=700,items={"Cover","List","Compact"},selected=2}',
        "toggle-on": 'K.toggle{value=true}',
        "toggle-off": 'K.toggle{value=false}',
        "slider": 'K.slider{w=700,value=.4}',
        "row": 'K.row{text="Evening reads",sub="Saved filter",detail="12 ›",icon="book.opened",w=700}',
    }
    evidence = []
    for name, expression in fixtures.items():
        result = device.command('''local K=BookSyncUI.new(2);local widget='''+expression+''';
local s=widget:getSize();assert(s.w>0 and s.h>0)
local BB=require("ffi/blitbuffer");local bb=BB.new(math.ceil(s.w)+16,math.ceil(s.h)+16,BB.TYPE_BB8)
bb:fill(BB.COLOR_WHITE);widget:paintTo(bb,8,8)
bb:writeToFile("/sdcard/koreader/kit-render.png");bb:free();widget:free();return s.w.."x"..s.h''')
        device.adb("pull", "/sdcard/koreader/kit-render.png", str(out/(name+".png")))
        evidence.append({"component": name, "size": result})
    # Callback and edge-value regressions, with the production InputContainer handlers.
    device.command('''local K=BookSyncUI.new(2);local n=0
local b=K.button{text="Disabled",w=200,enabled=false,callback=function() n=n+1 end};b:onKitTap();assert(n==0);b:free()
b=K.button{text="Enabled",w=200,callback=function() n=n+1 end};local BB=require("ffi/blitbuffer");local bb=BB.new(600,300,BB.TYPE_BB8);b:paintTo(bb,200,100);assert(b.ges_events.KitTap[1]:match{ges="tap",pos={x=250,y=120,w=0,h=0}});assert(not b.ges_events.KitTap[1]:match{ges="tap",pos={x=10,y=10,w=0,h=0}});b:onKitTap();assert(n==1);bb:free();b:free()
local t=K.toggle{value=false,onChange=function(v) assert(v);n=n+1 end};t:onKitTap();assert(n==2);t:free()
local p=K.progress{w=200,value=0/0};assert(p.percentage==0);p:free()
p=K.progress{w=200,value=2};assert(p.percentage==1);p:free()
p=K.progress{w=200,value=-1};assert(p.percentage==0);p:free()
local s=K.slider{w=400,onChange=function(v) assert(v==.5);n=n+1 end};s.dimen.x=100;s:onKitTap(nil,{pos={x=300}});assert(n==3);s:free()
return true''')
    device.command('if HomeHost.active then UI:close(HomeHost.active) end;local w=BookSyncUI.gallery();UI:show(w);return true')
    time.sleep(.5)
    device.shot(out/"kit-gallery.png")
    (out/"render-tests.json").write_text(json.dumps(evidence, indent=2)+"\n")
    return evidence


if __name__ == "__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--serial",required=True)
    p.add_argument("--out",required=True,type=Path)
    a=p.parse_args()
    review(Emulator(a.serial),a.out)

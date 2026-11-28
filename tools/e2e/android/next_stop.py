#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Cached native TOC capture, real local projection and all approved card spans."""
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
        end=time.monotonic()+40
        while device.command(code)!="ready":
            if time.monotonic()>end:raise TimeoutError('Next stop did not publish')
            time.sleep(.2)
    def rendered():
        device.command('local seen={};local function visit(w,depth) if type(w)~="table" or seen[w] or depth>20 then return end;seen[w]=true;assert(w.text~="Couldn\'t load this widget");for i=1,#w do visit(w[i],depth+1) end end;visit(HomeHost.active,0);return true')
    device.command('Library.companion.setupLater();ReaderPanel.close();Library._nextReview={layout=Library.settings.read("home_layout"),read=LibraryAdapter.read};Library.open({local_path="/storage/emulated/0/Books/001 Seedfall.epub"});return true')
    checks=0
    try:
        wait('local ui=require("apps/reader/readerui").instance;return ui and ui.document and ui.document.file:find("001 Seedfall",1,true) and "ready" or "pending"')
        device.command('local ui=require("apps/reader/readerui").instance;ui.toc:onShowToc();ui.toc.toc_menu.close_callback();Library._nextReview.ui=ui;local n=Library.localWidgetNeed("next-stop");assert(n.native.path and n.native.chapter_total==5 and n.native.chapter_exact);assert(#n.native.chapters==0 and #n.native.bookmarks==0);Library.retry();HomeHost.show();return true')
        wait('local h=Library.paint("home");local n=Library.localWidgetNeed("next-stop");local r=h:widget("next-stop"):read(n.op,n);h:flush();if r.pending then return "pending" end;assert(r.state=="ready" and r.remaining and r.to_next and r.to_end);Library._nextReview.data=r;return "ready"')
        checks+=1
        for i in range(1,4):
            device.command('local z=WidgetRegistry["next-stop"].sizes["android-tablet"]['+str(i)+'];local d=Layout.default();d.pages={{id="next",tab="Home",name="Next stop",placements={{instance="preview",widget="next-stop",version=1,x=0,y=0,w=z[1],h=z[2],settings={}}}}};Library.settings.write("home_layout",d);HomeHost.show();assert(HomeHost.active.metrics.spawns==0 and HomeHost.active.metrics.network==0 and HomeHost.active.metrics.roundTrips<=1);return true')
            rendered();device.shot(out/('next-stop-'+str(i)+'.png'));checks+=1
        # Rich pace is a presentation double. Real borrowed-SQL pace and missing
        # identity are exercised by NextStopTest; the real TOC/IPC path ran above.
        device.command('local t=Library._nextReview;LibraryAdapter.read=function(raw,...) if Cache.decode(raw).op=="local.nextstop" then return {state="ready",row_count=1,current="Now: A very long current contents title",next="Next: Another long contents title",to_next="≈ 25 min to next",to_end="≈ 1 h 24 min to end",remaining="3 contents entries left",source="Measured pace · this reader"},200 end;return t.read(raw,...) end;HomeHost.show();return true')
        rendered();device.shot(out/'measured-pace.png');checks+=1
        device.command('local t=Library._nextReview;LibraryAdapter.read=function(raw,...) if Cache.decode(raw).op=="local.nextstop" then return {state="unavailable",row_count=1,reason="Open a book to see its next stop"},100 end;return t.read(raw,...) end;HomeHost.show();return true')
        rendered();device.shot(out/'no-book.png');checks+=1
        print(str(checks)+' native Next stop checks passed',flush=True)
    except Exception:
        device.shot(out/'failure.png');raise
    finally:
        device.command('local t=Library._nextReview;if t then LibraryAdapter.read=t.read;Library.settings.write("home_layout",t.layout);Library._nextReview=nil;HomeHost.show() end;return true')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--serial',required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();review(Emulator(a.serial),a.out)

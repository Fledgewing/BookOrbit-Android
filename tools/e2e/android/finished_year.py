#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Real cached connector year projections, native source picker and counted See all."""
import argparse
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
            if time.monotonic()>end:raise TimeoutError('Finished-year projection not published')
            time.sleep(.2)
    device.command('assert(LibraryAdapter.owner()=="emulator-fixture","run the standard account review first");Library.companion.setupLater();ReaderPanel.close();Library._yearReview={layout=Library.settings.read("home_layout")};local cfg=BookList.preset("year");local d=Layout.default();d.pages={{id="year",tab="Stats",name="Finished in year",placements={{instance="year",widget="booklist",version=1,x=0,y=0,w=4,h=3,settings=cfg}}}};Library.settings.write("home_layout",d);Library.retry();HomeHost.show();return true')
    try:
        wait('local h=Library.paint("home");local r=h:widget("booklist"):read("window",{source={kind="finished-year",key="current"},limit=4});h:flush();if r.pending then return "pending" end;assert(r.total==12 and r.context.finished_total==100);assert(r.items[1].finished_on and r.items[1].status_note);Library._yearReview.year=r.context.year;return "ready"')
        device.command('HomeHost.show();assert(HomeHost.active.metrics.roundTrips<=1 and HomeHost.active.metrics.network==0 and HomeHost.active.metrics.spawns==0);return true')
        wait('local r=Cache.decode(HomeHost.active.signatures.year);return not r.pending and r.context and r.context.finished_total==100 and "ready" or "pending"')
        device.shot(out/'current-year.png')
        device.command('local t=Library._yearReview;t.config=BookListConfig.new{cfg=BookList.preset("year"),caps=HomeHost.active.caps,onDone=function(cfg) t.cfg=cfg;return true end};t.config.sources=true;t.config:paint();return true')
        wait('local t=Library._yearReview;local wanted="Finished in "..tostring(t.year-1);for _,line in ipairs(t.config.dialog.buttons) do for _,b in ipairs(line) do if b.text:find(wanted,1,true) then b.callback();return "ready" end end end;for _,line in ipairs(t.config.dialog.buttons) do for _,b in ipairs(line) do if b.text=="›" and b.enabled~=false then b.callback();return "pending" end end end;return "pending"')
        device.command('local t=Library._yearReview;for _,line in ipairs(t.config.dialog.buttons) do for _,b in ipairs(line) do if b.text=="Done" then b.callback() end end end;assert(t.cfg.src=="year:"..tostring(t.year-1));local d=Library.settings.read("home_layout");d.pages[1].placements[1].settings=t.cfg;d.pages[1].placements[1].w=2;d.pages[1].placements[1].h=2;Library.settings.write("home_layout",d);HomeHost.show();return true')
        wait('local r=Cache.decode(HomeHost.active.signatures.year);return not r.pending and r.context and r.context.year==Library._yearReview.year-1 and "ready" or "pending"')
        device.shot(out/'past-year-small.png')
        device.command('local t=Library._yearReview;HomeHost.active:dispatch("all",nil,{widget="booklist",settings=t.cfg});assert(HomeHost.active.filter.model.source.kind=="finished-year");assert(HomeHost.active.filter.model.source.key==tostring(t.year-1));return true')
        wait('local r=HomeHost.active.list_result;return r and not r.pending and r.total==12 and r.context.finished_total==100 and "ready" or "pending"')
        device.shot(out/'past-year-selection.png')
        device.command('local t=Library._yearReview;local d=Library.settings.read("home_layout");d.pages[1].placements[1].settings=BookList.choose(BookList.preset("year"),{src="year:"..tostring(t.year+1),title="Future year"});Library.settings.write("home_layout",d);HomeHost.show();return true')
        wait('local h=Library.paint("home");local r=h:widget("booklist"):read("window",{source={kind="finished-year",key=tostring(Library._yearReview.year+1)},limit=1});h:flush();if r.pending then return "pending" end;assert(not r.freshness.saved and r.context.finished_total==nil);return "ready"')
        wait('local r=Cache.decode(HomeHost.active.signatures.year);return not r.pending and r.context and r.context.year==Library._yearReview.year+1 and "ready" or "pending"')
        device.shot(out/'unknown-year.png')
        print('4 native finished-year checks passed (real cache, native year picker, counted selection, unknown year)',flush=True)
    except Exception:
        device.shot(out/'failure.png');raise
    finally:
        device.command('local t=Library._yearReview;if t then if t.config then t.config:close() end;Library.settings.write("home_layout",t.layout);Library._yearReview=nil;HomeHost.show() end;return true')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--serial',required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();review(Emulator(a.serial),a.out)

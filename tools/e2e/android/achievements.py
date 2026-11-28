#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Native retained achievement spans from the real cached connector summary."""
import argparse
from pathlib import Path
import sys,time
sys.dont_write_bytecode=True
from run import Emulator

def review(d,out):
    out.mkdir(parents=True,exist_ok=True);d.wait_companion()
    def wait():
        end=time.monotonic()+40
        while d.command('local r=Cache.decode(HomeHost.active.signatures.badges);if not r or r.pending then return "pending" end;assert(r.state=="ready" and r.earned==3 and r.total==20 and r.latest:find("Saved milestone",1,true) and r.next:find("Next milestone",1,true));return "ready"')!='ready':
            if time.monotonic()>end:raise TimeoutError('Cached achievement summary was not published')
            time.sleep(.2)
    d.command('assert(LibraryAdapter.owner()=="emulator-fixture");Library.companion.setupLater();ReaderPanel.close();if PositionPrompt.current then click("Yes") end;HomeHost.show();Library._badgesReview={layout=Library.settings.read("home_layout")};return true')
    try:
        for w,h in [(2,2),(4,2),(2,3)]:
            d.command('local doc=Layout.default();doc.pages={{id="badges",tab="Insights",name="Achievements",placements={{instance="badges",widget="achievements",version=1,x=0,y=0,w='+str(w)+',h='+str(h)+',settings={}}}}};assert(Layout.validate(doc));Library.settings.write("home_layout",doc);HomeHost.show();return true')
            wait();d.command('local m=HomeHost.active.metrics;assert(m.roundTrips<=1 and m.network==0 and m.spawns==0);return true');d.shot(out/(str(w)+'x'+str(h)+'.png'))
        print('3 native Achievements checks passed (real cached counts/latest/next in every supported span)',flush=True)
    except Exception:
        d.shot(out/'failure.png');raise
    finally:
        d.command('local t=Library._badgesReview;if t then Library.settings.write("home_layout",t.layout);Library._badgesReview=nil;HomeHost.show() end;return true')
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--serial',required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();review(Emulator(a.serial),a.out)

#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Native retained-series selection through the real cached adapter, without HTTP."""
import argparse
from pathlib import Path
import sys,time
sys.dont_write_bytecode=True
from run import Emulator

def review(d,out):
    out.mkdir(parents=True,exist_ok=True);d.wait_companion()
    def wait(code):
        end=time.monotonic()+40
        while d.command(code)!='ready':
            if time.monotonic()>end:raise TimeoutError('Up next selection was not published')
            time.sleep(.2)
    wait('return LibraryAdapter.owner()=="emulator-fixture" and "ready" or "pending"')
    d.command('assert(LibraryAdapter.owner()=="emulator-fixture");Library.companion.setupLater();ReaderPanel.close();if PositionPrompt.current then click("Yes") end;HomeHost.show();Library._nextReview={layout=Library.settings.read("home_layout")};local cfg=BookList.preset("upnext");local doc=Layout.default();doc.pages={{id="next",tab="Home",name="Up next",placements={{instance="next",widget="booklist",version=1,x=0,y=0,w=4,h=3,settings=cfg}}}};assert(Layout.validate(doc),"invalid native fixture layout");Library.settings.write("home_layout",doc);HomeHost.show();return true')
    try:
        wait('local r=Cache.decode(HomeHost.active.signatures.next);if not r or r.pending then return "pending" end;assert(r.total==3 and r.items[1].title=="Retained book 9" and r.items[2].title=="Retained book 2" and r.items[3].title=="Retained book 5");assert(r.context.coverage:find("Saved selection",1,true));return "ready"')
        d.shot(out/'ranked-selection.png')
        d.command('local t=Library._nextReview;t.config=BookListConfig.new{origin=HomeHost.active,cfg=BookList.preset("recent"),caps=HomeHost.active.caps,onDone=function(cfg) t.cfg=cfg;return true end};t.config.sources=true;t.config:paint();return true')
        wait('local t=Library._nextReview;for _,line in ipairs(t.config.dialog.buttons) do for _,b in ipairs(line) do if b.text:find("Up next in series",1,true) then b.callback();return "ready" end end end;for _,line in ipairs(t.config.dialog.buttons) do for _,b in ipairs(line) do if b.text=="›" and b.enabled~=false then b.callback();return "pending" end end end;return "pending"')
        d.command('local t=Library._nextReview;for _,line in ipairs(t.config.dialog.buttons) do for _,b in ipairs(line) do if b.text=="Done" then b.callback() end end end;assert(t.cfg.src=="upnext" and t.cfg.sort==0);local doc=Library.settings.read("home_layout");local p=doc.pages[1].placements[1];p.settings=t.cfg;p.w=2;p.h=2;assert(Layout.validate(doc),"invalid native fixture layout");Library.settings.write("home_layout",doc);HomeHost.show();return true')
        wait('local r=Cache.decode(HomeHost.active.signatures.next);return r and not r.pending and r.total==3 and "ready" or "pending"')
        d.shot(out/'small-selection.png')
        d.command('HomeHost.active:dispatch("all",nil,{widget="booklist",settings=Library._nextReview.cfg});assert(HomeHost.active.filter.model.source=="series-next");return true')
        wait('local r=HomeHost.active.list_result;if not r or r.pending then return "pending" end;assert(r.total==3 and r.items[1].title=="Retained book 9");return "ready"')
        d.shot(out/'counted-selection.png')
        d.command('HomeHost.active:showList("Filtered saved selection","series-next",{q="Retained book 2"});return true')
        wait('local r=HomeHost.active.list_result;if not r or r.pending then return "pending" end;assert(r.total==1 and r.items[1].title=="Retained book 2");return "ready"')
        d.shot(out/'filtered-selection.png')
        print('4 native Up next checks passed (cached rank, source picker and small shelf, counted See all, filtered selection)',flush=True)
    except Exception:
        d.shot(out/'failure.png');raise
    finally:
        d.command('local t=Library._nextReview;if t then if t.config then t.config:close() end;Library.settings.write("home_layout",t.layout);Library._nextReview=nil;HomeHost.show() end;return true')
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--serial',required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args();review(Emulator(a.serial),a.out)

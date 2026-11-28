#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Distinct Pick back up shelf through real local projections and native Home/editor."""
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
            if time.monotonic()>end: raise TimeoutError('Pick back up projection not published')
            time.sleep(.2)
    device.command('Library.companion.setupLater();local w=top();if w and type(w.text)=="string" and w.text:find("setup step",1,true) then click("Later") end;ReaderPanel.close();Library._pickupReview={layout=Library.settings.read("home_layout")};Library.retry();HomeHost.show();return true')
    try:
        wait('local t=Library._pickupReview;local h=Library.paint("home");local current=h:widget("continue-reading"):read("window",{source="reading",query={},limit=1});local older=h:widget("booklist"):read("window",{source="pick-back-up",query={},limit=4});h:flush();if current.pending or older.pending or not current.items[1] or older.total~=current.total-1 then return "pending" end;for _,b in ipairs(older.items) do assert(b.key~=current.items[1].key) end;assert(older.items[1]);t.older=older;return "ready"')
        device.command('local t=Library._pickupReview;local d=Layout.default();d.pages={{id="pickup",tab="Home",name="Pick back up",placements={{instance="pickup",widget="booklist",version=1,x=0,y=0,w=4,h=3,settings=BookList.preset("pickup")}}}};Library.settings.write("home_layout",d);HomeHost.show();return true')
        device.shot(out/'pick-back-up-shelf.png')
        device.command('HomeHost.active:dispatch("all",nil,{widget="booklist",settings=BookList.preset("pickup")});local h=HomeHost.active;assert(h.filter.model.source=="pick-back-up" and h.filter.exclude_current);return true')
        wait('local h=HomeHost.active;return h.list_result and not h.list_result.pending and "ready" or "pending"')
        device.shot(out/'pick-back-up-list.png')
        device.command('local h=HomeHost.active;assert(h.list_result.total==Library._pickupReview.older.total);h:onClose();local t=Library._pickupReview;t.editor=HomeEditor.show(h);click("+ Page");click("Add widget");return true')
        for _ in range(20):
            if device.command('local e=Library._pickupReview.editor;local canvas=e[1][1];for _,node in ipairs(canvas) do if node.text=="Pick back up" then local y=node.overlap_offset[2]+Device.screen:scaleBySize(83);for _,button in ipairs(canvas) do if button.text=="Add" and button.overlap_offset[2]==y then button.callback();return "ready" end end end end;return "pending"')=='ready':break
            device.command('click("›");return true')
        else:raise AssertionError('Pick back up missing from native Add widget picker')
        device.command('local e=Library._pickupReview.editor;local found;for _,p in ipairs(e.model:page().placements) do if p.settings.src=="pickup" then found=p end end;assert(found and found.settings.title=="Pick back up");return true')
        device.shot(out/'pick-back-up-added.png')
        device.command('click("Done");Library._pickupReview.editor=nil;return true')
        print('4 native Pick back up checks passed (real source, distinct shelf, counted See all, native preset picker)',flush=True)
    except Exception:
        device.shot(out/'failure.png');raise
    finally:
        device.command('local t=Library._pickupReview;if t then if t.editor then t.editor:onClose() end;Library.settings.write("home_layout",t.layout);Library._pickupReview=nil;HomeHost.show() end;return true')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--serial',required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();review(Emulator(a.serial),a.out)

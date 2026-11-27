#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Native card dialogs and real companion removal on a disposable emulator.

Status transport/ordering is exercised by JVM adapter/journal tests. Its native
presentation uses a temporary Library test double; removal crosses the real
Library command bridge into DeviceStorage. No production renderer is replaced.
"""
import argparse
from pathlib import Path
import time
import sys
sys.dont_write_bytecode = True
from run import Emulator


def review(device, out):
    out.mkdir(parents=True, exist_ok=True)
    device.wait_companion()
    device.command('Library.companion.setupLater();HomeHost.show();return true')
    device.command('HomeHost.active:showList("Card review","all",{sort="title"});return true')
    def wait(code):
        deadline=time.monotonic()+20
        while device.command(code)!="ready":
            if time.monotonic()>deadline: raise TimeoutError("card action did not complete")
            time.sleep(.2)
    wait('return HomeHost.active.list_result and not HomeHost.active.list_result.pending and "ready" or "pending"')
    path=device.command('local h=HomeHost.active;local ui=require("apps/reader/readerui").instance;local current=ui and ui.document and ui.document.file;for _,r in ipairs(h.list_result.items) do if r.local_path and r.local_path~=current then Library._cardReview={row=r,status=Library.cardStatus,leave=Library.cardStatusLeave};return r.local_path end end;error("no closed fixture book")')
    saved=out/"synthetic-book.epub"
    device.adb("pull",path,saved)
    try:
        device.command('local t=Library._cardReview;t.sidecar=io.open(t.row.local_path:gsub("%.epub$",".sdr/metadata.epub.lua"),"rb");assert(t.sidecar);t.metadata=t.sidecar:read("*a");t.sidecar:close();t.released=0;t.undone=0;Library.cardStatus=function(_,token,done) if token then t.undone=t.undone+1;done({ok=true}) else done({token="native-fixture"}) end end;Library.cardStatusLeave=function() t.released=t.released+1 end;HomeHost.active:dispatch("status",t.row);return true')
        device.shot(out/"status-undo.png")
        device.command('click("Undo");assert(Library._cardReview.undone==1);assert(Library._cardReview.released==0);HomeHost.active:dispatch("status",Library._cardReview.row);click("Done");assert(Library._cardReview.released==1);return true')
        device.command('local t=Library._cardReview;Library.cardStatus=t.status;Library.cardStatusLeave=t.leave;HomeHost.active:dispatch("remove",t.row);return true')
        wait('return top().ok_text=="Remove" and "ready" or "pending"')
        device.shot(out/"remove-confirm.png")
        device.command('UI:close(top());local f=assert(io.open(Library._cardReview.row.local_path,"rb"));f:close();HomeHost.active:dispatch("remove",Library._cardReview.row);return true')
        wait('return top().ok_text=="Remove" and "ready" or "pending"')
        device.command('click("Remove");return true')
        wait('local t=Library._cardReview;local f=io.open(t.row.local_path,"rb");if f then f:close();return "pending" end;return "ready"')
        device.command('local t=Library._cardReview;local f=assert(io.open(t.row.local_path:gsub("%.epub$",".sdr/metadata.epub.lua"),"rb"));local metadata=f:read("*a");f:close();assert(metadata==t.metadata,"removal changed native metadata");return true')
        device.shot(out/"removed.png")
        print("4 native card checks passed (Undo, Done, cancel, remove with preserved sidecar)",flush=True)
    except Exception:
        device.shot(out/"failure.png")
        raise
    finally:
        device.push(saved,path)
        device.command('local t=Library._cardReview;if t then Library.cardStatus=t.status;Library.cardStatusLeave=t.leave;Library._cardReview=nil end;return true')

if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial",required=True)
    parser.add_argument("--out",type=Path,required=True)
    args=parser.parse_args();review(Emulator(args.serial),args.out)

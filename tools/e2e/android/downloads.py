#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Native download chooser/control flow with the disposable fixture adapter.

Uses the production durable control plane with fixture bytes; HTTP streaming,
validator recovery and real catalog linking are separate JVM integration tests.
"""
import argparse
import json
import uuid
from pathlib import Path
import sys
import time
sys.dont_write_bytecode=True
from run import Emulator

def review(device,out):
    out.mkdir(parents=True,exist_ok=True)
    device.wait_companion()
    key="fixture-download-review-"+uuid.uuid4().hex
    device.command('Library.companion.setupLater();HomeHost.show();Library._downloadReview={row={key='+json.dumps(key)+',title="Transfer review"}};return true')
    def wait(code):
        end=time.monotonic()+20
        while device.command(code)!="ready":
            if time.monotonic()>end: raise TimeoutError("native transfer control did not complete")
            time.sleep(.2)
    def wait_state(state):
        deadline=time.monotonic()+60
        while time.monotonic()<deadline:
            device.command('Library._downloadReviewReply=nil;local accepted=Library.downloadControl(Library._downloadReview.row,"status",function(result) Library._downloadReviewReply=result end);assert(accepted,"no live transfer job");return true')
            wait('return Library._downloadReviewReply and "ready" or "pending"')
            observed=device.command('return Library._downloadReviewReply.state or Library._downloadReviewReply.error or "unknown"')
            if observed==state: return
            time.sleep(.3)
        raise TimeoutError("native transfer stayed in "+observed+" instead of "+state)
    try:
        device.shell("svc","wifi","disable")
        device.shell("svc","data","disable")
        try:
            wait('return not NetworkMgr:isConnected() and "ready" or "pending"')
            device.command('HomeHost.active:dispatch("download",{key="fixture-offline-review",title="Offline review"});return true')
            device.shot(out/"offline-consent.png")
            device.command('assert(top().title=="Not downloaded — connect to get it");click("Cancel");assert(Library.downloadState("fixture-offline-review")==nil);return true')
        finally:
            device.shell("svc","wifi","enable")
            device.shell("svc","data","enable")
        wait('return NetworkMgr:isConnected() and "ready" or "pending"')
        device.command('HomeHost.active:dispatch("download",Library._downloadReview.row);return true')
        wait('return top().title and top().title:find("Download · Transfer review",1,true) and "ready" or "pending"')
        device.shot(out/"format-destination.png")
        device.command('click("EPUB · size unknown");return true')
        wait('local j=Library.downloadState(Library._downloadReview.row.key);return j and j.id and "ready" or "pending"')
        device.command('HomeHost.active:dispatch("download-cancel",Library._downloadReview.row);return true')
        wait_state("canceled")
        device.command('HomeHost.active:dispatch("download",Library._downloadReview.row);return true')
        device.shot(out/"resume.png")
        device.command('click("Resume");local h=HomeHost.active;UI:close(h);assert(HomeHost.active~=h);return true')
        wait_state("complete")
        device.command('assert(not HomeHost.foreground());local j=Library.downloadState(Library._downloadReview.row.key);local f=assert(io.open(j.local_path,"rb"));assert(f:read(2)=="PK");f:close();return true')
        device.shot(out/"finished-without-focus.png")
        print("5 native download checks passed (offline consent, chooser, cancel, Resume, no late open)",flush=True)
    except Exception:
        device.shot(out/"failure.png");raise
    finally:
        device.command('Library._downloadReview=nil;Library._downloadReviewReply=nil;return true')
        # This fixed path is exclusively created by the disposable fixture adapter.
        device.shell("rm","-f","/sdcard/BookSync/Transfer review.epub")

if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__);p.add_argument("--serial",required=True);p.add_argument("--out",type=Path,required=True)
    a=p.parse_args();review(Emulator(a.serial),a.out)

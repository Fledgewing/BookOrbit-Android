#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Approved Series preview and real durable queue controls on a disposable emulator."""
import argparse
import json
from pathlib import Path
import sys
import time
sys.dont_write_bytecode=True
from run import Emulator

def review(device,out):
    out.mkdir(parents=True,exist_ok=True)
    device.wait_companion()
    def wait(code):
        deadline=time.monotonic()+30
        while device.command(code)!="ready":
            if time.monotonic()>deadline: raise TimeoutError("native Series state did not complete")
            time.sleep(.2)
    def dialog(prefix):
        wait('return top().title and top().title:find('+json.dumps(prefix,ensure_ascii=False)+',1,true)==1 and "ready" or "pending"')
    try:
        device.command('Library.companion.setupLater();HomeHost.show();local h=HomeHost.active;for i=#UI._window_stack,1,-1 do local w=UI._window_stack[i] and UI._window_stack[i].widget;if w==h then break end;if w then UI:close(w) end end;h:showSeries("The Glass Orchard");SeriesUI.download(h);return true')
        # A previous failed run may have left a retained queue: cancel explicitly,
        # then start the next preview rather than erasing the durable journal.
        wait('return top()~=HomeHost.active and "ready" or "pending"')
        title=device.command('return top().title or ""')
        if not title.startswith("Download next"):
            device.command('click("Cancel remaining");return true')
            wait('return top().title and top().title:find("0 failed",1,true) and "ready" or "pending"')
            device.command('click("Back");SeriesUI.download(HomeHost.active);return true')
        dialog("Download next 3")
        device.shot(out/"preview.png")
        device.command('assert(top().buttons[3][1].text:find("Series review 3",1,true));assert(top().buttons[3][1].text:find("size unknown",1,true));click("Change number (1–10)");local input;for _,window in ipairs(UI._window_stack) do if window.widget.setInputText then input=window.widget end end;assert(input);input:setInputText("2");input.buttons[1][2].callback();return true')
        dialog("Download next 2")
        device.shot(out/"count-two.png")
        device.command('click("Review files");return true')
        dialog("Choose file · Series review 1")
        device.command('click("EPUB · size unknown");return true')
        dialog("Choose file · Series review 2")
        device.command('click("PDF · size unknown");return true')
        dialog("Download 2 books?")
        device.shot(out/"exact-files.png")
        device.command('assert(top().buttons[1][1].text:find("EPUB",1,true));assert(top().buttons[2][1].text:find("PDF",1,true));click("Start downloads");return true')
        wait('return top().title and top().title:find("2 requested",1,true) and "ready" or "pending"')
        device.shot(out/"queue.png")
        device.command('local d=top();local label=d.buttons[1][1].text;assert(label:find("Series review 1",1,true));click(label);return true')
        wait('return top().title and top().title:find("1 skipped",1,true) and "ready" or "pending"')
        device.command('click("Cancel remaining");return true')
        wait('return top().title and top().title:find("2 skipped",1,true) and "ready" or "pending"')
        device.shot(out/"canceled.png")
        device.command('click("Back");local h=HomeHost.active;UI:close(h);assert(not HomeHost.foreground());return true')
        device.shot(out/"no-late-open.png")
        print("6 native Series checks passed (preview, count, file choices, queue, per-row/all cancel, no auto-open)",flush=True)
    except Exception:
        device.shot(out/"failure.png");raise

if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__);p.add_argument("--serial",required=True);p.add_argument("--out",type=Path,required=True)
    a=p.parse_args();review(Emulator(a.serial),a.out)

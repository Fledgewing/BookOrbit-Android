#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Native local completion/goal flows on an explicitly verified disposable emulator."""
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
    checks=[]
    def wait(code):
        deadline=time.monotonic()+40
        while device.command(code)!="ready":
            if time.monotonic()>deadline:raise TimeoutError('Local reading projection did not settle')
            time.sleep(.2)
    def check(name,code):
        device.command(code)
        device.shot(out/(name+'.png'))
        checks.append(name)
        (out/'checks.json').write_text(json.dumps(checks,indent=2)+'\n')
    def input(value,button=3):
        device.command('local input;for _,w in ipairs(UI._window_stack) do if w.widget.setInputText then input=w.widget end end;assert(input);input:setInputText('+json.dumps(value)+');input.buttons[1]['+str(button)+'].callback();return true')
    def local_ready(extra=''):
        wait('local p=Library.paint("settings-reading-statistics");local r=p:localReading();p:flush();if r.pending then return "pending" end;'+extra+';return "ready"')
    device.command('Library.companion.setupLater();if HomeHost.show then HomeHost.show() end;return true')
    # These are actual Library/companion reads, never a replacement model.
    local_ready('assert(r.completion_available);Library._localReview={before=r.books_this_year}')
    before=int(device.command("return Library._localReview.before"))
    check('local-summary','LocalReadingSettings.open();return true')
    wait('return SettingsView.active and SettingsView.active.dialog and #SettingsView.active.dialog.buttons>0 and "ready" or "pending"')
    device.command('SettingsView.active.dialog.buttons[1][1].callback();return true')
    check('number-keyboard-bottom','local input,kb;for _,w in ipairs(UI._window_stack) do if w.widget.setInputText then input=w.widget end;if w.widget.name=="VirtualKeyboard" or w.widget.layout then kb=w.widget end end;assert(input and input.input_type=="number");local d=input._input_widget:getKeyboardDimen();assert(d.y+d.h==Device.screen:getHeight(),"keyboard must dock at bottom");return true')
    input('12')
    wait('return SettingsView.active.make()[1].note_func():find("12 books",1,true) and "ready" or "pending"')
    check('goal-saved','assert(SettingsView.active.make()[1].note_func():find("This reader only",1,true));SettingsView.active:close();LocalReadingSettings.open();return true')
    local_ready('assert(r.target==12)')
    check('goal-reopened','assert(SettingsView.active.make()[1].note_func():find("12 books",1,true));return true')
    device.command('SettingsView.active.dialog.buttons[1][1].callback();return true');input('',2)
    wait('return SettingsView.active.make()[1].note_func():find("Off",1,true) and "ready" or "pending"')
    check('goal-off','SettingsView.active:close();return true')
    device.command('Library.open({local_path="/storage/emulated/0/Books/002 The Pruning.epub"});return true')
    wait('local ui=require("apps/reader/readerui").instance;return ui and ui.document and "ready" or "pending"')
    device.command('local ui=require("apps/reader/readerui").instance;Library._localReview.ui=ui;Library._localReview.native=ui.doc_settings:readSetting("summary");ui.status:markBook(true);return true')
    local_ready('if r.books_this_year~=Library._localReview.before+1 then return "pending" end')
    check('explicit-finish','local ui=Library._localReview.ui;assert(reading());assert(not FinishUI.sheet);ui.status:markBook(false);return true')
    local_ready('if r.books_this_year~=Library._localReview.before then return "pending" end')
    check('undo','Library._localReview.ui.status:markBook(true);return true')
    local_ready('if r.books_this_year~=Library._localReview.before+1 then return "pending" end')
    check('refinish','local ui=Library._localReview.ui;Library.prepareLocalCompletion(ui);Library.prepareLocalCompletion(ui);return true')
    local_ready('assert(r.books_this_year==Library._localReview.before+1)')
    # Native close flushes KOReader's own settings; restart replays exactly the saved event.
    device.command('local ui=Library._localReview.ui;ui:onClose();HomeHost.show();LocalReadingSettings.open();return true')
    device.shell('am','force-stop','org.koreader.launcher')
    device.shell('am','start','-n','org.koreader.launcher/.MainActivity')
    device.wait_companion()
    local_ready('assert(r.books_this_year=='+str(before+1)+' and r.target==nil)')
    check('restart-offline-labels','LocalReadingSettings.open();return true')
    device.shell('svc','wifi','disable');device.shell('svc','data','disable')
    try:
        local_ready('assert(r.count_label:find("This reader only",1,true));assert(r.goal_label:find("Off",1,true))')
        check('offline-local-summary','return true')
    finally:
        device.shell('svc','wifi','enable');device.shell('svc','data','enable')
    print(str(len(checks))+' native local-completion checks passed',flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--serial',required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();review(Emulator(a.serial),a.out)

#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Approved menu recommendations through the native reader and real companion plan."""
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
            if time.monotonic()>end: raise TimeoutError("native recommendation pass did not complete")
            time.sleep(.2)
    def pass_settings():
        device.command('Library._menuReview.done=false;Library.preferences.pass("native review",nil,false,function() Library._menuReview.done=true end);return true')
        wait('return Library._menuReview.done and not Recommendations.pending and "ready" or "pending"')
    def clear_setup_prompt():
        # A changed recommendation report may publish a new checklist signature.
        # Acknowledge only that known overlay, leaving the action dialog intact.
        time.sleep(.5)
        device.command('local w=top();if w and type(w.text)=="string" and w.text:find("setup step",1,true) then click("Later") end;Library.companion.setupLater();return true')
    def open_clean():
        clear_setup_prompt()
        device.command('local t=Library._menuReview;local p=Library.controller();if p.rec_menu then UI:close(p.rec_menu);p.rec_menu=nil end;p:showRecommended("native review");local found;for _,item in ipairs(p.rec_menu.item_table) do if item.text=="BookSync: Reading menus" then found=item end end;assert(found,"tenth recommendation missing from native review");found.callback();return true')
    device.command('Library.companion.setupLater();ReaderPanel.close();Library.open({local_path="/storage/emulated/0/Books/001 Seedfall.epub"});return true')
    wait('local ui=require("apps/reader/readerui").instance;return ui and ui.document and ui.gestures and #Recommendations.items==10 and not Recommendations.pending and "ready" or "pending"')
    try:
        device.command('local ui=require("apps/reader/readerui").instance;local t={ui=ui,record=S.recommended,backup=S.recommended_backup,clean=S.clean_menus,snapshot=Recommendations.snapshot,cached=LibraryAdapter.recommendations,subscriber=Recommendations.onSnapshot,line=Recommendations.line_pending,reviewed=Recommendations.reviewed,values={}};Library._menuReview=t;for _,item in ipairs(Recommendations.items) do local prior;if item.kind=="connector" then prior=Library.observeSetting(item).current;Library.writeSetting(item,Library.observeSetting(item).default) elseif item.kind=="ko" then prior=G_reader_settings:readSetting(item.key);if item.stock==nil then G_reader_settings:delSetting(item.key) else G_reader_settings:saveSetting(item.key,item.stock) end elseif item.kind=="gesture" then prior=ui.gestures.data.gesture_reader[item.key];ui.gestures.data.gesture_reader[item.key]=ui.gestures.default_settings.data.gesture_reader[item.key] else prior=S[item.key];Library.setReaderMenus(ui,nil) end;t.values[#t.values+1]={item=item,value=prior} end;ui.gestures:onFlushSettings();S.recommended=nil;S.recommended_backup=nil;Recommendations.items={};return true')
        pass_settings()
        device.command('assert(S.clean_menus==true);assert(S.recommended.items["o.clean_menus"]=="applied");assert(next(Library._menuReview.ui.gestures.data.gesture_reader.tap_top_left_corner)==nil);assert(#Recommendations.snapshot.items==10);return true')
        open_clean();clear_setup_prompt();device.shot(out/"applied-menu-undo.png")
        device.command('click("Undo");return true')
        wait('return not Recommendations.pending and S.clean_menus==nil and S.recommended.items["o.clean_menus"]=="kept" and "ready" or "pending"')
        device.command('local p=Library.controller();if p.rec_menu then UI:close(p.rec_menu);p.rec_menu=nil end;S.recommended=nil;S.recommended_backup=nil;Library._menuReview.ui.gestures.data.gesture_reader.tap_top_left_corner={toggle_night_mode=true};Library._menuReview.ui.gestures:onFlushSettings();return true')
        pass_settings()
        device.command('assert(S.clean_menus==nil);assert(S.recommended.items["o.clean_menus"]=="conflict");assert(Library._menuReview.ui.gestures.data.gesture_reader.tap_top_left_corner.toggle_night_mode);return true')
        open_clean();clear_setup_prompt();device.shot(out/"customized-review.png")
        device.command('click("Use BookSync\'s");return true')
        wait('return not Recommendations.pending and S.clean_menus==true and S.recommended.items["o.clean_menus"]=="applied" and "ready" or "pending"')
        device.command('assert(Library._menuReview.ui.gestures.data.gesture_reader.tap_top_left_corner.toggle_night_mode);return true')
        open_clean();clear_setup_prompt();device.command('click("Undo");return true')
        wait('return not Recommendations.pending and S.clean_menus==nil and S.recommended.items["o.clean_menus"]=="kept" and "ready" or "pending"')
        pass_settings()
        device.command('assert(S.clean_menus==nil);assert(S.recommended.items["o.clean_menus"]=="kept");return true')
        print("5 native menu recommendation checks passed (first fetch, ten-row review, pristine defaults, custom preservation, explicit opt-in/Undo)",flush=True)
    except Exception:
        device.shot(out/"failure.png");raise
    finally:
        device.command('local t=Library._menuReview;if t then local p=Library.controller();if p.rec_menu then UI:close(p.rec_menu);p.rec_menu=nil end;for _,saved in ipairs(t.values) do local item,value=saved.item,saved.value;if item.kind=="connector" then Library.writeSetting(item,value) elseif item.kind=="ko" then if value==nil then G_reader_settings:delSetting(item.key) else G_reader_settings:saveSetting(item.key,value) end elseif item.kind=="gesture" then t.ui.gestures.data.gesture_reader[item.key]=value end end;t.ui.gestures:onFlushSettings();Library.setReaderMenus(t.ui,t.clean);S.recommended=t.record;S.recommended_backup=t.backup;Recommendations.snapshot=t.snapshot;LibraryAdapter.recommendations=t.cached;Recommendations.onSnapshot=t.subscriber;Recommendations.line_pending=t.line;Recommendations.reviewed=t.reviewed;saveSettings();Library._menuReview=nil end;return true')

if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__);p.add_argument("--serial",required=True);p.add_argument("--out",type=Path,required=True)
    a=p.parse_args();review(Emulator(a.serial),a.out)

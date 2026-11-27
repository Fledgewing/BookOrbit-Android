#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise real KOReader widgets against the emulator fixture adapter; keep PNG evidence.

Run setup first. Commands use the same screen entry points and callbacks as taps; no
production test port, HTTP daemon, replacement renderer or release signing key is used.
"""
import argparse
import json
from pathlib import Path
import time
import sys
sys.dont_write_bytecode = True
from run import Emulator

def review(device, out):
    out.mkdir(parents=True,exist_ok=True)
    device.wait_companion()
    device.command('Library.companion.setupLater();local w=top();if w and type(w.text)=="string" and w.text:find("setup steps",1,true) then click("Later") end;return true')
    time.sleep(1)
    device.command('Library.settings.refresh("emulator-review");return true')
    evidence=[]
    def step(name,code,check=None):
        result=device.command(code)
        time.sleep(1)
        deadline=time.monotonic()+20
        while device.command('local h=HomeHost.active;local front=top();local pending=AccountView.active and AccountView.active.busy or h and front==h and ((h.list_result and h.list_result.pending) or (h.series_result and h.series_result.pending));return pending and "pending" or "ready"')=="pending":
            if time.monotonic()>deadline: raise TimeoutError(name+" did not publish its projection")
            time.sleep(.2)
        if check: device.command(check)
        device.shot(out/(name+".png"))
        evidence.append({"screen":name,"result":result})
        (out/"review.json").write_text(json.dumps(evidence,indent=2)+"\n")
        print(name,flush=True)
    def close(): device.command('UI:close(top());return true')
    step("home",'Library.settings.write("home_layout",nil);assert(HomeHost.show());return HomeHost.active.name')
    step("home-second-page",'HomeHost.active:turn(1);return HomeHost.active.index')
    step("editor",'HomeEditor.show(HomeHost.active);return true')
    step("editor-picker",'click("Add widget");return true')
    # Explicitly close the editor, preserving the saved layout.
    close()
    step("account",'AccountView.open();return AccountView.active.page')
    step("signin",'AccountView.active:form("account");return true')
    step("signin-result",'AccountView.active:command("account.signIn",{server="https://fixture.example.test",username="reader",password="fixture"});return true',
         'assert(AccountView.active.state.signedIn);return true')
    device.command('AccountView.active:close();HomeHost.show();return true')
    step("library",'HomeHost.active:showList("All books","all",{sort="title"});return true',
         'assert(HomeHost.active.list_result.total==59);assert(#HomeHost.active.list_result.items<=24);return true')
    step("filter",'HomeHost.active.filter:header(HomeHost.active.list_result.total).callback();return true')
    close()
    step("series",'SeriesUI.show("The Glass Orchard");return true',
         'assert(HomeHost.active.series_result.total==5);return true')
    step("storage",'StorageUI.show();return true')
    close()
    for group in ("sync","library","reading","home","sleep","updates","about"):
        step("settings-"+group,'plugin:showSettings("'+group+'");return true')
        close()
    device.command('HomeHost.show();return true')
    installed=device.command('local ids={};for id in pairs(HomeHost.installed()) do ids[#ids+1]=id end;table.sort(ids);return table.concat(ids,",")').split(',')
    # Each renderer receives its existing contract's first permitted tablet size.
    # Restore default pages afterwards; these previews are never saved.
    for widget in installed:
        step("widget-"+widget,'local id="'+widget+'";local size=WidgetRegistry[id].sizes["android-tablet"][1];local d=Layout.default();d.pages={{id="preview",tab="Home",name=id,placements={{instance="preview",widget=id,version=1,x=0,y=0,w=size[1],h=size[2],settings={}}}}};Library.settings.write("home_layout",d);HomeHost.show();return true')
    device.command('Library.settings.write("home_layout",nil);HomeHost.show();return true')
    step("open-book",'Library.open({local_path="/storage/emulated/0/Books/001 Seedfall.epub"});return true')
    step("reader-top",'ReaderPanel.show(require("apps/reader/readerui").instance,"reader-top-panel");return true')
    device.command('ReaderPanel.close();return true')
    step("reader-bottom",'ReaderPanel.show(require("apps/reader/readerui").instance,"reader-bottom-panel");return true')
    device.command('ReaderPanel.close();return true')
    for key in ("font","spacing","margins","contrast"):
        step("custom-"+key,'CustomReading.open("'+key+'",require("apps/reader/readerui").instance);return true')
        close()
    device.shell("run-as","net.fledgewing.orbitcompanion","rm","-f","files/e2e-position.lua")
    step("position-sync",'local ui=require("apps/reader/readerui").instance;(ui.paging or ui.rolling):onGotoPage(1);ReadingSync.run("manual",function() end);return true',
         'assert(PositionPrompt.current,"expected remote-ahead consent");return true')
    step("position-accepted",'click("Yes");return true',
         'assert(not PositionPrompt.current);assert(require("apps/reader/readerui").instance.document:getCurrentPage()==5);return true')
    step("end-of-book",'local ui=require("apps/reader/readerui").instance;(ui.paging or ui.rolling):onGotoPage(ui.document:getPageCount());FinishUI.showSheet(ui,Library.nativeReader(ui));return true')
    step("end-view-series",'local sheet=FinishUI.sheet;assert(sheet);assert(sheet.model.series_key);FinishUI.actions.series(sheet.ui,sheet.book,sheet.model.series_key);return true',
         'assert(HomeHost.active.series_result.total==5);return true')
    step("full-refresh",'Library.fullRefresh();return true',
         'assert(LibraryAdapter.owner()=="emulator-fixture");assert(type(LibraryAdapter.account_snapshot)=="table");return true')
    device.shell("svc","wifi","disable")
    try:
        step("offline-library",'HomeHost.show();HomeHost.active:showList("Offline books","all",{sort="title"});return true',
             'assert(HomeHost.active.list_result.total==59);return true')
    finally: device.shell("svc","wifi","enable")
    return evidence

if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial",required=True);parser.add_argument("--out",required=True,type=Path)
    args=parser.parse_args();review(Emulator(args.serial),args.out)

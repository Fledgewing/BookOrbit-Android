#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Upgrade an isolated emulator from a supplied main snapshot, then verify a clean install.

The legacy checkout and APK must be built from the same main commit. No fetch, release,
tag, real-device install or modification of either source checkout is performed here.
"""
import argparse
from pathlib import Path
import time
import sys
sys.dont_write_bytecode = True
import run

def reset_profile(device):
    installed=set(device.shell("pm","list","packages").splitlines())
    for package in ("org.koreader.launcher",run.PACKAGE):
        if "package:"+package in installed:
            device.shell("am","force-stop",package)
            device.shell("pm","clear",package)
    device.shell("mkdir","-p","/sdcard/koreader")
    device.shell("mv","/sdcard/koreader","/sdcard/koreader-upgrade-"+str(time.time_ns()))

def verify(device,legacy_source,legacy_apk,apk,koreader,apksigner,out):
    out.mkdir(parents=True,exist_ok=True)
    reset_profile(device)
    source=run.ROOT
    try:
        run.ROOT=legacy_source.resolve()
        run.setup(device,legacy_apk,koreader,apksigner)
    finally: run.ROOT=source
    time.sleep(2)
    device.command('S.review_upgrade_marker="upgrade-fixture";Shared.set("wifi_idle_min",7);saveSettings();G_reader_settings:flush();return PATCH_VERSION')
    device.shot(out/"upgrade-011.png")
    run.setup(device,apk,koreader,apksigner)
    time.sleep(2)
    device.command('assert(S.home_012_migrated);assert(S.home_screen=="booksync");assert(S.wifi_idle_min==7);assert(S.review_upgrade_marker=="upgrade-fixture");assert(S.news_012_pending);assert(HomeHost.show());return true')
    # Setup reminders are unrelated to migration and may precede the news sheet.
    device.command('if UI:getTopmostVisibleWidget().text and UI:getTopmostVisibleWidget().text:find("setup steps",1,true) then click("Later") end;return true')
    device.shot(out/"upgrade-012-news.png")
    device.command('click("Done");assert(not S.news_012_pending);HomeHost.show();return true')
    device.shot(out/"upgrade-012-acknowledged.png")
    reset_profile(device)
    run.setup(device,apk,koreader,apksigner)
    time.sleep(2)
    device.command('assert(S.home_012_migrated);assert(S.home_screen=="booksync");assert(not S.news_012_pending);assert(not S.review_upgrade_marker);assert(HomeHost.show());return true')
    device.shot(out/"fresh-012.png")

if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial",required=True)
    for name in ("legacy-source","legacy-apk","apk","koreader","apksigner","out"):
        parser.add_argument("--"+name,required=True,type=Path)
    args=parser.parse_args()
    verify(run.Emulator(args.serial),args.legacy_source,args.legacy_apk,args.apk,args.koreader,args.apksigner,args.out)

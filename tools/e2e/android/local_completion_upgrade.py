#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Proven 0.11 local completion import, preserving synthetic user state byte-for-byte."""
import argparse
from pathlib import Path
import sys
import time
sys.dont_write_bytecode=True
import run
from upgrade import reset_profile


def verify(device,legacy_source,legacy_apk,apk,koreader,apksigner,out):
    out.mkdir(parents=True,exist_ok=True)
    reset_profile(device)
    source=run.ROOT
    try:
        run.ROOT=legacy_source.resolve()
        run.setup(device,legacy_apk,koreader,apksigner)
    finally: run.ROOT=source
    time.sleep(2)
    device.command('S.review_upgrade_marker="completion-upgrade";Shared.set("wifi_idle_min",7);saveSettings();G_reader_settings:flush();return true')
    device.shell("cp '/sdcard/Books/001 Seedfall.epub' /sdcard/Books/Legacy-local.epub")
    device.command('require("apps/reader/readerui"):showReader("/storage/emulated/0/Books/Legacy-local.epub");return true')
    time.sleep(2)
    # A real native explicit mark, with a synthetic retained 0.11 queue entry. No server
    # adapter is installed in this legacy profile, and no attestation is involved.
    device.command('local ui=require("apps/reader/readerui").instance;ui.status:markBook(true);local hash=ui.doc_settings:readSetting("partial_md5_checksum");local summary=ui.doc_settings:readSetting("summary");assert(summary.status=="complete");EOB.queue()[hash]=Finish.newJob{hash=hash,file=ui.document.file,finished_on=summary.modified,now=os.time()};EOB.save();ui.doc_settings:saveSetting("completion_upgrade_sentinel","keep");ui:onClose();return true')
    sidecar='/sdcard/Books/Legacy-local.sdr/metadata.epub.lua'
    before=device.adb('exec-out','cat',sidecar)
    queue=device.adb('exec-out','cat','/sdcard/koreader/settings/orbit-finish-queue.lua')
    device.shot(out/'legacy-explicit-finish.png')
    run.setup(device,apk,koreader,apksigner)
    device.wait_companion()
    device.command('Library.companion.setupLater();assert(S.wifi_idle_min==7 and S.review_upgrade_marker=="completion-upgrade");if S.news_012_pending then HomeHost.show();if top().text and top().text:find("setup steps",1,true) then click("Later") end;if S.news_012_pending then click("Done") end end;HomeHost.show();LocalReadingSettings.open();return true')
    deadline=time.monotonic()+40
    while device.command('local p=Library.paint("settings-reading-statistics");local r=p:localReading();p:flush();if r.pending then return "pending" end;return r.books_this_year==1 and "ready" or "pending"')!='ready':
        if time.monotonic()>deadline:raise TimeoutError('Proven legacy finish was not imported')
        time.sleep(.2)
    assert device.adb('exec-out','cat',sidecar)==before,'borrowed native sidecar changed'
    assert device.adb('exec-out','cat','/sdcard/koreader/settings/orbit-finish-queue.lua')==queue,'legacy queue changed'
    device.shot(out/'upgrade-local-count.png')
    device.command('SettingsView.active:close();LocalReadingSettings.open();return true')
    time.sleep(1)
    device.command('local p=Library.paint("settings-reading-statistics");local r=p:localReading();p:flush();assert(r.books_this_year==1 and r.target==nil);return true')
    device.shot(out/'upgrade-idempotent.png')
    print('4 native local-completion upgrade checks passed (settings, proven import, byte preservation, idempotency)',flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--serial',required=True)
    for name in ('legacy-source','legacy-apk','apk','koreader','apksigner','out'):p.add_argument('--'+name,type=Path,required=True)
    a=p.parse_args();verify(run.Emulator(a.serial),a.legacy_source,a.legacy_apk,a.apk,a.koreader,a.apksigner,a.out)

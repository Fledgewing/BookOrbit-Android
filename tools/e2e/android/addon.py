#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Add-on fallbacks on a disposable, already set up emulator; never a physical reader.

Uses real companion pages plus the existing KOReader driver. Preferences are synthetic
fixture inputs and restored on completion. Browser navigation is covered by JVM tests;
this flow does not fetch an update or invoke an installer.
"""
import argparse
from pathlib import Path
import re
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
sys.dont_write_bytecode = True
from run import Emulator, PACKAGE

def review(device, out):
    out.mkdir(parents=True,exist_ok=True)
    pref="shared_prefs/orbit.xml"
    saved=device.shell("run-as",PACKAGE,"cat",pref)
    def store(xml):
        device.shell("am","force-stop",PACKAGE)
        with tempfile.TemporaryDirectory() as directory:
            source=Path(directory)/"orbit.xml";source.write_text(xml)
            device.push(source,"/data/local/tmp/booksync-addon-prefs.xml")
        device.shell("run-as",PACKAGE,"cp","/data/local/tmp/booksync-addon-prefs.xml",pref)
    def start(**extras):
        args=["am","start","-W","--activity-single-top","-a",PACKAGE+".action.SHOW_STATUS","-n",PACKAGE+"/.StatusActivity"]
        for k,v in extras.items(): args += ["--es",k,v]
        device.shell(*args)
    def tree():
        device.shell("uiautomator","dump","/sdcard/booksync-addon-ui.xml")
        return ET.fromstring(device.shell("cat","/sdcard/booksync-addon-ui.xml"))
    def wait_text(text):
        deadline=time.monotonic()+15
        while time.monotonic()<deadline:
            nodes=list(tree().iter("node"))
            match=next((n for n in nodes if n.get("text")==text),None)
            if match is not None: return match
            time.sleep(.2)
        raise AssertionError("missing native companion control: "+text)
    def tap(text):
        n=wait_text(text)
        x1,y1,x2,y2=map(int,re.findall(r"\d+",n.get("bounds")))
        device.shell("input","tap",str((x1+x2)//2),str((y1+y2)//2))
    xml=ET.fromstring(saved)
    def set_pref(key,value,kind="string"):
        for n in list(xml):
            if n.get("name")==key: xml.remove(n)
        n=ET.SubElement(xml,kind,{"name":key})
        if kind=="string": n.text=value
        else: n.set("value",value)
    try:
        set_pref("orbit_mode","addon")
        set_pref("setup_later_until","9000000000000000","long")
        set_pref("update_download_version","99.0.0")
        set_pref("update_download_url","https://example.test/fixture.apk")
        store(ET.tostring(xml,encoding="unicode"))
        start()
        wait_text("Download")
        device.shot(out/"addon-download.png")
        start(booksync_page="helpers")
        wait_text("Wi-Fi switching")
        device.shot(out/"addon-helpers.png")
        # Sleep sync is farther down this existing paged/scrolling Settings group.
        device.shell("input","swipe","600","1350","600","550","300")
        wait_text("Sleep sync")
        # The target is the existing protected settings surface, with its own PIN policy.
        device.shell("am","start","-W","-n","org.koreader.launcher/.MainActivity")
        device.wait_companion()
        device.command('Library.settings.refresh("addon-emulator");assert(Library.companion.addon());assert(plugin:statusText():find("BookSync update ready: v99.0.0",1,true));return true')
        device.command('assert(Library.companion.openHelpers());return true')
        wait_text("Wi-Fi switching")
        device.shot(out/"reader-helper-link.png")
        print("3 native add-on checks passed",flush=True)
    except Exception:
        device.shot(out/"failure.png")
        raise
    finally:
        store(saved)
        start()

if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial",required=True)
    parser.add_argument("--out",type=Path,required=True)
    args=parser.parse_args();review(Emulator(args.serial),args.out)

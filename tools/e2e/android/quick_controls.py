#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Native quick controls on a verified disposable emulator; no helper is enabled."""
import argparse
from pathlib import Path
import sys
import time
sys.dont_write_bytecode=True
from run import Emulator

def review(device,out):
    out.mkdir(parents=True,exist_ok=True);device.wait_companion()
    def wait(code):
        end=time.monotonic()+45
        while device.command(code)!="ready":
            if time.monotonic()>end:raise TimeoutError('Quick control did not settle')
            time.sleep(.2)
    device.command('Library.companion.setupLater();ReaderPanel.close();Library._controlReview={layout=Library.settings.read("home_layout"),night=G_reader_settings:isTrue("night_mode"),rotation=Device.screen:getRotationMode(),rotate=Device.screen.setRotationMode,last=S.last_sleep_sync};HomeHost.show();return true')
    checks=0
    try:
        wait('local h=Library.paint("home");local n=Library.localWidgetNeed("sync-controls");local r=h:widget("sync-controls"):read(n.op,n);h:flush();return not r.pending and r.state=="ready" and "ready" or "pending"')
        for i in range(1,3):
            device.command('local z=WidgetRegistry["sync-controls"].sizes["android-tablet"]['+str(i)+'];local d=Layout.default();d.pages={{id="controls",tab="Home",name="Quick controls",placements={{instance="sync",widget="sync-controls",version=1,x=0,y=0,w=z[1],h=z[2],settings={}},{instance="toggles",widget="reader-toggles",version=1,x=0,y=2,w=z[1],h=z[2],settings={}}}}};Library.settings.write("home_layout",d);HomeHost.show();assert(HomeHost.active.metrics.roundTrips<=1 and HomeHost.active.metrics.network==0 and HomeHost.active.metrics.spawns==0);return true')
            device.shot(out/('controls-'+str(i)+'.png'));checks+=1
        device.command('local before=G_reader_settings:isTrue("night_mode");assert(Library.localWidgetAction("control-night"));assert(G_reader_settings:isTrue("night_mode")~=before);HomeHost.show();return true')
        device.shot(out/'night-on.png');checks+=1
        device.command('local t=Library._controlReview;if G_reader_settings:isTrue("night_mode")~=t.night then Library.localWidgetAction("control-night") end;assert(G_reader_settings:isTrue("night_mode")==t.night);return true')
        device.command('local n=Library.controlInput();if not n.wifi_available then assert(not Library.localWidgetAction("control-wifi")) end;return true');checks+=1
        # The existing foreground Sync now path owns its asynchronous queue; no
        # presentation double replaces its controller or checkpoint writer.
        device.command('local c=Library.controller();assert(c and not c.sas_running);assert(Library.localWidgetAction("control-sync"));assert(c.sas_running);assert(not Library.localWidgetAction("control-sync"));return true')
        wait('local c=Library.controller();return not c.sas_running and S.last_sleep_sync and S.last_sleep_sync.reason=="menu_sync" and "ready" or "pending"')
        device.command('local w=top();if w and w.timeout then UI:close(w) end;HomeHost.show();Library.retry();return true')
        wait('local h=Library.paint("home");local n=Library.localWidgetNeed("sync-controls");local r=h:widget("sync-controls"):read(n.op,n);h:flush();if r.pending then return "pending" end;assert(r.result~="No saved sync check");return "ready"')
        device.shot(out/'sync-result.png');checks+=1
        device.command('local t=Library._controlReview;local h=HomeHost.active;t.height=Device.screen:getHeight();Device.screen.setRotationMode=function(screen,mode) t.requested=mode;return t.rotate(screen,mode) end;h:dispatch("control-rotate");assert(HomeHost.active==nil,"Home must hand back to native UI");assert(t.requested==(t.rotation+1)%4,"native rotation request missing");return true')
        wait('return Device.screen:getHeight()~=Library._controlReview.height and "ready" or "pending"')
        device.shot(out/'native-rotation.png');checks+=1
        print(str(checks)+' native quick-control checks passed',flush=True)
    except Exception:
        device.shot(out/'failure.png');raise
    finally:
        device.command('local t=Library._controlReview;if t then if G_reader_settings:isTrue("night_mode")~=t.night then Library.localWidgetAction("control-night") end;Device.screen.setRotationMode=t.rotate;Device.screen:setRotationMode(t.rotation);S.last_sleep_sync=t.last;saveSettings();Library.settings.write("home_layout",t.layout);Library._controlReview=nil end;return true')
        device.shell('am','force-stop','org.koreader.launcher');device.shell('am','start','-n','org.koreader.launcher/.MainActivity')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--serial',required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();review(Emulator(a.serial),a.out)

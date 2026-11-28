#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Synthetic local files, real unopened worker, native Next/restart/Open."""
import argparse
import importlib.util
import json
from pathlib import Path
import sys
import time
import uuid
sys.dont_write_bytecode=True
from run import Emulator

def review(device,out):
    out.mkdir(parents=True,exist_ok=True);device.wait_companion()
    def wait(code):
        end=time.monotonic()+45
        while device.command(code)!="ready":
            if time.monotonic()>end:raise TimeoutError('Unopened projection not published')
            time.sleep(.2)
    root=Path(__file__).resolve().parents[3]
    spec=importlib.util.spec_from_file_location('unopened_kit',root/'tools/e2e/kit.py')
    kit=importlib.util.module_from_spec(spec);sys.modules[spec.name]=kit;spec.loader.exec_module(kit)
    library=json.loads((root/'shared/fixtures/e2e/library.json').read_text())
    tag=uuid.uuid4().hex[:8];query='Unopened review '+tag
    destination='/sdcard/BookSync/E2E/Unopened-012/'+tag
    device.shell('mkdir','-p',destination)
    for i in range(3):
        book={'title':query+' '+str(i),'author':'Fixture','series':None,'index':None,'cover':False,'number':2050+i,'uuid':'urn:uuid:'+str(uuid.uuid4())}
        file=out/(book['title']+'.epub');file.write_bytes(kit.epub_bytes(book,library));device.push(file,destination+'/'+file.name)
    layout=device.command('HomeHost.show();return Cache.encode(Library.settings.read("home_layout"))')
    previous=device.command('return Cache.encode(S.home_dust_pick)')
    def show():
        device.command('HomeHost.show();local cfg=BookList.preset("unopened");cfg.query={q='+json.dumps(query)+'};local d=Layout.default();d.pages={{id="unopened",tab="Home",name="Unopened files",placements={{instance="u",widget="booklist",version=1,x=0,y=0,w=2,h=3,settings=cfg},{instance="d",widget="dust",version=1,x=2,y=0,w=2,h=2,settings={}}}}};assert(Layout.validate(d));Library.settings.write("home_layout",d);Library.retry();HomeHost.show();return true')
    try:
        show()
        wait('local h=HomeHost.active;local r=Cache.decode(h.signatures.u);local d=Cache.decode(h.signatures.d);return r and not r.pending and r.total==3 and d and d.state=="ready" and "ready" or "pending"')
        device.command('assert(HomeHost.active.metrics.roundTrips<=1 and HomeHost.active.metrics.network==0 and HomeHost.active.metrics.spawns==0);local r=Cache.decode(HomeHost.active.signatures.u);for _,b in ipairs(r.items) do assert(b.status=="unknown" and b.local_path and b.status_write==false) end;return true')
        device.shot(out/'unopened-and-dust.png')
        device.command('HomeHost.show();local cfg=BookList.preset("unopened");cfg.query={q='+json.dumps(query)+'};HomeHost.active:dispatch("all",nil,{widget="booklist",settings=cfg});assert(HomeHost.active.filter.model.source=="unopened");return true')
        wait('local r=HomeHost.active.list_result;return r and not r.pending and r.total==3 and "ready" or "pending"')
        open_row=device.command('return Cache.encode(HomeHost.active.list_result.items[1])')
        device.shot(out/'unopened-list.png');show()
        wait('local d=Cache.decode(HomeHost.active.signatures.d);return d and d.state=="ready" and "ready" or "pending"')
        choice=device.command('local d=Cache.decode(HomeHost.active.signatures.d);Library._dustBefore=d.book.key;click("Next");return tostring(S.home_dust_pick.skip)')
        wait('local d=Cache.decode(HomeHost.active.signatures.d);return d and d.state=="ready" and d.pick==S.home_dust_pick.skip and d.book.key~=Library._dustBefore and "ready" or "pending"')
        key=device.command('return Cache.decode(HomeHost.active.signatures.d).book.key')
        device.shot(out/'next-pick.png')
        device.shell('am','force-stop','org.koreader.launcher');device.shell('am','start','-n','org.koreader.launcher/.MainActivity');device.wait_companion();show()
        wait('local d=Cache.decode(HomeHost.active.signatures.d);return d and d.state=="ready" and d.pick=='+choice+' and d.book.key=='+json.dumps(key)+' and "ready" or "pending"')
        device.shot(out/'choice-after-restart.png')
        device.command('HomeHost.active:dispatch("book",Cache.decode('+json.dumps(open_row,ensure_ascii=False)+'));return true')
        wait('local ui=require("apps/reader/readerui").instance;return ui and ui.document and ui.document.file:find('+json.dumps(query)+',1,true) and "ready" or "pending"')
        device.shot(out/'explicit-open.png');show()
        wait('local r=Cache.decode(HomeHost.active.signatures.u);return r and not r.pending and r.total==2 and "ready" or "pending"')
        print('5 native unopened checks passed (real pool, counted list, Next, restart, explicit Open exclusion)',flush=True)
    except Exception:
        device.shot(out/'failure.png');raise
    finally:
        device.command('S.home_dust_pick=Cache.decode('+json.dumps(previous,ensure_ascii=False)+');saveSettings();G_reader_settings:flush();Library.settings.write("home_layout",Cache.decode('+json.dumps(layout,ensure_ascii=False)+'));Library._dustBefore=nil;HomeHost.show();return true')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--serial',required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();review(Emulator(a.serial),a.out)

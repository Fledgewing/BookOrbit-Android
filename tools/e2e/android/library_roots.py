#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Native Library roots/source pickers; real local RPC plus bounded remote UI fixtures.

JVM adapter tests verify account-scoped remote membership and complete/unknown counts.
The native remote states use a temporary Library snapshot double, not a real server.
"""
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
            if time.monotonic()>end: raise TimeoutError('Library root projection not published')
            time.sleep(.2)
    device.command('Library.companion.setupLater();local w=top();if w and type(w.text)=="string" and w.text:find("setup step",1,true) then click("Later") end;ReaderPanel.close();HomeHost.show();HomeHost.active:dispatch("browse");return true')
    wait('local p=StorageUI.active;return p and p.data.in_progress~=nil and not p.data.pending and "ready" or "pending"')
    device.command('local p=StorageUI.active;assert(p.data.coverage=="This reader\\\'s files");assert(p.metrics.rows==1 and p.metrics.roundTrips==1);p:onClose();Library._rootsReview={read=LibraryAdapter.read};return true')
    try:
        device.command('local t=Library._rootsReview;LibraryAdapter.read=function(raw,...) local a=Cache.decode(raw);if a.op=="library.summary" then return {total=59,in_progress=8,browse={libraries=13,authors=7,series=5,collections=13,lists=13},coverage="Saved catalog indexes",freshness={saved=true}},300 end;if a.op=="sources" and (a.category=="collections" or a.category=="libraries" or a.category=="lists") then local kind=a.category=="collections" and "collection" or a.category=="libraries" and "library" or "list";local title=kind=="collection" and "Collection" or kind=="library" and "Library" or "List";local rows={};for i=(a.offset or 0)+1,math.min((a.offset or 0)+(a.limit or 6),13) do rows[#rows+1]={src=kind..":opaque:"..i,title=title.." "..i,count=i} end;return {items=rows,total=13,next=(a.offset or 0)<12 and (a.offset or 0)+6 or nil,freshness={saved=true}},900 end;return t.read(raw,...) end;HomeHost.active.caps.collections=true;HomeHost.active.caps.libraries=true;HomeHost.active.caps.lists={read=true};HomeHost.active:dispatch("browse");return true')
        device.shot(out/'library-roots.png')
        device.command('local p=StorageUI.active;for _,b in ipairs(p.controls) do assert(b.height>=Device.screen:scaleBySize(50));assert(b.overlap_offset[2]+b.height<=p.dimen.h) end;click("Libraries · 13 ›");return true')
        device.shot(out/'libraries-first.png')
        device.command('click("Next");assert(StorageUI.active.offset==6);click("Library 7 · 7 ›");local source=HomeHost.active.filter.model.source;assert(source.kind=="library" and source.key=="opaque:7");HomeHost.active:onClose();return true')
        for category,title,kind in (('collections','Collection','collection'),('libraries','Library','library')):
            device.command('local t=Library._rootsReview;t.config=BookListConfig.new{cfg=BookList.preset("also"),caps={collections=true,libraries=true,lists={read=true}},onDone=function(cfg) t.selected=cfg end};t.config:paint();click("Source: Reading now ›");click("'+category.title()+'");click("›");assert(t.config.offset==6);return true')
            device.shot(out/(category+'-picker.png'))
            device.command('click("○ '+title+' 7 · 7");click("Done");local t=Library._rootsReview;local source=BookList.source(t.selected);assert(source.kind=="'+kind+'" and source.key=="opaque:7");assert(BookList.valid(t.selected));t.config=nil;return true')
        device.command('HomeHost.active:dispatch("browse");click("Your lists · 13 ›");click("List 1 · 1 ›");local source=HomeHost.active.filter.model.source;assert(source.kind=="list" and source.key=="opaque:1");HomeHost.active:onClose();return true')
        device.command('local t=Library._rootsReview;local rich=LibraryAdapter.read;LibraryAdapter.read=function(raw,...) if Cache.decode(raw).op=="library.summary" then return {total=59,browse={complete=false},coverage="Catalog indexes updating",freshness={saved=true}},180 end;return rich(raw,...) end;HomeHost.active:dispatch("browse");return true')
        device.shot(out/'unknown-index-counts.png')
        device.command('local labels={};for _,b in ipairs(StorageUI.active.controls) do labels[b.text]=true end;assert(labels["Libraries · — ›"] and not labels["Libraries · 0 ›"]);return true')
        print('7 native Library root checks passed (local RPC, counts/geometry, named root, collection/library picker, list root, unknown counts)',flush=True)
    except Exception:
        device.shot(out/'failure.png');raise
    finally:
        device.command('local t=Library._rootsReview;if t then if t.config then t.config:close() end;if StorageUI.active then StorageUI.active:onClose() end;LibraryAdapter.read=t.read;Library._rootsReview=nil;HomeHost.show() end;return true')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--serial',required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();review(Emulator(a.serial),a.out)

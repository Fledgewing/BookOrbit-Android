-- SPDX-License-Identifier: MIT
-- Instance-level stand-ins exercise the production lifecycle and geometry wrappers.
return function(here, test, ok, eq)
    local function world(paged)
        local E = setmetatable({}, {__index=_G})
        local function noop() end
        local Geom = {}
        function Geom:new(t) return setmetatable(t or {}, {__index=self}) end
        function Geom:copy() local t={}; for k,v in pairs(self) do t[k]=v end; return Geom:new(t) end
        local W = { queue={}, dirty={}, now=0, capacity=77, height=800, width=600 }
        E.Device={screen={ getWidth=function() return W.width end, getHeight=function() return W.height end,
            scaleBySize=function(_,n) return n end, getSize=function() return Geom:new{w=W.width,h=W.height} end},
            getPowerDevice=function() return {getCapacity=function() return W.capacity end} end}
        E.UIManager={ unschedule=function(_,fn) W.queue[fn]=nil end,
            scheduleIn=function(_,delay,fn) W.queue[fn]=delay end, nextTick=function(_,fn) W.next=fn end,
            getTopmostVisibleWidget=function() return W.top end,
            setDirty=function(_,widget,mode,rect) W.dirty[#W.dirty+1]={widget=widget,mode=mode,rect=rect} end }
        E.Event={new=function(_,name,...) return {name=name,args={...}} end}
        E.G_reader_settings={isTrue=function() return false end, readSetting=function() return nil end, saveSetting=function() end}
        E.S={status_orbit_layout=true}; E.OrbitAndroid={}
        E.os={time=function() return 120 end,date=function() return {hour=12,min=2} end}
        local Text={new=function(_,t) return {getSize=function() return {w=#t.text,h=12} end,paintTo=noop,free=noop} end}
        E.require=function(name)
            if name=="ui/geometry" then return Geom end
            if name=="ui/widget/textwidget" then return Text end
            if name=="ui/font" then return {getFace=function() return {} end} end
            if name=="ffi/blitbuffer" then return {COLOR_WHITE=0,COLOR_BLACK=1} end
            error(name)
        end
        local function load(name) local chunk=assert(loadfile(here.."/../orbit.koplugin/"..name)); setfenv(chunk,E); chunk() end
        load("logic/status_layout.lua"); load("ko/status_layout.lua")
        local ui={dimen=Geom:new{w=600,h=800},document={configurable={},info={number_of_pages=340}}, toc={getTocTitleByPage=function() return "Chapter" end}}
        local v={footer_visible=false, view_mode="page", dimen=Geom:new{w=600,h=800}}
        local native={reclaim_height=true}
        local base={settings=native,reclaim_height=true,mode_list={page_progress=1},mode=0,
            updateFooterContainer=noop,resetLayout=noop,onUpdateFooter=noop,
            onToggleFooterMode=function(self) self:applyFooterMode(self.mode==0 and 1 or 0); return true end,
            unscheduleFooterAutoRefresh=function() W.footer_cancelled=true end,
            rescheduleFooterAutoRefreshIfNeeded=function() W.footer_resumed=true end,
            getHeight=function() return 18 end,
            applyFooterMode=function(self, mode) self.mode=mode; self.genFooterText=function() return "temporary" end; v.footer_visible=mode~=0 end,
            updateFooterText=function() W.native_paint=true end, paintTo=function() W.native_paint=true end}
        -- Inherited methods must be inherited again after disable (rawget == nil).
        v.footer=setmetatable({pageno=12,pages=340,percent_finished=12/340},{__index=base})
        v.paintTo=function(self,bb,x,y) self.footer:paintTo(bb,x,y) end
        ui.view=v; W.top=ui; E.liveUI=function() return ui end
        if paged then
            local function size(self,d)
                self.dimen=d
                if self==v then v.visible_height=d.h-(v.footer_visible and v.footer:getHeight() or 0) end
            end
            v.onSetDimensions=size; v.onRestoreDimensions=size
            ui.zooming={onSetDimensions=size,onRestoreDimensions=size}
            ui.paging={current_page=12,onInitScrollPageStates=function() W.scroll_height=v.visible_height end}
            for _,name in ipairs({"drawSinglePage","drawScrollPages","drawPageBackground","drawPageSurround"}) do
                v[name]=function(_,bb,x,y) W.draw_y=y end
            end
            for _,name in ipairs({"getSinglePagePosition","getScrollPagePosition"}) do v[name]=function(_,pos) return pos end end
            v.getSinglePageRect=function(_,rect) return rect end
            v.getScrollPageRect=function(_,page,rect) return rect end
            v.getScreenPageArea=function() return Geom:new{x=0,y=0,w=600,h=v.visible_height} end
        else
            ui.document.setViewDimen=function(_,d) W.engine_height=d.h end
            ui.document.setViewMode=function() end
            ui.document.getScreenPositionFromXPointer=function() return 10,20 end
            ui.document.getLinkFromPosition=function(_,pos) return "link-at-"..pos.y end
            v.visible_area=Geom:new{w=600,h=800}
            v.recalculate=function(self) self.visible_area.h=self.dimen.h end
            v.drawScrollView=function(_,bb,x,y) W.draw_y=y end
            v.screenToPageTransform=function(_,pos) return pos end
            v.pageToScreenTransform=function(_,page,rect) return rect end
            ui.document.setStatusLineProp=function(_,n) W.header=n end
            ui.document.setPageMargins=function(_,l,t,r,b) W.margins={l,t,r,b} end
            ui.typeset={unscaled_margins={10,20,10,30},onSetPageMargins=function(self,m)
                ui.document:setPageMargins(m[1],m[2],m[3],m[4]+(v.footer.reclaim_height and 0 or v.footer:getHeight()))
                v:recalculate()
                W.anchor_preserved=true
            end}
            ui.rolling={cre_top_bar_enabled=true,
                onGotoViewRel=function() W.step=ui.dimen.h-v.footer:getHeight(); ui.rolling:_gotoPos() end,
                _gotoPos=function() W.max_pos=10000-ui.dimen.h+v.footer:getHeight() end,
                onSetStatusLine=function(_,n) ui.document:setStatusLineProp(n) end}
            ui.crelistener={unscheduleHeaderRefresh=function() W.header_cancelled=true end,
                rescheduleHeaderRefreshIfNeeded=function() W.header_resumed=true end}
        end
        ui.handleEvent=function(_,e)
            if e.name=="SetDimensions" then v:onSetDimensions(e.args[1]); ui.zooming:onSetDimensions(e.args[1]) end
        end
        W.E,W.ui,W.v,W.Geom=E,ui,v,Geom
        return W,E.ReadingStatus,native
    end
    test("status: CRE reserve, restore absent/inherited native state and repeat toggles", function()
        local w,R,native=world(false)
        R.enable(w.ui); local s=R.session
        eq(w.margins[2],44); eq(w.margins[4],54); eq(w.header,1)
        ok(w.header_cancelled and w.footer_cancelled and w.anchor_preserved)
        eq(native.reclaim_height,true); eq(w.ui.document.configurable.status_line,nil)
        eq(rawget(w.v.footer,"settings").reclaim_height,false)
        R.enable(w.ui); eq(R.session,s)
        eq(w.v.footer:onToggleFooterMode(),true); eq(w.margins[4],30)
        w.v.footer:applyFooterMode(1); eq(w.margins[4],54)
        R.disable(); eq(w.margins[2],20); eq(w.margins[4],30)
        eq(rawget(w.v.footer,"settings"),nil); eq(rawget(w.v.footer,"paintTo"),nil)
        eq(w.v.footer_visible,false); eq(w.v.footer.mode,0)
        eq(rawget(w.v.footer,"mode"),nil); eq(rawget(w.v.footer,"genFooterText"),nil)
        ok(w.footer_resumed and w.header_resumed); eq(next(w.queue),nil)
        R.disable(); R.enable(w.ui); R.disable(); eq(w.margins[2],20)
    end)
    test("status: PDF/CBZ viewport, zoom, scroll states, transforms, footer gesture and rotation", function()
        local w,R=world(true)
        R.enable(w.ui)
        eq(w.v.dimen.h,776); eq(w.ui.zooming.dimen.h,776); eq(w.scroll_height,752)
        for _,name in ipairs({"drawSinglePage","drawScrollPages"}) do w.v[name](w.v,{},0,0); eq(w.draw_y,24) end
        local p=w.Geom:new{x=10,y=34}
        eq(w.v:getSinglePagePosition(p).y,10); eq(p.y,34)
        eq(w.v:getScrollPagePosition(p).y,10)
        eq(w.v:getSinglePagePosition(w.Geom:new{x=0,y=10}),nil)
        eq(w.v:getSinglePagePosition(w.Geom:new{x=0,y=790}),nil)
        eq(w.v:getSinglePageRect(p).y,58); eq(p.y,34)
        eq(w.v:getScrollPageRect(12,p).y,58)
        eq(w.v:getScreenPageArea(12).y,24)
        w.v.page_scroll=true
        w.ui.paging.getTopPosition=function() return 0.25 end
        w.ui.paging.setPagePosition=function(_,page,pos) w.position=pos end
        R.relayout(R.session); eq(w.position,0.25); eq(w.scroll_height,752)
        -- Native applyFooterMode is delegated, not replaced by an Orbit tap handler.
        w.v.footer:applyFooterMode(0); eq(w.scroll_height,776)
        w.v.footer:applyFooterMode(1); eq(w.scroll_height,752)
        w.height,w.width=600,800; R.relayout(R.session)
        eq(w.v.dimen.h,576); eq(w.v.dimen.w,800); eq(w.scroll_height,552)
        R.disable(); eq(w.v.dimen.h,600); eq(w.ui.zooming.dimen.h,600); eq(w.v.footer_visible,false)
    end)
    test("status: CRE scroll reserves engine viewport and translates hits without skipping text", function()
        local w,R=world(false); R.enable(w.ui)
        w.v.view_mode="scroll"; w.ui.document:setViewMode("scroll")
        eq(w.engine_height,752); eq(w.v.visible_area.h,752)
        w.v:drawScrollView({},0,0); eq(w.draw_y,24)
        local pos=w.Geom:new{x=10,y=34}
        eq(w.v:screenToPageTransform(pos).y,10); eq(pos.y,34)
        eq(w.v:pageToScreenTransform(1,pos).y,58)
        eq(w.ui.document:getScreenPositionFromXPointer("xp"),34)
        eq(w.ui.document:getLinkFromPosition(pos),"link-at-10"); eq(pos.y,34)
        eq(w.ui.document:getLinkFromPosition(w.Geom:new{x=0,y=10}),"")
        w.ui.rolling:onGotoViewRel(1); eq(w.step,752); eq(w.max_pos,9248)
        eq(w.ui.dimen.h,800)
        w.v.footer:applyFooterMode(0); eq(w.engine_height,776); eq(w.v.visible_area.h,776)
        w.ui.rolling:onGotoViewRel(1); eq(w.step,776)
        R.disable(); eq(w.engine_height,800); eq(w.v.visible_area.h,800)
    end)
    test("status: minute and battery partial dirty regions, covered/asleep, close cleanup", function()
        local w,R=world(true); R.enable(w.ui); local s=R.session
        s.clock="12:01"; s.battery=77
        s.tick(); eq(#w.dirty,1); eq(w.dirty[1].rect.y,0); eq(w.dirty[1].rect.h,24)
        eq(w.dirty[1].mode,"partial"); eq(w.queue[s.tick],60)
        s.clock="12:02"; w.capacity=76; s.tick()
        eq(#w.dirty,2); eq(w.dirty[2].rect.y,776)
        w.top={}; s.tick(); eq(#w.dirty,2)
        w.E.OrbitAndroid.onSuspend({ui=w.ui}); eq(w.queue[s.tick],nil)
        w.E.OrbitAndroid.onResume({ui=w.ui}); eq(w.queue[s.tick],60)
        w.E.OrbitAndroid.onCloseDocument({ui=w.ui}); eq(R.session,nil); eq(next(w.queue),nil)
        w.E.OrbitAndroid.onCloseWidget({ui=w.ui}); eq(next(w.queue),nil)
    end)
    test("status: default-on setting, off leaves native footer and safe next-tick changes", function()
        local w,R=world(true)
        w.E.S.status_orbit_layout=false; w.E.OrbitAndroid.onReaderReady({ui=w.ui}); eq(R.session,nil)
        eq(rawget(w.v.footer,"paintTo"),nil)
        w.E.S.status_orbit_layout=true; R.changed(); eq(R.session,nil); w.next(); ok(R.session)
        w.E.S.status_orbit_layout=false; R.changed(); ok(R.session); w.next(); eq(R.session,nil)
    end)
end

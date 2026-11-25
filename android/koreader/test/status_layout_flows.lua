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
            getPowerDevice=function() return {getCapacity=function() return W.capacity end, isCharging=function() return W.charging end} end}
        E.UIManager={ unschedule=function(_,fn) W.queue[fn]=nil end,
            scheduleIn=function(_,delay,fn) W.queue[fn]=delay end, nextTick=function(_,fn) W.next=fn end,
            getTopmostVisibleWidget=function() return W.top end,
            setDirty=function(_,widget,mode,rect) W.dirty[#W.dirty+1]={widget=widget,mode=mode,rect=rect} end }
        E.Event={new=function(_,name,...) return {name=name,args={...}} end}
        E.G_reader_settings={isTrue=function() return false end, readSetting=function() return nil end, saveSetting=function() end}
        E.S={status_orbit_layout=true}; E.OrbitAndroid={}
        E.SOURCE_DIR=here.."/../orbit.koplugin"
        E.SettingsSync={decodeJson=dofile(here.."/json_mini.lua").decode}
        E.os={time=function() return 120 end,date=function() return {hour=12,min=2} end}
        local Text={new=function(_,t) return {getSize=function() return {w=#t.text,h=(t.face.size or 14)-2} end,paintTo=noop,free=noop} end}
        E.require=function(name)
            if name=="ui/geometry" then return Geom end
            if name=="ui/widget/textwidget" then return Text end
            if name=="ui/font" then return {getFace=function(_,name,size) return {size=size} end} end
            if name=="ffi/blitbuffer" then return {COLOR_WHITE=0,COLOR_BLACK=1} end
            error(name)
        end
        local function load(name) local chunk=assert(loadfile(here.."/../orbit.koplugin/"..name)); setfenv(chunk,E); chunk() end
        load("logic/status_layout.lua"); load("ko/status_layout.lua")
        local ui={dimen=Geom:new{w=600,h=800},document={configurable={},info={number_of_pages=340}}, toc={getTocTitleByPage=function() return "Chapter" end}}
        local v={footer_visible=false, view_mode="page", dimen=Geom:new{w=600,h=800}}
        local native={reclaim_height=true}
        local base={settings=native,reclaim_height=true,mode_list={off=0,page_progress=1},mode=0,
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
    test("status: enable, resize, tap, close and reopen never change document/global settings or layout", function()
        for _, paged in ipairs({false,true}) do
            local w,R,native=world(paged)
            local doc='return { ["copt_t_page_margin"]=15, ["copt_b_page_margin"]=15, ["copt_sync_t_b_page_margins"]=1, ["copt_font_size"]=24, ["footer"]=false }'
            local global='return { ["footer"]={ ["reclaim_height"]=true }, ["reader_footer_mode"]=0, ["copt_b_page_margin"]=15 }'
            local files={os.tmpname(),os.tmpname()}
            for i,text in ipairs({doc,global}) do local f=assert(io.open(files[i],"wb")); f:write(text); f:close() end
            local function forbidden() error("status may not write native settings or reflow a document") end
            w.E.G_reader_settings.saveSetting=forbidden
            w.E.G_reader_settings.delSetting=forbidden
            w.ui.doc_settings={saveSetting=forbidden,delSetting=forbidden}
            for _, name in ipairs({"setPageMargins","setViewDimen","setViewMode","setStatusLineProp"}) do w.ui.document[name]=forbidden end
            w.ui.handleEvent=forbidden
            if not paged then w.ui.typeset.onSetPageMargins=forbidden end
            local footer=w.v.footer
            local height,mode,visible,settings=footer:getHeight(),footer.mode,w.v.footer_visible,footer.settings
            local original=footer.onToggleFooterMode
            for _,size in ipairs({"small","medium","large"}) do
                w.E.S.status_orbit_size=size
                w.E.S.status_orbit_add_space=true -- obsolete saved preference must do nothing
                R.enable(w.ui)
                eq(footer:onToggleFooterMode(),true)
                eq(footer:onToggleFooterMode(),true)
                R.refreshGeometry(R.session)
                eq(footer:getHeight(),height); eq(footer.mode,mode); eq(w.v.footer_visible,visible)
                eq(footer.settings,settings); eq(native.reclaim_height,true)
                R.disable(); eq(footer.onToggleFooterMode,original)
                eq(rawget(footer,"onToggleFooterMode"),nil); eq(rawget(footer,"paintTo"),nil)
                R.enable(w.ui); w.E.OrbitAndroid.onCloseDocument({ui=w.ui})
                eq(R.session,nil); eq(next(w.queue),nil)
                eq(footer.settings,settings); eq(w.v.footer_visible,visible); eq(footer.mode,mode)
            end
            for i,text in ipairs({doc,global}) do
                local f=assert(io.open(files[i],"rb")); eq(f:read("*a"),text); f:close(); os.remove(files[i])
            end
        end
    end)
    test("status: disabled and visible native footer restore exactly without changing its timers or header", function()
        for _, disabled in ipairs({false,true}) do
            local w,R=world(false)
            w.v.footer.settings={disabled=disabled,reclaim_height=false}
            w.v.footer.reclaim_height=false
            w.v.footer_visible=not disabled
            w.v.footer.mode=disabled and 0 or 1
            w.v.footer.genFooterText=function() return "native" end
            local generator=w.v.footer.genFooterText
            R.enable(w.ui)
            eq(w.v.footer.genFooterText,generator)
            eq(w.v.footer_visible,not disabled)
            R.disable()
            eq(w.v.footer.settings.disabled,disabled)
            eq(w.v.footer.genFooterText,generator)
            eq(w.v.footer_visible,not disabled)
            eq(w.footer_cancelled,nil); eq(w.header_cancelled,nil); eq(w.header,nil)
        end
    end)
    test("status: fitted black text and battery align to the text block within existing margins", function()
        local w,R=world(false)
        w.ui.rolling.cre_top_bar_enabled=false
        w.ui.typeset.unscaled_margins={31,25,47,29}
        w.E.S.status_orbit_size="small"
        R.enable(w.ui); local s=R.session
        eq(s.top.height,25); eq(s.bottom.height,29)
        eq(s.left,31); eq(s.width,522)
        eq(s.top.size,25); eq(s.bottom.size,29)
        local count=0
        s.Text={new=function(_,t)
            eq(t.fgcolor,s.BB.COLOR_BLACK); eq(t.bold,true)
            return { getSize=function() return {w=#t.text,h=t.face.size-2} end,
                free=function() end,paintTo=function(_,bb,x,y)
                    ok(x>=31 and x+#t.text<=553)
                    ok(y>=771 or y+t.face.size-2<=25)
                    count=count+1
                end }
        end}
        -- Geometry measurement also uses Text; restore it before geometry refresh.
        local refresh=R.refreshGeometry; R.refreshGeometry=function() end
        local rects={}
        R.paint(s,{paintRect=function(_,x,y,width,height,color)
            ok(x>=31 and x+width<=553); ok(y>=771 or y+height<=25)
            rects[#rects+1]={x,y,width,height,color}
        end},0,0)
        R.refreshGeometry=refresh
        ok(count>=3); ok(#rects>=6)
        eq(rects[3][5],1); eq(rects[4][5],0) -- battery black outline, white inset
        w.ui.typeset.unscaled_margins={40,10,50,12}; R.refreshGeometry(s)
        eq(s.top.height,10); eq(s.bottom.height,12); eq(s.left,40); eq(s.width,510)
        R.disable()
    end)
    test("status: PDF surround, zero margins and scroll never reserve space or change transforms", function()
        for _,paged in ipairs({false,true}) do
            local w,R=world(paged)
            if not paged then w.v.view_mode="scroll" end
            w.E.S.status_orbit_add_space=true
            R.enable(w.ui); local s=R.session
            eq(s.top.height,0); eq(s.bottom.height,0)
            eq(w.v.dimen.h,800)
            R.paint(s,{paintRect=function() error("no safe margin") end},0,0)
            if paged then
                w.v.state={offset={x=20,y=12}}
                w.v.visible_area={w=560,h=772}
                R.refreshGeometry(s)
                eq(s.top.height,12); eq(s.bottom.height,16); eq(s.left,20); eq(s.width,560)
                w.v.state.offset.y=0; w.v.visible_area.h=800
                R.paint(s,{paintRect=function() error("zoom removed surround") end},0,0)
                eq(s.top.height,0); eq(s.bottom.height,0)
            end
            R.disable()
        end
    end)
    test("status: partial dirty regions, sleep and close cleanup", function()
        local w,R=world(false); w.ui.rolling.cre_top_bar_enabled=false
        R.enable(w.ui); local s=R.session; w.dirty={}
        s.clock="12:01"; s.battery=77
        s.tick(); eq(#w.dirty,1); eq(w.dirty[1].rect.y,0); eq(w.dirty[1].rect.h,20)
        eq(w.dirty[1].mode,"partial"); eq(w.queue[s.tick],60)
        s.clock="12:02"; w.capacity=76; s.tick()
        eq(#w.dirty,2); eq(w.dirty[2].rect.y,770)
        w.top={}; s.tick(); eq(#w.dirty,2)
        w.E.OrbitAndroid.onSuspend({ui=w.ui}); eq(w.queue[s.tick],nil)
        w.E.OrbitAndroid.onResume({ui=w.ui}); eq(w.queue[s.tick],60)
        w.E.OrbitAndroid.onCloseDocument({ui=w.ui}); eq(R.session,nil); eq(next(w.queue),nil)
        w.E.OrbitAndroid.onCloseWidget({ui=w.ui}); eq(next(w.queue),nil)
    end)
    test("status: narrow lanes keep every group within text bounds", function()
        local L=world(false).E.StatusLayout
        for width=0,50 do
            local layout=L.layout(width,0,4,"battery","b","chapter","123 / 1234 · 100%",function(t) return #t end)
            ok(layout.rx>=0); ok(layout.rx+#layout.right<=width)
            ok(layout.left=="" or #layout.left<=width)
        end
    end)
    test("status: default off and next-tick toggles", function()
        local w,R=world(true)
        w.E.S.status_orbit_layout=nil; w.E.OrbitAndroid.onReaderReady({ui=w.ui}); eq(R.session,nil)
        eq(rawget(w.v.footer,"paintTo"),nil)
        w.E.S.status_orbit_layout=true; R.changed(); eq(R.session,nil); w.next(); ok(R.session)
        w.E.S.status_orbit_layout=false; R.changed(); ok(R.session); w.next(); eq(R.session,nil)
    end)
end

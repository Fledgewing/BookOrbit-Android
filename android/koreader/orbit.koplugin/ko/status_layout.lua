-- SPDX-License-Identifier: AGPL-3.0-or-later
-- W17: reader-owned status strips. No floating window or input handler.
ReadingStatus = {}
local RS = ReadingStatus

-- Restore instance slots, including originally inherited/absent values.
local function hook(s, obj, key, fn)
    s.undo[#s.undo+1] = { obj, key, rawget(obj, key) }
    obj[key] = fn(obj[key])
end

function RS.visible(s)
    return not s.asleep and UIManager:getTopmostVisibleWidget() == s.ui
end
function RS.dirty(s, top)
    if not RS.visible(s) then return end
    local Screen = Device.screen
    UIManager:setDirty(s.ui, "partial", s.Geom:new{
        x = 0, y = top and 0 or Screen:getHeight() - s.height,
        w = Screen:getWidth(), h = s.height,
    })
end
function RS.arm(s)
    UIManager:unschedule(s.tick)
    if not s.asleep then UIManager:scheduleIn(60 - os.time() % 60, s.tick) end
end

function RS.paint(s, bb, x, y, bottom_only)
    local Screen = Device.screen
    local width, height = Screen:getWidth(), Screen:getHeight()
    local function text(value, px, py)
        if value == "" then return end
        local w = s.Text:new{ text = value, face = s.face }
        w:paintTo(bb, x + math.floor(px), y + math.floor(py + (s.height-w:getSize().h)/2))
        w:free()
    end
    if not bottom_only then
        local t = os.date("*t")
        local clock = StatusLayout.clock(t.hour, t.min, G_reader_settings:isTrue("twelve_hour_clock"))
        s.clock = clock
        bb:paintRect(x, y, width, s.height, s.BB.COLOR_WHITE)
        text(clock, (width - s.measure(clock))/2, 0)
    end
    if not s.view.footer_visible then return end
    local footer = s.footer
    local page = footer.pageno or (s.ui.paging and s.ui.paging.current_page) or s.ui.document:getCurrentPage()
    local total = footer.pages
    local progress = StatusLayout.progress(page, total, footer.percent_finished)
    local chapter = s.ui.toc:getTocTitleByPage(page) or ""
    local battery = Device:getPowerDevice():getCapacity()
    s.battery = battery
    local icon = "▱"
    -- Reserve an outlined battery independently of font glyph support.
    local icon_w = Screen:scaleBySize(18)
    local battery_text = string.format("%d%%", battery)
    local function measure(v) return v == icon and icon_w or s.measure(v) end
    local layout = StatusLayout.layout(width, s.inset, s.gap,
        icon .. " " .. battery_text, icon, chapter, progress,
        function(v)
            if v:sub(1,#icon) == icon then return icon_w + s.measure(v:sub(#icon+1)) end
            return measure(v)
        end)
    local by = height - s.height
    bb:paintRect(x, y + by, width, s.height, s.BB.COLOR_WHITE)
    if layout.left ~= "" then
        local ix, iy = x+s.inset, y+by+math.floor(s.height/2)-4
        bb:paintRect(ix, iy, icon_w-3, 9, s.BB.COLOR_BLACK)
        bb:paintRect(ix+1, iy+1, icon_w-5, 7, s.BB.COLOR_WHITE)
        bb:paintRect(ix+icon_w-3, iy+3, 2, 3, s.BB.COLOR_BLACK)
        if layout.left ~= icon then text(" " .. battery_text, s.inset+icon_w, by) end
    end
    text(layout.chapter, layout.cx, by)
    text(layout.right, layout.rx, by)
end

-- Layout updates use the engine's own anchor-preserving relayout, not a repaint/crop.
function RS.relayout(s)
    if s.ui.paging then
        local v, paging = s.view, s.ui.paging
        local x, y, zoom
        if v.page_scroll then
            paging:setPagePosition(paging.current_page, paging:getTopPosition())
        elseif v.visible_area then
            x, y, zoom = v.visible_area.x, v.visible_area.y, v.state.zoom
        end
        s.ui:handleEvent(Event:new("SetDimensions", Device.screen:getSize()))
        if x and zoom and zoom > 0 then
            v.visible_area.x = x * v.state.zoom / zoom
            v.visible_area.y = y * v.state.zoom / zoom
            v.visible_area:offsetWithin(v.page_area, 0, 0)
        end
        paging:onInitScrollPageStates()
    else
        s.ui.document:setViewDimen(Device.screen:getSize())
        s.ui.typeset:onSetPageMargins(s.ui.typeset.unscaled_margins)
    end
end

function RS.enable(ui)
    if RS.session or not ui or not ui.document or not ui.view or not ui.view.footer then return end
    local Geom = require("ui/geometry")
    local Text = require("ui/widget/textwidget")
    local Font = require("ui/font")
    local s = { ui = ui, view = ui.view, footer = ui.view.footer, undo = {},
        Geom = Geom, Text = Text, BB = require("ffi/blitbuffer"),
        face = Font:getFace("smallinfofont"), height = Device.screen:scaleBySize(24),
        inset = Device.screen:scaleBySize(8), gap = Device.screen:scaleBySize(8) }
    RS.session = s
    s.measure = function(value)
        local w = Text:new{ text = value, face = s.face }
        local width = w:getSize().w; w:free(); return width
    end
    local f, v = s.footer, s.view
    s.native_visible, s.native_mode = rawget(v, "footer_visible"), rawget(f, "mode")
    s.native_generator = rawget(f, "genFooterText")
    s.native_setting_mode = G_reader_settings:readSetting("reader_footer_mode")
        -- The native table is shared with global settings: never modify it.
    local settings = {}; for k,val in pairs(f.settings) do settings[k] = val end
    settings.reclaim_height = false
    hook(s, f, "settings", function() return settings end)
    hook(s, f, "reclaim_height", function() return false end)
    hook(s, f, "getHeight", function() return function() return v.footer_visible and s.height or 0 end end)
    f:unscheduleFooterAutoRefresh()
    hook(s, f, "rescheduleFooterAutoRefreshIfNeeded", function() return function() end end)
    hook(s, f, "updateFooterText", function() return function() end end)
    hook(s, f, "paintTo", function() return function() end end)
    hook(s, v, "paintTo", function(stock) return function(self, bb, x, y)
        stock(self, bb, x, y)
        RS.paint(s, bb, x, y)
    end end)
    -- Native toggle/tap handlers still own visibility and their gesture return values.
    hook(s, f, "applyFooterMode", function(stock) return function(self, ...)
        local was = v.footer_visible
        stock(self, ...)
        if was ~= v.footer_visible then RS.relayout(s) end
    end end)
    hook(s, f, "onToggleFooterMode", function(stock) return function(self, ...)
        local result = stock(self, ...)
        G_reader_settings:saveSetting("reader_footer_mode", s.native_setting_mode)
        return result
    end end)
    if ui.paging then
        -- A shorter viewport drives zoom, visible_area AND scroll page-state generation.
        -- Its content origin is shifted below the clock; highlights and hit testing agree.
        for _, obj in ipairs({v, ui.zooming}) do
            for _, name in ipairs({"onSetDimensions", "onRestoreDimensions"}) do
                hook(s, obj, name, function(stock) return function(self, dimensions, ...)
                    local d = dimensions:copy(); d.h = d.h - s.height
                    return stock(self, d, ...)
                end end)
            end
        end
        for _, name in ipairs({"drawSinglePage", "drawScrollPages", "drawPageBackground", "drawPageSurround"}) do
            hook(s, v, name, function(stock) return function(self, bb, x, y, ...)
                return stock(self, bb, x, y+s.height, ...)
            end end)
        end
        for _, name in ipairs({"getSinglePagePosition", "getScrollPagePosition"}) do
            hook(s, v, name, function(stock) return function(self, pos, ...)
                local p = pos:copy(); p.y = p.y-s.height
                if p.y < 0 or p.y >= self.dimen.h then return nil end
                return stock(self, p, ...)
            end end)
        end
        for _, name in ipairs({"getSinglePageRect", "getScrollPageRect", "getScreenPageArea"}) do
            hook(s, v, name, function(stock) return function(self, ...)
                local rect = stock(self, ...)
                if rect then rect = rect:copy(); rect.y = rect.y+s.height end
                return rect
            end end)
        end
    else
        -- Wrap the document setter, leaving unscaled book/global margin settings intact.
        hook(s, ui.document, "setPageMargins", function(stock) return function(self, l,t,r,b)
            return stock(self, l,t+s.height,r,b)
        end end)
        -- CRE scroll mode ignores top margins. Reserve an engine viewport there,
        -- translate document coordinates, and use the same height for scroll steps.
        local function scroll() return v.view_mode == "scroll" end
        local function reserve() return s.height + (v.footer_visible and s.height or 0) end
        hook(s, ui.document, "setViewDimen", function(stock) return function(self, dimen)
            local d = dimen:copy()
            if scroll() then d.h = d.h - reserve() end
            return stock(self, d)
        end end)
        hook(s, v, "recalculate", function(stock) return function(self, ...)
            local result = stock(self, ...)
            if scroll() then self.visible_area.h = self.dimen.h - reserve() end
            return result
        end end)
        hook(s, v, "drawScrollView", function(stock) return function(self, bb, x, y, ...)
            return stock(self, bb, x, y+s.height, ...)
        end end)
        hook(s, v, "screenToPageTransform", function(stock) return function(self, pos)
            if scroll() then pos=pos:copy(); pos.y=pos.y-s.height end
            return stock(self, pos)
        end end)
        hook(s, v, "pageToScreenTransform", function(stock) return function(self, ...)
            local rect = stock(self, ...)
            if scroll() and rect then rect=rect:copy(); rect.y=rect.y+s.height end
            return rect
        end end)
        hook(s, ui.document, "getScreenPositionFromXPointer", function(stock) return function(self, ...)
            local y,x = stock(self, ...)
            return y+(scroll() and s.height or 0),x
        end end)
        for _, name in ipairs({"onGotoViewRel", "_gotoPos"}) do
            hook(s, ui.rolling, name, function(stock) return function(self, ...)
                if not scroll() or s.scroll_dimensions then return stock(self, ...) end
                local full = ui.dimen
                ui.dimen = full:copy(); ui.dimen.h = ui.dimen.h - s.height
                s.scroll_dimensions = true
                local result = { pcall(stock, self, ...) }
                ui.dimen, s.scroll_dimensions = full, nil
                if not result[1] then error(result[2]) end
                return unpack(result, 2)
            end end)
        end
        hook(s, ui.document, "setViewMode", function(stock) return function(self, ...)
            local result = stock(self, ...)
            RS.relayout(s)
            return result
        end end)
        -- Force only the engine header off, without persisting configurable.status_line.
        s.native_header = ui.document.configurable.status_line
        hook(s, ui.document, "setStatusLineProp", function(stock) return function(self) return stock(self, 1) end end)
        ui.document:setStatusLineProp(1)
        s.native_top_enabled = ui.rolling.cre_top_bar_enabled
        ui.rolling.cre_top_bar_enabled = false
        if ui.crelistener then
            ui.crelistener:unscheduleHeaderRefresh()
            hook(s, ui.crelistener, "rescheduleHeaderRefreshIfNeeded", function() return function() end end)
        end
        hook(s, ui.rolling, "onSetStatusLine", function(stock) return function(self) return stock(self, 1) end end)
    end
    -- Show the default Orbit bottom lane even if the native footer was disabled.
    v.footer_visible = true
    f.mode = f.mode_list.page_progress
    s.tick = function()
        if RS.session ~= s then return end
        if RS.visible(s) then
            local t = os.date("*t")
            local clock = StatusLayout.clock(t.hour, t.min, G_reader_settings:isTrue("twelve_hour_clock"))
            if clock ~= s.clock then RS.dirty(s, true) end
            if Device:getPowerDevice():getCapacity() ~= s.battery then RS.dirty(s, false) end
        end
        RS.arm(s)
    end
    RS.relayout(s)
    RS.arm(s)
end
function RS.disable(closing)
    local s = RS.session
    if not s then return end
    RS.session = nil
    UIManager:unschedule(s.tick)
    for i=#s.undo,1,-1 do local h=s.undo[i]; h[1][h[2]]=h[3] end
    s.view.footer_visible, s.footer.mode = s.native_visible, s.native_mode
    s.footer.genFooterText = s.native_generator
    if not s.ui.paging then
        s.ui.rolling.cre_top_bar_enabled = s.native_top_enabled
        if not closing then s.ui.document:setStatusLineProp(s.native_header or (s.native_top_enabled and 0 or 1)) end
    end
    if not closing then
        s.footer:updateFooterContainer()
        s.footer:resetLayout(true)
        s.footer:onUpdateFooter(true)
        RS.relayout(s)
        s.footer:rescheduleFooterAutoRefreshIfNeeded()
        if s.ui.crelistener then s.ui.crelistener:rescheduleHeaderRefreshIfNeeded() end
    end
end
function RS.changed()
    UIManager:nextTick(function()
        local ui = liveUI()
        if S.status_orbit_layout ~= false then RS.enable(ui) else RS.disable() end
    end)
end

local function after(name, fn)
    local stock = OrbitAndroid[name]
    OrbitAndroid[name] = function(self, ...)
        local result
        if stock then result = stock(self, ...) end
        fn(self, ...)
        return result
    end
end
after("onReaderReady", function(self) if S.status_orbit_layout ~= false then RS.enable(self.ui) end end)
after("onPageUpdate", function() local s=RS.session; if s then RS.dirty(s, false) end end)
after("onPosUpdate", function() local s=RS.session; if s then RS.dirty(s, false) end end)
after("onSuspend", function() local s=RS.session; if s then s.asleep=true; UIManager:unschedule(s.tick) end end)
after("onResume", function() local s=RS.session; if s then s.asleep=false; RS.arm(s) end end)
after("onCharging", function() local s=RS.session; if s then RS.dirty(s, false) end end)
after("onNotCharging", function() local s=RS.session; if s then RS.dirty(s, false) end end)
after("onTimeFormatChanged", function() local s=RS.session; if s then RS.dirty(s, true) end end)
after("onCloseDocument", function(self) if RS.session and RS.session.ui == self.ui then RS.disable(true) end end)
after("onCloseWidget", function(self) if RS.session and RS.session.ui == self.ui then RS.disable(true) end end)

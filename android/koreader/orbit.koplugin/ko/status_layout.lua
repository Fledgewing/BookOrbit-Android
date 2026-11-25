-- SPDX-License-Identifier: AGPL-3.0-or-later
-- W17: reader-owned status strips. No floating window or input handler.
ReadingStatus = {}
local RS = ReadingStatus

-- Restore instance slots, including originally inherited/absent values.
local function hook(s, obj, key, fn)
    s.undo[#s.undo+1] = { obj, key, rawget(obj, key) }
    obj[key] = fn(obj[key])
end

-- Called before layout and painting, so book margin changes and rotation take effect.
function RS.geometry(s, top, bottom)
    local Screen = Device.screen
    local maximum = StatusLayout.fontSize(S.status_orbit_size)
    local key = table.concat({top, bottom, maximum, tostring(S.status_orbit_add_space == true), Screen:scaleBySize(1)}, ":")
    if s.geometry_key == key then return end
    s.geometry_key = key
    local function fit(margin)
        local lane = StatusLayout.fit(margin, maximum, math.max(1, Screen:scaleBySize(1)), function(size)
            local w = s.Text:new{ text="Ag", face=s.Font:getFace("ffont", size) }
            local h = w:getSize().h; w:free(); return h
        end, S.status_orbit_add_space == true)
        lane.face = s.Font:getFace("ffont", math.max(1, lane.size))
        return lane
    end
    s.top, s.bottom = fit(top), fit(bottom)
end
function RS.margins(s)
    if s.ui.paging then
        local v = s.view
        -- Only unused screen surround is safe; page-internal whitespace is content.
        local offset = v.state and v.state.offset
        local area = v.visible_area
        if not v.page_scroll and offset and area then
            return math.max(0, offset.y),
                math.max(0, v.dimen.h - offset.y - area.h - (v.footer_visible and s.footer:getHeight() or 0))
        end
        return 0, 0
    end
    if s.view.view_mode == "scroll" then return 0, 0 end
    local m = s.ui.typeset.unscaled_margins
    return Device.screen:scaleBySize(m[2]), Device.screen:scaleBySize(m[4])
end
function RS.refreshGeometry(s) RS.geometry(s, RS.margins(s)) end

function RS.visible(s)
    return not s.asleep and UIManager:getTopmostVisibleWidget() == s.ui
end
function RS.dirty(s, top)
    if not RS.visible(s) or (not top and not s.view.footer_visible) then return end
    local Screen = Device.screen
    local h = (top and s.top or s.bottom).height
    if h == 0 then return end
    UIManager:setDirty(s.ui, "partial", s.Geom:new{
        x = 0, y = top and 0 or Screen:getHeight() - h,
        w = Screen:getWidth(), h = h,
    })
end
function RS.arm(s)
    UIManager:unschedule(s.tick)
    if not s.asleep then UIManager:scheduleIn(60 - os.time() % 60, s.tick) end
end

function RS.paint(s, bb, x, y, bottom_only)
    local Screen = Device.screen
    local width, height = Screen:getWidth(), Screen:getHeight()
    local lane = s.top
    local function measure(value)
        local w = s.Text:new{ text=value, face=lane.face }
        local width = w:getSize().w; w:free(); return width
    end
    local function text(value, px, py)
        if value == "" then return end
        local w = s.Text:new{ text = value, face = lane.face }
        w:paintTo(bb, x + math.floor(px), y + math.floor(py + (lane.height-w:getSize().h)/2))
        w:free()
    end
    if not bottom_only and lane.height > 0 then
        local t = os.date("*t")
        local clock = StatusLayout.clock(t.hour, t.min, G_reader_settings:isTrue("twelve_hour_clock"))
        s.clock = clock
        bb:paintRect(x, y, width, lane.height, s.BB.COLOR_WHITE)
        text(clock, (width - measure(clock))/2, 0)
    end
    lane = s.bottom
    if not s.view.footer_visible or lane.height == 0 then return end
    local footer = s.footer
    local page = footer.pageno or (s.ui.paging and s.ui.paging.current_page) or s.ui.document:getCurrentPage()
    local total = footer.pages or s.ui.document:getPageCount()
    local progress = StatusLayout.progress(page, total, footer.percent_finished)
    local chapter = s.ui.toc:getTocTitleByPage(page) or ""
    local battery = Device:getPowerDevice():getCapacity()
    s.battery = battery
    local icon = "▱"
    local glyph = s.battery_program
    local icon_size = math.max(1, lane.height - 2 * Device.screen:scaleBySize(1))
    local icon_w = glyph.width * icon_size
    local battery_text = string.format("%d%%", battery)
    local function itemWidth(v) return v == icon and icon_w or measure(v) end
    local layout = StatusLayout.layout(width, s.inset, s.gap,
        icon .. " " .. battery_text, icon, chapter, progress,
        function(v)
            if v:sub(1,#icon) == icon then return icon_w + measure(v:sub(#icon+1)) end
            return itemWidth(v)
        end)
    local by = height - lane.height
    bb:paintRect(x, y + by, width, lane.height, s.BB.COLOR_WHITE)
    if layout.left ~= "" then
        local ix, iy = x+s.inset, y+by+(lane.height-glyph.height*icon_size)/2
        BatteryGlyph.draw(glyph, icon_size, battery, function(dx,dy,w,h,color)
            -- Round edges, not widths, so neighbouring rectangles share pixels.
            local l,t = math.floor(ix+dx+0.5), math.floor(iy+dy+0.5)
            local r,b = math.floor(ix+dx+w+0.5), math.floor(iy+dy+h+0.5)
            if r>l and b>t then bb:paintRect(l,t,r-l,b-t,color==1 and s.BB.COLOR_BLACK or s.BB.COLOR_WHITE) end
        end)
        if layout.left ~= icon then text(" " .. battery_text, s.inset+icon_w, by) end
    end
    text(layout.chapter, layout.cx, by)
    text(layout.right, layout.rx, by)
end

-- Layout updates use the engine's own anchor-preserving relayout, not a repaint/crop.
function RS.relayout(s)
    if RS.session == s then RS.refreshGeometry(s) end
    if s.ui.paging then
        local v, paging = s.view, s.ui.paging
        local x, y, zoom
        if v.page_scroll then
            paging:setPagePosition(paging.current_page, paging:getTopPosition())
        elseif v.visible_area then
            x, y, zoom = v.visible_area.x, v.visible_area.y, v.state.zoom
        end
        s.ui:handleEvent(Event:new("SetDimensions", Device.screen:getSize()))
        if RS.session == s and S.status_orbit_add_space == true and not v.page_scroll
                and v.state and v.state.offset and v.visible_area then
            -- Rezoom can consume existing surround. Add only any remaining deficit,
            -- then let the engine settle again before translating hits/highlights.
            for _ = 1, s.top.height + s.bottom.height do
                local top, bottom = RS.margins(s)
                local dt = math.max(0, math.ceil(s.top.height - top - s.top.extra))
                local db = v.footer_visible and math.max(0, math.ceil(s.bottom.height - bottom - s.bottom.extra)) or 0
                if dt == 0 and db == 0 then break end
                s.top.extra, s.bottom.extra = s.top.extra + dt, s.bottom.extra + db
                s.ui:handleEvent(Event:new("SetDimensions", Device.screen:getSize()))
            end
        end
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
        Geom = Geom, Text = Text, Font = Font, BB = require("ffi/blitbuffer"),
        inset = Device.screen:scaleBySize(2), gap = Device.screen:scaleBySize(4) }
    RS.session = s
    for _, path in ipairs({ SOURCE_DIR .. "/battery.json", SOURCE_DIR .. "/../../../shared/ui/battery.json" }) do
        local file = io.open(path, "rb")
        if file then s.battery_program = SettingsSync.decodeJson(file:read("*a")); file:close(); break end
    end
    assert(s.battery_program, "BookSync battery drawing program missing")
    RS.refreshGeometry(s)
    local f, v = s.footer, s.view
    s.native_visible, s.native_mode = rawget(v, "footer_visible"), rawget(f, "mode")
    s.native_generator = rawget(f, "genFooterText")
    s.native_setting_mode = G_reader_settings:readSetting("reader_footer_mode")
    -- The native table is shared with global settings: never modify it.
    s.dormant_footer = f.settings.disabled == true
    local settings = {}; for k,val in pairs(f.settings) do settings[k] = val end
    settings.reclaim_height = false
    hook(s, f, "settings", function() return settings end)
    hook(s, f, "reclaim_height", function() return false end)
    hook(s, f, "getHeight", function() return function() return v.footer_visible and s.bottom.extra or 0 end end)
    f:unscheduleFooterAutoRefresh()
    hook(s, f, "rescheduleFooterAutoRefreshIfNeeded", function() return function() end end)
    hook(s, f, "updateFooterText", function() return function() end end)
    hook(s, f, "paintTo", function() return function() end end)
    hook(s, v, "paintTo", function(stock) return function(self, bb, x, y)
        stock(self, bb, x, y)
        if S.status_orbit_add_space ~= true then RS.refreshGeometry(s) end
        RS.paint(s, bb, x, y)
    end end)
    -- Native toggle/tap handlers still own visibility and their gesture return values.
    hook(s, f, "applyFooterMode", function(stock) return function(self, ...)
        local was = v.footer_visible
        if s.dormant_footer then
            -- KOReader stops initialization before creating footer widgets when disabled.
            -- Keep its existing gesture registrations; only the visibility state is needed.
            local mode = ...
            if mode ~= nil then self.mode = mode end
            v.footer_visible = self.mode ~= self.mode_list.off
        else
            stock(self, ...)
        end
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
                    local d = dimensions:copy(); d.h = d.h - s.top.extra
                    return stock(self, d, ...)
                end end)
            end
        end
        for _, name in ipairs({"drawSinglePage", "drawScrollPages", "drawPageBackground", "drawPageSurround"}) do
            hook(s, v, name, function(stock) return function(self, bb, x, y, ...)
                return stock(self, bb, x, y+s.top.extra, ...)
            end end)
        end
        for _, name in ipairs({"getSinglePagePosition", "getScrollPagePosition"}) do
            hook(s, v, name, function(stock) return function(self, pos, ...)
                local p = pos:copy(); p.y = p.y-s.top.extra
                if p.y < 0 or p.y >= self.dimen.h - f:getHeight() then return nil end
                return stock(self, p, ...)
            end end)
        end
        for _, name in ipairs({"getSinglePageRect", "getScrollPageRect", "getScreenPageArea"}) do
            hook(s, v, name, function(stock) return function(self, ...)
                local rect = stock(self, ...)
                if rect then rect = rect:copy(); rect.y = rect.y+s.top.extra end
                return rect
            end end)
        end
    else
        -- Wrap the document setter, leaving unscaled book/global margin settings intact.
        hook(s, ui.document, "setPageMargins", function(stock) return function(self, l,t,r,b)
            local bottom = b - (v.footer_visible and s.bottom.extra or 0)
            if v.view_mode == "scroll" then RS.geometry(s, 0, 0) else RS.geometry(s, t, bottom) end
            return stock(self, l,t+s.top.extra,r,bottom + (v.footer_visible and s.bottom.extra or 0))
        end end)
        -- CRE scroll mode ignores top margins. Reserve an engine viewport there,
        -- translate document coordinates, and use the same height for scroll steps.
        local function scroll() return v.view_mode == "scroll" end
        local function reserve() return s.top.extra + (v.footer_visible and s.bottom.extra or 0) end
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
            return stock(self, bb, x, y+s.top.extra, ...)
        end end)
        hook(s, v, "screenToPageTransform", function(stock) return function(self, pos)
            if scroll() then pos=pos:copy(); pos.y=pos.y-s.top.extra end
            return stock(self, pos)
        end end)
        hook(s, v, "pageToScreenTransform", function(stock) return function(self, ...)
            local rect = stock(self, ...)
            if scroll() and rect then rect=rect:copy(); rect.y=rect.y+s.top.extra end
            return rect
        end end)
        hook(s, ui.document, "getLinkFromPosition", function(stock) return function(self, pos)
            if scroll() then
                pos = pos:copy(); pos.y = pos.y-s.top.extra
                if pos.y < 0 or pos.y >= v.dimen.h-reserve() then return "" end
            end
            return stock(self, pos)
        end end)
        hook(s, ui.document, "getScreenPositionFromXPointer", function(stock) return function(self, ...)
            local y,x = stock(self, ...)
            return y+(scroll() and s.top.extra or 0),x
        end end)
        for _, name in ipairs({"onGotoViewRel", "_gotoPos"}) do
            hook(s, ui.rolling, name, function(stock) return function(self, ...)
                if not scroll() or s.scroll_dimensions then return stock(self, ...) end
                local full = ui.dimen
                ui.dimen = full:copy(); ui.dimen.h = ui.dimen.h - s.top.extra
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
        if not s.dormant_footer then
            s.footer:updateFooterContainer()
            s.footer:resetLayout(true)
            s.footer:onUpdateFooter(true)
        end
        RS.relayout(s)
        s.footer:rescheduleFooterAutoRefreshIfNeeded()
        if s.ui.crelistener then s.ui.crelistener:rescheduleHeaderRefreshIfNeeded() end
    end
end
function RS.changed()
    UIManager:nextTick(function()
        local ui = liveUI()
        RS.disable()
        if S.status_orbit_layout == true then RS.enable(ui) end
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
after("onReaderReady", function(self) if S.status_orbit_layout == true then RS.enable(self.ui) end end)
after("onPageUpdate", function() local s=RS.session; if s then RS.dirty(s, false) end end)
after("onPosUpdate", function() local s=RS.session; if s then RS.dirty(s, false) end end)
after("onSuspend", function() local s=RS.session; if s then s.asleep=true; UIManager:unschedule(s.tick) end end)
after("onResume", function() local s=RS.session; if s then s.asleep=false; RS.arm(s) end end)
after("onCharging", function() local s=RS.session; if s then RS.dirty(s, false) end end)
after("onNotCharging", function() local s=RS.session; if s then RS.dirty(s, false) end end)
after("onTimeFormatChanged", function() local s=RS.session; if s then RS.dirty(s, true) end end)
after("onCloseDocument", function(self) if RS.session and RS.session.ui == self.ui then RS.disable(true) end end)
after("onCloseWidget", function(self) if RS.session and RS.session.ui == self.ui then RS.disable(true) end end)

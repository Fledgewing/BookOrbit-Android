-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Reader-owned strips. Effective engine margins are temporary; native settings stay untouched.
ReadingStatus = {}
local RS = ReadingStatus
local function hook(s, obj, key, fn)
    s.undo[#s.undo+1] = { obj, key, rawget(obj, key) }
    obj[key] = fn(obj[key])
end

function RS.margins(s)
    local v = s.view
    if s.ui.paging then
        local offset, area = v.state and v.state.offset, v.visible_area
        if not v.page_scroll and offset and area then
            return math.max(0, offset.y), math.max(0, v.dimen.h-offset.y-area.h),
                math.max(0, offset.x or 0), math.max(0, v.dimen.w-(offset.x or 0)-area.w)
        end
        return 0, 0, 0, 0
    end
    if v.view_mode == "scroll" then return 0, 0, 0, 0 end
    local m = s.ui.typeset.unscaled_margins
    local scale = function(n) return Device.screen:scaleBySize(n) end
    return scale(m[2]), scale(m[4]), scale(m[1]), scale(m[3])
end
function RS.refreshGeometry(s)
    local top, bottom, left, right = RS.margins(s)
    s.left, s.width = left, math.max(0, Device.screen:getWidth()-left-right)
    local key = table.concat({top, bottom, left, right, StatusLayout.fontSize(S.status_orbit_size),
        tostring(s.ui.rolling and s.ui.rolling.cre_top_bar_enabled), Device.screen:scaleBySize(1)}, ":")
    if s.geometry_key == key then return end
    s.geometry_key = key
    local size = StatusLayout.fontSize(S.status_orbit_size)
    local face = s.Font:getFace("ffont", size)
    local bold = StatusLayout.fontBold(S.status_orbit_size)
    local text = s.Text:new{ text="Ag", face=face, bold=bold, padding=0, fgcolor=s.BB.COLOR_BLACK }
    local text_height = text:getSize().h
    local height = StatusLayout.stripHeight(text_height, math.max(1, Device.screen:scaleBySize(1)))
    -- TextWidget has now selected the actual regular/bold face. Measure ink above
    -- the baseline: getSize().h includes ascenders, descenders and line spacing.
    local cap = s.RenderText:sizeUtf8Text(0, nil, text.face, "H", false, text.bold).y_top
    local battery_height = StatusLayout.batteryHeight(cap, text_height)
    text:free()
    local function lane(available)
        -- EPUB reserves only missing space in the engine, never in saved margins.
        local safe = not s.ui.paging and s.view.view_mode ~= "scroll" or available >= height
        return {size=size, height=safe and height or 0, face=face, bold=bold, battery_height=battery_height}
    end
    s.top = lane(top)
    if s.ui.rolling and s.ui.rolling.cre_top_bar_enabled then s.top.height = 0 end
    s.bottom = lane(bottom)
    if s.bottom_visible == nil then s.bottom_visible = true end
end
function RS.visible(s)
    return not s.asleep and UIManager:getTopmostVisibleWidget() == s.ui
end
function RS.dirty(s, top)
    if not RS.visible(s) or (not top and not s.bottom_visible) then return end
    RS.refreshGeometry(s)
    local h = (top and s.top or s.bottom).height
    if h == 0 then return end
    UIManager:setDirty(s.ui, "partial", s.Geom:new{
        x=s.left, y=top and 0 or Device.screen:getHeight()-h, w=s.width, h=h })
end
function RS.arm(s)
    UIManager:unschedule(s.tick)
    if not s.asleep then UIManager:scheduleIn(60-os.time()%60, s.tick) end
end

function RS.paint(s, bb, x, y, bottom_only)
    local Screen = Device.screen
    RS.refreshGeometry(s)
    local width, height = s.width, Screen:getHeight()
    x = x + s.left
    if width <= 0 then return end
    local lane = s.top
    local function measure(value)
        local w = s.Text:new{ text=value, face=lane.face, fgcolor=s.BB.COLOR_BLACK, bold=lane.bold, padding=0 }
        local width = w:getSize().w; w:free(); return width
    end
    local function text(value, px, py)
        if value == "" then return end
        local w = s.Text:new{ text = value, face = lane.face, fgcolor = s.BB.COLOR_BLACK, bold = lane.bold, padding = 0 }
        w:paintTo(bb, x + math.floor(px), y + math.floor(py + (lane.height-w:getSize().h)/2))
        w:free()
    end
    if not bottom_only and lane.height > 0 then
        local t = os.date("*t")
        local clock = StatusLayout.clock(t.hour, t.min, G_reader_settings:isTrue("twelve_hour_clock"))
        s.clock = clock
        bb:paintRect(x, y, width, lane.height, s.BB.COLOR_WHITE)
        if measure(clock) <= width then text(clock, (width - measure(clock))/2, 0) end
    end
    lane = s.bottom
    if not s.bottom_visible or lane.height == 0 then return end
    local footer = s.footer
    local page = footer.pageno or (s.ui.paging and s.ui.paging.current_page) or s.ui.document:getCurrentPage()
    local total = footer.pages or s.ui.document:getPageCount()
    local progress = StatusLayout.progress(page, total, footer.percent_finished)
    local chapter = s.ui.toc:getTocTitleByPage(page) or ""
    local power = Device:getPowerDevice()
    local battery = power:getCapacity()
    local charging = power.isCharging and power:isCharging()
    s.battery = battery
    local icon = "▱"
    local glyph = s.battery_program
    local icon_size = math.max(0, lane.battery_height / glyph.height)
    local icon_w = glyph.width * icon_size
    local battery_text = string.format("%d%%", battery)
    local percent_w = measure(battery_text)
    local mark_h = glyph.height*icon_size
    local mark_w = charging and StatusLayout.chargingMark(mark_h) or 0
    local battery_w = icon_w + s.gap + percent_w + (charging and s.gap+mark_w or 0)
    local layout = StatusLayout.layout(width, s.inset, s.gap,
        icon, icon, chapter, progress,
        function(value) return value == icon and battery_w or measure(value) end, true)
    local by = height - lane.height
    bb:paintRect(x, y + by, width, lane.height, s.BB.COLOR_WHITE)
    if layout.left ~= "" then
        local ix, iy = x+layout.lx, y+by+(lane.height-glyph.height*icon_size)/2
        local function rectangles(ox, oy)
            return function(dx,dy,w,h,color)
                -- Round edges, not widths, so neighbouring rectangles share pixels.
                local l,t = math.floor(ox+dx+0.5), math.floor(oy+dy+0.5)
                local r,b = math.floor(ox+dx+w+0.5), math.floor(oy+dy+h+0.5)
                if r>l and b>t then bb:paintRect(l,t,r-l,b-t,color==1 and s.BB.COLOR_BLACK or s.BB.COLOR_WHITE) end
            end
        end
        BatteryGlyph.draw(glyph, icon_size, battery, rectangles(ix, iy))
        local percent_x = layout.lx+icon_w+s.gap
        text(battery_text, percent_x, by)
        if charging then
            StatusLayout.chargingMark(mark_h, rectangles(x+percent_x+percent_w+s.gap, iy))
        end
    end
    text(layout.chapter, layout.cx, by)
    text(layout.right, layout.rx, by)
end

-- Normalize the hidden native reservation once per reader instance, including when
-- BookSync strips are off. Do not guess a saved height or overwrite a chosen value.
function RS.releaseHiddenFooter(ui)
    local footer = ui and ui.view and ui.view.footer
    if not footer or footer._booksync_height then return false end
    local stock = footer.getHeight
    footer._booksync_height = stock
    footer.getHeight = function(self, ...)
        if RS.session and RS.session.ui == ui or self.mode == 0 then return 0 end
        return stock(self, ...)
    end
    return true
end
function RS.relayout(ui)
    if ui.typeset and not ui.paging then
        ui.typeset:onSetPageMargins(ui.typeset.unscaled_margins)
    elseif ui.paging then
        ui:handleEvent(Event:new("SetDimensions", Device.screen:getSize()))
        ui.paging:onInitScrollPageStates()
    end
end

function RS.enable(ui)
    if RS.session or not ui or not ui.document or not ui.view or not ui.view.footer then return end
    local s = { ui=ui, view=ui.view, footer=ui.view.footer, undo={},
        Geom=require("ui/geometry"), Text=require("ui/widget/textwidget"),
        Font=require("ui/font"), RenderText=require("ui/rendertext"), BB=require("ffi/blitbuffer"),
        inset=math.max(1, Device.screen:scaleBySize(4)), gap=math.max(1, Device.screen:scaleBySize(4)) }
    RS.releaseHiddenFooter(ui)
    RS.session = s
    local margins = ui.typeset and ui.typeset.unscaled_margins or {}
    log("status layout: loaded margins top=" .. tostring(margins[2]) .. " bottom=" .. tostring(margins[4])
        .. " footer_height=" .. tostring(s.footer:getHeight()) .. " footer_reclaim=" .. tostring(s.footer.reclaim_height)
        .. " footer_mode=" .. tostring(s.footer.mode))
    for _, path in ipairs({ SOURCE_DIR .. "/battery.json", SOURCE_DIR .. "/../../../shared/ui/battery.json" }) do
        local file = io.open(path, "rb")
        if file then s.battery_program = SettingsSync.decodeJson(file:read("*a")); file:close(); break end
    end
    assert(s.battery_program, "BookSync battery drawing program missing")
    RS.refreshGeometry(s)
    hook(s, s.footer, "reclaim_height", function() return true end)
    if ui.typeset and not ui.paging then
        hook(s, ui.document, "setPageMargins", function(stock) return function(self, l,t,r,b)
            RS.refreshGeometry(s)
            if s.view.view_mode ~= "scroll" then
                t, b = math.max(t, s.top.height), math.max(b, s.bottom.height)
            end
            return stock(self, l,t,r,b)
        end end)
    end
    RS.relayout(ui)
    -- Native widgets must not reappear at their old height when a fixed-size
    -- strip has no safe PDF/scroll surround. Their refresh controller still runs.
    hook(s, s.footer, "paintTo", function() return function() end end)
    -- The overlay consumes footer taps without invoking native settings writers.
    hook(s, s.footer, "onToggleFooterMode", function() return function()
        s.bottom_visible = not s.bottom_visible
        UIManager:setDirty(ui, "partial")
        return true
    end end)
    hook(s, s.view, "paintTo", function(stock) return function(self, bb, x, y)
        stock(self, bb, x, y)
        RS.paint(s, bb, x, y)
    end end)
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
    RS.arm(s)
    UIManager:setDirty(ui, "partial")
end
function RS.disable(closing)
    local s = RS.session
    if not s then return end
    RS.session = nil
    UIManager:unschedule(s.tick)
    for i=#s.undo,1,-1 do local h=s.undo[i]; h[1][h[2]]=h[3] end
    if not closing then RS.relayout(s.ui); UIManager:setDirty(s.ui, "partial") end
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
after("onReaderReady", function(self)
    local repaired = RS.releaseHiddenFooter(self.ui)
    if S.status_orbit_layout == true then RS.enable(self.ui)
    elseif repaired then RS.relayout(self.ui) end
end)
after("onPageUpdate", function() local s=RS.session; if s then RS.dirty(s, false) end end)
after("onPosUpdate", function() local s=RS.session; if s then RS.dirty(s, false) end end)
after("onSuspend", function() local s=RS.session; if s then s.asleep=true; UIManager:unschedule(s.tick) end end)
after("onResume", function() local s=RS.session; if s then s.asleep=false; RS.arm(s) end end)
after("onCharging", function() local s=RS.session; if s then RS.dirty(s, false) end end)
after("onNotCharging", function() local s=RS.session; if s then RS.dirty(s, false) end end)
after("onTimeFormatChanged", function() local s=RS.session; if s then RS.dirty(s, true) end end)
after("onCloseDocument", function(self) if RS.session and RS.session.ui == self.ui then RS.disable(true) end end)
after("onCloseWidget", function(self) if RS.session and RS.session.ui == self.ui then RS.disable(true) end end)

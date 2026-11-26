-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- The Full refresh's progress (docs/design/sqlite-cache.md "Progress display"): one popup when the
-- reader starts it, then a small % in the bottom-left corner. One number, from the companion's
-- status (`pct`), that never goes down. A tap on it (outside a book) shows the full message: done
-- and total, time left, errors; another tap folds it. At the end "Done" for a few seconds.
-- E-ink: only the badge's own rectangle is redrawn, at most every EVERY_S and only when what it
-- says changed. It is a toast (every tap goes on to what is under it) and never takes focus; in a
-- book it is the one exception to the reading gate the user asked for, and passive there.
---------------------------------------------------------------------------------------------

Badge = { EVERY_S = 3, DONE_S = 5, POPUP_S = 6, MARGIN = 6 }

-- Bounded details only: these messages never open another widget.
function Badge.notice(what)
    Badge.notices = Badge.notices or {}
    if Badge.notices[#Badge.notices] == tostring(what) then return end
    table.insert(Badge.notices, tostring(what))
    if #Badge.notices > 8 then table.remove(Badge.notices, 1) end
end

local function nowT() return OC.now() end

-- "37%".
function Badge.short(pct) return string.format("%d%%", pct or 0) end

-- "Full refresh · 37% · 2,140 of 10,512 · about 3 min left · 2 errors".
function Badge.long(s, pct)
    s = s or {}
    local parts = { string.format(_("Full refresh · %d%%"), pct or 0) }
    local total = math.max(tonumber(s.total) or 0, tonumber(s.done) or 0)
    if total > 0 then table.insert(parts, string.format(_("%s of %s"), Cache.count(s.done or 0), Cache.count(total))) end
    local eta = tonumber(s.eta_s)
    if eta and eta > 0 then
        table.insert(parts, eta < 90 and _("about 1 min left") or string.format(_("about %d min left"), math.floor(eta / 60 + 0.5)))
    end
    local errors = (tonumber(s.errors) or 0) + (tonumber(s.skipped) or 0)
    if errors > 0 then table.insert(parts, string.format(errors == 1 and _("%d error") or _("%d errors"), errors)) end
    if type(s.limit_note) == "table" and s.limit_note.text then table.insert(parts, s.limit_note.text) end
    local line = table.concat(parts, " · ")
    if Badge.notices and #Badge.notices > 0 then line = line .. "\n" .. table.concat(Badge.notices, "\n") end
    return line
end

-- The start popup's text.
function Badge.popupText(pct)
    return string.format(_("Full refresh in progress · about %d%% done · you can keep reading and browsing while it loads"), pct or 0)
end

---------------------------------------------------------------- the widget

local function widgetClass()
    if Badge._class then return Badge._class end
    local okc, InputContainer = pcall(require, "ui/widget/container/inputcontainer")
    if not okc or type(InputContainer) ~= "table" or type(InputContainer.extend) ~= "function" then return nil end
    local W = InputContainer:extend{ name = "orbit_refresh_badge", toast = true }
    function W:init()
        local Geom = require("ui/geometry")
        local GestureRange = require("ui/gesturerange")
        self.dimen = Geom:new{ x = 0, y = 0, w = 0, h = 0 }
        self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } } }
        self:build()
    end
    function W:build()
        local Geom = require("ui/geometry")
        local Font = require("ui/font")
        local Size = require("ui/size")
        local Blitbuffer = require("ffi/blitbuffer")
        local TextWidget = require("ui/widget/textwidget")
        local TextBoxWidget = require("ui/widget/textboxwidget")
        local FrameContainer = require("ui/widget/container/framecontainer")
        local Device = require("device")
        local sw, sh = Device.screen:getWidth(), Device.screen:getHeight()
        local face = Font:getFace("xx_smallinfofont")
        local inner
        if self.expanded then
            inner = TextBoxWidget:new{ text = self.text, face = face, width = math.floor(sw * 0.6) }
        else
            inner = TextWidget:new{ text = self.text, face = face }
        end
        self.frame = FrameContainer:new{ bordersize = (Size.border and Size.border.thin) or 1, padding = (Size.padding and Size.padding.small) or 4,
            radius = 0, background = Blitbuffer.COLOR_WHITE, inner }
        local sz = type(self.frame.getSize) == "function" and self.frame:getSize() or { w = 60, h = 24 }
        local m = Badge.MARGIN
        self.dimen = Geom:new{ x = m, y = sh - (sz.h or 24) - m, w = sz.w or 60, h = sz.h or 24 }
    end
    function W:paintTo(bb)
        if self.frame and type(self.frame.paintTo) == "function" then self.frame:paintTo(bb, self.dimen.x, self.dimen.y) end
    end
    -- Taps always go on to what is under the badge (a toast); outside a book they also fold it.
    function W:onTap(_arg, ges)
        if reading() or not (ges and ges.pos and self.dimen and type(self.dimen.contains) == "function" and self.dimen:contains(ges.pos)) then return false end
        Badge.toggle()
        return false
    end
    -- A toast is closed by UIManager on input; this one stays until the run ends.
    function W:onCloseWidget() if Badge.widget == self then Badge.widget = nil end end
    Badge._class = W
    return W
end

-- Redraws only the badge's rectangle (and, when it shrank, the rectangle it left).
local function dirty(w, old)
    local new = w.dimen
    UIManager:setDirty(w, function() return "fast", new end)
    if old and (old.w > new.w or old.h > new.h) then UIManager:setDirty("all", function() return "ui", old end) end
end

-- Shows or changes the badge. -- gate: the Full refresh badge, the user's one exception (sqlite-cache.md "Progress display")
function Badge.draw()
    local text = Badge.expanded and Badge.long(Badge.status, Badge.pct) or Badge.text_now or Badge.short(Badge.pct)
    Badge.history = Badge.history or {}
    if Badge.widget and Badge.widget.text == text and Badge.widget.expanded == Badge.expanded then return end
    table.insert(Badge.history, text)
    Badge.drawn_at = nowT()
    local W = widgetClass()
    if not W then return end
    if Badge.widget then
        local w = Badge.widget
        local old = w.dimen
        w.text, w.expanded = text, Badge.expanded
        pcall(w.build, w)
        dirty(w, old)
        return
    end
    local okn, w = pcall(W.new, W, { text = text, expanded = Badge.expanded })
    if not okn or not w then return end
    Badge.widget = w
    UIManager:show(w, "fast") -- gate: the Full refresh badge, the user's one exception (sqlite-cache.md "Progress display")
end

function Badge.close()
    local w = Badge.widget
    Badge.widget, Badge.text_now, Badge.expanded, Badge.status = nil, nil, nil, nil
    if w then
        local old = w.dimen
        UIManager:close(w)
        UIManager:setDirty("all", function() return "ui", old end)
    end
end

---------------------------------------------------------------- the run

-- A Full refresh starts: the popup (only one the reader started), then the badge.
function Badge.start(manual, s)
    Badge.notices = {}
    if Badge.closing then UIManager:unschedule(Badge.closing); Badge.closing = nil end
    Badge.pct, Badge.text_now, Badge.expanded, Badge.status, Badge.running = math.max(0, tonumber(s and s.pct) or 0), nil, nil, s, true
    if manual then orbitNote(Badge.popupText(Badge.pct), Badge.POPUP_S, true) end
    Badge.draw()
end

-- The companion's status, at each poll: the % never goes down; drawn when it changed, at most
-- every EVERY_S.
function Badge.update(s)
    if not Badge.running then return end
    Badge.status = s
    local pct = math.min(99, math.max(Badge.pct or 0, tonumber(s and s.pct) or 0))
    local changed = pct ~= Badge.pct
    Badge.pct = pct
    if not changed and not Badge.expanded then return end
    if nowT() - (Badge.drawn_at or 0) < Badge.EVERY_S then return end
    Badge.draw()
end

-- Pressed again while it runs: the full message.
function Badge.expand()
    if not Badge.running then return end
    Badge.expanded = true
    Badge.draw()
end

function Badge.toggle()
    Badge.expanded = not Badge.expanded or nil
    Badge.draw()
end

-- The run ended: "Done" (or why it stopped) for DONE_S, then the badge goes.
function Badge.finish(text, s)
    if not Badge.running then return end
    Badge.running = nil
    if s then Badge.status = s end
    if text == nil then Badge.pct = 100 end
    Badge.text_now = text or _("Done")
    Badge.expanded = nil
    Badge.draw()
    Badge.closing = function() Badge.closing = nil; Badge.close() end
    UIManager:scheduleIn(text and Badge.DONE_S * 2 or Badge.DONE_S, Badge.closing)
end

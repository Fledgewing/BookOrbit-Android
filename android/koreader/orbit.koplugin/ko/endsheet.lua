-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- The end-of-book sheet (docs/design/end-of-book/DESIGN.md §4 "Layout", mockups.html): anchored
-- to the bottom, about 60% of the screen, heavy top rule, one e-ink paint and no dimming; the
-- last page stays visible above it, and a tap there closes the sheet (the mark stays). Rows,
-- top to bottom: status + Undo, title + author link, stars + "Write a review", the next card,
-- one suggestion, then Back to book / Home. Built from KOReader's own widgets; every tap goes
-- to EOB.actions.
---------------------------------------------------------------------------------------------

local function W(name) return require("ui/widget/" .. name) end

EndSheet = nil
do
    local InputContainer = W("container/inputcontainer")
    EndSheet = InputContainer:extend{
        name = "orbit_end_of_book",
        modal = true,
        covers_fullscreen = false,
    }
end

function EndSheet:init()
    local Device = require("device")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    self.screen_w, self.screen_h = Device.screen:getWidth(), Device.screen:getHeight()
    self.sheet_h = math.floor(self.screen_h * 0.6)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.ges_events = {
        TapAnywhere = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    self:build()
end

-- Taps above the sheet close it (the book is still marked); taps on it go to its buttons.
function EndSheet:onTapAnywhere(_arg, ges)
    local y0 = self.screen_h - self.sheet_h
    if ges and ges.pos and ges.pos.y < y0 then
        EOB.actions.back()
        return true
    end
    return false
end

function EndSheet:onClose()
    EOB.actions.back()
    return true
end

function EndSheet:update(model, card_state)
    self.model = model
    self.card_state = card_state
    self:build()
    UIManager:setDirty(self, function() return "ui", self.frame and self.frame.dimen end)
end

-- The pieces the tests look at: { kind, text, action } in drawing order.
function EndSheet:rows()
    local m, cs, rows = self.model, self.card_state, {}
    local ui, b = self.ui, self.book
    local function add(kind, text, action) table.insert(rows, { kind = kind, text = text, action = action }) end
    local r = { kind = "status", text = m.status }
    if m.undo then r.label, r.action = "Undo", function() EOB.actions.undo(ui, b) end
    elseif m.can_mark then r.label, r.action = "Mark as finished", function() EOB.actions.mark(ui, b) end end
    table.insert(rows, r)
    add("title", m.title)
    if m.author then add("author", m.author, function() EOB.actions.author(ui, b, m.author) end) end
    for n = 1, 5 do
        add("star", (m.stars and n <= m.stars) and "★" or "☆", function() EOB.actions.star(ui, b, n) end)
    end
    add("review", "Write a review", function() EOB.actions.review(ui) end)
    local card = m.next
    if card then
        add("next", card.line)
        if card.book_id then
            local busy = cs and cs.book_id == card.book_id
            if busy and cs.failure == "failed" then
                add("card", "Couldn't connect")
                add("button", "Try again", function() EOB.actions.retry(ui, b, card.book_id, card.title) end)
                add("button", "Get it at the next sync", function() EOB.actions.later(ui, b, card.book_id, card.title) end)
            elseif busy and cs.failure == "error" then
                add("card", "Download failed: " .. tostring(cs.err or "server error"))
                add("button", "Try again", function() EOB.actions.retry(ui, b, card.book_id, card.title) end)
            elseif busy and cs.text then
                add("card", card.title .. " · " .. cs.text)
            else
                add("button", (card.action == "open" and "Open: " or "Download and open: ") .. tostring(card.title),
                    function() EOB.actions.book(ui, b, card.book_id, card.title) end)
            end
        end
    end
    local s = m.suggestion
    if s then
        add("suggest", s.line)
        add("button", tostring(s.title), function() EOB.actions.book(ui, b, s.book_id, s.title) end)
    end
    add("footer", "Back to book", function() EOB.actions.back() end)
    add("footer", "Home", function() EOB.actions.home(ui) end)
    return rows
end

function EndSheet:build()
    local Blitbuffer = require("ffi/blitbuffer")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local Size = require("ui/size")
    local Button = W("button")
    local FrameContainer = W("container/framecontainer")
    local HorizontalGroup = W("horizontalgroup")
    local HorizontalSpan = W("horizontalspan")
    local LineWidget = W("linewidget")
    local TextBoxWidget = W("textboxwidget")
    local VerticalGroup = W("verticalgroup")
    local VerticalSpan = W("verticalspan")
    local BottomContainer = W("container/bottomcontainer")

    local pad = Size.padding.large or 10
    local inner_w = self.screen_w - 2 * pad
    local vg = VerticalGroup:new{ align = "left" }
    local stars, footer = HorizontalGroup:new{}, HorizontalGroup:new{}
    local function text(t, face, bold)
        return TextBoxWidget:new{ text = t or "", face = Font:getFace(face or "cfont", 20), bold = bold, width = inner_w }
    end
    local function button(t, cb, w, primary)
        return Button:new{ text = t, callback = cb, width = w or inner_w, bordersize = primary and 2 or 1,
            radius = Size.radius and Size.radius.button or 0, text_font_bold = primary }
    end
    local function gap(h) table.insert(vg, VerticalSpan:new{ width = h or pad }) end
    for _i, r in ipairs(self:rows()) do
        if r.kind == "status" then
            local row = HorizontalGroup:new{ TextBoxWidget:new{ text = r.text, face = Font:getFace("cfont", 18),
                width = inner_w - (r.action and 200 or 0) } }
            if r.action then table.insert(row, button(r.label, r.action, 190)) end
            table.insert(vg, row); gap()
        elseif r.kind == "title" then
            table.insert(vg, text(r.text, "cfont", true))
        elseif r.kind == "author" then
            table.insert(vg, button(r.text, r.action, nil, false)); gap()
        elseif r.kind == "star" then
            table.insert(stars, button(r.text, r.action, math.floor(inner_w / 7)))
            table.insert(stars, HorizontalSpan:new{ width = 4 })
        elseif r.kind == "review" then
            table.insert(vg, stars)
            table.insert(vg, button(r.text, r.action, nil, false)); gap()
        elseif r.kind == "next" or r.kind == "suggest" or r.kind == "card" then
            table.insert(vg, text(r.text, "smallinfofont")); gap(4)
        elseif r.kind == "button" then
            table.insert(vg, button(r.text, r.action, nil, true)); gap()
        elseif r.kind == "footer" then
            table.insert(footer, button(r.text, r.action, math.floor(inner_w / 2) - 4, false))
            table.insert(footer, HorizontalSpan:new{ width = 8 })
        end
    end
    table.insert(vg, footer)
    local rule = LineWidget:new{ dimen = Geom:new{ w = self.screen_w, h = Size.line and Size.line.thick or 3 },
        background = Blitbuffer.COLOR_BLACK }
    self.frame = FrameContainer:new{
        width = self.screen_w, height = self.sheet_h, padding = pad, bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ rule, VerticalSpan:new{ width = pad }, vg },
    }
    self[1] = BottomContainer:new{ dimen = Geom:new{ w = self.screen_w, h = self.screen_h }, self.frame }
end

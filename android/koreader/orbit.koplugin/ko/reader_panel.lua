-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Reuse EndSheet's measured rows and SheetLayout; every datum comes from Library.
ReaderPanel = {}
local ReaderSheet = EndSheet:extend{ name="booksync_reader_panel", min_button=50 }

function ReaderSheet:rows() return self.display_rows end
function ReaderSheet:onClose() ReaderPanel.close(); return true end
function ReaderSheet:onTapAnywhere(_arg, ges)
    if ges and ges.pos and ges.pos.y > (self.sheet_h or 0) then return self:onClose() end
    return false
end
function ReaderSheet:build()
    local finish = Budgets.span(self.screen .. ".draw", now_s, log)
    EndSheet.build(self)
    self[1] = require("ui/widget/container/topcontainer"):new{
        dimen=require("ui/geometry"):new{w=self.screen_w, h=self.screen_h}, self.frame }
    finish()
end
function ReaderPanel.close()
    local sheet = ReaderPanel.sheet
    ReaderPanel.sheet = nil
    if sheet then UIManager:close(sheet) end
end
local function button(text, action) return {kind="button", text=text, action=action} end

function ReaderPanel.show(ui, screen, key, reuse, attempt)
    if not (ui and ui.document) and screen ~= "details" then return false end
    local paint = Library.paint(screen)
    local book = paint:widget("reader-progress")
    local result = key and book:book(key) or book:reader(ui.document.file)
    local battery = screen == "reader-top-panel" and paint:battery() or nil
    local caps = paint:capabilities()
    local m = ReaderPanelPlan.model(result, battery)
    paint:flush()
    local rows = {
        {kind="title", text=m.title}, {kind="label", text=m.author},
        {kind="label", text=m.progress_text}, {kind="progress", value=m.progress},
    }
    local function back() ReaderPanel.close() end
    if screen == "reader-top-panel" then
        table.insert(rows, {kind="label", text=m.battery})
        if caps.progress and caps.progress.syncCurrent then
            local sync = button("Sync", function() end)
            local busy = false
            sync.action = function()
                if busy then return end
                busy = true
                local sheet = ReaderPanel.sheet
                sheet.syncing = true
                sync.text = "Syncing…"
                sheet:build(); UIManager:setDirty(sheet, "ui")
                Library.syncCurrent(function(_, message)
                    busy = false
                    sheet.syncing = false
                    -- Never reopen or repaint a dismissed panel over the reading page.
                    if ReaderPanel.sheet ~= sheet or UIManager:getTopmostVisibleWidget() ~= sheet then return end
                    sync.text = message
                    sheet:build(); UIManager:setDirty(sheet, "ui")
                end)
            end
            table.insert(rows, sync)
        end
        table.insert(rows, button("Book info", function() ReaderPanel.show(ui, "book-info", m.key) end))
        table.insert(rows, {kind="footer", text="Home", action=function()
            back(); if state.module then state.module:onOrbitGoHome() end
        end})
        table.insert(rows, {kind="footer", text="KOReader menu", action=function()
            back(); ReaderPanel.stockMenu(ui.menu)
        end})
    else
        table.insert(rows, {kind="label", text=m.days})
        table.insert(rows, {kind="label", text=m.time})
        table.insert(rows, {kind="label", text=m.pages})
        if screen == "book-info" and m.key then
            table.insert(rows, button("Details", function() ReaderPanel.show(ui, "details", m.key) end))
        end
    end
    table.insert(rows, {kind="footer", text="Back to book", action=back})
    local sheet
    if reuse then
        sheet = reuse
        sheet.model, sheet.display_rows = m, rows
        sheet:build()
        UIManager:setDirty(sheet, "ui")
    else
        ReaderPanel.close()
        sheet = ReaderSheet:new{ui=ui, screen=screen, model=m, display_rows=rows}
        ReaderPanel.sheet = sheet
        UIManager:show(sheet) -- gate: user action (reader top panel, Book info or Details)
    end
    -- A cold projection completes quietly, only while the user-opened surface is still on top.
    if (result.pending or caps.pending or (battery and battery.pending)) and (attempt or 0) < 5 then
        local document = ui and ui.document
        UIManager:scheduleIn(0.5, function()
            if ReaderPanel.sheet == sheet and not sheet.syncing and UIManager:getTopmostVisibleWidget() == sheet
                and (not ui or ui.document == document) then
                ReaderPanel.show(ui, screen, key, sheet, (attempt or 0)+1)
            end
        end)
    end
    return true
end
function ReaderPanel.details(key, ui) return ReaderPanel.show(ui, "details", key) end

-- Replace only the visible reader menu. Menu-search construction keeps its native seam.
local okMenu, ReaderMenu = pcall(require, "apps/reader/modules/readermenu")
if okMenu and type(ReaderMenu.onShowMenu) == "function" then
    ReaderPanel.stockMenu = ReaderMenu.onShowMenu
    wrap(ReaderMenu, "onShowMenu", function(stock) return function(self, tab, hidden)
        if hidden or not (self.ui and self.ui.document) then return stock(self, tab, hidden) end
        if self.menu_container then self:onCloseReaderMenu() end
        return ReaderPanel.show(self.ui, "reader-top-panel")
    end end, "reader-panel")
end
-- Also reachable from the plugin's existing Tools entry when a native menu is open.
local baseMenu = OrbitAndroid.menuItems
function OrbitAndroid:menuItems(...)
    local rows = baseMenu(self, ...)
    if self.ui and self.ui.document then
        table.insert(rows, 1, {text="Book info", callback=function() ReaderPanel.show(self.ui, "book-info") end})
    end
    return rows
end
local baseClose = OrbitAndroid.onCloseWidget
function OrbitAndroid:onCloseWidget(...)
    ReaderPanel.close()
    return baseClose(self, ...)
end

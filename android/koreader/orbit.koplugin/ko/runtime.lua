-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- The patch's module: one per FileManager / ReaderUI, created like a plugin
---------------------------------------------------------------------------------------------

state = {
    started = false,            -- first module of this process seen
    sas_done_at = -1000,        -- "Sync and sleep" finished (monotonic s)
    pending_home = nil,         -- "go home" waiting for the file browser
    suspended_at = nil,         -- last Suspend (monotonic s)
    paused_for = nil,           -- how long the last Suspend lasted, set on Resume
}

-- Battery stats batches (Stats above). One accumulator per KOReader process.
stats_acc = Stats.new(now_s())

function contentOfUI(ui)
    local doc = ui and ui.document
    if not doc then return "none" end
    return Stats.contentOf(doc.file, ui.view and ui.view.page_scroll, ui.paging ~= nil)
end

function readerContent()
    return contentOfUI(require("apps/reader/readerui").instance)
end

-- Sends the batch so far. content/open default to the open book (or none).
function Stats.send(why, content, open)
    if not Companion.has("stats") then return end
    content = content or readerContent()
    if open == nil then open = content ~= "none" end
    local extras = Stats.take(stats_acc, now_s(), content, open,
        { reason = why, wifi_mode = Shared.mode(), reading_schedule = S.reading_schedule or "off" })
    if extras then Companion.send(Companion.ACTION.STATS, extras) end
end

-- Every INTERVAL while a book is open. A Lua timer only: it never wakes the device.
function statsTick()
    local t = now_s()
    if Stats.isDue(stats_acc, t, readerContent() ~= "none") then Stats.send("interval") end
    local wait = stats_acc.at and math.max(5, stats_acc.at + Stats.INTERVAL - now_s()) or Stats.INTERVAL
    UIManager:scheduleIn(wait, statsTick)
end

-- Count every physical refresh: _repaint drains _refresh_stack through refresh_methods
-- (uimanager.lua:1388) and then replaces it (:1399), so the old table lists exactly what was
-- sent to the screen, after merging (:1200) and full-refresh promotion.
if UIManager._repaint then
    local stock_repaint = UIManager._repaint
    function UIManager:_repaint(...)
        local stack = self._refresh_stack
        local r = pack(stock_repaint(self, ...))
        if type(stack) == "table" and self._refresh_stack ~= stack then
            for i = 1, #stack do Stats.refresh(stats_acc, stack[i].mode) end
        end
        return unpack(r, 1, r.n)
    end
end

-- Clicker actions inside KOReader (android/docs/BTKEYS-DESIGN.md "Actions"): exact page turns
-- (ReaderPaging/ReaderRolling:onGotoViewRel, readerpaging.lua:575, readerrolling.lua:900),
-- Back (ReaderBack:onBack, readerback.lua:117), frontlight (DeviceListener:onToggleFrontlight,
-- devicelistener.lua:175), and the patch's own Home and Sync and sleep.
function Clicks.run(action, code)
    local ReaderUI = require("apps/reader/readerui")
    local ui = ReaderUI.instance or liveUI()
    log("clicker: key", code, "->", action)
    if action == "next" or action == "prev" then
        if ReaderUI.instance then ReaderUI.instance:handleEvent(Event:new("GotoViewRel", action == "next" and 1 or -1)) end
    elseif action == "back" then
        UIManager:sendEvent(Event:new("Back"))
    elseif action == "light" then
        if ui then ui:handleEvent(Event:new("ToggleFrontlight")) end
    elseif action == "home" then
        if state.module then state.module:onOrbitGoHome() end
    elseif action == "sync_sleep" then
        if state.module then state.module:onOrbitSyncAndSleep() end
    end
end

click_state = {}

function clickSchedule(code, st, acts)
    if st.task then UIManager:unschedule(st.task); st.task = nil end
    local due = Clicks.nextDue(st, acts)
    if not due then return end
    st.task = function()
        st.task = nil
        local kind = Clicks.tick(st, now_s(), acts)
        if kind then Clicks.run(acts[kind], code) end
        clickSchedule(code, st, acts)
    end
    UIManager:scheduleIn(math.max(0.01, due - now_s()), st.task)
end

-- A mapped key: handled here and dropped (KEY_PRESS 1, KEY_RELEASE 0, KEY_REPEAT 2,
-- input.lua:23-25). Returns true when it was ours.
function Clicks.onKey(ev)
    local acts = ev and Clicks.map[ev.code]
    if not acts then return false end
    local st = click_state[ev.code] or {}
    click_state[ev.code] = st
    local kind
    if ev.value == 1 then kind = Clicks.down(st, now_s(), acts)
    elseif ev.value == 0 then kind = Clicks.up(st, now_s(), acts) end
    if kind then Clicks.run(acts[kind], ev.code) end
    clickSchedule(ev.code, st, acts)
    return true
end

---------------------------------------------------------------------------------------------

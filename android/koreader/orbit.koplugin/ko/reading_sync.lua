-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Sync while reading
---------------------------------------------------------------------------------------------

function OrbitAndroid:chapterKey(page)
    local toc = self.ui and self.ui.toc
    if not toc or type(page) ~= "number" then return nil end
    local ok, key = pcall(function()
        if toc:isChapterStart(page) then return page end
        return toc:getPreviousChapter(page)
    end)
    return ok and key or nil
end

function OrbitAndroid:onCloseDocument()
    if not (self.ui and self.ui.document) then return end
    self.closed_file=self.ui.document.file
    self.closed_content=contentOfUI(self.ui)
    self.closed_capture=true
    ReadingSync.queue("close",self.ui)
    ReadingSync.closePrompt()
    local file=self.closed_file
    UIManager:nextTick(function()
        ReadingSync.command("sync.drain",{closed_path=file,online=NetworkMgr:isConnected()},function() Library.idle() end)
    end)
end

function OrbitAndroid:onCloseWidget()
    if self.ui and (self.ui.document or self.closed_file) then
        if not self.closed_capture then ReadingSync.queue("close",self.ui) end
        ReadingSync.closePrompt()
        Stats.send("close", self.closed_content or contentOfUI(self.ui), false)
    end
    -- A patch update waiting for the book: once nothing is open (another book may be opening).
    if self.ui and (self.ui.document or self.closed_file) and state.restart_waiting then
        UIManager:scheduleIn(1.5, function() OrbitAndroid.maybeRestart(self, "check") end)
    end
    -- The book closed: what waited for the reader shows now (another book may be opening).
    if self.ui and (self.ui.document or self.closed_file) then
        UIManager:scheduleIn(1.5, function()
            Gate.drain("book closed")
            Library.idle()
        end)
    end
    -- A close (Back to file browser, Exit) runs this; a kill or suspend doesn't. A close Home
    -- started keeps the book as the current one (home_book); the user's own close clears it.
    if self.ui and (self.ui.document or self.closed_file) then
        local file = self.closed_file or self.ui.document.file
        if state.closing_for_home and state.closing_for_home == file then
            S.home_book = file
            log("home: book closed by Home; it stays the current book")
        else
            S.home_book = nil
        end
        state.closing_for_home = nil
        S.open_book_at_exit = nil
        saveSettings()
        pcall(function() G_reader_settings:flush() end)
    end
    if self.reading_task then
        UIManager:unschedule(self.reading_task)
        self.reading_task = nil
    end
    if self.ui and (self.ui.document or self.closed_file) and self.book_tracked then
        self.book_tracked = false
        local st = Wifi.state()
        local restore = WifiPlan.bookClosed(st)
        log("wifi: book closed | mode", st.mode, restore == "on" and "| Wi-Fi was on before the book: turning it back on" or "")
        if restore == "on" and Companion.has("wifi") then
            Companion.netUp("book_closed", { owner = "auto" })
        end
    end
end

function OrbitAndroid:onReaderReady()
    -- "Open book at exit": survives a kill (flushed now), cleared when the book is closed.
    -- Another book opening replaces Home's current book.
    local file = self.ui and self.ui.document and self.ui.document.file
    if file and (S.open_book_at_exit ~= file or S.home_book) then
        S.open_book_at_exit = file
        S.home_book = nil
        saveSettings()
        pcall(function() G_reader_settings:flush() end)
    end
    self.schedule = Schedule.new(S.reading_schedule, now_s())
    ReadingSync.forward=0
    ReadingSync.turn_at=0; ReadingSync.last_page=nil
    ReadingSync.preview(self.ui)
    Stats.send("open", contentOfUI(self.ui), true)
    self:bookOpenFlow()
end

function OrbitAndroid:bookOpenFlow()
    local st=Wifi.state()
    WifiPlan.bookOpened(st,Wifi.radioOn())
    self.book_tracked=true
    Wifi.acquire("open")
    Net.up(nil,{reason="open",cap=20},function()
        ReadingSync.run("open",function() Wifi.release("open") end)
    end)
end
function OrbitAndroid:onNetworkConnected()
    Wifi.kick()
    Library.networkRestored()
    ReadingSync.run(inBook() and "wake" or "close")
end
function OrbitAndroid:onPageUpdate(page)
    if self.ui and (self.ui.document or self.closed_file) then Stats.page(stats_acc) end
    ReadingSync.turn_at=os.time()
    if ReadingSync.last_page and page>ReadingSync.last_page then ReadingSync.forward=(ReadingSync.forward or 0)+1 end
    ReadingSync.last_page=page
    -- The power settings choose cadence; the position rule chooses safe pull/push behavior.
    if S.reading_schedule == "off" or not (self.ui and self.ui.document) then return end
    local t = now_s()
    Schedule.onPage(self.schedule, self:chapterKey(page), t)
    if Schedule.isDue(self.schedule, t) then
        -- Run once the reader settles on a page, never in the middle of turning.
        if self.reading_task then UIManager:unschedule(self.reading_task) end
        self.reading_task = function()
            self.reading_task = nil
            self:readingSync()
        end
        UIManager:scheduleIn(3, self.reading_task)
    end
end

function OrbitAndroid:readingSync()
    if not inBook() then return end
    Schedule.markSynced(self.schedule,now_s())
    Wifi.acquire("reading")
    Net.up(nil,{reason="reading",cap=20},function()
        ReadingSync.run("pause",function() Wifi.release("reading") end)
    end)
end

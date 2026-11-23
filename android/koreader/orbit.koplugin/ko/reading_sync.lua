-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
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

function OrbitAndroid:onCloseWidget()
    if self.ui and self.ui.document then Stats.send("close", contentOfUI(self.ui), false) end
    -- A patch update waiting for the book: once nothing is open (another book may be opening).
    if self.ui and self.ui.document and state.restart_waiting then
        UIManager:scheduleIn(1.5, function() OrbitAndroid.maybeRestart(self, "check") end)
    end
    -- A close (Back to file browser, Exit) runs this; a kill or suspend doesn't. A close Home
    -- started keeps the book as the current one (home_book); the user's own close clears it.
    if self.ui and self.ui.document then
        local file = self.ui.document.file
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
    if self.ui and self.ui.document and self.book_tracked then
        self.book_tracked = false
        local st = Wifi.state()
        local restore = WifiPlan.bookClosed(st)
        log("wifi: book closed | mode", st.mode, restore == "on" and "| Wi-Fi was on before the book: turning it back on" or "")
        if restore == "on" and Companion.installed() then
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
    self:hookPluginPagePush()
    Stats.send("open", contentOfUI(self.ui), true)
    self:bookOpenFlow()
end

-- A book opened: remember Wi-Fi for off while reading; in the off-while-reading and just-in-time
-- modes, bring the network up for the plugin's open-time pull, then let Wi-Fi go off.
function OrbitAndroid:bookOpenFlow()
    if not Companion.installed() then return end
    local st = Wifi.state()
    local on = Wifi.radioOn()
    WifiPlan.bookOpened(st, on)
    self.book_tracked = true
    log("wifi: book opened (Wi-Fi", on == false and "off" or "on", ") mode", st.mode)
    if st.mode == "always_on" then return end
    local p = bookorbit(self.ui)
    if not p or not p:isLoggedIn() then return Wifi.kick() end
    Wifi.acquire("open")
    Net.up(p, { reason = "open", cap = 20, need_server = true }, function(ok)
        if not ok then return Wifi.release("open") end
        -- The plugin pulls on open by itself, or on NetworkConnected when it was offline
        -- (main.lua:1353-1361); its 25 s debounce keeps this from doubling up.
        p:requestProgressPull(false, false, "orbit_open")
        UIManager:scheduleIn(1, function()
            Sync.waitOutbox(p, 20, function() Wifi.release("open") end)
        end)
    end)
end

function OrbitAndroid:onNetworkConnected()
    Wifi.kick()
end

function OrbitAndroid:onPageUpdate(page)
    if self.ui and self.ui.document then Stats.page(stats_acc) end
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
    if self.reading_running then return end
    local p = bookorbit(self.ui)
    if not p or not p:isLoggedIn() or not inBook() then return end
    if not can(p, "reading_sync") then return end
    self.reading_running = true
    local t0 = now_s()
    Schedule.markSynced(self.schedule, t0)
    log("reading: sync due (" .. S.reading_schedule .. ")")
    Wifi.acquire("reading")
    Net.up(p, { reason = "reading", cap = 20, need_server = true }, function(ok, res)
        if not ok then
            Wifi.release("reading")
            self.reading_running = false
            log("reading: network not ready; try again at the next interval:", res.detail or "")
            return
        end
        p:requestLifecycleOutboxDrain("orbit_reading")
        local digest = p:getDocumentDigest()
        p:fetchRemoteProgress(digest, function(fetched)
            self.reading_running = false
            -- Wi-Fi goes back to its previous state once the plugin's push or pull is done.
            UIManager:scheduleIn(1, function()
                Sync.waitOutbox(p, 20, function() Wifi.release("reading") end)
            end)
            if not fetched then
                log("reading: plugin could not read BookOrbit's position")
                return
            end
            local remote = p.last_remote_progress
            local has_remote = remote ~= nil and remote.digest == digest and remote.percentage ~= nil
            local local_pct = p:getLastPercent()
            local action = Plan.readingAction{
                has_remote = has_remote,
                same_place = has_remote and p:isSamePlace(remote, local_pct, p:getLastProgress()),
                remote_newer = has_remote and p:remoteProgressIsNewer(remote, local_pct),
                forward = p.settings.sync_forward,
            }
            if action == "pull" then
                p.pull_timestamp = 0
                p:requestProgressPull(false, false, "orbit_reading")
            elseif action == "push" then
                p.push_timestamp = 0
                p:requestProgressPush(false, false, "orbit_reading")
            end
            log("reading: plugin", action, "in", fmt(now_s() - t0))
        end, true)
    end)
end

---------------------------------------------------------------------------------------------

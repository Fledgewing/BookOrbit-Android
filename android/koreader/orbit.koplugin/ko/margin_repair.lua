-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Check the selected book before KOReader loads its sidecar. The companion parses
-- and repairs only allowlisted keys; no file parsing or hash work on the UI loop.
MarginRepair = { seq = 0 }
function MarginRepair.install()
    local Reader = require("apps/reader/readerui")
    if MarginRepair.installed or not Compat.callable(Reader.showReader) then return end
    MarginRepair.installed = true
    local stock = Reader.showReader
    function Reader:showReader(file, ...)
        local ui = liveUI()
        -- Never edit the settings of an already loaded document.
        if ui and ui.document and ui.document.file == file then return stock(self, file, ...) end
        if Companion.workerProblem() then return stock(self, file, ...) end
        if MarginRepair.pending then return end
        MarginRepair.seq = MarginRepair.seq + 1
        local token = tostring(os.time()) .. "-" .. tostring(MarginRepair.seq)
        local args = pack(...)
        if not Companion.send(Companion.ACTION.PATCH, { reason = "margin repair before open", repair_book = file, repair_token = token }) then
            return stock(self, file, unpack(args, 1, args.n))
        end
        MarginRepair.pending = token
        log("status repair: checking selected book before open")
        local started = now_s()
        local function poll()
            if MarginRepair.pending ~= token then return end
            local result = Cache.decode(OC.readFile(OC.dir() .. "/repair-result.lua", 1024) or "")
            if type(result) == "table" and result.token == token then
                MarginRepair.pending = nil
                log("status repair: book-open check", result.result)
                return stock(self, file, unpack(args, 1, args.n))
            end
            if now_s() - started > 10 then
                MarginRepair.pending = nil
                log("status repair: no answer; book open deferred")
                return OC.note(_("BookSync Companion did not answer. Please open the book again."), 4)
            end
            UIManager:scheduleIn(0.1, poll)
        end
        UIManager:nextTick(poll)
    end
end
MarginRepair.install()

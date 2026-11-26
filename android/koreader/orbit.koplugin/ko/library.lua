-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Thin 0.12 UI boundary. One host-owned context per paint; finish with :flush().
Library = {}
local function counts()
    return {rows=0,bytes=0,spawns=0,roundTrips=0,network=0,snapshotBytes=0}
end
function Library.paint(screen)
    local budget = Budgets.get("screens", screen)
    return setmetatable({budget=budget, screen_budget=budget, usage=counts(), widgets={}, pending={}, seen={},
        metrics=counts(), finish=Budgets.span(screen .. ".paint", now_s, log)}, {__index=Library})
end
function Library:widget(name, instance)
    local budget = Budgets.get("widgets", name)
    local key = name .. ":" .. tostring(instance or name)
    assert(#key <= 256, "Widget instance key exceeds budget")
    if not self.widgets[key] then self.widgets[key] = counts() end
    return setmetatable({budget=budget, screen_budget=self.screen_budget, usage=self.widgets[key], widgets=self.widgets,
        is_widget=true, pending=self.pending, seen=self.seen, metrics=self.metrics}, {__index=Library})
end
function Library:read(op, args)
    assert(not self.metrics.flushed, "Library paint already flushed")
    local rows, bytes = 0, 0
    local finish = Budgets.span("library." .. op, now_s, function(line) log(line, "rows", rows, "bytes", bytes) end)
    args = args or {}
    args.op = op
    args.limit = math.max(1, math.min(self.budget.rows, Budgets.MAX_ROWS, Budgets.libraryWindow.rows,
        math.floor(tonumber(args.limit) or self.budget.rows)))
    args.bytes = math.min(self.budget.bytes, Budgets.libraryWindow.bytes, Budgets.MAX_SNAPSHOT)
    local request = Cache.encode(args)
    assert(#request <= Budgets.MAX_REQUEST, "Library request exceeds budget")
    local result, decoded = LibraryAdapter.read(request)
    if result then
        rows, bytes = result.items and #result.items or 1, decoded or 0
        assert(rows <= args.limit and bytes <= args.bytes, "Library call budget exceeded")
        local call = counts(); call.rows, call.bytes, call.snapshotBytes = rows, bytes, bytes
        assert(Budgets.check(Budgets.libraryWindow, call))
        self.usage.rows, self.usage.bytes = self.usage.rows + rows, self.usage.bytes + bytes
        self.usage.snapshotBytes = self.is_widget and self.usage.bytes or math.max(self.usage.snapshotBytes, bytes)
        assert(Budgets.check(self.budget, self.usage))
        self.metrics.rows, self.metrics.bytes = self.metrics.rows + rows, self.metrics.bytes + bytes
        self.metrics.snapshotBytes = math.max(self.metrics.snapshotBytes, self.usage.snapshotBytes)
        assert(Budgets.check(self.screen_budget, self.metrics))
    end
    if not self.seen[request] then
        assert(#self.pending < Budgets.MAX_BATCH, "Library paint request budget exceeded")
        self.seen[request] = true
        table.insert(self.pending, request)
    end
    finish()
    return result or {items={}, freshness={saved=false}, pending=true}
end
function Library:battery() return self:read("battery", {limit=1}) end
function Library:readingStats() return self:read("reading.stats", {limit=1}) end
function Library:capabilities() return self:read("capabilities") end
function Library:window(source, query, offset, limit)
    return self:read("window", {source=source or "library/all", query=query or {}, offset=offset or 0, limit=limit})
end
function Library:book(key) return self:read("book", {key=key, limit=1}) end
function Library:counts(source, query) return self:read("counts", {source=source or "library/all", query=query or {}}) end
-- Reader identity stays opaque to the UI; the worker joins the local file ledger.
function Library:reader(path)
    local position = LibraryAdapter.readerPosition and LibraryAdapter.readerPosition(path)
    return self:read("reader", {path=path, native_progress=position, limit=1})
end
-- An explicit user action, never invoked by paint/read.
function Library.syncCurrent(done)
    local finish = Budgets.span("library.progress.sync", now_s, log)
    local result = LibraryAdapter.syncCurrent(done)
    finish()
    return result
end
function Library:facets(source, query, field, offset, limit)
    return self:read("facets", {source=source or "library/all", query=query or {}, field=field, offset=offset or 0, limit=limit})
end
function Library:progress(key) return self:read("progress", {key=key, limit=1}) end
function Library:status(key) return self:read("status", {key=key, limit=1}) end
function Library:job(key) return self:read("job", {key=key, limit=1}) end
function Library:flush()
    assert(not self.is_widget and not self.metrics.flushed, "Library host paint already flushed or missing")
    self.metrics.flushed = true
    if #self.pending > 0 and LibraryAdapter.request(self.pending) then self.metrics.roundTrips = 1 end
    assert(Budgets.check(self.screen_budget, self.metrics))
    self.finish()
    self.pending = {}
    return self.metrics
end

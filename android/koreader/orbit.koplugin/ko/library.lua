-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Thin 0.12 UI boundary. One host-owned context per paint; finish with :flush().
Library = {}
-- Explicit user command; the existing adapter/worker owns the full-refresh job.
local function command(id, run)
    local finish = Budgets.span("library." .. id .. ".enqueue", now_s, log)
    local result = run()
    finish()
    return result
end
function Library.fullRefresh() return command("full-refresh", LibraryAdapter.fullRefresh) end
function Library.syncNow(reader) return command("sync-now", function() return LibraryAdapter.syncNow(reader) end) end
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
    local function read()
    args = args or {}
    args.op = op
    args.limit = math.max(1, math.min(self.budget.rows, Budgets.MAX_ROWS, Budgets.libraryWindow.rows,
        math.floor(tonumber(args.limit) or self.budget.rows)))
    args.bytes = math.min(self.budget.bytes, Budgets.libraryWindow.bytes, Budgets.MAX_SNAPSHOT)
    local request = Cache.encode(args)
    assert(#request <= Budgets.MAX_REQUEST, "Library request exceeds budget")
    assert(self.metrics.bytes + args.bytes <= self.screen_budget.bytes, "Library page byte budget exhausted")
    assert(self.metrics.rows + args.limit <= self.screen_budget.rows, "Library page row budget exhausted")
    assert(self.seen[request] or #self.pending < Budgets.MAX_BATCH, "Library paint request budget exceeded")
    local result, decoded = LibraryAdapter.read(request,op)
    if result then
        rows, bytes = result.items and #result.items or 1, decoded or 0
        assert(rows <= args.limit and bytes <= args.bytes, "Library call budget exceeded")
        local call = counts(); call.rows, call.bytes, call.snapshotBytes = rows, bytes, bytes
        assert(Budgets.check(Budgets.libraryWindow, call))
        local usage = counts()
        usage.rows, usage.bytes = self.usage.rows + rows, self.usage.bytes + bytes
        usage.snapshotBytes = self.is_widget and usage.bytes or math.max(self.usage.snapshotBytes, bytes)
        assert(Budgets.check(self.budget, usage))
        for k,v in pairs(usage) do self.usage[k]=v end
        self.metrics.rows, self.metrics.bytes = self.metrics.rows + rows, self.metrics.bytes + bytes
        self.metrics.snapshotBytes = math.max(self.metrics.snapshotBytes, self.usage.snapshotBytes)
        assert(Budgets.check(self.screen_budget, self.metrics))
    end
    if not self.seen[request] then
        assert(#self.pending < Budgets.MAX_BATCH, "Library paint request budget exceeded")
        self.seen[request] = true
        table.insert(self.pending, request)
    end
    return result or {items={}, freshness={saved=false}, pending=true}
    end
    local ok,result=pcall(read)
    finish()
    if not ok then error(result,0) end
    return result
end
function Library:accountState() return self:read("account.state", {limit=1}) end
function Library:summary() return self:read("library.summary", {limit=1}) end
function Library:modeEstimates() return self:read("mode-estimates", {limit=3}) end
function Library:battery() return self:read("battery", {limit=1}) end
function Library:readingStats() return self:read("reading.stats", {limit=1}) end
function Library:capabilities() return self:read("capabilities") end
function Library:window(source, query, offset, limit)
    return self:read("window", {source=source or "library/all", query=query or {}, offset=offset or 0, limit=limit})
end
function Library:book(key) return self:read("book", {key=key, limit=1}) end
function Library:cover(key) return self:read("cover", {key=key, limit=1}) end
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
function Library:facets(source, query, field, offset, limit, exclude_current)
    return self:read("facets", {source=source or "library/all", query=query or {}, field=field, offset=offset or 0, limit=limit, exclude_current=exclude_current})
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

-- Owned read-model notifications. The adapter uses the existing companion event poll.
function Library:lists(limit) return self:read("lists", {limit=limit}) end
function Library.subscribe(callback)
    Library.listener = callback
    LibraryAdapter.watch(true)
    return function()
        if Library.listener == callback then Library.listener=nil; LibraryAdapter.watch(false) end
    end
end
function Library.changed(event)
    if Library.listener then Library.listener(event) end
end
function Library.open(row)
    if type(row.local_path) ~= "string" then return false end
    require("apps/reader/readerui"):showReader(row.local_path)
    return true
end

function Library.retry() LibraryAdapter.reset() end

-- Explicit account commands; transport and connector compatibility stay behind the adapter.
function Library.openAccount() return LibraryAdapter.openAccount() end
function Library.accountReturned() return LibraryAdapter.accountReturned() end

function Library.syncPosition(document, update, callback)
    local args={document=document}
    if update then args.percentage,args.position=update.percentage,update.position end
    return LibraryAdapter.command(update and "sync.write" or "sync.read",args,callback)
end
function Library.catalogPage(page,limit,callback)
    return LibraryAdapter.command("catalog.window",{page=page,limit=math.min(limit or 24,Budgets.MAX_ROWS)},callback)
end
function Library.download(key,destination,callback)
    return LibraryAdapter.command("downloads.start",{key=key,destination=destination},callback)
end

-- Explicit account actions only; credentials are dispatched and immediately released.
function Library.accountCommand(op,args,done)
    return command(op,function() return LibraryAdapter.command(op,args,done) end)
end

-- Paged source names/counts, never a catalog delivered to the editor.
function Library:sources(category, offset, limit, caps)
    return self:read("sources", {category=category,offset=offset or 0,limit=limit or 6,
        allow_lists=not (caps and caps.lists and caps.lists.read==false),
        allow_wtr=not (caps and caps.wantToRead==false),allow_device=not (caps and caps.onDevice==false)})
end

-- Position sync owns one local row and a bounded pure preview; all writes remain worker commands.
function Library.nativeReaderPosition(path) return LibraryAdapter.readerPosition(path) end
function Library.idle() if LibraryAdapter.idle then return LibraryAdapter.idle() end end
function Library.networkRestored() if LibraryAdapter.networkRestored then return LibraryAdapter.networkRestored() end end
function Library.positionCommand(op,args,done)
    return command(op,function() return LibraryAdapter.command(op,args,done or function() end) end)
end
function Library.positionCached(path)
    local finish=Budgets.span("library.position.cached",now_s,log)
    local b=Budgets.get("screens","position-consent")
    local root=require("datastorage"):getSettingsDir() .. "/orbit-cache"
    local body=Store.readFile(root .. "/position/" .. require("ffi/sha2").md5(path) .. ".lua",b.bytes+1)
    local value=type(body)=="string" and #body<=16384 and Cache.decode(body) or nil
    finish()
    return type(value)=="table" and value.path==path and value or nil
end
function Library.positionPreview(args)
    local finish=Budgets.span("library.position.preview",now_s,log)
    local encoded=Cache.encode(args); assert(#encoded<=Budgets.MAX_REQUEST,"Position preview exceeds budget")
    local result=Jni.call(Companion.AUTHORITY,Companion.PACKAGE .. ".call.SYNC_PREVIEW",{args=encoded})
    local body=result and result.body
    local value=type(body)=="string" and #body<=16384 and Cache.decode(body) or nil
    finish()
    return value
end

-- Neutral lifecycle hooks shared with the independently migrating catalog/finish adapter.
function Library.backgroundCommand(op,...)
    local args={...}
    return command(op,function() return LibraryAdapter.backgroundCommand(op,unpack(args)) end)
end
function Library.backgroundBusy()
    local finish=Budgets.span("library.background.busy",now_s,log)
    local busy=LibraryAdapter.backgroundBusy and LibraryAdapter.backgroundBusy()
    finish(); return busy
end

-- Explicit background acquisition; paints consume local references from their snapshots.
function Library.acquireCover(key,done)
    return command("covers.acquire",function()
        return LibraryAdapter.command("covers.acquire",{key=key},function(result)
            if result.local_path then LibraryAdapter.reset(); Library.changed({kind="cover"}) end
            if done then done(result) end
        end)
    end)
end

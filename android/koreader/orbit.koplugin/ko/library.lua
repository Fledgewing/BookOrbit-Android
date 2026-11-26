-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Thin 0.12 UI boundary. One host-owned context per paint; finish with :flush().
-- Neutral companion transport. Only lifecycle calls import the opaque owner; paints never
-- inspect a server plugin, credentials or protocol records. Tests may inject this interface.
if not rawget(getfenv(1),"LibraryAdapter") then
LibraryAdapter={sent={},order={},ready={}}
function LibraryAdapter.owner() return LibraryAdapter.managed_owner end
function LibraryAdapter.read(request,op)
    if op=="account.state" and LibraryAdapter.account_snapshot then
        return LibraryAdapter.account_snapshot, LibraryAdapter.account_bytes
    end
    local owner = LibraryAdapter.owner()
    if not owner then
        if op=="capabilities" and LibraryAdapter.account_snapshot then
            local result={account=LibraryAdapter.account_snapshot}
            return result,#Cache.encode(result)
        end
        return nil
    end
    local result, bytes = Store.library(owner, request)
    if op=="capabilities" and LibraryAdapter.account_snapshot then
        local merged={}
        for k,v in pairs(result or {}) do merged[k]=v end
        merged.account=LibraryAdapter.account_snapshot
        bytes=#Cache.encode(merged)
        if bytes>Budgets.MAX_SNAPSHOT then return nil end
        result=merged
    end
    LibraryAdapter.ready[owner .. request] = result ~= nil
    return result, bytes
end
function LibraryAdapter.request(requests)
    local owner = LibraryAdapter.owner()
    local problem=Companion.workerProblem()
    if not owner or problem then
        if manual and not reading() then
            UIManager:show(require("ui/widget/infomessage"):new{text=problem or _("Connect to the server and sign in to refresh the catalog.")}) -- gate: user action (explicit refresh)
        end
        return false
    end
    -- Coalesce repeat paints; misses retry sooner than already materialized windows.
    local due, now = {}, now_s()
    for _, request in ipairs(requests) do
        local key = owner .. request
        local last = LibraryAdapter.sent[key]
        if not last or now-last >= (request:find("catalog.state",1,true) and 3 or LibraryAdapter.ready[key] and 30 or 2) then
            table.insert(due, request)
            if not last then
                table.insert(LibraryAdapter.order, key)
                if #LibraryAdapter.order > 64 then
                    local old = table.remove(LibraryAdapter.order, 1)
                    LibraryAdapter.sent[old], LibraryAdapter.ready[old] = nil, nil
                end
            end
            LibraryAdapter.sent[key] = now
        end
    end
    if #due == 0 then return false end
    local batch = Cache.encode(due)
    assert(#batch <= 131072, "Library batch byte budget exceeded")
    Companion.send(Companion.ACTION.PATCH, {library_batch=batch, owner=owner})
    return true
end

function LibraryAdapter.fullRefresh() return Library.refreshCatalog("full",true) end
function LibraryAdapter.syncNow(reader) return reader:onOrbitSyncAndSleep(true) end
function LibraryAdapter.syncCurrent(done)
    return ReadingSync.run("manual",function(ok,why) done(ok,why or (ok and "Synced" or "Saved · delivery pending")) end)
end
-- KOReader already computes this on page/position updates, even with its footer hidden.
-- No document scan, sidecar read or second progress writer on a panel paint.
function LibraryAdapter.readerPosition(path)
    local ui = liveUI()
    if not (ui and ui.document and ui.document.file == path) then return nil end
    local footer = ui.view and ui.view.footer
    local fraction = footer and footer.percent_finished
    if type(fraction) == "number" and fraction == fraction and fraction >= 0 and fraction <= 1 then
        return fraction
    end
end

function LibraryAdapter.watch(enabled)
    LibraryAdapter.watching = enabled
    if enabled then LibraryAdapter.reset(); Library.watchEvents() end
end
function LibraryAdapter.changed(ev)
    if ev.owner and ev.owner ~= LibraryAdapter.owner() then return end
    if ev.kind ~= "library" then LibraryAdapter.reset() end
    Library.changed(ev)
end

function LibraryAdapter.reset() LibraryAdapter.sent, LibraryAdapter.ready, LibraryAdapter.order = {}, {}, {} end

function LibraryAdapter.openAccount()
    if Companion.workerProblem() then return false end
    local result=Jni.call(Companion.AUTHORITY,Companion.PACKAGE..".call.ACCOUNT_OPEN",{})
    return result and result.ok=="1"
end
function LibraryAdapter.accountReturned(attempt)
    if Companion.workerProblem() then return false end
    local result = Jni.call(Companion.AUTHORITY, Companion.PACKAGE .. ".call.SERVER_STATE", {reload=attempt==nil and "1" or "0"})
    if result and result.pending == "1" and (attempt or 0) < 3 then
        UIManager:scheduleIn(1, function() LibraryAdapter.accountReturned((attempt or 0)+1) end)
        return false
    end
    if not result or result.ok ~= "1" then return false end
    local body=result.body
    if type(body)=="string" and #body<=Budgets.MAX_SNAPSHOT then
        LibraryAdapter.account_snapshot=Cache.decode(body)
        LibraryAdapter.account_bytes=#body
    end
    local changed = LibraryAdapter.managed_owner ~= result.owner
    LibraryAdapter.managed_owner = result.owner
    if changed then LibraryAdapter.reset() end
    return changed
end

-- Explicit dispatched commands only; paint reads continue to use the owned SQLite windows.
function LibraryAdapter.command(op, args, callback)
    if Companion.workerProblem() then callback({error="unavailable"}); return false end
    local encoded = Cache.encode(args or {})
    assert(#encoded <= Budgets.MAX_REQUEST, "Server command exceeds budget")
    local sent = Jni.call(Companion.AUTHORITY, Companion.PACKAGE .. ".call.SERVER_COMMAND", {op=op,args=encoded})
    if not sent or sent.ok ~= "1" or not sent.id then callback({error="unavailable"}); return false end
    local deadline = now_s()+120
    local function poll()
        local result = Jni.call(Companion.AUTHORITY, Companion.PACKAGE .. ".call.SERVER_RESULT", {id=sent.id})
        local body = result and result.body
        if type(body) ~= "string" or #body > Budgets.MAX_SNAPSHOT then callback({error="unavailable"}); return end
        local decoded = Cache.decode(body)
        if type(decoded) ~= "table" then callback({error="invalid"}); return end
        if not decoded.pending then
            if decoded.state then
                LibraryAdapter.account_snapshot=decoded.state
                LibraryAdapter.account_bytes=#Cache.encode(decoded.state)
                LibraryAdapter.managed_owner=decoded.state.owner
                LibraryAdapter.reset()
            end
            callback(decoded); return
        end
        if now_s() >= deadline then callback({error="unavailable"}); return end
        UIManager:scheduleIn(0.2,poll)
    end
    UIManager:scheduleIn(0.2,poll)
    return true
end

end

Library = rawget(getfenv(1),"Library") or {}
if Library.bindLifecycle then Library.bindLifecycle() end
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
        rows, bytes = result.row_count or (result.items and #result.items or 1), decoded or 0
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
function Library:clock(twelve) return self:read("device.clock", {limit=1,twelve_hour=twelve==true}) end
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
function Library:flush(local_only)
    assert(not self.is_widget and not self.metrics.flushed, "Library host paint already flushed or missing")
    self.metrics.flushed = true
    if not local_only and #self.pending > 0 and LibraryAdapter.request(self.pending) then self.metrics.roundTrips = 1 end
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

local function storagePath()
    local ui=liveUI and liveUI()
    return ui and ui.document and ui.document.file or nil
end
function Library:storage() return self:read("storage.summary",{limit=1,exclude_path=storagePath(),current_folder=G_reader_settings:readSetting("download_dir") or G_reader_settings:readSetting("home_dir")}) end
function Library:collections(offset,limit) return self:read("collections",{offset=offset or 0,limit=limit or 6}) end
function Library.storageCommand(op,args,done)
    args.exclude_path=storagePath()
    return command(op,function() return LibraryAdapter.command(op,args,function(result)
        if op=="storage.folder" and result and not result.error and result.download_path then
            G_reader_settings:saveSetting("download_dir",result.download_path)
        end
        done(result)
    end) end)
end

-- Companion-materialized Series and grouped catalog windows, including preview row charges.
function Library:series(key, offset, limit)
    return self:read("series", {key=key,offset=offset or 0,limit=limit or 12})
end
function Library:groups(source, query, offset, limit, exclude_current, preview, group_limit)
    return self:read("groups", {source=source,query=query,offset=offset or 0,limit=limit or 8,exclude_current=exclude_current,preview=preview,group_limit=group_limit})

end

-- Settings projections reuse the companion's sleep choices and device settings owners.
function Library.refreshDevice(attempt)
    local finish=Budgets.span("library.settings-device.refresh",now_s,log)
    local result=Jni.call(Companion.AUTHORITY,Companion.PACKAGE..".call.DEVICE_SETTINGS",{})
    local body=result and result.ok=="1" and result.body
    Library.device_snapshot=type(body)=="string" and #body<=16384 and Cache.decode(body) or nil
    assert(Budgets.check(Budgets.get("screens","settings-device"),{rows=1,bytes=type(body)=="string" and #body or 0,
        spawns=0,roundTrips=1,network=0,snapshotBytes=type(body)=="string" and #body or 0}))
    if Library.device_snapshot and Library.device_snapshot.pending and (attempt or 0)<3 then
        UIManager:scheduleIn(.5,function() Library.refreshDevice((attempt or 0)+1) end)
    end
    finish()
end
function Library:deviceSettings()
    local finish=Budgets.span("library.settings-device",now_s,log)
    local device=Library.device_snapshot or {reader="Not available",sleep_label="Not available",unavailable=true}
    self.usage.rows=self.usage.rows+1; self.metrics.rows=self.metrics.rows+1
    assert(Budgets.check(self.budget,self.usage))
    assert(Budgets.check(self.screen_budget,self.metrics))
    finish(); return device
end
function Library:sleepChoices(category, offset)
    return self:read("sleep.choices", {category=category,offset=offset or 0,limit=6})
end
function Library.sleepAfter(ms, done)
    return command("device.sleep",function() return LibraryAdapter.command("device.sleep",{ms=ms},function(result)
        if result.device then Library.device_snapshot=result.device end
        done(result)
    end) end)
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

-- Cover lookup never schedules work on a paint. The thumbnail host explicitly acquires misses
-- after paint; the companion publishes the exact one-row reference on its existing writer.
function Library.cachedCover(reference)
    local paint=Library.paint("cover-cache")
    local result=paint:read("cover.reference",{reference=reference,limit=1})
    paint:flush(true)
    local path=result.local_path
    return type(path)=="string" and Store.readFile(path,1) and path or nil
end
function Library.acquireCoverReference(reference,refresh,done)
    local owner=LibraryAdapter.owner()
    return command("covers.acquire",function()
        return LibraryAdapter.command("covers.acquire",{reference=reference,refresh=refresh==true,owner=owner},function(result)
            if LibraryAdapter.owner()~=owner then
                if done then done({error="canceled"}) end
                return
            end
            if result.local_path then LibraryAdapter.reset(); Library.changed({kind="cover"}) end
            if done then done(result) end
        end)
    end)
end

-- One shared durable event reader, retained across catalog and sync cutovers. Acknowledgement
-- follows dispatch, and an unchanged durable batch never creates a second timer chain.
Library.events={}
function Library.watchEvents()
    if Library.events.watching then return end
    Library.events.watching=true
    UIManager:scheduleIn(.5,Library.pollEvents)
end
function Library.pollEvents()
    local state=Library.events
    UIManager:unschedule(Library.pollEvents)
    UIManager:scheduleIn(.5,Library.pollEvents)
    if Companion.workerProblem() or reading() then return end
    if Library.compatTick then Library.compatTick(Store.now()) end
    local encoded=Store.readFile(Store.dir().."/events-batch.lua",65537)
    if not encoded or #encoded>65536 then return end
    local batch=Cache.decode(encoded)
    if type(batch)~="table" or not batch.id then return end
    if batch.id~=state.ack then
        state.ack,state.sent_at=batch.id,nil
        local applied,err=pcall(Library.applyEvents,batch.events or {})
        if not applied then state.ack=nil;log("library events: dispatch deferred",tostring(err));return end
    end
    if not state.sent_at or now_s()-state.sent_at>=10 then
        state.sent_at=now_s()
        Companion.send(Companion.ACTION.PATCH,{reason="events",drain_events="1",events_ack=batch.id})
    end
end
function Library.applyEvents(events)
    for _,event in ipairs(events) do
        if type(event)=="table" then
            if event.kind=="library" or event.kind=="library_source" or event.kind=="account" or event.kind=="checked" or event.kind=="copies" then
                LibraryAdapter.changed(event)
            end
            if Library.compatEvent then Library.compatEvent(event) end
        end
    end
end
function Library:catalogState() return self:read("catalog.state",{limit=1}) end
function Library.catalogSnapshot()
    local paint=Library.paint("catalog-refresh")
    local result=paint:catalogState(); paint:flush(true)
    return result
end
function Library.refreshCatalog(action,manual)
    local owner=LibraryAdapter.owner()
    local problem=Companion.workerProblem()
    if not owner or problem then
        if manual and not reading() then
            UIManager:show(require("ui/widget/infomessage"):new{text=problem or _("Connect to the server and sign in to refresh the catalog.")}) -- gate: user action (explicit refresh)
        end
        return false
    end
    local generation={}
    if Library.catalog_active and Library.catalog_owner==owner and (not manual or Library.catalog_requested=="full" and (action=="full" or action=="refresh")) then
        if manual and Badge.running then Badge.expand() end
        return true
    end
    Library.catalog_owner=owner
    Library.catalog_requested=action
    Library.catalog_generation=generation
    Library.catalog_active=true
    Wifi.acquire("mirror")
    local finished=false
    local deadline=now_s()+120
    local function finish()
        if finished then return end
        finished=true
        Library.catalog_active=nil
        Wifi.release("mirror")
    end
    local function accept(result)
        if Library.catalog_generation~=generation then return end
        if LibraryAdapter.owner()~=owner or result.error then finish(); return end
        Library.catalog_status=result
        if manual and action=="full" and Library.catalogStarted then Library.catalogStarted() end
        if manual and action=="full" and not Badge.running and not reading() then Badge.start(true,result) end
        local function poll()
            if Library.catalog_generation~=generation then return end
            if LibraryAdapter.owner()~=owner then finish(); return end
            local status=Library.catalogSnapshot()
            if now_s()>=deadline and (status.pending or result.run and status.run~=result.run) then
                finish()
                if Badge.running and not reading() then Badge.finish(_("Paused · it goes on when the server answers")) end
                return
            end
            if not status.pending and (not result.run or status.run==result.run) then
                Library.catalog_status=status
                if Badge.running and not reading() then Badge.update(status) end
                local stale=status.beat and Store.now()-status.beat>=90
                if status.running~=true or stale then
                    finish()
                    if Badge.running and not reading() then Badge.finish((stale or status.why and status.why~="finished") and _("Paused · it goes on when the server answers") or nil,status) end
                    LibraryAdapter.reset()
                    Library.changed({kind="catalog",owner=owner})
                    if Library.catalogFinished then Library.catalogFinished(status) end
                    return
                end
            end
            UIManager:scheduleIn(3,poll)
        end
        UIManager:scheduleIn(3,poll)
    end
    local started=command("catalog.control",function()
        return LibraryAdapter.command("catalog.control",{owner=owner,action=action,manual=manual==true},accept)
    end)
    if not started then finish() end
    return started
end

if OrbitAndroid then
    local init=OrbitAndroid.init
    function OrbitAndroid:init(...)
        local result=init(self,...)
        if Library.connectorReady then Library.connectorReady() end
        Library.accountReturned()
        Library.watchEvents()
        return result
    end
end

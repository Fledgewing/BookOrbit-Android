-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- The BookOrbit plugin
---------------------------------------------------------------------------------------------

-- The reader or file browser on screen now. Flows outlive the module that started them
-- (a book can close mid-flow), so they look the UI up again when they need it.
function liveUI()
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance then return ReaderUI.instance end
    return require("apps/filemanager/filemanager").instance
end

compat_seen = setmetatable({}, { __mode = "k" })
compat_logged = {}
EOB=setmetatable({}, {__index=function(_,key) return FinishUI and FinishUI[key] end}) -- lifecycle bridge until library initialization

-- The plugin's version (main.lua:54/95: BookOrbit.PLUGIN_VERSION; _meta.lua has none).
function pluginVersion(p)
    local okv, v = pcall(function() return p.PLUGIN_VERSION end)
    return (okv and type(v) == "string") and v or "unknown"
end

-- Unavailable features for this plugin instance, logged once per feature. Only a full pass is
-- cached (per live instance): a check that finds something missing, e.g. one made before the
-- plugin finished init, is made again next time.
function compatOf(p)
    if not p then return {} end
    local m = compat_seen[p]
    if m then return m end
    m = Compat.check(p)
    if next(m) == nil then compat_seen[p] = m end
    for id, missing in pairs(m) do
        if not compat_logged[id] then
            compat_logged[id] = true
            log("compat:", id, "unavailable (plugin " .. pluginVersion(p) .. "): missing",
                table.concat(missing, ", "), "->", Compat.fallback(id))
        end
    end
    return m
end

-- Can the patch use this plugin feature?
function can(p, id)
    return p ~= nil and compatOf(p)[id] == nil
end

function serverPlugin(ui)
    ui = liveUI() or ui
    local p = ui and ui.bookorbit
    if not p then
        local ok, inst = pcall(PluginLoader.getPluginInstance, PluginLoader, "bookorbit")
        p = ok and inst or nil
    end
    -- Without isLoggedIn/settings nothing else is safe: behave as without the plugin.
    if p and not can(p, "core") then return nil end
    if Server and Server.installCovers then Server.installCovers(Server.loaded("api"),Server.loaded("catalog")) end
    return p
end

-- Status lines for the menu and Test sync path; {} when the plugin is fully supported.
function compatLines(p)
    if not p then return {} end
    return Compat.lines(compatOf(p), pluginVersion(p))
end

function inBook()
    local ui = liveUI()
    return ui ~= nil and ui.document ~= nil
end

function serverUrl(p)
    local settings = p and p.settings or G_reader_settings:readSetting("bookorbit")
    return settings and settings.server_url or nil
end

-- Any HTTP status from the base URL counts: it proves the route and the server, with no login.
-- Blocking primitive: only called by Net.up's background child. Socket timeouts
-- do not bound DNS resolution; Background.run also caps the child's lifetime.
function probeServer(url, timeout)
    local http = require("socket.http")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local ltn12 = require("ltn12")
    timeout = math.min(1.5, timeout)
    socketutil:set_timeout(timeout, timeout)
    local code = socket.skip(1, http.request{ url = url, method = "HEAD", sink = ltn12.sink.null() })
    socketutil:reset_timeout()
    return type(code) == "number", code
end

---------------------------------------------------------------------------------------------

-- One compatibility entry point. Only main.lua loads this implementation.
Server = {}
Server.events = { home = "BookOrbitOpenDashboard", sync = "BookOrbitSyncBook", auto = "BookOrbitToggleAutoSync" }
function Server.loaded(name) return package.loaded["bookorbit_" .. name] end
function Server.require(name) return require("bookorbit_" .. name) end
function Server.ownsView(name) return type(name) == "string" and name:find("^bookorbit") ~= nil end
function Server.notice(w) return w and w.name == "bookorbit_toast" end
function Server.credentials(client, extras)
    extras.server, extras.user, extras.userkey = client.server_url, client.username, client.userkey
    return extras
end

function Server.signedIn(p) return p ~= nil and p:isLoggedIn() end
function Server.openLogin(p) return p:promptLogin() end
function Server.drain(p, ...) return p:requestLifecycleOutboxDrain(...) end
function Server.pull(p, reason) return p:requestProgressPull(false, false, reason) end
function Server.snapshot(p) return pcall(p._onSuspend, p) end
function Server.syncBusy(p)
    local c = p:getSyncCoordinator()
    if c:isBusy() or c:queuedCount() > 0 then return true end
    return outboxPending(p:getLifecycleOutbox():diagnostics()) > 0
end
function Server.testReady(p)
    return hasHandler(p, Server.events.sync) and Compat.callable(p.startSweep) and Compat.callable(p.errorLabel)
end
function Server.testError(p, err) return p:errorLabel(err) end
function Server.testSync(p, reader, done)
    if reader then pluginEvent(liveUI(), p, Server.events.sync, {quiet=true, on_done=done})
    else p:startSweep({quiet=true, on_progress=function() end, on_done=done}) end
end

-- Legacy service bridge. Only reviewed lifecycle/sheet modules use this facade.
function Server.cacheClient() return OC.client() end
function Server.watchCache() return OC.watchChecks() end
function Server.cacheBusy() if OC and OC.busy then return OC.busy() end end
function Server.refreshLibrary(...) return OC.menuFullRefresh(...) end
function Server.resumeCache(...) if Mirror and Mirror.kick then return Mirror.kick(...) end end
function Server.fullRefreshNotice() return Mirror and (Mirror.notices or Mirror.fullRunning()) end
function Server.installGrouping(...) return Server.installGroupViews(...) end
function Server.positionOn() return OSM and OSM.on() end
function Server.positionWakeMinimum() return OSM.WAKE_MIN_S end
function Server.pullThenDrain(...) return OSM.pullThenDrain(...) end
function Server.readFromHere(...) return OSM.readFromHere(...) end
function Server.waitOutbox(...) return Sync.waitOutbox(...) end
function Server.clearPullDebounce(...) return Sync.clearPullDebounce(...) end
function Server.countStorage(...) if OC and OC.storageCount then return OC.storageCount(...) end end
function Server.refreshCovers(...) if Mirror and Mirror.coverPass then return Mirror.coverPass(...) end end
function Server.positionModeChanged(...) if OSM and OSM.modeChanged then return OSM.modeChanged(...) end end
function Server.reportRecommended(...) if Recommendations then return Recommendations.report(...) end end
function Server.applyRecommended(...) if Recommendations then return Recommendations.applyChoices(...) end end
function Server.capabilitiesLost(...) if Recommendations then return Recommendations.pass("caps lost",nil,true) end end
function Server.capabilitiesGained(...) if Recommendations then return Recommendations.pass("capabilities gained") end end
function Server.endSheetOpen() return FinishUI and FinishUI.sheet~=nil end
function Server.leaveEndSheet(...) return FinishUI and FinishUI.leaveForHome(...) end
function Server.endAction(name,...) return Library.endAction(name,...) end
function Server.localBookId(path)
    local cat=Mirror and Mirror.catalog and Mirror.catalog()
    if not (path and cat and type(cat.on_device)=="table") then return nil end
    for id,p in pairs(cat.on_device) do if p==path then return tonumber(id) end end
end
function Server.quietLegacy(quiet)
    quiet(OC,{"watchChecks","applyEvents","landed","redraw_soon","redraw","storageCount","storageCounted","rechecked"})
    quiet(Mirror,{"tick","kick","poll","ran","finish","coverPass"})
    quiet(LF,{"quiet","paintTiles","quietSwitch"})
    quiet(OSM,{"pause","pullThenDrain"})
end
function Server.timeLegacy(wrap)
    for _,name in ipairs({"OSM","OC","LF","Sync","Mirror"}) do
        wrap(getfenv(1)[name],name)
    end
end

-- Covers have one owner even with legacy catalog caching disabled. Never call the upstream
-- downloader: these low-level methods can be reached inside an upstream subprocess.
function Server.installCovers(Api,Catalog)
    if type(Api)~="table" then return false end
    if not Api._booksync_covers then
        Api._booksync_covers=true
        for _,name in ipairs({"downloadCatalogThumbnail","downloadCatalogAuthorPhoto"}) do
            Api[name]=function(_,_,path)
                return Library.cachedCover(path) and true or nil,"companion-owned"
            end
        end
    end
    if type(Catalog)~="table" then return false end
    if Catalog._booksync_covers then return true end
    Catalog._booksync_covers=true
    -- The upstream batch entry point no longer forks. Its timer calls this parent-side
    -- asynchronous worker instead; a direct legacy call can only inspect local snapshots.
    Catalog.downloadThumbnailBatch=function(self,batch)
        local result={}
        for _,book in ipairs(batch or {}) do
            local entry=self:thumbnailEntry(book)
            if entry then result[entry.reference:match("([^/]+)%.jpg$")]=entry.exists end
        end
        return result
    end
    local entry=Catalog.thumbnailEntry
    if type(entry)=="function" then
        Catalog.thumbnailEntry=function(self,book)
            local row=entry(self,book)
            if row then
                row.reference=row.reference or row.path
                local path=Library.cachedCover(row.reference)
                row.path,row.exists=path or row.reference,path~=nil
            end
            return row
        end
    end
    Catalog.runThumbnailWorker=function(self,generation)
        local function valid() return not self.catalog_closed and self.thumbnail_generation==generation end
        if not valid() then return self:stopThumbnailWorker(generation) end
        local visible=true
        local books=CoverQueue.take(self.thumbnail_queue)
        if #books==0 then visible=false; books=CoverQueue.take(self.thumbnail_prefetch_queue) end
        if #books==0 then self:stopThumbnailWorker(generation); return end
        local rows={}
        for _,book in ipairs(books) do
            local row=self:thumbnailEntry(book)
            if row then rows[#rows+1]={reference=row.reference,entry=row,key=row.reference:match("([^/]+)%.jpg$")} end
        end
        local written=false
        CoverQueue.acquire(rows,false,valid,function(row,result)
            if result.local_path then
                row.entry.path,row.entry.exists=result.local_path,true
                written=true
                if self.thumbnail_failures then self.thumbnail_failures[row.key]=nil end
            elseif self.thumbnail_failures then self.thumbnail_failures[row.key]=true end
        end,function(ok)
            if not ok then return self:stopThumbnailWorker(generation) end
            if visible and written and not reading() and valid() then self:updateItems(nil,true) end
            UIManager:scheduleIn(0.05,function() self:runThumbnailWorker(generation) end)
        end)
    end
    -- These old maintenance paths enumerate/delete files. The companion owns storage policy.
    for _,name in ipairs({"sweepThumbnailTemp","cleanLegacyThumbnails","maybePruneThumbnailCache","pruneThumbnailCache"}) do
        Catalog[name]=function() end
    end
    return true
end

-- Transitional lifecycle contracts used by the parallel sync/copies cutovers. All catalog
-- transport and projection work is companion-owned; these never read upstream replies.
OC={now=os.time}
function OC.dir() return OC._dir or Store.defaultDirectory() end
-- Existing test/diagnostic directory providers remain supported.

function OC.readFile(...) return Store.readFile(...) end
function OC.writeFile(...) return Store.writeFile(...) end
function OC.on() return S.offline_cache~=false end
function OC.owner(value) return tostring(value.username or "").."|"..tostring(value.server_url or ""):lower() end
function OC.client()
    local p=serverPlugin(liveUI())
    if p and p.catalog_browser and p.catalog_browser.client then return p.catalog_browser.client end
    return p and Compat.callable(p.newClient) and p:newClient() or nil
end
function OC.watchChecks() return Library.watchEvents() end
function OC.drainEvents() return Library.pollEvents() end
function OC.applyEvents(events) return Library.applyEvents(events) end
function OC.busy() return Library.catalog_active and "saving the catalog for offline" or nil end
function OC.refresh() return Library.refreshCatalog("refresh",true) end
function OC.fullRefresh() return Library.fullRefresh() end
function OC.menuFullRefresh() return Library.fullRefresh() end
function OC.storageCount(why)
    local now=Store.now()
    if why=="over the limit" and OC.storage_last and now-OC.storage_last<60 then return end
    if OC.storage_asked and now-OC.storage_asked<60 then OC.storage_again=why;return end
    if not Companion.workerProblem() then
        OC.storage_asked,OC.storage_last=now,now Companion.send(Companion.ACTION.STORAGE,{reason=tostring(why),
        limit=tostring((tonumber(S.storage_limit_mb) or 512)*1048576),mirror_covers=S.mirror_covers and "1" or "0"}) end
    OC.watchChecks()
end
function OC.storageCounted(event)
    OC.storage=event.totals;OC.storage_asked=nil
    local again=OC.storage_again;OC.storage_again=nil
    if again and again~="over the limit" then OC.storageCount(again) end
end
function OC.storageTotals() return OC.storage end
function OC.storageText() return string.format("Using %.1f MB",((OC.storage or {}).used or 0)/1048576) end
function OC.install()
    local api,cat=Server.loaded("api"),Server.loaded("catalog")
    Server.installCovers(api,cat)
    OC.installed=Server.installCatalogApi(api,cat)
    return OC.installed
end
Mirror={SENTINEL="987654321"}
function Mirror.catalog()
    local p=serverPlugin(liveUI())
    return p and p.catalog_browser or Mirror.cat
end
function Mirror.status() return Library.catalog_status or {} end
function Mirror.fullRunning() return Library.catalog_active==true end
function Mirror.running() return Library.catalog_active==true end
function Mirror.savedText() return Companion.workerProblem() or Mirror.status().saved_label or _("Not saved for offline yet") end
function Mirror.coverPass() return Library.refreshCatalog("covers",false) end
function Mirror.tick(why)
    if not reading() and NetworkMgr:isConnected() then return Library.refreshCatalog("incremental",false) end
end
function Mirror.kick(why)
    if Sleep and Sleep.kick then Sleep.kick(why) end
    if Library and Library.copiesTick then pcall(Library.copiesTick,why) end
    UIManager:scheduleIn(1,function() Mirror.tick(why) end)
end
-- The parent explicitly revalidates the visible local references through the library.
-- Only the companion owns conditional image transport and publication.
OC.RECHECK_WAIT_S = 120
function OC.recheckCovers(cat, jobs)
    local generation=cat.thumbnail_generation
    local rows={}
    for _,job in ipairs(jobs) do rows[#rows+1]={reference=job.path} end
    local index=1
    local changed=0
    local function nextBatch()
        if cat.catalog_closed or cat.thumbnail_generation~=generation then return end
        local batch={}
        for _=1,CoverQueue.MAX_BATCH do
            if rows[index] then batch[#batch+1]=rows[index]; index=index+1 end
        end
        if #batch==0 then return OC.rechecked({checked=#jobs,changed=changed>0 and {true} or {}}) end
        CoverQueue.acquire(batch,true,function() return not cat.catalog_closed and cat.thumbnail_generation==generation end,
            function(_,result) if result.local_path then changed=changed+1 end end,function(ok) if ok then nextBatch() end end)
    end
    OC.recheck={at=Store.now(),cat=cat,n=#jobs}
    nextBatch()
end

function OC.rechecked(ev)
    local r = OC.recheck
    OC.recheck = nil
    if not r then return end
    if ev.err then log("cache: covers not re-asked:", tostring(ev.err)) end
    local changed = type(ev.changed) == "table" and ev.changed or {}
    log("cache: covers re-asked:", tonumber(ev.checked) or 0, "checked,", #changed, "replaced")
    local cat = r.cat
    if #changed > 0 and cat and not cat.catalog_closed and not reading() then
        if Compat.callable(cat.resetThumbnailMemo) then cat:resetThumbnailMemo() end
        if Compat.callable(cat.updateItems) then cat:updateItems(nil, true) end
    end
end


function Server.installCatalogRuntime()
    Store.directory=OC.dir
    Server.bindCatalogActions()
    Library.compatTick=function(t)
        if OC.storage_asked and t-OC.storage_asked>=60 then OC.storage_asked=nil end
        if LF and LF.year_waiting and t-LF.year_waiting>60 then LF.year_waiting=nil end
        if Sleep and Sleep.waited then Sleep.waited(t) end
    end
    Library.compatEvent=function(ev)
        if ev.kind=="library" or ev.kind=="library_source" or ev.kind=="account" then Server.catalogChanged(ev) end
    if ev.kind == "board_year" and LF then
                LF.yearLanded(ev)
    elseif ev.kind == "native_footer_repair" then
                -- G_reader_settings is already loaded. Correct its matching scalar
                -- too, or KOReader's next native flush would undo the disk repair.
                -- This does not touch an open ReaderFooter or reflow the document.
        if type(ev.token) == "string" and S.native_footer_repair ~= ev.token then
                    local function scalar(text)
                if text == "nil" then return nil, true end
                        local n = tonumber(text)
                        return n, n ~= nil and n == n and n ~= math.huge and n ~= -math.huge
                    end
                    local before, valid_before = scalar(ev.before)
                    local after, valid_after = scalar(ev.after)
            if valid_before and valid_after then
                if G_reader_settings:readSetting("reader_footer_mode") == before then
                            G_reader_settings:saveSetting("reader_footer_mode", after)
                            log("status repair: native global footer mode " .. tostring(before) .. "->" .. tostring(after))
                        end
                        S.native_footer_repair = ev.token
                        saveSettings()
                    end
                end
    elseif ev.kind == "storage" then
                OC.storageCounted(ev)
    elseif ev.kind == "sleep_pool" and Sleep then
                Sleep.landed(ev)
    elseif ev.kind=="copy.identity" or ev.kind=="finish.applied" or ev.kind=="download.saved" then
                Server.applyCatalogEvent(ev)
    end
    end
    Library.catalogStarted=function()
        local p=serverPlugin(liveUI())
        local cat=p and p.catalog_browser
        if not cat or cat.catalog_closed or reading() or not catalogOnTop(p) then return end
        local context=cat.current_context or {}
        local books=context.books or {}
        if context.kind=="dashboard" and Compat.callable(cat.dashboardBooks) then books=cat.dashboardBooks(context.dashboard) end
        if context.kind=="detail" and Compat.callable(cat.detailThumbnailBooks) then books=cat:detailThumbnailBooks(context.detail) end
        local generation=cat.thumbnail_generation
        UIManager:nextTick(function()
            if cat.catalog_closed or cat.thumbnail_generation~=generation or reading() or not catalogOnTop(p) then return end
            local jobs={}
            for i=1,math.min(24,#books) do
                local book=books[i]
                if book.hasCover~=false and Compat.callable(cat.thumbnailPath) then
                    local path=cat:thumbnailPath(book)
                    if path then jobs[#jobs+1]={path=path} end
                end
            end
            if #jobs>0 then OC.recheckCovers(cat,jobs) end
        end)
    end
    Library.catalogFinished=function(status)
        Server.catalogChanged({owner=LibraryAdapter.owner()})
        if Library.copiesTick then pcall(Library.copiesTick,"catalog refresh") end
    end
    LibraryAdapter.syncCurrent=Server.syncCurrent
    Library.watchEvents()
end
function Server.syncCurrent(done)
    local ui = liveUI()
    local p = serverPlugin(ui)
    if not (p and ui and ui.document and hasHandler(p, "BookOrbitSyncBook")) then
        done(false, "Sync unavailable")
        return false
    end
    local document = ui.document
    Wifi.acquire("reader-panel")
    Net.up(p, {reason="reader-panel", cap=20, need_server=true}, function(ok)
        if not ok then
            Wifi.release("reader-panel")
            done(false, "Offline · will sync when connected")
            return
        end
        if liveUI() ~= ui or ui.document ~= document then
            Wifi.release("reader-panel")
            done(false, "Book closed · your place stays saved")
            return
        end
        local completed = false
        local function finish(err)
            if completed then return end
            completed = true
            Wifi.release("reader-panel")
            done(err == nil, err and "Sync failed · your place stays saved" or "Synced")
        end
        pluginEvent(ui, p, "BookOrbitSyncBook", {quiet=true, on_done=finish})
        UIManager:scheduleIn(30, function() finish("timeout") end)
    end)
    return true
end


-- Compatibility shapes are assembled from BookSync display records, never HTTP/JSON. The
-- remaining copies/EOB slice still uses native identifiers; catalog queries are worker-owned.
function Server.installCatalogApi(Api,Catalog)
    if not Library or type(Api)~="table" then return false end
    if #Compat.missingOn(Api,{request="function",requestBlocking="function",runInSubprocess="function",query="function"})>0 then return false end
    if not Library.compatEvent then Server.installCatalogRuntime() end
    if not Api._booksync_catalog then
        Api._booksync_catalog=true
        local function row(book)
            local files={}
            for _,f in ipairs(book.files or {}) do files[#files+1]={id=f.reference,format=f.format,size=f.bytes,
                md5=f.digest,fileHash=f.digest,sizeBytes=f.bytes,contentVersion=f.revision,role=f.role,filename=f.filename,
                downloadVariant=f.delivery,requestedVariant=f.requested_delivery,devicePath=f.local_path} end
            return {id=book.reference,title=book.title,authors=book.authors,seriesName=(book.series or {})[1],
                seriesId=book.series_reference,seriesIndex=book.series_position,readStatus=book.status_raw,
                progressPercentage=book.progress,lastReadAt=book.last_read,updatedAt=book.cover_revision,
                hasCover=book.cover_available,rating=book.rating,pageCount=book.pages,formats=book.formats,
                description=book.description,files=files}
        end
        Server.catalogRow=row
        local function read(view,params,extra)
            params=params or {}
            local limit=math.max(1,math.min(24,tonumber(params.size) or 24))
            local names={libraryId="library",collectionId="collection",smartScopeId="list",seriesId="series",
                series="series_name",author="author",format="format",readStatus="status",ids="ids",q="search",order="direction",filter="section_filter"}
            local selection={}
            for field,name in pairs(names) do if params[field]~=nil then selection[name]=tostring(params[field]) end end
            if params.sort then selection.sort=({recently_added="added",recently_updated="updated",recently_read="last"})[params.sort] or params.sort end
            local args={view=view,selection=selection,offset=tonumber(params.offset) or math.max(0,(tonumber(params.page) or 1)-1)*limit,limit=limit}
            for k,v in pairs(extra or {}) do args[k]=v end
            local paint=Library.paint("library")
            local result=paint:read("connector.catalog",args); paint:flush()
            if result.pending or result.error then return nil,"cancelled" end
            local items={}
            for _,item in ipairs(result.items or {}) do items[#items+1]=view=="index" and
                {id=item.reference,title=item.title,name=item.title,bookCount=item.count,count=item.count,seriesId=item.series_reference,
                 readingCount=item.reading,finishedCount=item.finished} or row(item) end
            if view=="book" then return items[1],items[1] and nil or "cancelled" end
            return {items=items,total=result.total,page=tonumber(params.page) or 1,size=limit,offset=args.offset,hasNext=result.more,hasPrevious=args.offset>0}
        end
        Api.catalogBooks=function(_,params) return read("books",params) end
        Api.catalogRoot=function()
            local paint=Library.paint("library")
            local snapshot=paint:read("connector.root",{limit=24});paint:flush()
            if snapshot.pending or snapshot.error then return nil,"cancelled" end
            local sections={}
            for _,category in ipairs(snapshot.items or {}) do sections[#sections+1]={section=category.kind=="lists" and "smart-scopes" or category.kind,title=category.title,count=category.count} end
            return {sections=sections}
        end
        Api.catalogBook=function(_,id) return read("book",{size=1},{reference=id}) end
        Api.catalogSection=function(_,category,params)
            return read("index",params,{category=category=="smart-scopes" and "lists" or category})
        end
        -- The owned Home supplies these surfaces. Opening a native Home redirects to its host;
        -- no native dashboard/root request is permitted to fall back to upstream transport.
        for _,name in ipairs({"catalogDashboard","catalogDiscover","catalogDashboardSection","catalogManifest"}) do
            Api[name]=function() return nil,"cancelled" end
        end
        -- A legacy Catalog.fetch closure can only use local catalog reads. Prevent another
        -- operation in that closure from performing transport synchronously on the UI thread.
        if Compat.callable(Api.download) then
            wrap(Api,"download",function(stock) return function(self,...)
                if Server.catalog_paint then return nil,"cancelled" end
                return stock(self,...)
            end end,"catalog-local")
        end
        if Compat.callable(Api.request) then
            wrap(Api,"request",function(stock) return function(self,...)
                if Server.catalog_paint then return nil,"cancelled" end
                return stock(self,...)
            end end,"catalog-local")
        end
    end
    if type(Catalog)=="table" and not Catalog._booksync_catalog then
        Catalog._booksync_catalog=true
        if Compat.callable(Catalog.initialDashboardContext) then
            wrap(Catalog,"initialDashboardContext",function(stock) return function(self,...)
                local before=Library.catalog_opening;Library.catalog_opening=true
                local result={pcall(function(...)
                    if LF and LF.primeOnDevice then LF.primeOnDevice(self) end
                    return stock(self,...)
                end,...)}
                Library.catalog_opening=before
                if not result[1] then error(result[2],0) end
                return unpack(result,2)

            end end,"catalog-local")
        end
        if Compat.callable(Catalog.runConnected) then
            wrap(Catalog,"runConnected",function(stock) return function(self,fn)
                if NetworkMgr:isConnected() then return stock(self,fn) end
                local before=Server.catalog_paint;Server.catalog_paint=true
                local result={pcall(fn)}
                Server.catalog_paint=before
                if not result[1] then error(result[2],0) end
                return unpack(result,2)
            end end,"catalog-local")
        end
        if Compat.callable(Catalog.fetch) then
            Catalog.fetch=function(_,_,fn)
                local previous=Server.catalog_paint; Server.catalog_paint=true
                local ok,a,b,c=pcall(fn)
                Server.catalog_paint=previous
                if not ok then error(a,0) end
                return a,b,c
            end
        end
        if Compat.callable(Catalog.dashboardRootFetch) then
            Catalog.dashboardRootFetch=function(self)
                local sources,names={},{}
                if Compat.callable(self.boardSources) then sources,names=self:boardSources() end
                local shelves,labels={},{}
                for slot,props in pairs(sources) do
                    if #shelves<6 then
                        local params=props.params or {}
                        local select={}
                        local fields={libraryId="library",collectionId="collection",smartScopeId="list",seriesId="series",series="series_name",author="author"}
                        for field,target in pairs(fields) do if params[field] then select[target]=tostring(params[field]) end end
                        local source=props.source or slot
                        if source=="in-progress" or source=="pick-back-up" then select.status,select.sort="reading","last"
                        elseif source=="finished" then select.status,select.sort="finished","last"
                        elseif source=="recently-added" then select.sort="added"
                        elseif source=="want-to-read" then select.status="want_to_read"
                        else select.sort="title" end
                        if source=="pick-back-up" then select.direction="asc" end
                        shelves[#shelves+1]={slot=slot,selection=select}
                    end
                end
                for name in pairs(names) do if #labels<2 then labels[#labels+1]=name=="scopes" and "lists" or name end end
                local paint=Library.paint("home")
                local snapshot=paint:read("connector.home",{shelves=shelves,names=labels,limit=24});paint:flush()
                if snapshot.pending or snapshot.error then return self:dashboardContext(nil,{stale=true,unavailable=true}) end
                local body={boardShelves={},boardNames={},continueReading={},finishedThisYear={},discover={},
                    displayName=snapshot.greeting,username=snapshot.account_label,totalBooks=snapshot.total,bookCount=snapshot.total}
                for slot,items in pairs(snapshot.shelves or {}) do
                    local books={}
                    for _,book in ipairs(items) do books[#books+1]=Server.catalogRow(book) end
                    body.boardShelves[slot]=books
                    if slot=="in-progress" then body.continueReading=books end
                    if slot=="finished" then body.finishedThisYear=books end
                    if slot=="random" then body.discover=books end
                end
                for category,titles in pairs(snapshot.names or {}) do body.boardNames[category=="lists" and "scopes" or category]=titles end
                local goal,streak,activity=snapshot.goal or {},snapshot.streak or {},snapshot.activity or {}
                body.readingGoal={year=goal.year,goalBooks=goal.target,completedBooks=goal.completed}
                body.readingStreak={currentStreak=streak.current,longestStreak=streak.best}
                body.readingYear={startDate=activity.start_date,minutes=activity.minutes}
                return self:dashboardContext(body,{stale=not (snapshot.freshness and snapshot.freshness.saved)})
            end
        end

    end
    return true
end

Library={connectorReady=function() Server.installCatalogRuntime(); OC.install() end}

function Server.catalogChanged(event)
    local p=serverPlugin(liveUI())
    local cat=p and p.catalog_browser
    if not cat or cat.catalog_closed or reading() or not catalogOnTop(p) or cat._booksync_redraw then return end
    local context=cat.current_context
    cat._booksync_redraw=true
    UIManager:scheduleIn(.3,function()
        cat._booksync_redraw=nil
        if cat.catalog_closed or cat.current_context~=context or reading() or not catalogOnTop(p) then return end
        if event.owner and event.owner~=LibraryAdapter.owner() then return end
        if LF and Compat.callable(cat.refreshCurrent) then LF.refreshKeepingCovers(cat) end
    end)
end

-- Minimal native binding. UI and shared lifecycle hooks call the neutral Library/FinishUI.
function Server.installGroupViews()
    local cat=Server.loaded("catalog")
    if type(cat)~="table" or not Compat.callable(cat.listSortSheetModel) or not Compat.callable(cat.listRun) then return false end
    wrap(cat,"listSortSheetModel",function(stock) return function(self,sheet)
        local m=stock(self,sheet)
        if m and m.rows and self:listKind()=="books" then
            table.insert(m.rows,1,{label="By author",action={kind="booksync-group",group="author"}})
            table.insert(m.rows,1,{label="By series",action={kind="booksync-group",group="series"}})
        end
        return m
    end end,"owned-groups")
    wrap(cat,"listRun",function(stock) return function(self,action,region,hold)
        if not hold and type(action)=="table" and action.kind=="booksync-group" then
            local context=self.current_context or {};local p=context.params or {}
            local names={libraryId="library",collectionId="collection",smartScopeId="list",seriesId="series",author="author",ids="ids",q="search",readStatus="status",format="format",sort="sort",order="direction"}
            local selection={};for k,n in pairs(names) do if p[k]~=nil then selection[n]=tostring(p[k]) end end
            Library.openGrouped(context.title or "Library",{kind="selection",selection=selection},{group=action.group})
            return true
        end
        return stock(self,action,region,hold)
    end end,"owned-groups")
    return true
end

function Server.bindCatalogActions()
    EOB=FinishUI -- temporary compatibility for F12-Q's lifecycle/push holds; no second outbox
    Library.nativeReader=function(ui)
        local p=ui and ui.bookorbit
        if not (p and ui.document and ui.doc_settings) then return end
        local ok,digest=pcall(p.getDocumentDigest,p);if not ok or type(digest)~="string" then return end
        local state=Server.loaded("state_manager")
        local b=state and state.getBook and state.getBook(digest)
        local pct=LibraryAdapter.readerPosition(ui.document.file)
        return {digest=digest,file=ui.document.file,key=b and b.bookId and true,book_id=b and b.bookId,
            percentage=pct,summary=ui.doc_settings:readSetting("summary") or {},doc_settings=ui.doc_settings,plugin=p}
    end
    Library.noteReaderMark=function(b) if LocalState then LocalState.noteMark(b,b.summary.status) end end
    Library.noteReaderLeave=function(b)
        if LocalState then LocalState.put(b.digest,{pending=true,bookId=b.book_id,percent=b.percentage and b.percentage*100,status=b.summary.status}) end
        if LF and LF.noteOnDevice then LF.noteOnDevice(b.book_id,b.file) end
    end
    Library.observeSetting=function(item)
        local p=serverPlugin(liveUI())
        if not p then return {available=false,reason="Connector unavailable"} end
        local defaults=p.default_settings or {}
        local current=p.settings[item.key]
        if OSM and OSM.savedPluginSetting then current=OSM.savedPluginSetting(item.key,current) end
        return {available=true,current=current,default=defaults[item.key]}
    end
    Library.writeSetting=function(item,value)
        local p=serverPlugin(liveUI());if not p then return false end
        if OSM and OSM.setSavedPluginSetting and OSM.setSavedPluginSetting(item.key,value) then G_reader_settings:flush();return true end
        if item.key=="auto_sync" then
            if (p.settings.auto_sync==true)~=(value==true) then pluginEvent(liveUI(),p,Server.events.auto,value==true,true,true) end
        else p.settings[item.key]=value end
        G_reader_settings:flush();return true
    end
    Library.installFinishHooks=function(p)
        local cls=getmetatable(p) and getmetatable(p).__index
        if type(cls)~="table" then return end
        if Compat.callable(cls.enqueueLifecycleSnapshot) then wrap(cls,"enqueueLifecycleSnapshot",function(stock) return function(self,snap,reason)
            if type(snap)=="table" and FinishUI.hold(snap.digest,snap.percentage,snap.status) then snap.percentage,snap.progress=nil,nil end
            if LocalState and type(snap)=="table" then pcall(LocalState.noteSnapshot,snap) end
            return stock(self,snap,reason)
        end end,"finish") end
        for _,name in ipairs({"updateProgress","pushProgressAfterBookSync"}) do
            if Compat.callable(cls[name]) then wrap(cls,name,function(stock) return function(self,...)
                local ui=self.ui;local digest=ui and FinishUI.page_digests[ui] and FinishUI.page_digests[ui].digest
                local summary=ui and ui.doc_settings and ui.doc_settings:readSetting("summary") or {}
                if digest and FinishUI.hold(digest,LibraryAdapter.readerPosition(ui.document.file),summary.status) then return end
                return stock(self,...)
            end end,"finish") end
        end
    end
    local stock=Sync.waitOutbox
    if not Server.finish_wait_bound then
        Server.finish_wait_bound=true
        Sync.waitOutbox=function(p,cap,done) return stock(p,cap,function(ok,why,elapsed)
            if not ok then return done(ok,why,elapsed) end
            FinishUI.drain(p,false,function() done(ok,why,elapsed) end)
        end) end
    end
end
function Server.applyCatalogEvent(ev)
    if ev.owner~=LibraryAdapter.owner() then return end
    local sm=Server.loaded("state_manager")
    if ev.kind=="copy.identity" and sm and sm.repairFileIdentity then
        sm.repairFileIdentity(ev.path,ev.before,ev.after)
        Library.catalogAction("copies.ack",{token=ev.token})
    elseif ev.kind=="download.saved" and sm and sm.linkFile then
        sm.linkFile(ev.document,ev.file_reference,ev.reference,ev.path)
        if ev.deferred then Gate.show("downloaded book",function()
            UIManager:show(require("ui/widget/infomessage"):new{text="Downloaded: "..tostring(ev.title or "Book"),timeout=3}) -- gate: Gate.show
        end) end
    elseif ev.kind=="finish.applied" then
        local epoch=FinishUI.intent[ev.document] or 0
        Library.catalogAction("finish.validate",{document=ev.document,token=ev.token},function(result)
            if not result.apply or ev.owner~=LibraryAdapter.owner() or epoch~=(FinishUI.intent[ev.document] or 0) then return end
            local side=Server.loaded("sidecar")
            if not (side and sm and sm.mutate) then return end
            local st={status_known=ev.complete,status=ev.complete and "complete" or nil,status_modified=ev.date,rating_known=ev.rated,rating=ev.rating}
            local ui=liveUI()
            if ui and ui.document and ui.document.file==ev.path then side.applyServerStateLive(ui,st)
            elseif ev.path then side.applyServerStateSidecar(ev.path,st) end
            sm.mutate(function(session) local b=session:getBook(ev.document);if b then side.rememberServerState(b,st) end end)
            if LocalState then LocalState.noteSent(ev.document) end
            FinishUI.jobs[ev.document]=nil
            Library.catalogAction("finish.ack",{document=ev.document,token=ev.token})
        end)
    end
end

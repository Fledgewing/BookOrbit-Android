-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Legacy cached protocol query translation; owned UI uses Store.library only.
function Server.bulkList(conn, w)
    local g = tonumber(Store.meta(conn, "bulk_active"))
    if not g then return nil end
    local q = ServerCache.parseQuery(w.identity:match("%?(.*)$") or "")
    local statusarg
    local args, from, cond, order, context = {g}, "bulk_books b", {"b.g=?"}, nil, false
    if w.section then
        from, cond, args = "bulk_sections b", {"b.g=?", "b.section=?"}, {g, w.section}
        if q.sort == "name_desc" then from = from .. " JOIN bulk_section_ranks r ON r.g=b.g AND r.section=b.section AND r.id=b.id AND r.direction='name_desc'" end
        if q.filter then
            if q.filter ~= "reading" and q.filter ~= "finished" then return nil end
            table.insert(cond, "b." .. q.filter .. ">0")
        end
        order = q.sort == "books" and "b.n DESC,b.pos" or q.sort == "name_desc" and "r.pos" or "b.pos"
    else
        if q.q and q.q ~= "" then return nil end
        local sort = q.sort or "recently_added"
        local dir = q.order or (sort:match("^recently_") and "desc" or "asc")
        if dir ~= "asc" and dir ~= "desc" then return nil end
        local d = dir:upper()
        local sid = q.seriesId or (q.series and q.series:match("^series:(%d+)$"))
        context = not q.smartScopeId and (sid ~= nil or q.series ~= nil)
        if context then
            from = from .. " JOIN bulk_members s ON s.g=b.g AND s.id=b.id AND s.kind=? AND s.value=?"
            table.insert(args, 1, sid or q.series:match("^%s*(.-)%s*$"):lower())
            table.insert(args, 1, sid and "seriesId" or "series")
        end
        local selectors = q.smartScopeId and {"smartScopeId"} or {"libraryId", "collectionId", "author", "format"}
        for _, k in ipairs(selectors) do
            if q[k] and q[k] ~= "" then
                table.insert(cond, "EXISTS (SELECT 1 FROM bulk_members m WHERE m.g=b.g AND m.id=b.id AND m.kind=? AND m.value=?)")
                table.insert(args, k); table.insert(args, q[k])
            end
        end
        if not q.smartScopeId then
            if q.readStatus then table.insert(cond, "b.status=?"); table.insert(args, q.readStatus); statusarg = #args end
            if q.ids then
                local marks, count = {}, 0
                for id in q.ids:gmatch("[^,]+") do
                    if id:match("^%d+$") and count < 200 then
                        table.insert(marks, "?"); table.insert(args, tonumber(id)); count = count + 1
                    end
                end
                table.insert(cond, #marks == 0 and "0" or "b.id IN (" .. table.concat(marks, ",") .. ")")
            end
        end
        if sort == "title" or (sort == "series" and not context) then
            from = from .. " JOIN bulk_ranks r ON r.g=b.g AND r.id=b.id AND r.kind=? AND r.direction=?"
            local n = context and 3 or 1
            table.insert(args, n, sort); table.insert(args, n + 1, dir)
            if statusarg then statusarg = statusarg + 2 end
            order = "r.pos"
        elseif sort == "series" then
            from = from .. " JOIN bulk_ranks tr ON tr.g=b.g AND tr.id=b.id AND tr.kind='title' AND tr.direction='asc'"
            order = "s.ix1 IS NULL,s.ix1 " .. d .. ",s.ix2 " .. d .. ",s.ix " .. d .. ",tr.pos,b.id"
        elseif sort == "recently_added" or sort == "recently_updated" then
            order = "b." .. (sort == "recently_added" and "added" or "updated") .. " " .. d .. ",b.id"
        elseif sort == "author" or sort == "published" or sort == "recently_read" then
            from = from .. " JOIN bulk_ranks r ON r.g=b.g AND r.id=b.id AND r.kind=? AND r.direction=?"
            local n = context and 3 or 1
            table.insert(args, n, sort); table.insert(args, n + 1, dir)
            if statusarg then statusarg = statusarg + 2 end
            order = "r.pos"
        else return nil end
    end
    from = from .. " WHERE " .. table.concat(cond, " AND ")
    local total = tonumber(Store.rows(conn, "SELECT count(*) FROM " .. from, unpack(args))[1][1]) or 0
    local start, stop, size = ServerCache.window(w.kind, total, w.page, w.size, w.offset)
    local h = Store.rows(conn, "SELECT head FROM bulk_heads WHERE g=? AND identity=?",g,w.identity)[1]
    local head = h and ServerCache.decode(h[1] or "") or {}
    if not w.section and q.buckets == "1" and (q.sort == "title" or q.sort == "author") then
        head.buckets = {}
        for _, b in ipairs(Store.rows(conn, "SELECT r.letter,min(r.pos),count(*) FROM " .. from .. " GROUP BY r.letter ORDER BY min(r.pos)", unpack(args))) do
            local a = {unpack(args)}; table.insert(a, tonumber(b[2]))
            local index = tonumber(Store.rows(conn, "SELECT count(*) FROM " .. from .. " AND r.pos<?", unpack(a))[1][1]) or 0
            table.insert(head.buckets, {key=b[1] or "#", index=index, count=tonumber(b[3]) or 0})
        end
    end
    if w.section and (w.section=="authors" or w.section=="series") and q.sort~="books" then
        head.buckets={}
        local pos=q.sort=="name_desc" and "r.pos" or "b.pos"
        for _,b in ipairs(Store.rows(conn,"SELECT b.letter,min(" .. pos .. "),count(*) FROM " .. from .. " GROUP BY b.letter ORDER BY min(" .. pos .. ")",unpack(args))) do
            local a={unpack(args)};table.insert(a,tonumber(b[2]))
            local index=tonumber(Store.rows(conn,"SELECT count(*) FROM " .. from .. " AND " .. pos .. "<?",unpack(a))[1][1]) or 0
            table.insert(head.buckets,{key=b[1] or "#",index=index,count=tonumber(b[3]) or 0})
        end
    end
    if context then
        local a = {unpack(args)}
        local scope = from
        if statusarg then table.remove(a, statusarg); scope = scope:gsub(" AND b.status=%?", "") end
        local counts = {}
        for _, r in ipairs(Store.rows(conn, "SELECT b.status,count(*) FROM " .. scope .. " GROUP BY b.status", unpack(a))) do counts[r[1]] = tonumber(r[2]) end
        head.seriesSummary = {total=total, reading=counts.reading or 0, finished=counts.finished or 0}
    end
    table.insert(args, stop-start); table.insert(args, start)
    local got = Store.rows(conn, "SELECT " .. (w.section and "b.item" or "b.item" .. (context and ",s.context" or ""))
        .. " FROM " .. from .. " ORDER BY " .. order .. " LIMIT ? OFFSET ?", unpack(args))
    local items = {}
    for _, row in ipairs(got) do
        local book = ServerCache.decode(row[1] or "")
        if type(book) ~= "table" then return nil end
        if context then for k, v in pairs(ServerCache.decode(row[2] or "") or {}) do book[k] = v end end
        table.insert(items, book)
    end
    return {body=ServerCache.assemble(head, items, total, start, stop, size, w.offset),
        validated_at=tonumber(Store.meta(conn, "bulk_at")) or 0, table="lists"}
end


-- Original legacy lookup/search; owned renderers only consume Store.library.
local within,rows=Store.within,Store.rows
-- Bulk-generation windows: SQL filters/ranks use bound values and decode only this window.
-- Network, JSON parsing and index construction belong to the companion.
-- A list window. -> entry { body, validated_at } or nil when a position isn't saved.
local function list(conn, w)
    if Store.meta(conn, "bulk_active") then return Server.bulkList(conn, w) end
    local l = rows(conn, "SELECT kind, total, head, validated_at FROM lists WHERE identity = ?", w.identity)[1]
    if not l then return nil end
    local total = tonumber(l[2]) or 0
    local start, stop, size = ServerCache.window(l[1] or w.kind, total, w.page, w.size, w.offset)
    local got = rows(conn, "SELECT li.pos, COALESCE(b.item, li.item) FROM list_items li LEFT JOIN books b ON b.id = li.book_id "
        .. "WHERE li.identity = ? AND li.pos >= ? AND li.pos < ? ORDER BY li.pos", w.identity, start, stop)
    if #got ~= stop - start then return nil end
    local items = {}
    for i, r in ipairs(got) do
        local item = ServerCache.decode(r[2] or "")
        if type(item) ~= "table" then return nil end
        items[i] = item
    end
    return { body = ServerCache.assemble(ServerCache.decode(l[3] or ""), items, total, start, stop, size, w.offset),
        validated_at = tonumber(l[4]) or 0, table = "lists" }
end

-- What the cache holds for a read (OC.lookup): { key, body, validated_at, stale, path } or nil.
-- template: the plugin's detail request with Mirror.SENTINEL for the id (Mirror.detailPath).
function Store.read(owner, key, path, template)
    return within(owner, "read:" .. key, function(conn)
        local w = ServerCache.listWindow(path)
        local e
        if w then
            e = list(conn, w)
        else
            local id = ServerCache.detailId(path, template, Mirror.SENTINEL)
            if id then
                local r = rows(conn, "SELECT detail, detail_at FROM books WHERE id = ? AND detail IS NOT NULL", id)[1]
                local body = r and ServerCache.decode(r[1] or "")
                if type(body) == "table" then e = { body = body, validated_at = tonumber(r[2]) or 0, table = "books" }
                elseif Store.meta(conn, "bulk_active") then
                    local stub = rows(conn, "SELECT item FROM bulk_books WHERE g = ? AND id = ?", tonumber(Store.meta(conn, "bulk_active")), id)[1]
                    local item = stub and ServerCache.decode(stub[1] or "")
                    if type(item) == "table" then e = {body=item, validated_at=0, stale=true, table="books", partial=true} end
                end
            else
                local r = rows(conn, "SELECT body, validated_at, stale FROM entries WHERE key = ?", key)[1]
                local body = r and ServerCache.decode(r[1] or "")
                if type(body) == "table" then e = { body = body, validated_at = tonumber(r[2]) or 0, stale = tonumber(r[3]) == 1 or nil, table = "entries" } end
            end
        end
        if e then e.key, e.path = key, path end
        return e
    end)
end

-- An offline search over the saved books (title, authors, series): the server's list shape.
function Store.search(owner, path)
    local q = ServerCache.parseQuery((tostring(path):match("%?(.*)$")) or "")
    local words = ServerCache.searchWords(q.q)
    if #words == 0 then return nil end
    return within(owner, "search:" .. path, function(conn)
        local where = {}
        for _ in ipairs(words) do table.insert(where, "search LIKE ? ESCAPE '\\'") end
        local bulk = tonumber(Store.meta(conn, "bulk_active"))
        local source = bulk and "books b JOIN bulk_books c ON c.id=b.id AND c.g=" .. bulk or "books"
        local item = bulk and "c.item" or "item"
        local cond = item .. " IS NOT NULL AND " .. table.concat(where, " AND ")
        local total = tonumber(rows(conn, "SELECT count(*) FROM " .. source .. " WHERE " .. cond, unpack(words))[1][1]) or 0
        local start, stop, size = ServerCache.window("books", total, q.page, q.size, q.offset)
        local args = { unpack(words) }
        table.insert(args, stop - start)
        table.insert(args, start)
        local items = {}
        for _, r in ipairs(rows(conn, "SELECT " .. item .. " FROM " .. source .. " WHERE " .. cond .. " ORDER BY search LIMIT ? OFFSET ?", unpack(args))) do
            local item = ServerCache.decode(r[1] or "")
            if type(item) == "table" then table.insert(items, item) end
        end
        return ServerCache.assemble({ query = q.q }, items, total, start, stop, size, q.offset)
    end)
end


-- Live non-cover catalog caching and event plumbing. This remains only until the catalog
-- command cutover; cover acquisition/IO and its fallback downloader have been removed.
OC = { inflight = {}, done = {}, MODE_S = 30 }


OC.now = os.time
local function nowT() return OC.now() end

function OC.on() return S.offline_cache ~= false end

function OC.dir()
    if not OC._dir then OC._dir=Store.defaultDirectory() end
    return OC._dir
end
Store.directory=OC.dir
Store.directoryReady=function() return OC._dir~=nil end
Store.inChild=function() return OC.child end
Store.now=function() return OC.now() end
local function readFile(...) return Store.readFile(...) end
local function writeFile(...) return Store.writeFile(...) end
OC.readFile, OC.writeFile = readFile, writeFile

-- The entry's file name (Cache.hash; the key is stored inside and checked).
function OC.hash(s) return ServerCache.hash(s) end

-- In a forked child (the plugin's runInSubprocess, catalog.lua:881): never JNI (NetworkMgr on
-- Android is JNI, device/android/device.lua:333; a child that calls it dies and the plugin gets
-- subprocess_no_result), never the UI; the parent's state comes across the fork.
local function inChild(client) return OC.child == true or (client and (client.subprocess_depth or 0) > 0) end

-- Online? In a child: what the parent saw just before it forked.
function OC.online(client)
    if inChild(client) then return OC.parent_online ~= false end
    return NetworkMgr:isConnected()
end

---------------------------------------------------------------- the plugin's own state

-- What the plugin keeps between starts besides the database: the detail variant it reads (for
-- the companion's detail template) and the copies queue. A few lines, written in place.
function OC.state()
    if OC._state then return OC._state end
    local d = ServerCache.decode(readFile(OC.dir() .. "/plugin-state.lua") or "")
    OC._state = type(d) == "table" and d or {}
    return OC._state
end

function OC.saveState()
    if OC.child then return end
    if Companion.workerProblem() then return end
    Companion.send(Companion.ACTION.PATCH, { reason = "plugin state", plugin_state = ServerCache.encode(OC.state()) })
end

-- Everything goes: the setting turned off, or on request (another account or server: the
-- companion clears the database itself when it next saves for another owner).
function OC.wipe(why)
    log("cache: cleared (" .. tostring(why) .. ")")
    OC._state = {}
    OC.saveState()
    OC.storage = nil
    if not Companion.workerProblem() then Companion.send(Companion.ACTION.PATCH, { reason = tostring(why), wipe = "1" }) end
    UIManager:scheduleIn(5, function() pcall(OC.storageCount, "cleared") end)
end

-- The account and server this cache belongs to (the database's owner; another one is a miss).
function OC.owner(client)
    return tostring(client.username or "") .. "|" .. tostring(client.server_url or ""):lower()
end

-- The plugin's detail request with Mirror.SENTINEL for the id (how the database names details).
function OC.detailTemplate(client)
    local okp, p = pcall(Mirror.detailPath, client, Mirror.SENTINEL)
    return okp and p or nil
end

---------------------------------------------------------------- child events

-- Child metadata travels in the subprocess result, never through a scanned directory.
function OC.event(kind, data)
    data.kind = kind
    OC.child_events = OC.child_events or {}
    table.insert(OC.child_events, data)
end

-- A single poll chain, shared by startup, reads and all job watchers. A lost ack is
-- retried with backoff; reading the same durable batch never creates another timer.
OC.EVENT_POLL_S, OC.EVENT_RETRY_S = 0.5, 10
function OC.drainEvents()
    if OC.child then return end
    UIManager:unschedule(OC.drainEvents)
    UIManager:scheduleIn(OC.EVENT_POLL_S, OC.drainEvents)
    if Companion.workerProblem() then return end
    local t = now_s()
    if OC.events_read_at and t - OC.events_read_at < OC.EVENT_POLL_S then return end
    OC.events_read_at = t
    local batch = ServerCache.decode(readFile(OC.dir() .. "/events-batch.lua", 65536) or "")
    if type(batch) ~= "table" or not batch.id then return end
    if batch.id ~= OC.events_ack then
        -- Record before dispatch: an event may synchronously call a watcher again.
        OC.events_ack, OC.events_sent_at = batch.id, nil
        OC.applyEvents(batch.events or {})
    end
    if not OC.events_sent_at or t - OC.events_sent_at >= OC.EVENT_RETRY_S then
        OC.events_sent_at = t
        Companion.send(Companion.ACTION.PATCH, { reason = "events", drain_events = "1", events_ack = batch.id })
    end
end

function OC.applyEvents(events)
    for _, ev in ipairs(events) do
        if type(ev) == "table" then
            if LibraryAdapter and (ev.kind == "checked" or ev.kind == "copies") then LibraryAdapter.changed(ev) end
            if ev.kind == "library" or ev.kind == "library_source" or ev.kind == "account" then
                LibraryAdapter.changed(ev)
            elseif ev.kind == "stored" then
                -- (0.11.x) nothing: the companion saves now.
            elseif ev.kind == "board_year" and LF then
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
            elseif ev.kind == "copy_prepared" and Copies then
                Copies.prepared(ev)
            elseif ev.kind == "copies" and Copies then
                Copies.found(ev)
            elseif ev.kind == "checked" and ev.key then
                local job = OC.inflight[ev.key]
                OC.inflight[ev.key] = nil
                if job then OC.landed(nil, job, ev) end
            elseif ev.kind == "check" and ev.key then
                OC.check(nil, ev.key, ev.method, ev.path, ev.headers, nil, ev.mode)
            elseif ev.kind == "write" then
                OC.afterWrite(ev.method, ev.path, ev.body)
            elseif ev.kind == "read" and ev.key then
                table.insert(OC.pending, ev.key)
                OC.source[ev.key] = ev.source
            elseif ev.kind == "miss" then
                OC.offline_miss = true
            elseif ev.kind == "search" then
                OC.offline_search = true
            elseif ev.kind == "other" then
                OC.offline_other = true
            end
        end
    end
end

---------------------------------------------------------------- reads

-- The active refresh mode: { mode = "refresh" | "full", until_t }.
function OC.mode()
    local m = OC.active
    if m and nowT() <= m.until_t then return m.mode end
    OC.active = nil
    return "open"
end

function OC.begin(mode)
    OC.active = { mode = mode, until_t = nowT() + OC.MODE_S }
    OC.done = {}
end

-- The entry for a read: the database's answer (a list window, a detail, any other reply), or nil.
function OC.lookup(client, key, path)
    return Store.read(OC.owner(client), key, path, OC.detailTemplate(client))
end

-- The wrapper's body for a cacheable GET. Returns handled, body, err, errbody.
function OC.read(client, stock, method, path, body, headers)
    local owner = OC.owner(client)
    local key = ServerCache.key({ account = owner, server = client.server_url, method = method, path = path })
    local entry = OC.lookup(client, key, path)
    local mode = OC.mode()
    -- Within one refresh each key is fetched or checked once; later reads are plain opens.
    if mode ~= "open" and OC.done[key] then mode = "open" end
    local offline = not OC.online(client)
    local serve, fetch = ServerCache.readPlan(entry, nowT(), mode, offline)
    if OC.cache_only then fetch = false end
    local variant = tostring(path):match("/catalog/books/%d+%?.*variant=([%w_]+)")
    if variant and not inChild(client) and OC.state().detail_variant ~= variant then
        OC.state().detail_variant = variant
        OC.saveState()
    end
    local short = tostring(path):gsub("^/koreader/plugin/catalog", "")
    if not serve and OC.cache_only then return true, nil, "cancelled" end
    if not offline and not OC.cache_only and not inChild(client) then pcall(OC.mirrorTick, "read") end
    if serve then
        OC.saw(client, key, "cache")
        if fetch then
            OC.done[key] = true
            if inChild(client) then OC.event("check", { key = key, method = method, path = path, headers = headers })
            else OC.check(nil, key, method, path, headers, client) end
            log("cache:", short, "from the cache, age", (nowT() - (entry.validated_at or 0)) .. "s"
                .. (entry.stale and ", changed here since" or "") .. "; checking (" .. mode .. ")")
        else
            log("cache:", short, "from the cache, age", (nowT() - (entry.validated_at or 0)) .. "s" .. (offline and ", offline" or ""))
        end
        return true, ServerCache.copy(entry.body)
    end
    if offline and OC.offline_pass then
        -- Offline, not saved: quiet ("cancelled" is the plugin's no-error path) and the
        -- runConnected wrapper asks to connect; a search only says it needs a connection.
        if ServerCache.isSearch(path) then
            -- Offline search: over the saved books (title, authors, series).
            local found = Store.search(OC.owner(client), path)
            if found and (found.total or 0) > 0 then
                OC.saw(client, key, "cache")
                log("cache:", short, "searched the saved books (offline):", found.total)
                return true, found
            end
            if inChild(client) then OC.event("search", {}) else OC.offline_search = true end
            log("cache:", short, "is a search; it needs a connection (offline)")
            return true, nil, "cancelled"
        end
        OC.missed(client)
        log("cache:", short, "isn't saved on this reader (offline)")
        return true, nil, "cancelled"
    end
    local b, e, eb = stock(client, method, path, body, headers)
    if b ~= nil then
        OC.saw(client, key, "server")
        OC.store(client, key, method, path, headers)
        log("cache:", short, "from the server (" .. mode .. ")")
        return true, b, e, eb
    end
    if entry then
        OC.saw(client, key, "cache")
        log("cache:", short, "server failed (" .. tostring(e) .. "); the cached copy instead")
        OC.failed[key] = true
        return true, ServerCache.copy(entry.body)
    end
    return true, b, e, eb
end
OC.pending, OC.source, OC.failed = {}, {}, {}

-- A reply read from the server: the companion asks again and saves it (CHECK mode "store"), so
-- KOReader never encodes or writes a reply. A search isn't saved (offline search reads the books).
function OC.store(client, key, method, path, headers)
    if ServerCache.isSearch(path) then return end
    if inChild(client) then return OC.event("check", { key = key, method = method, path = path, headers = headers, mode = "store" }) end
    OC.check(nil, key, method, path, headers, client, "store")
end

-- A view read key (for redraws and the paint log); from a child, through an event.
function OC.saw(client, key, source)
    if inChild(client) then return OC.event("read", { key = key, source = source }) end
    table.insert(OC.pending, key)
    OC.source[key] = source
end

function OC.missed(client)
    if inChild(client) then return OC.event("miss", {}) end
    OC.offline_miss = true
end

---------------------------------------------------------------- background checks

-- Asks the companion to check key against the server (docs/design/companion-worker.md): it
-- asks, compares with what the plugin would serve (its entry, else the mirror's pages), saves a
-- changed reply under the key and answers with a "checked" event (OC.drainEvents). KOReader only
-- sends the job and reads the small answer: it never handles the reply's body (decoding and
-- encoding it froze the UI on the M8C). One per key; none without the companion.
function OC.check(_, key, method, path, headers, client, mode)
    if OC.inflight[key] or method ~= "GET" then return end
    client = client or OC.client()
    if not client or not NetworkMgr:isConnected() then return end
    local problem = Companion.workerProblem()
    if problem then
        if OC.check_blocked ~= problem then log("cache: background checks off:", problem) end
        OC.check_blocked = problem
        return
    end
    OC.check_blocked = nil
    OC.inflight[key] = { key = key, path = path, at = nowT() }
    Companion.send(Companion.ACTION.CHECK, { reason = "check", cache_key = key, path = path, mode = mode or OC.mode(),
        owner = OC.owner(client), server = client.server_url, user = client.username, userkey = client.userkey,
        template = OC.detailTemplate(client) or "" })
    OC.watchChecks()
end

-- While checks are out: their answers are read every second; one with no answer in CHECK_S fails.
OC.CHECK_S = 60
function OC.watchChecks()
    if OC.watching then return end
    OC.watching = true
    local function tick()
        pcall(OC.drainEvents)
        local t = nowT()
        for key, job in pairs(OC.inflight) do
            if t - job.at >= OC.CHECK_S then
                OC.inflight[key] = nil
                OC.landed(nil, job, { err = "the companion didn't answer" })
            end
        end
        if OC.storage_asked and t - OC.storage_asked >= OC.STORAGE_WAIT_S then
            log("storage: the companion didn't answer the count")
            OC.storage_asked = nil
        end
        if Copies and Copies.asked and t - Copies.asked >= Copies.WAIT_S then
            log("copies: the companion didn't answer the check")
            Copies.asked = nil
        end
        if LF and LF.year_waiting and os.time() - LF.year_waiting > 60 then LF.year_waiting = nil end
        local sleep_waits = Sleep and Sleep.waited(t)
        if OC.recheck and t - OC.recheck.at >= OC.RECHECK_WAIT_S then
            log("cache: the companion didn't answer the cover recheck")
            OC.rechecked({ err = "no answer" })
        end
        if Copies and Copies.prepare_at and t - Copies.prepare_at >= Copies.WAIT_S then
            Copies.preparing, Copies.prepare_at, Copies.busy = nil, nil, nil
            Copies.stop("companion preparation timed out")
        end
        if not (LibraryAdapter and LibraryAdapter.watching) and next(OC.inflight) == nil and not OC.storage_asked and not (Copies and (Copies.asked or Copies.prepare_at)) and not sleep_waits and not OC.recheck and not (LF and LF.year_waiting) then OC.watching = nil; return end
        UIManager:scheduleIn(1, tick)
    end
    UIManager:scheduleIn(1, tick)
end

function OC.client()
    local p = serverPlugin(liveUI())
    if not p then return nil end
    if p.catalog_browser and p.catalog_browser.client then return p.catalog_browser.client end
    if Compat.callable(p.newClient) then
        local okc, c = pcall(p.newClient, p)
        if okc then return c end
    end
    return nil
end

function OC.landed(client, job, r)
    local short = tostring(job.path):gsub("^/koreader/plugin/catalog", "")
    if type(r) ~= "table" or not (r.changed or r.unchanged) then
        OC.failed[job.key] = true
        log("cache:", short, "check failed (network:", tostring(type(r) == "table" and r.err or "no answer") .. "); the saved copy stays")
        return
    end
    OC.failed[job.key] = nil
    if r.unchanged then
        log("cache:", short, "checked: unchanged")
        return
    end
    if OC.onScreen(job.key) then
        log("cache:", short, "checked: changed; redrawing once the checks are done")
        OC.redraw_soon(job.key)
    else
        log("cache:", short, "checked: changed; saved (not on screen)")
    end
end

function OC.onScreen(key)
    local p = serverPlugin(liveUI())
    local cat = p and p.catalog_browser
    return cat ~= nil and not cat.catalog_closed and cat._orbit_view_keys ~= nil and cat._orbit_view_keys[key] == true
end

-- One redraw after the running checks land, however many of the view's keys changed.
function OC.redraw_soon(key)
    OC.redraw_key = key
    if OC.redraw_scheduled then return end
    OC.redraw_scheduled = true
    local function flush()
        if next(OC.inflight) ~= nil then return UIManager:scheduleIn(0.5, flush) end
        OC.redraw_scheduled = nil
        local k = OC.redraw_key
        OC.redraw_key = nil
        if k then OC.redraw(k) end
    end
    UIManager:scheduleIn(0.3, flush)
end

-- What keeps Wi-Fi on (Wifi.busy): checks in flight or the offline mirror saving.
function OC.busy()
    if next(OC.inflight) ~= nil then return "the BookSync cache checking BookOrbit" end
    if Mirror and Mirror.active then return "saving BookOrbit for offline" end
    return nil
end

-- A changed entry that is on screen: the view reloads from the cache (no request, no spinner).
function OC.redraw(key)
    local p = serverPlugin(liveUI())
    local cat = p and p.catalog_browser
    if not cat or cat.catalog_closed or not cat._orbit_view_keys or not cat._orbit_view_keys[key] then return end
    local ctx = cat.current_context or {}
    if ctx.kind == "dashboard" and Compat.callable(cat.loadDashboardRoot) then
        cat:loadDashboardRoot(true, { invisible = true })
        return true
    end
    if Compat.callable(cat.refreshCurrent) then LF.refreshKeepingCovers(cat); return true end
end

---------------------------------------------------------------- writes

function OC.afterWrite(method, path, body)
    local eff = ServerCache.writeEffect(method, path, body)
    if not eff then return end
    -- The companion patches the saved book (and the lists that name it) and marks Home stale.
    -- A progress write names the book by document digest; the local overlay already shows this
    -- device's position, and Home is checked against the server on its next read.
    if Companion.workerProblem() then return end
    Companion.send(Companion.ACTION.PATCH, { reason = "write", id = eff.id and tostring(eff.id) or "",
        fields = eff.fields and ServerCache.encode(eff.fields) or "", stale_home = eff.stale_home and "1" or "0" })
    log("cache: a write to", (tostring(path):gsub("^/koreader/plugin/catalog", "")), "sent to the companion to patch")
end

---------------------------------------------------------------- the storage limit (v0.11.2)

-- Everything Orbit stores counts (Orbit menu › Storage limit, S.storage_limit_mb): the database
-- (browsing replies, the lists and books saved for offline) and the covers in the plugin's cover
-- directory, saved for offline or not. Book files and KOReader's own data don't. Orbit Companion
-- counts and, over the limit, removes the oldest browsing replies and covers itself (STORAGE,
-- docs/design/companion-worker.md); the plugin keeps the totals it answers with.
local MB = 1048576
OC.STORAGE_WAIT_S = 60

function OC.limitBytes()
    local mb = tonumber(S.storage_limit_mb) or ServerCache.STORAGE_DEFAULT_MB
    return mb > 0 and mb * MB or nil
end

function OC.coverDir()
    if OC.cover_dir then return OC.cover_dir end
    local okd, DataStorage = pcall(require, "datastorage")
    local okp, d = pcall(function() return DataStorage:getDataDir() end)
    return okd and okp and d and (d .. "/cache/bookorbit") or nil
end

-- Asks the companion to count (and, over the limit, remove). One ask at a time; one asked
-- meanwhile follows it.
function OC.storageCount(why)
    if OC.child then return end
    if why == "over the limit" and OC.storage_last and nowT() - OC.storage_last < 60 then return end
    if OC.storage_asked and nowT() - OC.storage_asked < OC.STORAGE_WAIT_S then OC.storage_again = why; return end
    local problem = Companion.workerProblem()
    if problem then
        if OC.storage_problem ~= problem then OC.storage_problem = problem; log("storage: not counted:", problem) end
        return
    end
    OC.storage_problem = nil
    OC.storage_asked, OC.storage_again, OC.storage_last = nowT(), nil, nowT()
    local limit = OC.limitBytes()
    Companion.send(Companion.ACTION.STORAGE, { reason = tostring(why), limit = limit and tostring(limit) or "",
        cover_dir = OC.coverDir() or "", mirror_covers = S.mirror_covers and "1" or "0" })
    OC.watchChecks()
end

-- The companion's count: dropped browsing entries leave the index (unless used since), totals kept.
function OC.storageCounted(ev)
    OC.storage_asked = nil
    local rm0 = type(ev.removed) == "table" and ev.removed or {}
    local dropped = rm0.cache or 0
    if type(ev.totals) == "table" then OC.storage = ev.totals end
    local st, limit, rm = OC.storage or {}, OC.limitBytes(), type(ev.removed) == "table" and ev.removed or {}
    if (ev.used or 0) ~= (ev.after or 0) then
        log(string.format("storage: %.1f MB of %d MB (%s); removed %d browsing entries, %d covers, %d saved-for-offline covers -> %.1f MB",
            (ev.used or 0) / MB, math.floor((limit or 0) / MB), tostring(ev.why), dropped, rm.cover or 0, rm.mirror_cover or 0, (ev.after or 0) / MB))
    elseif ev.why == "start" then
        log(string.format("storage: using %.1f MB of %s (lists and books saved for offline %.1f MB, covers %.1f MB, of them saved for offline %.1f MB)",
            (st.used or 0) / MB, limit and (math.floor(limit / MB) .. " MB") or "no limit", (st.kept or 0) / MB,
            ((st.cover or 0) + (st.mirror_cover or 0)) / MB, (st.mirror_cover or 0) / MB))
    end
    local again = OC.storage_again
    OC.storage_again = nil
    if again and again ~= "over the limit" then OC.storageCount(again) end
end

-- What Orbit stores now ({ used, kept, cache, cover, mirror_cover } bytes): the last count (the
-- worker's last answer), or nil before the first.
function OC.storageTotals()
    return OC.storage
end

-- "Using 58 MB" (the setting's line).
function OC.storageText()
    local st = OC.storageTotals()
    local mb = (st and st.used or 0) / MB
    return string.format(mb < 10 and _("Using %.1f MB") or _("Using %d MB"), mb < 10 and mb or math.floor(mb + 0.5))
end

---------------------------------------------------------------- Refresh and Full refresh

function OC.visibleBooks(cat)
    local ctx = cat.current_context or {}
    if ctx.kind == "dashboard" and Compat.callable(cat.dashboardBooks) then return cat.dashboardBooks(ctx.dashboard) end
    if ctx.kind == "books" then return ctx.books or {} end
    if ctx.kind == "detail" and Compat.callable(cat.detailThumbnailBooks) then return cat:detailThumbnailBooks(ctx.detail) end
    return {}
end

-- A short note on screen (the plugin's toast; its absence is no error).
function OC.note(text, timeout)
    log("cache: note:", text)
    pcall(function() require("bookorbit_toast").show(text, { timeout = timeout or 2 }) end) -- gate: bookorbit_toast is gated (Gate.installToast)
end

-- Full refresh is done when its view has painted and its covers are re-asked.
function OC.fullStep(what, n)
    local f = OC.full
    if not f then return end
    if what == "painted" then f.painted = true end
    if what == "covers" then f.covers_done, f.replaced = true, n or 0 end
    if f.painted and f.covers_done then
        -- Logged only: during a Full refresh the badge is the one thing on screen.
        OC.full = nil
        log(string.format("cache: Full refresh: this page is refreshed, %d covers checked, %d replaced", f.covers or 0, f.replaced or 0))
    end
end

-- Tap ⟳ / background checks: revalidate this view, never evict, retry failed covers.
-- Offline, a refresh first asks for the network (KOReader's own path, which the Orbit Wi-Fi
-- switching answers quietly) and runs once connected: it never repaints from a saved body.
local function whenOnline(what, fn)
    if NetworkMgr:isConnected() then return false end
    log("cache:", what, "while offline: connecting first")
    if Compat.callable(NetworkMgr.runWhenConnected) then
        NetworkMgr:runWhenConnected(fn)
    else
        OC.note(_("Connect to refresh"), 3)
    end
    return true
end

function OC.refresh(cat)
    if Mirror and Mirror.fullRunning() then return Mirror.showProgress("Refresh tapped") end
    if whenOnline("Refresh", function() OC.refresh(cat) end) then return end
    log("cache: Refresh")
    if not S.refresh_tip_shown then
        S.refresh_tip_shown = true
        pcall(saveSettings)
        OC.note(_("Refreshing… Tip: hold ⟳ for a full refresh"), 4)
    else
        OC.note(_("Refreshing…"), 2)
    end
    OC.begin("refresh")
    if type(cat.thumbnail_failures) == "table" then cat.thumbnail_failures = {} end
    local r = LF.refreshKeepingCovers(cat)
    -- The delta for the offline mirror: every saved page, in the background.
    if Mirror then pcall(Mirror.revalidate, "Refresh") end
    return r
end

-- Hold ⟳ / the menu: this view (and Home) from the server; bad cover files replaced, good ones
-- asked If-None-Match.
function OC.fullRefresh(cat)
    -- A second press while one is saving keeps that run and shows its progress (v0.11.1 on the
    -- M8C: four presses restarted it four times).
    if Mirror and Mirror.fullRunning() then return Mirror.showProgress("pressed again") end
    if whenOnline("Full refresh", function() OC.fullRefresh(cat) end) then return end
    local problem = Companion.workerProblem()
    if problem then return OC.note(problem, 4) end
    -- Start the bulk job before any view work. The companion owns validation,
    -- hashing, cover checks and the manifest. No synchronous Home refresh here.
    Mirror.cat, Mirror.notices = cat, true
    log("cache: Full refresh: starting companion bulk catalog")
    local started = Mirror.start("Full refresh", true)
    if started then
        local jobs = {}
        for _, book in ipairs(OC.visibleBooks(cat)) do
            if book.hasCover ~= false and Compat.callable(cat.thumbnailPath) then
                local path = cat:thumbnailPath(book)
                if path then jobs[#jobs + 1] = { book = book, path = path } end
            end
        end
        if #jobs > 0 then OC.recheckCovers(cat, jobs) end
    end
    return started
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
    OC.recheck={at=nowT(),cat=cat,n=#jobs}
    nextBatch()
end

function OC.rechecked(ev)
    local r = OC.recheck
    OC.recheck = nil
    if not r then return end
    if ev.err then log("cache: covers not re-asked:", tostring(ev.err)) end
    local changed = type(ev.changed) == "table" and ev.changed or {}
    log("cache: covers re-asked:", tonumber(ev.checked) or 0, "checked,", #changed, "replaced")
    OC.fullStep("covers", #changed)
    local cat = r.cat
    if #changed > 0 and cat and not cat.catalog_closed and not reading() then
        if Compat.callable(cat.resetThumbnailMemo) then cat:resetThumbnailMemo() end
        if Compat.callable(cat.updateItems) then cat:updateItems(nil, true) end
    end
end

-- Refresh or Full refresh from the menu: the open catalog's view, else Home next time it opens.
function OC.menuFullRefresh()
    local p = serverPlugin(liveUI())
    local cat = p and p.catalog_browser
    if not cat and p and EOB then cat = EOB.headlessCatalog(p) end
    if cat then return OC.fullRefresh(cat) end
    OC.note(_("Connect to the server and sign in to refresh the catalog."), 4)
end

-- One line per paint: covers the view needs, how many are on disk, how many are queued.
function OC.coverSummary(cat)
    local books = OC.visibleBooks(cat)
    local need, have, shown = 0, 0, {}
    for _, b in ipairs(books) do
        if type(b) == "table" and b.hasCover then
            need = need + 1
            local path = Compat.callable(cat.cachedThumbnailPath) and cat:cachedThumbnailPath(b)
            if path then have = have + 1; table.insert(shown, path) end
        end
    end
    if #shown > 0 and not Companion.workerProblem() then
        Companion.send(Companion.ACTION.STORAGE, { shown = table.concat(shown, "\n") })
    end
    local q = cat.thumbnail_queue
    local queued = type(q) == "table" and q.tail and q.head and (q.tail - q.head + 1) or 0
    if need > 0 then log("covers:", need, "needed,", have, "on disk,", queued, "queued") end
end

---------------------------------------------------------------- install

OC.API = { request = "function", requestBlocking = "function", runInSubprocess = "function" }

function OC.install(why)
    local Api = package.loaded["bookorbit_api"]
    local Catalog = package.loaded["bookorbit_catalog"]
    if type(Api) ~= "table" or type(Catalog) ~= "table" then return false end
    Server.installCovers(Api,Catalog)
    if OC.installed then return true end
    if not OC.on() then return false end
    local missing = Compat.missingOn(Api, OC.API)
    if #missing > 0 then
        log("compat: offline cache off (plugin changed): missing " .. table.concat(missing, ", "))
        return false
    end
    wrap(Api, "request", function(stock) return function(self, method, path, body, headers)
        if OC.on() and ServerCache.cacheable(method, path) then
            local okr, handled, b, e, eb = pcall(OC.read, self, stock, method, path, body, headers)
            if okr and handled then return b, e, eb end
            if not okr then log("cache: read failed, straight to the server:", handled) end
            return stock(self, method, path, body, headers)
        end
        if OC.offline_pass and OC.on() then
            -- A write or other call in an offline view load: stop here quietly and connect.
            if inChild(self) then pcall(OC.event, "other", {}) else OC.offline_other = true end
            return nil, "cancelled"
        end
        local b, e, eb = stock(self, method, path, body, headers)
        if b ~= nil and tostring(method):upper() ~= "GET" and OC.on() then
            if inChild(self) then pcall(OC.event, "write", { method = method, path = path, body = body })
            else pcall(OC.afterWrite, method, path, body) end
        end
        return b, e, eb
    end end, "cache")
    wrap(Api, "runInSubprocess", function(stock) return function(self, fn, ...)
        if inChild(self) then return stock(self, fn, ...) end
        local okn, on = pcall(NetworkMgr.isConnected, NetworkMgr)
        OC.parent_online = not okn or on == true
        local a, b = stock(self, function(...)
            OC.child = true -- this copy of the process is the child
            OC.child_events = {}
            local okf, r1, r2, r3 = pcall(fn, ...)
            OC.child = nil
            if not okf then error(r1, 0) end
            return { orbit_result = { body = r1, err = r2, errbody = r3 }, orbit_events = OC.child_events }
        end, ...)
        if a and type(b) == "table" and type(b.body) == "table" and b.body.orbit_result then
            local envelope = b.body
            b = envelope.orbit_result
            OC.applyEvents(envelope.orbit_events or {})
        end
        pcall(OC.drainEvents)
        return a, b
    end end, "cache")
    -- Offline: run the view's load from the cache, no connection asked. A page that isn't saved
    -- answers "cancelled" (quiet) and then asks "Connect and load more" (local-first design,
    -- "Paging past the saved pages"); a write or download just connects as before.
    if Compat.callable(Catalog.runConnected) then
        wrap(Catalog, "runConnected", function(stock) return function(self, fn)
            if not OC.on() or OC.offline_pass or NetworkMgr:isConnected() then return stock(self, fn) end
            OC.offline_pass, OC.offline_miss, OC.offline_other, OC.offline_search = true, false, false, false
            local okr, err = pcall(function()
                local Trapper = require("ui/trapper")
                Trapper:wrap(function()
                    local okf, ferr = pcall(fn)
                    OC.offline_pass = nil
                    pcall(OC.drainEvents)
                    if not okf then log("cache: offline view failed:", ferr) end
                    if OC.offline_other then return stock(self, fn) end
                    if OC.offline_search and not OC.offline_miss then
                        OC.note(_("Search needs a connection"), 3)
                        return
                    end
                    if OC.offline_miss then
                        log("cache: offline; asking to connect for a page that isn't saved")
                        UIManager:show(require("ui/widget/confirmbox"):new{ -- gate: user action (paging a list offline)
                            text = _("This page isn't saved on this reader."),
                            ok_text = _("Connect and load more"),
                            ok_callback = function() stock(self, fn) end,
                        })
                    end
                end)
            end)
            if not okr then OC.offline_pass = nil; log("cache: offline pass failed:", err); return stock(self, fn) end
        end end, "cache")
    end
    if Compat.callable(Api.download) then
        wrap(Api, "download", function(stock) return function(self, ...)
            if OC.offline_pass and OC.on() then
                if inChild(self) then pcall(OC.event, "other", {}) else OC.offline_other = true end
                return nil, "cancelled"
            end
            return stock(self, ...)
        end end, "cache")
    end
    -- The keys a view was built from, for redrawing it when one of them changes; a log line per
    -- paint naming where its data came from.
    wrap(Catalog, "switchTo", function(stock) return function(self, title, item_table, context, push)
        if #OC.pending > 0 then
            local keys, from = {}, {}
            for _, k in ipairs(OC.pending) do keys[k] = true; from[OC.source[k] or "?"] = true end
            self._orbit_view_keys = keys
            local src = {}
            for s in pairs(from) do table.insert(src, s) end
            table.sort(src)
            self._orbit_paint_source = table.concat(src, "+")
            OC.pending = {}
        end
        local r = stock(self, title, item_table, context, push)
        if OC.full then OC.fullStep("painted") end
        pcall(OC.coverSummary, self)
        return r
    end end, "cache")
    -- Home's first paint from this cache (the dashboard and its sections, assembled by the
    -- plugin's own dashboardRootFetch, nothing asked of the network) instead of the plugin's saved
    -- body; the local overlay goes on top in BoardData.build. Anything not saved -> the plugin's.
    if Compat.callable(Catalog.initialDashboardContext) and Compat.callable(Catalog.dashboardRootFetch) then
        wrap(Catalog, "initialDashboardContext", function(stock) return function(self, ...)
            -- The first paint shows which books are on the reader (Resume, never Download first).
            if LF and LF.primeOnDevice then pcall(LF.primeOnDevice, self) end
            if not OC.on() then return stock(self, ...) end
            OC.cache_only = true
            local prefer = self.prefer_cached_dashboard
            self.prefer_cached_dashboard = nil -- offline too: this cache, not the saved body
            local okf, items, context = pcall(self.dashboardRootFetch, self, { invisible = true })
            self.prefer_cached_dashboard = prefer
            OC.cache_only = nil
            OC.pending = {}
            if okf and type(context) == "table" and type(context.dashboard) == "table" and not context.unavailable then
                context.stale, context.orbit_first = true, true
                self._orbit_paint_source = "cache"
                log("cache: Home's first paint from the cache")
                return items, context
            end
            return stock(self, ...)
        end end, "cache")
    end
    -- Cover jobs dropped by a new view (the plugin's switchTo), for the log.
    if Compat.callable(Catalog.cancelThumbnailJobs) then
        wrap(Catalog, "cancelThumbnailJobs", function(stock) return function(self, ...)
            local q = self.thumbnail_queue
            local n = type(q) == "table" and q.tail and q.head and (q.tail - q.head + 1) or 0
            if n > 0 then log("covers:", n, "queued cover job(s) cancelled by a new view") end
            return stock(self, ...)
        end end, "cache")
    end
    pcall(Mirror.guardPrune, Catalog)
    OC.installed = true
    log("cache: installed (" .. tostring(why) .. ")")
    -- The storage limit, counted on start.
    UIManager:scheduleIn(8, function()
        local okc, err = pcall(OC.storageCount, "start")
        if not okc then log("storage: count failed:", tostring(err)) end
    end)
    UIManager:scheduleIn(5, function()
        pcall(OC.drainEvents)
    end)
    return true
end

do
    local base_init = OrbitAndroid.init
    function OrbitAndroid:init(...)
        local r = base_init(self, ...)
        pcall(OC.install, "init")
        return r
    end
end

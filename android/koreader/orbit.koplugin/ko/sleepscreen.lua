-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- The sleep screen (docs/design/lock-screen.md). KOReader can't draw it on Android, so Orbit
-- Companion does (its screen saver, or a picture the vendor's setting shows). This file supplies
-- what it draws, in koreader/settings/orbit-sleep/ (android/docs/INTERFACE.md "Sleep screen"):
--
--   pool.json, covers/<id>.jpg   Recommended: up to 12 covers in the order they are shown, each
--                                already checked against Leave out. Refreshed in the background
--                                when the network is up anyway (network up, wake, Home), never at
--                                sleep and never in a book.
--   current.png, current.json    Current book: the open book's cover, written once per book at
--                                ReaderReady. It stays after the book closes: "the last book read".
--   state.json                   Written by the companion: the cover it showed and when.
--   bag.lua, leave_out.lua       Ours: the shuffle bag of a smart scope or collection, and the
--                                member lists of Leave out's scope and collection rules.
-- Rules: logic/sleep_pool.lua. Settings: S.sleep_*, shared with the companion through SETTINGS.
---------------------------------------------------------------------------------------------

Sleep = { REFRESH_EVERY_S = 1800, TIMEOUT_S = 240 }

local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")

local function exists(path) return lfs_ok and lfs.attributes(path, "mode") == "file" end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- Atomic: a temp file renamed over the target, so the companion never reads half a file.
local function writeFile(path, s)
    local tmp = path .. ".orbit-new"
    local f = io.open(tmp, "wb")
    if not f then return false end
    local okw = f:write(s)
    f:close()
    if not okw or not os.rename(tmp, path) then os.remove(tmp); return false end
    return true
end
Sleep.writeFile = writeFile

function Sleep.dir()
    if Sleep.base_dir then return Sleep.base_dir end
    local okd, DataStorage = pcall(require, "datastorage")
    if not okd then return nil end
    local d = DataStorage:getSettingsDir() .. "/orbit-sleep"
    if lfs_ok then lfs.mkdir(d); lfs.mkdir(d .. "/covers") end
    Sleep.base_dir = d
    return d
end

function Sleep.settings() return SleepPool.normalize(S) end

-- The companion draws the screen; one without the feature can't (an older release).
function Sleep.available() return Companion.has("sleep_screen") end

function Sleep.on() return Sleep.available() and Sleep.settings().sleep_mode ~= "off" end

-- A sleep setting changed here: saved, sent to the companion, and the pool or the current cover
-- follow. value: already valid (the menu only offers valid values).
function Sleep.set(key, value)
    local was = Sleep.settings()
    Shared.set(key, value)
    local now = Sleep.settings()
    if was.sleep_mode ~= now.sleep_mode or was.sleep_from ~= now.sleep_from
        or table.concat(was.sleep_leave_out, "\n") ~= table.concat(now.sleep_leave_out, "\n") then
        Sleep.changed("setting " .. key)
    end
end

-- The mode, source or rules changed (here or in the companion): fetch again, and the open book's
-- cover is written if it wasn't.
function Sleep.changed(why)
    Sleep.refreshed_at = nil
    if Sleep.on() then
        local ui = liveUI()
        if ui and ui.document then pcall(Sleep.writeCurrent, ui, why) end
        Sleep.kick(why)
    end
end

-- Tells the companion its files changed (it redraws a picture, the dream reads them at sleep).
function Sleep.notify(why)
    if not Sleep.available() then return end
    Companion.send(Companion.ACTION.SLEEP_POOL, { reason = why })
end

---------------------------------------------------------------- files

function Sleep.load(name)
    local d = Sleep.dir()
    local v = d and Cache.decode(readFile(d .. "/" .. name) or "")
    return type(v) == "table" and v or nil
end

function Sleep.save(name, v)
    local d = Sleep.dir()
    return d ~= nil and writeFile(d .. "/" .. name, Cache.encode(v))
end

-- The companion's state.json: { shown = id, changed_at = ms }, or {}.
function Sleep.state()
    local d = Sleep.dir()
    local body = d and readFile(d .. "/state.json")
    if not body then return {} end
    local okj, json = pcall(require, "json")
    local okd, v = okj and pcall(json.decode, body)
    return (okd and type(v) == "table") and v or {}
end

-- The BookOrbit id of a book file on this reader (the plugin's on-device map), or nil.
function Sleep.bookId(path)
    local cat = Mirror and Mirror.catalog and Mirror.catalog()
    if not (path and cat and type(cat.on_device) == "table") then return nil end
    for id, p in pairs(cat.on_device) do
        if p == path then return tonumber(id) end
    end
    return nil
end

---------------------------------------------------------------- Current book (R9)

-- The open book's cover as current.png, once per book (KOReader's own call for it,
-- filemanagerbookinfo.lua:461; the Cover image plugin isn't used: it pads to the screen).
function Sleep.writeCurrent(ui, why)
    if not Sleep.on() then return false end
    local doc = ui and ui.document
    local file = doc and doc.file
    local d = Sleep.dir()
    if not (file and d) then return false end
    if S.sleep_current_file == file and exists(d .. "/current.json") then return false end
    local props = type(ui.doc_props) == "table" and ui.doc_props or {}
    local title = props.display_title or props.title or file:match("([^/]+)$") or ""
    local authors = props.authors and tostring(props.authors):gsub("\n", ", ") or ""
    local okb, BookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
    local bb
    if okb and type(BookInfo) == "table" and type(BookInfo.getCoverImage) == "function" then
        local okc, img = pcall(BookInfo.getCoverImage, BookInfo, doc)
        bb = okc and img or nil
    end
    local has_cover = false
    if bb then
        local tmp = d .. "/current.png.orbit-new"
        local okw, wrote = pcall(bb.writeToFile, bb, tmp, "png")
        pcall(bb.free, bb)
        has_cover = okw and wrote ~= false and exists(tmp) and os.rename(tmp, d .. "/current.png") and true or false
        if not has_cover then os.remove(tmp) end
    end
    if not has_cover then os.remove(d .. "/current.png") end
    local id = Sleep.bookId(file)
    writeFile(d .. "/current.json", SleepPool.json({ v = 1, title = title, authors = authors, path = file,
        id = id, file = has_cover and "current.png" or nil, at = os.time() * 1000 }))
    S.sleep_current_file = file
    saveSettings()
    log("sleep screen: current book", has_cover and "cover written" or "has no cover (the companion draws its title)",
        "(" .. tostring(why) .. ")")
    Sleep.notify("current book")
    return true
end

---------------------------------------------------------------- the pool (R1-R3, X1-X7)

-- Every page of a smart scope's or collection's books, up to max ids (R1b, X5).
-- -> ids, books (id -> list item), or nil, err.
function Sleep.listMembers(client, rule, max)
    local ids, books = {}, {}
    local q = { size = SleepPool.PAGE_SIZE, sort = "recently_added", order = "desc" }
    if rule.kind == "scope" then q.smartScopeId = rule.id else q.collectionId = rule.id end
    for page = 1, math.ceil(max / SleepPool.PAGE_SIZE) do
        q.page = page
        local body, err = client:requestBlocking("GET", client:query("/koreader/plugin/catalog/books", q))
        if type(body) ~= "table" then return nil, tostring(err or "no answer") end
        local items, more = SleepPool.pageItems(body)
        for _, b in ipairs(items) do
            local id = tonumber(b.id)
            if id and not books[id] and #ids < max then table.insert(ids, id); books[id] = b end
        end
        if not more or #ids >= max then break end
    end
    return ids, books
end

function Sleep.detail(client, id)
    local body = client:requestBlocking("GET", "/koreader/plugin/catalog/books/" .. tostring(id))
    return type(body) == "table" and body or nil
end

-- The cover, by its ETag (OC.coverDownload); tests replace it.
function Sleep.download(client, id, path)
    local api = package.loaded["bookorbit_api"]
    local stock = api and (api.__orbit_stock and api.__orbit_stock["cache:downloadCatalogThumbnail"] or api.downloadCatalogThumbnail)
    if not stock then stock = function() return nil, "no plugin download" end end
    local okd, ok = pcall(OC.coverDownload, client, stock, id, path, { temp_path = path .. ".part", max_bytes = 4 * 1024 * 1024 })
    return okd and ok and true or false
end

-- In the background process: lists what is due, picks and checks the books, fetches their covers
-- and writes the files. Returns a short summary for the log.
function Sleep.build(client, plan, rand)
    local d = plan.dir
    local now = plan.now
    local sum = { kept = 0, probed = 0, left_out = 0, unknown = 0, skipped = 0, listed = {} }
    -- Leave out's member lists, once a day (X5).
    local lo = plan.leave_out
    for _, p in ipairs(SleepPool.memberRules(plan.rules)) do
        local e = lo[p.key]
        if not e or SleepPool.due(e.at, now) then
            local ids, err = Sleep.listMembers(client, p, SleepPool.LEAVE_OUT_MAX)
            if ids then
                lo[p.key] = { at = now, ids = ids }
                table.insert(sum.listed, p.key .. "=" .. #ids)
            else
                table.insert(sum.listed, p.key .. " failed (" .. err .. ")")
            end
        end
    end
    -- Keep only the rules still set.
    local members = {}
    for _, p in ipairs(SleepPool.memberRules(plan.rules)) do
        if lo[p.key] then
            local set = {}
            for _, id in ipairs(lo[p.key].ids or {}) do set[id] = true end
            members[p.key] = set
        end
    end
    local keep_lo = {}
    for _, p in ipairs(SleepPool.memberRules(plan.rules)) do keep_lo[p.key] = lo[p.key] end
    Sleep.save("leave_out.lua", keep_lo)

    -- The candidates, in the order they would be shown.
    local candidates, known, source = {}, {}, plan.from_key
    local from = SleepPool.parseFrom(plan.from_key)
    local bag
    if from.kind == "list" then
        local order = { from.type }
        for _, l in ipairs(SleepPool.LISTS) do if l.type ~= from.type then table.insert(order, l.type) end end
        for _, t in ipairs(order) do
            local body = client:requestBlocking("GET", "/koreader/plugin/catalog/dashboard/sections/" .. t)
            local books = SleepPool.sectionBooks(body)
            if #books > 0 then
                for _, b in ipairs(books) do
                    local id = tonumber(b.id)
                    if id then table.insert(candidates, id); known[id] = b end
                end
                if t ~= from.type then sum.fallback = t end
                break
            end
        end
    else
        bag = plan.bag
        if bag.source ~= plan.from_key then bag = { source = plan.from_key, order = {}, pos = 0 } end
        if not bag.at or SleepPool.due(bag.at, now) then
            local ids, err = Sleep.listMembers(client, from, SleepPool.BAG_MAX)
            if ids then
                SleepPool.bagSync(bag, ids, rand)
                bag.at = now
                table.insert(sum.listed, plan.from_key .. "=" .. #ids)
            else
                table.insert(sum.listed, plan.from_key .. " failed (" .. err .. ")")
            end
        end
        SleepPool.bagSeek(bag, plan.shown)
        candidates = SleepPool.bagNext(bag, rand)
    end

    -- Checked one by one, covers fetched for the ones kept.
    local keep = from.kind == "list" and SleepPool.LIST_KEEP or SleepPool.BAG_KEEP
    local items = {}
    local wanted = {}
    local function try(id)
        sum.probed = sum.probed + 1
        local b = known[id]
        local detail
        if not b or SleepPool.needsTags(plan.rules) then
            detail = Sleep.detail(client, id)
            b = b or detail
        end
        local okb = SleepPool.eligible(b, plan.open_id)
        if not okb then sum.skipped = sum.skipped + 1; return end
        local verdict = SleepPool.check(id, plan.rules, members, detail and detail.tags or nil)
        if verdict == "out" then sum.left_out = sum.left_out + 1; return end
        if verdict == "unknown" then sum.unknown = sum.unknown + 1; return end -- fail closed (X7)
        local rel = "covers/" .. id .. ".jpg"
        if Sleep.download(client, id, d .. "/" .. rel) and exists(d .. "/" .. rel) then
            table.insert(items, { id = id, title = tostring(b.title or ""), file = rel })
            wanted[rel] = true
        else
            sum.skipped = sum.skipped + 1
        end
    end
    -- The bag's last shown book stays first, so the companion's "next" is the bag's next.
    if bag and bag.prev and exists(d .. "/covers/" .. bag.prev .. ".jpg") then
        if SleepPool.check(bag.prev, plan.rules, members, nil) == "keep" then
            table.insert(items, { id = bag.prev, title = "", file = "covers/" .. bag.prev .. ".jpg" })
            wanted["covers/" .. bag.prev .. ".jpg"] = true
        end
    end
    local first = #items
    for _, id in ipairs(candidates) do
        if #items - first >= keep or sum.probed >= SleepPool.PROBE_MAX then break end
        try(id)
    end
    -- A bag whose rest is all left out or read: shuffled again, once.
    if bag and #items - first == 0 and #bag.order > 0 and sum.probed < SleepPool.PROBE_MAX then
        bag.pos = #bag.order
        for _, id in ipairs((SleepPool.bagNext(bag, rand))) do
            if #items - first >= keep or sum.probed >= SleepPool.PROBE_MAX then break end
            try(id)
        end
    end
    if bag then Sleep.save("bag.lua", bag) end
    sum.kept = #items - first
    -- Covers no longer in the pool go.
    if lfs_ok and lfs.attributes(d .. "/covers", "mode") == "directory" then
        for name in lfs.dir(d .. "/covers") do
            local rel = "covers/" .. name
            if name:match("^%d+%.jpg$") and not wanted[rel] then
                os.remove(d .. "/" .. rel)
                os.remove(d .. "/" .. rel .. ".etag")
            end
        end
    end
    writeFile(d .. "/pool.json", SleepPool.json(SleepPool.poolDoc(source, items, now * 1000)))
    sum.items = #items
    return sum
end

-- Due: Recommended is on, the network is up, nobody is reading, and the last refresh is older
-- than REFRESH_EVERY_S (or the settings changed since).
function Sleep.kick(why)
    UIManager:scheduleIn(2, function()
        local okr, err = pcall(Sleep.refresh, why)
        if not okr then log("sleep screen: refresh failed:", tostring(err)) end
    end)
end

function Sleep.refresh(why)
    local s = Sleep.settings()
    if Sleep.busy or s.sleep_mode ~= "recommended" or not Sleep.available() then return false end
    local t = os.time()
    if Sleep.refreshed_at and t >= Sleep.refreshed_at and t - Sleep.refreshed_at < Sleep.REFRESH_EVERY_S then return false end
    if not NetworkMgr:isConnected() or reading() then return false end
    local client = OC.client()
    local d = Sleep.dir()
    if not (client and d) then
        log("sleep screen: no BookOrbit client yet; the pool waits (" .. tostring(why) .. ")")
        return false
    end
    local plan = {
        dir = d, now = t, from_key = s.sleep_from, rules = s.sleep_leave_out,
        leave_out = Sleep.load("leave_out.lua") or {}, bag = Sleep.load("bag.lua") or { order = {}, pos = 0 },
        shown = tonumber(Sleep.state().shown), open_id = Sleep.bookId(S.sleep_current_file),
    }
    Sleep.busy = true
    Sleep.refreshed_at = t
    Wifi.acquire("sleep screen")
    log("sleep screen: refreshing the pool from", s.sleep_from, "(" .. tostring(why) .. ")")
    Background.run("sleep screen", function()
        local seed = os.time() + math.floor((os.clock() * 1e6) % 1e6)
        math.randomseed(seed)
        local sum = Sleep.build(client, plan, function(n) return math.random(n) end)
        return Cache.encode(sum)
    end, Sleep.TIMEOUT_S, function(out, berr)
        Sleep.busy = nil
        Wifi.release("sleep screen")
        local sum = Cache.decode(out or "")
        if type(sum) ~= "table" then
            log("sleep screen: pool not refreshed:", tostring(berr or out))
            return
        end
        log(string.format("sleep screen: pool %d cover(s): %d new, %d checked, %d left out, %d unchecked (left out), %d skipped%s%s",
            sum.items or 0, sum.kept or 0, sum.probed or 0, sum.left_out or 0, sum.unknown or 0, sum.skipped or 0,
            sum.fallback and (", from " .. sum.fallback .. " (the chosen list was empty)") or "",
            #(sum.listed or {}) > 0 and (", listed " .. table.concat(sum.listed, " ")) or ""))
        Sleep.notify("pool")
    end)
    return true
end

---------------------------------------------------------------- the pickers

-- The account's smart scopes and collections (picked from the two section lists): from the
-- server when online, else from the cache. cb({ scopes = {…}, collections = {…} } or nil).
function Sleep.scopes(cb)
    local client = OC.client()
    local function cached(section)
        local out = {}
        for key, meta in pairs(OC.index().entries) do
            if meta.path and meta.path:find("^/koreader/plugin/catalog/sections/" .. section) then
                local e = OC.get(key)
                if e then out = SleepPool.entries(e.body) end
                if #out > 0 then break end
            end
        end
        return out
    end
    if not client or not NetworkMgr:isConnected() then
        return cb({ scopes = cached("smart%-scopes"), collections = cached("collections"), cached = true })
    end
    Background.run("sleep screen scopes", function()
        local a = client:requestBlocking("GET", "/koreader/plugin/catalog/sections/smart-scopes")
        local b = client:requestBlocking("GET", "/koreader/plugin/catalog/sections/collections")
        return Cache.encode({ scopes = SleepPool.entries(a), collections = SleepPool.entries(b) })
    end, 30, function(out)
        local v = Cache.decode(out or "")
        if type(v) ~= "table" then
            return cb({ scopes = cached("smart%-scopes"), collections = cached("collections"), cached = true })
        end
        Sleep.scope_names = Sleep.scope_names or {}
        for _, e in ipairs(v.scopes or {}) do Sleep.scope_names["scope:" .. e.id] = e.title end
        for _, e in ipairs(v.collections or {}) do Sleep.scope_names["collection:" .. e.id] = e.title end
        cb(v)
    end)
end

-- Tags from the book details in the cache (X3), with counts. At most max details are read.
function Sleep.cachedTags(max)
    local details = {}
    for key, meta in pairs(OC.index().entries) do
        if #details >= (max or 400) then break end
        if meta.path and meta.path:match("^/koreader/plugin/catalog/books/%d+") and not meta.path:find("/thumbnail", 1, true) then
            local e = OC.get(key)
            if e and type(e.body) == "table" and type(e.body.tags) == "table" then table.insert(details, e.body) end
        end
    end
    return SleepPool.tagCounts(details)
end

-- "Romance (smart scope)", "Scope 12 (not listed)" …
function Sleep.ruleLabel(rule)
    local p = SleepPool.parseRule(rule)
    if not p then return tostring(rule) end
    if p.kind == "tag" then return _("Tag: ") .. p.tag end
    local name = Sleep.scope_names and Sleep.scope_names[p.key]
    local kind = p.kind == "scope" and _("smart scope") or _("collection")
    if name then return string.format("%s (%s)", name, kind) end
    local lo = Sleep.load("leave_out.lua") or {}
    local e = lo[p.key]
    return string.format(_("%s %d (%s)"), p.kind == "scope" and _("Smart scope") or _("Collection"), p.id,
        e and string.format(_("%d books"), #(e.ids or {})) or _("not listed yet"))
end

function Sleep.fromLabel(v)
    local p = SleepPool.parseFrom(v)
    if not p then return "?" end
    if p.kind == "list" then return _(SleepPool.label(SleepPool.LISTS, p.id)) end
    local name = Sleep.scope_names and Sleep.scope_names[v]
    return name or string.format("%s %d", p.kind == "scope" and _("Smart scope") or _("Collection"), p.id)
end

---------------------------------------------------------------- hooks

-- The open book's cover, a moment after it opens (never in the way of the first page).
local base_ready = OrbitAndroid.onReaderReady
function OrbitAndroid:onReaderReady(...)
    local ui = self.ui
    UIManager:scheduleIn(3, function()
        local okw, err = pcall(Sleep.writeCurrent, ui, "book opened")
        if not okw then log("sleep screen: current cover failed:", tostring(err)) end
    end)
    return base_ready(self, ...)
end

---------------------------------------------------------------------------------------------

-- Menu (docs/design/lock-screen.md S2): Tools › Android sync › Sleep screen, behind the Settings
-- PIN with the rest of the Orbit menu.
---------------------------------------------------------------------------------------------

local function radios(list, key, after)
    local out = {}
    for _i, o in ipairs(list) do
        local id = type(o) == "table" and o.id or o
        table.insert(out, {
            text = type(o) == "table" and _(o.label) or (string.format(_("%d h"), o)),
            radio = true,
            checked_func = function() return Sleep.settings()[key] == id end,
            callback = function() Sleep.set(key, id); if after then after(id) end end,
        })
    end
    return out
end

local function info(text_func)
    return { text_func = text_func, keep_menu_open = true, callback = function() end }
end

-- The smart scopes and collections, as menu rows; pick(key) on a tap.
local function scopeRows(pick)
    return function()
        local rows = {}
        local got
        Sleep.scopes(function(v) got = v end)
        if not got then
            -- Fetched in the background: the list fills in when the menu is opened again.
            return { info(function() return _("Loading the smart scopes and collections… open this again in a moment.") end) }
        end
        local function add(title, list, kind)
            table.insert(rows, info(function() return title end))
            if #list == 0 then table.insert(rows, info(function() return _("  none") end)) end
            for _i, e in ipairs(list) do
                local key = kind .. ":" .. e.id
                table.insert(rows, {
                    text = e.count and string.format("%s · %d", e.title, e.count) or e.title,
                    callback = function() pick(key) end,
                })
            end
        end
        add(_("Smart scopes") .. (got.cached and _(" (saved list, offline)") or ""), got.scopes or {}, "scope")
        add(_("Collections"), got.collections or {}, "collection")
        return rows
    end
end

local function addRule(rule)
    local list = {}
    for _i, r in ipairs(Sleep.settings().sleep_leave_out) do table.insert(list, r) end
    table.insert(list, rule)
    Sleep.set("sleep_leave_out", SleepPool.decodeRules(list))
end

local function removeRule(rule)
    local list = {}
    for _i, r in ipairs(Sleep.settings().sleep_leave_out) do if r ~= rule then table.insert(list, r) end end
    Sleep.set("sleep_leave_out", list)
end

-- A one-line input (Text…, Type a tag…). done(text) on Save.
local function askText(title, value, hint, done)
    local okd, InputDialog = pcall(require, "ui/widget/inputdialog")
    if not okd then return end
    local dialog
    dialog = InputDialog:new{
        title = title, input = value or "", input_hint = hint,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local v = dialog:getInputText()
                UIManager:close(dialog)
                done(v)
            end },
        } },
    }
    UIManager:show(dialog) -- gate: user action (menu)
    pcall(dialog.onShowKeyboard, dialog)
end

function Sleep.preview()
    local ok = Jni.startActivity{ action = Companion.ACTION.SLEEP_PREVIEW, package = Companion.PACKAGE } -- gate: user action (menu)
    log("sleep screen: preview", ok and "started" or "FAILED")
end

function Sleep.openCompanion()
    local ok = Jni.startActivity{ action = Companion.ACTION.SHOW_SLEEP, package = Companion.PACKAGE } -- gate: user action (menu)
    log("sleep screen: companion page", ok and "opened" or "FAILED")
end

function Sleep.menuItem(_plugin, later)
    if not Companion.installed() then return false end
    if not Sleep.available() then
        return info(function() return _("Sleep screen: needs a newer Orbit Companion") end)
    end
    local function rec() return Sleep.settings().sleep_mode == "recommended" end
    local function overlay() return Sleep.settings().sleep_style == "overlay" end
    local from_items = radios(SleepPool.LISTS, "sleep_from")
    table.insert(from_items, {
        text_func = function()
            local p = SleepPool.parseFrom(Sleep.settings().sleep_from)
            return _("Smart scope or collection…") .. ((p and p.kind ~= "list") and (": " .. Sleep.fromLabel(Sleep.settings().sleep_from)) or "")
        end,
        checked_func = function() local p = SleepPool.parseFrom(Sleep.settings().sleep_from); return p ~= nil and p.kind ~= "list" end,
        sub_item_table_func = scopeRows(function(key) Sleep.set("sleep_from", key) end),
    })
    local function leaveOutItems()
        local rows = {}
        for _i, r in ipairs(Sleep.settings().sleep_leave_out) do
            table.insert(rows, { text = Sleep.ruleLabel(r) .. _(" · tap to remove"), callback = function() removeRule(r) end })
        end
        if #rows == 0 then table.insert(rows, info(function() return _("No rules: every cover can show.") end)) end
        rows[#rows].separator = true
        table.insert(rows, {
            text = _("Add a rule: Tag…"),
            sub_item_table_func = function()
                local out = {}
                for _i, t in ipairs(Sleep.cachedTags(400)) do
                    table.insert(out, { text = string.format("%s · %d", t.label, t.count), callback = function() addRule("tag:" .. t.tag) end })
                    if #out >= 60 then break end
                end
                table.insert(out, 1, { text = _("Type a tag…"), separator = true, callback = later(function()
                    askText(_("Leave out books with the tag"), "", _("e.g. age:18"), function(v)
                        local p = SleepPool.parseRule("tag:" .. tostring(v or ""))
                        if p then addRule(p.key) end
                    end)
                end) })
                return out
            end,
        })
        table.insert(rows, { text = _("Add a rule: Smart scope or collection…"),
            sub_item_table_func = scopeRows(function(key) addRule(key) end) })
        table.insert(rows, info(function()
            return _("For a custom field: make a smart scope with that condition in BookOrbit, then add it here.")
        end))
        return rows
    end
    return {
        text = _("Sleep screen"),
        sub_item_table_func = function()
            return {
                {
                    text_func = function() return _("Sleep screen: ") .. _(SleepPool.label(SleepPool.MODES, Sleep.settings().sleep_mode)) end,
                    sub_item_table = radios(SleepPool.MODES, "sleep_mode"),
                },
                {
                    text_func = function() return _("Pick from: ") .. Sleep.fromLabel(Sleep.settings().sleep_from) end,
                    enabled_func = rec,
                    sub_item_table = from_items,
                },
                {
                    text_func = function()
                        local n = #Sleep.settings().sleep_leave_out
                        return n == 0 and _("Leave out: nothing") or string.format(n == 1 and _("Leave out: %d rule") or _("Leave out: %d rules"), n)
                    end,
                    enabled_func = rec,
                    sub_item_table_func = leaveOutItems,
                },
                {
                    text_func = function() return string.format(_("Change cover every: %d h"), Sleep.settings().sleep_hours) end,
                    enabled_func = rec,
                    sub_item_table = radios(SleepPool.HOURS, "sleep_hours"),
                    separator = true,
                },
                {
                    text_func = function()
                        local t = Sleep.settings().sleep_text
                        return _("Text: ") .. (t == "" and _("none") or t)
                    end,
                    keep_menu_open = true,
                    callback = function()
                        askText(_("Sleep screen text (up to 60 characters)"), Sleep.settings().sleep_text, _("e.g. Please return to the front desk"),
                            function(v) Sleep.set("sleep_text", SleepPool.cleanText(v)) end)
                    end,
                },
                {
                    text = _("Show battery level"),
                    checked_func = function() return Sleep.settings().sleep_battery end,
                    callback = function() Sleep.set("sleep_battery", not Sleep.settings().sleep_battery) end,
                },
                {
                    text_func = function() return _("Style: ") .. _(SleepPool.label(SleepPool.STYLES, Sleep.settings().sleep_style)) end,
                    sub_item_table = radios(SleepPool.STYLES, "sleep_style"),
                },
                {
                    text_func = function() return _("Text position: ") .. _(SleepPool.label(SleepPool.TEXT_POSITIONS, Sleep.settings().sleep_text_position)) end,
                    enabled_func = overlay,
                    sub_item_table = radios(SleepPool.TEXT_POSITIONS, "sleep_text_position"),
                },
                {
                    text_func = function()
                        local s = Sleep.settings()
                        local t = _("Battery corner: ") .. _(SleepPool.label(SleepPool.CORNERS, s.sleep_battery_corner))
                        local moved = SleepPool.batteryCorner(s.sleep_battery_corner, s.sleep_text_position)
                        if s.sleep_text ~= "" and moved ~= s.sleep_battery_corner then
                            t = t .. string.format(_(" (moves to %s beside the text)"), _(SleepPool.label(SleepPool.CORNERS, moved)):lower())
                        end
                        return t
                    end,
                    enabled_func = overlay,
                    sub_item_table = radios(SleepPool.CORNERS, "sleep_battery_corner"),
                    separator = true,
                },
                {
                    text_func = function() return _("Shown by: ") .. (Shared.sleep_shown_by or _("Orbit Companion")) end,
                    callback = later(function() Sleep.openCompanion() end),
                },
                { text = _("Preview"), enabled_func = function() return Sleep.settings().sleep_mode ~= "off" end,
                  callback = later(function() Sleep.preview() end) },
            }
        end,
        separator = true,
    }
end

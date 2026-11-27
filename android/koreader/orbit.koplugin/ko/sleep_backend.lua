-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- The sleep screen (docs/design/lock-screen.md). KOReader can't draw it on Android, so Orbit
-- Companion does (its screen saver, or a picture the vendor's setting shows). This file supplies
-- what it draws, in koreader/settings/orbit-sleep/ (android/docs/INTERFACE.md "Sleep screen"):
--
--   pool.json, covers/<id>.jpg   Recommended: up to 24 covers in the order they are shown, each
--                                already checked against Leave out. Orbit Companion refreshes them
--                                when asked (SLEEP_REFRESH) while the network is up anyway (network
--                                up, wake, Home), never at sleep and never in a book.
--   current.png, current.json    Current book: the open book's cover, written once per book at
--                                ReaderReady. It stays after the book closes: "the last book read".
--   state.json                   Written by the companion: the cover it showed and when.
--   scopes.json, tags.json       The companion's: every list and collection, and the tags in
--                                the saved book details, with counts, for the pickers (Pick from,
--                                Leave out); refreshed when one opens and with the pool.
--   bag.lua, leave_out.lua       The companion's: the shuffle bag of a list or collection, and
--                                the member lists of Leave out's scope and collection rules.
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

-- Back from a real sleep: the companion moves the picture on for the next one (Every sleep on
-- a reader that shows a picture). Its service hears the screen come on too; without the service
-- (Add-on mode) this is the wake it hears. It counts one wake once (SleepWake).
function Sleep.woke()
    if not Sleep.on() then return end
    Companion.send(Companion.ACTION.SLEEP_POOL, { reason = "wake", wake = "1" })
end

---------------------------------------------------------------- files

function Sleep.load(name)
    local d = Sleep.dir()
    local v = d and Cache.decode(readFile(d .. "/" .. name) or "")
    return type(v) == "table" and v or nil
end

-- A JSON file of ours or the companion's, decoded, or nil.
-- (Not `okj and pcall(...)`: `and` keeps only pcall's first result, so the value was always lost.)
local function readJson(path)
    local body = path and readFile(path)
    if not body then return nil end
    local okj, json = pcall(require, "json")
    if not okj then return nil end
    local okd, v = pcall(json.decode, body)
    return (okd and type(v) == "table") and v or nil
end

function Sleep.bookId(path) return Library.localBookReference(path) end

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

-- Orbit Companion refreshes the pool on its worker thread (SleepPoolBuilder.kt; docs/design/
-- companion-worker.md): lists what is due, picks and checks the books, fetches their covers and
-- writes pool.json, covers/, bag.lua, leave_out.lua and scopes.json, then redraws its picture.
-- KOReader asks (SLEEP_REFRESH) and hears a sleep_pool event when it is done.

-- Due: Recommended is on, the network is up, nobody is reading, and the last refresh is older
-- than REFRESH_EVERY_S (or the settings changed since).
function Sleep.kick(why)
    UIManager:scheduleIn(2, function()
        local okr, err = pcall(Sleep.refresh, why)
        if not okr then log("sleep screen: refresh failed:", tostring(err)) end
    end)
end

-- The login travels only in the caller-checked call to the verified companion (Companion.send), never in a file.
local function ask(extras) return Library.sleepRefresh(extras) end

function Sleep.refresh(why)
    local s = Sleep.settings()
    if Sleep.asked or s.sleep_mode ~= "recommended" or not Sleep.available() then return false end
    local t = os.time()
    if Sleep.refreshed_at and t >= Sleep.refreshed_at and t - Sleep.refreshed_at < Sleep.REFRESH_EVERY_S then return false end
    if not NetworkMgr:isConnected() or reading() then return false end
    local problem = Companion.workerProblem(_("for the sleep screen's covers"))
    if problem then
        if Sleep.problem ~= problem then Sleep.problem = problem; log("sleep screen: pool not refreshed:", problem) end
        return false
    end
    Sleep.problem = nil
    local available=(Library.cachedAccountState().catalog or {}).canRefresh==true
    if not (available and Sleep.dir()) then
        log("sleep screen: no library client yet; the pool waits (" .. tostring(why) .. ")")
        return false
    end
    Sleep.asked, Sleep.refreshed_at = Store.now(), t
    Wifi.acquire("sleep screen")
    log("sleep screen: the companion refreshes the pool from", s.sleep_from, "(" .. tostring(why) .. ")")
    ask({ reason = tostring(why), from = s.sleep_from, rules = SleepPool.encodeRules(s.sleep_leave_out),
        open_id = tostring(Sleep.bookId(S.sleep_current_file) or ""), every = s.sleep_hours == SleepPool.EVERY_SLEEP and "1" or "0",
        storage_limit_mb = tostring(tonumber(S.storage_limit_mb) or Cache.STORAGE_DEFAULT_MB) })
    return true
end

-- The companion's answer (a sleep_pool event): the pool, or the pickers' lists only.
function Sleep.landed(ev)
    Sleep.tags_cache = nil
    if ev.scopes_only then
        Sleep.scopes_asked = nil
        Sleep.scopes_cache = nil
        local v = Sleep.scopes()
        if v then log(string.format("sleep screen: %d list(s), %d collection(s) listed", #v.scopes, #v.collections))
        else Sleep.scopes_at = nil; log("sleep screen: scopes and collections not listed:", tostring(ev.err or "no answer")) end
        local done = Sleep.scopes_done
        Sleep.scopes_done = nil
        if done then done(v) end
        return
    end
    if Sleep.asked then Sleep.asked = nil; Wifi.release("sleep screen") end
    if ev.err then return log("sleep screen: pool not refreshed:", tostring(ev.err)) end
    log(string.format("sleep screen: pool %d cover(s): %d new, %d checked, %d left out, %d unchecked (left out), %d skipped%s%s%s",
        tonumber(ev.items) or 0, tonumber(ev.kept) or 0, tonumber(ev.probed) or 0, tonumber(ev.left_out) or 0, tonumber(ev.unknown) or 0,
        tonumber(ev.skipped) or 0,
        ev.every and string.format(", every sleep: %d kept, %d retired", tonumber(ev.carried) or 0, tonumber(ev.retired) or 0) or "",
        ev.fallback and (", from " .. tostring(ev.fallback) .. " (the chosen list was empty)") or "",
        type(ev.listed) == "table" and #ev.listed > 0 and (", listed " .. table.concat(ev.listed, " ")) or ""))
    if ev.scopes then Sleep.scopes_cache = nil; Sleep.scopes() end
end

-- No answer in time: the Wi-Fi hold goes and the next trigger asks again.
function Sleep.waited(t)
    if Sleep.asked and t - Sleep.asked >= Sleep.TIMEOUT_S then
        log("sleep screen: the companion didn't answer the pool refresh")
        Sleep.asked = nil
        Wifi.release("sleep screen")
    end
    if Sleep.scopes_asked and t - Sleep.scopes_asked >= Sleep.SCOPES_WAIT_S then
        Sleep.scopes_asked = nil
        Sleep.landed({ scopes_only = true, err = "the companion didn't answer" })
    end
    return Sleep.asked ~= nil or Sleep.scopes_asked ~= nil
end

---------------------------------------------------------------- the pickers

-- The account's lists and collections, for Pick from and Leave out: every entry of the two
-- section lists, with counts. Saved in scopes.json ({ v, at, scopes = {…}, collections = {…} },
-- entries { id, title, count }) so a picker opens at once, offline too; refreshed in the
-- background each time a picker opens and at each pool refresh.
Sleep.SCOPES_FILE = "scopes.json"
Sleep.SCOPES_EVERY_S = 60
Sleep.SCOPES_WAIT_S = 60

local function remember(v)
    Sleep.scope_names = Sleep.scope_names or {}
    for _i, e in ipairs(v.scopes or {}) do Sleep.scope_names["scope:" .. e.id] = e.title end
    for _i, e in ipairs(v.libraries or {}) do Sleep.scope_names["library:" .. e.id] = e.title end
    for _i, e in ipairs(v.collections or {}) do Sleep.scope_names["collection:" .. e.id] = e.title end
end

function Sleep.saveScopes(v)
    if type(v) ~= "table" or type(v.scopes) ~= "table" or type(v.collections) ~= "table" then return false end
    remember(v)
    Sleep.scopes_cache = v
    local d = Sleep.dir()
    return d ~= nil and writeFile(d .. "/" .. Sleep.SCOPES_FILE, SleepPool.json(v))
end

-- The saved lists, or nil before the first fetch.
function Sleep.scopes()
    if Sleep.scopes_cache then return Sleep.scopes_cache end
    local d = Sleep.dir()
    local v = readJson(d and (d .. "/" .. Sleep.SCOPES_FILE))
    if not (v and type(v.scopes) == "table" and type(v.collections) == "table") then return nil end
    local clean = { v = 1, at = tonumber(v.at), scopes = SleepPool.entries({ items = v.scopes }), collections = SleepPool.entries({ items = v.collections }), libraries = SleepPool.entries({ items = v.libraries }) }
    remember(clean)
    Sleep.scopes_cache = clean
    return clean
end

-- The companion lists both again when online; done(v or nil) after.
function Sleep.refreshScopes(why, done)
    local available=(Library.cachedAccountState().catalog or {}).canRefresh==true
    local t = os.time()
    if Sleep.scopes_asked or not available or not NetworkMgr:isConnected() or Companion.workerProblem()
        or (Sleep.scopes_at and t >= Sleep.scopes_at and t - Sleep.scopes_at < Sleep.SCOPES_EVERY_S) then
        if done then done(nil) end
        return false
    end
    Sleep.scopes_asked, Sleep.scopes_at, Sleep.scopes_done = Store.now(), t, done
    ask({ reason = tostring(why), scopes_only = "1" })
    return true
end

-- Leave out's tag picker (X3): the tags in the saved book details, with counts, as the companion
-- counted them (tags.json, refreshed with the pickers' lists). Nothing is read here but that file.
Sleep.TAGS_FILE = "tags.json"
function Sleep.tags()
    if Sleep.tags_cache then return Sleep.tags_cache end
    local d = Sleep.dir()
    local v = readJson(d and (d .. "/" .. Sleep.TAGS_FILE))
    if not (v and type(v.tags) == "table") then return nil end
    local out = {}
    for _i, t in ipairs(v.tags) do
        if type(t) == "table" and type(t.tag) == "string" and t.tag ~= "" then
            table.insert(out, { tag = t.tag, label = tostring(t.label or t.tag), count = tonumber(t.count) or 0 })
        end
    end
    Sleep.tags_cache = out
    return out
end

-- "Romance (list)", "Scope 12 (not listed)" …
function Sleep.ruleLabel(rule)
    local p = SleepPool.parseRule(rule)
    if not p then return tostring(rule) end
    if p.kind == "tag" then return _("Tag: ") .. p.tag end
    if p.kind == "library" and not p.id then return _("Library (every book)") end
    if not Sleep.scope_names then Sleep.scopes() end
    local name = Sleep.scope_names and Sleep.scope_names[p.key]
    local kind = p.kind == "library" and _("library") or (p.kind == "scope" and _("list") or _("collection"))
    if name then return string.format("%s (%s)", name, kind) end
    local lo = Sleep.load("leave_out.lua") or {}
    local e = lo[p.key]
    return string.format(_("%s %d (%s)"), p.kind == "library" and _("Library") or (p.kind == "scope" and _("List") or _("Collection")), p.id,
        e and string.format(_("%d books"), #(e.ids or {})) or _("not listed yet"))
end

-- Pick from in words: one item's name, or the items' names joined (R1c).
function Sleep.fromLabel(v)
    local items = SleepPool.sources(v)
    if #items > 1 then
        local names = {}
        for _i, it in ipairs(items) do table.insert(names, Sleep.fromLabel(it)) end
        return table.concat(names, ", ")
    end
    v = items[1]
    local p = SleepPool.parseFrom(v)
    if not p then return "?" end
    if p.kind == "library" and not p.id then return _("Whole library") end
    if p.kind == "list" then return _(SleepPool.label(SleepPool.LISTS, p.id)) end
    if not Sleep.scope_names then Sleep.scopes() end
    local name = Sleep.scope_names and Sleep.scope_names[v]
    return name or string.format("%s %d", p.kind == "library" and _("Library") or (p.kind == "scope" and _("List") or _("Collection")), p.id)
end

---------------------------------------------------------------- hooks

-- The open book's cover, a moment after it opens (never in the way of the first page).
-- Menu (docs/design/lock-screen.md S2): Tools › BookSync › Sleep screen, behind the Settings
-- PIN with the rest of the Orbit menu.
---------------------------------------------------------------------------------------------

function Sleep.preview()
    local ok = Jni.startActivity{ action = Companion.ACTION.SLEEP_PREVIEW, package = Companion.PACKAGE } -- gate: user action (menu)
    log("sleep screen: preview", ok and "started" or "FAILED")
end

function Sleep.openCompanion()
    local ok = Jni.startActivity{ action = Companion.ACTION.SHOW_SLEEP, package = Companion.PACKAGE } -- gate: user action (menu)
    log("sleep screen: companion page", ok and "opened" or "FAILED")
end


function Sleep.menuItem(...) return Library.sleep.menuItem(...) end

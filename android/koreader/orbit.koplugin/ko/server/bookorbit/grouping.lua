-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Lists by series and by author (v0.6.0): the KOReader side of Group. The plugin's own views
-- draw everything; the patch wraps methods on its catalog class (bookorbit_catalog.lua; the
-- list methods are copied onto that class by CatalogLists.install, bookorbit_catalog_lists.lua
-- :1492-1496, so wrapping CatalogLists would change nothing) and on its API class
-- (bookorbit_api.lua). Each wrapper passes through unchanged unless its own mark is there:
--   - a list's Sort sheet (listSortSheetModel, :659; rows :707-713) gets "By series" and
--     "By author" (action orbit-group) on every book list: a library, collection, smart scope,
--     On device, and the whole library's lists (All books, Recently updated; v0.11.2);
--   - orbit-group reads the list's books once (catalogBooks, 100 a page, "Reading N of M
--     books…"), holds them (Group.remember), and opens the plugin's Series or Authors view
--     (loadSection, bookorbit_catalog.lua:974) for them: listSectionParams (:246) hands the
--     request to fetch (:881), which answers it from the held books (Group.sectionBody), and
--     switchTo (:847) tags the context with orbit_group, so paging, the A-Z rail, sort, the
--     filter and reloads (reloadSection :1047, listReload :336) all keep working;
--   - listRun (:739) opens a row in the list (open-series / open-author), and the chips;
--   - listHeader (:1155) and listToolbar (:1115) say which list, and carry the chips;
--   - the API's query (:386) never sends the patch's orbit* marks; catalogBooks (:714) and
--     catalogManifest (:720) answer orbitLocal (a smart scope's row past 200 books) from the
--     held books.
---------------------------------------------------------------------------------------------
Grouping = { installed = false }

function bookCount(n)
    return n == 1 and "1 book" or string.format("%d books", n)
end

-- The held list a context belongs to: from its orbit_group, or its request's orbitGroup.
function heldOf(context)
    context = context or {}
    local token = (context.orbit_group and context.orbit_group.token) or (context.params and context.params.orbitGroup)
    return token and Group.held[token] or nil, token
end

-- Reads every book of the current list (inside a connected job), then opens the grouped view.
function Grouping.start(cat, section)
    local context = cat.current_context or {}
    local params = context.params or {}
    local list = Group.listOf(params)
    if not list then return end
    local function open(token)
        cat:loadSection(section, { orbit_group = { token = token, section = section } })
    end
    if context.orbit_snapshot and Group.held[context.orbit_snapshot] then
        return open(context.orbit_snapshot)
    end
    cat:runConnected(function()
        local t0 = now_s()
        local books, total, page = {}, nil, 1
        while true do
            local label = total and string.format("Reading %d of %d books…", #books, total) or "Reading the list…"
            local q = Group.fetchParams(params, page)
            local body, err = cat:fetch(label, function() return cat.client:catalogBooks(q) end)
            if not body then
                if err ~= "cancelled" then
                    cat:showRetry(err, function() Grouping.start(cat, section) end)
                end
                return
            end
            local items = body.items or {}
            for _, b in ipairs(items) do table.insert(books, b) end
            total = tonumber(body.total) or total
            if #items == 0 or (total and #books >= total) or body.hasNext == false then break end
            page = page + 1
        end
        local token = Group.remember({ list = list, params = params, title = context.title or "", books = books })
        context.orbit_snapshot = token
        log("lists: read", #books, "books of", list.section, tostring(list.id or ""), "for", section,
            string.format("in %d ms (%d page(s))", math.floor((now_s() - t0) * 1000 + 0.5), page))
        UIManager:nextTick(function() open(token) end)
    end)
end

-- Opens a row of a grouped view: a series' books (in the list), an author's books by series.
function Grouping.openRow(cat, kind, entry)
    local context = cat.current_context or {}
    local og = context.orbit_group
    local snap = Group.held[og.token]
    if not snap then return false end
    if kind == "open-author" then
        cat:loadSection("series", { orbit_group = { token = og.token, section = "series", author = entry.title } })
        return true
    end
    local key = entry.orbitKey
    local books = Group.select(snap.books, og.author, key)
    local marks = { orbitGroup = og.token, orbitAuthor = og.author, orbitSeries = key }
    local target, flat
    if key == Group.STANDALONE then
        target, flat = { sort = "title" }, true
    else
        target = cat:paramsForEntry("series", entry)
        if og.author then target.author = og.author end
    end
    local p, how = Group.drill(snap.list, snap.params, books, target, marks, flat)
    log("lists: open", entry.title, "in", snap.list.section, tostring(snap.list.id), "(" .. how .. ", " .. #books .. " books)")
    cat:loadBooks(p, entry.title, true)
    return true
end

-- The chips: an author's books by series, all of them flat, or the author with no list.
function Grouping.chip(cat, chip)
    local context = cat.current_context or {}
    local params = context.params or {}
    local snap, token = heldOf(context)
    local author = (context.orbit_group and context.orbit_group.author) or params.orbitAuthor
    if chip == "whole-series" then
        local whole = { sort = "series", seriesId = params.seriesId, series = params.series }
        return cat:loadBooks(whole, context.title, true)
    end
    if chip == "all-by-author" and author then
        return cat:loadBooks({ author = author, sort = "series" }, author, true)
    end
    if not snap or not author then return end
    if chip == "by-series" then
        return cat:loadSection("series", { orbit_group = { token = token, section = "series", author = author }, replace = true })
    end
    if chip == "all-books" then
        local books = Group.select(snap.books, author, nil)
        local p = Group.drill(snap.list, snap.params, books, { sort = "title" }, { orbitGroup = token, orbitAuthor = author }, true)
        return cat:loadBooks(p, author, false)
    end
end

function chipButton(label, on, chip, icon)
    return { icon = icon, label = label, on = on, action = { kind = "orbit-chip", chip = chip }, key = "orbit-" .. chip }
end

function authorChips(on)
    return {
        chipButton("By series", on == "by-series", "by-series", "layers-2"),
        chipButton("All books", on == "all-books", "all-books", "book"),
        chipButton("All by author", false, "all-by-author", "user"),
    }
end

-- Wraps one class method once per feature; the function it wrapped stays callable as
-- Cls.__orbit_stock[key] (key: the method name for grouping, "<feature>:<name>" otherwise).
-- Features share one chain per method, in install order: grouping (at init) first, then
-- local-first and end of book (docs/design/local-first/DESIGN.md "Sharing hooks").
function wrap(Cls, name, make, feature)
    local stock = rawget(Cls, "__orbit_stock") or {}
    rawset(Cls, "__orbit_stock", stock)
    local key = feature and (feature .. ":" .. name) or name
    if stock[key] then return end
    stock[key] = Cls[name]
    Cls[name] = make(stock[key])
end

function Grouping.install(why)
    if Grouping.installed then return true end
    local Catalog = package.loaded["bookorbit_catalog"]
    local Api = package.loaded["bookorbit_api"]
    if type(Catalog) ~= "table" or type(Api) ~= "table" then return false end
    local missing = {}
    for _, m in ipairs(Compat.missingOn(Catalog, Compat.CATALOG_CLASS)) do table.insert(missing, m) end
    for _, m in ipairs(Compat.missingOn(Api, Compat.API_CLASS)) do table.insert(missing, "api." .. m) end
    if #missing > 0 then
        if not compat_logged.grouping then
            compat_logged.grouping = true
            log("compat: lists by series and author off (plugin changed): missing " .. table.concat(missing, ", "))
        end
        return false
    end
    Grouping.installed = true

    wrap(Api, "query", function(stock) return function(self, path, params)
        return stock(self, path, Group.strip(params))
    end end)
    wrap(Api, "catalogBooks", function(stock) return function(self, params)
        if type(params) == "table" and params.orbitLocal == "1" then
            local books = Group.localBooks(params)
            if not books then return nil, 404 end
            return Group.booksBody(books, params)
        end
        return stock(self, params)
    end end)
    wrap(Api, "catalogManifest", function(stock) return function(self, params)
        if type(params) == "table" and params.orbitLocal == "1" then
            local books = Group.localBooks(params)
            if not books then return nil, 404 end
            local p = Group.strip(params)
            p.ids = Group.ids(books, Group.MANIFEST_IDS_MAX)
            return stock(self, p)
        end
        return stock(self, params)
    end end)

    wrap(Catalog, "listSortSheetModel", function(stock) return function(self, sheet)
        local m = stock(self, sheet)
        local context = self.current_context or {}
        local params = context.params or {}
        if type(m) == "table" and type(m.rows) == "table" and self:listKind() == "books"
            and Group.listOf(params) and not params.orbitGroup then
            table.insert(m.rows, 1, { icon = "user", label = "By author", value = "authors in this list", chevron = true,
                action = { kind = "orbit-group", section = "authors" }, key = "orbit-authors" })
            table.insert(m.rows, 1, { icon = "layers-2", label = "By series", value = "series in this list", chevron = true,
                action = { kind = "orbit-group", section = "series" }, key = "orbit-series" })
        end
        return m
    end end)

    wrap(Catalog, "listRun", function(stock) return function(self, action, region, hold)
        local context = self.current_context or {}
        local kind = type(action) == "table" and action.kind
        if not hold and kind == "orbit-group" then
            context.list_sheet = nil
            pcall(self.updateItems, self, nil, true) -- the sheet closes while the list is read
            return Grouping.start(self, action.section)
        elseif not hold and kind == "orbit-chip" then
            return Grouping.chip(self, action.chip)
        elseif not hold and (kind == "open-series" or kind == "open-author") and context.orbit_group
            and not context.dashboard_source_index and action.entry then
            if Grouping.openRow(self, kind, action.entry) then return end
        end
        return stock(self, action, region, hold)
    end end)

    -- A grouped view's request: marked by loadSection, taken by listSectionParams, answered by fetch.
    wrap(Catalog, "loadSection", function(stock) return function(self, section, opts)
        opts = opts or {}
        local og = opts.orbit_group
        local cur = self.current_context or {}
        if not og and opts.replace and cur.kind == "section" and cur.section == section and cur.orbit_group then
            og = cur.orbit_group
        end
        self._orbit_pending = og and Group.held[og.token] and { section = section, group = og } or nil
        return stock(self, section, opts)
    end end)
    wrap(Catalog, "listSectionParams", function(stock) return function(self, section, opts)
        local params = stock(self, section, opts)
        local pend = self._orbit_pending
        self._orbit_pending = nil
        if pend and pend.section == section then self._orbit_next = { group = pend.group, params = params or {} } end
        return params
    end end)
    wrap(Catalog, "fetch", function(stock) return function(self, text, fn, opts)
        local nxt = self._orbit_next
        if nxt then
            self._orbit_next = nil
            local snap = Group.held[nxt.group.token]
            if snap then
                local og = nxt.group
                local t0 = os.clock()
                -- The groups are built once per held list (and author); paging, sort and filter
                -- reuse them.
                snap.rows = snap.rows or {}
                local rk = og.section .. "|" .. tostring(og.author or "")
                local built = snap.rows[rk]
                if not built then
                    local books = og.author and Group.select(snap.books, og.author, nil) or snap.books
                    built = { rows = og.section == "authors" and Group.authors(books) or Group.series(books),
                        extra = og.author and Group.standalone(books) or nil }
                    snap.rows[rk] = built
                    log(string.format("lists: grouped %d books of %s by %s in %d ms", #snap.books, tostring(snap.list.section),
                        og.section == "authors" and "author" or "series", math.floor((os.clock() - t0) * 1000 + 0.5)))
                end
                self._orbit_tag = og
                return Group.sectionBody(built.rows, og.section, nxt.params, built.extra)
            end
        end
        return stock(self, text, fn, opts)
    end end)
    wrap(Catalog, "switchTo", function(stock) return function(self, title, item_table, context, push)
        local tag = self._orbit_tag
        self._orbit_tag = nil
        if tag and type(context) == "table" and context.kind == "section" then context.orbit_group = tag end
        return stock(self, title, item_table, context, push)
    end end)

    wrap(Catalog, "listHeader", function(stock) return function(self, kind, context)
        local h = stock(self, kind, context)
        local snap = heldOf(context)
        if type(h) ~= "table" or not snap or h.select then return h end
        local name = snap.title ~= "" and snap.title or "this list"
        local og = context.orbit_group
        if og and og.author then
            local n = #Group.select(snap.books, og.author, nil)
            h.title, h.title_data = og.author, true
            h.sub = string.format("%s in %s · by series", bookCount(n), name)
        elseif og then
            h.title = string.format(og.section == "authors" and "Authors in %s" or "Series in %s", name)
            h.title_data = true
        elseif kind == "seriespage" or kind == "books" then
            local n = tonumber(context.total) or #(context.books or {})
            if kind == "seriespage" then
                local summary = context.series_summary or {}
                n = tonumber(summary.total) or n
                local b = context.books and context.books[1]
                local who = b and b.authors and b.authors[1]
                h.sub = (who and (who .. " · ") or "") .. string.format("%s in %s", bookCount(n), name)
            else
                local sort = Compat.callable(self.listSortLabel) and (" · " .. self:listSortLabel(context.params or {})) or ""
                h.sub = string.format("%s in %s", bookCount(n), name) .. sort
            end
        end
        return h
    end end)

    wrap(Catalog, "listToolbar", function(stock) return function(self, kind, context)
        local buttons = stock(self, kind, context)
        local snap = heldOf(context)
        if not snap then return buttons end
        local og = context.orbit_group
        local params = context.params or {}
        if og and og.author then return authorChips("by-series") end
        if kind == "books" and params.orbitAuthor and not params.orbitSeries then return authorChips("all-books") end
        if kind == "seriespage" then
            buttons = type(buttons) == "table" and buttons or {}
            table.insert(buttons, chipButton("Whole series", false, "whole-series", "layers-2"))
        end
        return buttons
    end end)

    log("lists: by series and by author on (" .. tostring(why) .. ")")
    return true
end

---------------------------------------------------------------------------------------------

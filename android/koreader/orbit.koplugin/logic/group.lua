-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Lists by series and by author (v0.6.0, android/docs/DESIGN.md "Lists by series and by author").
-- BookOrbit's Series and Authors views are server-wide: its sections endpoint takes no list
-- (KoreaderCatalogSectionQueryDto whitelists q, page, offset, size, sort, filter). So the
-- patch reads a list's books once and groups them here, in the section shape the plugin draws
-- (bookorbit_list_data.lua:195-225: count, readingCount, finishedCount, memberStates,
-- authorNames, previewBooks, letter), with the server's semantics copied from
-- opds-book.service.ts: read buckets (:115-118, readStatusBucket :193-198), the series and
-- author filters (:711, :793-797), the name and "most books" orders (:211-231), the A-Z letter
-- (latinJumpBucketExpr :200-205) and buckets (first row of each letter, :865-877), series
-- members in series order with the first author of each (:965-1035, 40 states, 2 names,
-- 3 previews), author previews reading, then finished, then newest (:899-960) and an author's
-- series line (their series with the most books, :885-897). Pure (tested).
---------------------------------------------------------------------------------------------
Group = { PAGE = 100, IDS_MAX = 200, MANIFEST_IDS_MAX = 500, PREVIEWS = 3, MEMBER_STATES = 40,
    AUTHOR_NAMES = 2, SECTION_SIZE = 60, STANDALONE = "orbit:standalone", SNAPSHOTS = 6 }

READING_STATUS = { reading = true, rereading = true, on_hold = true }
FINISHED_STATUS = { read = true, skimmed = true, abandoned = true }

function Group.bucket(status)
    if READING_STATUS[status] then return "reading" end
    if FINISHED_STATUS[status] then return "finished" end
    return "unread"
end

-- Latin-1 letters with accents, folded (UTF-8 pairs), as bookorbit_unaccent does for these.
FOLD = {}
for from, to in pairs({ A = "ÀÁÂÃÄÅàáâãäå", C = "Çç", E = "ÈÉÊËèéêë", I = "ÌÍÎÏìíîï", N = "Ññ",
    O = "ÒÓÔÕÖØòóôõöø", U = "ÙÚÛÜùúûü", Y = "Ýýÿ" }) do
    for ch in to:gmatch("[\192-\223][\128-\191]") do FOLD[ch] = to:find(ch, 1, true) and from end
end
-- Lower case, accents folded, spaces trimmed: the key names compare and match by.
function Group.fold(s)
    s = tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("[\192-\223][\128-\191]", function(ch) return FOLD[ch] or ch end)
    return s:lower()
end

-- "A".."Z" for a name starting with a (folded) letter, else "#".
function Group.letter(name)
    local c = Group.fold(name):sub(1, 1)
    if c:match("^[a-z]$") then return c:upper() end
    return "#"
end

-- A book's series: its id, or (an older server sends no seriesId) its name. nil: no series.
function Group.seriesKey(book)
    if book.seriesId ~= nil then return "id:" .. tostring(book.seriesId) end
    local name = book.seriesName
    if type(name) == "string" and name:match("%S") then return "name:" .. Group.fold(name) end
    return nil
end

-- Series order: the index as a number, then as text, missing last; then title, then id.
function Group.bySeriesIndex(a, b)
    local ia, ib = tonumber(a.seriesIndex), tonumber(b.seriesIndex)
    if ia ~= ib then
        if ia == nil then return false end
        if ib == nil then return true end
        return ia < ib
    end
    local sa, sb = tostring(a.seriesIndex or ""), tostring(b.seriesIndex or "")
    if sa ~= sb then return sa < sb end
    local ta, tb = Group.fold(a.title), Group.fold(b.title)
    if ta ~= tb then return ta < tb end
    return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
end

function counts(books)
    local reading, finished = 0, 0
    for _, b in ipairs(books) do
        local k = Group.bucket(b.readStatus)
        if k == "reading" then reading = reading + 1 elseif k == "finished" then finished = finished + 1 end
    end
    return reading, finished
end

function firstN(list, n)
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i] end
    return out
end

-- Books grouped by key(book) (nil: left out), in first-seen order: { key, books }.
function groupBy(books, key)
    local groups, by = {}, {}
    for _, b in ipairs(books or {}) do
        for _, k in ipairs(key(b)) do
            local g = by[k]
            if not g then g = { key = k, books = {} }; by[k] = g; table.insert(groups, g) end
            table.insert(g.books, b)
        end
    end
    return groups
end

-- One series row per series among the books (each book under its primary series only).
function Group.series(books)
    local out = {}
    for _, g in ipairs(groupBy(books, function(b) local k = Group.seriesKey(b); return k and { k } or {} end)) do
        local members = firstN(g.books, #g.books)
        table.sort(members, Group.bySeriesIndex)
        local first = members[1]
        local name = first.seriesName or ""
        for _, b in ipairs(members) do if type(b.seriesName) == "string" and b.seriesName ~= "" then name = b.seriesName break end end
        local reading, finished = counts(members)
        local states, names, seen = {}, {}, {}
        for i, b in ipairs(members) do
            if i <= Group.MEMBER_STATES then states[i] = Group.bucket(b.readStatus) end
            local who = b.authors and b.authors[1]
            if who and not seen[who] and #names < Group.AUTHOR_NAMES then seen[who] = true; table.insert(names, who) end
        end
        local sid = tonumber(first.seriesId)
        table.insert(out, {
            id = sid and ("series:" .. sid) or name, title = name, section = "series", seriesId = sid,
            count = #members, readingCount = reading, finishedCount = finished,
            memberStates = states, authorNames = names, previewBooks = firstN(members, Group.PREVIEWS),
            letter = Group.letter(name), orbitKey = g.key,
        })
    end
    return out
end

-- The time a preview orders by: reading by last read, finished by last read, others by added.
function previewTier(b)
    local k = Group.bucket(b.readStatus)
    if k == "reading" then return 0, b.lastReadAt or "" end
    if k == "finished" then return 1, b.lastReadAt or "" end
    return 2, b.addedAt or ""
end

function Group.byPreview(a, b)
    local ta, ra = previewTier(a)
    local tb, rb = previewTier(b)
    if ta ~= tb then return ta < tb end
    if ra ~= rb then return ra > rb end
    return (tonumber(a.id) or 0) > (tonumber(b.id) or 0)
end

-- One author row per author among the books (a book counts for each of its authors).
function Group.authors(books)
    local out = {}
    local groups = groupBy(books, function(b)
        local keys, seen = {}, {}
        for _, a in ipairs(b.authors or {}) do
            if type(a) == "string" and a ~= "" and not seen[a] then seen[a] = true; table.insert(keys, a) end
        end
        return keys
    end)
    for _, g in ipairs(groups) do
        local reading, finished = counts(g.books)
        local previews = firstN(g.books, #g.books)
        table.sort(previews, Group.byPreview)
        -- Their series with the most books here; a tie goes to the name first A-Z.
        local top, top_n, top_fold
        for _, s in ipairs(groupBy(g.books, function(b) local k = Group.seriesKey(b); return k and { k } or {} end)) do
            local name = s.books[1].seriesName or ""
            local f = Group.fold(name)
            if not top or #s.books > top_n or (#s.books == top_n and f < top_fold) then top, top_n, top_fold = name, #s.books, f end
        end
        table.insert(out, {
            id = g.key, title = g.key, section = "authors", count = #g.books,
            readingCount = reading, finishedCount = finished, seriesName = top,
            previewBooks = firstN(previews, Group.PREVIEWS), letter = Group.letter(g.key), orbitKey = "author:" .. g.key,
        })
    end
    return out
end

-- The "Not in a series" row of an author's books by series: always last.
function Group.standalone(books)
    local alone = {}
    for _, b in ipairs(books or {}) do if Group.seriesKey(b) == nil then table.insert(alone, b) end end
    if #alone == 0 then return nil end
    local reading, finished = counts(alone)
    local states = {}
    for i, b in ipairs(alone) do if i <= Group.MEMBER_STATES then states[i] = Group.bucket(b.readStatus) end end
    return { id = Group.STANDALONE, title = "Not in a series", section = "series", count = #alone,
        readingCount = reading, finishedCount = finished, memberStates = states, authorNames = {},
        previewBooks = firstN(alone, Group.PREVIEWS), letter = "", orbitKey = Group.STANDALONE }
end

-- The server's Reading / Finished filters: a series under way (a book in progress, or some but
-- not all finished) or all finished; an author with a book in progress, or one finished.
function Group.keep(e, section, filter)
    local n, r, f = e.count or 0, e.readingCount or 0, e.finishedCount or 0
    if filter == "reading" then
        if section == "authors" then return r > 0 end
        return r > 0 or (f > 0 and f < n)
    elseif filter == "finished" then
        if section == "authors" then return f > 0 end
        return f == n
    end
    return true
end

-- Name A-Z (or Z-A), or most books first then name A-Z; ties by id.
function Group.sort(entries, sort)
    table.sort(entries, function(a, b)
        local fa, fb = Group.fold(a.title), Group.fold(b.title)
        if sort == "books" and a.count ~= b.count then return a.count > b.count end
        if fa ~= fb then
            if sort == "name_desc" then return fa > fb end
            return fa < fb
        end
        return tostring(a.id) < tostring(b.id)
    end)
    return entries
end

-- One page of rows, as the sections endpoint answers it. params: the plugin's section
-- request (q, sort, filter, size, offset or page; bookorbit_catalog_lists.lua:246-260).
-- A section of an author's books adds the "Not in a series" row last.
function Group.sectionBody(rows, section, params, extra_last)
    params = params or {}
    local sort = params.sort or "name"
    local q = params.q and Group.fold(params.q) or ""
    local list = {}
    for _, e in ipairs(rows) do
        if (q == "" or Group.fold(e.title):find(q, 1, true)) and Group.keep(e, section, params.filter) then
            table.insert(list, e)
        end
    end
    Group.sort(list, sort)
    local buckets
    if sort ~= "books" then
        buckets = {}
        local seen = {}
        for i, e in ipairs(list) do
            if not seen[e.letter] then seen[e.letter] = true; table.insert(buckets, { key = e.letter, index = i - 1 }) end
        end
    end
    if extra_last and q == "" and Group.keep(extra_last, "series", params.filter) then table.insert(list, extra_last) end
    local size = tonumber(params.size) or Group.SECTION_SIZE
    local offset = tonumber(params.offset) or ((tonumber(params.page) or 1) - 1) * size
    local items = {}
    for i = offset + 1, math.min(#list, offset + size) do table.insert(items, list[i]) end
    return {
        items = items, total = #list, size = size, sort = sort, filter = params.filter, buckets = buckets,
        page = math.floor(offset / size) + 1, offset = params.offset ~= nil and offset or nil,
        hasNext = offset + size < #list, hasPrevious = offset > 0, query = params.q,
    }
end

-- The books of one row: an author's, a series', or (STANDALONE) an author's outside a series.
function Group.select(books, author, key)
    local out = {}
    for _, b in ipairs(books or {}) do
        local by = author == nil
        if not by then for _, a in ipairs(b.authors or {}) do if a == author then by = true break end end end
        local sk = Group.seriesKey(b)
        local in_key = key == nil or (key == Group.STANDALONE and sk == nil) or (key ~= Group.STANDALONE and sk == key)
        if by and in_key then table.insert(out, b) end
    end
    return out
end

-- Which list a book list is: { section, id } from its params, or nil (a search, a series or an
-- author page, a list by id). Every other book list is the whole library with its filters
-- (All books, Recently updated, Recently added...): { section = "all" } (v0.11.2).
function Group.listOf(params)
    params = params or {}
    if params.smartScopeId then return { section = "smart-scopes", id = tonumber(params.smartScopeId) } end
    if params.collectionId then return { section = "collections", id = tonumber(params.collectionId) } end
    if params.libraryId then return { section = "libraries", id = tonumber(params.libraryId) } end
    -- On device: the plugin's list of this reader's books by id (bookorbit_catalog.lua:1187-1206,
    -- ids capped at 200 by the server, koreader-catalog-query.dto.ts:114). Its rows drill by id.
    if params.on_device_filter and params.ids and params.ids ~= "" then return { section = "on-device" } end
    local function set(v) return v ~= nil and tostring(v) ~= "" end
    if set(params.q) or set(params.ids) or set(params.seriesId) or set(params.series) or set(params.author) then return nil end
    return { section = "all" }
end

-- The request for every book of the list, page by page: its params with the list's filters.
FETCH_DROP = { page = true, size = true, offset = true, sort = true, order = true, buckets = true, on_device_filter = true }
function Group.fetchParams(params, page)
    local q = {}
    for k, v in pairs(params or {}) do
        if not FETCH_DROP[k] and not tostring(k):match("^orbit") then q[k] = v end
    end
    q.sort, q.size, q.page = "title", Group.PAGE, page or 1
    return q
end

-- Book ids, ascending, joined for the ids parameter.
function Group.ids(books, max)
    local ids = {}
    for _, b in ipairs(books) do table.insert(ids, tonumber(b.id)) end
    table.sort(ids)
    if max and #ids > max then for i = #ids, max + 1, -1 do ids[i] = nil end end
    return table.concat(ids, ",")
end

-- The request for some of a list's books (a row tapped in the grouped view).
--   list: { section, id }; list_params: the list's own params (its filters); books: those books;
--   target: what the page is (seriesId/series, author, sort); marks: orbit* keys to carry.
-- A library or collection: the server ANDs libraryId / collectionId with the target
-- (opds-book.service.ts:378-395), with the list's filters. A smart scope: the server drops
-- every other filter when smartScopeId is set (:368-375), so the books go by id instead (ids
-- caps at 200, koreader-catalog-query.dto.ts:114); past that the patch serves them from the
-- books it holds (orbitLocal). flat: always by id (a flat book list, not the author page).
function Group.drill(list, list_params, books, target, marks, flat)
    local p = {}
    for k, v in pairs(target or {}) do p[k] = v end
    for k, v in pairs(marks or {}) do p[k] = v end
    if not flat and list.section ~= "smart-scopes" and list.section ~= "on-device" then
        for _, k in ipairs({ "libraryId", "collectionId", "readStatus", "format", "ids" }) do
            if list_params[k] ~= nil then p[k] = list_params[k] end
        end
        return p, "server"
    end
    if #books <= Group.IDS_MAX then
        p.ids = Group.ids(books)
        return p, "ids"
    end
    p.orbitLocal = "1"
    return p, "held"
end

-- A page of the held books (orbitLocal), as the books endpoint answers it.
SORT_KEY = {
    title = function(b) return Group.fold(b.title) end,
    author = function(b) return Group.fold(b.authors and b.authors[1]) end,
    series = function(b) return Group.fold(b.seriesName) end,
    recently_added = function(b) return b.addedAt or "" end,
    recently_read = function(b) return b.lastReadAt or "" end,
}
NATURAL = { recently_added = "desc", recently_read = "desc", recently_updated = "desc", published = "desc" }
function Group.booksBody(books, params)
    params = params or {}
    local list = {}
    for _, b in ipairs(books or {}) do
        local k = Group.bucket(b.readStatus)
        if params.readStatus == nil or k == params.readStatus then table.insert(list, b) end
    end
    local sort = SORT_KEY[params.sort] and params.sort or "series"
    local desc = (params.order or NATURAL[params.sort] or "asc") == "desc"
    table.sort(list, function(a, b)
        local ka, kb = SORT_KEY[sort](a), SORT_KEY[sort](b)
        if ka ~= kb then if desc then return ka > kb end return ka < kb end
        return Group.bySeriesIndex(a, b)
    end)
    local size = tonumber(params.size) or 20
    local offset = tonumber(params.offset) or ((tonumber(params.page) or 1) - 1) * size
    local items = {}
    for i = offset + 1, math.min(#list, offset + size) do table.insert(items, list[i]) end
    return { items = items, total = #list, size = size, page = math.floor(offset / size) + 1,
        offset = params.offset ~= nil and offset or nil, hasNext = offset + size < #list, hasPrevious = offset > 0 }
end

-- Lists read for the grouped views, by token: { list, params, title, books }. A few at a time
-- (the oldest goes); the token rides in the request params (orbitGroup), never to the server.
Group.held, Group.order, Group.next = {}, {}, 0
function Group.remember(snap)
    Group.next = Group.next + 1
    local token = "g" .. Group.next
    Group.held[token] = snap
    table.insert(Group.order, token)
    while #Group.order > Group.SNAPSHOTS do Group.held[table.remove(Group.order, 1)] = nil end
    return token
end

-- Request params never sent: the patch's own marks.
function Group.strip(params)
    if type(params) ~= "table" then return params end
    local has = false
    for k in pairs(params) do if tostring(k):match("^orbit") then has = true break end end
    if not has then return params end
    local out = {}
    for k, v in pairs(params) do if not tostring(k):match("^orbit") then out[k] = v end end
    return out
end

-- The books a request with orbitLocal means: the held list, narrowed by its marks.
function Group.localBooks(params)
    local snap = Group.held[params.orbitGroup or ""]
    if not snap then return nil end
    local key = params.orbitSeries
    return Group.select(snap.books, params.orbitAuthor, key ~= "" and key or nil)
end

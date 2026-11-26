-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Legacy cache policy and response shapes are private to this adapter.
ServerCache=setmetatable({
    FRESH_S = 60,          -- a read within this of the last check is not checked again
    VERSION = 1,
    MIRROR_PAGE = 100,     -- the server's largest page (koreader-catalog-query.dto.ts:87, :284)
    MIRROR_TTL_DAYS = 7,   -- an automatic Full refresh once the mirror is older than this
},{__index=Cache})
-- Legacy protocol classification and cached-field normalization. No IO.
function ServerCache.cacheable(method, path)
    if tostring(method or ""):upper() ~= "GET" then return false end
    local p = ServerCache.splitPath(path)
    if not (p:find("^/koreader/plugin/catalog/") or p:find("^/plugin/catalog/")) then return false end
    if p:find("/thumbnail$") or p:find("/photo$") or p:find("/download") or p:find("/files/") then return false end
    return true
end

function ServerCache.listWindow(path)
    local p, q = ServerCache.splitPath(path)
    local books = p:find("/catalog/books$") ~= nil
    local section = p:match("/catalog/sections/([%w%-]+)$")
    if not books and not section then return nil end
    local query = ServerCache.parseQuery(q)
    if query.q and query.q ~= "" then return nil end -- search stays online
    local w = { page = tonumber(query.page), size = tonumber(query.size), offset = tonumber(query.offset),
        kind = books and "books" or "section", section = section }
    query.page, query.size, query.offset = nil, nil, nil
    local rest = ServerCache.encQuery(query)
    w.identity = p .. (rest ~= "" and ("?" .. rest) or "")
    return w
end

function ServerCache.writeEffect(method, path, body)
    if tostring(method or ""):upper() == "GET" then return nil end
    local p = ServerCache.splitPath(path)
    local id, what = p:match("/catalog/books/(%d+)/([%w%-]+)$")
    id = tonumber(id)
    if not id then return { stale_home = p:find("/catalog/") ~= nil or p:find("/sync") ~= nil or p:find("/progress") ~= nil } end
    body = type(body) == "table" and body or {}
    if what == "read-status" then return { id = id, fields = { readStatus = body.status }, stale_home = true } end
    if what == "rating" then
        local r = body.rating
        if type(r) ~= "number" then r = ServerCache.NULL end
        return { id = id, fields = { rating = r }, stale_home = true }
    end
    return { stale_home = true }
end

ServerCache.VOLATILE = { generatedAt = true }
ServerCache.KEEP_SAVED = { discover = true }

function ServerCache.normalize(body)
    if type(body) ~= "table" then return body end
    local out = {}
    for k, v in pairs(body) do
        if not ServerCache.VOLATILE[k] and not ServerCache.KEEP_SAVED[k] then out[k] = v end
    end
    return out
end

local splitPath=ServerCache.splitPath
local function normQuery(query)
    local keys = {}
    for k, v in pairs(query or {}) do
        if v ~= nil and tostring(v) ~= "" then table.insert(keys, tostring(k)) end
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do table.insert(parts, k .. "=" .. tostring(query[k])) end
    return table.concat(parts, "&")
end
local function normServer(s)
    return (tostring(s or ""):lower():gsub("/+$", ""))
end

function ServerCache.key(r)
    local path, q = splitPath(r.path)
    local query = ServerCache.parseQuery(q)
    for k, v in pairs(r.query or {}) do query[k] = v end
    return table.concat({ tostring(r.account or ""), normServer(r.server), tostring(r.method or "GET"):upper(),
        path, normQuery(query) }, "|")
end

-- Catalog reads only; never covers, downloads, auth, version or sync.

---------------------------------------------------------------- reads

-- entry: nil or { validated_at }; mode: "open" | "refresh" | "full". -> serve, fetch.
-- entry.stale: a write since may have changed it (served, checked at once).
function ServerCache.readPlan(entry, now, mode, offline)
    if mode == "full" then
        if offline then return entry ~= nil, false end
        return false, true
    end
    if not entry then return false, not offline end
    if offline then return true, false end
    if mode == "refresh" or entry.stale then return true, true end
    return true, (now - (entry.validated_at or 0)) >= ServerCache.FRESH_S
end

-- Fields that differ on every request and say nothing about the data: generatedAt is the
-- server's clock (koreader-catalog.service.ts:279); discover is a fresh random pick each time
-- (:417-433, getRandomBooks), so a check never counts it and the saved pick is kept until a
-- Full refresh.

-- -> changed, stored
function ServerCache.revalidate(cached, reply, status)
    if type(status) ~= "number" or status < 200 or status >= 300 or reply == nil then return false, false end
    return ServerCache.encode(ServerCache.normalize(cached)) ~= ServerCache.encode(ServerCache.normalize(reply)), true
end

---------------------------------------------------------------- the offline mirror

-- A list read (a books page or a section page): its identity (the path without page, size and
-- offset) and the window it asks for. nil for anything else (a book, the dashboard, a search).

-- A search: never mirrored; offline it says it needs a connection.
function ServerCache.isSearch(path)
    local _, q = splitPath(path)
    local query = ServerCache.parseQuery(q)
    return query.q ~= nil and query.q ~= ""
end

function ServerCache.pageCount(total, size)
    total = tonumber(total) or 0
    if total <= 0 then return 1 end
    return math.ceil(total / (size or ServerCache.MIRROR_PAGE))
end

-- One list page answered from the mirror's pages.
--   w: Cache.listWindow; pages: { [n] = body of mirror page n }; -> body, or nil when a page it
--   needs isn't saved.
local PAGING = { items = true, page = true, size = true, offset = true, hasNext = true, hasPrevious = true,
    nextUrl = true, previousUrl = true }
function ServerCache.slice(w, pages, page_size)
    local per = page_size or ServerCache.MIRROR_PAGE
    local first = pages[1]
    if type(first) ~= "table" or type(first.items) ~= "table" then return nil end
    local total = tonumber(first.total) or #first.items
    local size = w.size or (w.kind == "books" and 20 or total)
    if size < 1 then size = 1 end
    local start = w.offset or ((w.page or 1) - 1) * size
    local stop = math.min(total, start + size)
    local items = {}
    for i = start + 1, stop do
        local n = math.floor((i - 1) / per) + 1
        local page = pages[n]
        if type(page) ~= "table" or type(page.items) ~= "table" then return nil end
        local item = page.items[i - (n - 1) * per]
        if item == nil then return nil end
        table.insert(items, item)
    end
    local out = {}
    for k, v in pairs(first) do if not PAGING[k] then out[k] = v end end
    out.items, out.total, out.size = items, total, size
    out.page = math.floor(start / size) + 1
    if w.offset then out.offset = w.offset end
    out.hasNext, out.hasPrevious = stop < total, start > 0
    return out
end

-- The positions a list read asks for (docs/design/sqlite-cache.md "How KOReader reads"; the
-- companion's CacheStore.windowOf). kind: "books" | "section"; page, size, offset: the read's own.
-- -> start (0-based), stop (exclusive), size
function ServerCache.window(kind, total, page, size, offset)
    total = tonumber(total) or 0
    size = tonumber(size) or (kind == "books" and 20 or total)
    if size < 1 then size = 1 end
    local start = tonumber(offset) or ((tonumber(page) or 1) - 1) * size
    return start, math.max(start, math.min(total, start + size)), size
end

-- A list page from its saved head (the first page's other fields) and the items at start..stop-1.
function ServerCache.assemble(head, items, total, start, stop, size, offset)
    local out = {}
    for k, v in pairs(type(head) == "table" and head or {}) do if not PAGING[k] then out[k] = v end end
    out.items, out.total, out.size = items, total, size
    out.page = math.floor(start / size) + 1
    if offset then out.offset = tonumber(offset) end
    out.hasNext, out.hasPrevious = stop < total, start > 0
    return out
end

-- The book id when path is the detail template (the plugin's detail request with the sentinel id)
-- filled with an id; the companion's CacheStore.detailId.
function ServerCache.detailId(path, template, sentinel)
    if type(template) ~= "string" or type(path) ~= "string" then return nil end
    local i, j = template:find(sentinel, 1, true)
    if not i then return nil end
    local pre, post = template:sub(1, i - 1), template:sub(j + 1)
    if #path <= #pre + #post or path:sub(1, #pre) ~= pre or (post ~= "" and path:sub(-#post) ~= post) then return nil end
    local mid = path:sub(#pre + 1, #path - #post)
    if not mid:match("^%d+$") or #mid > 12 then return nil end
    return tonumber(mid)
end

-- An offline search's words, each as a LIKE pattern (% and _ escaped with \).
function ServerCache.searchWords(q)
    local out = {}
    for w in tostring(q or ""):gmatch("%S+") do
        table.insert(out, "%" .. w:gsub("[\\%%_]", "\\%0") .. "%")
    end
    return out
end

-- Whether the mirror needs an automatic Full refresh.
--   m: { at (last complete Full refresh), lib_version }; lib_version: the plugin's current one.
-- -> reason ("never" | "ttl" | "library") or nil
function ServerCache.mirrorDue(m, now, ttl_days, lib_version)
    if type(m) ~= "table" or not m.at then return "never" end
    if now - m.at >= (ttl_days or ServerCache.MIRROR_TTL_DAYS) * 86400 then return "ttl" end
    if lib_version and m.lib_version and lib_version ~= m.lib_version then return "library" end
    return nil
end

---------------------------------------------------------------- writes

-- The book id and the fields a write sets, or nil when the write patches nothing.

ServerCache.NULL = {} -- a field the write clears

-- The book ids a body lists (for finding the entries a write touches).
function ServerCache.ids(body, out, depth)
    out = out or {}
    depth = depth or 0
    if type(body) ~= "table" or depth > 30 then return out end
    local id = tonumber(body.id)
    if id then out[id] = true end
    for _, v in pairs(body) do
        if type(v) == "table" then ServerCache.ids(v, out, depth + 1) end
    end
    return out
end

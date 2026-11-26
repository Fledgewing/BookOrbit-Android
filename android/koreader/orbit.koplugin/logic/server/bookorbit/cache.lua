-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Legacy protocol classification and cached-field normalization. No IO.
function Cache.cacheable(method, path)
    if tostring(method or ""):upper() ~= "GET" then return false end
    local p = Cache.splitPath(path)
    if not (p:find("^/koreader/plugin/catalog/") or p:find("^/plugin/catalog/")) then return false end
    if p:find("/thumbnail$") or p:find("/photo$") or p:find("/download") or p:find("/files/") then return false end
    return true
end

function Cache.listWindow(path)
    local p, q = Cache.splitPath(path)
    local books = p:find("/catalog/books$") ~= nil
    local section = p:match("/catalog/sections/([%w%-]+)$")
    if not books and not section then return nil end
    local query = Cache.parseQuery(q)
    if query.q and query.q ~= "" then return nil end -- search stays online
    local w = { page = tonumber(query.page), size = tonumber(query.size), offset = tonumber(query.offset),
        kind = books and "books" or "section", section = section }
    query.page, query.size, query.offset = nil, nil, nil
    local rest = Cache.encQuery(query)
    w.identity = p .. (rest ~= "" and ("?" .. rest) or "")
    return w
end

function Cache.writeEffect(method, path, body)
    if tostring(method or ""):upper() == "GET" then return nil end
    local p = Cache.splitPath(path)
    local id, what = p:match("/catalog/books/(%d+)/([%w%-]+)$")
    id = tonumber(id)
    if not id then return { stale_home = p:find("/catalog/") ~= nil or p:find("/sync") ~= nil or p:find("/progress") ~= nil } end
    body = type(body) == "table" and body or {}
    if what == "read-status" then return { id = id, fields = { readStatus = body.status }, stale_home = true } end
    if what == "rating" then
        local r = body.rating
        if type(r) ~= "number" then r = Cache.NULL end
        return { id = id, fields = { rating = r }, stale_home = true }
    end
    return { stale_home = true }
end

Cache.VOLATILE = { generatedAt = true }
Cache.KEEP_SAVED = { discover = true }

function Cache.normalize(body)
    if type(body) ~= "table" then return body end
    local out = {}
    for k, v in pairs(body) do
        if not Cache.VOLATILE[k] and not Cache.KEEP_SAVED[k] then out[k] = v end
    end
    return out
end

-- The companion's cache rules as the fake companion (fake_companion.lua, fake_store.lua) plays
-- them. Test code: nothing ships. The plugin once owned these and now only the companion runs
-- them (docs/design/companion-worker.md); each names its Kotlin owner, and test_logic.lua checks
-- these copies against the same shared tables the companion's tests read
-- (shared/fixtures/REGISTRY.json), so the fake cannot drift from the real worker.
--   local R = dofile(here .. "/companion_rules.lua")(Cache)   -- Cache: the plugin's logic/cache.lua
return function(Cache)
    local R = {
        MIRROR_SMALL_PAGE = 25, -- MirrorLogic.SMALL_PAGE: a list whose first 100-item page timed out
        MIRROR_TRIES = 3,       -- MirrorLogic.TRIES: a mirror request with no answer, then skipped
        MIRROR_RETRY_S = 5,     -- the first retry's wait; it doubles each try
    }

    local function splitPath(path)
        local p, q = tostring(path or ""):match("^([^?]*)%??(.*)$")
        return p, q
    end

    local function escape(v)
        return (tostring(v):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
    end

    local function encQuery(query)
        local keys = {}
        for k, v in pairs(query or {}) do
            if v ~= nil and tostring(v) ~= "" then table.insert(keys, tostring(k)) end
        end
        table.sort(keys)
        local parts = {}
        for _, k in ipairs(keys) do table.insert(parts, escape(k) .. "=" .. escape(query[k])) end
        return table.concat(parts, "&")
    end

    -- CacheWorker.coverName: a book's cover file name, as KOReader's BookOrbit plugin names it
    -- (bookorbit_catalog_thumbnails.lua:61-85), or nil (shared/fixtures/cache/worker.json "covers").
    function R.coverName(book)
        local id = type(book) == "table" and book.id
        if type(id) ~= "number" or id ~= math.floor(id) or id < 1 or id > 2147483647 then return nil end
        local token = book.updatedAt and tostring(book.updatedAt):gsub("%D", "") or "0"
        if #token > 32 then token = token:sub(1, 16) .. token:sub(-16) end
        if token == "" then token = "0" end
        return (book.author_photo and "a" or "") .. string.format("%.0f", id) .. "_" .. token .. ".jpg"
    end

    -- MirrorLogic.isHome: Home's replies (kept, marked stale by a write).
    function R.isHome(path)
        return splitPath(path):find("/catalog/dashboard") ~= nil
    end

    -- LuaValue.settle: what a check stores; the saved random pick is kept, a Full refresh takes the
    -- new one (cases.json "settle").
    function R.settle(cached, reply, mode)
        if type(cached) ~= "table" or type(reply) ~= "table" or mode == "full" then return reply end
        local out = {}
        for k, v in pairs(reply) do out[k] = v end
        for k in pairs(Cache.KEEP_SAVED) do if cached[k] ~= nil then out[k] = cached[k] end end
        return out
    end

    -- MirrorLogic.mirrorPage: the path of a mirror page of a list identity (worker.json "windows").
    function R.mirrorPage(identity, page, size)
        local p, q = splitPath(identity)
        local query = Cache.parseQuery(q)
        query.page, query.size = page, size or Cache.MIRROR_PAGE
        return p .. "?" .. encQuery(query)
    end

    -- MirrorLogic.retry: a mirror request that got no answer. tries: failures so far; size: the
    -- page size it asked for (nil: not a list page). -> { skip = true }, else { wait_s, size }
    -- (cases.json "mirror.retry").
    function R.mirrorRetry(tries, size, page)
        if tries >= R.MIRROR_TRIES then return { skip = true } end
        local out = { wait_s = R.MIRROR_RETRY_S * 2 ^ (tries - 1), size = size }
        if size and page == 1 and size > R.MIRROR_SMALL_PAGE then
            out.size = math.max(R.MIRROR_SMALL_PAGE, math.floor(size / 2))
        end
        return out
    end

    -- MirrorLogic.limitText: the note when the mirror stops at the storage limit (cases.json "storage.notes").
    function R.limitText(what, done, total)
        return string.format("Storage limit reached: %d of %d %s saved. No room for new data; protected covers are kept. Raise the limit in BookSync settings.",
            done or 0, total or 0, what == "covers" and "covers" or "lists and books")
    end

    -- CacheStore.patched: every table in body whose id is the book's gets the fields (Cache.NULL
    -- clears one). -> the number of tables patched (cases.json "writes").
    function R.patch(body, id, fields, depth)
        depth = depth or 0
        if type(body) ~= "table" or depth > 30 then return 0 end
        local n = 0
        if tonumber(body.id) == id then
            for k, v in pairs(fields) do
                if v == Cache.NULL then body[k] = nil else body[k] = v end
            end
            n = 1
        end
        for _, v in pairs(body) do
            if type(v) == "table" then n = n + R.patch(v, id, fields, depth + 1) end
        end
        return n
    end

    return R
end

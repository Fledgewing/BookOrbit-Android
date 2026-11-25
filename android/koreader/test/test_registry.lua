-- The shared rule tables' registry (shared/fixtures/REGISTRY.json) against the plugin's tests.
-- test_logic.lua runs it. Fails when a table section names "lua" as a reader and no test here
-- carries its mark ("@fixture <file>#<section>", or "@fixture <file>" for a whole file), when a
-- mark names a section the registry does not give "lua", and, for every suite at once, when a
-- fixture file or section has no row, a row names a missing file or section, or a row has no reader.
-- The companion (RegistryTest.kt), the Xteink host tests (registry_test.cpp) and the e2e kit
-- (test_kit.py) check their own marks.
local JSON = dofile((debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".") .. "/json_mini.lua")

local COMMENTS = { _comment = true, comment = true, description = true }

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local t = f:read("*a")
    f:close()
    return t
end

local function lines(cmd)
    local out, p = {}, assert(io.popen(cmd))
    for l in p:lines() do table.insert(out, l) end
    p:close()
    return out
end

-- The marks in the given files: { ["file#section"] = "where" }.
local function marks(files)
    local out = {}
    for _, path in ipairs(files) do
        for m in readFile(path):gmatch("@fixture ([%w%._/%-]+[#%w%._]*)") do out[m] = path end
    end
    return out
end

local function id(r) return r.section and (r.file .. "#" .. r.section) or r.file end

local function has(list, v)
    for _, x in ipairs(list or {}) do if x == v then return true end end
    return false
end

-- The value at a dotted key path, or nil.
local function at(doc, path)
    local v = doc
    for k in path:gmatch("[^%.]+") do
        if type(v) ~= "table" then return nil end
        v = v[k]
    end
    return v
end

return function(here)
    local root = here .. "/../../../shared/fixtures"
    local reg = JSON.decode(readFile(root .. "/REGISTRY.json"))
    local problems = {}
    local function bad(s) table.insert(problems, s) end

    -- This suite's marks.
    local tests = lines("ls " .. here .. "/*.lua")
    local mine, given = marks(tests), {}
    for _, r in ipairs(reg.tables) do
        if has(r.readers, "lua") then
            given[id(r)] = true
            if not mine[id(r)] then bad("no plugin test reads " .. id(r) .. " (mark it '@fixture " .. id(r) .. "')") end
        end
    end
    for m, where in pairs(mine) do
        if not given[m] then bad(where:match("[^/]*$") .. " marks " .. m .. ", which REGISTRY.json does not give to lua") end
    end

    -- Every file and section has a row; every row names something real and has a reader.
    local rows = {}
    for _, r in ipairs(reg.tables) do
        rows[r.file] = rows[r.file] or {}
        table.insert(rows[r.file], r)
        if #(r.readers or {}) == 0 then bad(id(r) .. " has no reader") end
    end
    local files = {}
    for _, path in ipairs(lines("cd " .. root .. " && find . -type f | sort")) do
        local rel = path:gsub("^%./", "")
        if not rel:match("README%.md$") and rel ~= "REGISTRY.json" then
            files[rel] = true
            if not rows[rel] then bad(rel .. " has no row in REGISTRY.json") end
        end
    end
    for file, rs in pairs(rows) do
        if not files[file] then
            bad("REGISTRY.json names " .. file .. ", which does not exist")
        elseif file:match("%.json$") then
            local doc = JSON.decode(readFile(root .. "/" .. file))
            local named, whole = {}, false
            for _, r in ipairs(rs) do
                if not r.section then whole = true
                elseif at(doc, r.section) == nil then bad(id(r) .. ": no such section")
                else named[r.section] = true end
            end
            -- A table (array or object) is covered when a row names it or names all its tables.
            local function check(path, v)
                if named[path] then return end
                if type(v) ~= "table" or v[1] ~= nil or next(v) == nil then
                    bad(file .. "#" .. path .. " has no row in REGISTRY.json")
                    return
                end
                for k, x in pairs(v) do
                    if not COMMENTS[k] and type(x) == "table" then check(path .. "." .. k, x) end
                end
            end
            if not whole and type(doc) == "table" then
                for k, x in pairs(doc) do
                    if not COMMENTS[k] and type(x) == "table" then check(k, x) end
                end
            end
        end
    end
    table.sort(problems)
    return problems
end

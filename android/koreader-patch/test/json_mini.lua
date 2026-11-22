-- A small JSON decoder for the tests (KOReader has its own; plain LuaJIT has none).
-- Enough for the recorded responses in shared/fixtures: objects, arrays, strings with
-- the common escapes, numbers, true/false/null (null becomes nil).
local M = {}

local function skip(s, i)
    return s:find("[^ \t\r\n]", i) or #s + 1
end

local decode_value

local function decode_string(s, i)
    local out, j = {}, i + 1
    while true do
        local c = s:sub(j, j)
        if c == "" then error("unterminated string at " .. i) end
        if c == '"' then return table.concat(out), j + 1 end
        if c == "\\" then
            local e = s:sub(j + 1, j + 1)
            local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
            if e == "u" then
                local code = tonumber(s:sub(j + 2, j + 5), 16)
                out[#out + 1] = code < 128 and string.char(code) or "?"
                j = j + 6
            else
                out[#out + 1] = map[e] or error("bad escape at " .. j)
                j = j + 2
            end
        else
            out[#out + 1] = c
            j = j + 1
        end
    end
end

function decode_value(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "{" then
        local obj = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            local key
            key, i = decode_string(s, skip(s, i))
            i = skip(s, i)
            assert(s:sub(i, i) == ":", "expected : at " .. i)
            obj[key], i = decode_value(s, i + 1)
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "}" then return obj, i + 1 end
            assert(d == ",", "expected , at " .. i)
            i = i + 1
        end
    elseif c == "[" then
        local arr = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            arr[#arr + 1], i = decode_value(s, i)
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "]" then return arr, i + 1 end
            assert(d == ",", "expected , at " .. i)
            i = i + 1
        end
    elseif c == '"' then
        return decode_string(s, i)
    elseif s:sub(i, i + 3) == "true" then return true, i + 4
    elseif s:sub(i, i + 4) == "false" then return false, i + 5
    elseif s:sub(i, i + 3) == "null" then return nil, i + 4
    end
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if not num or num == "" then error("unexpected '" .. c .. "' at " .. i) end
    return tonumber(num), i + #num
end

function M.decode(s)
    local v = decode_value(s, 1)
    return v
end

-- Reads a file under the repo's shared/fixtures/ (path relative to it).
function M.fixture(here, rel)
    local f = assert(io.open(here .. "/../../../shared/fixtures/" .. rel, "rb"))
    local text = f:read("*a")
    f:close()
    return M.decode(text)
end

return M

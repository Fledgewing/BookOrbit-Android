-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Pure formatting/codec utilities and injectable local clock; no persistence or transport.
UIUtil={now=os.time}
function UIUtil.count(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end
function UIUtil.encode(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "0" end
        if v == math.floor(v) and math.abs(v) < 2^53 then return string.format("%d", v) end
        return string.format("%.17g", v)
    end
    if t == "boolean" then return tostring(v) end
    if t ~= "table" or depth > 40 then return "nil" end
    local n = #v
    local parts = {}
    for i = 1, n do table.insert(parts, UIUtil.encode(v[i], depth + 1)) end
    local keys = {}
    for k, val in pairs(v) do
        local kt = type(k)
        local vt = type(val)
        if vt ~= "function" and vt ~= "userdata" and vt ~= "thread"
            and not (kt == "number" and k >= 1 and k <= n and k == math.floor(k)) and (kt == "string" or kt == "number") then
            table.insert(keys, k)
        end
    end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return type(a) == "number"
    end)
    for _, k in ipairs(keys) do
        local ks = type(k) == "string" and string.format("[%q]", k) or ("[" .. UIUtil.encode(k) .. "]")
        table.insert(parts, ks .. "=" .. UIUtil.encode(v[k], depth + 1))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

function UIUtil.pack(...) return {n=select("#",...),...} end

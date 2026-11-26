-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Release versions. Updates come with Orbit Companion: it installs the plugin of its own release
-- (PatchInstaller), so the plugin never downloads one (docs/design/companion-worker.md).
Update = {}

-- "v1.2.3", "android-v1.2.3", "1.2.3-rc.1", "1.2.3+build" -> { 1, 2, 3, pre = "rc.1" | nil }, or nil.
-- BookSync releases Android (v<version>; android-v<version> is read too) and firmware
-- (xteink-v<version>) from one repo (AGENTS.md "Releases"); a firmware tag is not a version
-- here.
function Update.parseVersion(s)
    if type(s) ~= "string" then return nil end
    s = s:match("^%s*(.-)%s*$"):gsub("^android%-", ""):gsub("^[vV]", "")
    s = s:gsub("%+[%w%.%-]*$", "")
    local a, b, c, rest = s:match("^(%d+)%.(%d+)%.(%d+)(.*)$")
    if not a then return nil end
    local pre = nil
    if rest ~= "" then
        pre = rest:match("^%-([%w%.%-]+)$")
        if not pre then return nil end
    end
    return { tonumber(a), tonumber(b), tonumber(c), pre = pre }
end

function comparePre(x, y)
    if x == y then return 0 end
    if x == nil then return 1 end  -- a release sorts after its pre-releases
    if y == nil then return -1 end
    local xs, ys = {}, {}
    for part in x:gmatch("[^%.]+") do xs[#xs + 1] = part end
    for part in y:gmatch("[^%.]+") do ys[#ys + 1] = part end
    for i = 1, math.min(#xs, #ys) do
        local xn, yn = tonumber(xs[i]), tonumber(ys[i])
        if xn and yn then
            if xn ~= yn then return xn < yn and -1 or 1 end
        elseif xn then return -1  -- numeric identifiers sort first
        elseif yn then return 1
        elseif xs[i] ~= ys[i] then return xs[i] < ys[i] and -1 or 1 end
    end
    if #xs == #ys then return 0 end
    return #xs < #ys and -1 or 1
end

-- -1, 0 or 1; nil when either side isn't a version.
function Update.compare(a, b)
    a = type(a) == "table" and a or Update.parseVersion(a)
    b = type(b) == "table" and b or Update.parseVersion(b)
    if not a or not b then return nil end
    for i = 1, 3 do
        if a[i] ~= b[i] then return a[i] < b[i] and -1 or 1 end
    end
    return comparePre(a.pre, b.pre)
end

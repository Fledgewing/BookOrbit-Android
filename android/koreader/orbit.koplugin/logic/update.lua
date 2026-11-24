-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Self-update from the repo's GitHub releases.
Update = {
    INTERVAL = 24 * 60 * 60, -- at most one automatic check per day (os.time seconds)
    ASSET = "orbit.koplugin.zip", -- the plugin folder, zipped with its folder name (release.yml)
    PLUGIN = "orbit.koplugin",
    SUMS = "SHA256SUMS",
}

-- "v1.2.3", "android-v1.2.3", "1.2.3-rc.1", "1.2.3+build" -> { 1, 2, 3, pre = "rc.1" | nil }, or nil.
-- Orbify releases Android (v<version>; android-v<version> is read too) and firmware
-- (xteink-v<version>) from one repo (AGENTS.md "Releases"); a firmware tag is not a version
-- here, so the patch never picks one.
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

-- sha256sum output, "<64 hex>  name" or "<64 hex> *name" -> { [name] = lowercase hex }.
function Update.parseSums(text)
    local out = {}
    for line in (text or ""):gmatch("[^\r\n]+") do
        local hex, name = line:match("^%s*(%x+) [ %*](.-)%s*$")
        if hex and #hex == 64 and name ~= "" then out[name] = hex:lower() end
    end
    return out
end

-- The PATCH_VERSION a downloaded patch declares, so a release can't install an unstamped file.
-- A zip member of the release's plugin zip -> its path inside the plugin folder, or nil when it
-- is outside "orbit.koplugin/" or could escape it (absolute, "..", backslashes, empty parts).
function Update.zipMember(path)
    if type(path) ~= "string" then return nil end
    local prefix = Update.PLUGIN .. "/"
    if path:sub(1, #prefix) ~= prefix then return nil end
    local rel = path:sub(#prefix + 1)
    if rel == "" or rel:find("\\", 1, true) or rel:sub(1, 1) == "/" then return nil end
    for part in (rel .. "/"):gmatch("([^/]*)/") do
        if part == "" or part == "." or part == ".." then return nil end
    end
    return rel
end

function Update.stampedVersion(text)
    return (text or ""):match('\nlocal PATCH_VERSION = "([^"\n]+)"')
end

-- A test build (release.yml with publish off, tools/sideload-android.sh): <next patch>-0.test.<run>.
-- Never published; it sorts below every release and pre-release of the next patch, so the
-- device takes the next real release. Never picked, should one reach a release list.
Update.TEST_PRE = "0.test."
function Update.isTest(v)
    v = type(v) == "table" and v or Update.parseVersion(v)
    return v ~= nil and v.pre ~= nil and v.pre:sub(1, #Update.TEST_PRE) == Update.TEST_PRE
end

-- releases: decoded GitHub release objects. The newest that is not a draft and, unless
-- include_pre, not a pre-release. Returns the release and its parsed version.
function Update.pick(releases, include_pre)
    local best, best_v
    for _i, r in ipairs(releases or {}) do
        local v = type(r) == "table" and Update.parseVersion(r.tag_name)
        if v and not r.draft and (include_pre or not r.prerelease) and not Update.isTest(v) then
            if not best_v or Update.compare(v, best_v) > 0 then best, best_v = r, v end
        end
    end
    return best, best_v
end

function Update.assetUrl(release, name)
    for _i, a in ipairs(release and release.assets or {}) do
        if a.name == name then return a.browser_download_url end
    end
end

-- A clock that went backwards also allows a check.
Update.BLOCKED = "Internet blocked: is 'Block connections without VPN' on for Tailscale?"

Update.WENT_DOWN = "network went down during the check"
Update.NO_ANSWER = "GitHub didn't answer (the network may still be starting). Try again in a minute."

-- A connect timeout or reset right after Wi-Fi or Tailscale comes up is usually gone seconds
-- later (11-21 Boox: a 15 s timeout, then 0.04 s a minute after). Retry twice, after 3 s
-- and 10 s, with a shorter per-try timeout (Update.TRY_TIMEOUT_S).
Update.RETRY_WAITS = { 3, 10 }
Update.TRY_TIMEOUT_S = 8

function Update.transient(err)
    local low = tostring(err or ""):lower()
    if not low:find("^network:") then return false end
    return low:find("timeout", 1, true) ~= nil or low:find("timed out", 1, true) ~= nil
        or low:find("reset", 1, true) ~= nil
end

-- fn() returns body or nil, err. Retries transient errors after each wait in RETRY_WAITS.
-- sleep(s) and note(try, err, wait) are injected (tests; the child sleeps for real).
function Update.withRetry(fn, sleep, note)
    local body, err = fn()
    for i, wait in ipairs(Update.RETRY_WAITS) do
        if body or not Update.transient(err) then break end
        if note then note(i, err, wait) end
        sleep(wait)
        body, err = fn()
    end
    return body, err
end

-- An update request failed: plain words. err: httpGet's error ("network: permission denied"
-- is EACCES, what Android returns when "Block connections without VPN" stops a socket outside
-- Tailscale). st (the state after the failure; nil fields: unknown):
--   wifi_on, connected: the radio and KOReader's "connected";
--   lockdown: the companion's reading of "Block connections without VPN" (only true blames it);
--   went_down: Wi-Fi was switched off (or decided off) while the check ran.
function Update.errorText(err, st)
    err = tostring(err)
    st = st or {}
    local low = err:lower()
    if low:find("permission denied", 1, true) or err:find("EACCES", 1, true) or err:find("EPERM", 1, true)
        or low:find("operation not permitted", 1, true) then
        if st.lockdown == true then return Update.BLOCKED end
        return "no internet: Android refused the connection (" .. err:gsub("^network: ", "") .. ")"
    end
    if st.went_down then return Update.WENT_DOWN end
    if st.wifi_on == false then return "no internet: Wi-Fi is off" end
    if st.connected == false then return "no internet: Wi-Fi isn't connected" end
    if err:find("network:", 1, true) then
        if st.lockdown == true then return Update.BLOCKED end
        return Update.NO_ANSWER
    end
    return "check failed: " .. err
end

-- After a failed check, wait this long before an automatic retry.
Update.RETRY_S = 3600

-- The automatic check's gate. ctx: enabled, now (os.time), checked_at (last success),
-- failed_at (last failure), connected, in_book, off_decided (a just-in-time Wi-Fi off was
-- decided recently). Returns ok, why.
function Update.autoGate(ctx)
    if not ctx.enabled then return false, "auto-update is off" end
    if not Update.isDue(ctx.checked_at, ctx.now) then return false, "checked today" end
    local failed = tonumber(ctx.failed_at) or 0
    if failed > 0 and ctx.now >= failed and ctx.now - failed < Update.RETRY_S then
        return false, "failed " .. math.floor((ctx.now - failed) / 60) .. " min ago; retry after 1 h"
    end
    if ctx.in_book then return false, "a book is open; deferred to the file browser or BookOrbit home" end
    if ctx.off_decided then return false, "Wi-Fi is going off" end
    if not ctx.connected then return false, "network not up" end
    return true
end

-- The child's result over the pipe: "1|0 <tab> net|msg <tab> text".
function Update.encode(ok, text, neterr)
    return (ok and "1" or "0") .. "\t" .. (neterr and "net" or "msg") .. "\t" .. tostring(neterr or text or "")
end

function Update.decode(data)
    local okf, kind, text = tostring(data or ""):match("^([01])\t(%a+)\t(.*)$")
    if not okf then return false, "msg", "check failed: no answer from the background check" end
    return okf == "1", kind, text
end

function Update.isDue(last, now, interval)
    last = tonumber(last) or 0
    return last <= 0 or now < last or now - last >= (interval or Update.INTERVAL)
end

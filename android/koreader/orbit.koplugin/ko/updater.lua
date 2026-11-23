-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Self-update from github.com/Fledgewing/Orbify releases (README "Updates").
-- Checks at most once a day on start/wake when the network is already up (never brings it up
-- for this), or from the menu. The release's plugin zip is SHA-256-checked against its
-- SHA256SUMS, unpacked next to this plugin's folder and swapped in for it; it runs from the next
-- start.
---------------------------------------------------------------------------------------------

Updater = { busy = false }
RELEASES_API = "https://api.github.com/repos/Fledgewing/Orbify/releases"
-- This plugin's main.lua (PLUGIN_DIR is set by main.lua; it carries PATCH_VERSION).
SELF_PATH = PLUGIN_DIR and (PLUGIN_DIR .. "/main.lua") or nil

-- GET with manual redirects (release assets redirect to another host). Returns body or nil, err.
function httpGet(url, block_timeout, total_timeout)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    socketutil:set_timeout(block_timeout, total_timeout)
    local okp, body, err = pcall(function()
        for _hop = 1, 5 do
            local chunks = {}
            local is_api = url:find("api.github.com", 1, true) ~= nil
            local code, headers = socket.skip(1, http.request{
                url = url,
                method = "GET",
                headers = {
                    ["User-Agent"] = "Orbify-patch/" .. PATCH_VERSION,
                    ["Accept"] = is_api and "application/vnd.github+json" or "*/*",
                },
                sink = ltn12.sink.table(chunks),
                redirect = false,
            })
            if type(code) ~= "number" then return nil, "network: " .. tostring(code) end
            local location = type(headers) == "table" and (headers.location or headers.Location) or nil
            if code >= 300 and code < 400 and location then
                log("update: redirect", code, "to", (location:match("^https?://([^/]+)") or "?"))
                url = location
            elseif code == 200 then
                return table.concat(chunks)
            else
                return nil, "HTTP " .. code
            end
        end
        return nil, "too many redirects"
    end)
    socketutil:reset_timeout()
    if not okp then return nil, tostring(body) end
    return body, err
end

function setUpdateStatus(text)
    S.patch_update_status = { at = os.time(), text = text }
    saveSettings()
    log("update:", text)
end

function Updater.readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    return text
end

function Updater.purge(dir)
    local okf, ffiutil = pcall(require, "ffi/util")
    if okf and type(ffiutil) == "table" and ffiutil.purgeDir then pcall(ffiutil.purgeDir, dir) end
    os.remove(dir)
end

-- The zip unpacked into "<plugin folder>.new" (never *.koplugin: KOReader must not load a half
-- copy). Returns that folder, or nil and the status text. KOReader's own libarchive wrapper
-- (koreader-base ffi/archiver.lua, Reader:iterate / extractToMemory, as readerdictionary.lua
-- uses it); every member must sit inside orbit.koplugin/ (Update.zipMember).
function Updater.unpack(zip)
    local oka, Archiver = pcall(require, "ffi/archiver")
    if not oka or type(Archiver) ~= "table" or not Archiver.Reader then
        return nil, "this KOReader can't unpack the update; update it from Orbit Companion"
    end
    local lfs = require("libs/libkoreader-lfs")
    local staged = PLUGIN_DIR .. ".new"
    local zpath = PLUGIN_DIR .. ".zip.new"
    Updater.purge(staged)
    local f, ferr = io.open(zpath, "wb")
    if not f then return nil, "can't write " .. zpath .. ": " .. tostring(ferr) end
    local okw, werr = f:write(zip)
    f:close()
    if not okw or Updater.readFile(zpath) ~= zip then
        os.remove(zpath)
        return nil, "write failed: " .. tostring(werr or "short write")
    end
    local arc = Archiver.Reader:new()
    if not arc:open(zpath) then
        os.remove(zpath)
        return nil, "the download isn't a readable zip; not installed"
    end
    local files, bad = {}, nil
    for entry in arc:iterate() do
        if entry.mode == "file" then
            local member = Update.zipMember(entry.path)
            if not member then bad = entry.path break end
            table.insert(files, { path = entry.path, member = member })
        end
    end
    local err
    if arc.err then err = "can't read the download: " .. tostring(arc.err) .. "; not installed" end
    if not err and bad then err = "unexpected file " .. tostring(bad) .. " in the download; not installed" end
    if not err and #files == 0 then err = "the download holds no plugin files; not installed" end
    if not err then lfs.mkdir(staged) end
    for _i, e in ipairs(err and {} or files) do
        local data = arc:extractToMemory(e.path)
        if not data then err = "can't unpack " .. e.member .. ": " .. tostring(arc.err) break end
        local dir = staged
        for part in e.member:gmatch("([^/]+)/") do
            dir = dir .. "/" .. part
            lfs.mkdir(dir)
        end
        local out, oerr = io.open(staged .. "/" .. e.member, "wb")
        if not out then err = "can't write " .. e.member .. ": " .. tostring(oerr) break end
        local okd = out:write(data)
        out:close()
        if not okd then err = "write failed: " .. e.member break end
    end
    arc:close()
    os.remove(zpath)
    if err then
        Updater.purge(staged)
        return nil, err
    end
    log("update: unpacked", #files, "files into", staged)
    return staged
end

-- The unpacked folder takes this plugin's place: old aside, new in, old gone (the way the
-- companion swaps plugin folders). A failed second step puts the old folder back.
function Updater.swap(staged)
    local old = PLUGIN_DIR .. ".old"
    Updater.purge(old)
    local ok1, err1 = os.rename(PLUGIN_DIR, old)
    if not ok1 then
        Updater.purge(staged)
        return false, "rename failed: " .. tostring(err1)
    end
    local ok2, err2 = os.rename(staged, PLUGIN_DIR)
    if not ok2 then
        os.rename(old, PLUGIN_DIR)
        Updater.purge(staged)
        return false, "rename failed: " .. tostring(err2)
    end
    Updater.purge(old)
    return true
end

-- Returns ok, status text (or ok=false, nil, network error). Blocking: runs only in the
-- background process (Updater.check), never on KOReader's UI thread.
function Updater.run(why)
    local pre = S.patch_update_prerelease == true
    log("update: check started (" .. why .. "), installed", PATCH_VERSION, "pre-releases", tostring(pre))
    -- The list holds firmware releases too: a longer page still reaches the newest Android one.
    local url = pre and (RELEASES_API .. "?per_page=30") or (RELEASES_API .. "/latest")
    local body, err = Update.withRetry(function() return httpGet(url, Update.TRY_TIMEOUT_S, 20) end,
        function(s) require("socket").sleep(s) end,
        function(i, e, wait) log("update: try", i, "failed:", tostring(e), "- retrying in", wait, "s") end)
    if not body then
        -- The parent words it (Update.errorText) from the state after the check: no JNI here.
        log("update: check failed:", tostring(err))
        return false, nil, err
    end
    local okj, json = pcall(require, "json")
    if not okj then return false, "check failed: no JSON module" end
    local okd, data = pcall(json.decode, body)
    if not okd or type(data) ~= "table" then return false, "check failed: unreadable answer" end
    local rel, v = Update.pick(pre and data or { data }, pre)
    if not rel then return false, "no release found" end
    log("update: newest release", rel.tag_name)
    if Update.compare(v, PATCH_VERSION) ~= 1 then return true, "up to date (" .. PATCH_VERSION .. ")" end

    local zip_url, sums_url = Update.assetUrl(rel, Update.ASSET), Update.assetUrl(rel, Update.SUMS)
    if not zip_url or not sums_url then return false, rel.tag_name .. " has no " .. Update.ASSET .. " or " .. Update.SUMS end
    local sums, err2 = httpGet(sums_url, 15, 60)
    if not sums then return false, "SHA256SUMS download failed: " .. tostring(err2) end
    local expected = Update.parseSums(sums)[Update.ASSET]
    if not expected then return false, "SHA256SUMS has no line for " .. Update.ASSET end
    log("update: expecting sha256", expected)
    local zip, err3 = httpGet(zip_url, 15, 60)
    if not zip then return false, "plugin download failed: " .. tostring(err3) end
    -- koreader-base ffi/sha2.lua:5612 (sha256 returns lowercase hex); also used by frontend/util.lua.
    local sha2 = require("ffi/sha2")
    local got = sha2.sha256(zip)
    if got:lower() ~= expected then
        log("update: checksum MISMATCH, got", got)
        return false, "download failed its checksum; not installed"
    end
    log("update: checksum ok,", #zip, "bytes")

    if not PLUGIN_DIR then return false, "can't find this plugin's own folder; not installed" end
    local staged, serr = Updater.unpack(zip)
    if not staged then return false, serr end
    local stamped = Update.stampedVersion(Updater.readFile(staged .. "/main.lua"))
    if Update.compare(stamped, v) ~= 0 then
        Updater.purge(staged)
        return false, "download declares " .. tostring(stamped) .. ", not " .. rel.tag_name .. "; not installed"
    end
    local oks, swerr = Updater.swap(staged)
    if not oks then return false, swerr end
    log("update: installed", stamped, "in", PLUGIN_DIR)
    return true, "updated to " .. stamped .. "; KOReader restarts to use it (after the book, if one is open)"
end

---------------------------------------------------------------------------------------------

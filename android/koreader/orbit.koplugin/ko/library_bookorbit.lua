-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Compatibility binding only: backend credentials/owner remain on this side.
-- Worker BookOrbitLibrary owns projection and query semantics.
LibraryAdapter = { sent={}, order={}, ready={} }
function LibraryAdapter.owner()
    -- newClient/apiOpts may initialize the upstream reading ledger on account change.
    -- Ownership needs only the plugin's already-loaded account scalars.
    local plugin = bookorbit()
    local settings = plugin and plugin.settings
    if type(settings) ~= "table" or not settings.username or not settings.server_url then return nil end
    return OC.owner(settings)
end
function LibraryAdapter.read(request)
    local owner = LibraryAdapter.owner()
    if not owner then return nil end
    local result, bytes = Store.library(owner, request)
    LibraryAdapter.ready[owner .. request] = result ~= nil
    return result, bytes
end
function LibraryAdapter.request(requests)
    local owner = LibraryAdapter.owner()
    if not owner or Companion.workerProblem() then return false end
    -- Coalesce repeat paints; misses retry sooner than already materialized windows.
    local due, now = {}, now_s()
    for _, request in ipairs(requests) do
        local key = owner .. request
        local last = LibraryAdapter.sent[key]
        if not last or now-last >= (LibraryAdapter.ready[key] and 30 or 2) then
            table.insert(due, request)
            if not last then
                table.insert(LibraryAdapter.order, key)
                if #LibraryAdapter.order > 64 then
                    local old = table.remove(LibraryAdapter.order, 1)
                    LibraryAdapter.sent[old], LibraryAdapter.ready[old] = nil, nil
                end
            end
            LibraryAdapter.sent[key] = now
        end
    end
    if #due == 0 then return false end
    local batch = Cache.encode(due)
    assert(#batch <= 131072, "Library batch byte budget exceeded")
    Companion.send(Companion.ACTION.PATCH, {library_batch=batch, owner=owner})
    return true
end

function LibraryAdapter.watch(enabled)
    LibraryAdapter.watching = enabled
    if enabled then LibraryAdapter.reset(); OC.watchChecks() end
end
function LibraryAdapter.changed(ev)
    if ev.owner and ev.owner ~= LibraryAdapter.owner() then return end
    if ev.kind ~= "library" then LibraryAdapter.reset() end
    Library.changed(ev)
end

function LibraryAdapter.reset() LibraryAdapter.sent, LibraryAdapter.ready, LibraryAdapter.order = {}, {}, {} end

-- User-invoked only: the trusted provider opens the companion's private sign-in screen.
function LibraryAdapter.openAccount()
    if Companion.workerProblem() then return false end
    local p = bookorbit()
    local settings = p and p.settings or {}
    local result = Jni.call(Companion.AUTHORITY, Companion.PACKAGE .. ".call.ACCOUNT_OPEN", {
        server=settings.server_url or "", user=settings.username, userkey=settings.userkey,
    })
    return result and result.ok == "1"
end
-- Lifecycle handoff, never a paint read. Only the connector key crosses this boundary.
function LibraryAdapter.accountReturned(attempt)
    if Companion.workerProblem() then return false end
    local result = Jni.call(Companion.AUTHORITY, Companion.PACKAGE .. ".call.ACCOUNT_CONNECTOR", {})
    if result and result.pending == "1" and (attempt or 0) < 3 then
        UIManager:scheduleIn(1, function() LibraryAdapter.accountReturned((attempt or 0)+1) end)
        return false
    end
    if not result or result.ok ~= "1" or not result.revision or S.account_connector_revision == result.revision or not result.server or not result.user or not result.userkey then return false end
    local p = bookorbit()
    if not p or type(p.settings) ~= "table" then return false end
    local s = p.settings
    S.account_connector_revision = result.revision
    saveSettings()
    if s.server_url == result.server and s.username == result.user and s.userkey == result.userkey then return false end
    -- The account owner explicitly chose sign-in in the companion. Existing sync ownership
    -- is left to upstream's one ledger on its next normal command; no second sync writer.
    s.server_url, s.username, s.userkey = result.server, result.user, result.userkey
    G_reader_settings:saveSetting("bookorbit", s)
    G_reader_settings:flush()
    LibraryAdapter.reset()
    return true
end

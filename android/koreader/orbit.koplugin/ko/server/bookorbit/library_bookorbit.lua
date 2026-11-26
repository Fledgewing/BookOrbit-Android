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

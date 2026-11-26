-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Compatibility binding only: backend credentials/owner remain on this side.
-- Worker BookOrbitLibrary owns projection and query semantics.
LibraryAdapter = { sent={}, order={}, ready={} }
function LibraryAdapter.owner()
    if LibraryAdapter.managed_owner then return LibraryAdapter.managed_owner end
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
        server=settings.server_url or "",
    })
    return result and result.ok == "1"
end
-- A lifecycle refresh imports only an opaque namespace, never a login or key.
function LibraryAdapter.accountReturned(attempt)
    if Companion.workerProblem() then return false end
    local result = Jni.call(Companion.AUTHORITY, Companion.PACKAGE .. ".call.SERVER_STATE", {})
    if result and result.pending == "1" and (attempt or 0) < 3 then
        UIManager:scheduleIn(1, function() LibraryAdapter.accountReturned((attempt or 0)+1) end)
        return false
    end
    if not result or result.ok ~= "1" then return false end
    local changed = LibraryAdapter.managed_owner ~= result.owner
    LibraryAdapter.managed_owner = result.owner
    if changed then LibraryAdapter.reset() end
    return changed
end

-- Explicit dispatched commands only; paint reads continue to use the owned SQLite windows.
function LibraryAdapter.command(op, args, callback)
    if Companion.workerProblem() then callback({error="unavailable"}); return false end
    local encoded = Cache.encode(args or {})
    assert(#encoded <= Budgets.MAX_REQUEST, "Server command exceeds budget")
    local sent = Jni.call(Companion.AUTHORITY, Companion.PACKAGE .. ".call.SERVER_COMMAND", {op=op,args=encoded})
    if not sent or sent.ok ~= "1" or not sent.id then callback({error="unavailable"}); return false end
    local deadline = now_s()+120
    local function poll()
        local result = Jni.call(Companion.AUTHORITY, Companion.PACKAGE .. ".call.SERVER_RESULT", {id=sent.id})
        local body = result and result.body
        if type(body) ~= "string" or #body > Budgets.MAX_SNAPSHOT then callback({error="unavailable"}); return end
        local decoded = Cache.decode(body)
        if type(decoded) ~= "table" then callback({error="invalid"}); return end
        if not decoded.pending then callback(decoded); return end
        if now_s() >= deadline then callback({error="unavailable"}); return end
        UIManager:scheduleIn(0.2,poll)
    end
    UIManager:scheduleIn(0.2,poll)
    return true
end

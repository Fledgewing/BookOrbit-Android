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

-- Keep the existing sync writer and Wi-Fi lifecycle behind the adapter. No second outbox.
function LibraryAdapter.syncCurrent(done)
    local ui = liveUI()
    local p = bookorbit(ui)
    if not (p and ui and ui.document and hasHandler(p, "BookOrbitSyncBook")) then
        done(false, "Sync unavailable")
        return false
    end
    local document = ui.document
    Wifi.acquire("reader-panel")
    Net.up(p, {reason="reader-panel", cap=20, need_server=true}, function(ok)
        if not ok then
            Wifi.release("reader-panel")
            done(false, "Offline · will sync when connected")
            return
        end
        if liveUI() ~= ui or ui.document ~= document then
            Wifi.release("reader-panel")
            done(false, "Book closed · your place stays saved")
            return
        end
        local completed = false
        local function finish(err)
            if completed then return end
            completed = true
            Wifi.release("reader-panel")
            done(err == nil, err and "Sync failed · your place stays saved" or "Synced")
        end
        pluginEvent(ui, p, "BookOrbitSyncBook", {quiet=true, on_done=finish})
        UIManager:scheduleIn(30, function() finish("timeout") end)
    end)
    return true
end

-- KOReader already computes this on page/position updates, even with its footer hidden.
-- No document scan, sidecar read or second progress writer on a panel paint.
function LibraryAdapter.readerPosition(path)
    local ui = liveUI()
    if not (ui and ui.document and ui.document.file == path) then return nil end
    local footer = ui.view and ui.view.footer
    local fraction = footer and footer.percent_finished
    if type(fraction) == "number" and fraction == fraction and fraction >= 0 and fraction <= 1 then
        return fraction
    end
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

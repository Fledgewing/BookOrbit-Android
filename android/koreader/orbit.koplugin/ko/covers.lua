-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Neutral parent-side cover host. No network, child processes, directory scans or file writes.
CoverQueue = {MAX_BATCH=4,MAX_RETRIES=2}
function CoverQueue.take(queue) return Cache.takeWindow(queue,CoverQueue.MAX_BATCH) end
-- Dispatch is deferred by the catalog's existing worker timer, never by a paint/lookup.
-- A callback can update only the generation and still-visible view that initiated it.
function CoverQueue.acquire(rows,refresh,valid,landed,done)
    assert(#rows<=CoverQueue.MAX_BATCH,"Cover batch exceeds budget")
    local index=0
    local function step()
        if not valid() then return done(false) end
        index=index+1
        local row=rows[index]
        if not row then return done(true) end
        local attempts=0
        local function dispatch()
            if not valid() then return done(false) end
            Library.acquireCoverReference(row.reference,refresh,function(result)
                if not valid() or result.error=="canceled" then return done(false) end
                if result.error=="retryable" and attempts<CoverQueue.MAX_RETRIES then
                    attempts=attempts+1
                    return UIManager:scheduleIn(1,dispatch)
                end
                landed(row,result)
                step()
            end)
        end
        dispatch()
    end
    step()
end

-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Deterministic render/read limits; device timings are targets, not host-test assertions.
Budgets = { screens = {}, widgets = {} }
local function budget(rows, bytes, ms)
    return { rows=rows, bytes=bytes, spawns=0, roundTrips=1, network=0,
        snapshotBytes=16384, targetMs=ms }
end
for _, id in ipairs({"home", "library", "details", "series", "settings", "filter", "editor", "reader-top-panel"}) do
    Budgets.screens[id] = budget(id == "home" and 128 or 32, id == "home" and 131072 or 32768,
        id == "home" and 500 or id == "editor" and 100 or 50)
end
Budgets.screens["account"] = budget(3, 16384, 50)
-- Picker pages inherit the same filter screen limits, including one worker round-trip.
Budgets.screens["filter-picker"] = budget(24, 16384, 50)
Budgets.libraryWindow = budget(32, 32768, 30)
for _, id in ipairs({"continue-reading", "booklist", "lists", "library", "battery", "this-week",
    "year-in-reading", "when-you-read", "reading-records", "clock"}) do
    Budgets.widgets[id] = budget(id == "booklist" and 12 or id == "lists" and 8 or 1, 16384, 50)
end
-- Library summary + local storage summary are two materialized rows in one batch.
Budgets.widgets.library.rows = 2
local fields = {"rows", "bytes", "spawns", "roundTrips", "network", "snapshotBytes"}
-- Counts must be supplied by the host/read-model boundary, including zeroes. A Home paint
-- checks aggregate counts once; each widget/read also checks its inherited budget.
function Budgets.check(b, counts)
    if type(b) ~= "table" or type(counts) ~= "table" then return nil, "missing budget/counts" end
    for _, k in ipairs(fields) do
        local n, limit = counts[k], b[k]
        if type(n) ~= "number" or n < 0 or n ~= math.floor(n)
            or type(limit) ~= "number" or limit < 0 or limit ~= math.floor(limit) or n > limit then return nil, "budget: " .. k end
    end
    if b.spawns ~= 0 or b.network ~= 0 or b.roundTrips > 1 or b.snapshotBytes > 16384 then
        return nil, "unsafe budget"
    end
    return true
end
-- Inject the logger and monotonic clock at the host boundary. One info line per completed
-- paint/call; no clock, logging, networking or subprocess dependencies in the pure engine.
function Budgets.span(id, clock, info)
    local start = clock()
    return function() info(string.format("BookSync %s %.1f ms", id, (clock()-start)*1000)) end
end

-- Wire/result ceilings for the companion read model. Caller budgets may be narrower.
Budgets.MAX_SNAPSHOT, Budgets.MAX_ROWS = 16384, 24
Budgets.MAX_BATCH, Budgets.MAX_REQUEST = 16, 8192
function Budgets.get(kind, id)
    local b = assert(Budgets[kind] and Budgets[kind][id], "Missing screen/widget budget")
    assert(Budgets.check(b, {rows=0,bytes=0,spawns=0,roundTrips=0,network=0,snapshotBytes=0}))
    return b
end

-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Geometry and bounded presentation selection only; worker owns all catalog semantics.
SeriesPlan = {}
function SeriesPlan.state(result)
    if result.error then return "error", "Couldn't load this page" end
    if result.pending then return "loading", "Loading…" end
    if not (result.freshness and result.freshness.saved) then return "offline-without-data", "Not saved yet" end
    if #(result.items or {})==0 then return "empty", "No books" end
    local offline=result.offline or result.freshness.offline
    return offline and "offline-with-data" or "ready", offline and "Offline · saved library" or nil
end
function SeriesPlan.geometry(w,h,scale)
    local bottom=scale(60)
    local count=math.max(1,math.min(8,math.floor((h-scale(410)-bottom)/scale(92))))
    return {gap=scale(18),top=scale(410),bottom=bottom,row=scale(92),limit=count+4,
        covers=math.max(1,math.min(9,math.floor((w-2*scale(18)+scale(10))/scale(72)))),
        groups=math.max(1,math.min(4,math.floor((h-scale(170)-bottom)/scale(168))))}
end
function SeriesPlan.groupQuery(query,row)
    local q=Layout.copy(query)
    q.group="none"
    if row.field=="author" then q.author={row.value}
    elseif row.value=="" then q.series=nil; q.without_series=true
    else q.series={row.value} end
    return q
end
function SeriesPlan.dot(value) return value=="read" and 1 or value=="reading" and .5 or 0 end

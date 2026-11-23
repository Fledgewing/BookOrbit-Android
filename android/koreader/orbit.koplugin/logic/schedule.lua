-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Pure logic (no KOReader modules). Unit-tested by android/koreader/test/.
---------------------------------------------------------------------------------------------

Schedule = {}

-- "Sync while reading" options, in menu order.
Schedule.OPTIONS = {
    { id = "off",    kind = "off",      n = 0,   label = "Off" },
    { id = "min10",  kind = "minutes",  n = 10,  label = "Every 10 minutes" },
    { id = "min15",  kind = "minutes",  n = 15,  label = "Every 15 minutes" },
    { id = "min30",  kind = "minutes",  n = 30,  label = "Every 30 minutes" },
    { id = "min60",  kind = "minutes",  n = 60,  label = "Every 60 minutes" },
    { id = "pg25",   kind = "pages",    n = 25,  label = "Every 25 pages" },
    { id = "pg50",   kind = "pages",    n = 50,  label = "Every 50 pages" },
    { id = "pg100",  kind = "pages",    n = 100, label = "Every 100 pages" },
    { id = "ch1",    kind = "chapters", n = 1,   label = "Every chapter" },
    { id = "ch2",    kind = "chapters", n = 2,   label = "Every 2 chapters" },
}

function Schedule.option(id)
    for _, o in ipairs(Schedule.OPTIONS) do
        if o.id == id then return o end
    end
    return Schedule.OPTIONS[1]
end

function Schedule.valid(id)
    for _, o in ipairs(Schedule.OPTIONS) do
        if o.id == id then return true end
    end
    return false
end

-- "Sync while reading" set in the companion (android/docs/INTERFACE.md "reading_schedule_request"):
-- req = { id, at (ms) } from /status. The patch keeps the setting; it applies a request once,
-- newer than the last it applied (applied_at, ms). Returns the id to apply, or nil.
function Schedule.request(req, applied_at)
    if type(req) ~= "table" or not Schedule.valid(req.id) then return nil end
    local at = tonumber(req.at)
    if not at or at <= (tonumber(applied_at) or 0) then return nil end
    return req.id, at
end

-- A fresh counter. `now` is in seconds (any monotonic clock).
function Schedule.new(id, now)
    local o = Schedule.option(id)
    return {
        id = o.id, kind = o.kind, n = o.n,
        last_sync = now or 0,
        pages = 0,          -- page turns since the last sync
        chapters = 0,       -- forward chapter changes since the last sync
        chapter_key = nil,  -- start page of the current chapter
        active = false,     -- a page was turned since the last sync
    }
end

-- One page turn. chapter_key identifies the chapter the new page is in (its start page),
-- or nil when the book has no table of contents.
function Schedule.onPage(state, chapter_key, now)
    if state.kind == "off" then return end
    state.pages = state.pages + 1
    state.active = true
    if chapter_key ~= nil then
        if state.chapter_key ~= nil and chapter_key > state.chapter_key then
            state.chapters = state.chapters + 1
        end
        state.chapter_key = chapter_key
    end
end

-- Whether a sync is due. Minutes only count while reading: an idle book never syncs.
function Schedule.isDue(state, now)
    if state.kind == "off" then return false end
    if state.kind == "minutes" then
        return state.active and (now - state.last_sync) >= state.n * 60
    elseif state.kind == "pages" then
        return state.pages >= state.n
    elseif state.kind == "chapters" then
        return state.chapters >= state.n
    end
    return false
end

function Schedule.markSynced(state, now)
    state.last_sync = now
    state.pages = 0
    state.chapters = 0
    state.active = false
end

-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- End of book (docs/design/end-of-book/DESIGN.md, ROADMAP 1 and 2): the FinishJob queue and its
-- drain decisions, the "next in series" / suggestion / author picker, and the stale-push hold.
-- Pure: no KOReader modules. Table-tested from shared/fixtures/bookorbit/ (test_logic.lua).
---------------------------------------------------------------------------------------------

Finish = {
    MAX_ATTEMPTS = 5,       -- then the job is parked until a manual sync (design §3 "Errors")
    BACKOFF_FIRST = 60,     -- seconds, doubling...
    BACKOFF_MAX = 3600,     -- ...up to an hour
    HOLD_POINTS = 10,       -- a push this many points below the finish is held (§7, server S3)
    HOLD_RELEASE_PAGES = 10, -- unless the reader turned this many pages forward in the session
    SUGGEST_ANDROID = 1,
}

-- The statuses someone chose elsewhere on purpose; the drain doesn't fight them (G4).
Finish.DELIBERATE = { rereading = true, on_hold = true, abandoned = true }

-- A new job. f: { hash, book_id?, file?, finished_on? (YYYY-MM-DD), final_pos? {percentage,
-- xpointer}, rating? (1..5 | "clear"), status_seen?, now }.
function Finish.newJob(f)
    return {
        hash = f.hash, book_id = f.book_id, file = f.file, finished_on = f.finished_on,
        final_pos = f.final_pos, rating = f.rating, status_seen = f.status_seen,
        created_at = f.now or 0, attempts = 0, next_try_at = 0, parked = false,
    }
end

-- One job per book, the newest local intent wins (§3): a new job replaces the book's old one,
-- keeping a rating given earlier unless the new one carries its own.
function Finish.put(queue, job)
    local old = queue[job.hash]
    if old and job.rating == nil then job.rating = old.rating end
    queue[job.hash] = job
    return job
end

-- Undo, "Mark as reading" or a reread deletes the unsent job.
function Finish.cancel(queue, hash)
    local had = queue[hash] ~= nil
    queue[hash] = nil
    return had
end

-- A rating on the end screen: 1..5, the same star again clears it ("clear"), nil leaves it.
function Finish.setRating(job, stars, current)
    if stars == nil then return job.rating end
    if current == stars then job.rating = "clear" else job.rating = stars end
    return job.rating
end

-- Jobs to send now, oldest first. manual: a sync the reader asked for also retries parked jobs.
function Finish.due(queue, now, manual)
    local out = {}
    for _, job in pairs(queue) do
        if (manual or not job.parked) and (manual or (job.next_try_at or 0) <= now) then
            table.insert(out, job)
        end
    end
    table.sort(out, function(a, b)
        if a.created_at == b.created_at then return tostring(a.hash) < tostring(b.hash) end
        return a.created_at < b.created_at
    end)
    return out
end

-- Steps 4 and 5 from the guard read (step 3, `GET catalog/books/:id`, server S9/S11):
-- { read_status = bool, rating = nil | 1..5 | "clear", reason = text }.
function Finish.plan(job, server_status)
    local p = { read_status = true, rating = job.rating, reason = "send" }
    if server_status == "read" then
        p.read_status, p.reason = false, "already read"
    elseif Finish.DELIBERATE[server_status] and server_status ~= job.status_seen then
        p.read_status, p.reason = false, "changed elsewhere to " .. server_status
    end
    return p
end

-- What to do after a failed request: "retry" (backoff, parked after MAX_ATTEMPTS), "auth"
-- (keep it, ask to sign in) or "drop" (the server refused it for good). code: HTTP status or nil
-- (network error, timeout).
function Finish.onError(job, code, now)
    code = tonumber(code)
    if code == 401 then return "auth" end
    if code == 400 or code == 403 or code == 404 then return "drop" end
    job.attempts = (job.attempts or 0) + 1
    local wait = math.min(Finish.BACKOFF_MAX, Finish.BACKOFF_FIRST * 2 ^ (job.attempts - 1))
    job.next_try_at = now + wait
    if job.attempts >= Finish.MAX_ATTEMPTS then job.parked = true end
    return "retry"
end

-- The day a finish happened, or nil when the clock can't be trusted (G19).
function Finish.day(t, date_fn)
    if type(t) ~= "number" or t < 1577836800 then return nil end -- before 2020: unset clock
    return (date_fn or os.date)("%Y-%m-%d", t)
end

---------------------------------------------------------------- next, suggestions, author (§6)

local function num(v)
    if type(v) == "number" then return v end
    if type(v) == "string" then return tonumber(v) end
    return nil
end

-- The book after this one in its series (detail = `GET catalog/books/:id`, server S13/S14):
--   { kind = "next", book = member, read = bool }
--   { kind = "gap", number = n }        "Book n isn't in your library" (D3: no skip ahead)
--   { kind = "series_done" }            "You've finished the series"
--   { kind = "last_unread", book = m }  "Last book · not read yet: Book n"
--   nil                                 not in a series
function Finish.next(detail)
    if type(detail) ~= "table" then return nil end
    local c = num(detail.seriesIndex)
    if detail.seriesId == nil or c == nil then return nil end
    local after, all_read, first_unread = {}, true, nil
    for _, m in ipairs(detail.seriesMembers or {}) do
        local i = num(m.seriesIndex)
        if m.id ~= detail.id and i ~= nil then
            if i > c then table.insert(after, { m = m, i = i }) end
            if m.readStatus ~= "read" then
                all_read = false
                if not first_unread or i < first_unread.i or (i == first_unread.i and m.id < first_unread.m.id) then
                    first_unread = { m = m, i = i }
                end
            end
        end
    end
    table.sort(after, function(a, b) if a.i == b.i then return a.m.id < b.m.id end return a.i < b.i end)
    local nxt = after[1]
    if not nxt then
        if all_read or not first_unread then return { kind = "series_done" } end
        return { kind = "last_unread", book = first_unread.m, number = first_unread.i }
    end
    local whole = math.floor(c) + 1
    if nxt.i > whole then return { kind = "gap", number = whole } end
    return { kind = "next", book = nxt.m, number = nxt.i, read = nxt.m.readStatus == "read" }
end

-- Suggestions: the first books of relatedSections "author", then "similar", skipping this book,
-- the next one and anything read (the related books carry no status, so read is known only from
-- seriesMembers). limit: 1 on Android, 2 on Xteink. Each: { book, source = "author"|"similar" }.
function Finish.suggestions(detail, limit, next_id)
    local out, skip = {}, { [detail and detail.id or -1] = true }
    if next_id then skip[next_id] = true end
    for _, m in ipairs(detail and detail.seriesMembers or {}) do
        if m.readStatus == "read" then skip[m.id] = true end
    end
    local by = {}
    for _, s in ipairs(detail and detail.relatedSections or {}) do by[s.id] = s end
    for _, src in ipairs({ "author", "similar" }) do
        for _, b in ipairs(by[src] and by[src].books or {}) do
            if #out >= (limit or 1) then return out end
            if not skip[b.id] and b.readStatus ~= "read" then
                skip[b.id] = true
                table.insert(out, { book = b, source = src })
            end
        end
    end
    return out
end

-- The author link (S16: the author list takes a name): authors[1], or nil.
function Finish.author(detail)
    local a = detail and detail.authors and detail.authors[1]
    if type(a) == "string" and a ~= "" then return a end
    return nil
end

-- The words on the card for a picker result. on_device: is that book on this device.
function Finish.nextCard(n, on_device)
    if not n then return nil end
    if n.kind == "gap" then
        return { line = string.format("Book %s isn't in your library", Finish.fmtNum(n.number)) }
    elseif n.kind == "series_done" then
        return { line = "You've finished the series" }
    end
    local b = n.book
    local head = n.kind == "last_unread"
        and string.format("Last book · not read yet: Book %s", Finish.fmtNum(n.number))
        or string.format("Next in series · Book %s%s", Finish.fmtNum(n.number), n.read and " · Read" or "")
    return { line = head, title = b.title, book_id = b.id, action = on_device and "open" or "download" }
end

function Finish.fmtNum(v)
    if v == nil then return "?" end
    if v == math.floor(v) then return string.format("%d", v) end
    return (string.format("%.2f", v):gsub("0+$", ""))
end

---------------------------------------------------------------- stale-push hold (§7)

-- Hold a progress push for a book finished on this device? final: the finish position (%),
-- push: the position about to be sent (%), forward: page turns forward this session,
-- released: the reader pressed Undo / Read again.
function Finish.holdPush(final, push, forward, released)
    if released or type(final) ~= "number" or type(push) ~= "number" then return false end
    if (forward or 0) >= Finish.HOLD_RELEASE_PAGES then return false end
    return push <= final - Finish.HOLD_POINTS
end

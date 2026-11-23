-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Keep book copies current (v0.11.1, docs/design/keep-copies-current.md). BookOrbit writes
-- metadata into the library file (tags, series), so its partial MD5 moves and every copy on a
-- reader stops matching it: the server marks those copies position-incompatible and progress,
-- highlights and bookmarks stop syncing. These are the pure rules: which copies changed, which
-- file replaces them, where KOReader keeps a hash-keyed sidecar.

CopiesPlan = {}

-- books: BookOrbit's state books (md5 -> { file, bookId, fileId, positionIncompatible });
-- details: book id (string) -> a detail we saved ({ files = { { id, fileHash } } }).
-- Returns { { md5, path, book_id, file_id, why = "incompatible" | "hash" } }, by path.
function CopiesPlan.candidates(books, details)
    local out = {}
    for md5, b in pairs(books or {}) do
        if type(b) == "table" and type(b.file) == "string" and b.bookId ~= nil then
            local why
            if b.positionIncompatible == true then why = "incompatible" end
            local d = details and details[tostring(b.bookId)]
            if not why and type(d) == "table" and type(d.files) == "table" then
                for _, f in ipairs(d.files) do
                    if f.id == b.fileId and type(f.fileHash) == "string" and f.fileHash ~= md5 then why = "hash" end
                end
            end
            if why then
                table.insert(out, { md5 = md5, path = b.file, book_id = b.bookId, file_id = b.fileId, why = why })
            end
        end
    end
    table.sort(out, function(a, b) return a.path < b.path end)
    return out
end

-- The file that replaces the copy: the same library file when the delivery detail lists it,
-- else the primary one, else the first.
function CopiesPlan.pick(files, file_id)
    if type(files) ~= "table" then return nil end
    for _, f in ipairs(files) do if file_id ~= nil and f.id == file_id then return f end end
    for _, f in ipairs(files) do if f.role == "primary" then return f end end
    return files[1]
end

-- "same" (the copy already is the file), "replace", or "unknown" (no hash to check against:
-- never replaced blind).
function CopiesPlan.decide(local_md5, file)
    if type(file) ~= "table" or type(file.fileHash) ~= "string" or file.fileHash == "" then return "unknown" end
    if local_md5 == file.fileHash then return "same" end
    return "replace"
end

-- KOReader's hash-keyed sidecar folder (docsettings.lua getSidecarDir, "hash" location).
function CopiesPlan.hashSidecar(root, md5)
    return string.format("%s/%s/%s.sdr", root, md5:sub(1, 2), md5)
end

-- Adds the new candidates to the queue (by path, once); returns how many were added.
function CopiesPlan.enqueue(queue, found)
    local have, added = {}, 0
    for _, j in ipairs(queue) do have[j.path] = true end
    for _, c in ipairs(found) do
        if not have[c.path] then table.insert(queue, c); have[c.path] = true; added = added + 1 end
    end
    return added
end

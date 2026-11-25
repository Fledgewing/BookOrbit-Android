-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Keep book copies current (v0.11.1, docs/design/keep-copies-current.md). BookOrbit writes
-- metadata into the library file (tags, series), so its partial MD5 moves and every copy on a
-- reader stops matching it: the server marks those copies position-incompatible and progress,
-- highlights and bookmarks stop syncing. These are the pure rules: which copies changed, which
-- file replaces them, where KOReader keeps a hash-keyed sidecar. Which copies changed is
-- Orbit Companion's lookup (CopiesLogic).

CopiesPlan = {}

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

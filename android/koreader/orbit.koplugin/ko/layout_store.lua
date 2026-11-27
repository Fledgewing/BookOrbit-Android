-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Existing atomic layout persistence, separate from pure editor/geometry helpers.
LayoutStore={}
-- writeFile MUST publish atomically. Backup is published before the new primary.
function LayoutStore.load(path, io, codec, registry)
    local raw=io.readFile(path,Layout.MAX_BYTES+1)
    local d,err=Layout.parse(raw,codec,registry)
    if d then return d end
    local backup=Layout.parse(io.readFile(path..".bak",Layout.MAX_BYTES+1),codec,registry)
    if backup then return backup,"Recovered previous valid layout: "..tostring(err) end
    return Layout.default(), raw and "Invalid layout; using default" or "No saved layout; using default"
end
function LayoutStore.save(path,d,io,codec,registry)
    local raw,err=Layout.serialize(d,codec,registry); if not raw then return nil,err end
    local old=io.readFile(path,Layout.MAX_BYTES+1)
    if Layout.parse(old,codec,registry) and not io.writeFile(path..".bak",old) then return nil,"backup write failed" end
    if not io.writeFile(path,raw) then return nil,"layout write failed" end
    return true
end

-- SPDX-License-Identifier: AGPL-3.0-or-later
-- The thumbnail subprocess may inspect old versions; the UI may never iterate here.
CoverChild = {}
local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")
-- The book's other cover files in dir: "<id>_<version>.jpg" with an ETag next to it.
function CoverChild.olderCover(dir, name, id)
    if not lfs_ok or not (Store.inChild() or Db.pid() ~= Store.ui_pid) then return nil end
    local best, best_t
    local prefix = "^" .. id .. "_%d+%.jpg$"
    for n in lfs.dir(dir) do
        if n ~= name and n:match(prefix) then
            local p = dir .. "/" .. n
            if Store.readFile(p .. ".etag", 200) then
                local t = lfs.attributes(p, "modification") or 0
                if not best_t or t > best_t then best, best_t = p, t end
            end
        end
    end
    return best
end


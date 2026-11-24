-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- The offline cache's SQLite database (docs/design/sqlite-cache.md): one file the Orbit Companion
-- writes; KOReader only reads it, through KOReader's own lua-ljsqlite3 (as its statistics plugin
-- does), opened read-only. Rollback journal: a read during the companion's commit waits (the busy
-- timeout) and never sees half of one.
--
-- A connection belongs to the process that opened it: SQLite connections must not cross fork(),
-- and the BookOrbit plugin reads its catalog in forked children. A child opens its own and leaves
-- the inherited one alone. A file replaced under us (the companion recreated it, or the swap
-- fallback renamed a new one in) has another inode: the next read reopens.
---------------------------------------------------------------------------------------------

Db = { BUSY_MS = 2000 }

local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then pcall(ffi.cdef, "int getpid(void);") end
local lfs_ok, lfs = pcall(require, "libs/libkoreader-lfs")

function Db.pid()
    if not ffi_ok then return 0 end
    local ok, p = pcall(function() return ffi.C.getpid() end)
    return ok and tonumber(p) or 0
end

function Db.sq3()
    local ok, m = pcall(require, "lua-ljsqlite3/init")
    return ok and m or nil
end

-- A text or blob column as a Lua string (a blob is { ptr, size } until the next step), an integer
-- as a number.
function Db.value(v)
    if type(v) == "table" and v[1] ~= nil and v[2] ~= nil and ffi_ok then return ffi.string(v[1], tonumber(v[2])) end
    if type(v) == "cdata" then return tonumber(v) end
    return v
end

-- An error's SQLite code ("busy", "corrupt", "readonly"...), from ljsqlite3's "ljsqlite3[code] msg".
function Db.code(err) return tostring(err):match("ljsqlite3%[(%w+)%]") end

-- A new connection. mode: "ro" (the default: KOReader never writes) or "rwc" (tests only).
-- busy_ms: 0 for none (the caller retries itself). -> conn, or nil, err.
function Db.connect(path, mode, busy_ms)
    local sq3 = Db.sq3()
    if not sq3 then return nil, "no lua-ljsqlite3" end
    local ok, conn = pcall(sq3.open, path, mode or "ro")
    if not ok then return nil, conn end
    if (busy_ms or Db.BUSY_MS) > 0 then pcall(conn.set_busy_timeout, conn, busy_ms or Db.BUSY_MS) end
    return conn
end

local function inode(path)
    if not lfs_ok then return 0 end
    return lfs.attributes(path, "ino") or nil
end

-- The process's connection to path, opened on first use and again after a fork or a replaced file.
-- -> conn, or nil, err ("missing" when there is no file).
Db._open = {}
function Db.conn(path)
    local ino = inode(path)
    if not ino then return nil, "missing" end
    local c = Db._open[path]
    local pid = Db.pid()
    if c and c.pid == pid and c.ino == ino then return c.conn end
    if c and c.pid == pid then pcall(c.conn.close, c.conn) end -- ours: replaced file; an inherited one is left alone
    Db._open[path] = nil
    local conn, err = Db.connect(path)
    if not conn then return nil, err end
    Db._open[path] = { conn = conn, pid = pid, ino = ino }
    return conn
end

function Db.close(path)
    local c = Db._open[path]
    Db._open[path] = nil
    if c and c.pid == Db.pid() then pcall(c.conn.close, c.conn) end
end

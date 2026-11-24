-- KOReader's lua-ljsqlite3 (vendor/lua-ljsqlite3/init.lua, a copy of koreader-base
-- thirdparty/lua-ljsqlite3 at the pinned base commit, MIT) on the host's LuaJIT and libsqlite3, so
-- the tests read SQLite through the same binding the plugin uses on the device. KOReader provides
-- ffi.loadlib and ffi/posix_h; these stand-ins do the same with the system library.
--   require("sqlite_shim") -- then require("lua-ljsqlite3/init") as the plugin does
local here = (debug.getinfo(1, "S").source or ""):match("^@(.*)/[^/]*$") or "."
local ffi = require("ffi")

if not ffi.loadlib then
    function ffi.loadlib(name, version)
        local tries = { name, "lib" .. name .. ".so." .. tostring(version), "lib" .. name .. ".so",
            "/usr/lib/lib" .. name .. ".dylib", "/opt/homebrew/opt/" .. name .. "/lib/lib" .. name .. ".dylib" }
        local last
        for _, t in ipairs(tries) do
            local ok, lib = pcall(ffi.load, t)
            if ok then return lib end
            last = lib
        end
        error("no " .. name .. " library: " .. tostring(last))
    end
end

package.preload["ffi/posix_h"] = package.preload["ffi/posix_h"] or function()
    pcall(ffi.cdef, "void free(void *);")
    return true
end

package.path = here .. "/vendor/?.lua;" .. package.path
return require("lua-ljsqlite3/init")

-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Background work never announces itself, even on Home. Keep the scope per
-- coroutine: a yielding download must not silence the user's next menu action.
Gate.backgrounds = setmetatable({}, { __mode = "k" })
local main = {}
function Gate.inBackground()
    return Gate.backgrounds[coroutine.running() or main] == true
end
function Gate.silent()
    return Gate.inBackground() or Library.catalog_active
end
function Gate.withBackground(background, fn, ...)
    local key = coroutine.running() or main
    local previous = Gate.backgrounds[key]
    Gate.backgrounds[key] = background
    local result = pack(pcall(fn, ...))
    Gate.backgrounds[key] = previous
    if not result[1] then error(result[2], 0) end
    return unpack(result, 2, result.n)
end
function Gate.background(fn, ...)
    return Gate.withBackground(true, fn, ...)
end
Gate.callbacks = setmetatable({}, { __mode = "kv" })
function Gate.bind(fn)
    if Gate.callbacks[fn] then return Gate.callbacks[fn] end
    local quiet = function(...) return Gate.background(fn, ...) end
    Gate.callbacks[fn], Gate.callbacks[quiet] = quiet, quiet
    return quiet
end

-- Propagate only the background scope, including into upstream callbacks.
-- Stable wrappers preserve unschedule, arguments and repeated registrations.
for _, name in ipairs({ "scheduleIn", "nextTick" }) do
    local stock = UIManager[name]
    UIManager[name] = function(self, ...)
        local args = pack(...)
        local index = name == "scheduleIn" and 2 or 1
        if Gate.inBackground() and type(args[index]) == "function" then args[index] = Gate.bind(args[index]) end
        return stock(self, unpack(args, 1, args.n))
    end
end
local unschedule = UIManager.unschedule
function UIManager:unschedule(fn, ...)
    if Gate.callbacks[fn] then unschedule(self, Gate.callbacks[fn], ...) end
    return unschedule(self, fn, ...)
end

function Gate.installTrapper()
    local ok, Trapper = pcall(require, "ui/trapper")
    if not ok or type(Trapper) ~= "table" then return end
    if type(Trapper.wrap) == "function" then
        wrap(Trapper, "wrap", function(stock) return function(self, fn, ...)
            return stock(self, Gate.inBackground() and Gate.bind(fn) or fn, ...)
        end end, "background_notices")
    end
    if type(Trapper.info) == "function" then
        wrap(Trapper, "info", function(stock) return function(self, text, ...)
            if Gate.silent() then
                if text then Gate.refreshNotice("Trapper: " .. tostring(text)) end
                return true -- keep working; no widget, delay or dismissal check
            end
            return stock(self, text, ...)
        end end, "background_notices")
    end
end

-- The native sync coordinator can run a queued job in another job's callback.
-- Bind the job itself, rather than relying on the scheduler's current scope.
function Gate.installPlugin(p)
    if not p or type(p.submitSyncJob) ~= "function" then return end
    wrap(p, "submitSyncJob", function(stock) return function(self, job, ...)
        local background = job.interactive ~= true
        for _, key in ipairs({ "run", "on_done", "on_error", "on_queued" }) do
            local fn = job[key]
            if type(fn) == "function" then
                job[key] = function(...) return Gate.withBackground(background, fn, ...) end
            end
        end
        return Gate.withBackground(background, stock, self, job, ...)
    end end, "background_notices")
end

-- Automatic entry points, including replies/repaints after a manual refresh has
-- finished. Full refresh's explicitly tagged progress notice remains visible.
local function quietMethods(t, names)
    for _, name in ipairs(names) do
        if type(t[name]) == "function" then t[name] = Gate.bind(t[name]) end
    end
end
quietMethods(OrbitAndroid, { "init", "onResume", "onReaderReady", "onSuspend", "wakeFlow", "showWakeBanner", "bookOpenFlow", "readingSync", "onNetworkConnected" })


function Gate.installCatalog() end

-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- KOReader's key path: Input:handleKeyBoardEv (input.lua:723), called for every EV_KEY at
-- :1814. On Android every key the activity gets becomes an EV_KEY with the Android keycode
-- (ffi/input_android.lua keyEventHandler:195-231), letters and gamepad buttons included;
-- media keys, power and (when KOReader ignores them) volume keys are handed back to Android
-- unconsumed and never reach Lua, so only the companion's service can map those.
-- Returning nothing drops the event, so a mapped key never also does KOReader's own thing.
-- Installed on the Input class and on the live Device.input: inhibitInput (input.lua:1859-1905,
-- used by ReaderUI:init and suspend) copies the handler onto the instance, which then shadows
-- the class.
---------------------------------------------------------------------------------------------

key_wrappers = setmetatable({}, { __mode = "k" })

function Clicks.handleKey(self, ev, stock)
    local acts = ev and Clicks.map[ev.code]
    local result
    if acts and Clicks.ownPath(Channel.up, Channel.service_on) then
        local ok, mine = pcall(Clicks.onKey, ev)
        if ok and mine then result = "mapped (own path)" end
        if not ok then log("clicker: key handler error:", mine) end
    elseif acts then
        result = nil -- the companion's service has it; anything that still arrives is KOReader's
    end
    if S.key_log and ev and ev.code then
        local name = self and type(self.event_map) == "table" and self.event_map[ev.code] or "?"
        local what = result or (acts and "pass (service handles mapped keys)" or "pass")
        log("key", ev.code, name, ev.value == 1 and "down" or ev.value == 0 and "up" or "repeat", "->", what)
    end
    if result then return end
    return stock(self, ev)
end

function wrapKey(stock)
    local w = function(self, ev) return Clicks.handleKey(self, ev, stock) end
    key_wrappers[w] = true
    return w
end

function Clicks.install(why)
    local okI, Input = pcall(require, "device/input")
    if okI and type(Input) == "table" and type(Input.handleKeyBoardEv) == "function" and not key_wrappers[Input.handleKeyBoardEv] then
        Input.handleKeyBoardEv = wrapKey(Input.handleKeyBoardEv)
        log("clicker: key hook on Input (" .. why .. ")")
    end
    local inst = type(Device) == "table" and rawget(Device, "input") or nil
    if type(inst) == "table" and inst ~= Input then
        for _i, field in ipairs({ "handleKeyBoardEv", "_key_ev_handler" }) do
            local own = rawget(inst, field)
            -- handleKeyBoardEv is the power-only handler while input is inhibited: leave it.
            local inhibited = field == "handleKeyBoardEv" and rawget(inst, "_key_ev_handler") ~= nil
            if type(own) == "function" and not key_wrappers[own] and not inhibited then
                inst[field] = wrapKey(own)
                log("clicker: key hook on Device.input." .. field .. " (" .. why .. ")")
            end
        end
    end
end
Clicks.install("load")

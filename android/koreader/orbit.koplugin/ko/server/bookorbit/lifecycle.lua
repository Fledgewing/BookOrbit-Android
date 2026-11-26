-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync.
-- Legacy upstream lifecycle/settings bindings, loaded after ko/module.lua.

-- "Sync while reading" replaces the plugin's every-few-pages push while it is on.
-- The plugin's every-few-pages push is its user setting "Push while reading"
-- (settings.pages_before_update, bookorbit_settings_page.lua:259-260; read by _onPageUpdate,
-- main.lua:1322-1324; 0 = off). While our Sync while reading is on we set it to 0 and keep the
-- reader's value; when it goes off we put that value back (unless they changed it meanwhile).
function OrbitAndroid:hookPluginPagePush()
    local p = serverPlugin(self.ui)
    if not p or type(p.settings) ~= "table" then return end
    local cur = p.settings.pages_before_update
    -- OrbiSmart pushes at a pause instead (docs/design/position-sync.md §3.3).
    if S.reading_schedule ~= "off" or (OSM and OSM.on()) then
        if S.saved_pages_before_update == nil and (cur or 0) > 0 then
            S.saved_pages_before_update = cur
            p.settings.pages_before_update = 0
            saveSettings()
            log("page push: plugin's Push while reading", cur, "-> off while Sync while reading is on")
        end
    elseif S.saved_pages_before_update ~= nil then
        if (cur or 0) == 0 then
            p.settings.pages_before_update = S.saved_pages_before_update
            log("page push: plugin's Push while reading restored to", S.saved_pages_before_update)
        end
        S.saved_pages_before_update = nil
        saveSettings()
    end
end

---------------------------------------------------------------------------------------------

-- BookOrbit snapshots the open book into its outbox on every Suspend (main.lua:1340-1351), and
-- Android sends Suspend on every app switch: each press of the Home key bounces through the
-- companion's launcher and back (logged "home press: START_KOREADER"), so every press synced the
-- book again ("book sync done reason=recovery", the label every outbox drain carries,
-- bookorbit_book_sync.lua:169). With the screen on, a snapshot of a book that hasn't moved since
-- its last one is skipped; a real sleep, a close and Sync and sleep always snapshot.
function snapshotKey(p, ui)
    local okd, digest = pcall(p.getDocumentDigest, p)
    if not okd or not digest then return nil end
    local okp, pct = pcall(p.getLastPercent, p)
    local ann = ui and ui.annotation and ui.annotation.annotations
    local okst, status = pcall(function() return ui.doc_settings:readSetting("summary").status end)
    return table.concat({ tostring(digest), tostring(okp and pct or "?"), tostring(p.last_page or "?"),
        tostring(type(ann) == "table" and #ann or "?"), tostring(okst and status or "?") }, "|")
end

function OrbitAndroid:hookSuspendSnapshot()
    local p = serverPlugin(self.ui)
    if not p or type(p._onSuspend) ~= "function" or rawget(p, "_orbit_snapshot_hooked") then return end
    local orig = p._onSuspend
    p._orbit_snapshot_hooked = true
    p._onSuspend = function(plugin, ...)
        local key = snapshotKey(plugin, self.ui)
        if not state.force_snapshot and key and key == state.last_snapshot_key and Jni.isInteractive() == true then
            log("suspend: app switch and the book hasn't moved since its last snapshot; library's snapshot skipped")
            return
        end
        state.last_snapshot_key = key
        return orig(plugin, ...)
    end
    if p.onSuspend == orig then p.onSuspend = p._onSuspend end
end

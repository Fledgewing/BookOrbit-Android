-- SPDX-License-Identifier: AGPL-3.0-or-later
function OrbitAndroid:testSyncPath()
    local wait=InfoMessage:new{text=_("Testing the sync path…")}
    UIManager:show(wait) -- gate: user action (menu)
    UIManager:forceRePaint()
    return Library.testSyncPath(function(text)
        UIManager:close(wait)
        UIManager:show(TextViewer:new{title=_("Test sync path"),text=text}) -- gate: user action (menu)
    end)
end

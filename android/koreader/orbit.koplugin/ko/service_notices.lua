-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Presentation only. Callers select the lifecycle moment; the reading gate remains final.
ServiceNotices={}
function ServiceNotices.info(args) return InfoMessage:new(args) end
function ServiceNotices.showInfo(args)
    local widget=ServiceNotices.info(args)
    UIManager:show(widget) -- gate: existing lifecycle or explicit user operation; Gate.installToast is final
    return widget
end

function ServiceNotices.progress(args)
    local widget=ServiceNotices.showInfo(args)
    UIManager:forceRePaint()
    return widget
end

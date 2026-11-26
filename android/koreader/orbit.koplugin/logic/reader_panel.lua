-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Display only: already joined, bounded library rows. No catalog or statistics work here.
ReaderPanelPlan = {}
function ReaderPanelPlan.model(result, battery)
    local b = result.items and result.items[1] or {}
    local pct = tonumber(b.progress)
    if pct and (pct ~= pct or pct == math.huge or pct == -math.huge) then pct = nil end
    if pct then pct = math.max(0, math.min(100, pct)) end
    local stats = b.stats or {}
    local hours = battery and tonumber(battery.hours_usual_use)
    local battery_text = "Battery estimate not available yet"
    if hours and hours == hours and hours >= 0 and hours < math.huge then
        local whole = math.floor(hours)
        local days, rest = math.floor(whole/24), whole%24
        local duration = days > 0 and (tostring(days) .. " d " .. tostring(rest) .. " h") or (tostring(rest) .. " h")
        battery_text = "≈ " .. duration .. " left at your usual use"
    end
    return { key=b.key, title=b.title or "Book info not saved yet",
        author=table.concat(b.authors or {}, ", "), progress=pct and pct/100,
        progress_text=pct and (string.format("%d%% read", math.floor(pct+0.5))) or "Progress not saved yet",
        battery=battery_text,
        days=stats.days_start_to_finish and (tostring(stats.days_start_to_finish) .. " days start to finish") or "Days start to finish: not saved yet",
        time=stats.reading_seconds and (tostring(math.floor(stats.reading_seconds/60)) .. " min reading time") or "Reading time: not saved yet",
        pages=stats.pages_read and (tostring(stats.pages_read) .. " pages read") or "Pages read: not saved yet" }
end

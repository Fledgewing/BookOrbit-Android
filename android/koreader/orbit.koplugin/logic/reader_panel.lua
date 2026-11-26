-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Display only: already joined, bounded library rows. No catalog or statistics work here.
ReaderPanelPlan = {}
-- Scalar display conversion only; all battery predictions are companion-owned.
function ReaderPanelPlan.duration(value, minutes)
    local hours=tonumber(value)
    if not hours or hours~=hours or hours<0 or hours==math.huge then return nil end
    if minutes and hours<1 then return math.floor(hours*60).." min" end
    local whole=math.floor(hours)
    local days,rest=math.floor(whole/24),whole%24
    return days>0 and (days.." d "..rest.." h") or (rest.." h")
end
function ReaderPanelPlan.model(result, battery)
    local b = result.items and result.items[1] or {}
    local pct = tonumber(b.progress)
    if pct and (pct ~= pct or pct == math.huge or pct == -math.huge) then pct = nil end
    if pct then pct = math.max(0, math.min(100, pct)) end
    local stats = b.stats or {}
    local battery_text=battery and battery.display and battery.display.page_estimate
        or "Battery estimate not available yet"
    return { key=b.key, title=b.title or "Book info not saved yet",
        author=table.concat(b.authors or {}, ", "), progress=pct and pct/100,
        progress_text=pct and (string.format("%d%% read", math.floor(pct+0.5))) or "Progress not saved yet",
        battery=battery_text,
        days=stats.days_start_to_finish and (tostring(stats.days_start_to_finish) .. " days start to finish") or "Days start to finish: not saved yet",
        time=stats.reading_seconds and (tostring(math.floor(stats.reading_seconds/60)) .. " min reading time") or "Reading time: not saved yet",
        pages=stats.pages_read and (tostring(stats.pages_read) .. " pages read") or "Pages read: not saved yet" }
end

-- Quick-size steps wrap through the approved M8C choices, including a native size
-- outside the preset list. No style/catalog work occurs in this projection.
local FONT_SIZES={16,18,20,22,24,27}
function ReaderPanelPlan.sizeIndex(current)
    local index=1
    for i,value in ipairs(FONT_SIZES) do if math.abs(value-current)<math.abs(FONT_SIZES[index]-current) then index=i end end
    return index
end
function ReaderPanelPlan.fontSize(current,delta)
    return FONT_SIZES[(ReaderPanelPlan.sizeIndex(current)-1+delta)%#FONT_SIZES+1]
end
function ReaderPanelPlan.sizeDots(current)
    local selected=ReaderPanelPlan.sizeIndex(current)
    local dots={}
    for i=1,#FONT_SIZES do dots[i]=i<=selected and "●" or "○" end
    return table.concat(dots)
end

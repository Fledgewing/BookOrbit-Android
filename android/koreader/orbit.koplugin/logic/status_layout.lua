-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Pure reading-strip formatting and physical (not bidi) anchors.
StatusLayout = {}
function StatusLayout.progress(page, total, fraction)
    if type(total) ~= "number" or total <= 0 or type(page) ~= "number" then return "" end
    local pct = math.floor(math.max(0, math.min(1, fraction or page / total)) * 100 + 0.5)
    return string.format("%d / %d · %d%%", page, total, pct)
end
function StatusLayout.clock(hour, minute, twelve)
    if twelve then return string.format("%d:%02d %s", (hour + 11) % 12 + 1, minute, hour < 12 and "AM" or "PM") end
    return string.format("%02d:%02d", hour, minute)
end
function StatusLayout.truncate(text, width, measure)
    text = (text or ""):gsub("[\r\n]", " ")
    if measure(text) <= width then return text end
    if measure("…") > width then return "" end
    local chars = {}
    for c in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars+1] = c end
    local lo, hi = 0, #chars
    while lo < hi do
        local mid = math.ceil((lo + hi) / 2)
        if measure(table.concat(chars, "", 1, mid) .. "…") <= width then lo = mid else hi = mid - 1 end
    end
    return table.concat(chars, "", 1, lo) .. "…"
end
function StatusLayout.layout(width, inset, gap, battery, icon, chapter, progress, measure, keep_battery)
    local left = battery
    local available = math.max(0, width-2*inset)
    if keep_battery then
        -- Keep percentage and charging mark together; shorten lower-priority page text.
        if measure(left) > available then left = "" end
        available = math.max(0, available - (left ~= "" and measure(left)+gap or 0))
    end
    progress = StatusLayout.truncate(progress, available, measure)
    local right = width - inset - measure(progress)
    if not keep_battery then
        if inset + measure(left) + gap > right then left = icon end
        if inset + measure(left) + gap > right then left = "" end
    end
    local inner = math.max(inset, inset + measure(left)) + gap
    local half = math.max(0, math.min(width/2 - inner, right - gap - width/2))
    local title = StatusLayout.truncate(chapter, half * 2, measure)
    return { left = left, chapter = title, right = progress, lx = inset,
        cx = (width - measure(title))/2, rx = right }
end

-- Small uses the largest face fitting the margin (up to 48 pt); explicit sizes cap it.
StatusLayout.SIZES = { small = 48, medium = 18, large = 22 }
function StatusLayout.fontSize(choice) return StatusLayout.SIZES[choice] or 48 end
function StatusLayout.stripHeight(text_height, padding) return math.ceil(text_height) + 2 * padding end
-- Fit actual font metrics to each margin independently; the configured size is a maximum.
function StatusLayout.fit(margin, maximum, padding, measureHeight)
    margin = math.max(0, math.floor(margin or 0))
    local wanted = StatusLayout.stripHeight(measureHeight(maximum), padding)
    for size = maximum, 1, -1 do
        local height = StatusLayout.stripHeight(measureHeight(size), padding)
        if height <= margin then return { size=size, height=height, extra=0, wanted=wanted } end
    end
    return { size=0, height=0, extra=0, wanted=wanted }
end
-- Both Android renderers interpret shared/ui/battery.json.
BatteryGlyph = {}
function BatteryGlyph.draw(program, size, capacity, rectangle)
    for _, r in ipairs(program.rectangles) do
        local fraction = r[6] and math.max(0, math.min(100, capacity))/100 or 1
        rectangle(r[1]*size, r[2]*size, r[3]*size*fraction, r[4]*size, r[5])
    end
end

-- A separate black charging mark keeps its polarity independent of battery fill.
-- Seven by nine pixel silhouette, scaled to the same safe height as the battery.
function StatusLayout.chargingMark(height, rectangle)
    local unit = height / 9
    if rectangle then
        for row, run in ipairs({{3,2},{2,3},{1,3},{0,7},{3,3},{2,3},{2,2},{1,2},{1,1}}) do
            rectangle(run[1]*unit, (row-1)*unit, run[2]*unit, unit, 1)
        end
    end
    return 7*unit
end

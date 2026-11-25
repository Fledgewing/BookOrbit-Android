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
function StatusLayout.layout(width, inset, gap, battery, icon, chapter, progress, measure)
    local right = width - inset - measure(progress)
    local left = battery
    if inset + measure(left) + gap > right then left = icon end
    if inset + measure(left) + gap > right then left = "" end
    local inner = math.max(inset, inset + measure(left)) + gap
    local half = math.max(0, math.min(width/2 - inner, right - gap - width/2))
    local title = StatusLayout.truncate(chapter, half * 2, measure)
    return { left = left, chapter = title, right = progress, lx = inset,
        cx = (width - measure(title))/2, rx = right }
end

-- Sizes are unscaled font points, like KOReader's footer default (14).
StatusLayout.SIZES = { small = 14, medium = 18, large = 22 }
function StatusLayout.fontSize(choice) return StatusLayout.SIZES[choice] or 14 end
function StatusLayout.stripHeight(text_height, padding) return math.ceil(text_height) + 2 * padding end
-- Fit actual font metrics to each margin independently; the configured size is a maximum.
function StatusLayout.fit(margin, maximum, padding, measureHeight, add)
    margin = math.max(0, math.floor(margin or 0))
    local wanted = StatusLayout.stripHeight(measureHeight(maximum), padding)
    local extra = add and math.max(0, wanted - margin) or 0
    local available = margin + extra
    for size = maximum, 1, -1 do
        local height = StatusLayout.stripHeight(measureHeight(size), padding)
        if height <= available then return { size=size, height=height, extra=extra, wanted=wanted } end
    end
    return { size=0, height=0, extra=extra, wanted=wanted }
end
-- Both Android renderers interpret shared/ui/battery.json; no status-specific geometry.
BatteryGlyph = {}
function BatteryGlyph.draw(program, size, capacity, rectangle)
    for _, r in ipairs(program.rectangles) do
        local fraction = r[6] and math.max(0, math.min(100, capacity))/100 or 1
        rectangle(r[1]*size, r[2]*size, r[3]*size*fraction, r[4]*size, r[5])
    end
end

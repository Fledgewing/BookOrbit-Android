-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of Orbify (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Where each row of the end-of-book sheet goes (docs/design/end-of-book/mockups.html, Android
-- screens 1-6). Pure: no widgets, so tests can check the geometry the device gets.
--   SheetLayout.blocks(flat): the sheet's tap rows (EndSheet:rows) grouped into layout rows.
--   SheetLayout.plan(blocks, m): { w, h, pad, items = { { block, x, y, w, h } } } in sheet
--     coordinates (y from the sheet's top edge, below its rule). m: metrics in pixels:
--     w (screen width), pad, gap, gap_small, rule, body, small, title, button, star, card,
--     and measured = { [block] = h } for rows whose widget came out taller than planned.
-- Rows never overlap; every row spans the same inner width, padded evenly on both sides.
---------------------------------------------------------------------------------------------

SheetLayout = {}

-- Rows that sit tight under the row before them (a heading and its line, a label and its card).
local TIGHT = { author = true, series = true, hint = true, card = true }

function SheetLayout.blocks(flat)
    local out, stars, footer, hint = {}, nil, nil, nil
    for _, r in ipairs(flat) do
        if r.kind == "star" then
            if not stars then stars = { kind = "stars", items = {} }; table.insert(out, stars) end
            table.insert(stars.items, r)
        elseif r.kind == "footer" then
            if not footer then footer = { kind = "footer", items = {} }; table.insert(out, footer) end
            table.insert(footer.items, r)
        elseif r.kind == "hint" then
            hint = { kind = "hint", text = r.text, items = {} }
            table.insert(out, hint)
        elseif r.kind == "review" and hint then
            table.insert(hint.items, r)
        else
            table.insert(out, { kind = r.kind, text = r.text, row = r, items = { r } })
        end
    end
    return out
end

function SheetLayout.height(block, m)
    local k = block.kind
    local h
    if k == "status" then h = math.max(m.body, m.button)
    elseif k == "title" then h = m.title
    elseif k == "author" or k == "series" or k == "hint" or k == "label" then h = m.small
    elseif k == "stars" then h = m.star
    elseif k == "card" then h = m.card
    elseif k == "notice" then h = m.body
    elseif k == "button" or k == "footer" then h = m.button
    else h = m.body end
    local measured = m.measured and m.measured[block]
    if measured and measured > h then h = measured end
    return h
end

function SheetLayout.plan(blocks, m)
    local inner = m.w - 2 * m.pad
    local items, y = {}, m.rule + m.pad
    for i, b in ipairs(blocks) do
        if i > 1 then y = y + ((TIGHT[b.kind] and m.gap_small) or m.gap) end
        -- The footer sits apart from the content above it.
        if b.kind == "footer" and i > 1 then y = y + m.gap end
        local h = SheetLayout.height(b, m)
        table.insert(items, { block = b, kind = b.kind, x = m.pad, y = y, w = inner, h = h })
        y = y + h
    end
    return { w = m.w, h = y + m.pad, pad = m.pad, inner = inner, items = items }
end

-- Inside one row: n equal cells across w (footer buttons), and a centred group of n square
-- tap targets no wider than max each (the stars). Each returns { { x, w } } relative to the row.
function SheetLayout.split(w, n, sep)
    sep = sep or 0
    local cell = math.floor((w - sep * (n - 1)) / n)
    local out = {}
    for i = 1, n do table.insert(out, { x = (i - 1) * (cell + sep), w = cell }) end
    return out
end

function SheetLayout.centred(w, n, max)
    local cell = math.min(max, math.floor(w / n))
    local x0 = math.floor((w - cell * n) / 2)
    local out = {}
    for i = 1, n do table.insert(out, { x = x0 + (i - 1) * cell, w = cell }) end
    return out
end

-- Font sizes (KOReader scales them by Screen:scaleBySize too) per text in the sheet.
SheetLayout.FONTS = { status = 18, title = 22, author = 16, series = 15, label = 15, hint = 14,
    review = 15, star = 30, card_title = 17, card_sub = 14, notice = 15 }
-- A text line's height for a font size: KOReader's line height runs about 1.35x the face size.
SheetLayout.LINE = 1.4

-- Metrics for a screen: scale(px) is KOReader's Screen:scaleBySize.
function SheetLayout.metrics(screen_w, scale)
    return {
        w = screen_w, pad = scale(16), gap = scale(12), gap_small = scale(4), rule = scale(2),
        body = scale(26), small = scale(24), title = scale(32), button = scale(44),
        star = scale(48), card = scale(72), cover_w = scale(48), action_w = scale(150),
    }
end

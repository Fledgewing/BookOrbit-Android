-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Fledgewing. Part of BookSync (see android/koreader/LICENSE).
-- Part of orbit.koplugin: loaded by main.lua into the plugin's shared environment, in the
-- order main.lua lists (docs/design/orbit-plugin.md "Module layout").

-- Battery stats (docs/design/STATS-DESIGN.md): the patch counts page turns and screen refreshes and
-- sends them to the companion in batches (STATS), never per page. The companion stores them.
---------------------------------------------------------------------------------------------

Stats = { INTERVAL = 300 }

function set(list) local t = {} for w in list:gmatch("%S+") do t[w] = true end return t end
Stats.TEXT = set("epub epub3 fb2 fb3 txt text html htm xhtml mobi azw azw3 prc pdb doc docx rtf odt md chm")
Stats.COMIC = set("cbz cbr cb7 cbt jpg jpeg png gif webp bmp tif tiff")
Stats.PDF = set("pdf djvu djv xps oxps")
-- Flashing refreshes (refresh_methods, frontend/ui/uimanager.lua:1142-1152); the rest
-- (partial, ui, fast, a2, [ui], [partial]) are partial.
Stats.FULL = set("full flashui flashpartial")

-- text, comic, webtoon (a comic in continuous mode: ReaderView.page_scroll,
-- readerview.lua:959/986), pdf, or none (no book). Unknown extensions go by the engine.
function Stats.contentOf(file, page_scroll, paging)
    if type(file) ~= "string" or file == "" then return "none" end
    local f = file:lower():gsub("%.zip$", "")
    local ext = f:match("%.([%w]+)$")
    if ext and Stats.COMIC[ext] then return page_scroll and "webtoon" or "comic" end
    if ext and Stats.PDF[ext] then return "pdf" end
    if ext and Stats.TEXT[ext] then return "text" end
    return paging and "pdf" or "text"
end

function Stats.new(now) return { pages = 0, full = 0, partial = 0, at = now, seq = 0 } end

function Stats.refresh(acc, mode)
    if Stats.FULL[mode] then acc.full = acc.full + 1 else acc.partial = acc.partial + 1 end
end

function Stats.page(acc) acc.pages = acc.pages + 1 end

function Stats.counted(acc) return acc.pages + acc.full + acc.partial > 0 end

-- Takes the batch since the last one as STATS extras (all strings) and starts a new one.
-- content: the open book's type, or "none". open: a book stays open after this batch.
-- Nothing to send (no book and nothing counted, or paused by a suspend): nil.
function Stats.take(acc, now, content, open, extra)
    if not acc.at then return nil end
    if content == "none" and not Stats.counted(acc) then acc.at = now return nil end
    local period = math.max(0, now - acc.at)
    acc.seq = acc.seq + 1
    local out = {
        seq = tostring(acc.seq),
        period_s = tostring(math.floor(period + 0.5)),
        pages = tostring(acc.pages), full = tostring(acc.full), partial = tostring(acc.partial),
        content = content,
        open = open and "1" or "0",
        reading_min = string.format("%.1f", content ~= "none" and period / 60 or 0),
    }
    for k, v in pairs(extra or {}) do out[k] = tostring(v) end
    acc.pages, acc.full, acc.partial, acc.at = 0, 0, 0, now
    return out
end

-- When the next batch is due: every INTERVAL while a book is open or something was counted.
function Stats.isDue(acc, now, book_open)
    return acc.at ~= nil and (book_open or Stats.counted(acc)) and now - acc.at >= Stats.INTERVAL
end

---------------------------------------------------------------------------------------------

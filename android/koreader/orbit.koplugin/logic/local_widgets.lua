-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Bounded presentation only; selection and reading messages belong to the companion.
LocalWidgetPlan = {}
function LocalWidgetPlan.build(id,snapshot)
    local d=snapshot.data or {}
    local state=d.state or snapshot.state
    local ready=state=="ready" or state=="offline-with-data"
    local fallback={loading="Loading…",error="Couldn't load this widget",empty=(id=="recommended" or id=="discover") and "No unread books saved yet" or id=="yearago" and "No reading from a year ago on this device yet" or id=="highlight" and "Save a highlight while reading." or id=="word" and "Look up a word while reading." or id=="dust" and "No unopened files saved" or id=="light" and "Frontlight unavailable on this reader" or "Your next chapter is waiting.",
        ["offline-without-data"]="Not saved yet",["not-saved"]="Not saved yet",unavailable=(id=="moon" or id=="glyph" or id=="next-stop" or id=="dust") and (d.reason or (id=="next-stop" and "Open a book" or "Local date unavailable")) or "Frontlight unavailable on this reader"}
    return {title=WidgetRegistry[id].name,state=state,ready=ready,
        message=ready and (d.message or "On this reader") or (fallback[state] or "Unavailable"),
        passage=ready and d.passage,book=ready and d.book,book_title=ready and d.book_title,summary=ready and d.summary,
        word=ready and d.word,context=ready and d.context,source=ready and d.source,
        retry=state=="error" or state=="loading" or state=="offline-without-data" or state=="not-saved"}
end

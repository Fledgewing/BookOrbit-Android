-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Bounded presentation only; selection and reading messages belong to the companion.
LocalWidgetPlan = {}
function LocalWidgetPlan.build(id,snapshot)
    local d=snapshot.data or {}
    local state=d.state or snapshot.state
    local ready=state=="ready" or state=="offline-with-data"
    local fallback={loading="Loading…",error="Couldn't load this widget",empty=id=="word" and "Look up a word while reading." or "Your next chapter is waiting.",
        ["offline-without-data"]="Not saved yet",["not-saved"]="Not saved yet",unavailable="Frontlight unavailable on this reader"}
    return {title=WidgetRegistry[id].name,state=state,ready=ready,
        message=ready and (d.message or "On this reader") or (fallback[state] or "Unavailable"),
        word=ready and d.word,context=ready and d.context,source=ready and d.source,
        retry=state=="error" or state=="loading" or state=="offline-without-data" or state=="not-saved"}
end

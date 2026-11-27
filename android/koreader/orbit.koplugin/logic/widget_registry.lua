-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Semantic contracts only. Presence here is not a claim that a renderer has shipped.
-- Hosts pass their installed subset to Layout.resolve/validate. No endpoint or server JSON.
WidgetRegistry = {}
local function widget(id, source, sizes, x4)
    WidgetRegistry[id] = { id=id, version=1, dataNeeds={{source=source, params={limit={type="integer", maximum=Budgets.widgets[id].rows}},
        budget=Budgets.widgets[id]}}, sizes={ ["android-tablet"]=sizes, x4=x4 },
        states={"loading", "offline-with-data", "offline-without-data", "empty", "error", "ready"},
        budget=Budgets.widgets[id] }
end
widget("continue-reading", "books.query", {{4,3},{4,2},{2,3},{2,2}}, {{1,2},{2,3},{2,2}})
widget("booklist", "books.query", {{2,2},{4,2},{2,3},{4,3},{2,1}}, {{2,2},{1,3},{1,2},{2,3},{2,4},{2,1}})
widget("lists", "lists.list", {{2,3},{1,3},{2,2},{4,2}}, {{1,3},{1,2},{2,2},{2,3}})
widget("library", "library.summary", {{2,1},{2,2},{1,1}}, {{2,3},{1,2},{2,1},{1,1},{2,2}})
widget("battery", "battery.stats", {{2,2},{1,2},{2,1},{4,3},{2,3},{4,2}}, {{1,2},{1,1},{2,2},{2,3},{2,1}})
widget("this-week", "reading.stats", {{2,2},{2,3},{2,1},{1,2}}, {{1,2},{2,2},{2,1}})
widget("year-in-reading", "reading.stats", {{4,3},{4,2}}, {{2,4},{2,3}})
widget("when-you-read", "reading.stats", {{2,2},{2,3},{2,1},{4,1}}, {{2,1},{2,2},{1,2}})
widget("reading-records", "reading.stats", {{3,2},{2,3},{2,2},{4,1}}, {{2,2},{2,3}})
widget("clock", "device.clock", {{1,2},{2,1},{2,2}}, {{2,2},{1,1},{2,1}})
for _,id in ipairs({"word","light","buddy"}) do
    widget(id, "local."..id, {{2,1},{2,2}}, {{2,1}})
    WidgetRegistry[id].localOnly=true
end
for _,id in ipairs({"highlight","yearago","recommended","discover"}) do
    widget(id,"personal.reading",{{2,1},{2,2}},{{2,2}})
    WidgetRegistry[id].localOnly=true
    WidgetRegistry[id].refreshSeconds=60
end
WidgetRegistry.recommended.sizes['android-tablet']={{4,2},{2,2}}
WidgetRegistry.recommended.sizes.x4={{2,2}}
WidgetRegistry.word.refreshSeconds = 60 -- daily selection is companion-owned
WidgetRegistry.clock.refreshSeconds = 60 -- host-owned refresh, only while visible
-- The Library tile also displays local storage; both small needs share its budget and
-- are part of the host's single batched snapshot, never separate render-time round trips.
WidgetRegistry.library.dataNeeds[1].params.limit.maximum = 1
WidgetRegistry.library.dataNeeds[2] = {source="storage.summary", params={limit={type="integer", maximum=1}},
    budget=Budgets.widgets.library}

-- Picker copy belongs to the existing widget contract, shared by every host.
local descriptions={
    ["continue-reading"]={"Continue reading","Your current book, with progress and a Resume button."},
    booklist={"Book list","A shelf of books from a source you choose."},
    lists={"Lists","Your saved lists and their book counts."},
    library={"Library","Your library and storage at a glance."},
    battery={"Battery","Battery remaining at your usual use."},
    ["this-week"]={"This week","Your reading across the week."},
    ["year-in-reading"]={"Year in reading","A calendar of your reading days."},
    ["when-you-read"]={"When you read","Your reading by hour of day."},
    ["reading-records"]={"Reading records","Your reading streaks and records."},
    recommended={"Recommended for you","What to read next using saved books and reading history."},
    discover={"Discover (random)","A daily unread pick, with Another to choose again."},
    highlight={"Highlight of the day","A daily passage from your saved highlights."},
    yearago={"A year ago","Books and reading from this date last year."},
    word={"Word of the day","A daily word from your KOReader vocabulary."},
    light={"Light","Control this reader's frontlight."},
    buddy={"Reading buddy","A reading message from activity on this reader."},
    clock={"Clock","The time on your Home page."},
}
for id,copy in pairs(descriptions) do WidgetRegistry[id].name=copy[1]; WidgetRegistry[id].description=copy[2] end

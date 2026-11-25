package net.fledgewing.orbitcompanion

import java.io.File
import org.junit.Assert.*
import org.junit.Test

// @fixture catalog/sections.json
class CatalogPlanTest {
    private val inventory = LuaValue.fromJson(File("../../../shared/fixtures/catalog/sections.json").readText()) as Map<*, *>
    private fun values(key: String) = (inventory[key] as List<*>).filterIsInstance<String>()
    private val planner = CatalogPlan(CacheWorker.Plan(mapOf("catalog" to inventory)))
    private val books = "/koreader/plugin/catalog/books"
    private fun query(path: String) = MirrorLogic.parseQuery(MirrorLogic.splitPath(path).second)

    @Test fun everyBookSheetCombinationIsCoveredAcrossEverySelector() {
        for (selector in listOf("", "libraryId", "collectionId", "smartScopeId", "author", "seriesId", "series", "ids")) {
            val base = books + if (selector.isEmpty()) "" else "?$selector=7&sort=title&buckets=1"
            val paths = planner.bookPaths(base, listOf("9"), "1,2").toSet()
            val series = selector in listOf("seriesId", "series")
            for (sort in if (series) values("series_sorts") else values("book_sorts")) {
                for (order in values("orders")) for (status in listOf("") + values("read_statuses")) {
                    for (format in if (series) listOf("") else listOf("") + values("formats")) {
                        val q = linkedMapOf("sort" to sort, "order" to order)
                        if (selector.isNotEmpty()) q[selector] = "7"
                        if (status.isNotEmpty()) q["readStatus"] = status
                        if (format.isNotEmpty()) q["format"] = format
                        assertTrue("uncovered $q", "$books?${MirrorLogic.encQuery(q)}" in paths)
                        if (!series) {
                            q["libraryId"] = "9"; q["ids"] = "1,2"
                            assertTrue("uncovered library/device combination $q", "$books?${MirrorLogic.encQuery(q)}" in paths)
                        }
                    }
                }
            }
        }
    }

    @Test fun allIndexSortAndStatusFacetsAreCovered() {
        val paths = planner.sectionPaths().toSet()
        for (section in listOf("authors", "series")) for (sort in values("section_sorts")) {
            for (filter in listOf("") + values("section_filters")) {
                val q = linkedMapOf<String, String>()
                if (sort != "name") q["sort"] = sort
                if (filter.isNotEmpty()) q["filter"] = filter
                val path = "/koreader/plugin/catalog/sections/$section" + if (q.isEmpty()) "" else "?${MirrorLogic.encQuery(q)}"
                assertTrue(path, path in paths)
            }
        }
    }

    @Test fun auditKindsSeparateTheReportedMissingShelves() {
        assertEquals("recently-added", CatalogPlan.kind("$books?sort=recently_added"))
        assertEquals("reading", CatalogPlan.kind("$books?sort=recently_read&readStatus=reading"))
        assertEquals("finished", CatalogPlan.kind("$books?readStatus=finished"))
        assertEquals("index:collections", CatalogPlan.kind("/koreader/plugin/catalog/sections/collections"))
    }
}

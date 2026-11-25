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

    @Test fun fullPlanDiscoversFreshSelectorsThenSavesAllTheirPagesAndVariants() {
        val root = java.nio.file.Files.createTempDirectory("catalog-plan").toFile()
        val server = "https://books.example"
        val base = "/koreader/plugin/catalog"
        val asked = java.util.Collections.synchronizedList(ArrayList<String>())
        val small = inventory.entries.associate { it.key to it.value }.toMutableMap().apply {
            put("book_sorts", listOf("title", "recently_added")); put("list_sorts", emptyList<String>())
            put("series_sorts", listOf("series")); put("read_statuses", listOf("reading", "finished"))
            put("orders", listOf("asc")); put("formats", listOf("pdf"))
        }
        val templates = values("sections").associateWith { section ->
            val keys = (inventory["selectors"] as Map<*, *>)[section] as List<*>
            mapOf("path" to "$books?${keys.first()}=${MirrorLogic.SENTINEL}&sort=${if (section == "series") "series" else "title"}",
                "series_name_path" to "$books?series=${MirrorLogic.SENTINEL}&sort=series")
        }
        val dynamic = (inventory["home_books"] as Map<*, *>).values.map { value ->
            val q = (value as Map<*, *>).entries.associate { it.key.toString() to it.value.toString() }.toMutableMap()
            q.putIfAbsent("order", if (q["sort"] in listOf("recently_added", "recently_read")) "desc" else "asc")
            "$books?${MirrorLogic.encQuery(q)}"
        }
        val p = CacheWorker.Plan(mapOf("run" to "catalog", "op" to "full", "owner" to "reader|$server", "catalog" to small,
            "all_books" to "$books?sort=title&order=asc", "sections" to values("sections").map { "$base/sections/$it" },
            "templates" to templates, "detail_template" to "$books/${MirrorLogic.SENTINEL}", "dynamic_lists" to dynamic,
            "entries" to listOf("$base/root", "$base/dashboard"), "seed_lists" to listOf("$books?ids=9&sort=title&order=asc"),
            "seed_details" to listOf(9L)))
        val w = CacheWorker(root, { url, _, _, _ ->
            val path = url.removePrefix(server)
            asked.add(path)
            val (endpoint, encoded) = MirrorLogic.splitPath(path)
            val q = MirrorLogic.parseQuery(encoded)
            val reply = when {
                endpoint.contains("/sections/") -> "{\"total\":1,\"items\":[{\"id\":7,\"seriesId\":7}]}"
                endpoint == books -> {
                    val total = if (q["sort"] == "recently_added" && q["readStatus"] == null && q["libraryId"] == null && q["ids"] == null) 101 else 1
                    val page = q["page"]!!.toInt()
                    val items = ((page - 1) * 100 + 1..minOf(page * 100, total)).joinToString(",") { "{\"id\":$it,\"updatedAt\":\"2026-01-01\"}" }
                    "{\"total\":$total,\"items\":[$items]}"
                }
                endpoint.startsWith("$books/") -> "{\"id\":${endpoint.substringAfterLast('/')}}"
                else -> "{}"
            }
            CacheWorker.Reply(200, reply.toByteArray())
        }, log = {}, openSql = { JdbcSql(it) })
        try {
            assertEquals("finished", w.run(p, CacheWorker.Creds(server, "reader", "k")))
            for (section in values("sections")) {
                val path = MirrorLogic.entryPath(templates, MirrorLogic.SENTINEL, section, mapOf("id" to 7L, "seriesId" to 7L))!!
                assertNotNull("never-opened $section", w.store.read(MirrorLogic.key(p.owner, server, path), path, null))
            }
            for (path in dynamic) assertNotNull("never-opened Home list $path", w.store.read(MirrorLogic.key(p.owner, server, path), path, null))
            val recent = "$books?order=desc&sort=recently_added"
            assertEquals(101L, ((w.store.window(recent, 2, 100, null)!!["items"] as List<*>).single() as Map<*, *>)["id"])
            val variant = "$books?format=pdf&libraryId=7&order=asc&readStatus=finished&sort=recently_added"
            assertNotNull("library/status/format variant", w.store.read(MirrorLogic.key(p.owner, server, variant), variant, null))
            assertEquals("each request once", asked.size, asked.toSet().size)
        } finally { w.store.close(); root.deleteRecursively() }
    }

    @Test fun auditKindsSeparateTheReportedMissingShelves() {
        assertEquals("recently-added", CatalogPlan.kind("$books?sort=recently_added"))
        assertEquals("reading", CatalogPlan.kind("$books?sort=recently_read&readStatus=reading"))
        assertEquals("finished", CatalogPlan.kind("$books?readStatus=finished"))
        assertEquals("index:collections", CatalogPlan.kind("/koreader/plugin/catalog/sections/collections"))
    }
}

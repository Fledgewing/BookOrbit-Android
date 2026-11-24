package net.fledgewing.orbitcompanion

import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * A Full refresh against a real BookOrbit (the stage 0 server kit, tools/e2e/kit.py), one request
 * at a time and four at a time, with the worker's own timing line. Skipped unless
 * ORBIFY_E2E_SERVER (e.g. http://127.0.0.1:3990/api/v1), ORBIFY_E2E_USER and ORBIFY_E2E_KEY
 * (the KOReader key: md5 of the sync password) are set. Prints, asserts only that both finish.
 */
class CacheWorkerLiveTest {
    @Test fun fullRefreshTimings() {
        val server = System.getenv("ORBIFY_E2E_SERVER")
        assumeTrue("no ORBIFY_E2E_SERVER", !server.isNullOrEmpty())
        val creds = CacheWorker.Creds(server!!, System.getenv("ORBIFY_E2E_USER") ?: "", System.getenv("ORBIFY_E2E_KEY") ?: "")
        val c = "/koreader/plugin/catalog"
        for (parallel in listOf(1, CacheWorker.PARALLEL)) {
            val root = Files.createTempDirectory("orbit-live").toFile()
            val plan = CacheWorker.Plan(sortedMapOf<String, Any?>(
                "run" to "live-$parallel", "op" to "full", "reason" to "live", "owner" to "${creds.user}|$server", "sentinel" to "987654321",
                "templates" to sortedMapOf(
                    "authors" to sortedMapOf("path" to "$c/books?author=987654321&order=asc&sort=title"),
                    "series" to sortedMapOf("path" to "$c/books?order=asc&seriesId=987654321&sort=series",
                        "series_name_path" to "$c/books?order=asc&series=987654321&sort=series")),
                "detail_template" to "$c/books/987654321?deviceId=orbify-live",
                "sections" to listOf("$c/sections/series", "$c/sections/authors"),
                "seed_lists" to listOf("$c/books?order=asc&sort=title"), "covers_on" to false))
            val lines = ArrayList<String>()
            val w = CacheWorker(root, Worker.UrlHttp, log = { synchronized(lines) { lines.add(it) } }, parallel = parallel, openSql = { JdbcSql(it) })
            val why = w.run(plan, creds)
            println("live, $parallel at a time: $why; " + lines.filter { it.startsWith("mirror: run ") || it.startsWith("mirror: Full refresh saved") }.joinToString(" | "))
            check(why == "finished") { lines.takeLast(5).joinToString("\n") }
            root.deleteRecursively()
        }
    }
}

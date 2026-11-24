package net.fledgewing.orbitcompanion

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.nio.file.Files

/** A Full refresh of N books over a server answering in LAT ms, covers on (ORBIFY_BENCH=1). */
class CacheWorkerBench {
    @Test fun bench() {
        assumeTrue(System.getenv("ORBIFY_BENCH") != null)
        val n = (System.getenv("ORBIFY_BENCH_N") ?: "2000").toInt()
        val lat = (System.getenv("ORBIFY_BENCH_MS") ?: "60").toLong()
        val S = "https://books.example/api/v1"; val C = "/koreader/plugin/catalog"
        val requests = java.util.concurrent.atomic.AtomicInteger()
        val http = CacheWorker.Http { url, _, sink, _ ->
            requests.incrementAndGet()
            Thread.sleep(lat)
            val path = url.removePrefix(S + C)
            val m = Regex("^/books\\?(?:order=asc&)?page=(\\d+)&size=(\\d+)&sort=title$").find(path)
            when {
                path.endsWith("/thumbnail") -> { sink!!.writeBytes(ByteArray(20_000)); CacheWorker.Reply(200, etag = "\"e\"", contentType = "image/jpeg") }
                m != null -> {
                    val p = m.groupValues[1].toInt(); val size = m.groupValues[2].toInt()
                    val items = JSONArray(((p - 1) * size + 1..minOf(n, p * size)).map { JSONObject().put("id", it).put("title", "Book $it").put("authors", JSONArray().put("A ${it % 50}")).put("hasCover", true).put("updatedAt", "2026-01-01") })
                    CacheWorker.Reply(200, JSONObject().put("total", n).put("items", items).toString().toByteArray())
                }
                path.matches(Regex("^/books/\\d+$")) -> CacheWorker.Reply(200, JSONObject().put("id", path.substringAfterLast('/').toInt()).put("description", "x".repeat(1500)).put("tags", JSONArray().put("t")).toString().toByteArray())
                else -> CacheWorker.Reply(404)
            }
        }
        val root = Files.createTempDirectory("bench").toFile()
        val plan = CacheWorker.Plan(sortedMapOf<String, Any?>("run" to "b", "op" to "full", "reason" to "bench", "owner" to "u|$S", "sentinel" to "987654321",
            "templates" to sortedMapOf<String, Any?>(), "detail_template" to "$C/books/987654321", "cover_dir" to "${root.path}/thumbs", "covers_on" to true,
            "all_books" to "$C/books?order=asc&sort=title", "seed_lists" to listOf("$C/books?sort=title"), "sections" to emptyList<String>(), "seed_details" to emptyList<Long>()))
        val lines = ArrayList<String>()
        val w = CacheWorker(root, http, log = { synchronized(lines) { lines.add(it) } }, openSql = { JdbcSql(it) })
        val t0 = System.nanoTime()
        val why = w.run(plan, CacheWorker.Creds(S, "u", "k"))
        val secs = (System.nanoTime() - t0) / 1e9
        val items = 2 * n // details + covers
        println(String.format(java.util.Locale.ROOT, "BENCH %s: %d books, %d ms a request: %d requests, %.1f s, %.1f items/s; 10,000 books ≈ %.1f min",
            why, n, lat, requests.get(), secs, items / secs, secs * 10_000 / n / 60))
        lines.filter { it.startsWith("mirror: run") || it.contains("Full refresh done") }.forEach { println("BENCH   $it") }
        root.deleteRecursively()
    }
}

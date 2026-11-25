package net.fledgewing.orbitcompanion

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class CacheWorkerTest {
    // @fixture cache/worker.json
    private val fx = JSONObject(File("../../../shared/fixtures/cache/worker.json").readText())

    private fun hexBytes(h: String) = String(ByteArray(h.length / 2) { h.substring(it * 2, it * 2 + 2).toInt(16).toByte() }, Charsets.ISO_8859_1)

    /** shared/fixtures/cache/worker.json: the plugin's keys and file names (test_logic reads the same file). */
    @Test fun keysAndHashesMatchThePlugin() {
        val keys = fx.getJSONArray("keys")
        for (i in 0 until keys.length()) {
            val k = keys.getJSONObject(i)
            val key = MirrorLogic.key(LuaValue.str(k.getString("account")), LuaValue.str(k.getString("server")), LuaValue.str(k.getString("path")))
            assertEquals(k.getString("path"), hexBytes(k.getString("key_hex")), key)
            assertEquals(k.getString("hash"), MirrorLogic.hash(key))
        }
    }

    @Test fun listWindowsAndMirrorPagesMatchThePlugin() {
        val ws = fx.getJSONArray("windows")
        for (i in 0 until ws.length()) {
            val w = ws.getJSONObject(i)
            val got = MirrorLogic.listWindow(LuaValue.str(w.getString("path")))
            if (w.isNull("identity")) { assertNull(w.getString("path"), got); continue }
            assertNotNull(got)
            assertEquals(LuaValue.str(w.getString("identity")), got!!.identity)
            assertEquals(w.getString("kind"), got.kind)
            assertEquals(if (w.isNull("section")) null else w.getString("section"), got.section)
            assertEquals(LuaValue.str(w.getString("page2")), MirrorLogic.mirrorPage(got.identity, 2, null))
            assertEquals(LuaValue.str(w.getString("page1_50")), MirrorLogic.mirrorPage(got.identity, 1, 50))
        }
    }

    /** The entry file is byte-for-byte what the plugin's Cache.encode writes, and loads back. */
    @Test fun entryFileMatchesCacheEncode() {
        val e = fx.getJSONObject("entry")
        val body = LuaValue.fromJson(e.getString("body_json"))
        val lit = LuaValue.encode(sortedMapOf<String, Any?>("key" to e.getString("key"), "body" to body, "fetched_at" to 100L, "validated_at" to 200L, "path" to e.getString("path")))
        val want = LuaValue.str(e.getString("lua")).toByteArray(Charsets.ISO_8859_1)
        assertEquals(String(want, Charsets.ISO_8859_1), String(lit, Charsets.ISO_8859_1))
        val back = LuaValue.parse(want) as Map<*, *>
        assertTrue(LuaValue.encode(back).contentEquals(want))
        assertFalse(LuaValue.changed(back["body"], body))
    }

    @Test fun coverNamesMatchThePlugin() {
        val cs = fx.getJSONArray("covers")
        val w = CacheWorker(Files.createTempDirectory("c").toFile(), { _, _, _, _ -> CacheWorker.Reply(0) }, log = {}, openSql = { JdbcSql(it) })
        for (i in 0 until cs.length()) {
            val c = cs.getJSONObject(i)
            val book = sortedMapOf<String, Any?>("id" to c.getLong("id"), "updatedAt" to (if (c.isNull("updatedAt")) null else c.getString("updatedAt")),
                "author_photo" to c.getBoolean("author_photo").takeIf { it })
            assertEquals(if (c.isNull("name")) null else c.getString("name"), w.coverName(book))
        }
    }

    @Test fun unescapeKeepsBadPercents() {
        assertEquals("a b%zz%4", MirrorLogic.unescape("a+b%zz%4"))
        assertEquals("A", MirrorLogic.unescape("%41"))
    }

    // ------------------------------------------------------------------ a fake BookOrbit

    private val S = "https://books.example/api/v1"
    private val C = "/koreader/plugin/catalog"

    private class Fake(val routes: MutableMap<String, String>) : CacheWorker.Http {
        val asked = ArrayList<String>()
        val headersSeen = ArrayList<Map<String, String>>()
        var down = false
        var forceCover = false
        @Synchronized
        override fun get(url: String, headers: Map<String, String>, sink: File?, maxBytes: Long): CacheWorker.Reply {
            asked.add(url); headersSeen.add(headers)
            if (down) return CacheWorker.Reply(0, err = "timeout")
            if (url.endsWith("/thumbnail")) {
                if (!forceCover && headers["If-None-Match"] == "\"e1\"") return CacheWorker.Reply(304)
                sink!!.writeBytes(byteArrayOf(1, 2, 3))
                return CacheWorker.Reply(200, etag = "\"e1\"", contentType = "image/jpeg")
            }
            val b = routes[url] ?: return CacheWorker.Reply(404)
            return CacheWorker.Reply(200, b.toByteArray())
        }
    }

    private fun books(ids: List<Int>, total: Int = ids.size) =
        JSONObject().put("total", total).put("items", org.json.JSONArray(ids.map { JSONObject().put("id", it).put("title", "B$it").put("hasCover", true).put("updatedAt", "2026-01-0${it % 9 + 1}") })).toString()

    private fun plan(root: File, op: String, extra: Map<String, Any?> = emptyMap()): CacheWorker.Plan {
        val m = sortedMapOf<String, Any?>(
            "run" to "r1", "op" to op, "reason" to "test", "owner" to "alice|$S", "sentinel" to "987654321",
            "templates" to sortedMapOf("authors" to sortedMapOf("path" to "$C/books?author=987654321")),
            "detail_template" to "$C/books/987654321", "cover_dir" to File(root, "thumbs").path, "covers_on" to true,
            "seed_lists" to listOf("$C/books?sort=title"), "lists" to emptyList<String>(), "sections" to listOf("$C/sections/authors"),
            "seed_details" to listOf(1L))
        m.putAll(extra)
        return CacheWorker.Plan(m)
    }

    private fun setup(parallel: Int = 1, resize: (File, Int, Int) -> Unit = { _, _, _ -> }): Triple<File, Fake, CacheWorker> {
        val root = Files.createTempDirectory("orbit-cache").toFile()
        val routes = mutableMapOf(
            "$S$C/books?page=1&size=100&sort=title" to books(listOf(1, 2)),
            "$S$C/sections/authors?page=1&size=100" to JSONObject().put("total", 1).put("items", org.json.JSONArray().put(JSONObject().put("id", "Ana María"))).toString(),
            "$S$C/books?author=Ana%20Mar%C3%ADa&page=1&size=100" to books(listOf(3)),
            "$S$C/books/1" to JSONObject().put("id", 1).put("hasCover", true).put("updatedAt", "2026-01-02").toString(),
            "$S$C/books/2" to JSONObject().put("id", 2).toString(),
            "$S$C/books/3" to JSONObject().put("id", 3).toString(),
        )
        val fake = Fake(routes)
        var t = 1000L
        var ms = 0L
        val w = CacheWorker(root, fake, now = { synchronized(this) { t++ } }, log = {}, sleep = { synchronized(this) { ms += it * 1000L } }, parallel = parallel,
            openSql = { JdbcSql(it) }, clockMs = { synchronized(this) { ms } }, resizeThumbnail = resize)
        return Triple(root, fake, w)
    }

    private val creds = CacheWorker.Creds(S, "alice", "secret-key")

    @Test fun fullRefreshSavesSeedThenListsThenDetailsThenCovers() {
        val (root, fake, w) = setup()
        assertEquals("finished", w.run(plan(root, "full"), creds))
        val pages = fake.asked.filter { !it.endsWith("/thumbnail") }.map { it.removePrefix(S + C) }
        // Lists first (requests queue ahead of the pool, so a detail may overlap a later list), each
        // page and each book's detail once.
        assertEquals(listOf("/books?page=1&size=100&sort=title", "/sections/authors?page=1&size=100"), pages.take(2))
        assertEquals(setOf("/books?author=Ana%20Mar%C3%ADa&page=1&size=100", "/books/1", "/books/2", "/books/3"), pages.drop(2).toSet())
        assertEquals(6, pages.size)
        // Each cover once, whichever lists name the book.
        assertEquals(3, fake.asked.count { it.endsWith("/thumbnail") })
        // Saved where the plugin reads: the detail by book id, the lists by position.
        val key = MirrorLogic.key("alice|$S", S, "$C/books/2")
        assertEquals(2L, (w.store.read(key, "$C/books/2", "$C/books/987654321")!!.body as Map<*, *>)["id"])
        assertEquals(3L, w.store.db().query("SELECT count(*) FROM books") { it.long(0) }.single())
        val status = LuaValue.parse(File(w.mirrorDir, "status.lua").readBytes()) as Map<*, *>
        assertEquals("companion", status["runner"]); assertEquals(0L, status["left"]); assertNull(status["running"])
        assertNotNull(status["at"])
        val summary = LuaValue.parse(File(w.mirrorDir, "summary.lua").readBytes()) as Map<*, *>
        assertEquals(true, summary["saved"])
        assertTrue(File(root, "thumbs/1_20260102.jpg").isFile)
        assertEquals("\"e1\"", File(root, "thumbs/1_20260102.jpg.etag").readText())
        // The key goes only in headers, never in a file.
        assertTrue(fake.headersSeen.all { it["x-auth-key"] == "secret-key" })
        root.walkTopDown().filter { it.isFile }.forEach { assertFalse(it.path, String(it.readBytes(), Charsets.ISO_8859_1).contains("secret-key")) }
    }

    @Test fun refreshRechecksSavedPagesAndReportsChanges() {
        val (root, fake, w) = setup()
        w.run(plan(root, "full"), creds)
        fake.routes["$S$C/books?page=1&size=100&sort=title"] = books(listOf(1, 2, 4))
        fake.asked.clear()
        assertEquals("finished", w.run(plan(root, "revalidate"), creds))
        val summary = LuaValue.parse(File(w.mirrorDir, "summary.lua").readBytes()) as Map<*, *>
        assertEquals(true, summary["revalidated"])
        assertEquals(listOf("$C/books?sort=title"), summary["changed"])
        // A recheck reads list pages, and details only for books it has not saved.
        assertEquals(listOf("$S$C/books/4"), fake.asked.filter { it.matches(Regex(".*/books/\\d+$")) })
        // Unchanged covers are not requested at all.
        val st = LuaValue.parse(File(w.mirrorDir, "status.lua").readBytes()) as Map<*, *>
        assertEquals(0L, (st["covers"] as Map<*, *>)["not_modified"])
        assertEquals(1, fake.asked.count { it.endsWith("/thumbnail") })
    }

    @Test fun stopFileAndOutagesEndTheRunAndItResumes() {
        val (root, fake, w) = setup()
        fake.down = true
        assertEquals("no answer", w.run(plan(root, "full"), creds))
        val left = (LuaValue.parse(File(w.mirrorDir, "status.lua").readBytes()) as Map<*, *>)["left"] as Long
        assertTrue(left > 0)
        fake.down = false
        File(w.mirrorDir, "stop").writeText("")
        assertEquals("stopped", w.run(plan(root, "resume"), creds))
        File(w.mirrorDir, "stop").delete()
        assertEquals("finished", w.run(plan(root, "resume"), creds))
    }

    @Test fun underLimitRefreshSavesAndPruningDuringYieldUsesTheLiveCoverTotal() {
        val (root, fake, w) = setup()
        val thumbs = File(root, "thumbs").apply { mkdirs() }
        File(thumbs, "old.jpg").writeBytes(ByteArray(2 * 1024 * 1024))
        val p = plan(root, "full", mapOf("limit" to 1024L * 1024))
        var yielded = false
        assertEquals("finished", w.run(p, creds) {
            if (!yielded) {
                yielded = true
                w.storage(CacheWorker.StorageAsk("during refresh", 1024L * 1024, thumbs.path, true))
            }
        })
        val status = LuaValue.parse(File(w.mirrorDir, "status.lua").readBytes()) as Map<*, *>
        assertNull(status["limit_note"])
        assertTrue(fake.asked.isNotEmpty())
        assertNotNull(w.store.detail(1))
        assertNotNull(w.store.meta("full_at"))
    }

    @Test fun coverPrunedWhileYieldingDoesNotRemainInTheRunBudget() {
        val (root, _, w) = setup()
        val thumbs = File(root, "thumbs").apply { mkdirs() }
        File(thumbs, "old.jpg").writeBytes(ByteArray(850 * 1024))
        val p = plan(root, "full", mapOf("limit" to 1024L * 1024))
        var first = true
        assertEquals("finished", w.run(p, creds) {
            if (first) {
                first = false
                w.storage(CacheWorker.StorageAsk("prune while yielding", 1L, thumbs.path, true))
                w.store.putEntry("kept", "/dashboard/test", mapOf("payload" to "x".repeat(250 * 1024)), 1L, home = true)
            }
        })
        assertFalse(File(thumbs, "old.jpg").exists())
        assertNotNull(w.store.detail(1))
        val status = LuaValue.parse(File(w.mirrorDir, "status.lua").readBytes()) as Map<*, *>
        assertNull(status["limit_note"])
    }

    @Test fun fullRefreshReplacesExistingRowsAtTheLimit() {
        val (root, fake, w) = setup()
        assertEquals("finished", w.run(plan(root, "full"), creds))
        val used = w.storageItems(File(root, "thumbs").path, true).sumOf { it.bytes }
        // Force 200 replacements too, so both rows and image bodies are exercised at capacity.
        fake.forceCover = true
        assertEquals("finished", w.run(plan(root, "full", mapOf("limit" to used)), creds))
        val status = LuaValue.parse(File(w.mirrorDir, "status.lua").readBytes()) as Map<*, *>
        assertNull(status["limit_note"])
        assertNotNull(w.store.detail(1))
    }

    @Test fun growingDataEvictsCoversButKeepsProtectedAndStopsOnlyAfterExhaustion() {
        val (root, fake, w) = setup()
        assertEquals("finished", w.run(plan(root, "full", mapOf("covers_on" to false)), creds))
        val thumbs = File(root, "thumbs").apply { mkdirs() }
        File(thumbs, "99_0.jpg").writeBytes(ByteArray(128 * 1024))
        File(thumbs, "1_0.jpg").writeBytes(ByteArray(128 * 1024))
        val used = w.storageItems(thumbs.path, false).sumOf { it.bytes }
        fake.routes["$S$C/books/1"] = """{"id":1,"title":"${"x".repeat(64 * 1024)}"}"""
        assertEquals("finished", w.run(plan(root, "full", mapOf("limit" to used, "covers_on" to false, "seed_details" to listOf(1L))), creds))
        assertFalse(File(thumbs, "99_0.jpg").exists())
        assertTrue(File(thumbs, "1_0.jpg").exists())
        fake.routes["$S$C/books/1"] = """{"id":1,"title":"${"x".repeat(512 * 1024)}"}"""
        assertEquals("storage limit", w.run(plan(root, "full", mapOf("limit" to used, "covers_on" to false, "seed_details" to listOf(1L))), creds))
        assertTrue(File(thumbs, "1_0.jpg").exists())
        val status = LuaValue.parse(File(w.mirrorDir, "status.lua").readBytes()) as Map<*, *>
        assertTrue(((status["limit_note"] as Map<*, *>)["text"] as String).contains("protected covers"))
        assertEquals(64 * 1024, ((w.store.detail(1)!!.first as Map<*, *>)["title"] as String).length)
    }

    @Test fun existingCoversResizeOnTheWriterAlongsideEviction() {
        val touched = java.util.concurrent.ConcurrentLinkedQueue<Pair<String, Thread>>()
        val (root, _, w) = setup(resize = { f, _, _ -> touched.add(f.name to Thread.currentThread()) })
        assertEquals("finished", w.run(plan(root, "full"), creds))
        val writer = Thread.currentThread()
        for (withoutEtag in listOf(false, true)) {
            touched.clear()
            if (withoutEtag) File(root, "thumbs").listFiles()!!.filter { it.name.endsWith(".etag") }.forEach { it.delete() }
            assertEquals("finished", w.run(plan(root, "full"), creds))
            assertTrue(touched.isNotEmpty())
            assertTrue("304 and untagged existing images cannot race writer eviction", touched.all { it.first.endsWith(".jpg") && it.second === writer })
        }
    }

    @Test fun recheckedCoverShrinkImmediatelyReturnsBudgetWhileYielding() {
        val (root, fake, w) = setup()
        val thumbs = File(root, "thumbs").apply { mkdirs() }
        val cover = File(thumbs, "99_0.jpg").apply { writeBytes(ByteArray(850 * 1024)) }
        File(cover.path + ".etag").writeText("old")
        fake.forceCover = true
        var first = true
        assertEquals("finished", w.run(plan(root, "full", mapOf("limit" to 1024L * 1024)), creds) {
            if (first) {
                first = false
                w.recheckCovers("test", creds, listOf(99L to cover.path))
                w.store.putEntry("home", "/dashboard/test", mapOf("payload" to "x".repeat(250 * 1024)), 1L, home = true)
            }
        })
        assertTrue("resized/rechecked cover did not need eviction", cover.exists())
        assertEquals(3L, cover.length())
    }

    @Test fun storageLimitStopsSavingAndSaysWhy() {
        val (root, _, w) = setup()
        assertEquals("storage limit", w.run(plan(root, "full", mapOf("limit" to 1L)), creds))
        val st = LuaValue.parse(File(w.mirrorDir, "status.lua").readBytes()) as Map<*, *>
        assertTrue(((st["limit_note"] as Map<*, *>)["text"] as String).startsWith("Storage limit reached"))
        assertEquals(0L, st["done"])
        assertNull(w.store.meta("full_at"))
        assertTrue(w.store.db().query("SELECT count(*) FROM jobs WHERE state = 0") { it.long(0)!! }.single() > 0)
    }

    @Test fun checkComparesWithTheMirrorAndSavesOnlyChanges() {
        val (root, fake, w) = setup()
        w.run(plan(root, "full"), creds)
        val path = "$C/books?sort=title&page=1&size=20"
        val key = MirrorLogic.key("alice|$S", S, path)
        fun page(ids: List<Int>) = JSONObject(books(ids)).put("page", 1).put("size", 20).put("hasNext", false).put("hasPrevious", false).toString()
        fake.routes["$S$path"] = page(listOf(1, 2))
        w.check(CacheWorker.Check(key, path, "open", creds, "alice|$S"))
        val ev1 = File(root, "events").listFiles()!!.map { LuaValue.parse(it.readBytes()) as Map<*, *> }.single()
        assertEquals(true, ev1["unchanged"]); assertEquals(true, ev1["saved"])
        fake.routes["$S$path"] = page(listOf(1, 2, 5))
        w.check(CacheWorker.Check(key, path, "open", creds, "alice|$S"))
        val ev2 = File(root, "events").listFiles()!!.map { LuaValue.parse(it.readBytes()) as Map<*, *> }.first { it["changed"] == true }
        val saved = w.store.read(key, path, null)!!.body as Map<*, *>
        assertEquals(listOf(1L, 2L, 5L), (saved["items"] as List<*>).map { (it as Map<*, *>)["id"] })
    }

    /** Speed: a 500-book library over a server that takes 20 ms a request; PARALLEL at a time. */
    @Test fun aBigLibraryIsFetchedSeveralAtATime() {
        val root = Files.createTempDirectory("orbit-cache").toFile()
        val n = 500
        val inFlight = java.util.concurrent.atomic.AtomicInteger()
        var most = 0
        val http = CacheWorker.Http { url, _, _, _ ->
            val now = inFlight.incrementAndGet()
            synchronized(this) { most = maxOf(most, now) }
            Thread.sleep(20)
            inFlight.decrementAndGet()
            val path = url.removePrefix(S + C)
            val m = Regex("^/books\\?page=(\\d+)&size=100&sort=title$").find(path)
            when {
                m != null -> {
                    val p = m.groupValues[1].toInt()
                    CacheWorker.Reply(200, books(((p - 1) * 100 + 1..minOf(n, p * 100)).toList(), n).toByteArray())
                }
                path.matches(Regex("^/books/\\d+$")) -> CacheWorker.Reply(200, JSONObject().put("id", path.substringAfterLast('/').toInt()).toString().toByteArray())
                else -> CacheWorker.Reply(404)
            }
        }
        val logs = ArrayList<String>()
        val w = CacheWorker(root, http, log = { synchronized(logs) { logs.add(it) } }, sleep = {}, openSql = { JdbcSql(it) })
        val t0 = System.nanoTime()
        assertEquals("finished", w.run(plan(root, "full", mapOf("covers_on" to false, "sections" to emptyList<String>(), "seed_details" to emptyList<Long>())), creds))
        val secs = (System.nanoTime() - t0) / 1e9
        val line = logs.first { it.startsWith("mirror: run r1") }
        assertTrue(line, line.contains("${n + 5} requests, $n books' details"))
        assertEquals(CacheWorker.PARALLEL, most)
        // One at a time this is 505 x 20 ms = 10 s; six at a time about a sixth.
        assertTrue("took $secs s: $line", secs < 5)
    }

    /**
     * rc.6 showed "2,805 of 197,709" and "covers 0/57,409" for about 10,300 books: totals that grew
     * with every list page and counted a cover per list a book is in. Now each book's detail and
     * cover is one job, the total is fixed once the library's size is known, and the % only rises.
     */
    @Test fun eachBookOnceAndTheProgressNeverGoesDown() {
        val root = Files.createTempDirectory("orbit-cache").toFile()
        val n = 250
        // Every book in the all-books list and again in three author lists.
        val http = CacheWorker.Http { url, _, sink, _ ->
            val path = url.removePrefix(S + C)
            val all = Regex("^/books\\?order=asc&page=(\\d+)&size=100&sort=title$").find(path)
            val author = Regex("^/books\\?author=(\\d)&page=(\\d+)&size=100$").find(path)
            when {
                path.endsWith("/thumbnail") -> { sink!!.writeBytes(byteArrayOf(1)); CacheWorker.Reply(200, etag = "\"e\"", contentType = "image/jpeg") }
                all != null -> { val p = all.groupValues[1].toInt(); CacheWorker.Reply(200, books(((p - 1) * 100 + 1..minOf(n, p * 100)).toList(), n).toByteArray()) }
                author != null -> { val p = author.groupValues[2].toInt(); CacheWorker.Reply(200, books(((p - 1) * 100 + 1..minOf(n, p * 100)).toList(), n).toByteArray()) }
                path.startsWith("/sections/authors") -> CacheWorker.Reply(200, JSONObject().put("total", 3).put("items", org.json.JSONArray(listOf(1, 2, 3).map { JSONObject().put("id", it.toString()) })).toString().toByteArray())
                path.matches(Regex("^/books/\\d+$")) -> CacheWorker.Reply(200, JSONObject().put("id", path.substringAfterLast('/').toInt()).toString().toByteArray())
                else -> CacheWorker.Reply(404)
            }
        }
        val pcts = ArrayList<Long?>()
        val asked = ArrayList<String>()
        val counting = CacheWorker.Http { url, h, sink, max -> synchronized(asked) { asked.add(url) }; http.get(url, h, sink, max) }
        val w2 = CacheWorker(root, counting, log = {}, sleep = {}, parallel = 3, openSql = { JdbcSql(it) }, onProgress = { synchronized(pcts) { pcts.add(it) } })
        assertEquals("finished", w2.run(plan(root, "full", mapOf("all_books" to "$C/books?order=asc&sort=title", "seed_lists" to emptyList<String>(),
            "seed_details" to emptyList<Long>())), creds))
        val details = asked.filter { it.matches(Regex(".*/books/\\d+$")) }
        val covers = asked.filter { it.endsWith("/thumbnail") }
        assertEquals("each book's detail once", n, details.size); assertEquals(n, details.toSet().size)
        assertEquals("each book's cover once", n, covers.size)
        val st = LuaValue.parse(File(w2.mirrorDir, "status.lua").readBytes()) as Map<*, *>
        // 3 all-books pages + 1 section page + 3 x 3 author pages + 250 details + 250 covers.
        assertEquals(513L, st["total"]); assertEquals(100L, st["pct"]); assertEquals(250L, st["cover_total"])
        val shown = pcts.dropLast(1).filterNotNull()
        assertTrue("rises: $shown", shown.zipWithNext().all { (a, b) -> b >= a })
        assertTrue("never 100 before the end: $shown", shown.dropLast(1).all { it < 100 })
        assertNull("the end clears it", pcts.last())
        assertEquals("Full refresh · 37%", MirrorLogic.progressLine(37))
        assertNull(MirrorLogic.progressLine(null))
    }

    /** M8C: the series index never answered in pages of 100; authors never at all. */
    @Test fun retriedInSmallerPagesThenSkipped() {
        val root = Files.createTempDirectory("orbit-cache").toFile()
        val logs = ArrayList<String>()
        val waits = ArrayList<Int>()
        val http = CacheWorker.Http { url, _, _, _ ->
            val path = url.removePrefix(S + C)
            when {
                path.startsWith("/sections/authors") -> CacheWorker.Reply(0, err = "timeout")
                path.startsWith("/sections/series") && path.contains("size=100") -> CacheWorker.Reply(0, err = "timeout")
                path.startsWith("/sections/series") -> CacheWorker.Reply(200, JSONObject().put("total", 0).put("items", org.json.JSONArray()).toString().toByteArray())
                else -> CacheWorker.Reply(404)
            }
        }
        var ms = 0L
        val w = CacheWorker(root, http, log = { logs.add(it) }, sleep = { waits.add(it); ms += it * 1000L }, parallel = 1,
            openSql = { JdbcSql(it) }, clockMs = { ms })
        val p = plan(root, "full", mapOf("seed_lists" to emptyList<String>(), "seed_details" to emptyList<Long>(),
            "sections" to listOf("$C/sections/series", "$C/sections/authors")))
        assertEquals("finished", w.run(p, creds))
        val log = logs.joinToString("\n")
        assertTrue(log, log.contains("/sections/series?page=1&size=100 failed (timeout), try 1 of 3; again in 5s, in pages of 50"))
        assertTrue(log, log.contains("/sections/authors?page=1&size=50 failed (timeout), try 2 of 3; again in 10s, in pages of 25"))
        assertTrue(log, log.contains("/sections/authors?page=1&size=25 skipped after 3 tries (timeout); the rest continues"))
        // Both lists' retries wait together.
        assertEquals(listOf(5, 10), waits)
        val st = LuaValue.parse(File(w.mirrorDir, "status.lua").readBytes()) as Map<*, *>
        assertEquals(1L, st["skipped"])
        assertTrue(log, log.contains("/sections/series?page=1&size=50") || !log.contains("series?page=1&size=50 failed"))
    }
    @Test fun incrementalChecksNewestPageAndFetchesOnlyChangedDetailsAndMembership() {
        val (root, fake, w) = setup()
        val p = plan(root, "incremental", mapOf("covers_on" to false))
        w.store.own(p.owner)
        w.store.setMeta("full_at", 100L)
        w.store.setMeta("incremental_watermark", "2026-01-04")
        val initial = LuaValue.fromJson(books(listOf(1, 2, 3))) as Map<*, *>
        w.store.putWindow("$C/books?collectionId=1", "books", null, 0, initial, 100L)
        for (id in 1L..3L) w.store.putDetail(id, mapOf("id" to id), 100L)
        val newest = "$S$C/books?order=desc&page=1&size=100&sort=recently_updated"
        fake.routes[newest] = books(listOf(3, 2, 1))
        assertEquals("finished", w.run(p, creds))
        assertEquals(listOf(newest), fake.asked)
        assertEquals(100L, w.store.meta("full_at")!!.toLong())
        fake.asked.clear()
        val changed = JSONObject(books(listOf(2, 3, 1)))
        changed.getJSONArray("items").getJSONObject(0).put("updatedAt", "2026-02-01")
        fake.routes[newest] = changed.toString()
        fake.routes["$S$C/books?collectionId=1&page=1&size=100"] = changed.toString()
        assertEquals("finished", w.run(p, creds))
        assertEquals(1, fake.asked.count { it == "$S$C/books/2" })
        assertFalse(fake.asked.any { it == "$S$C/books/1" || it == "$S$C/books/3" || it.endsWith("/thumbnail") })
        assertTrue(fake.asked.contains("$S$C/books?collectionId=1&page=1&size=100"))
        assertEquals("2026-02-01", w.store.meta("incremental_watermark"))
        fake.asked.clear()
        w.run(p, creds)
        assertEquals(listOf(newest), fake.asked)
        w.store.close(); root.deleteRecursively()
    }

    @Test fun fullRefreshSavesUnopenedHomeRepliesWithThePluginKeyAndAuditsKinds() {
        val (root, fake, unused) = setup()
        val logs = ArrayList<String>()
        val w = CacheWorker(root, fake, log = { logs.add(it) }, openSql = { JdbcSql(it) })
        val paths = listOf("$C/dashboard", "$C/root", "$C/dashboard/sections/want-to-read", "$C/dashboard/sections/up-next-in-series")
        for (path in paths) fake.routes[S + path] = "{\"items\":[]}"
        val recent = "$C/books?sort=recently_added&order=desc"
        fake.routes[S + MirrorLogic.mirrorPage(recent, 1, null)] = books(emptyList())
        val p = plan(root, "full", mapOf("entries" to paths, "dynamic_lists" to listOf(recent)))
        assertEquals("finished", w.run(p, creds))
        for (path in paths) {
            assertNotNull(path, w.store.read(MirrorLogic.key(p.owner, S, path), path, null))
        }
        assertTrue(logs.joinToString("\n"), logs.any { it.contains("lists saved by kind:") && it.contains("recently-added=1") && it.contains("index:authors=1") })
        w.store.close(); unused.store.close(); root.deleteRecursively()
    }

    @Test fun dynamicShelvesRefreshWithoutTimestampChangesIncludingUnopenedListsAndSameSizeReordering() {
        val (root, fake, w) = setup()
        val dynamic = listOf("$C/books?sort=recently_added", "$C/books?readStatus=reading&sort=recently_read", "$C/books?readStatus=finished&sort=recently_read")
        val p = plan(root, "incremental", mapOf("covers_on" to false, "dynamic_lists" to dynamic))
        w.store.own(p.owner)
        w.store.setMeta("incremental_watermark", "2026-12-01")
        fake.routes["$S$C/books?order=desc&page=1&size=100&sort=recently_updated"] = books(listOf(1))
        for (path in dynamic) {
            fake.routes[S + MirrorLogic.mirrorPage(path, 1, null)] = books((1..100).toList(), 101)
            fake.routes[S + MirrorLogic.mirrorPage(path, 2, null)] = books(listOf(101), 101)
        }
        for (id in 1L..101L) w.store.putDetail(id, mapOf("id" to id), 100L)
        assertEquals("finished", w.run(p, creds))
        assertEquals(7, fake.asked.size)
        fake.asked.clear()
        for (path in dynamic) fake.routes[S + MirrorLogic.mirrorPage(path, 2, null)] = books(listOf(102), 101)
        fake.routes["$S$C/books/102"] = "{\"id\":102}"
        assertEquals("finished", w.run(p, creds))
        for (path in dynamic) {
            assertTrue(fake.asked.contains(S + MirrorLogic.mirrorPage(path, 2, null)))
            assertEquals(102L, ((w.store.window(path, 2, 100, null)!!["items"] as List<*>).single() as Map<*, *>)["id"])
        }
        assertEquals("2026-12-01", w.store.meta("incremental_watermark"))
        w.store.close(); root.deleteRecursively()
    }

    @Test fun incrementalIncludesWholeTimestampTieAcrossPages() {
        val (root, fake, w) = setup()
        val p = plan(root, "incremental", mapOf("covers_on" to false))
        w.store.own(p.owner)
        w.store.setMeta("full_at", 100L)
        w.store.setMeta("incremental_watermark", "2026-01-01")
        for (page in 1..2) {
            val ids = if (page == 1) (1..100).toList() else listOf(101)
            val body = JSONObject(books(ids, 101))
            for (i in 0 until body.getJSONArray("items").length()) body.getJSONArray("items").getJSONObject(i).put("updatedAt", "2026-01-01")
            for (id in ids) {
                val item = LuaValue.fromJson(body.getJSONArray("items").getJSONObject(ids.indexOf(id)).toString()) as Map<*, *>
                w.store.putItem(item, 100L); w.store.putDetail(id.toLong(), mapOf("id" to id.toLong()), 100L)
            }
            fake.routes["$S$C/books?order=desc&page=$page&size=100&sort=recently_updated"] = body.toString()
        }
        assertEquals("finished", w.run(p, creds))
        assertEquals(2, fake.asked.size)
        assertTrue(fake.asked.all { it.contains("sort=recently_updated") })
        w.store.close(); root.deleteRecursively()
    }

    @Test fun incrementalFailureKeepsWatermarkAndReturnsSummary() {
        val (root, fake, w) = setup()
        val p = plan(root, "incremental", mapOf("covers_on" to false))
        w.store.own(p.owner)
        w.store.setMeta("full_at", 100L)
        w.store.setMeta("incremental_watermark", "2026-01-04")
        fake.down = true
        assertEquals("no answer", w.run(p, creds))
        assertEquals("2026-01-04", w.store.meta("incremental_watermark"))
        val summary = LuaValue.parse(File(w.mirrorDir, "summary.lua").readBytes()) as Map<*, *>
        assertEquals("no answer", summary["why"])
        w.store.close(); root.deleteRecursively()
    }

}

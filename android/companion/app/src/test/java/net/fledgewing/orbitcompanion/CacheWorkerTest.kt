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
        val w = CacheWorker(Files.createTempDirectory("c").toFile(), { _, _, _, _ -> CacheWorker.Reply(0) }, log = {})
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
        @Synchronized
        override fun get(url: String, headers: Map<String, String>, sink: File?, maxBytes: Long): CacheWorker.Reply {
            asked.add(url); headersSeen.add(headers)
            if (down) return CacheWorker.Reply(0, err = "timeout")
            if (url.endsWith("/thumbnail")) {
                if (headers["If-None-Match"] == "\"e1\"") return CacheWorker.Reply(304)
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

    private fun setup(parallel: Int = 1): Triple<File, Fake, CacheWorker> {
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
        val w = CacheWorker(root, fake, now = { synchronized(this) { t++ } }, log = {}, sleep = {}, parallel = parallel)
        return Triple(root, fake, w)
    }

    private val creds = CacheWorker.Creds(S, "alice", "secret-key")

    @Test fun fullRefreshSavesSeedThenListsThenDetailsThenCovers() {
        val (root, fake, w) = setup()
        assertEquals("finished", w.run(plan(root, "full"), creds))
        val pages = fake.asked.filter { !it.endsWith("/thumbnail") }.map { it.removePrefix(S + C) }
        // Seed list, seed detail, then the section and the list it opens, then the other details.
        assertEquals(listOf("/books?page=1&size=100&sort=title", "/books/1", "/sections/authors?page=1&size=100",
            "/books?author=Ana%20Mar%C3%ADa&page=1&size=100", "/books/2", "/books/3"), pages)
        assertTrue(fake.asked.indexOfFirst { it.endsWith("/thumbnail") } > fake.asked.indexOf("$S$C/books/3"))
        // Each entry under its plugin key, readable by the plugin's Cache.decode format.
        val key = MirrorLogic.key("alice|$S", S, "$C/books/2")
        assertNotNull(w.entryBody(File(w.mirrorDir, MirrorLogic.hash(key) + ".lua"), key))
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
        // Covers already saved come back 304.
        val st = LuaValue.parse(File(w.mirrorDir, "status.lua").readBytes()) as Map<*, *>
        assertTrue(((st["covers"] as Map<*, *>)["not_modified"] as Long) > 0)
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

    @Test fun storageLimitStopsSavingAndSaysWhy() {
        val (root, _, w) = setup()
        assertEquals("finished", w.run(plan(root, "full", mapOf("limit" to 1L, "base_kept" to 10L)), creds))
        val st = LuaValue.parse(File(w.mirrorDir, "status.lua").readBytes()) as Map<*, *>
        assertTrue(((st["limit_note"] as Map<*, *>)["text"] as String).startsWith("Storage limit reached"))
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
        assertEquals(true, ev1["unchanged"]); assertNull(ev1["saved"])
        fake.routes["$S$path"] = page(listOf(1, 2, 5))
        w.check(CacheWorker.Check(key, path, "open", creds, "alice|$S"))
        val ev2 = File(root, "events").listFiles()!!.map { LuaValue.parse(it.readBytes()) as Map<*, *> }.first { it["changed"] == true }
        assertEquals(listOf(1L, 2L, 5L), ev2["ids"])
        assertNotNull(w.entryBody(File(root, MirrorLogic.hash(key) + ".lua"), key))
    }

    /** Speed: a 500-book library over a server that takes 20 ms a request; 4 at a time. */
    @Test fun aBigLibraryIsFetchedFourAtATime() {
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
        val w = CacheWorker(root, http, log = { synchronized(logs) { logs.add(it) } }, sleep = {})
        val t0 = System.nanoTime()
        assertEquals("finished", w.run(plan(root, "full", mapOf("covers_on" to false, "sections" to emptyList<String>(), "seed_details" to emptyList<Long>())), creds))
        val secs = (System.nanoTime() - t0) / 1e9
        val line = logs.first { it.startsWith("mirror: run r1") }
        assertTrue(line, line.contains("$n books' details, ${n + 5} requests"))
        assertEquals(4, most)
        // One at a time this is 505 x 20 ms = 10 s; four at a time about a quarter.
        assertTrue("took $secs s: $line", secs < 5)
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
        val w = CacheWorker(root, http, log = { logs.add(it) }, sleep = { waits.add(it) }, parallel = 1)
        val p = plan(root, "full", mapOf("seed_lists" to emptyList<String>(), "seed_details" to emptyList<Long>(),
            "sections" to listOf("$C/sections/series", "$C/sections/authors")))
        assertEquals("finished", w.run(p, creds))
        val log = logs.joinToString("\n")
        assertTrue(log, log.contains("/sections/series?page=1&size=100 failed (timeout), try 1 of 3; again in 5s, in pages of 50"))
        assertTrue(log, log.contains("/sections/authors?page=1&size=50 failed (timeout), try 2 of 3; again in 10s, in pages of 25"))
        assertTrue(log, log.contains("/sections/authors?page=1&size=25 skipped after 3 tries (timeout); the rest continues"))
        assertEquals(listOf(5, 5, 10), waits)
        val st = w.loadState()!!
        assertEquals(50, st.lists["$C/sections/series"]!!.size)
        assertEquals(1, st.skipped)
    }
}

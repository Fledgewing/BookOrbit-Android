package net.fledgewing.orbitcompanion

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** The sleep screen's pool, refreshed by the companion (SleepPoolLogic, SleepPoolBuilder; lock-screen.md R1-R4b, X1-X7). */
class SleepPoolTest {
    private fun seq(vararg v: Int): (Int) -> Int {
        var i = 0
        return { n -> val x = v[i % v.size]; i++; ((x - 1) % n) + 1 }
    }

    private fun ids(a: org.json.JSONArray?): List<Long> = a?.let { (0 until it.length()).map { i -> it.getLong(i) } }.orEmpty()

    /** shared/fixtures/sleep/cases.json "sources": Pick from and Leave out as sets, Library (R1c, X8). */
    @Test fun pickFromAndLeaveOutFollowTheSharedCases() {
        val src = JSONObject(File("../../../shared/fixtures/sleep/cases.json").readText()).getJSONObject("sources")
        val from = src.getJSONArray("from")
        for (n in 0 until from.length()) from.getJSONObject(n).let { c ->
            assertEquals(c.getString("name"), c.getString("expect"), SleepPoolLogic.sources(c.getString("wire")).joinToString("\n"))
        }
        val lo = src.getJSONArray("leave_out")
        for (n in 0 until lo.length()) lo.getJSONObject(n).let { c ->
            assertEquals(c.getString("name"), c.getString("expect"), SleepPoolLogic.rules(c.getString("wire")).joinToString("\n"))
        }
        val cand = src.getJSONArray("candidates")
        assertTrue(cand.length() >= 6)
        for (n in 0 until cand.length()) cand.getJSONObject(n).let { c ->
            val l = c.getJSONObject("lists").let { o -> o.keys().asSequence().associateWith { k -> ids(o.getJSONArray(k)) } }
            val (got, fb) = SleepPoolLogic.candidates(SleepPoolLogic.sources(c.getString("from")), l, ids(c.getJSONArray("bag")))
            assertEquals(c.getString("name"), ids(c.getJSONArray("expect")), got)
            assertEquals(c.getString("name"), c.optString("fallback").takeIf { !c.isNull("fallback") }, fb)
        }
        val check = src.getJSONArray("check")
        for (n in 0 until check.length()) check.getJSONObject(n).let { c ->
            val m = c.getJSONObject("members").let { o -> o.keys().asSequence().associateWith { k -> ids(o.getJSONArray(k)).toSet() } }
            val tags = if (c.isNull("tags")) null else c.getJSONArray("tags").let { a -> (0 until a.length()).map { a.getString(it) } }
            assertEquals(c.getString("name"), c.getString("expect"), SleepPoolLogic.check(c.getLong("id"), SleepPoolLogic.rules(c.getString("rules")), m, tags))
        }
    }

    @Test fun whichBooksCountAndLeaveOutIsOredAndFailsClosed() {
        val fx = JSONObject(File("../../../shared/fixtures/bookorbit/catalog-dashboard-section.want-to-read.json").readText())
        val first = fx.getJSONObject("section").getJSONArray("books").getJSONObject(0)
        assertTrue(SleepPoolLogic.eligible(mapOf("id" to first.getLong("id"), "hasCover" to first.getBoolean("hasCover")), null))
        assertFalse(SleepPoolLogic.eligible(mapOf("id" to 3L, "hasCover" to false), null))
        assertFalse(SleepPoolLogic.eligible(mapOf("id" to 3L, "hasCover" to true, "readStatus" to "read"), null))
        assertFalse("the book open now", SleepPoolLogic.eligible(mapOf("id" to 3L, "hasCover" to true), 3L))
        assertTrue(SleepPoolLogic.eligible(mapOf("id" to 3L, "hasCover" to true, "readStatus" to "want_to_read"), null))

        val rules = listOf("tag:age:18", "scope:3")
        val members = mapOf("scope:3" to setOf(10L))
        assertEquals("out", SleepPoolLogic.check(10, rules, members, emptyList()))
        assertEquals("tag, any case", "out", SleepPoolLogic.check(11, rules, members, listOf(" AGE:18 ")))
        assertEquals("keep", SleepPoolLogic.check(11, rules, members, listOf("fantasy")))
        assertEquals("no detail yet", "unknown", SleepPoolLogic.check(11, rules, members, null))
        assertEquals("scope not listed yet", "unknown", SleepPoolLogic.check(11, rules, emptyMap(), listOf("fantasy")))
        assertEquals("a known match wins", "out", SleepPoolLogic.check(10, rules, members, null))
        assertEquals("keep", SleepPoolLogic.check(11, emptyList(), emptyMap(), null))
        assertTrue(SleepPoolLogic.needsTags(rules)); assertFalse(SleepPoolLogic.needsTags(listOf("collection:2")))
        assertEquals(1, SleepPoolLogic.memberRules(rules).size)
        assertEquals(listOf("tag:age:18", "scope:3"), SleepPoolLogic.rules("tag: Age:18 \nscope:3\nscope:0\nscope:3"))
        assertTrue(SleepPoolLogic.due(null, 100)); assertFalse(SleepPoolLogic.due(100, 100 + 86_399))
        assertTrue(SleepPoolLogic.due(100, 100 + 86_400)); assertTrue(SleepPoolLogic.due(200, 100))
    }

    @Test fun theShuffleBagNeverRepeatsUntilUsedUp() {
        val rand = seq(1, 3, 2, 1, 2)
        val bag = SleepPoolLogic.Bag()
        SleepPoolLogic.bagSync(bag, listOf(1L, 2L, 3L, 4L), rand)
        assertEquals(4, bag.order.toSet().size)
        val first = bag.order[0]
        assertEquals("nothing shown yet", 4, SleepPoolLogic.bagNext(bag, rand).size)
        assertTrue(SleepPoolLogic.bagSeek(bag, bag.order[1]))
        assertEquals(2, bag.pos)
        assertFalse("never back", SleepPoolLogic.bagSeek(bag, first))
        assertFalse("the same book again", SleepPoolLogic.bagSeek(bag, bag.prev))
        // A member leaves before the cursor, a new one joins after it.
        val keep = bag.order.filter { it != bag.order[0] } + 9L
        SleepPoolLogic.bagSync(bag, keep, rand)
        assertEquals(4, bag.order.size); assertEquals("cursor follows the removal", 1, bag.pos)
        val rest = SleepPoolLogic.bagNext(bag, rand)
        assertEquals(3, rest.size); assertTrue("the new member is still to come", 9L in rest)
        for (i in 1..20) {
            val b = SleepPoolLogic.Bag(order = mutableListOf(1L, 2L, 3L), pos = 3, prev = 3)
            val again = SleepPoolLogic.bagNext(b) { n -> ((i + n) % n) + 1 }
            assertEquals(3, again.size); assertNotEquals("not the book just shown first", 3L, again[0])
        }
    }

    @Test fun everySleepRetiresTheUsedUpAndContinuesTheBag() {
        val (carry, retired) = SleepPoolLogic.carry(listOf(5L, 6L, 7L, 6L, 8L), mapOf(5L to 3, 6L to 2, 8L to 4))
        assertEquals("kept in order, once", listOf(6L, 7L), carry)
        assertEquals(setOf(5L, 8L), retired)
        assertEquals("no counts yet: all stay", 2, SleepPoolLogic.carry(listOf(1L, 2L), emptyMap()).first.size)
        val bag = SleepPoolLogic.Bag(order = mutableListOf(3L, 4L, 5L, 6L, 7L), pos = 1, prev = 3)
        SleepPoolLogic.bagTake(bag, setOf(4L, 6L))
        assertEquals(4, bag.pos); assertEquals(null, bag.prev)
        assertEquals(listOf(7L), SleepPoolLogic.bagNext(bag) { 1 })
    }

    private class Server(val books: () -> String) : CacheWorker.Http {
        val calls = ArrayList<String>()
        var auth: String? = null
        override fun get(url: String, headers: Map<String, String>, sink: File?, maxBytes: Long): CacheWorker.Reply {
            calls.add(url); auth = headers["x-auth-key"]
            val path = url.removePrefix("https://books.example")
            Regex("/books/(\\d+)/thumbnail$").find(path)?.let { m -> sink!!.writeText("jpg" + m.groupValues[1]); return CacheWorker.Reply(200, etag = "\"e\"") }
            val body = when {
                path.contains("sections/up-next-in-series") -> """{"section":{"books":[]}}"""
                path.contains("sections/want-to-read") -> books()
                path.endsWith("/catalog/books/2") -> """{"id":2,"title":"Tagged","hasCover":true,"tags":["Age:18"]}"""
                path.endsWith("/catalog/books/3") -> """{"id":3,"title":"Kept","hasCover":true,"tags":["cosy"]}"""
                path.contains("/sections/smart-scopes") -> """{"items":[{"id":12,"title":"Romance","count":4}]}"""
                path.contains("/sections/collections") -> """{"items":[]}"""
                else -> return CacheWorker.Reply(404)
            }
            return CacheWorker.Reply(200, body.toByteArray())
        }
    }

    private val creds = CacheWorker.Creds("https://books.example", "reader", "secret-key")

    @Test fun aPoolFromUpNextFallsBackLeavesOutAndWritesTheFiles() {
        val dir = Files.createTempDirectory("sleep").toFile()
        File(dir, "covers").mkdirs()
        File(dir, "covers/99.jpg").writeText("old")
        val server = Server { """{"section":{"books":[{"id":1,"title":"Read One","hasCover":true,"readStatus":"read"},
            {"id":2,"title":"Tagged","hasCover":true},{"id":3,"title":"Kept","hasCover":true},{"id":4,"title":"No Cover","hasCover":false}]}}""" }
        val sum = SleepPoolBuilder(dir, server, now = { 1000L }).build(SleepPoolBuilder.Ask("up_next", listOf("tag:age:18"), null, false, 100, creds))
        val pool = JSONObject(File(dir, "pool.json").readText())
        val items = pool.getJSONArray("items")
        assertEquals("only the kept book", 1, items.length())
        assertEquals(3L, items.getJSONObject(0).getLong("id")); assertEquals("covers/3.jpg", items.getJSONObject(0).getString("file"))
        assertEquals("jpg3", File(dir, "covers/3.jpg").readText())
        assertFalse("the old cover went", File(dir, "covers/99.jpg").exists())
        assertEquals("want-to-read", sum["fallback"]); assertEquals(1L, sum["left_out"])
        // The sharp covers' account: server and user, never the key, in no file.
        assertEquals("https://books.example", pool.getString("server")); assertEquals("reader", pool.getString("user"))
        assertEquals(100L, pool.getLong("storage_limit_mb"))
        dir.walk().filter { it.isFile }.forEach { assertFalse(it.name, it.readText().contains("secret-key")) }
        assertEquals("secret-key", server.auth)
        assertEquals("the pickers' lists", 12L, JSONObject(File(dir, "scopes.json").readText()).getJSONArray("scopes").getJSONObject(0).getLong("id"))
        dir.deleteRecursively()
    }

    @Test fun twentyFourReadyAndEverySleepRetiresAndTopsUp() {
        val dir = Files.createTempDirectory("sleep").toFile()
        var n = 30
        val server = object : CacheWorker.Http {
            override fun get(url: String, headers: Map<String, String>, sink: File?, maxBytes: Long): CacheWorker.Reply {
                Regex("/books/(\\d+)/thumbnail$").find(url)?.let { sink!!.writeText("jpg"); return CacheWorker.Reply(200) }
                if (!url.contains("sections/up-next-in-series")) return CacheWorker.Reply(404)
                val books = (1..n).joinToString(",") { """{"id":${if (n == 1) 40 else it},"title":"B","hasCover":true}""" }
                return CacheWorker.Reply(200, """{"section":{"books":[$books]}}""".toByteArray())
            }
        }
        fun build(every: Boolean): List<Long> {
            SleepPoolBuilder(dir, server).build(SleepPoolBuilder.Ask("up_next", emptyList(), null, every, null, creds))
            val a = JSONObject(File(dir, "pool.json").readText()).getJSONArray("items")
            return (0 until a.length()).map { a.getJSONObject(it).getLong("id") }
        }
        fun state(json: String) = File(dir, "state.json").writeText(json)
        var ids = build(false)
        assertEquals((1L..24L).toList(), ids)
        state("""{"v":1,"shown":3,"changed_at":1,"shows":{"1":3,"2":3,"3":1}}""")
        ids = build(true)
        assertEquals(24, ids.size)
        assertTrue("retired and topped up: $ids", 1L !in ids && 2L !in ids && 3L in ids && 25L in ids && 26L in ids)
        assertFalse("a retired cover's file goes", File(dir, "covers/1.jpg").exists())
        n = 1
        state("""{"v":1,"shown":0,"changed_at":1,"shows":{}}""")
        assertEquals(listOf(40L), build(true))
        state("""{"v":1,"shown":40,"changed_at":1,"shows":{"40":3}}""")
        assertEquals("kept cycling", listOf(40L), build(true))
        dir.deleteRecursively()
    }

    @Test fun aScopeIsShuffledIntoABagAndTheBagFollowsWhatWasShown() {
        val dir = Files.createTempDirectory("sleep").toFile()
        val server = object : CacheWorker.Http {
            override fun get(url: String, headers: Map<String, String>, sink: File?, maxBytes: Long): CacheWorker.Reply {
                if (url.contains("/thumbnail")) { sink!!.writeText("jpg"); return CacheWorker.Reply(200) }
                if (url.contains("smartScopeId=5")) return CacheWorker.Reply(200, """{"items":[{"id":1},{"id":2},{"id":3}],"hasNext":false}""".toByteArray())
                val id = Regex("/catalog/books/(\\d+)$").find(url)?.groupValues?.get(1) ?: return CacheWorker.Reply(404)
                return CacheWorker.Reply(200, """{"id":$id,"title":"B$id","hasCover":true}""".toByteArray())
            }
        }
        val b = SleepPoolBuilder(dir, server, now = { 5000L }, rand = { 1 })
        b.build(SleepPoolBuilder.Ask("scope:5", emptyList(), null, false, null, creds))
        val bag = SleepPoolLogic.Bag.of(LuaValue.parse(File(dir, "bag.lua").readBytes()) as Map<*, *>)
        assertEquals("scope:5", bag.source); assertEquals(3, bag.order.size); assertEquals(5000L, bag.at)
        File(dir, "state.json").writeText("""{"v":1,"shown":${bag.order[1]},"changed_at":1}""")
        b.build(SleepPoolBuilder.Ask("scope:5", emptyList(), null, false, null, creds))
        val moved = SleepPoolLogic.Bag.of(LuaValue.parse(File(dir, "bag.lua").readBytes()) as Map<*, *>)
        assertEquals("moved to what was shown", 2, moved.pos)
        val first = JSONObject(File(dir, "pool.json").readText()).getJSONArray("items").getJSONObject(0).getLong("id")
        assertEquals("the last shown stays first", moved.prev, first)
        dir.deleteRecursively()
    }

    /** R1c: two lists and a collection take turns; Library lists every book with no filter; Leave out Library empties the pool. */
    @Test fun severalSourcesTakeTurnsAndLibraryListsEveryBook() {
        val dir = Files.createTempDirectory("sleep").toFile()
        val calls = mutableListOf<String>()
        val server = object : CacheWorker.Http {
            override fun get(url: String, headers: Map<String, String>, sink: File?, maxBytes: Long): CacheWorker.Reply {
                calls.add(url)
                if (url.contains("/thumbnail")) { sink!!.writeText("jpg"); return CacheWorker.Reply(200) }
                fun list(vararg ids: Int) = """{"section":{"books":[${ids.joinToString(",") { """{"id":$it,"title":"B$it","hasCover":true}""" }}]}}"""
                val body = when {
                    url.contains("sections/up-next-in-series") -> list(1, 2, 3)
                    url.contains("sections/want-to-read") -> list(20, 2)
                    url.contains("collectionId=7") -> """{"items":[{"id":70}],"hasNext":false}"""
                    url.contains("/catalog/books?") -> """{"items":[{"id":101},{"id":102}],"hasNext":false}"""
                    else -> Regex("/catalog/books/(\\d+)$").find(url)?.groupValues?.get(1)?.let { """{"id":$it,"title":"B$it","hasCover":true}""" }
                        ?: return CacheWorker.Reply(404)
                }
                return CacheWorker.Reply(200, body.toByteArray())
            }
        }
        fun ids(): List<Long> = JSONObject(File(dir, "pool.json").readText()).getJSONArray("items").let { a -> (0 until a.length()).map { a.getJSONObject(it).getLong("id") } }
        val b = SleepPoolBuilder(dir, server, now = { 5000L }, rand = { 1 })
        b.build(SleepPoolBuilder.Ask("up_next\nwant_to_read\ncollection:7", emptyList(), null, false, null, creds))
        assertEquals("in turn, a book once", listOf(1L, 20L, 70L, 2L, 3L), ids())
        calls.clear()
        val sum = b.build(SleepPoolBuilder.Ask("library", emptyList(), null, false, null, creds))
        assertTrue("every book, no filter: $calls", calls.any { it.contains("/catalog/books?") && !it.contains("Id=") })
        assertEquals(setOf(101L, 102L), ids().toSet())
        assertEquals(null, sum["fallback"])
        b.build(SleepPoolBuilder.Ask("library", listOf("library"), null, false, null, creds))
        assertEquals("Leave out Library: nothing left, the current book shows", emptyList<Long>(), ids())
        dir.deleteRecursively()
    }
}

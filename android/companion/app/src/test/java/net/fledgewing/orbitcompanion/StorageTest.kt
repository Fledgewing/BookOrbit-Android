package net.fledgewing.orbitcompanion

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** The storage limit, counted and applied in the companion (docs/design/companion-worker.md). */
class StorageTest {
    /** shared/fixtures/cache/cases.json storage.plans: the eviction order the plugin used to compute. */
    @Test fun evictionOrderMatchesTheSharedCases() {
        // @fixture cache/cases.json#storage.plans
        val plans = JSONObject(File("../../../shared/fixtures/cache/cases.json").readText()).getJSONObject("storage").getJSONArray("plans")
        for (i in 0 until plans.length()) {
            val c = plans.getJSONObject(i)
            val its = c.getJSONArray("items")
            val items = (0 until its.length()).map { its.getJSONObject(it) }.map {
                StorageLogic.Item(it.getString("k"), it.getLong("bytes"), it.getLong("at"), it.getString("kind"))
            }
            val limit = if (c.isNull("limit")) null else c.getLong("limit")
            val r = StorageLogic.plan(items, limit)
            val want = c.getJSONArray("drop").let { d -> (0 until d.length()).map { d.getString(it) } }
            assertEquals(c.getString("name"), want, r.drop)
            assertEquals(c.getString("name") + " after", c.getLong("after"), r.after)
        }
    }

    @Test fun netGrowthAndDataPriorityMatchFirmwareContract() {
        // @fixture storage/cases.json
        val cases = JSONObject(File("../../../shared/fixtures/storage/cases.json").readText()).getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val items = c.getJSONArray("items").let { a -> (0 until a.length()).map { a.getJSONObject(it) }.map {
                StorageLogic.Item(it.getString("k"), it.getLong("bytes"), it.getLong("at"), it.getString("kind"))
            } }
            val got = StorageLogic.admit(c.getLong("used"), c.getLong("old"), c.getLong("new"),
                if (c.isNull("limit")) null else c.getLong("limit"), items, c.getBoolean("data"))
            val drop = c.getJSONArray("drop").let { a -> (0 until a.length()).map { a.getString(it) } }
            assertEquals(c.getString("name"), drop, got.drop)
            assertEquals(c.getString("name"), c.getBoolean("allowed"), got.allowed)
        }
    }

    @Test fun shownOrderAndAllProtectionSourcesAreAppliedWithoutAnImageSweep() {
        val settings = Files.createTempDirectory("storage-protection").toFile()
        val root = File(settings, "orbit-cache").apply { mkdirs() }
        val covers = File(root, "covers").apply { mkdirs() }
        var resized = 0
        val w = CacheWorker(root, { _, _, _, _ -> CacheWorker.Reply(0) }, now = { 100L }, log = {},
            openSql = { JdbcSql(it) }, resizeThumbnail = { _, _, _ -> resized++ })
        w.store.putEntry("home", "/koreader/plugin/catalog/dashboard", mapOf("continueReading" to listOf(mapOf("id" to 1L))), 1L)
        File(settings, "orbit-sleep").mkdirs()
        File(settings, "orbit-sleep/pool.json").writeText("""{"items":[{"id":2}]}""")
        File(root, "copies").mkdirs()
        File(root, "copies/ask.lua").writeBytes(LuaValue.encode(mapOf("books" to listOf(mapOf("book_id" to 3L)))))
        for (id in 1..5) File(covers, "${id}_0.jpg").apply { writeBytes(ByteArray(1000)); setLastModified(id * 1000L) }
        w.store.keepCovers(listOf("4_0.jpg"))
        val items = w.storageItems(covers.path, true)
        assertEquals(0, resized)
        for (id in 1..3) assertEquals("kept", items.single { it.k == "c:${id}_0.jpg" }.kind)
        w.coversShown(listOf(File(covers, "4_0.jpg").path))
        assertEquals(1, resized)
        w.storage(CacheWorker.StorageAsk("test", items.sumOf { it.bytes } - 1, covers.path, true))
        assertFalse("oldest eligible shown cover goes", File(covers, "5_0.jpg").exists())
        for (id in 1..4) assertTrue(File(covers, "${id}_0.jpg").exists())
        settings.deleteRecursively()
    }

    @Test fun orphanEtagsAndInactiveStressFilesGoOnCheck() {
        val root = Files.createTempDirectory("cleanup").toFile()
        val covers = File(root, "covers").apply { mkdirs() }
        File(covers, "orphan.jpg.etag").writeText("orphan")
        File(covers, "kept.jpg").writeText("image")
        File(covers, "kept.jpg.etag").writeText("kept")
        File(root, "stress.db").writeText("stress")
        File(root, "stress-writer.lua").writeText("stress")
        val w = CacheWorker(root, { _, _, _, _ -> CacheWorker.Reply(0) }, log = {}, openSql = { JdbcSql(it) })
        w.storageItems(covers.path, false)
        assertFalse(File(covers, "orphan.jpg.etag").exists())
        assertTrue(File(covers, "kept.jpg.etag").exists())
        assertFalse(File(root, "stress.db").exists())
        assertFalse(File(root, "stress-writer.lua").exists())
    }

    @Test fun countRemovesBrowsingEntriesAndCoversButNeverTheSavedOnes() {
        val root = Files.createTempDirectory("s").toFile()
        val covers = File(root, "covers").apply { mkdirs() }
        var t = 0L
        val w = CacheWorker(root, { _, _, _, _ -> CacheWorker.Reply(0) }, now = { t }, log = {}, openSql = { JdbcSql(it) })
        val st = w.store
        st.own("reader|https://books.example")
        val big = sortedMapOf<String, Any?>("text" to "x".repeat(2900))
        // Home is kept; two browsing entries, the older one used at 2.
        t = 1; st.save("home", "/koreader/plugin/catalog/dashboard", big, 1, null)
        st.save("old", "/koreader/plugin/catalog/collections", big, 2, null)
        st.save("new", "/koreader/plugin/catalog/shelves", big, 50, null)
        fun cover(name: String, bytes: Int, at: Long) = File(covers, name).apply { writeBytes(ByteArray(bytes)); setLastModified(at * 1000) }
        cover("a.jpg", 2000, 10); cover("m1.jpg", 2000, 3); cover("m2.jpg", 2000, 40)
        st.keepCovers(listOf("m1.jpg", "m2.jpg"))
        val before = w.storageItems(covers.path, true)
        val used = before.sumOf { it.bytes }
        val entry = before.first { it.k == "e:old" }.bytes
        // Room for everything but one browsing entry and one cover.
        t = 500
        w.storage(CacheWorker.StorageAsk("start", used - entry - 1000, covers.path, mirrorCovers = true))
        assertFalse("the plain cover went", File(covers, "a.jpg").exists())
        assertTrue(File(covers, "m1.jpg").exists() && File(covers, "m2.jpg").exists())
        assertEquals("the oldest browsing entry went; Home never", null, st.read("old", "/koreader/plugin/catalog/collections", null))
        assertTrue(st.read("home", "/koreader/plugin/catalog/dashboard", null) != null && st.read("new", "/koreader/plugin/catalog/shelves", null) != null)
        val ev = File(root, "events").listFiles()!!.single().let { LuaValue.parse(it.readBytes()) as Map<*, *> }
        assertEquals("storage", ev["kind"])
        assertEquals(sortedMapOf("cache" to 1L, "cover" to 1L, "mirror_cover" to 0L), ev["removed"])
        val totals = ev["totals"] as Map<*, *>
        assertEquals(4000L, totals["mirror_cover"])
        assertEquals(used - entry - 2000, totals["used"])
        // The totals for the plugin's next start, in the database.
        assertEquals(totals, (LuaValue.parse(st.meta("storage")!!.toByteArray(Charsets.ISO_8859_1)) as Map<*, *>)["totals"])
        root.deleteRecursively()
    }
}

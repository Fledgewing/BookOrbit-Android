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

    @Test fun countRemovesCoversAndNamesTheEntriesForThePlugin() {
        val root = Files.createTempDirectory("s").toFile()
        val covers = File(root, "covers").apply { mkdirs() }
        val w = CacheWorker(root, { _, _, _, _ -> CacheWorker.Reply(0) }, now = { 500L }, log = {})
        File(root, "index.lua").writeBytes(LuaValue.encode(sortedMapOf<String, Any?>("entries" to sortedMapOf(
            "list" to sortedMapOf<String, Any?>("bytes" to 3000L, "used_at" to 1L, "keep" to true),
            "old" to sortedMapOf<String, Any?>("bytes" to 3000L, "used_at" to 2L),
            "new" to sortedMapOf<String, Any?>("bytes" to 3000L, "used_at" to 50L),
        ))))
        fun cover(name: String, bytes: Int, at: Long) = File(covers, name).apply { writeBytes(ByteArray(bytes)); setLastModified(at * 1000) }
        cover("a.jpg", 2000, 10); cover("m1.jpg", 2000, 3); cover("m2.jpg", 2000, 40)
        File(root, "mirror").mkdirs()
        File(root, "mirror/cover_keep.lua").writeBytes(LuaValue.encode(sortedMapOf("m1.jpg" to true, "m2.jpg" to true)))
        val index = File(root, "index.lua").length()
        // 9000 entries + 6000 covers + the index; the limit leaves room for the index and 10000.
        w.storage(CacheWorker.StorageAsk("start", 10_000L + index, covers.path, mirrorCovers = true))
        assertFalse("the plain cover went", File(covers, "a.jpg").exists())
        assertTrue(File(covers, "m1.jpg").exists() && File(covers, "m2.jpg").exists())
        val ev = File(root, "events").listFiles()!!.single().let { LuaValue.parse(it.readBytes()) as Map<*, *> }
        assertEquals("storage", ev["kind"])
        val drop = (ev["drop"] as List<*>).map { (it as Map<*, *>)["key"] }
        assertEquals("the oldest browsing page; the kept list never", listOf("old"), drop)
        assertEquals(2L, ((ev["drop"] as List<*>)[0] as Map<*, *>)["used_at"])
        val totals = ev["totals"] as Map<*, *>
        assertEquals(10_000L + index, totals["used"])
        assertEquals(4000L, totals["mirror_cover"])
        // The totals for the plugin's next start.
        assertEquals(totals, (LuaValue.parse(File(root, "storage.lua").readBytes()) as Map<*, *>)["totals"])
        root.deleteRecursively()
    }
}

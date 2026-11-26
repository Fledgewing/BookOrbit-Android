package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** The last two jobs off KOReader: Leave out's tag counts (tags.json) and a Full refresh's cover recheck. */
class TagsAndRecheckTest {
    @Test fun tagsAreCountedFromTheCachesAndTheMirrorsSavedDetails() {
        assertEquals(listOf(SleepPoolLogic.Tag("age:18", "Age:18", 2), SleepPoolLogic.Tag("cosy", "cosy", 1)),
            SleepPoolLogic.tagCounts(listOf(listOf("Age:18", "cosy"), listOf("age:18", " Age:18 "), emptyList())))
        val root = Files.createTempDirectory("tags").toFile()
        val w = CacheWorker(root, { _, _, _, _ -> CacheWorker.Reply(0) }, log = {}, openSql = { JdbcSql(it) })
        for (i in 1..3) w.store.putDetail(i.toLong(), sortedMapOf<String, Any?>("tags" to listOf("Fantasy", LuaValue.str("Ünïcode"))), 1L)
        w.store.putDetail(9L, sortedMapOf<String, Any?>("tags" to listOf("Space")), 1L)
        val details = w.detailTags(2000)
        assertEquals(4, details.size)
        assertEquals("capped", 2, w.detailTags(2).size)
        val sleep = File(root, "sleep").apply { mkdirs() }
        SleepPoolBuilder(sleep, { _, _, _, _ -> CacheWorker.Reply(0) }).tags(details)
        val tags = JSONObject(File(sleep, "tags.json").readText()).getJSONArray("tags")
        assertEquals("fantasy", tags.getJSONObject(0).getString("tag")); assertEquals(3, tags.getJSONObject(0).getInt("count"))
        assertEquals("real text, not bytes", "Ünïcode", tags.getJSONObject(1).getString("label"))
        root.deleteRecursively()
    }

    @Test fun aFullRefreshsCoversAreAskedAgainIfNoneMatch() {
        val root = Files.createTempDirectory("rc").toFile()
        val sent = HashMap<Long, String?>()
        val http = CacheWorker.Http { url, h, sink, _ ->
            val id = Regex("/books/(\\d+)/thumbnail").find(url)!!.groupValues[1].toLong()
            sent[id] = h["If-None-Match"]
            if (id == 2L) { sink!!.writeText("new"); CacheWorker.Reply(200, etag = "\"n\"", contentType = "image/jpeg") } else CacheWorker.Reply(304)
        }
        val w = CacheWorker(root, http, now = { 100L }, log = {}, openSql = { JdbcSql(it) })
        val covers = File(root, "covers").apply { mkdirs() }
        for (id in 1..3) File(covers, "${id}_0.jpg").writeBytes(byteArrayOf(-1, -40, -1) + "old".toByteArray())
        File(covers, "1_0.jpg.etag").writeText("\"a\""); File(covers, "2_0.jpg.etag").writeText("\"b\"")
        w.store.own("owner")
        val results=(1L..3L).associateWith { w.acquireCoverReference("owner",File(covers,"${it}_0.jpg").path,
            CacheWorker.Creds("https://books.example","reader","k"),covers,true) }
        assertEquals(mapOf(1L to "\"a\"",2L to "\"b\"",3L to null),sent)
        fun delivered(id: Long)=File(LuaValue.utf8(results.getValue(id)["local_path"] as String))
        assertEquals("new",delivered(2).readText()); assertEquals("\"n\"",File(delivered(2).path+".etag").readText())
        assertEquals("old",delivered(1).readBytes().drop(3).toByteArray().toString(Charsets.UTF_8))
        assertFalse(File(delivered(2).path+".part").exists())
        assertEquals("old",File(covers,"2_0.jpg").readBytes().drop(3).toByteArray().toString(Charsets.UTF_8))
        root.deleteRecursively()
    }
}

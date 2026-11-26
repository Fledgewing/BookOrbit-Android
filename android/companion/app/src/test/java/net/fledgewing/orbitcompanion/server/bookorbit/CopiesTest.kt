package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** Keep copies current: the lookup the companion does for the plugin (COPIES). */
class CopiesTest {
    private fun book(md5: String, path: String, id: Long, file: Long, incompatible: Boolean = false) =
        sortedMapOf<String, Any?>("md5" to md5, "path" to path, "book_id" to id, "file_id" to file, "incompatible" to incompatible)

    private fun files(id: Long, hash: String) = listOf(sortedMapOf<String, Any?>("id" to id, "fileHash" to hash))

    @Test fun detailPersistenceRunsFromTheCompanionSnapshot() {
        val base = Files.createTempDirectory("detail-persist").toFile()
        try {
            CacheWorker(File(base, "orbit-cache"), { _, _, _, _ -> CacheWorker.Reply(0) }, log = {}, openSql = { JdbcSql(it) }).let { w ->
                w.store.putDetail(7, mapOf("id" to 7L, "title" to "Synthetic", "files" to files(70, "hash")), 1)
                w.rememberDetail(7)
                val saved = LuaValue.parse(File(base, "orbit-detail-cache.lua").readBytes()) as Map<*, *>
                assertEquals("Synthetic", (((saved["books"] as Map<*, *>)["7"]) as Map<*, *>)["title"])
            }
        } finally { base.deleteRecursively() }
    }

    @Test fun changedCopiesAreFoundByTheFlagOrASavedDetailsHash() {
        val books = listOf(book("aaa", "/b/a.epub", 1, 10, incompatible = true), book("bbb", "/b/b.epub", 2, 20), book("ccc", "/b/c.epub", 3, 30))
        val details = mapOf("2" to CopiesLogic.Detail(files(20, "new"), 1), "3" to CopiesLogic.Detail(files(30, "ccc"), 1))
        val c = CopiesLogic.candidates(books, details)
        assertEquals(listOf("/b/a.epub:incompatible", "/b/b.epub:hash:bbb"), c.map { "${it["path"]}:${it["why"]}" + if (it["why"] == "hash") ":${it["md5"]}" else "" })
        assertEquals("12", CopiesLogic.detailId("/koreader/plugin/catalog/books/12?variant=x"))
        assertEquals("12", CopiesLogic.detailId("/koreader/plugin/catalog/books/12"))
        assertEquals(null, CopiesLogic.detailId("/koreader/plugin/catalog/books/12/thumbnail"))
    }

    @Test fun theNewestSavedDetailWinsAndOnlyCopiesOnTheReaderCount() {
        val root = Files.createTempDirectory("cp").toFile()
        val w = CacheWorker(root, { _, _, _, _ -> CacheWorker.Reply(0) }, now = { 500L }, log = {}, openSql = { JdbcSql(it) })
        val books = File(root, "books").apply { mkdirs() }
        File(books, "b.epub").writeText("x")
        File(books, "c.epub").writeText("x")
        val owner = "reader|https://books.example"
        val server = "https://books.example"
        val template = "/koreader/plugin/catalog/books/987654321?variant=v"
        // Book 2: the end-of-book cache is older than the saved detail, which has the new hash.
        w.store.own(owner)
        w.store.putDetail(2L, sortedMapOf("id" to 2L, "files" to files(20, "srv2")), 200L)
        // Book 3: a saved detail newer than the end-of-book cache, with a changed hash; its copy is gone.
        w.store.putDetail(3L, sortedMapOf("id" to 3L, "files" to files(30, "srv3")), 300L)
        File(root, "copies").mkdirs()
        File(root, "copies/ask.lua").writeBytes(LuaValue.encode(sortedMapOf<String, Any?>(
            "books" to listOf(book("old2", "${books.path}/b.epub", 2, 20), book("old3", "${books.path}/gone.epub", 3, 30), book("cur4", "${books.path}/c.epub", 4, 40)),
            "eob" to sortedMapOf("2" to sortedMapOf<String, Any?>("files" to files(20, "old2"), "saved_at" to 100L),
                "4" to sortedMapOf<String, Any?>("files" to files(40, "cur4"), "saved_at" to 100L)),
            "owner" to owner, "server" to server, "detail_template" to template, "sentinel" to "987654321")))
        val ask=LuaValue.parse(File(root,"copies/ask.lua").readBytes()) as Map<*,*>
        val result=w.changedCopies((ask["books"] as List<*>).map { it as Map<*,*> },ask["eob"] as Map<*,*>)
        assertEquals(3,result.checked)
        assertEquals(listOf("${books.path}/b.epub"),result.found.map { it["path"] })
        assertEquals(1,result.gone)
        root.deleteRecursively()
    }
}

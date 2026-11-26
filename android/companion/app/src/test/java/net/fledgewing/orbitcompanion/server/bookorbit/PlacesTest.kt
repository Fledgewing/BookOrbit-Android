package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** Commands touch files only inside the companion's own folders (docs/design/security.md). */
class PlacesTest {
    private fun tmp(p: String) = Files.createTempDirectory(p).toFile()

    @Test fun onlyPathsInsideTheRootsAreAccepted() {
        val base = tmp("places")
        val root = File(base, "orbit-cache").apply { mkdirs() }
        val roots = listOf(root)
        assertEquals(File(root, "covers/1.jpg").canonicalFile, Places.inside(File(root, "covers/1.jpg").path, roots))
        assertEquals(root.canonicalFile, Places.inside(root.path, roots))
        assertNull("a sibling with the same prefix", Places.inside(File(base, "orbit-cache2/x.jpg").path, roots))
        assertNull("parent segments", Places.inside("${root.path}/../orbit-cache/x.jpg", roots))
        assertNull("relative", Places.inside("covers/x.jpg", roots))
        assertNull("outside", Places.inside(File(base, "photos").path, roots))
        assertNull(Places.inside(null, roots))
        assertNull(Places.inside("", roots))
        base.deleteRecursively()
    }

    @Test fun aSymlinkPointingOutIsRefused() {
        val base = tmp("places-link")
        val root = File(base, "root").apply { mkdirs() }
        val out = File(base, "out").apply { mkdirs() }
        Files.createSymbolicLink(File(root, "link").toPath(), out.toPath())
        assertNull(Places.inside(File(root, "link/a.jpg").path, listOf(root)))
        assertNull(Places.inside(File(root, "link").path, listOf(root)))
        base.deleteRecursively()
    }

    @Test fun storageOutsideTheRootsCountsAndDeletesNothingThere() {
        val base = tmp("places-storage")
        val root = File(base, "orbit-cache").apply { mkdirs() }
        val photos = File(base, "photos").apply { mkdirs() }
        for (i in 1..3) File(photos, "$i.jpg").writeBytes(ByteArray(5000))
        val w = CacheWorker(root, { _, _, _, _ -> CacheWorker.Reply(0) }, log = {}, openSql = { JdbcSql(it) })
        w.store.own("reader|https://books.example")
        assertTrue("not counted", w.storageItems(photos.path, false).none { it.k.startsWith("c:") })
        w.storage(CacheWorker.StorageAsk("plugin", 1, photos.path, mirrorCovers = false))
        assertEquals(3, photos.listFiles()!!.size)
        // A link inside the root that points out is not followed either.
        Files.createSymbolicLink(File(root, "covers").toPath(), photos.toPath())
        w.storage(CacheWorker.StorageAsk("plugin", 1, File(root, "covers").path, mirrorCovers = false))
        assertEquals(3, photos.listFiles()!!.size)
        base.deleteRecursively()
    }

    @Test fun recheckLeavesFilesOutsideTheRootsAlone() {
        val base = tmp("places-recheck")
        val root = File(base, "orbit-cache").apply { mkdirs() }
        val other = File(base, "other").apply { mkdirs() }
        val f = File(other, "1.jpg").apply { writeText("mine") }
        File(other, "1.jpg.etag").writeText("\"a\"")
        var asked = 0
        val http = CacheWorker.Http { _, _, sink, _ -> asked++; sink?.writeText("theirs"); CacheWorker.Reply(200, etag = "\"n\"", contentType = "image/jpeg") }
        val w = CacheWorker(root, http, log = {}, openSql = { JdbcSql(it) })
        w.recheckCovers("plugin", CacheWorker.Creds("https://books.example", "reader", "k"), listOf(1L to f.path, 2L to "${root.path}/../other/1.jpg"))
        assertEquals(0, asked)
        assertEquals("mine", f.readText())
        assertEquals("\"a\"", File(other, "1.jpg.etag").readText())
        base.deleteRecursively()
    }

    @Test fun aPlansCoverFolderOutsideTheRootsGetsNoCovers() {
        val base = tmp("places-plan")
        val root = File(base, "orbit-cache").apply { mkdirs() }
        val w = CacheWorker(root, { _, _, _, _ -> CacheWorker.Reply(0) }, log = {}, openSql = { JdbcSql(it) })
        val book = mapOf("id" to 1L, "updatedAt" to "2026", "hasCover" to true)
        assertNull(w.coverPath(CacheWorker.Plan(mapOf("cover_dir" to File(base, "elsewhere").path)), book))
        assertNotNull(w.coverPath(CacheWorker.Plan(mapOf("cover_dir" to File(root, "thumbs").path)), book))
        base.deleteRecursively()
    }
}

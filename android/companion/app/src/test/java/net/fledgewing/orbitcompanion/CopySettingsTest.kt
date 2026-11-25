// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class CopySettingsTest {
    @Test fun copyMigrationKeepsStatisticsWalAndCacheRollbackModesSeparate() {
        val base = Files.createTempDirectory("copy-settings").toFile()
        val old = "1".repeat(32)
        val new = "2".repeat(32)
        try {
            val book = File(base, "Books/book.epub").apply { parentFile!!.mkdirs(); writeText("book") }
            val sidecar = File(base, "Books/book.sdr/metadata.epub.lua").apply {
                parentFile!!.mkdirs()
                writeBytes(LuaValue.encode(mapOf("partial_md5_checksum" to old, "copt_b_page_margin" to 15L)))
            }
            val root = File(base, "orbit-cache")
            AndroidSql(File(base, "statistics.sqlite3"), wal = true).use { stats ->
                stats.exec("CREATE TABLE book (md5 TEXT)")
                stats.exec("INSERT INTO book VALUES (?)", old)
                val worker = CacheWorker(root, { _, _, _, _ -> CacheWorker.Reply(0) }, log = {}, bookRoots = listOf(base))
                worker.carryCopySettings(book.path, old, new)
                assertEquals("wal", stats.pragma("journal_mode"))
                assertEquals(new, stats.query("SELECT md5 FROM book") { it.text(0) }.single())
                assertEquals(new, (LuaValue.parse(sidecar.readBytes()) as Map<*, *>)["partial_md5_checksum"])
                assertEquals(15L, (LuaValue.parse(sidecar.readBytes()) as Map<*, *>)["copt_b_page_margin"])
            }
            AndroidSql(File(root, "orbit.db")).use { cache -> assertEquals("truncate", cache.pragma("journal_mode")) }
            assertEquals("book", book.readText())
        } finally { base.deleteRecursively() }
    }
}

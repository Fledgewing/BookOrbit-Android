package net.fledgewing.orbitcompanion

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicLong

/**
 * The stress test's writer (docs/design/sqlite-cache.md "Stress test") against a real SQLite, with
 * a reader on its own connection reading the same file the whole time, as KOReader does on the
 * device: every read sees one whole page, and the writer's file passes integrity_check.
 */
class SqliteStressTest {
    @Test
    fun writerAndReaderAgreeUnderLoad() {
        val dir = Files.createTempDirectory("orbit-stress").toFile()
        val file = java.io.File(dir, SqliteStress.FILE)
        val lines = ArrayList<String>()
        val done = java.util.concurrent.atomic.AtomicBoolean(false)
        val reads = AtomicLong()
        val torn = AtomicLong()
        val reader = Thread {
            Thread.sleep(200)
            val db = JdbcSql(file)
            while (!done.get()) {
                try {
                    val page = (reads.get() * 7919) % SqliteStress.PAGES
                    // A deferred read transaction, as the plugin reads (never BEGIN IMMEDIATE: that's the writer's lock).
                    db.exec("BEGIN")
                    try {
                        val head = db.query("SELECT gen, sum FROM head WHERE page = ?", page) { it.long(0)!! to it.long(1)!! }.firstOrNull()
                        if (head == null) reads.incrementAndGet() else {
                            val rows = db.query("SELECT gen, val FROM rows WHERE page = ? ORDER BY pos", page) { it.long(0)!! to it.text(1)!! }
                            if (rows.size != SqliteStress.ROWS || rows.any { it.first != head.first } || rows.sumOf { it.second.length.toLong() } != head.second) torn.incrementAndGet()
                            reads.incrementAndGet()
                        }
                    } finally {
                        db.exec("COMMIT")
                    }
                } catch (e: Exception) {
                    // busy past the timeout: a wait, not a wrong answer
                }
            }
            db.close()
        }
        reader.start()
        val r = SqliteStress({ JdbcSql(file) }, log = { lines.add(it) }).run(2)
        done.set(true)
        reader.join()
        assertEquals(0L, r.errors)
        assertEquals("ok", r.integrity)
        assertTrue("writes: ${r.writes}", r.writes > 20)
        assertTrue("reads: ${reads.get()}", reads.get() > 20)
        assertEquals("torn pages seen", 0L, torn.get())
        assertTrue(lines.single().startsWith("sqlite-stress writer: ${r.writes} writes, 0 errors"))
        dir.deleteRecursively()
    }

    @Test
    fun rowTextMatchesThePluginsLengths() {
        // The plugin checks lengths with SqliteStress.len (ko/sqlite_stress.lua): 40 + (gen*7 + pos*13) % 160.
        for ((gen, pos) in listOf(1L to 0, 17L to 99, 123456L to 42)) {
            assertEquals(40 + ((gen * 7 + pos * 13) % 160).toInt(), SqliteStress.value(gen, pos).length)
        }
    }
}

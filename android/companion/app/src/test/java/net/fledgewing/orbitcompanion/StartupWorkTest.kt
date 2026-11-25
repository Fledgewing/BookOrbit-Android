// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.Calendar

class StartupWorkTest {
    @Test fun sevenThousandCoverFilesAreCountedAndOrphansCleanedByWorker() {
        val root = Files.createTempDirectory("startup-cache").toFile()
        try {
            val covers = File(root, "covers").apply { mkdirs() }
            repeat(3500) { File(covers, "${it}_1.jpg").writeBytes(byteArrayOf(1)) }
            repeat(3499) { File(covers, "gone${it}.jpg.etag").writeText("etag") }
            File(covers, "0_1.jpg.etag").writeText("kept")
            assertEquals(7000, covers.list()!!.size)
            val worker = CacheWorker(root, { _, _, _, _ -> CacheWorker.Reply(0) }, log = {}, openSql = { JdbcSql(it) })
            val items = worker.storageItems(covers.path, false)
            assertEquals(3500, items.count { it.k.startsWith("c:") })
            assertEquals(3501, covers.list()!!.size)
            assertEquals("kept", File(covers, "0_1.jpg.etag").readText())
        } finally { root.deleteRecursively() }
    }

    @Test fun mailboxBoundsReplaysAcknowledgementsAndSurvivesRestart() {
        val root = Files.createTempDirectory("mailbox").toFile()
        try {
            val spool = File(root, "events").apply { mkdirs() }
            repeat(17) { File(spool, "100-0-c${it}.lua").writeBytes(LuaValue.encode(mapOf("kind" to "checked", "key" to "$it"))) }
            fun batch() = LuaValue.parse(File(root, "events-batch.lua").readBytes()) as Map<*, *>
            EventMailbox(root).publish(null)
            val first = batch()
            assertEquals(8, (first["events"] as List<*>).size)
            assertTrue(File(root, "events-batch.lua").length() < 65536)
            EventMailbox(root).publish("wrong")
            assertEquals(first, batch())
            EventMailbox(root).publish(first["id"] as String)
            assertEquals(9, spool.list()!!.size)
            val second = batch()
            assertNotEquals(first["id"], second["id"])
            EventMailbox(root).publish(second["id"] as String)
            assertEquals(1, (batch()["events"] as List<*>).size)
            EventMailbox(root).publish(batch()["id"] as String)
            assertEquals(0, spool.list()!!.size)
            assertFalse(File(root, "events-batch.lua").exists())
        } finally { root.deleteRecursively() }
    }

    @Test fun largeCopiesAnswerIsSplitWithoutBlockingLaterEvents() {
        val root = Files.createTempDirectory("large-mailbox").toFile()
        try {
            val spool = File(root, "events").apply { mkdirs() }
            val found = (0 until 200).map { mapOf("path" to "/books/" + "a".repeat(500) + it) }
            File(spool, "100-0-c1.lua").writeBytes(LuaValue.encode(mapOf("kind" to "copies", "found" to found)))
            EventMailbox(root).publish(null)
            var seen = 0
            while (File(root, "events-batch.lua").exists()) {
                assertTrue(File(root, "events-batch.lua").length() < 65536)
                val batch = LuaValue.parse(File(root, "events-batch.lua").readBytes()) as Map<*, *>
                for (event in batch["events"] as List<*>) seen += ((event as Map<*, *>)["found"] as List<*>).size
                EventMailbox(root).publish(batch["id"] as String)
            }
            assertEquals(200, seen)
        } finally { root.deleteRecursively() }
    }

    @Test fun calendarMergesLocalAndServerMinutesAndOmitsFutureDays() {
        val cal = Calendar.getInstance().apply { set(2026, Calendar.NOVEMBER, 24, 12, 0, 0); set(Calendar.MILLISECOND, 0) }
        val result = BoardYear.build(cal.timeInMillis / 1000,
            mapOf("startDate" to "2026-11-24", "minutes" to listOf(15L)), mapOf("2026-11-24" to 1200L))
        val values = result["values"] as List<*>
        assertEquals(20L, values.last())
        assertTrue(values.size in 358..364)
        assertTrue((result["today"] as Long) < cal.timeInMillis / 1000)
    }

    @Test fun hashSidecarCopiesFilesAndRefusesTraversalAndExternalLinks() {
        val root = Files.createTempDirectory("hash-sidecars").toFile()
        try {
            val old = "a".repeat(32); val new = "b".repeat(32)
            val from = File(root, "aa/$old.sdr").apply { mkdirs() }
            File(from, "metadata.epub.lua").writeText("state")
            HashSidecar.carry(root, old, new)
            assertEquals("state", File(root, "bb/$new.sdr/metadata.epub.lua").readText())
            assertTrue(File(from, "metadata.epub.lua").exists())
            HashSidecar.carry(root, "../bad", new)
            assertEquals(2, root.list()!!.size)
        } finally { root.deleteRecursively() }
    }
}

package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class LegacyLifecycleImportTest {
    private val id="entry_${"a".repeat(32)}_100_1"
    private val digest="a".repeat(32)
    private fun entry(root: File, generation: Long=1, payloadGeneration: Long=generation, ack: Map<String,Boolean> = emptyMap(), id: String=this.id, at: Long=100) {
        val dir=File(root,"bookorbit-lifecycle-outbox").also { it.mkdirs() }
        File(dir,"${id}_g$generation.lua").writeBytes("return ".toByteArray()+LuaValue.encode(mapOf("version" to 1L,"id" to id,"generation" to generation,
            "enqueued_at" to at,"payload_generation" to payloadGeneration,"digest" to digest,"acknowledged" to ack,"remote_pending" to mapOf("annotations" to mapOf("to_apply" to listOf("pending"))))))
        File(dir,"${id}_payload_g$payloadGeneration.lua").writeBytes("return ".toByteArray()+LuaValue.encode(mapOf("version" to 1L,"id" to id,"digest" to digest,
            "snapshot" to mapOf("digest" to digest,"percentage" to 0.5,"annotations" to listOf(mapOf("text" to "fixture")),"stats_ids" to listOf(7L),"status" to "reading"))))
    }
    private fun fixture(test: (File,LifecycleQueue)->Unit) {
        val root=Files.createTempDirectory("legacy-import").toFile()
        try { JdbcSql(File(root,"journal.db")).use { test(root,LifecycleQueue(it)) } } finally { root.deleteRecursively() }
    }
    @Test fun importsAllPhasesAndPendingPayloadWithProvenanceAndGenerationFallback() = fixture { root,q ->
        entry(root,ack=mapOf("match" to true,"stats" to false,"annotations" to false,"state" to true,"progress" to false))
        entry(root,2); File(root,"bookorbit-lifecycle-outbox/${id}_payload_g2.lua").writeText("corrupt")
        val import=LegacyLifecycleImport(q,root,{ "old-account" })
        assertEquals(1,import.run(true))
        val e=q.window("bookorbit","old-account").single()
        assertEquals(setOf("match","state"),e.acknowledged)
        val payload=LuaValue.parse(e.payload) as Map<*, *>
        assertEquals(listOf(7L),payload["stats_ids"])
        assertEquals("reading",payload["status"])
        assertNotNull((LuaValue.parse(e.checkpoint) as Map<*, *>)["remote_pending"])
        assertTrue(e.retired)
        assertEquals(0,q.pending("bookorbit","new-account"))
        assertEquals(0,import.run(true))
        assertEquals(1,q.pending("bookorbit","old-account"))
    }
    @Test fun crashesOnBothSidesOfCheckpointAndRetirementNeverLoseOrDuplicate() {
        for (boundary in listOf("before-checkpoint","after-checkpoint","retire-file","after-retire")) fixture { root,q ->
            entry(root)
            assertThrows(IllegalStateException::class.java) {
                LegacyLifecycleImport(q,root,{ "owner" }) { if (it==boundary) error("fixture crash") }.run(true)
            }
            assertEquals(if (boundary=="before-checkpoint") 0 else 1,q.pending("bookorbit","owner"))
            LegacyLifecycleImport(q,root,{ "owner" }).run(true)
            val job=q.window("bookorbit","owner").single()
            assertTrue(job.retired)
            assertEquals(emptySet<String>(),job.acknowledged)
            assertEquals(0,LegacyLifecycleImport(q,root,{ "owner" }).run(true))
            assertEquals(1,q.pending("bookorbit","owner"))
        }
    }
    @Test fun importPreservesLegacyFifoRatherThanDirectoryEnumerationOrder() = fixture { root,q ->
        val second="entry_${digest}_200_2"; val first="entry_${digest}_100_3"
        entry(root,id=id,at=300); entry(root,id=first,at=100); entry(root,id=second,at=200)
        LegacyLifecycleImport(q,root,{"owner"}).run(true)
        assertEquals(listOf(first,second,id),q.window("bookorbit","owner").map { it.source })
    }
    @Test fun acknowledgedExchangeStillImportsItsPendingRemoteApplication() = fixture { root,q ->
        entry(root,ack=LifecycleQueue.PHASES.associateWith { true })
        LegacyLifecycleImport(q,root,{ "owner" }).run(true)
        val job=q.window("bookorbit","owner").single()
        assertFalse("pending remote work must not be skipped",job.acknowledged.contains("annotations"))
        assertEquals(LifecycleQueue.PHASES.toSet()-"annotations",job.acknowledged)
        assertNotNull((LuaValue.parse(job.checkpoint) as Map<*, *>)["remote_pending"])
    }
    @Test fun corruptAndUnknownOwnerEntriesStayInSourceAndLiveWriterIsRejected() = fixture { root,q ->
        entry(root)
        val source=File(root,"bookorbit-lifecycle-outbox/${id}_g1.lua")
        assertThrows(IllegalStateException::class.java) { LegacyLifecycleImport(q,root,{ "owner" }).run(false) }
        assertEquals(0,LegacyLifecycleImport(q,root,{ null }).run(true)); assertTrue(source.isFile)
        source.writeText("return os.execute('never run')")
        assertEquals(0,LegacyLifecycleImport(q,root,{ "owner" }).run(true)); assertTrue(source.isFile)
        assertEquals(0,q.pending("bookorbit","owner"))
    }
}

package net.fledgewing.orbitcompanion

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

/** End-to-end journal/policy/consent tests deliberately use an unrelated opaque-key adapter. */
class SyncOwnerTest {
    private class Toy : ServerAdapter {
        override val id="toy"
        var account="account/one"
        var offline=false
        var remote: Map<String,Any?> = emptyMap()
        val writes=mutableListOf<Map<String,Any?>>()
        val phases=mutableListOf<String>()
        val leases=mutableListOf<String?>()
        override fun positionOwner()=account
        override fun position(document: String, update: Map<String,Any?>?): Map<String,Any?> {
            if(offline) throw ServerFailure("offline")
            if(update!=null) { writes+=update; remote=mapOf("percentage" to update["percentage"],"position" to update["position"],"timestamp" to update["capturedAt"]) }
            return remote
        }
        override fun captureLifecycle(capture: Map<*, *>): Pair<String,ByteArray> = "urn:toy:book" to LuaValue.encode(mapOf(
            "percentage" to capture["percentage"],"position" to capture["position"],"capturedAt" to capture["captured_at"],"finished" to capture["finished"]))
        override fun lifecyclePhase(entry: LifecycleQueue.Entry,phase: String,checkpoint: ByteArray,openPath: String?): SyncPhaseResult {
            phases+=phase; leases+=openPath; return SyncPhaseResult(checkpoint)
        }
    }
    private fun args(fraction: Double=.4,at: Long=1000,moment: String="open",online: Boolean=true) = mapOf<String,Any?>(
        "path" to "/fixture/book.epub","percentage" to fraction,"position" to "locator:$fraction","page" to fraction*300,
        "captured_at" to at,"turn_at" to at,"moment" to moment,"online" to online)
    private fun fixture(test: (File,LifecycleQueue,SyncOwner,Toy)->Unit) {
        val root=Files.createTempDirectory("sync-owner").toFile()
        try { JdbcSql(File(root,"journal.db")).use { sql ->
            val q=LifecycleQueue(sql); val a=Toy(); val owner=SyncOwner(q,root,{}, { 1000L })
            owner.activate(a,true); test(root,q,owner,a)
        } } finally { root.deleteRecursively() }
    }
    @Test fun quiescenceIsRequiredAndOfflineSnapshotsSurviveCompanionRestart() = fixture { root,q,owner,a ->
        assertThrows(IllegalStateException::class.java) { SyncOwner(q,root,{}).activate(a,false) }
        a.offline=true
        assertEquals(true,owner.command(a,"sync.capture",args(online=false))["queued"])
        assertEquals(1,q.pending(a.id,a.account)); assertTrue(a.writes.isEmpty())
        val restarted=SyncOwner(q,root,{},{ 2000L }); restarted.activate(a,true)
        assertEquals("offline",restarted.command(a,"sync.drain",emptyMap<Any,Any>())["error"])
        assertEquals(1,q.pending(a.id,a.account))
        a.offline=false
        assertEquals(0,restarted.command(a,"sync.drain",emptyMap<Any,Any>())["remaining"])
        assertEquals(listOf("match","stats","annotations","state"),a.phases)
        assertEquals(1000L,a.writes.single()["capturedAt"])
    }
    @Test fun sidecarLeaseSurvivesCloseCaptureAndCompanionRestartUntilNativeClosure() = fixture { root,q,owner,a ->
        owner.command(a,"sync.capture",args(moment="close",online=false))
        owner.command(a,"sync.drain",emptyMap<Any,Any>())
        assertTrue(a.leases.all { it=="/fixture/book.epub" })
        a.leases.clear()
        val restarted=SyncOwner(q,root,{}, {2000L})
        restarted.command(a,"sync.activate",mapOf("quiesced" to true,"epoch" to "same-reader","path" to "/fixture/book.epub"))
        restarted.command(a,"sync.capture",args(online=false))
        restarted.command(a,"sync.drain",emptyMap<Any,Any>())
        assertTrue(a.leases.isNotEmpty()); assertTrue(a.leases.all { it=="/fixture/book.epub" })
        a.leases.clear()
        restarted.command(a,"sync.capture",args(online=false))
        restarted.command(a,"sync.drain",mapOf("closed_path" to "/fixture/book.epub","online" to false))
        assertTrue("offline closure only releases the lease",a.leases.isEmpty())
        restarted.command(a,"sync.drain",emptyMap<Any,Any>())
        assertTrue(a.leases.isNotEmpty()); assertTrue(a.leases.all { it==null })
    }
    @Test fun declineAndMarkerStatePersistAndStaleConsentCannotMoveAnotherPlace() = fixture { root,q,owner,a ->
        a.remote=mapOf("percentage" to .8,"position" to "remote:240","timestamp" to 900L)
        val pulled=owner.command(a,"sync.capture",args())
        val snapshot=pulled["snapshot"] as Map<*, *>
        val mapped=mapOf("document" to "urn:toy:book","token" to snapshot["token"],"page" to 120,"remote_page" to 240,"moment" to "open")
        val decision=owner.command(a,"sync.decide",mapped)
        assertEquals("take",decision["decision"]); assertEquals("ask",decision["applied"]); assertTrue(a.writes.isEmpty())
        owner.command(a,"sync.answer",mapped+mapOf("yes" to false))
        val restarted=SyncOwner(q,root,{}); restarted.activate(a,true)
        assertEquals("stay",restarted.command(a,"sync.decide",mapped)["decision"])
        a.remote=a.remote+("timestamp" to 1100L)
        restarted.command(a,"sync.pull",args())
        assertEquals(true,restarted.command(a,"sync.answer",mapped+mapOf("yes" to true))["stale"])
        assertEquals(900L,q.record(a.id,a.account,"urn:toy:book")["declinedAt"])
    }
    @Test fun overrideGoesBeforeOlderSnapshotsAndIsConsumedOnce() = fixture { _,q,owner,a ->
        a.remote=mapOf("percentage" to .8,"position" to "remote:240","timestamp" to 900L)
        owner.command(a,"sync.capture",args(.5,500,online=false))
        owner.command(a,"sync.override",args(.1,1000,online=false))
        owner.command(a,"sync.drain",emptyMap<Any,Any>())
        assertEquals(1,a.writes.size)
        assertEquals(.1,a.writes.single()["percentage"])
        assertEquals("locator:0.1",a.writes.single()["position"])
        assertNull(q.record(a.id,a.account,"urn:toy:book")["override"])
        owner.command(a,"sync.capture",args(.05,1200,online=false))
        owner.command(a,"sync.drain",emptyMap<Any,Any>())
        assertEquals(1,a.writes.size)
    }
    @Test fun newerRemoteMovementDropsAnOfflineOverrideInsteadOfReplayingIt() = fixture { _,q,owner,a ->
        a.remote=mapOf("percentage" to .8,"position" to "remote:240","timestamp" to 900L)
        owner.command(a,"sync.pull",args())
        owner.command(a,"sync.override",args(.1,1000,online=false))
        a.remote=a.remote+("timestamp" to 1200L)
        owner.command(a,"sync.drain",emptyMap<Any,Any>())
        assertTrue(a.writes.isEmpty()); assertNull(q.record(a.id,a.account,"urn:toy:book")["override"])
    }
    @Test fun ownerSwitchNeverSendsAnotherAccountsQueueAndPreviewHasNoTransport() = fixture { _,q,owner,a ->
        owner.command(a,"sync.capture",args(online=false))
        a.account="account/two"
        assertEquals(0,owner.command(a,"sync.drain",emptyMap<Any,Any>())["remaining"])
        assertEquals(1,q.pending(a.id,"account/one")); assertTrue(a.writes.isEmpty())
        a.offline=true
        assertEquals(true,owner.preview(a.id,a.account,args())["pending"])
        assertTrue(a.writes.isEmpty())
    }
}

// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class CatalogTransfersTest {
    private fun fixture(test:(CatalogTransfers,java.io.File)->Unit) {
        val root=Files.createTempDirectory("transfer-control").toFile()
        try { test(CatalogTransfers(root),root) } finally { root.deleteRecursively() }
    }
    private fun start(q:CatalogTransfers,owner:String="account",key:String="opaque-book")=q.start(owner,mapOf("key" to key,"file_reference" to 7L,"destination" to "/fixture/book.epub"))["id"] as String
    @Test fun activeJobsDeduplicateByOwnerBookAndExactFile()=fixture { q,_ ->
        val id=start(q);assertEquals(id,start(q))
        assertNotEquals(id,start(q,"other"))
        assertNotEquals(id,q.start("account",mapOf("key" to "opaque-book","file_reference" to 8L))["id"])
        assertNotEquals(id,q.start("account",mapOf("key" to "opaque-book","file_reference" to 7L,"variant" to "other-choice"))["id"])
    }
    @Test fun restartPausesWithoutAutoRunningOrChangingTheDestination()=fixture { q,root ->
        val id=start(q);var ran=false
        val restarted=CatalogTransfers(root)
        assertEquals("paused",restarted.read("account",id)["state"])
        restarted.run("account",id) { ran=true;emptyMap() };assertFalse(ran)
        restarted.resume("account",id)
        restarted.run("account",id) { args -> assertEquals("/fixture/book.epub",args["destination"]);mapOf("local_path" to args["destination"]) }
        assertEquals("complete",restarted.read("account",id)["state"])
    }
    @Test fun cancelDoesNotWaitForBlockedTransportAndLateProgressCannotResurrectIt()=fixture { q,_ ->
        val id=start(q)
        val entered=java.util.concurrent.CountDownLatch(1);val proceed=java.util.concurrent.CountDownLatch(1)
        val thread=Thread { q.run("account",id) {
            entered.countDown();check(proceed.await(5,java.util.concurrent.TimeUnit.SECONDS))
            assertTrue(q.canceled("account",id));throw ServerFailure("canceled")
        } }.apply { start() }
        try {
            assertTrue(entered.await(5,java.util.concurrent.TimeUnit.SECONDS))
            assertEquals("canceling",q.cancel("account",id)["state"])
            q.progress("account",id,1000,null)
            assertEquals(0L,q.read("account",id)["received"])
        } finally { proceed.countDown();thread.join(5000) }
        assertFalse(thread.isAlive);assertEquals("canceled",q.read("account",id)["state"])
    }
    @Test fun committedFileWinsFinalCancelRaceWithoutDeletingTheArtifact()=fixture { q,root ->
        val id=start(q);val saved=java.io.File(root,"saved.epub")
        q.run("account",id) { saved.writeText("complete");q.cancel("account",id);mapOf("local_path" to saved.path) }
        assertTrue(saved.isFile);assertEquals("complete",q.read("account",id)["state"])
    }
    @Test fun progressHasNoInventedPercentageAndReplyStaysBounded()=fixture { q,_ ->
        val id=start(q)
        q.run("account",id) {
            q.progress("account",id,4096,null)
            val progress=q.read("account",id)
            assertEquals(null,progress["total"]);assertEquals("4 KB received",progress["progress_text"])
            assertFalse(progress.containsKey("percentage"));assertTrue(LuaValue.encode(progress).size<16384)
            mapOf("local_path" to "/fixture/book.epub")
        }
    }
    @Test fun accountSwitchCannotReadCancelOrResumeAnotherOwnersJob()=fixture { q,_ ->
        val id=start(q)
        for(action in listOf<()->Unit>({q.read("other",id)},{q.cancel("other",id)},{q.resume("other",id)})) {
            try { action();fail("wrong owner") } catch(e:ServerFailure) { assertEquals("missing",e.kind) }
        }
    }
    @Test fun errorsRetainTheOriginalJobForExplicitResumeAndHistoryIsBounded()=fixture { q,_ ->
        val id=start(q);q.run("account",id) { throw ServerFailure("space") }
        assertEquals("space",q.read("account",id)["error"])
        val failed=q.read("account",id)["sequence"] as Long
        val resumed=q.resume("account",id)
        assertEquals("queued",resumed["state"]);assertTrue((resumed["sequence"] as Long)>failed)
        q.cancel("account",id)
        repeat(40) { val next=start(q,key="book-$it");q.cancel("account",next) }
        try { q.read("account",id);fail("old terminal history retained") } catch(e:ServerFailure) { assertEquals("missing",e.kind) }
    }
}

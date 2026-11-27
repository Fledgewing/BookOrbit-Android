// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit
import net.fledgewing.orbitcompanion.*
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
class SeriesTransfersTest {
    private fun fixture(test:(CatalogTransfers,SeriesTransfers,java.io.File)->Unit) {
        val root=Files.createTempDirectory("series-jobs").toFile()
        try { val jobs=CatalogTransfers(root);test(jobs,SeriesTransfers(root,jobs),root) } finally { root.deleteRecursively() }
    }
    private fun choices(n:Int=3)=(1..n).map { mapOf<String,Any?>("key" to "b$it","title" to "Book $it","file_reference" to it.toLong(),"destination" to "/fixture/$it.epub") }
    @Test fun actorStepsAreSequentialAndSummarySurvivesHistoryEviction()=fixture { jobs,q,_ ->
        val id=q.start("a","series",choices())["id"] as String
        val seen=mutableListOf<String>();val perform={ row:Map<String,Any?> -> seen.add(row["key"] as String);mapOf<String,Any?>("local_path" to row["destination"]) }
        assertTrue(q.step("a",id,perform));assertEquals(listOf("b1"),seen)
        q.run("a",id,perform);assertEquals(listOf("b1","b2","b3"),seen)
        repeat(35) { val j=jobs.start("a",mapOf("key" to "history$it"))["id"] as String;jobs.cancel("a",j) }
        val done=q.read("a",id);assertEquals(3,done["saved"]);assertEquals("complete",done["state"])
        assertTrue(LuaValue.encode(done).size<16384)
    }
    @Test fun cancelOneKeepsLaterBooksAndCancelRemainingKeepsSavedFiles()=fixture { jobs,q,_ ->
        val id=q.start("a","series",choices())["id"] as String
        val first=((q.read("a",id)["items"] as List<*>)[0] as Map<*,*>)["id"] as String
        jobs.cancel("a",first);q.step("a",id) { mapOf("local_path" to it["destination"]) }
        val result=q.cancel("a",id);assertEquals(1,result["saved"]);assertEquals(2,result["skipped"])
        q.resume("a",id);var ran=false;q.run("a",id) { ran=true;emptyMap() };assertFalse(ran)
    }
    @Test fun offlinePausesRestAndRestartRequiresExplicitResume()=fixture { _,q,root ->
        val id=q.start("a","series",choices())["id"] as String
        var calls=0;q.run("a",id) { calls++;throw ServerFailure("offline") };assertEquals(1,calls)
        assertEquals("paused",q.read("a",id)["state"])
        val restarted=SeriesTransfers(root,CatalogTransfers(root));restarted.run("a",id) { fail("auto resume");emptyMap() }
        restarted.resume("a",id);restarted.run("a",id) { mapOf("local_path" to it["destination"]) }
        assertEquals(3,restarted.read("a",id)["saved"])
    }
    @Test fun fileErrorsContinueAndActiveJobsAreNotDuplicated()=fixture { jobs,q,_ ->
        jobs.start("a",choices()[0]);val id=q.start("a","series",choices())["id"] as String
        q.run("a",id) { if(it["key"]=="b2") throw ServerFailure("space");mapOf("local_path" to it["destination"]) }
        val result=q.read("a",id);assertEquals(1,result["saved"]);assertEquals(1,result["skipped"]);assertEquals(1,result["failed"])
        assertEquals(id,q.start("a","series",choices())["id"])
        try { q.cancel("other",id);fail("owner") } catch(e:ServerFailure) { assertEquals("missing",e.kind) }
    }
    @Test fun interruptedQueueCreationReattachesAnAlreadyCreatedJobOnExplicitResume()=fixture { jobs,_,root ->
        val choice=choices(1).single()
        val orphan=jobs.start("a",choice)["id"] as String
        java.io.File(root,"series-transfer-queues.lua").writeBytes(LuaValue.encode(mapOf("batch" to mapOf("id" to "batch","owner" to "a","series" to "s","rows" to listOf(choice+mapOf("state" to "paused","id" to null))))))
        val control=CatalogTransfers(root);val recovered=SeriesTransfers(root,control)
        assertEquals("paused",recovered.read("a","batch")["state"])
        recovered.resume("a","batch")
        val row=(recovered.read("a","batch")["items"] as List<*>).single() as Map<*,*>
        assertEquals(orphan,row["id"])
        var calls=0;recovered.run("a","batch") { calls++;mapOf("local_path" to it["destination"]) }
        assertEquals(1,calls);assertEquals(1,recovered.read("a","batch")["saved"])
    }

    @Test fun unsupportedFilesAreCountedAsFailuresWithoutPreventingLaterBooks()=fixture { _,q,_ ->
        val choices=choices().mapIndexed { i,row -> if(i==0) row+mapOf("failure" to "unsupported") else row }
        val id=q.start("a","s",choices)["id"] as String
        q.run("a",id) { mapOf("local_path" to it["destination"]) }
        val done=q.read("a",id);assertEquals(2,done["saved"]);assertEquals(1,done["failed"]);assertEquals("complete",done["state"])
        assertEquals(1,q.cancel("a",id)["failed"])
    }

}

package net.fledgewing.orbitcompanion

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class ProgressOutboxTest {
    private class Toy : ServerAdapter {
        override val id = "toy"
        var account: String? = "sync:one"
        var offline = false
        val delivered = mutableListOf<Pair<String,Map<String,Any?>>>()
        override fun owner() = "catalog:other"
        override fun positionOwner() = account
        override fun position(document: String, update: Map<String,Any?>?): Map<String,Any?> {
            if (offline) throw ServerFailure("unavailable")
            delivered += document to requireNotNull(update)
            return mapOf("ok" to true)
        }
    }
    private fun write(position: String = "opaque:chapter/one") = mapOf<String,Any?>("percentage" to 0.5,"position" to position)
    private fun database(test: (File) -> Unit) {
        val dir = Files.createTempDirectory("position-outbox").toFile()
        try { test(File(dir,"queue.db")) } finally { dir.deleteRecursively() }
    }
    @Test fun offlineWritesSurviveRestartAndReplayWithOriginalTimeAndLocator() = database { file ->
        val toy = Toy().also { it.offline = true }
        val locator = LuaValue.str("opaque:位置/one")
        val id = JdbcSql(file).use { sql ->
            val queue = ProgressOutbox(sql, {}) { 100L }
            val id = queue.enqueue(toy.id,toy.positionOwner()!!,"urn:book:one",write(locator))
            assertEquals(ProgressOutbox.Drain(0,1,"unavailable"),queue.drain(toy))
            assertTrue(queue.contains(id))
            id
        }
        JdbcSql(file).use { sql ->
            val queue = ProgressOutbox(sql, {}) { 900L }
            assertTrue(queue.contains(id))
            toy.offline = false
            assertEquals(ProgressOutbox.Drain(1,0,null),queue.drain(toy))
            assertEquals("urn:book:one",toy.delivered.single().first)
            assertEquals(locator,toy.delivered.single().second["position"])
            assertEquals(100L,toy.delivered.single().second["capturedAt"])
            assertFalse(queue.contains(id))
            assertEquals(0,queue.drain(toy).sent)
        }
    }
    @Test fun accountsAdaptersAndCatalogOwnershipCannotCrossDeliver() = database { file ->
        JdbcSql(file).use { sql ->
            val queue = ProgressOutbox(sql, {}) { 100L }
            val toy = Toy()
            queue.enqueue("other","sync:one","book:other-adapter",write())
            queue.enqueue("toy","sync:two","book:other-account",write())
            queue.enqueue("toy","catalog:other","book:catalog-account",write())
            queue.enqueue("toy","sync:one","book:current",write())
            assertEquals(ProgressOutbox.Drain(1,0,null),queue.drain(toy))
            assertEquals("book:current",toy.delivered.single().first)
            assertEquals(3,queue.count())
            toy.account = null
            assertEquals("unauthorized",queue.drain(toy).error)
            assertEquals(3,queue.count())
            toy.account = "sync:two"
            assertEquals(1,queue.drain(toy).sent)
            assertEquals("book:other-account",toy.delivered.last().first)
        }
    }
    @Test fun fifoStopsAtFailureAndDrainReadsOnlyOneBoundedWindow() = database { file ->
        JdbcSql(file).use { sql ->
            val queue = ProgressOutbox(sql, {}) { 100L }
            val toy = Toy().also { it.offline = true }
            repeat(ProgressOutbox.MAX_BATCH+1) { queue.enqueue("toy","sync:one","book:$it",write()) }
            assertEquals(ProgressOutbox.Drain(0,25,"unavailable"),queue.drain(toy))
            toy.offline = false
            assertEquals(ProgressOutbox.Drain(24,1,null),queue.drain(toy))
            assertEquals((0..23).map { "book:$it" },toy.delivered.map { it.first })
            assertEquals(ProgressOutbox.Drain(1,0,null),queue.drain(toy))
        }
    }
    @Test fun unsuccessfulRepliesAreNeverAcknowledged() = database { file ->
        JdbcSql(file).use { sql ->
            val queue = ProgressOutbox(sql, {}) { 100L }
            val adapter = object : ServerAdapter { override val id = "unsupported"; override fun owner() = "account" }
            queue.enqueue(adapter.id,adapter.owner(),"book",write())
            assertEquals(ProgressOutbox.Drain(0,1,"unsupported"),queue.drain(adapter))
            assertEquals(1,queue.count())
        }
    }
    @Test fun validationAndCapacityFailureLeaveEarlierWritesIntact() = database { file ->
        JdbcSql(file).use { sql ->
            val queue = ProgressOutbox(sql, {}) { 100L }
            for (bad in listOf(write("x".repeat(4097)),write("位置"),mapOf("percentage" to Double.NaN),mapOf("percentage" to -1),mapOf("percentage" to 2))) {
                assertThrows(IllegalArgumentException::class.java) { queue.enqueue("toy","sync:one","book",bad) }
            }
            assertEquals(0,queue.count())
            repeat(ProgressOutbox.MAX_PENDING) { queue.enqueue("toy","sync:one","book:$it",write()) }
            assertThrows(IllegalStateException::class.java) { queue.enqueue("toy","sync:one","new",write()) }
            assertEquals(ProgressOutbox.MAX_PENDING,queue.count())
        }
    }
    @Test fun queuePersistsOnlyReviewedFields() = database { file ->
        JdbcSql(file).use { sql ->
            val queue = ProgressOutbox(sql, {}) { 100L }
            queue.enqueue("toy","sync:one","book",write()+mapOf("password" to "fixture-secret","unrelated" to listOf(1,2)))
            val body = LuaValue.parse(sql.query("SELECT body FROM position_outbox") { it.bytes(0)!! }.single()) as Map<*, *>
            assertEquals(setOf("percentage","position","capturedAt"),body.keys)
        }
    }
    @Test fun failedAcknowledgmentReplaysTheSameIntentAfterRestart() = database { file ->
        val toy = Toy()
        JdbcSql(file).use { database ->
            val failing = object : Sql by database {
                override fun exec(sql: String, vararg args: Any?) {
                    if (sql.startsWith("DELETE FROM position_outbox")) throw IllegalStateException("fixture disk error")
                    database.exec(sql,*args)
                }
            }
            val queue = ProgressOutbox(failing, {}) { 100L }
            queue.enqueue("toy","sync:one","book",write())
            assertEquals(ProgressOutbox.Drain(0,1,"unavailable"),queue.drain(toy))
            assertEquals(1,toy.delivered.size)
        }
        JdbcSql(file).use { sql ->
            val queue = ProgressOutbox(sql, {}) { 900L }
            assertEquals(ProgressOutbox.Drain(1,0,null),queue.drain(toy))
            assertEquals(2,toy.delivered.size)
            assertEquals(toy.delivered[0],toy.delivered[1])
        }
    }
}

package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class CacheSqlTest {
    @Test fun failedNestedScopeRollsBackOuterEvenWhenCaughtAndNextWriteSucceeds() {
        val root = Files.createTempDirectory("cache-sql-rollback").toFile()
        try {
            CacheStore(root, {}, ::JdbcSql).use { store ->
                try {
                    store.transaction {
                        store.setMeta("outer", "uncommitted")
                        try {
                            store.transaction { store.setMeta("inner", "uncommitted"); error("failed write") }
                        } catch (_: IllegalStateException) { }
                    }
                    fail("outer must roll back")
                } catch (_: IllegalStateException) { }
                assertNull(store.meta("outer"))
                assertNull(store.meta("inner"))
                store.transaction { store.setMeta("next", "committed") }
                assertEquals("committed", store.meta("next"))
            }
        } finally { root.deleteRecursively() }
    }

    @Test fun separateHandlesOfTheSameDatabaseShareOneWriterOwnership() {
        val root=Files.createTempDirectory("cache-sql-handles").toFile()
        val pool=Executors.newFixedThreadPool(2)
        val entered=CountDownLatch(1);val attempted=CountDownLatch(1);val completed=CountDownLatch(1);val release=CountDownLatch(1)
        try {
            CacheStore(root,{}, { JdbcSql(it,busyMs=0) }).use { first ->
                CacheStore(root,{}, { JdbcSql(it,busyMs=0) }).use { second ->
                    first.db();second.db()
                    val outer=pool.submit { first.transaction { first.setMeta("outer","committed");entered.countDown();assertTrue(release.await(5,TimeUnit.SECONDS)) } }
                    assertTrue(entered.await(5,TimeUnit.SECONDS))
                    val patch=pool.submit { attempted.countDown();try { second.transaction { second.setMeta("other","committed") } } finally { completed.countDown() } }
                    assertTrue(attempted.await(5,TimeUnit.SECONDS))
                    try { assertFalse("another handle entered SQLite during the active write",completed.await(150,TimeUnit.MILLISECONDS)) }
                    finally { release.countDown() }
                    outer.get(5,TimeUnit.SECONDS);patch.get(5,TimeUnit.SECONDS)
                    assertEquals("committed",first.meta("other"));assertEquals("committed",second.meta("outer"))
                }
            }
        } finally { release.countDown();pool.shutdownNow();root.deleteRecursively() }
    }

    @Test fun anotherThreadCannotJoinOrWriteThroughAnOpenTransaction() {
        val root = Files.createTempDirectory("cache-sql-threads").toFile()
        val pool = Executors.newSingleThreadExecutor()
        try {
            CacheStore(root, {}, ::JdbcSql).use { store ->
                store.db()
                val entered = CountDownLatch(1)
                val attempted = CountDownLatch(1)
                val release = CountDownLatch(1)
                val outer = pool.submit {
                    store.transaction {
                        store.setMeta("outer", "committed")
                        entered.countDown()
                        assertTrue(release.await(5, TimeUnit.SECONDS))
                    }
                }
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                val writer = Executors.newSingleThreadExecutor()
                try {
                    val patch = writer.submit {
                        attempted.countDown()
                        store.transaction { store.setMeta("other", "committed") }
                    }
                    assertTrue(attempted.await(5, TimeUnit.SECONDS))
                    assertFalse(patch.isDone)
                    release.countDown()
                    outer.get(5, TimeUnit.SECONDS)
                    patch.get(5, TimeUnit.SECONDS)
                    assertEquals("committed", store.meta("outer"))
                    assertEquals("committed", store.meta("other"))
                } finally { release.countDown(); writer.shutdownNow() }
            }
        } finally { pool.shutdownNow(); root.deleteRecursively() }
    }
}

package net.fledgewing.orbitcompanion

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

/** These adapters deliberately have different identity shapes and capability sets. Neither
 * imports the shipping implementation or uses its fixtures, JSON vocabulary or numeric IDs. */
class ServerAdapterTest {
    private class FakeAdapter : ServerAdapter {
        override val id = "fake"
        val requests = mutableListOf<Map<*, *>>()
        override fun project(owner: String, request: Map<*, *>): Map<String, Any?> {
            requests += request
            return when (request["op"]) {
                "capabilities" -> mapOf("catalog" to true, "detail" to true, "download" to false)
                "window", "book" -> mapOf("items" to listOf(mapOf("key" to "$owner/urn:one", "title" to "Fixture", "status" to "unknown")))
                "lists" -> mapOf("items" to emptyList<Any>())
                "progress" -> mapOf("progress" to 20)
                "status" -> mapOf("status" to "unknown")
                else -> unsupported()
            }
        }
    }
    private class AcquisitionOnlyAdapter : ServerAdapter {
        override val id = "acquisition"
        override fun project(owner: String, request: Map<*, *>): Map<String, Any?> = when (request["op"]) {
            "capabilities" -> mapOf("catalog" to true, "download" to true, "lists" to mapOf("read" to false))
            "window" -> mapOf("items" to listOf(mapOf("key" to "urn:uuid:alternate", "title" to "Feed item")))
            else -> unsupported()
        }
        override fun download(owner: String, key: String, file: String, revision: String?) = mapOf<String, Any?>("job" to "transfer:opaque")
    }
    private class Store(root: File) : ProjectionStore {
        private val sql = JdbcSql(File(root, "projection.sqlite3"))
        init { sql.exec("CREATE TABLE meta (k TEXT PRIMARY KEY,v TEXT)"); LibraryReadModel.initialize(sql); sql.exec("INSERT INTO meta VALUES ('owner','fixture')") }
        override fun db() = sql
        override fun meta(k: String) = sql.query("SELECT v FROM meta WHERE k=?", k) { it.text(0) }.firstOrNull()
        override fun <T> transaction(block: () -> T): T = sql.transaction(block)
        override fun close() = sql.close()
    }
    @Test fun registryAndPublisherDoNotAssumeBackendOrIdentityShape() {
        val registry = AdapterRegistry(listOf(
            "fake" to { _, _ -> FakeAdapter() }, "acquisition" to { _, _ -> AcquisitionOnlyAdapter() },
        ))
        val root = Files.createTempDirectory("adapter-contract").toFile()
        try {
            Store(root).use { store ->
                for (id in listOf("fake", "acquisition")) {
                    val adapter = registry.create(id, store)
                    val model = LibraryReadModel(store, log = {}, adapter = adapter)
                    val request = String(LuaValue.encode(mapOf("op" to "window", "source" to "all", "limit" to 1)), Charsets.ISO_8859_1)
                    assertTrue(model.publish("fixture", listOf(request)))
                    val bytes = store.db().query("SELECT body FROM library_views WHERE request=?", LuaValue.utf8(request)) { it.bytes(0)!! }.single()
                    val result = LuaValue.parse(bytes) as Map<*, *>
                    val row = (result["items"] as List<*>).single() as Map<*, *>
                    assertTrue(row["key"].toString().contains(if (id == "fake") "urn:one" else "urn:uuid:"))
                    assertTrue(bytes.size <= LibraryReadModel.MAX_BYTES)
                    assertFalse(model.publish("another-account", listOf(request)))
                }
                assertThrows(IllegalArgumentException::class.java) { registry.create("missing", store) }
                assertThrows(IllegalArgumentException::class.java) {
                    AdapterRegistry(listOf("wrong" to { _, _ -> FakeAdapter() })).create("wrong", store)
                }
                assertEquals(false, (registry.create("acquisition", store).capabilities("fixture")["lists"] as Map<*, *>)["read"])
                assertEquals("unsupported", registry.create("acquisition", store).detail("fixture", "opaque")["error"])
                assertEquals("transfer:opaque", registry.create("acquisition", store).download("fixture", "opaque", "epub", null)["job"])
            }
        } finally { root.deleteRecursively() }
    }
    @Test fun optionalOperationsAreExplicitAndSecretsAreCleared() {
        val fake = FakeAdapter()
        assertEquals("unsupported", fake.manifest("fixture")["error"])
        assertEquals("unsupported", fake.cover("fixture", "opaque")["error"])
        assertEquals("unsupported", fake.setProgress("fixture", "opaque", emptyMap())["error"])
        assertEquals("unsupported", fake.setStatus("fixture", "opaque", "finished")["error"])
        assertEquals("unsupported", fake.saveList("fixture", null, emptyMap())["error"])
        assertEquals("unsupported", fake.readingStats("fixture")["error"])
        assertEquals("unsupported", fake.setupCredentials(emptyMap())["error"])
        assertEquals("unsupported", fake.signOut()["error"])
        val secret = "fixture".toCharArray()
        assertEquals("unsupported", fake.signIn("https://library.invalid", "reader", secret)["error"])
        assertTrue(secret.all { it == '\u0000' })
        secret.fill('x')
        assertEquals("unsupported", fake.connectorCredentials("reader", "reader", secret)["error"])
        assertTrue(secret.all { it == '\u0000' })
        val factory: AdapterFactory = { _, _ -> fake }
        assertThrows(IllegalArgumentException::class.java) { AdapterRegistry(listOf("fake" to factory, "fake" to factory)) }
    }
    @Test fun oneBatchSharesOneLocalStatisticsAggregate() {
        val root = Files.createTempDirectory("adapter-stats").toFile()
        try { Store(root).use { store ->
            val fake = FakeAdapter()
            var reads = 0
            val model = LibraryReadModel(store, log = {}, adapter = fake,
                readingStats = { reads++; mapOf("state" to "ready") })
            val requests = listOf(512, 1024).map { budget -> String(LuaValue.encode(
                mapOf("op" to "reading.stats", "bytes" to budget)), Charsets.ISO_8859_1) }
            assertTrue(model.publish("fixture", requests))
            assertEquals(1, reads)
            assertTrue(fake.requests.isEmpty())
            assertEquals(2, store.db().query("SELECT body FROM library_views") { it.bytes(0) }.size)
        } } finally { root.deleteRecursively() }
    }
    @Test fun publisherEnforcesCallerBudgetAgainstAnOversizedAdapter() {
        val root = Files.createTempDirectory("adapter-budget").toFile()
        try { Store(root).use { store ->
            var payload: List<Map<String, String>> = emptyList()
            val adapter = object : ServerAdapter {
                override val id = "oversize"
                override fun project(owner: String, request: Map<*, *>) = mapOf<String, Any?>("items" to payload)
            }
            val request = String(LuaValue.encode(mapOf("op" to "window", "limit" to 1, "bytes" to 512)), Charsets.ISO_8859_1)
            // Separate failures: too many bytes in one row; too many rows within the byte cap.
            for (items in listOf(listOf(mapOf("key" to "one", "title" to "x".repeat(1000))),
                    listOf(mapOf("key" to "one"), mapOf("key" to "two")))) {
                payload = items
                LibraryReadModel(store, log = {}, adapter = adapter).publish("fixture", listOf(request))
                val bytes = store.db().query("SELECT body FROM library_views") { it.bytes(0)!! }.single()
                assertEquals("budget", (LuaValue.parse(bytes) as Map<*, *>)["error"])
                assertTrue(bytes.size <= 512)
            }
        } } finally { root.deleteRecursively() }
    }
}

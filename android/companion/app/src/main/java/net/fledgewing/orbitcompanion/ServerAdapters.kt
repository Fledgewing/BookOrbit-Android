package net.fledgewing.orbitcompanion

import net.fledgewing.orbitcompanion.server.bookorbit.AdapterWorker
import net.fledgewing.orbitcompanion.server.bookorbit.BookOrbitCovers
import net.fledgewing.orbitcompanion.server.bookorbit.BookOrbitProjection
import net.fledgewing.orbitcompanion.server.bookorbit.CacheStore
import net.fledgewing.orbitcompanion.server.bookorbit.ConnectorPlugin
import net.fledgewing.orbitcompanion.server.bookorbit.SleepChoicesProjection

/** The only production composition root allowed to import an implementation. */
object ServerAdapters {
    private val registry = AdapterRegistry(listOf(
        "bookorbit" to { store, clock -> BookOrbitProjection(store as CacheStore, clock) },
    ))
    fun forStore(store: ProjectionStore, id: String = "bookorbit", clock: () -> Long = { System.currentTimeMillis()/1000 }): ServerAdapter =
        registry.create(id, store, clock)
    val cachedLists: CachedListProjection get() = SleepChoicesProjection
    val connector: ConnectorInstaller get() = ConnectorPlugin
    val runtime: ServerRuntime get() = AdapterWorker
    val covers: CoverService get() = BookOrbitCovers
}

typealias AdapterFactory = (ProjectionStore, () -> Long) -> ServerAdapter

/** The same registry serves production factories and independent contract-test adapters. */
class AdapterRegistry(factories: List<Pair<String, AdapterFactory>>) {
    private val entries = factories.toMap()
    init { require(entries.size == factories.size); require(entries.keys.none { it.isBlank() }) }
    fun create(id: String, store: ProjectionStore, clock: () -> Long = { System.currentTimeMillis()/1000 }): ServerAdapter =
        requireNotNull(entries[id]) { "unknown adapter" }(store, clock).also { require(it.id == id) { "adapter identity mismatch" } }
}

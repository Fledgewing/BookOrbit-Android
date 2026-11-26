package net.fledgewing.orbitcompanion

import net.fledgewing.orbitcompanion.server.bookorbit.AdapterWorker
import net.fledgewing.orbitcompanion.server.bookorbit.BookOrbitCovers
import net.fledgewing.orbitcompanion.server.bookorbit.BookOrbitProjection
import net.fledgewing.orbitcompanion.server.bookorbit.CacheStore
import net.fledgewing.orbitcompanion.server.bookorbit.ConnectorPlugin

/** The only production composition root allowed to import an implementation. */
object ServerAdapters {
    private val factories = mapOf<String, (ProjectionStore, () -> Long) -> ServerAdapter>(
        "bookorbit" to { store, clock -> BookOrbitProjection(store as CacheStore, clock) },
    )
    fun forStore(store: ProjectionStore, id: String = "bookorbit", clock: () -> Long = { System.currentTimeMillis()/1000 }): ServerAdapter =
        requireNotNull(factories[id]) { "unknown adapter" }(store, clock)
    val connector: ConnectorInstaller get() = ConnectorPlugin
    val runtime: ServerRuntime get() = AdapterWorker
    val covers: CoverService get() = BookOrbitCovers
}

/** Injectable registry used by worker/account owners; duplicate IDs fail rather than shadow. */
class AdapterRegistry(adapters: List<ServerAdapter>) {
    private val entries = adapters.associateBy { it.id }
    init { require(entries.size == adapters.size); require(entries.keys.none { it.isBlank() }) }
    fun get(id: String): ServerAdapter = requireNotNull(entries[id]) { "unknown adapter" }
}

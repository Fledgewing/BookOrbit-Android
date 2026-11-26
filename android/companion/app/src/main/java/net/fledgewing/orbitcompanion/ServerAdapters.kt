package net.fledgewing.orbitcompanion

import android.content.Context
import net.fledgewing.orbitcompanion.server.bookorbit.AccountHttp
import net.fledgewing.orbitcompanion.server.bookorbit.BookOrbitAccount
import net.fledgewing.orbitcompanion.server.bookorbit.BookOrbitServerAdapter
import net.fledgewing.orbitcompanion.server.bookorbit.ConnectorHttp
import net.fledgewing.orbitcompanion.server.bookorbit.ServerCredentials
import net.fledgewing.orbitcompanion.server.bookorbit.AdapterWorker
import net.fledgewing.orbitcompanion.server.bookorbit.BookOrbitCovers
import net.fledgewing.orbitcompanion.server.bookorbit.BookOrbitProjection
import net.fledgewing.orbitcompanion.server.bookorbit.BookOrbitLibrary
import net.fledgewing.orbitcompanion.server.bookorbit.CacheStore
import net.fledgewing.orbitcompanion.server.bookorbit.ConnectorPlugin
import net.fledgewing.orbitcompanion.server.bookorbit.SleepChoicesProjection

/** The only production composition root allowed to import an implementation. */
object ServerAdapters {
    private val registry = AdapterRegistry(listOf(
        "bookorbit" to { store, clock -> BookOrbitProjection(store as CacheStore, clock.clock, clock.fallbackReadingStats ?: { BookOrbitLibrary.readingStats(store) }, clock.accountState, clock.accountStats) },
    ))
    fun forStore(store: ProjectionStore, id: String = "bookorbit", clock: () -> Long = { System.currentTimeMillis()/1000 },
        fallbackReadingStats: ((String) -> RemoteReadingStats?)? = null,
        accountState: () -> Map<String, Any?> = { mapOf("signedIn" to false) },
        accountStats: (String) -> Map<*, *>? = { null }): ServerAdapter =
        registry.create(id, store, ProjectionContext(clock, fallbackReadingStats, accountState, accountStats))
    fun session(ctx: Context, id: String = "bookorbit"): ServerAdapter {
        require(id == "bookorbit") { "unknown adapter" }
        val credentials = ServerCredentials(EncryptedAccountVault.android(ctx))
        val account = BookOrbitAccount(credentials.accountVault, AccountHttp, setupOnSignIn = { false })
        return BookOrbitServerAdapter(credentials, account, ConnectorHttp,
            coverReferenceJob = { creds, owner, reference, refresh, done ->
                AdapterWorker.acquireCoverReference(ctx,creds,owner,reference,refresh,done)
            }, coverJob = { creds, owner, key, done -> AdapterWorker.acquireCover(ctx,creds,owner,key,done) })
    }
    val cachedLists: CachedListProjection get() = SleepChoicesProjection
    val connector: ConnectorInstaller get() = ConnectorPlugin
    val runtime: ServerRuntime get() = AdapterWorker
    val covers: CoverService get() = BookOrbitCovers
}

data class ProjectionContext(val clock: () -> Long = { System.currentTimeMillis()/1000 },
    val fallbackReadingStats: ((String) -> RemoteReadingStats?)? = null,
    val accountState: () -> Map<String, Any?> = { mapOf("signedIn" to false) },
    val accountStats: (String) -> Map<*, *>? = { null })

typealias AdapterFactory = (ProjectionStore, ProjectionContext) -> ServerAdapter

/** The same registry serves production factories and independent contract-test adapters. */
class AdapterRegistry(factories: List<Pair<String, AdapterFactory>>) {
    private val entries = factories.toMap()
    init { require(entries.size == factories.size); require(entries.keys.none { it.isBlank() }) }
    fun create(id: String, store: ProjectionStore, clock: ProjectionContext = ProjectionContext()): ServerAdapter =
        requireNotNull(entries[id]) { "unknown adapter" }(store, clock).also { require(it.id == id) { "adapter identity mismatch" } }
}

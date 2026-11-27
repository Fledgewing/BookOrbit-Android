package net.fledgewing.orbitcompanion

import java.io.File

/** Neutral, worker-only server boundary. Keys are opaque and account scoped. Implementations
 * normalize protocol data before returning it; unsupported operations are explicit. Renderers
 * use LibraryReadModel, never this transport-facing interface. */
interface ServerAdapter {
    fun recommendedSettings(): List<Map<String,Any?>> = emptyList()
    val id: String
    fun project(owner: String, request: Map<*, *>): Map<String, Any?> = unsupported()
    fun capabilities(owner: String) = project(owner, mapOf("op" to "capabilities"))
    fun catalog(owner: String, query: Map<String, Any?>, limit: Int, offset: Int = 0) =
        project(owner, mapOf("op" to "window", "source" to "all", "query" to query, "limit" to limit, "offset" to offset))
    fun detail(owner: String, key: String) = project(owner, mapOf("op" to "book", "key" to key))
    fun progress(owner: String, key: String) = project(owner, mapOf("op" to "progress", "key" to key))
    fun status(owner: String, key: String) = project(owner, mapOf("op" to "status", "key" to key))
    fun lists(owner: String, limit: Int, offset: Int = 0) = project(owner, mapOf("op" to "lists", "limit" to limit, "offset" to offset))
    fun sources(owner: String, category: String, limit: Int = 6, offset: Int = 0) =
        project(owner, mapOf("op" to "sources", "category" to category, "limit" to limit, "offset" to offset))
    fun catalogAction(owner: String, action: String, args: Map<*,*>, done: (Map<String,Any?>?,String?) -> Unit) = done(null,"unsupported")
    fun catalogControl(owner: String, action: String, manual: Boolean, done: (Map<String,Any?>?,String?) -> Unit) = done(null,"unsupported")
    fun manifest(owner: String): Map<String, Any?> = unsupported()
    fun cover(owner: String, key: String): Map<String, Any?> = unsupported()
    /** Explicit acquisition off the render path; the result is a local file reference. */
    fun acquireCoverReference(reference: String, refresh: Boolean, owner: String, done: (Map<String, Any?>?, String?) -> Unit) = done(null,"unsupported")
    fun acquireCover(key: String, done: (Map<String, Any?>?, String?) -> Unit) = done(null,"unsupported")
    fun download(owner: String, key: String, file: String, revision: String?): Map<String, Any?> = unsupported()
    fun setProgress(owner: String, key: String, position: Map<String, Any?>): Map<String, Any?> = unsupported()
    fun setStatus(owner: String, key: String, status: String): Map<String, Any?> = unsupported()
    fun saveList(owner: String, key: String?, query: Map<String, Any?>): Map<String, Any?> = unsupported()
    fun localFiles(owner: String): List<LocalBook>? = null
    fun cachedReadingStats(owner: String): RemoteReadingStats? = null
    fun readingStats(owner: String): Map<String, Any?> = unsupported()
    fun state(): Map<String, Any?> = unsupported()
    fun signIn(server: String, username: String, password: CharArray): Unit = try { throw ServerFailure("unsupported") } finally { password.fill('\u0000') }
    fun signOut(): Unit = throw ServerFailure("unsupported")
    fun setLogin(kind: String, server: String, username: String, secret: CharArray, derivedKey: Boolean = false): Unit = try { throw ServerFailure("unsupported") } finally { secret.fill('\u0000') }
    fun removeLogin(kind: String): Unit = throw ServerFailure("unsupported")
    fun useAccountLogin(kind: String): Unit = throw ServerFailure("unsupported")
    fun fallbackReadingStats(): RemoteReadingStats? = null
    fun refreshStats() {}
    fun owner(): String? = null
    /** Position credentials may belong to a different account from the catalog login. */
    fun positionOwner(): String? = owner()
    fun positionDirections(): PositionDirections = PositionDirections()
    fun stats(owner: String): Map<*, *>? = null
    fun position(document: String, update: Map<String, Any?>? = null): Map<String, Any?> = unsupported()
    /** Companion's sole sync owner invokes these on its serial worker, never from rendering. */
    fun importLifecycle(queue: LifecycleQueue, settings: File, quiesced: Boolean): Int = 0
    fun captureLifecycle(capture: Map<*, *>): Pair<String,ByteArray> = throw ServerFailure("unsupported")
    fun positionIntent(document: String, update: Map<String,Any?>): ByteArray = LuaValue.encode(update)
    fun lifecyclePosition(payload: ByteArray): CapturedPosition {
        val raw=LuaValue.parse(payload) as? Map<*, *> ?: throw ServerFailure("invalid")
        return CapturedPosition((raw["percentage"] as? Number)?.toDouble(),raw["position"] as? String,
            (raw["capturedAt"] as? Number)?.toLong() ?: 0L,raw["finished"]==true)
    }
    fun lifecyclePhase(entry: LifecycleQueue.Entry, phase: String, checkpoint: ByteArray, openPath: String?): SyncPhaseResult = throw ServerFailure("unsupported")
    fun lifecycleComplete(checkpoint: ByteArray): Boolean = true
    fun nextSyncVerification(owner: String, document: String): Map<String,Any?> = emptyMap()
    fun syncVerification(owner: String, document: String, key: String, valid: Boolean, page: Int?) {}
    fun catalog(page: Int = 1, limit: Int = 24): Map<String, Any?> = unsupported()
    fun download(key: String, destination: File): Boolean = false
    fun setupCredentials(values: Map<String, String>): Map<String, Any?> = unsupported()
    fun connectorCredentials(connector: String, user: String, secret: CharArray): Map<String, Any?> = try { unsupported() } finally { secret.fill('\u0000') }
    fun unsupported(): Map<String, Any?> = mapOf("error" to "unsupported")
}

/** Existing projection persistence; adapters may reuse their catalog DB without exposing it to UI. */
interface ProjectionStore : AutoCloseable {
    val root: File

    fun db(): Sql
    fun meta(k: String): String?
    fun <T> transaction(block: () -> T): T
}

interface ConnectorInstaller {
    val minimumVersion: String
    val homeModeKey: String
    fun coverCacheDir(root: File): File
    fun setupId(label: String): String?
    fun pluginDir(): File
    fun version(main: String?): String?
    fun needsInstall(installed: String?): Boolean
    fun install(): String
}

interface CachedListProjection {
    fun read(sql: Sql, saved: SleepChoices?): SleepChoices?
}

/** Neutral, credential-free failure surfaced by any adapter. */
open class ServerFailure(val kind: String) : Exception(kind)

data class CapturedPosition(val percentage: Double?, val position: String?, val capturedAt: Long, val finished: Boolean = false)

/** Owned position policy options, translated by adapters from any legacy preference format. */
data class PositionDirections(val automatic: Boolean=true,val ahead: String="ask",val behind: String="keep")

package net.fledgewing.orbitcompanion

import android.content.Context
import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executors

/** BookSync's account interface. UI sees only immutable, small state and completion codes.
 * Adapter, token vault and all HTTP stay on one private worker; paints never wait on it. */
object LibraryAccount {
    const val OPEN = "${Contract.PACKAGE}.call.ACCOUNT_OPEN"
    const val CONNECTOR = "${Contract.PACKAGE}.call.ACCOUNT_CONNECTOR"
    private val queue = Executors.newSingleThreadExecutor { r -> Thread(r, "booksync-account").apply { isDaemon = true } }
    private val main = Handler(Looper.getMainLooper())
    private var adapter: BookOrbitAccount? = null // worker thread only
    @Volatile private var snapshot: Map<String, Any?> = mapOf("signedIn" to false, "connector" to "not-configured")
    @Volatile private var savedStats: Map<*, *>? = null
    @Volatile private var savedConnector: CacheWorker.Creds? = null
    @Volatile private var savedOwner: String? = null
    @Volatile private var loaded = false
    private var nextRefreshAt = 0L
    private var legacy: CacheWorker.Creds? = null
    private fun adapter(ctx: Context) = adapter ?: BookOrbitAccount(EncryptedAccountVault.android(ctx), AccountHttp).also { adapter = it }
    fun state(): Map<String, Any?> = snapshot
    fun stats(owner: String): Map<*, *>? = savedStats.takeIf { owner == savedOwner }
    fun connector(): CacheWorker.Creds? = savedConnector
    fun ready(): Boolean = loaded
    fun initialize(ctx: Context, done: () -> Unit = {}) {
        if (loaded) { main.post(done); return }
        queue.execute { if (!loaded) { publish(adapter(ctx)); loaded = true }; main.post(done) }
    }
    fun bind(ctx: Context, credentials: CacheWorker.Creds?) {
        queue.execute { legacy = credentials; val a = adapter(ctx);
            if (a.state()["signedIn"] == true && credentials != null) runCatching { a.setupConnector(credentials) }
            publish(a); loaded = true }
    }
    private fun publish(a: BookOrbitAccount) {
        val signed = a.state()
        savedConnector = a.connector().takeIf { signed["signedIn"] == true }
        savedOwner = a.owner()
        savedStats = savedOwner?.let(a::stats)
        require(LuaValue.encode(signed).size <= 16384)
        snapshot = signed
    }
    private fun command(ctx: Context, work: (BookOrbitAccount) -> Unit, done: (String?) -> Unit) {
        val app = ctx.applicationContext
        queue.execute {
            var error: String? = null
            val a = adapter(app)
            try { work(a) } catch (e: BookOrbitAccount.Failure) { error = e.kind }
            catch (_: Exception) { error = "unavailable" }
            publish(a)
            Worker.accountChanged(app)
            main.post { done(error) }
        }
    }
    fun signIn(ctx: Context, server: String, username: String, password: CharArray, done: (String?) -> Unit) =
        command(ctx, { a -> try { a.signIn(server, username, password, legacy) } finally { password.fill('\u0000') } }, done)
    fun retryConnection(ctx: Context, done: (String?) -> Unit) = command(ctx, { it.setupConnector(legacy); it.refreshStats(force = true) }, done)
    fun signOut(ctx: Context, done: (String?) -> Unit) = command(ctx, { it.signOut() }, done)
    @Synchronized fun refresh(ctx: Context) {
        val now = System.currentTimeMillis()
        if (now < nextRefreshAt) return
        nextRefreshAt = now + 300000
        command(ctx, { it.refreshStats() }, {})
    }
}

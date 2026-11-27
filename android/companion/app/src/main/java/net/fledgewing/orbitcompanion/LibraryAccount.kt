package net.fledgewing.orbitcompanion

import android.content.Context
import android.os.Handler
import android.os.Looper
import java.io.File
import java.util.concurrent.Executors

/** BookSync's neutral server interface. One private worker owns all three logins and transport. */
object LibraryAccount {
    const val OPEN = "${Contract.PACKAGE}.call.ACCOUNT_OPEN"
    const val STATE = "${Contract.PACKAGE}.call.SERVER_STATE"
    private val queue = Executors.newSingleThreadExecutor { r -> Thread(r, "booksync-server").apply { isDaemon = true } }
    // Cached publication context is readable on the writer without constructing UI dispatch.
    private val main by lazy { Handler(Looper.getMainLooper()) }
    private var adapter: ServerAdapter? = null
    @Volatile private var syncOwner: SyncOwner? = null
    private var syncRetryScheduled=false
    private fun syncOwner(ctx: Context): SyncOwner = syncOwner ?: SyncOwner(
        LifecycleQueue(AndroidSql(File(ctx.filesDir,"sync-journal.db"))),
        File(android.os.Environment.getExternalStorageDirectory(),"koreader/settings")).also { syncOwner=it }
    private fun retrySync(ctx: Context) {
        val owner=syncOwner ?: return
        val a=adapter ?: return
        if(syncRetryScheduled || !owner.needsRetry(a)) return
        syncRetryScheduled=true
        main.postDelayed({ queue.execute {
            syncRetryScheduled=false
            runCatching { if(owner.needsRetry(a)) owner.drain(a) }
            retrySync(ctx)
        } },60000)
    }
    fun positionPreview(args: Map<*, *>): Map<String,Any?> {
        val a=adapter ?: return mapOf("pending" to true)
        return syncOwner?.preview(a.id,published.positionOwner,args) ?: mapOf("pending" to true)
    }
    private class Published(val state: Map<String, Any?> = emptyMap(), val owner: String? = null, val stats: Map<*, *>? = null, val fallback: RemoteReadingStats? = null, val positionOwner: String? = null)
    @Volatile private var published = Published()
    @Volatile private var loaded = false
    private var nextRefreshAt = 0L
    private fun adapter(ctx: Context): ServerAdapter = adapter ?: run {
        ServerAdapters.session(ctx).also { adapter = it }
    }
    fun state(): Map<String, Any?> = published.state
    fun owner(): String? = published.owner
    fun stats(owner: String): Map<*, *>? = published.let { if (owner == it.owner) it.stats else null }
    fun fallbackReadingStats(owner: String): RemoteReadingStats? = published.let { if (owner == it.owner) it.fallback else null }
    fun ready() = loaded
    fun initialize(ctx: Context, done: () -> Unit = {}) {
        if (loaded) { main.post(done); return }
        val app = ctx.applicationContext
        queue.execute {
            try { if (!loaded) { publish(adapter(app)); syncOwner(app).restorePreviews(adapter(app)); loaded = true } }
            catch (_: Exception) { published = Published() }
            finally { main.post(done) }
        }
    }
    fun refreshIdentity(ctx: Context) {
        val app=ctx.applicationContext
        loaded=false
        queue.execute {
            try { publish(adapter(app)); loaded=true }
            catch(_: Exception) { published=Published(); loaded=true }
        }
    }
    private fun publish(a: ServerAdapter) {
        val state = a.state(); val owner = a.owner()
        require(LuaValue.encode(state).size <= 16384)
        published = Published(state, owner, owner?.let(a::stats),a.fallbackReadingStats(),a.positionOwner())
    }
    private fun command(ctx: Context, work: (ServerAdapter) -> Unit, done: (String?) -> Unit, cleanup: () -> Unit = {}, invalidate: Boolean = true) {
        val app = ctx.applicationContext
        queue.execute {
            val start = System.nanoTime()
            var error: String? = null
            try { work(adapter(app)) } catch (e: ServerFailure) { error = e.kind }
            catch (_: Exception) { error = "unavailable" }
            finally { cleanup(); runCatching { retrySync(app) } }
            runCatching { adapter?.let(::publish) }.onFailure { published = Published(); error = "unavailable" }
            if (invalidate) Worker.accountChanged(app)
            OLog.i("server.command ms=${(System.nanoTime()-start)/1_000_000}")
            main.post { done(error) }
        }
    }
    fun signIn(ctx: Context, server: String, username: String, password: CharArray, done: (String?) -> Unit) =
        command(ctx, { it.signIn(server,username,password) }, done, { password.fill('\u0000') })
    fun signOut(ctx: Context, done: (String?) -> Unit) = command(ctx, { it.signOut() }, done)
    fun setLogin(ctx: Context, kind: String, server: String, username: String, secret: CharArray, derivedKey: Boolean, done: (String?) -> Unit) =
        command(ctx, { it.setLogin(kind,server,username,secret,derivedKey) }, done, { secret.fill('\u0000') })
    fun removeLogin(ctx: Context, kind: String, done: (String?) -> Unit) = command(ctx, { it.removeLogin(kind) }, done)
    fun useAccountLogin(ctx: Context, kind: String, done: (String?) -> Unit) = command(ctx, { it.useAccountLogin(kind) }, done)
    fun position(ctx: Context, document: String, update: Map<String,Any?>? = null, done: (Map<String,Any?>?,String?) -> Unit) {
        var result: Map<String,Any?>? = null
        // Writes go through the same owner/policy journal as lifecycle captures.
        command(ctx, { result = if(update==null) it.position(document,null) else syncOwner(ctx.applicationContext).write(it,document,update) }, { done(result,it) }, invalidate = false)
    }
    fun sync(ctx: Context, op: String, args: Map<*, *>, done: (Map<String,Any?>?,String?)->Unit) {
        var result: Map<String,Any?>?=null
        command(ctx,{ result=syncOwner(ctx.applicationContext).command(it,op,args) },{ done(result,it) },invalidate=false)
    }
    fun catalog(ctx: Context, page: Int = 1, limit: Int = 24, done: (Map<String,Any?>?,String?) -> Unit) {
        var result: Map<String,Any?>? = null
        command(ctx, { result = it.catalog(page,limit) }, { done(result,it) }, invalidate = false)
    }
    fun recommendedSettings(ctx:Context,args:Map<*,*>,done:(Map<String,Any?>?,String?)->Unit) {
        val app=ctx.applicationContext
        queue.execute {
            val start=System.nanoTime()
            val result=runCatching {
                val definitions=adapter(app).recommendedSettings()
                if(args["definitions"]==true) mapOf("items" to definitions) else {
                    val result=RecommendationPlan.evaluate(definitions,args)
                    val destination=java.io.File(android.os.Environment.getExternalStorageDirectory(),"koreader/settings/orbit-recommended.json")
                    destination.parentFile?.mkdirs()
                    val tmp=java.io.File(destination.path+".new")
                    val rows=(result["items"] as? List<*>).orEmpty().map { raw ->
                        val row=raw as Map<*,*>;row.filterKeys { it in setOf("id","label","state","yours","orbit","was","reason") }
                    }
                    tmp.writeText(org.json.JSONObject(mapOf("v" to 1,"at" to System.currentTimeMillis(),"items" to rows)).toString())
                    check(tmp.renameTo(destination));result
                }
            }
            OLog.i("library.recommendations ms=${(System.nanoTime()-start)/1_000_000}")
            main.post { result.fold({done(it,null)},{done(null,"unavailable")}) }
        }
    }
    fun catalogAction(ctx: Context, owner: String, action: String, args: Map<*,*>, done: (Map<String,Any?>?,String?) -> Unit) {
        val app=ctx.applicationContext
        queue.execute {
            try { adapter(app).catalogAction(owner,action,args) { value,error -> main.post { done(value,error) } } }
            catch(e: ServerFailure) { main.post { done(null,e.kind) } }
            catch(_: Exception) { main.post { done(null,"unavailable") } }
        }
    }
    fun catalogControl(ctx: Context, owner: String, action: String, manual: Boolean, done: (Map<String,Any?>?,String?) -> Unit) {
        val app=ctx.applicationContext
        queue.execute {
            try { adapter(app).catalogControl(owner,action,manual) { value,error -> main.post { done(value,error) } } }
            catch(e: ServerFailure) { main.post { done(null,e.kind) } }
            catch(_: Exception) { main.post { done(null,"unavailable") } }
        }
    }
    fun acquireCover(ctx: Context, key: String, done: (Map<String, Any?>?, String?) -> Unit) {
        val app = ctx.applicationContext
        queue.execute {
            val start = System.nanoTime()
            fun complete(result: Map<String, Any?>?, error: String?) {
                OLog.i("library.cover.acquire ms=${(System.nanoTime()-start)/1_000_000}")
                main.post { done(result,error) }
            }
            try { adapter(app).acquireCover(key,::complete) }
            catch (e: ServerFailure) { complete(null,e.kind) }
            catch (_: Exception) { complete(null,"unavailable") }
        }
    }
    fun acquireCoverReference(ctx: Context, reference: String, refresh: Boolean, owner: String, done: (Map<String, Any?>?, String?) -> Unit) {
        val app=ctx.applicationContext
        queue.execute {
            try { adapter(app).acquireCoverReference(reference,refresh,owner) { result,error -> main.post { done(result,error) } } }
            catch (e: ServerFailure) { main.post { done(null,e.kind) } }
            catch (_: Exception) { main.post { done(null,"unavailable") } }
        }
    }
    fun download(ctx: Context, key: String, destination: File, done: (String?) -> Unit) = command(ctx, {
        require(Places.inside(destination.path,Places.roots()+DeviceStorage.downloadRoot(Worker.root())) != null)
        if (!it.download(key,destination)) throw ServerFailure("unavailable")
    }, done)
    @Synchronized fun refresh(ctx: Context) {
        val now = System.currentTimeMillis()
        if (now < nextRefreshAt) return
        nextRefreshAt = now + 300000
        command(ctx, { it.refreshStats() }, {})
    }
}

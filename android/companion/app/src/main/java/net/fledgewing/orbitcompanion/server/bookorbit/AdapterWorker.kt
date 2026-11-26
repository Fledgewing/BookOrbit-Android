package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import android.content.Context
import android.content.Intent
import android.os.Environment
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * Sole cache writer. Neutral catalog commands resolve credentials in the server adapter and
 * queue private plans here; display snapshots/events reuse the existing database and mailbox.
 * Remaining copy/sleep compatibility commands share this writer until their separate cutover.
 * No catalog login or protocol plan arrives from the plugin.
 */
object AdapterWorker : ServerRuntime {
    const val ACTION_STORAGE = "${Contract.PACKAGE}.action.STORAGE"
    const val ACTION_SLEEP_REFRESH = "${Contract.PACKAGE}.action.SLEEP_REFRESH"
    /** The shared-storage stress test's writer (docs/design/sqlite-cache.md "Stress test"); no login. */
    const val ACTION_SQLITE_STRESS = "${Contract.PACKAGE}.action.SQLITE_STRESS"
    /** A write the plugin made, to patch into the saved replies (or a wipe); no login. */
    const val ACTION_PATCH = "${Contract.PACKAGE}.action.PATCH"

    /** The cap the plugin needs before it hands work over (ModeLogic.BASE). */
    const val CAP = "cache_worker"

    fun root(): File = File(Environment.getExternalStorageDirectory(), "koreader/settings/orbit-cache")

    private val lock = Object()
    private val patches = ArrayDeque<() -> Unit>()
    private var pending: Pair<CacheWorker.Plan, CacheWorker.Creds>? = null
    private var storage: CacheWorker.StorageAsk? = null
    private var sleep: Pair<String, SleepPoolBuilder.Ask>? = null
    private var pickers: Pair<String, CacheWorker.Creds>? = null
    @Volatile private var app: Context? = null
    private var running = false
    private var activeCatalogOwner: String? = null
    private var deferredAccountChange = false

    @Volatile
    override var mirrorRunning = false
        private set

    /** Work in hand: an automatic Wi-Fi off waits for it. */
    override fun busy(): Boolean = mirrorRunning || catalogActionRunning || synchronized(lock) { patches.isNotEmpty() || pending != null || storage != null || sleep != null || pickers != null }

    private var worker: CacheWorker? = null

    /** A Full refresh's % while it runs (the status page shows it), else null. */
    @Volatile
    var progress: Long? = null
        private set

    /** "Full refresh · 37%" while a Full refresh runs, else null. */
    @Volatile private var manualRefresh = false

    override fun progressLine(): String? {
        if (!mirrorRunning || !manualRefresh) return null
        return MirrorLogic.runningProgressLine(progress, BulkWork.paused)
    }

    private fun worker(): CacheWorker = worker ?: CacheWorker(root(), UrlHttp, cpuMs = { android.os.SystemClock.currentThreadTimeMillis() }, checkpoint = { BulkWork.checkpoint() }, threadFactory = { name, task -> BulkWork.thread(name, task) }, onProgress = { progress = it }, places = Places.roots(), bookRoots = listOf(Environment.getExternalStorageDirectory()), resizeThumbnail = { f, w, h ->
        val dm = app?.resources?.displayMetrics
        BulkWork.phase("cover") { ThumbnailCache.shrink(f, if (w > 0) w else (dm?.widthPixels ?: 1080) / 3,
            if (h > 0) h else (dm?.heightPixels ?: 1440) / 3) }
    }).also { worker = it }

    override fun nativeFooterRepair(before: String, after: String, token: String) {
        worker().event(mapOf("kind" to "native_footer_repair", "before" to before, "after" to after, "token" to token))
    }

    /** Ownership changes wait until the active catalog writer has stopped. Lifecycle/position
     * queues are untouched; the same sole writer applies the cache transition afterward. */
    private fun applyAccountChange() {
        val owner=LibraryAccount.owner()
        synchronized(lock) { if(pending?.first?.owner!=owner) pending=null }
        owner?.let { worker().store.own(it) }
        worker().store.db().exec("DELETE FROM library_views")
        worker().event(mapOf("kind" to "account"))
    }
    override fun accountChanged(ctx: Context) {
        app=ctx.applicationContext
        synchronized(lock) { patches.addLast {
            if(mirrorRunning && LibraryAccount.owner()!=activeCatalogOwner) {
                File(root(),"mirror/stop").writeText("stop")
                deferredAccountChange=true
            } else applyAccountChange()
        }; lock.notifyAll() }
        start()
    }

    /** Uses the existing sole cache writer; credentials never cross the plugin boundary. */
    fun acquireCover(ctx: Context, credentials: CacheWorker.Creds, owner: String, id: Long,
        done: (Map<String, Any?>?, String?) -> Unit) {
        app = ctx.applicationContext
        BulkWork.attach(ctx)
        synchronized(lock) {
            patches.addLast {
                val result = runCatching {
                    val directory = java.io.File(ConnectorPlugin.coverCacheDir(Environment.getExternalStorageDirectory()),BookOrbitLibrary.namespace(owner))
                    worker().acquireCover(owner,id,credentials,directory)
                }
                result.fold({ done(it,null) }, { done(null,(it as? ServerFailure)?.kind ?: "unavailable") })
            }
            lock.notifyAll()
        }
        start()
    }

    fun acquireCoverReference(ctx: Context, credentials: CacheWorker.Creds?, owner: String, reference: String,
        refresh: Boolean, done: (Map<String, Any?>?, String?) -> Unit) {
        app=ctx.applicationContext
        BulkWork.attach(ctx)
        synchronized(lock) {
            patches.addLast {
                val start=System.nanoTime()
                val result=runCatching {
                    BulkWork.checkpoint()
                    val external=Environment.getExternalStorageDirectory()
                    val current=worker().store.meta("owner")
                    // Managed credentials are immutable captures from the originating account.
                    // A legacy lookup must match that same namespace before any transport.
                    val legacy=if (credentials==null) LegacyCoverSource.read(File(external,"koreader/settings.reader.lua"),owner) else null
                    val account=owner
                    val login=credentials ?: legacy?.credentials ?: throw ServerFailure("canceled")
                    if (current!=null && current!=account) throw ServerFailure("retryable")
                    val directory=ConnectorPlugin.coverCacheDir(external)
                    var growth=0L
                    val value=worker().acquireCoverReference(account,reference,login,directory,refresh) { growth=it }
                    if (growth>0) {
                        val limit=SettingsStore.get(ctx,"storage_limit_mb").toLongOrNull()?.takeIf { it>0 }?.times(1048576)
                        worker().storage(CacheWorker.StorageAsk("cover acquisition",limit,directory.path,SettingsStore.get(ctx,"mirror_covers")=="1"))
                        val local=value["local_path"] as? String ?: throw ServerFailure("missing")
                        if (!File(LuaValue.utf8(local)).isFile) throw ServerFailure("space")
                    }
                    // Publish the bounded local reference on the same sole writer.
                    val request=mapOf("op" to "cover.reference","reference" to LuaValue.str(reference),"limit" to 1L,"bytes" to 16384L)
                    LibraryReadModel(worker().store).publish(account,listOf(String(LuaValue.encode(request),Charsets.ISO_8859_1)))
                    worker().event(mapOf("kind" to "library","owner" to account))
                    value
                }
                OLog.i("library.cover.reference ms=${(System.nanoTime()-start)/1_000_000}")
                result.fold({ done(it,null) },{ done(null,(it as? ServerFailure)?.kind ?: "unavailable") })
            }
            lock.notifyAll()
        }
        start()
    }

    @Volatile private var catalogActionRunning=false
    /** Auto Wi-Fi off must include an executing command after it leaves the pending queue. */
    internal fun <T> catalogActionWork(work: () -> T): T {
        catalogActionRunning=true
        return try { work() } finally { catalogActionRunning=false }
    }

    fun catalogAction(ctx: Context, credentials: CacheWorker.Creds, owner: String, action: String, args: Map<*,*>,
        done: (Map<String,Any?>?,String?) -> Unit) {
        app=ctx.applicationContext
        BulkWork.attach(ctx)
        synchronized(lock) { patches.addLast { catalogActionWork {
            val start=System.nanoTime()
            val result=runCatching {
                if(owner!=LibraryAccount.owner() || worker().store.meta("owner")!=owner) throw ServerFailure("canceled")
                CatalogWorkflow(worker(),credentials,owner,ConnectorHttp,reading={ Reading.now(ctx) },
                    current={ owner==LibraryAccount.owner() },checkpoint=BulkWork::checkpoint).command(action,args)
            }
            OLog.i("library.catalog.action ms=${(System.nanoTime()-start)/1_000_000}")
            result.fold({ done(it,null) },{ done(null,(it as? ServerFailure)?.kind ?: "unavailable") })
        } }; lock.notifyAll() }
        start()
    }

    /** One sole-writer command. The plugin sends an action and opaque owner, never a plan/login. */
    fun catalogControl(ctx: Context, credentials: CacheWorker.Creds, owner: String, action: String, manual: Boolean,
        done: (Map<String,Any?>?,String?) -> Unit) {
        app=ctx.applicationContext
        BulkWork.attach(ctx)
        synchronized(lock) { patches.addLast {
            val started=System.nanoTime()
            val result=runCatching {
                BulkWork.checkpoint()
                val current=LibraryAccount.owner()
                if(current!=owner) throw ServerFailure("canceled")
                val w=worker()
                val state=if(w.store.meta("owner")==owner) CatalogPlan.status(w.store) else emptyMap()
                var accepted: Map<String,Any?>?=null
                if(action=="stop") {
                    File(root(),"mirror/stop").apply { parentFile?.mkdirs(); writeText("stop") }
                } else if((!mirrorRunning && synchronized(lock) { pending==null }) ||
                    (manual && action in setOf("full","refresh") &&
                        (activeCatalogOwner!=owner || state["op"]!="full") && synchronized(lock) { pending?.first?.let { it.owner!=owner || it.op!="full" } != false })) {
                    val limit=SettingsStore.get(ctx,"storage_limit_mb").toLongOrNull()?.takeIf { it>0 }?.times(1048576)
                    val now=System.currentTimeMillis()/1000
                    val last=w.store.meta("catalog_probe_at")?.toLongOrNull() ?: 0L
                    val op=CatalogPlan.operation(action,state,limit,manual,now,last)
                    if(op!=null) {
                        if(mirrorRunning) File(root(),"mirror/stop").writeText("stop")
                        val ids=BookOrbitLibrary.localEntries(w.store,owner).orEmpty().mapNotNull { (it["book_id"] as? Number)?.toLong() }
                        val external=Environment.getExternalStorageDirectory()
                        val directory=File(ConnectorPlugin.coverCacheDir(external),BookOrbitLibrary.namespace(owner))
                        val plan=CatalogPlan.create(owner,op,ids,SettingsStore.get(ctx,"mirror_covers")=="1",directory.path,limit,manual,server=credentials.server)

                        val file=File(root(),"mirror/plan.lua"); file.parentFile?.mkdirs()
                        val tmp=File(file.path+".tmp"); tmp.writeBytes(LuaValue.encode(plan.m)); check(tmp.renameTo(file))
                        accepted=mapOf("run" to plan.run,"op" to if(op=="resume") "full" else op,"running" to true,"beat" to now,
                            "done" to if(op=="resume") state["done"] else 0L,"total" to if(op=="resume") state["total"] else 100L,
                            "left" to if(op=="resume") state["left"] else 100L,"pct" to if(op=="resume") state["pct"] else 0L,"row_count" to 1L)
                        if(!mirrorRunning) {
                            w.store.own(owner)
                            File(root(),"mirror/status.lua").writeBytes(LuaValue.encode(accepted+mapOf("owner" to owner,"engine" to "bulk")))
                        }
                        synchronized(lock) { pending=plan to credentials; lock.notifyAll() }
                    }
                }
                w.publishCatalogState()
                accepted ?: CatalogPlan.status(w.store)
            }
            OLog.i("library.catalog.control ms=${(System.nanoTime()-started)/1_000_000}")
            result.fold({ done(it,null) },{ done(null,(it as? ServerFailure)?.kind ?: "unavailable") })
        }; lock.notifyAll() }
        start()
    }

    private fun creds(i: Intent): CacheWorker.Creds? {
        val server = i.getStringExtra("server")?.takeIf { it.isNotEmpty() } ?: return null
        val user = i.getStringExtra("user") ?: return null
        val key = i.getStringExtra("userkey") ?: return null
        return CacheWorker.Creds(server, user, key)
    }

    override fun onIntent(ctx: Context, i: Intent) {
        app = ctx.applicationContext
        BulkWork.attach(ctx)
        LibraryAccount.initialize(ctx)
        if (i.action == ACTION_SQLITE_STRESS) {
            val secs = i.getStringExtra("seconds")?.toIntOrNull()?.coerceIn(5, 600) ?: SqliteStress.SECONDS
            return SqliteStress.start(root(), secs)
        }
        if (i.action == ACTION_STORAGE) {
            val shown = i.getStringExtra("shown")?.lines()?.filter { it.isNotEmpty() }
            if (shown != null) {
                synchronized(lock) { patches.addLast { worker().coversShown(shown) }; lock.notifyAll() }
                return start()
            }
            // No login: files only. A newer ask replaces a waiting one.
            val a = CacheWorker.StorageAsk(i.getStringExtra("reason") ?: "plugin", i.getStringExtra("limit")?.toLongOrNull()?.takeIf { it > 0 },
                ConnectorPlugin.coverCacheDir(Environment.getExternalStorageDirectory()).path, i.getStringExtra("mirror_covers") == "1")
            synchronized(lock) { storage = a; lock.notifyAll() }
            return start()
        }
        if (i.action == ACTION_PATCH && i.hasExtra("library_batch")) {
            val encoded = i.getStringExtra("library_batch")?.takeIf { it.length <= 131072 } ?: return
            val owner = i.getStringExtra("owner") ?: return
            synchronized(lock) { patches.addLast {
                val requests = LuaValue.parse(LuaValue.str(encoded).toByteArray(Charsets.ISO_8859_1)) as? List<*> ?: return@addLast
                val model = LibraryReadModel(worker().store, fallbackReadingStats = { scope -> LibraryAccount.fallbackReadingStats(scope) ?: BookOrbitLibrary.readingStats(worker().store) }, accountState = LibraryAccount::state, accountStats = LibraryAccount::stats, readingStats = {
                    ReadingStats.read(File(root().parentFile, "statistics.sqlite3"), System.currentTimeMillis() / 1000, AccountStats.zone(LibraryAccount.stats(LuaValue.str(owner))))
                }, battery = { StatsStore.get(ctx).batterySnapshot(System.currentTimeMillis(), java.time.ZoneId.systemDefault()) })
                if (requests.size <= LibraryReadModel.MAX_BATCH && model.publish(LuaValue.str(owner), requests))
                    worker().event(mapOf("kind" to "library", "owner" to LuaValue.str(owner)))
            }; lock.notifyAll() }
            return start()
        }
        if (i.action == ACTION_PATCH && i.hasExtra("board_year")) {
            val encoded = i.getStringExtra("board_year") ?: return
            val key = i.getStringExtra("board_key") ?: return
            val at = i.getStringExtra("board_now")?.toLongOrNull() ?: return
            synchronized(lock) {
                patches.addLast {
                    BulkWork.checkpoint()
                    val year = LuaValue.parse(LuaValue.str(encoded).toByteArray(Charsets.ISO_8859_1)) as? Map<*, *>
                    val stats = File(root().parentFile, "statistics.sqlite3")
                    val daily = if (stats.isFile) runCatching {
                        AndroidSql(stats, readOnly = true).use { db ->
                            db.query("SELECT date(start_time, 'unixepoch', 'localtime'), SUM(MIN(duration, 86400)) FROM page_stat_data WHERE start_time >= ? GROUP BY 1", at - 371 * 86400) {
                                (it.text(0) ?: "") to (it.long(1) ?: 0L)
                            }.toMap()
                        }
                    }.getOrDefault(emptyMap()) else emptyMap()
                    worker().event(sortedMapOf("kind" to "board_year", "key" to key, "data" to BoardYear.build(at, year, daily)))
                }
                lock.notifyAll()
            }
            return start()
        }
        if (i.action == ACTION_PATCH && i.getStringExtra("drain_events") == "1") {
            val ack = i.getStringExtra("events_ack")
            synchronized(lock) { patches.addLast { worker().drainEvents(ack) }; lock.notifyAll() }
            return start()
        }
        if (i.action == ACTION_PATCH) return

        app = ctx.applicationContext
        val creds = creds(i)
        if (creds == null) {
            OLog.w("worker: ${Contract.shortName(i.action)} without a BookOrbit login; ignored")
            return
        }
        when (i.action) {
            ACTION_SLEEP_REFRESH -> if (i.getStringExtra("scopes_only") == "1") {
                // The pickers' lists only (Pick from, Leave out and its tags); never a pool build.
                synchronized(lock) { pickers = (i.getStringExtra("reason") ?: "picker") to creds; lock.notifyAll() }
            } else {
                val a = SleepPoolBuilder.Ask(i.getStringExtra("from") ?: "", SleepPoolLogic.rules(i.getStringExtra("rules")),
                    i.getStringExtra("open_id")?.toLongOrNull(), i.getStringExtra("every") == "1", i.getStringExtra("storage_limit_mb")?.toLongOrNull(), creds)
                synchronized(lock) { sleep = (i.getStringExtra("reason") ?: "plugin") to a; lock.notifyAll() }
            }
            else -> return
        }
        start()
    }

    private fun start(): Unit = synchronized(lock) {
        if (running) return@synchronized
        running = true
        BulkWork.executor.execute {
            var completed = false
            try { NoMedia.roots(Places.roots()); loop(); completed = true }
            catch (e: Exception) { OLog.w("worker: bulk job deferred", e) }
            finally { synchronized(lock) { running = false; if (completed && busy()) start() } }
        }
    }

    private fun drainChecks() {
        val a = synchronized(lock) { storage.also { storage = null } }
        if (a != null) try { BulkWork.phase("storage") { worker().storage(a) } } catch (e: Exception) { OLog.w("worker: storage count failed", e) }
        val sp = synchronized(lock) { sleep.also { sleep = null } }
        if (sp != null) sleepPool(sp.first, sp.second)
        val pk = synchronized(lock) { pickers.also { pickers = null } }
        if (pk != null) pickers(pk.first, pk.second)
        while (true) {
            val pt = synchronized(lock) { patches.removeFirstOrNull() } ?: break
            try { pt() } catch (e: Exception) { OLog.w("worker: patch failed", e) }
        }

    }

    /** The sleep screen's pool, then its picture redrawn; the plugin hears a sleep_pool event. */
    private fun sleepPool(why: String, a: SleepPoolBuilder.Ask) {
        BulkWork.checkpoint()
        val ev = sortedMapOf<String, Any?>("kind" to "sleep_pool", "why" to why)
        try {
            val b = SleepPoolBuilder(SleepScreen.dir(), UrlHttp, checkpoint = { BulkWork.checkpoint() })
            ev.putAll(BulkWork.phase("sleep pool") { b.build(a) })
            ev["tags"] = b.tags(worker().detailTags(SleepPoolBuilder.TAG_DETAILS_MAX)).toLong()
            OLog.i("worker: sleep screen pool: ${ev["items"]} cover(s), ${ev["kept"]} new, ${ev["probed"]} checked ($why)")
            app?.let { SleepScreen.onPool(it, "pool") }
        } catch (e: Exception) {
            OLog.w("worker: sleep screen pool failed", e)
            ev["err"] = e.javaClass.simpleName
        }
        worker().event(ev)
    }

    /** The pickers' lists: scopes.json from the server, tags.json from the saved details. */
    private fun pickers(why: String, c: CacheWorker.Creds) {
        BulkWork.checkpoint()
        val ev = sortedMapOf<String, Any?>("kind" to "sleep_pool", "why" to why, "scopes_only" to true)
        try {
            val b = SleepPoolBuilder(SleepScreen.dir(), UrlHttp, checkpoint = { BulkWork.checkpoint() })
            ev["tags"] = b.tags(worker().detailTags(SleepPoolBuilder.TAG_DETAILS_MAX)).toLong()
            if (b.scopes(c)) ev["scopes"] = true else ev["err"] = "not listed"
        } catch (e: Exception) {
            OLog.w("worker: sleep screen pickers failed", e)
            ev["err"] = e.javaClass.simpleName
        }
        worker().event(ev)
    }

    private fun loop() {
        while (true) {
            drainChecks()
            val p = synchronized(lock) {
                if (patches.isEmpty() && pending == null && storage == null && sleep == null && pickers == null) { return }
                pending.also { pending = null }
            } ?: continue
            File(root(), "mirror/stop").delete()
            progress = 0
            manualRefresh = p.first.m["manual"] == true
            mirrorRunning = true
            activeCatalogOwner=p.first.owner
            try {
                val why = BulkWork.phase("mirror") { worker().run(p.first, p.second) { drainChecks() } }
                OLog.i("worker: mirror run ${p.first.run} ended: $why")
            } catch (e: Exception) {
                OLog.w("worker: mirror run failed", e)
            } finally {
                mirrorRunning = false
                activeCatalogOwner=null
                progress = null
                if(deferredAccountChange) { deferredAccountChange=false;applyAccountChange() }
            }
        }
    }

    /**
     * HttpURLConnection over kept-alive connections (a reply read to its end returns its connection
     * to the pool; nothing calls disconnect), 30 s timeouts. Redirects as the plugin's requests
     * take them (bookorbit_api.lua requestBlocking, safeRequestRedirect): a GET follows up to 5,
     * only to the same scheme, host and port, so the BookOrbit key never goes to another host.
     */
    object UrlHttp : CacheWorker.Http {
        private const val REDIRECTS = 5
        private val buffers = ThreadLocal.withInitial { ByteArray(16 * 1024) }

        override fun get(url: String, headers: Map<String, String>, sink: File?, maxBytes: Long): CacheWorker.Reply {
            var at = URL(url)
            repeat(REDIRECTS + 1) {
                val c = try { at.openConnection() as HttpURLConnection } catch (e: Exception) { return CacheWorker.Reply(0, err = e.javaClass.simpleName) }
                try {
                    c.instanceFollowRedirects = false
                    c.connectTimeout = 30_000
                    c.readTimeout = 30_000
                    for ((k, v) in headers) c.setRequestProperty(k, v)
                    val code = c.responseCode
                    if (code in listOf(301, 302, 303, 307, 308)) {
                        val loc = c.getHeaderField("Location")
                        drain(c)
                        val next = loc?.let { runCatching { URL(at, it) }.getOrNull() }
                        if (next == null || next.protocol != at.protocol || next.host != at.host || next.port != at.port) {
                            return CacheWorker.Reply(0, err = "unsafe_redirect")
                        }
                        at = next
                        return@repeat
                    }
                    val etag = c.getHeaderField("ETag")
                    val type = c.contentType
                    if (code != 200) { drain(c); return CacheWorker.Reply(code, etag = etag, contentType = type) }
                    c.inputStream.use { input ->
                        if (sink != null) {
                            sink.parentFile?.let(NoMedia::directory)
                            var n = 0L
                            sink.outputStream().use { out ->
                                val buf = buffers.get()!!
                                while (true) {
                                    val r = input.read(buf)
                                    if (r < 0) break
                                    n += r
                                    if (n > maxBytes) { c.disconnect(); sink.delete(); return CacheWorker.Reply(0, err = "response_too_large") }
                                    out.write(buf, 0, r)
                                }
                            }
                            return CacheWorker.Reply(code, etag = etag, contentType = type)
                        }
                        val out = java.io.ByteArrayOutputStream(16 * 1024)
                        val buf = buffers.get()!!
                        var n = 0L
                        while (true) {
                            val r = input.read(buf)
                            if (r < 0) break
                            n += r
                            if (n > maxBytes) { c.disconnect(); return CacheWorker.Reply(0, err = "response_too_large") }
                            out.write(buf, 0, r)
                        }
                        return CacheWorker.Reply(code, out.toByteArray(), etag, type)
                    }
                } catch (e: Exception) {
                    c.disconnect()
                    return CacheWorker.Reply(0, err = e.javaClass.simpleName)
                }
            }
            return CacheWorker.Reply(0, err = "too_many_redirects")
        }

        /** Reads an answer we don't keep to its end, so its connection is reused. */
        private fun drain(c: HttpURLConnection) {
            try {
                (c.errorStream ?: c.inputStream)?.use { input ->
                    val buf = buffers.get()!!
                    var n = 0L
                    while (true) {
                        val r = input.read(buf)
                        if (r < 0) break
                        n += r
                        if (n > CacheWorker.MAX_BODY) { c.disconnect(); break }
                    }
                }
            } catch (e: Exception) { c.disconnect() }
        }
    }
}

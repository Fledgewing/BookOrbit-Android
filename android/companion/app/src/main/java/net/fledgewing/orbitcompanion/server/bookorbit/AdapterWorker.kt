package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*

import android.content.Context
import android.content.Intent
import android.os.Environment
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * The cache worker's Android side (docs/design/companion-worker.md): the plugin's MIRROR and CHECK
 * broadcasts (android/docs/INTERFACE.md) land here and run on one worker thread, checks first
 * (a mirror run answers waiting checks between its jobs). Needs no service: the receiver starts the
 * thread. The BookOrbit login comes with each broadcast and is held in memory only, never written
 * or logged.
 */
object AdapterWorker : ServerRuntime {
    const val ACTION_MIRROR = "${Contract.PACKAGE}.action.MIRROR"
    const val ACTION_CHECK = "${Contract.PACKAGE}.action.CHECK"
    const val ACTION_STORAGE = "${Contract.PACKAGE}.action.STORAGE"
    const val ACTION_COPIES = "${Contract.PACKAGE}.action.COPIES"
    const val ACTION_SLEEP_REFRESH = "${Contract.PACKAGE}.action.SLEEP_REFRESH"
    const val ACTION_RECHECK = "${Contract.PACKAGE}.action.RECHECK"
    /** The shared-storage stress test's writer (docs/design/sqlite-cache.md "Stress test"); no login. */
    const val ACTION_SQLITE_STRESS = "${Contract.PACKAGE}.action.SQLITE_STRESS"
    /** A write the plugin made, to patch into the saved replies (or a wipe); no login. */
    const val ACTION_PATCH = "${Contract.PACKAGE}.action.PATCH"

    /** The cap the plugin needs before it hands work over (ModeLogic.BASE). */
    const val CAP = "cache_worker"

    fun root(): File = File(Environment.getExternalStorageDirectory(), "koreader/settings/orbit-cache")

    private val lock = Object()
    private val checks = ArrayDeque<CacheWorker.Check>()
    private val patches = ArrayDeque<() -> Unit>()
    private var pending: Pair<CacheWorker.Plan, CacheWorker.Creds>? = null
    private var storage: CacheWorker.StorageAsk? = null
    private var sleep: Pair<String, SleepPoolBuilder.Ask>? = null
    private var pickers: Pair<String, CacheWorker.Creds>? = null
    private var recheck: Triple<String, CacheWorker.Creds, List<Pair<Long, String>>>? = null
    @Volatile private var app: Context? = null
    private var running = false

    @Volatile
    override var mirrorRunning = false
        private set

    /** Work in hand: an automatic Wi-Fi off waits for it. */
    override fun busy(): Boolean = mirrorRunning || synchronized(lock) { checks.isNotEmpty() || patches.isNotEmpty() || pending != null || storage != null || sleep != null || pickers != null || recheck != null }

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

    /** Invalidate normalized views after a private account command, using the existing writer queue. */
    override fun localCommand(ctx: Context, op: String, args: Map<*, *>, done: (Map<String, Any?>?, String?) -> Unit) {
        app = ctx.applicationContext
        synchronized(lock) { patches.addLast {
            try {
                val store = worker().store
                val owner = store.meta("owner") ?: throw IllegalArgumentException("owner")
                val storage = DeviceStorage(store, ServerAdapters.forStore(store))
                val result = storage.command(owner,op,args)
                val requests=store.db().query("SELECT request FROM library_views WHERE owner=?",LuaValue.utf8(owner)) { it.text(0)!! }
                    .filter { raw -> (LuaValue.parse(raw.toByteArray(Charsets.ISO_8859_1)) as? Map<*,*>)?.get("op") in setOf("storage.summary","library.summary","window","book","reader") }
                val model=LibraryReadModel(store)
                requests.chunked(LibraryReadModel.MAX_BATCH).forEach { model.publish(owner,it) }
                worker().event(mapOf("kind" to "library", "owner" to owner))
                done(result,null)
            } catch (_: Exception) { done(null,"unavailable") }
        }; lock.notifyAll() }
        start()
    }

    override fun accountChanged(ctx: Context) {
        app = ctx.applicationContext
        synchronized(lock) { patches.addLast {
            LibraryAccount.owner()?.let { worker().store.own(it) }
            worker().store.db().exec("DELETE FROM library_views")
            worker().event(mapOf("kind" to "account"))
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
        if (i.action in setOf(ACTION_MIRROR, ACTION_CHECK, ACTION_RECHECK)) LibraryAccount.refresh(ctx)
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
                i.getStringExtra("cover_dir")?.takeIf { it.isNotEmpty() }, i.getStringExtra("mirror_covers") == "1")
            synchronized(lock) { storage = a; lock.notifyAll() }
            return start()
        }
        if (i.action == ACTION_PATCH && i.hasExtra("plugin_state")) {
            val state = i.getStringExtra("plugin_state") ?: return
            synchronized(lock) { patches.addLast { worker().savePluginState(LuaValue.str(state)) }; lock.notifyAll() }
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
        if (i.action == ACTION_PATCH && i.hasExtra("remember_id")) {
            val id = i.getStringExtra("remember_id")?.toLongOrNull() ?: return
            synchronized(lock) { patches.addLast { worker().rememberDetail(id) }; lock.notifyAll() }
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
        if (i.action == ACTION_PATCH && i.hasExtra("old_hash")) {
            val old = i.getStringExtra("old_hash") ?: return
            val new = i.getStringExtra("new_hash") ?: return
            val path = i.getStringExtra("copy_path")
            synchronized(lock) { patches.addLast {
                HashSidecar.carry(File(root().parentFile?.parentFile, "hashdocsettings"), old, new, BulkWork::checkpoint)
                if (path != null) worker().carryCopySettings(path, old, new)
            }; lock.notifyAll() }
            return start()
        }
        if (i.action == ACTION_PATCH && i.getStringExtra("drain_events") == "1") {
            val ack = i.getStringExtra("events_ack")
            synchronized(lock) { patches.addLast { worker().drainEvents(ack) }; lock.notifyAll() }
            return start()
        }
        if (i.action == ACTION_PATCH) {
            // The database only, no login; in order with the checks.
            val wipe = i.getStringExtra("wipe") == "1"
            val id = i.getStringExtra("id")?.toLongOrNull()
            val fields = i.getStringExtra("fields")?.takeIf { it.isNotEmpty() }?.let { runCatching { LuaValue.parse(LuaValue.str(it).toByteArray(Charsets.ISO_8859_1)) }.getOrNull() } as? Map<*, *>
            val staleHome = i.getStringExtra("stale_home") == "1"
            synchronized(lock) { patches.addLast { worker().patch(id, fields ?: emptyMap<Any?, Any?>(), staleHome, wipe) }; lock.notifyAll() }
            return start()
        }
        if (i.action == ACTION_COPIES) {
            val prepare = i.getStringExtra("prepare")
            val ask = i.getStringExtra("ask")
            val reason = i.getStringExtra("reason") ?: "plugin"
            val credentials = creds(i)
            val template = i.getStringExtra("template")
            synchronized(lock) {
                patches.addLast {
                    if (prepare != null && credentials != null && template != null) {
                        val job = LuaValue.parse(LuaValue.str(prepare).toByteArray(Charsets.ISO_8859_1)) as? Map<*, *> ?: return@addLast
                        worker().prepareCopy(job, template, credentials)
                    } else {
                        if (ask != null) {
                            val file = File(root(), "copies/ask.lua")
                            file.parentFile?.mkdirs()
                            file.writeBytes(LuaValue.str(ask).toByteArray(Charsets.ISO_8859_1))
                        }
                        worker().copies(reason)
                    }
                }
                lock.notifyAll()
            }
            return start()
        }

        app = ctx.applicationContext
        val creds = creds(i)
        if (creds == null) {
            OLog.w("worker: ${Contract.shortName(i.action)} without a BookOrbit login; ignored")
            return
        }
        when (i.action) {
            ACTION_CHECK -> {
                val key = i.getStringExtra("cache_key") ?: return
                val path = i.getStringExtra("path") ?: return
                val c = CacheWorker.Check(LuaValue.str(key), LuaValue.str(path), i.getStringExtra("mode") ?: "open", creds,
                    LuaValue.str(i.getStringExtra("owner") ?: ""), i.getStringExtra("template")?.takeIf { it.isNotEmpty() }?.let { LuaValue.str(it) })
                synchronized(lock) { checks.addLast(c); lock.notifyAll() }
            }
            ACTION_SLEEP_REFRESH -> if (i.getStringExtra("scopes_only") == "1") {
                // The pickers' lists only (Pick from, Leave out and its tags); never a pool build.
                synchronized(lock) { pickers = (i.getStringExtra("reason") ?: "picker") to creds; lock.notifyAll() }
            } else {
                val a = SleepPoolBuilder.Ask(i.getStringExtra("from") ?: "", SleepPoolLogic.rules(i.getStringExtra("rules")),
                    i.getStringExtra("open_id")?.toLongOrNull(), i.getStringExtra("every") == "1", i.getStringExtra("storage_limit_mb")?.toLongOrNull(), creds)
                synchronized(lock) { sleep = (i.getStringExtra("reason") ?: "plugin") to a; lock.notifyAll() }
            }
            ACTION_RECHECK -> {
                val ids = (i.getStringExtra("ids") ?: "").split('\n')
                val paths = (i.getStringExtra("paths") ?: "").split('\n')
                val items = ids.zip(paths).mapNotNull { (id, p) -> id.toLongOrNull()?.takeIf { p.isNotEmpty() }?.let { it to p } }
                synchronized(lock) { recheck = Triple(i.getStringExtra("reason") ?: "plugin", creds, items); lock.notifyAll() }
            }
            ACTION_MIRROR -> {
                val encoded = i.getStringExtra("plan") ?: return
                synchronized(lock) {
                    patches.addLast {
                        BulkWork.checkpoint()
                        val bytes = LuaValue.str(encoded).toByteArray(Charsets.ISO_8859_1)
                        val m = LuaValue.parse(bytes) as? Map<*, *> ?: return@addLast
                        val plan = CacheWorker.Plan(m)
                        OLog.i("worker: mirror ${plan.op} (${plan.reason}) run ${plan.run}")
                        val f = File(root(), "mirror/plan.lua")
                        f.parentFile?.mkdirs()
                        // A replacement must stop the current run before the next
                        // one clears this flag in loop().
                        if (mirrorRunning) File(root(), "mirror/stop").writeText("stop")
                        val tmp = File(f.path + ".tmp")
                        tmp.writeBytes(bytes); check(tmp.renameTo(f))
                        synchronized(lock) { pending = plan to creds; lock.notifyAll() }
                    }
                    lock.notifyAll()
                }
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
        val rc = synchronized(lock) { recheck.also { recheck = null } }
        if (rc != null) try { worker().recheckCovers(rc.first, rc.second, rc.third) } catch (e: Exception) {
            OLog.w("worker: cover recheck failed", e)
            worker().event(sortedMapOf("kind" to "covers_rechecked", "why" to rc.first, "err" to e.javaClass.simpleName))
        }
        val sp = synchronized(lock) { sleep.also { sleep = null } }
        if (sp != null) sleepPool(sp.first, sp.second)
        val pk = synchronized(lock) { pickers.also { pickers = null } }
        if (pk != null) pickers(pk.first, pk.second)
        while (true) {
            val pt = synchronized(lock) { patches.removeFirstOrNull() } ?: break
            try { pt() } catch (e: Exception) { OLog.w("worker: patch failed", e) }
        }
        while (true) {
            val c = synchronized(lock) { checks.removeFirstOrNull() } ?: return
            try { worker().check(c) } catch (e: Exception) { OLog.w("worker: check failed", e) }
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
                if (checks.isEmpty() && patches.isEmpty() && pending == null && storage == null && sleep == null && pickers == null && recheck == null) { return }
                pending.also { pending = null }
            } ?: continue
            File(root(), "mirror/stop").delete()
            progress = 0
            manualRefresh = p.first.m["manual"] == true
            mirrorRunning = true
            try {
                val why = BulkWork.phase("mirror") { worker().run(p.first, p.second) { drainChecks() } }
                OLog.i("worker: mirror run ${p.first.run} ended: $why")
            } catch (e: Exception) {
                OLog.w("worker: mirror run failed", e)
            } finally {
                mirrorRunning = false
                progress = null
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

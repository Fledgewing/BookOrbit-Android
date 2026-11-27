package net.fledgewing.orbitcompanion

import android.content.Context
import android.content.Intent
import android.os.Environment
import java.io.File

interface ServerRuntime {
    fun localCommand(ctx: Context, op: String, args: Map<*, *>, done: (Map<String, Any?>?, String?) -> Unit) { done(null,"unsupported") }
    fun accountChanged(ctx: Context)
    fun busy(): Boolean
    val mirrorRunning: Boolean
    fun progressLine(): String?
    fun onIntent(ctx: Context, i: Intent)
    fun nativeFooterRepair(before: String, after: String, token: String)
}

/** Command routing only. The selected adapter owns transport and all legacy protocol state. */
object Worker {
    const val ACTION_STORAGE = "${Contract.PACKAGE}.action.STORAGE"
    const val ACTION_COPIES = "${Contract.PACKAGE}.action.COPIES"
    const val ACTION_SLEEP_REFRESH = "${Contract.PACKAGE}.action.SLEEP_REFRESH"
    const val ACTION_SQLITE_STRESS = "${Contract.PACKAGE}.action.SQLITE_STRESS"
    const val ACTION_PATCH = "${Contract.PACKAGE}.action.PATCH"
    const val CAP = "cache_worker"
    fun localCommand(ctx: Context, op: String, args: Map<*, *>, done: (Map<String, Any?>?, String?) -> Unit) = ServerAdapters.runtime.localCommand(ctx,op,args,done)
    internal fun accountChanged(ctx: Context) = ServerAdapters.runtime.accountChanged(ctx)
    fun root() = File(Environment.getExternalStorageDirectory(), "koreader/settings/orbit-cache")
    fun busy() = ServerAdapters.runtime.busy()
    val mirrorRunning get() = ServerAdapters.runtime.mirrorRunning
    fun progressLine() = ServerAdapters.runtime.progressLine()
    fun onIntent(ctx: Context, i: Intent) {
        if (i.action == ACTION_PATCH && i.getStringExtra("owner") == DeviceLibrary.OWNER && i.hasExtra("library_batch")) {
            val encoded=i.getStringExtra("library_batch")?.takeIf { it.length<=131072 } ?: return
            val app=ctx.applicationContext
            BulkWork.attach(app)
            BulkWork.executor.execute {
                runCatching {
                    val requests=LuaValue.parse(LuaValue.str(encoded).toByteArray(Charsets.ISO_8859_1)) as? List<*> ?: return@runCatching
                    ServerAdapters.projectionStore(root()).use { store ->
                        val model=LibraryReadModel(store,readingStats={
                            ReadingStats.read(File(root().parentFile,"statistics.sqlite3"),System.currentTimeMillis()/1000)
                        },battery={ StatsStore.get(app).batterySnapshot(System.currentTimeMillis(),java.time.ZoneId.systemDefault()) })
                        if(model.publish(DeviceLibrary.OWNER,requests)) {
                            val spool=File(root(),"events").apply { mkdirs() }
                            val file=File(spool,"device-${java.util.UUID.randomUUID()}.lua")
                            android.util.AtomicFile(file).let { atomic ->
                                val out=atomic.startWrite()
                                try { out.write(LuaValue.encode(mapOf("kind" to "library","owner" to DeviceLibrary.OWNER))); atomic.finishWrite(out) }
                                catch(e: Exception) { atomic.failWrite(out); throw e }
                            }
                            ServerAdapters.runtime.onIntent(app,Intent(ACTION_PATCH).putExtra("drain_events","1"))
                        }
                    }
                }.onFailure { OLog.w("library.device publication unavailable") }
            }
        } else ServerAdapters.runtime.onIntent(ctx,i)
    }
    internal fun nativeFooterRepair(before: String, after: String, token: String) = ServerAdapters.runtime.nativeFooterRepair(before, after, token)
}

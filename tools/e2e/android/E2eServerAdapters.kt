// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import android.content.Context
import android.content.Intent
import java.io.File

/** Compiled only in the disposable emulator build. Never added to app source sets. */
object ServerAdapters {
    private var context: Context? = null
    private val root get() = Worker.root()
    private val books get() = DeviceLibrary(listOf(File(android.os.Environment.getExternalStorageDirectory(), "Books")))
    private val prefs get() = requireNotNull(context).getSharedPreferences("e2e", Context.MODE_PRIVATE)
    private val signedIn get() = context != null && prefs.getBoolean("signedIn", false)
    private const val OWNER = "emulator-fixture"
    private val adapter = object : ServerAdapter {
        override val id = "fixture"
        override fun owner() = OWNER.takeIf { signedIn }
        override fun state(): Map<String, Any?> = mapOf("signedIn" to signedIn, "owner" to owner(), "username" to "reader", "server" to "https://fixture.example.test",
            "account" to mapOf("set" to signedIn, "origin" to "user"),
            "sync" to mapOf("set" to signedIn, "available" to signedIn, "origin" to "account"),
            "opds" to mapOf("set" to signedIn, "available" to signedIn, "origin" to "account"),
            "catalog" to mapOf("canRefresh" to signedIn))
        override fun signIn(server: String, username: String, password: CharArray) {
            try {
                if (server != "https://fixture.example.test" || username != "reader" || String(password) != "fixture") throw ServerFailure("unauthorized")
                prefs.edit().putBoolean("signedIn", true).commit()
            } finally { password.fill('\u0000') }
        }
        override fun signOut() { prefs.edit().putBoolean("signedIn", false).commit() }
        override fun project(owner: String, request: Map<*, *>): Map<String, Any?> {
            if(request["op"]=="capabilities") return books.capabilities(DeviceLibrary.OWNER)+mapOf("lists" to mapOf("read" to true,"save" to false))
            if(request["op"]=="lists") return mapOf("items" to listOf(mapOf("key" to "fixture-list","title" to "Fixture shelf","count" to 59)),"freshness" to mapOf("saved" to true))
            return books.project(DeviceLibrary.OWNER, request)
        }
        override fun personalCatalog(owner: String) = books.personalCatalog(DeviceLibrary.OWNER)
        override fun localFiles(owner: String) = books.localFiles(DeviceLibrary.OWNER)
        override fun catalogControl(owner: String, action: String, manual: Boolean, done: (Map<String, Any?>?, String?) -> Unit) {
            done(mapOf("state" to "complete", "freshness" to mapOf("saved" to true)), null)
        }
        override fun captureLifecycle(capture: Map<*, *>): Pair<String, ByteArray> =
            "fixture-document" to LuaValue.encode(mapOf("percentage" to capture["percentage"], "position" to capture["position"], "capturedAt" to System.currentTimeMillis()/1000))
        override fun position(document: String, update: Map<String, Any?>?): Map<String, Any?> {
            val file=File(requireNotNull(context).filesDir,"e2e-position.lua")
            if(update!=null) file.writeBytes(LuaValue.encode(update))
            @Suppress("UNCHECKED_CAST")
            return if(file.isFile) LuaValue.parse(file.readBytes()) as Map<String,Any?> else mapOf("percentage" to 0.5,"label" to "Fixture tablet","timestamp" to System.currentTimeMillis()/1000)
        }
        override fun lifecyclePhase(entry: LifecycleQueue.Entry, phase: String, checkpoint: ByteArray, openPath: String?) = SyncPhaseResult(checkpoint)
    }
    fun session(ctx: Context, id: String = "fixture"): ServerAdapter { context=ctx.applicationContext; return adapter }
    fun forStore(store: ProjectionStore, id: String = "fixture", clock: () -> Long = { System.currentTimeMillis()/1000 },
        fallbackReadingStats: ((String) -> RemoteReadingStats?)? = null,
        accountState: () -> Map<String, Any?> = { emptyMap() }, accountStats: (String) -> Map<*, *>? = { null }): ServerAdapter = adapter
    fun projectionStore(root: File) = ShippingServerAdapters.projectionStore(root)
    val connector get() = ShippingServerAdapters.connector
    val cachedLists get() = ShippingServerAdapters.cachedLists
    val covers get() = ShippingServerAdapters.covers
    val runtime = object : ServerRuntime {
        override fun accountChanged(ctx: Context) {
            context=ctx.applicationContext
            BulkWork.executor.execute {
                projectionStore(root).use { store ->
                    store.db().exec("INSERT OR REPLACE INTO meta(k,v) VALUES ('owner',?)", OWNER)
                }
                event()
            }
        }
        override fun busy() = false
        override val mirrorRunning = false
        override fun progressLine(): String? = null
        override fun nativeFooterRepair(before: String, after: String, token: String) {}
        override fun onIntent(ctx: Context, i: Intent) {
            context=ctx.applicationContext
            val raw=i.getStringExtra("library_batch") ?: return
            val owner=i.getStringExtra("owner") ?: return
            BulkWork.executor.execute {
                runCatching {
                    val requests=LuaValue.parse(LuaValue.str(raw).toByteArray(Charsets.ISO_8859_1)) as List<*>
                    projectionStore(root).use { store ->
                        store.db().exec("INSERT OR REPLACE INTO meta(k,v) VALUES ('owner',?)", OWNER)
                        LibraryReadModel(store, adapter=adapter).publish(owner,requests)
                    }
                    event()
                }.onFailure { OLog.w("emulator fixture projection failed",it) }
            }
        }
    }
    private fun event() {
        root.mkdirs()
        File(root,"events-batch.lua").writeBytes(LuaValue.encode(mapOf("id" to java.util.UUID.randomUUID().toString(),
            "events" to listOf(mapOf("kind" to "library", "owner" to OWNER)))))
    }
}

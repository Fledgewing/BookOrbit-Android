package net.fledgewing.orbitcompanion

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import java.util.concurrent.Executors

/** Device-local settings, shared by the owned reader and the worker projection. */
object DeviceSettings {
    private var app: Context? = null
    internal var work: java.util.concurrent.Executor = Executors.newSingleThreadExecutor()
    internal var canWrite: (Context) -> Boolean = Settings.System::canWrite
    @Volatile private var state: Map<String, Any?> = mapOf("reader" to "Loading…", "sleep_label" to "Loading…", "pending" to true, "unavailable" to true, "writable" to false)
    fun initialize(ctx: Context) {
        app = ctx.applicationContext
        work.execute { refresh() }
    }
    private fun refresh() {
        val ctx = app ?: return
        val start=System.nanoTime()
        val ms = Settings.System.getInt(ctx.contentResolver, Settings.System.SCREEN_OFF_TIMEOUT, 600000)
        state = mapOf("reader" to Build.MODEL.take(80), "sleep_ms" to ms,
            "sleep_label" to if (ms == Int.MAX_VALUE) "Never" else "${ms / 60000} min idle",
            "writable" to canWrite(ctx))
        OLog.i("library settings-device ms=${(System.nanoTime()-start)/1_000_000} rows=1 bytes=${LuaValue.encode(state).size}")
    }
    fun snapshot(): Map<String, Any?> = state
    fun refreshAsync() { work.execute { refresh() } }
    fun sleep(ctx: Context, ms: Int, done: (String?) -> Unit) {
        require(ms in listOf(300000,600000,900000,1800000,Int.MAX_VALUE))
        app = ctx.applicationContext
        if (!canWrite(ctx)) {
            ctx.startActivity(Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, Uri.parse("package:${ctx.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            done("permission"); return
        }
        work.execute {
            val error = runCatching {
                check(Settings.System.putInt(ctx.contentResolver, Settings.System.SCREEN_OFF_TIMEOUT, ms))
                refresh()
            }.exceptionOrNull()?.let { "unavailable" }
            done(error)
        }
    }
}

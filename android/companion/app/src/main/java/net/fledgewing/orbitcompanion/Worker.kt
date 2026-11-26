package net.fledgewing.orbitcompanion

import android.content.Context
import android.content.Intent
import android.os.Environment
import java.io.File

interface ServerRuntime {
    fun accountChanged(ctx: Context)
    fun busy(): Boolean
    val mirrorRunning: Boolean
    fun progressLine(): String?
    fun onIntent(ctx: Context, i: Intent)
    fun nativeFooterRepair(before: String, after: String, token: String)
}

/** Command routing only. The selected adapter owns transport and all legacy protocol state. */
object Worker {
    const val ACTION_MIRROR = "${Contract.PACKAGE}.action.MIRROR"
    const val ACTION_CHECK = "${Contract.PACKAGE}.action.CHECK"
    const val ACTION_STORAGE = "${Contract.PACKAGE}.action.STORAGE"
    const val ACTION_COPIES = "${Contract.PACKAGE}.action.COPIES"
    const val ACTION_SLEEP_REFRESH = "${Contract.PACKAGE}.action.SLEEP_REFRESH"
    const val ACTION_SQLITE_STRESS = "${Contract.PACKAGE}.action.SQLITE_STRESS"
    const val ACTION_PATCH = "${Contract.PACKAGE}.action.PATCH"
    const val CAP = "cache_worker"
    internal fun accountChanged(ctx: Context) = ServerAdapters.runtime.accountChanged(ctx)
    fun root() = File(Environment.getExternalStorageDirectory(), "koreader/settings/orbit-cache")
    fun busy() = ServerAdapters.runtime.busy()
    val mirrorRunning get() = ServerAdapters.runtime.mirrorRunning
    fun progressLine() = ServerAdapters.runtime.progressLine()
    fun onIntent(ctx: Context, i: Intent) = ServerAdapters.runtime.onIntent(ctx, i)
    internal fun nativeFooterRepair(before: String, after: String, token: String) = ServerAdapters.runtime.nativeFooterRepair(before, after, token)
}

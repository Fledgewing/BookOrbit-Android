package net.fledgewing.orbitcompanion

import android.content.Context
import android.content.Intent
import android.app.admin.DevicePolicyManager
import android.os.Handler
import android.os.Looper

/** Local reader interface. No catalog, credential, network or checklist scan on a sheet read. */
object ReaderCompanion {
    const val SNAPSHOT = "${Contract.PACKAGE}.call.READER_COMPANION"
    private val main by lazy { Handler(Looper.getMainLooper()) }

    fun snapshot(ctx: Context): Map<String, Any?> {
        val start = System.nanoTime()
        val p = Prefs(ctx)
        val addon = Mode.isAddon(ctx)
        val admin = Net.adminActive(ctx)
        val observed=System.currentTimeMillis()
        fun freshness(at: Long) = when {
            at<=0L || at>observed -> "freshness unknown"
            observed-at>86_400_000L -> "stale"
            else -> "saved result"
        }
        val helpers = listOf(
            mapOf("id" to "wifi", "label" to "Wi-Fi switching", "on" to (!addon || p.helperWifi),
                "mutable" to addon, "detail" to "BookSync can connect when asked"),
            mapOf("id" to "sleep", "label" to "Sleep sync", "on" to (!addon || p.helperSleepSync),
                "mutable" to addon, "detail" to "Save and send before sleep"),
            mapOf("id" to "screen", "label" to "Screen off after sync", "on" to (!addon || p.helperScreenOff),
                "mutable" to (addon && p.helperSleepSync), "permission" to admin,
                "detail" to if (addon && !p.helperSleepSync) "Sleep sync is off; ${if (admin) "permission available" else "permission needed"}"
                    else if (admin) "Permission available" else "Android permission needed to turn the screen off"),
        )
        val result = mapOf("mode" to if (addon) "add-on" else "full", "protected" to Pin.locked(ctx),
            "helpers" to helpers, "sync" to LuaValue.str(if (p.lastSleepSyncAt == 0L) "Last sleep sync: unknown · your place stays saved on this reader" else "Last sleep sync: ${if (p.lastSleepSyncOk) "sent" else "delivery pending"} · ${freshness(p.lastSleepSyncAt)} at ${Ui.clock(ctx,p.lastSleepSyncAt)}"),
            "setup" to LuaValue.str(if (p.setupPromptKey.isEmpty()) "Setup: unknown" else "Setup: ${p.setupNeeded} ${if (p.setupNeeded == 1) "thing needs" else "things need"} you · saved checklist, freshness unknown"),
            "updates" to LuaValue.boundedText(if (p.updateStatusAt > 0L) "Updates: ${freshness(p.updateStatusAt)} · ${p.updateStatus.ifBlank { "unknown" }}"
                else "Updates: unknown",256),
            "observed" to observed)
        check(LuaValue.encode(result).size <= 16384)
        OLog.i("library reader-companion ms=${(System.nanoTime()-start)/1_000_000} rows=4")
        return result
    }

    /** Recheck protection and permission at execution time. A permission action never sets a helper. */
    fun command(ctx: Context, args: Map<*, *>, done: (Map<String, Any?>?, String?) -> Unit) {
        val action = args["action"] as? String
        val helper = args["helper"] as? String
        val on = args["on"] as? Boolean
        main.post {
            val error = runCatching {
                when (action) {
                    "set" -> {
                        if (Pin.locked(ctx)) { done(null, "protected"); return@post }
                        if (!Mode.isAddon(ctx)) { done(null, "mode"); return@post }
                        require(on != null)
                        val p = Prefs(ctx)
                        if (helper == "screen" && on && !p.helperSleepSync) { done(null, "dependency"); return@post }
                        if (helper == "screen" && on && !Net.adminActive(ctx)) { done(null, "permission"); return@post }
                        when (helper) {
                            "wifi" -> p.helperWifi = on
                            "sleep" -> p.helperSleepSync = on
                            "screen" -> p.helperScreenOff = on
                            else -> throw IllegalArgumentException("helper")
                        }
                        Mode.helpersChanged(ctx, "reader helper")
                    }
                    else -> throw IllegalArgumentException("action")
                }
            }.exceptionOrNull()
            done(if (error == null) mapOf("ok" to true) else null, if (error != null) "unavailable" else null)
        }
    }
    /** Only a foreground activity may request Android's device-admin consent. No NEW_TASK on its child. */
    fun systemIntent(ctx: Context, action: String?): Intent? = when (action) {
        "permission" -> if (Pin.locked(ctx)) SettingsPage.section(ctx,"sync") else
            Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                .putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN,AdminReceiver.component(ctx))
                .putExtra(DevicePolicyManager.EXTRA_ADD_EXPLANATION,"Lets Sync and sleep turn the screen off after syncing.")
        "protected" -> SettingsPage.section(ctx,"sync")
        "recovery" -> Intent(ctx,StatusActivity::class.java)
        "setup" -> Intent(ctx,SetupActivity::class.java)
        else -> null
    }

}

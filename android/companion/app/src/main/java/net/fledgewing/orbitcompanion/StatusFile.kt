package net.fledgewing.orbitcompanion

import android.content.Context
import android.content.Intent
import android.os.Environment
import java.io.File

/**
 * koreader/settings/orbit-companion.json (docs/design/addon-mode.md §6.2): the companion's mode,
 * caps and setup prompt for the Orbit plugin, readable when no service answers on loopback.
 * Written by rename (never half a file), only when its content changed. Also keeps the plugin's
 * REPORT (§7.3), which arrives without the service.
 */
object StatusFile {
    @Volatile private var lastBody = ""
    @Volatile private var failedLogged = false

    fun file(): File = File(Environment.getExternalStorageDirectory(), "koreader/settings/orbit-companion.json")

    fun caps(ctx: Context): List<String> = Mode.caps(ctx)

    fun write(ctx: Context, why: String) {
        val p = Prefs(ctx)
        val body = ModeLogic.statusFileBody(BuildConfig.VERSION_NAME, p.mode, caps(ctx), p.setupPromptKey, p.setupPromptRows) +
            ",\"setup_needed\":${p.setupNeeded}" +
            ",\"app_update\":${Updater.readySummary(ctx)?.let(ModeLogic::str) ?: "null"}" +
            // The sleep screen's settings, for a plugin with no /status to ask (Add-on, docs/design/lock-screen.md A2).
            ",\"settings\":{${SleepScreen.settingsJson(ctx)},\"settings_at\":${p.sharedSettingsAt},\"values\":${SettingsStore.valuesJson(ctx)}}" +
            ",\"sleep\":${SleepScreen.statusJson(ctx)},\"want_choices\":${p.wantChoicesAt}"
        if (body == lastBody) return
        val f = file()
        val ok = runCatching {
            val dir = f.parentFile ?: return
            // Only into a KOReader that exists: koreader/ is KOReader's, the plugin reads this there.
            if (!dir.isDirectory && !(File(dir.parentFile, "plugins").isDirectory && dir.mkdirs())) return
            val tmp = File(dir, f.name + ".orbit-new")
            tmp.writeText(ModeLogic.statusFile(body, System.currentTimeMillis()))
            if (!tmp.renameTo(f)) {
                tmp.delete()
                error("rename failed")
            }
        }
        ok.onSuccess {
            lastBody = body
            failedLogged = false
            OLog.i("status file written ($why): mode ${ModeLogic.effective(p.mode).key}")
        }.onFailure { e ->
            if (!failedLogged) {
                failedLogged = true
                OLog.w("status file not written ($why); the plugin uses /status", e)
            }
        }
    }

    /** REPORT from the plugin: keep only the three fields, then re-evaluate Setup. */
    fun onReport(ctx: Context, intent: Intent) {
        val p = Prefs(ctx)
        val signed = PluginReport.signedIn(intent.getStringExtra("signed_in"))
        val rec = PluginReport.recommended(intent.getStringExtra("recommended"))
        val conflicts = PluginReport.conflicts(intent.getStringExtra("conflicts"))
        if (intent.getStringExtra("sender") == Contract.PATCH_SENDER) {
            p.patchSeenAt = System.currentTimeMillis()
            p.patchSeenVia = "REPORT"
        }
        val changed = signed != p.reportSignedIn || rec != p.reportRecommended || conflicts != p.reportConflicts
        p.reportSignedIn = signed
        p.reportRecommended = rec
        p.reportConflicts = conflicts
        p.reportAt = System.currentTimeMillis()
        OLog.i("REPORT signed_in=${signed.ifEmpty { "?" }} recommended=${rec.ifEmpty { "?" }} conflicts=$conflicts (${intent.getStringExtra("reason") ?: "-"})${if (changed) "" else ", unchanged"}")
        if (changed) Attention.evaluate(ctx.applicationContext, "plugin report")
    }
}

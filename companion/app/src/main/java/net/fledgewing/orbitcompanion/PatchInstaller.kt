package net.fledgewing.orbitcompanion

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.File
import kotlin.concurrent.thread

/**
 * One-tap install of the KOReader patch: 2-orbit-android.lua from the release matching this
 * app (latest for a dev build), SHA-256 checked against SHA256SUMS, written as .new and
 * renamed into <shared storage>/koreader/patches/.
 *
 * Storage: the companion targets SDK 28, below scoped storage (which applies from target 29;
 * developer.android.com/training/data-storage#scoped-storage), so WRITE_EXTERNAL_STORAGE,
 * granted at run time, still gives direct file access on Android 14
 * (developer.android.com/reference/android/Manifest.permission#WRITE_EXTERNAL_STORAGE: it has
 * no effect only for apps targeting 33+). If the write still fails, Setup explains the copy.
 */
object PatchInstaller {
    const val REQUEST_CODE = 47
    @Volatile
    var busy = false
        private set
    private val main = Handler(Looper.getMainLooper())

    private fun log(msg: String) = OLog.i("patch install: $msg")

    @Suppress("DEPRECATION")
    fun dir(): File = File(Environment.getExternalStorageDirectory(), "koreader/patches")
    fun file(): File = File(dir(), PatchFile.NAME)

    /** PATCH_VERSION of the installed file, or null (missing or unreadable). */
    fun installedVersion(): String? = try {
        file().takeIf { it.isFile }?.readText()?.let { PatchFile.version(it) }
    } catch (e: Exception) {
        OLog.d("patch install: can't read ${file()}: ${e.javaClass.simpleName}")
        null
    }

    fun hasPermission(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < 23 ||
            ctx.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

    fun manualHint(): String =
        "copy ${PatchFile.NAME} from the release page to koreader/patches/ on the device (README \"Install\")"

    /** Asks for storage first if needed; the activity calls [install] again on the grant. */
    fun installFrom(a: Activity, done: (String) -> Unit) {
        if (!hasPermission(a)) {
            log("asking for storage permission")
            a.requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), REQUEST_CODE)
            return
        }
        install(a, done)
    }

    fun install(ctx: Context, done: (String) -> Unit) {
        if (busy) return
        busy = true
        val app = ctx.applicationContext
        thread(name = "orbit-patch-install", isDaemon = true) {
            var turnedOn = false
            val result = try {
                if (!Net.wifiConnected(app)) turnedOn = Updater.bringWifiUp(app)
                run()
            } catch (e: Exception) {
                OLog.w("patch install: failed", e)
                Updater.friendly(app, e)
            } finally {
                if (turnedOn) Net.setWifi(app, false, "patch install done, restoring off")
            }
            log("result: $result")
            val p = Prefs(app)
            p.patchInstallStatus = result
            busy = false
            main.post { done(result) }
        }
    }

    /** After the companion updated (Updater.onReplaced): the release's patch, then its restart. */
    fun afterAppUpdate(ctx: Context) {
        val app = BuildConfig.VERSION_NAME
        val file = installedVersion()
        if (!UpdateFlow.patchAfterUpdate(file, app)) {
            log("after the update: patch ${file ?: "not installed"}; nothing to do for v$app")
            return
        }
        if (!hasPermission(ctx)) {
            log("after the update: no storage access; left to Setup")
            Updater.status(ctx, UpdateFlow.manualLine(app, "storage access isn't allowed"))
            return
        }
        log("after the update: patch v$file is older than v$app; installing it")
        install(ctx) { result ->
            val now = installedVersion()
            val p = Prefs(ctx)
            if (now != null && !PatchFile.needsInstall(now, app)) {
                p.patchAwaitVersion = now
                Updater.status(ctx, UpdateFlow.installedLine(app, p.patchVersionSeen.ifEmpty { null }))
                onPatchSeen(ctx, p.patchVersionSeen.ifEmpty { null })
            } else {
                Updater.status(ctx, UpdateFlow.manualLine(app, result))
            }
        }
    }

    /** The running patch reported its version: the restart after an update is done. */
    fun onPatchSeen(ctx: Context, running: String?) {
        val p = Prefs(ctx)
        val want = p.patchAwaitVersion
        if (want.isEmpty() || !UpdateFlow.loaded(want, running)) return
        p.patchAwaitVersion = ""
        log("KOReader runs patch v$running now")
        Updater.status(ctx, UpdateFlow.doneLine(BuildConfig.VERSION_NAME))
    }

    private fun run(): String {
        val v = BuildConfig.VERSION_NAME
        val dev = Version.parse(v) == null || v.contains("dev")
        val url = if (dev) "${Updater.API}/releases/latest" else "${Updater.API}/releases/tags/v$v"
        log("fetching ${if (dev) "the latest release" else "release v$v"}")
        val rel = Updater.release(JSONObject(Updater.httpText(url)))
        val luaUrl = rel.assets[PatchFile.NAME] ?: return "${rel.tag} has no ${PatchFile.NAME}"
        val sumsUrl = rel.assets[UpdatePolicy.SUMS_NAME] ?: return "${rel.tag} has no ${UpdatePolicy.SUMS_NAME}"
        val expected = Checksums.parse(Updater.httpText(sumsUrl))[PatchFile.NAME]
            ?: return "${UpdatePolicy.SUMS_NAME} has no line for ${PatchFile.NAME}"
        val dir = dir()
        if (!dir.isDirectory && !dir.mkdirs()) {
            log("can't create $dir")
            return "can't write to storage: ${manualHint()}"
        }
        val tmp = File(dir, PatchFile.NAME + ".new")
        val sha = try {
            Updater.download(luaUrl, tmp)
        } catch (e: java.io.FileNotFoundException) {
            log("can't write $tmp: ${e.message}")
            return "can't write to storage: ${manualHint()}"
        }
        if (sha != expected) {
            tmp.delete()
            return "download failed its checksum; not installed"
        }
        val stamped = PatchFile.version(tmp.readText())
        if (!tmp.renameTo(file())) {
            tmp.delete()
            log("rename to ${file()} failed")
            return "can't write to storage: ${manualHint()}"
        }
        log("installed $stamped to ${file()} (sha256 ok)")
        return "installed v$stamped; restart KOReader to use it"
    }
}

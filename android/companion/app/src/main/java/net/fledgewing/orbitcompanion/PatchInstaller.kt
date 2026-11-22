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
        install(a, userStarted = true, done = done)
    }

    /** [userStarted]: the user asked for it (Setup, an update by hand): KOReader restarts at once, book or not. */
    fun install(ctx: Context, userStarted: Boolean = false, done: (String) -> Unit) {
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
            val stamped = installedVersion()
            if (result.startsWith("installed") && stamped != null) {
                p.patchAwaitVersion = stamped
                p.patchRestartNow = if (userStarted) stamped else ""
                Updater.status(app, UpdateFlow.installedLine(stamped))
            }
            busy = false
            if (result.startsWith("installed")) main.post {
                onPatchSeen(app, p.patchVersionSeen.ifEmpty { null })
                follow(app, "patch installed")
            }
            main.post { done(result) }
        }
    }

    /**
     * After the companion updated (Updater.onReplaced): the release's patch, then its restart.
     * [then] runs when that is done (Setup is evaluated only then: no prompt for a step in progress).
     */
    fun afterAppUpdate(ctx: Context, then: () -> Unit = {}) {
        val app = BuildConfig.VERSION_NAME
        val file = installedVersion()
        if (!UpdateFlow.patchAfterUpdate(file, app)) {
            // The file is current but KOReader still runs an older patch: the same restart now.
            val p = Prefs(ctx)
            val running = p.patchVersionSeen.ifEmpty { null }
            if (file != null && running != null && UpdateFlow.staleRestart(running, file, false, true, emptySet()) == UpdateFlow.Restart.NOW) {
                log("after the update: patch v$file on disk, KOReader runs v$running: restarting now")
                p.patchAwaitVersion = file
                p.patchRestartNow = file
                follow(ctx, "app updated")
            } else {
                log("after the update: patch ${file ?: "not installed"}; nothing to do for v$app")
            }
            return then()
        }
        if (!hasPermission(ctx)) {
            log("after the update: no storage access; left to Setup")
            Updater.status(ctx, UpdateFlow.manualLine(app, "storage access isn't allowed"))
            return then()
        }
        val p = Prefs(ctx)
        // An app replace is always user-confirmed (UpdateFlow.restartNowAfter): restart at once.
        val user = UpdateFlow.restartNowAfter(appReplaced = true, nowMs = System.currentTimeMillis(), markAtMs = p.userUpdateAt)
        p.userUpdateAt = 0
        log("after the update: patch v$file is older than v$app; installing it (you confirmed the app update: KOReader restarts now, the book reopens)")
        afterUpdateBusy = true
        install(ctx, userStarted = user) { result ->
            afterUpdateBusy = false
            val now = installedVersion()
            if (now == null || PatchFile.needsInstall(now, app)) Updater.status(ctx, UpdateFlow.manualLine(app, result))
            then()
        }
    }

    /** A patch install or restart is under way: Setup doesn't count the patch row as needed. */
    fun inProgress(ctx: Context): Boolean {
        val p = Prefs(ctx)
        val book = when (p.koreaderBook) { "1" -> true; "0" -> false; else -> null }
        return busy || UpdateFlow.restart(p.patchAwaitVersion, p.patchVersionSeen.ifEmpty { null }, p.patchRestartSentFor, book) != UpdateFlow.Restart.NONE
    }

    /** KOReader's book state changed (STATS, /status?book=): maybe the restart can go now. */
    fun onBook(ctx: Context, book: Boolean?, why: String) {
        if (book == null) return
        val p = Prefs(ctx)
        val v = if (book) "1" else "0"
        if (p.koreaderBook != v) p.koreaderBook = v
        if (!book) follow(ctx, why)
    }

    /**
     * The restart after a patch install (any patch version): COMMAND=restart now when KOReader
     * has no book open (or isn't running), else on the book's close, the next Home or screen-off.
     * The patch (0.5.0+) also restarts itself for a newer file; the two are one restart.
     */
    fun follow(ctx: Context, why: String, quiet: Boolean = true): Boolean {
        val p = Prefs(ctx)
        val want = p.patchAwaitVersion
        val book = when (p.koreaderBook) { "1" -> true; "0" -> false; else -> null }
        val now = want.isNotEmpty() && p.patchRestartNow == want
        return when (UpdateFlow.restart(want, p.patchVersionSeen.ifEmpty { null }, p.patchRestartSentFor, book, now)) {
            UpdateFlow.Restart.NONE -> followStale(ctx, p, book, why, quiet)
            UpdateFlow.Restart.WAIT -> {
                // Once per version, not on every event that checks.
                if (waitLogged != want) {
                    waitLogged = want
                    log("v$want installed; KOReader has a book open: restarting after it ($why)")
                }
                false
            }
            UpdateFlow.Restart.NOW -> {
                p.patchRestartSentFor = want
                p.restartReopen = if (book == true) "1" else ""
                log("v$want installed; restarting KOReader ($why)${if (book == true) "; you started the update: the book reopens where you were" else ""}")
                Koreader.restart(ctx.applicationContext, "patch v$want installed ($why)")
                true
            }
        }
    }

    private val stale = StaleRestart()
    @Volatile
    private var waitLogged: String? = null

    /** The patch install that follows an app update is running (Setup holds its prompts). */
    @Volatile
    var afterUpdateBusy = false
        private set
    private var cachedKey: Pair<Long, Long>? = null
    private var cachedVersion: String? = null

    /** [installedVersion], read again only when the file changed (it is checked on every /status). */
    @Synchronized
    fun installedVersionCached(): String? {
        val f = file()
        val key = try { f.lastModified() to f.length() } catch (e: Exception) { null }
        if (key == null || key.second == 0L) return installedVersion()
        if (key != cachedKey) {
            cachedVersion = installedVersion()
            cachedKey = key
        }
        return cachedVersion
    }

    /**
     * No install pending, but KOReader runs an older patch than the file (v0.5.4): restart once
     * per (running, file) pair in this process; with a book open, after it (UpdateFlow.staleRestart).
     */
    private fun followStale(ctx: Context, p: Prefs, book: Boolean?, why: String, quiet: Boolean): Boolean {
        val running = p.patchVersionSeen.ifEmpty { null } ?: return false
        val file = installedVersionCached() ?: return false
        if (stale.decide(running, file, book, quiet) { OLog.i("$it ($why)") } != UpdateFlow.Restart.NOW) return false
        Koreader.restart(ctx.applicationContext, "patch v$file on disk, v$running running ($why)")
        return true
    }

    /** The running patch reported its version: the restart after an install is done. */
    fun onPatchSeen(ctx: Context, running: String?) {
        val p = Prefs(ctx)
        val want = p.patchAwaitVersion
        if (want.isEmpty() || !UpdateFlow.loaded(want, running)) return
        p.patchAwaitVersion = ""
        p.patchRestartNow = ""
        log("KOReader runs patch v$running now")
        Updater.status(ctx, UpdateFlow.doneLine(want))
    }

    /** This version's release: tagged android-v<v> since Orbify, v<v> before it (and the v0.7.0 bridge). */
    private fun releaseText(v: String): String {
        var last: Exception? = null
        for (tag in ReleaseTags.forVersion(v)) {
            try {
                return Updater.httpText("${Updater.API}/releases/tags/$tag")
            } catch (e: java.io.IOException) {
                last = e
            }
        }
        throw last ?: java.io.IOException("no release for v$v")
    }

    private fun run(): String {
        val v = BuildConfig.VERSION_NAME
        val dev = Version.parse(v) == null || v.contains("dev")
        log("fetching ${if (dev) "the latest release" else "release v$v"}")
        val rel = Updater.release(JSONObject(if (dev) Updater.httpText("${Updater.API}/releases/latest") else releaseText(v)))
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
        return "installed v$stamped"
    }
}

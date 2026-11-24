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
 * One-tap install of the Orbit KOReader plugin: orbit.koplugin.zip from the release matching
 * this app (latest for a dev build), SHA-256 checked against SHA256SUMS, unpacked beside
 * <shared storage>/koreader/plugins/orbit.koplugin and swapped in for it (as Installers swaps the
 * BookOrbit plugin). The old user patch koreader/patches/2-orbit-android.lua (0.7.x and older)
 * is deleted: with both present the plugin stays off (docs/design/orbit-plugin.md).
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

    fun pluginDir(): File = File(Installers.pluginsDir(), PatchFile.PLUGIN)
    fun file(): File = File(pluginDir(), "main.lua")
    @Suppress("DEPRECATION")
    fun oldPatch(): File = File(Environment.getExternalStorageDirectory(), "koreader/patches/${PatchFile.OLD_PATCH}")

    /**
     * PATCH_VERSION on disk, or null (missing or unreadable): the plugin's main.lua, else the old
     * patch, so an app update over a 0.7.x patch installs the plugin like any patch update.
     */
    fun installedVersion(): String? = read(file()) ?: read(oldPatch())

    private fun read(f: File): String? = try {
        f.takeIf { it.isFile }?.readText()?.let { PatchFile.version(it) }
    } catch (e: Exception) {
        OLog.d("patch install: can't read $f: ${e.javaClass.simpleName}")
        null
    }

    fun hasPermission(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < 23 ||
            ctx.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

    fun manualHint(): String =
        "unzip ${PatchFile.ZIP} from the release page into koreader/plugins/ on the device (README \"Install\")"

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
                Updater.status(app, UpdateFlow.installedLine(stamped, now = userStarted))
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
            // The app replace was confirmed by the user (UpdateFlow.restartNowAfter): a manual restart.
            if (file != null && running != null && UpdateFlow.staleRestart(running, file, manual = true, screenOff = false, sent = emptySet()) == UpdateFlow.Restart.NOW) {
                // Started from one of our pages: the user is back on it; KOReader waits for the screen-off.
                val now = UpdateReturn.restartNow(userConfirmed = true, fromPage = UpdateReturn.fromPage())
                log("after the update: patch v$file on disk, KOReader runs v$running: restarting ${if (now) "now" else "at the next screen-off (started from our page)"}")
                p.patchAwaitVersion = file
                p.patchRestartNow = if (now) file else ""
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
        // From one of our pages (UpdateReturn): the user stays there; KOReader restarts at the next screen-off.
        val user = UpdateReturn.restartNow(
            UpdateFlow.restartNowAfter(appReplaced = true, nowMs = System.currentTimeMillis(), markAtMs = p.userUpdateAt),
            fromPage = UpdateReturn.fromPage(),
        )
        p.userUpdateAt = 0
        log("after the update: patch v$file is older than v$app; installing it (${if (user) "you confirmed the app update: KOReader restarts now, the book reopens" else "started from our page: KOReader restarts at the next screen-off"})")
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
        return busy || UpdateFlow.restart(p.patchAwaitVersion, p.patchVersionSeen.ifEmpty { null }, p.patchRestartSentFor, manual = false) != UpdateFlow.Restart.NONE
    }

    /** KOReader's book state changed (STATS, /status?book=): kept for the relaunch's reopen; a manual restart may go. */
    fun onBook(ctx: Context, book: Boolean?, why: String) {
        if (book == null) return
        val p = Prefs(ctx)
        val v = if (book) "1" else "0"
        if (p.koreaderBook != v) p.koreaderBook = v
        if (!book) follow(ctx, why)
    }

    /**
     * The restart after a patch install (any patch version), COMMAND=restart (UpdateFlow.restart):
     * at once when the user started the update, book open or not; after an automatic update
     * only when the screen goes off ([screenOff]), never while KOReader may be in front.
     * The patch (0.5.0+) also restarts itself for a newer file; the two are one restart.
     */
    fun follow(ctx: Context, why: String, screenOff: Boolean = false): Boolean {
        val p = Prefs(ctx)
        val want = p.patchAwaitVersion
        val book = when (p.koreaderBook) { "1" -> true; "0" -> false; else -> null }
        val manual = want.isNotEmpty() && p.patchRestartNow == want
        return when (UpdateFlow.restart(want, p.patchVersionSeen.ifEmpty { null }, p.patchRestartSentFor, manual, screenOff)) {
            UpdateFlow.Restart.NONE -> followStale(ctx, p, why, screenOff)
            UpdateFlow.Restart.WAIT -> {
                // Once per version, not on every event that checks.
                if (waitLogged != want) {
                    waitLogged = want
                    log("v$want installed automatically; KOReader restarts at the next screen-off ($why)")
                }
                false
            }
            UpdateFlow.Restart.NOW -> {
                p.patchRestartSentFor = want
                p.restartReopen = if (book == true) "1" else ""
                log("v$want installed; restarting KOReader ($why)${if (manual) "; you started the update" else ""}${if (book == true) "; the book reopens where you were" else ""}")
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
     * per (running, file) pair in this process, only at a screen-off (UpdateFlow.staleRestart).
     */
    private fun followStale(ctx: Context, p: Prefs, why: String, screenOff: Boolean): Boolean {
        val running = p.patchVersionSeen.ifEmpty { null } ?: return false
        val file = installedVersionCached() ?: return false
        if (stale.decide(running, file, manual = false, screenOff = screenOff) { OLog.i("$it ($why)") } != UpdateFlow.Restart.NOW) return false
        if (p.koreaderBook == "1") p.restartReopen = "1"
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

    /** This version's release: tagged v<v> (android-v<v> is read too, AGENTS.md "Releases"). */
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

    /** Unpacks [zip] into [to] (emptied first); null when done, else the status text. */
    private fun unpack(zip: File, to: File): String? {
        to.deleteRecursively()
        var files = 0
        java.util.zip.ZipInputStream(zip.inputStream().buffered()).use { zin ->
            while (true) {
                val e = zin.nextEntry ?: break
                val rel = PatchFile.zipMember(e.name) ?: return "unexpected file ${e.name} in ${PatchFile.ZIP}; not installed"
                val f = File(to, rel)
                if (e.isDirectory) {
                    f.mkdirs()
                    continue
                }
                f.parentFile?.mkdirs()
                f.outputStream().use { zin.copyTo(it) }
                files++
            }
        }
        if (files == 0) return "${PatchFile.ZIP} holds no plugin files; not installed"
        log("unpacked $files files")
        return null
    }

    /** The user patch the plugin replaced: with both present the plugin stays off. */
    private fun removeOldPatch() {
        for (f in listOf(oldPatch(), File(oldPatch().path + ".new"))) {
            if (f.exists() && !f.delete()) OLog.w("patch install: can't delete $f; the plugin stays off while it is there")
        }
    }

    private fun run(): String {
        val v = BuildConfig.VERSION_NAME
        // A test build has no release to fetch its plugin from: the sideload script pushed it.
        if (TestBuild.isTest(v)) return "test build v$v: install its plugin with tools/sideload-android.sh; not installed"
        val dev = Version.parse(v) == null || v.contains("dev")
        log("fetching ${if (dev) "the latest release" else "release v$v"}")
        val rel = Updater.release(JSONObject(if (dev) Updater.httpText("${Updater.API}/releases/latest") else releaseText(v)))
        val zipUrl = rel.assets[PatchFile.ZIP] ?: return "${rel.tag} has no ${PatchFile.ZIP}"
        val sumsUrl = rel.assets[UpdatePolicy.SUMS_NAME] ?: return "${rel.tag} has no ${UpdatePolicy.SUMS_NAME}"
        val expected = Checksums.parse(Updater.httpText(sumsUrl))[PatchFile.ZIP]
            ?: return "${UpdatePolicy.SUMS_NAME} has no line for ${PatchFile.ZIP}"
        val parent = Installers.pluginsDir()
        if (!parent.isDirectory && !parent.mkdirs()) {
            log("can't create $parent")
            return "can't write to storage: ${manualHint()}"
        }
        val zip = File(parent, PatchFile.ZIP + ".new")
        val sha = try {
            Updater.download(zipUrl, zip)
        } catch (e: java.io.FileNotFoundException) {
            log("can't write $zip: ${e.message}")
            return "can't write to storage: ${manualHint()}"
        }
        if (sha != expected) {
            zip.delete()
            return "download failed its checksum; not installed"
        }
        // Never *.koplugin while incomplete: KOReader must not load a half copy.
        val staging = File(parent, PatchFile.PLUGIN + ".orbit-new")
        val unpacked = try {
            unpack(zip, staging)
        } finally {
            zip.delete()
        }
        if (unpacked != null) {
            staging.deleteRecursively()
            return unpacked
        }
        val stamped = PatchFile.version(File(staging, "main.lua").takeIf { it.isFile }?.readText())
        if (stamped == null) {
            staging.deleteRecursively()
            return "${rel.tag}: the plugin has no main.lua version; not installed"
        }
        // Swap: old aside, new in, old gone.
        val live = pluginDir()
        val old = File(parent, PatchFile.PLUGIN + ".orbit-old")
        old.deleteRecursively()
        if (live.exists() && !live.renameTo(old)) {
            staging.deleteRecursively()
            return "can't write to storage: ${manualHint()}"
        }
        if (!staging.renameTo(live)) {
            if (old.exists()) old.renameTo(live)
            staging.deleteRecursively()
            return "can't write to storage: ${manualHint()}"
        }
        old.deleteRecursively()
        removeOldPatch()
        log("installed $stamped to $live (sha256 ok)")
        return "installed v$stamped"
    }
}

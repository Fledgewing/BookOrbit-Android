package net.fledgewing.orbitcompanion

import android.content.Context
import android.os.Environment
import android.os.Handler
import android.os.Looper
import java.io.File
import java.security.MessageDigest
import kotlin.concurrent.thread

/**
 * Reading fonts on disk (docs/design/reading-fonts.md): applies ReadingFonts.plan to
 * <shared storage>/koreader/fonts, the folder KOReader on Android searches besides its own
 * (frontend/ui/elements/font_settings.lua: home .. "/koreader/fonts"). Storage access as for the
 * Orbit plugin (PatchInstaller: target SDK 28, WRITE_EXTERNAL_STORAGE).
 */
object FontInstaller {
    const val REQUEST_CODE = 49
    @Volatile
    var busy = false
        private set
    private val main = Handler(Looper.getMainLooper())

    private fun log(msg: String) = OLog.i("reading fonts: $msg")

    @Suppress("DEPRECATION")
    fun dir(): File = File(Environment.getExternalStorageDirectory(), "koreader/fonts")

    /** Each manifest file's size on disk (cheap: Setup reads it on every render). */
    fun sizes(d: File = dir()): Map<String, Long> =
        ReadingFonts.FILES.mapNotNull { f -> File(d, f.name).takeIf { it.isFile }?.let { f.name to it.length() } }.toMap()

    fun installed(): Boolean = ReadingFonts.installed(sizes())

    fun sha256(f: File): String? = try {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { input ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val r = input.read(buf)
                if (r < 0) break
                md.update(buf, 0, r)
            }
        }
        md.digest().joinToString("") { "%02x".format(it) }
    } catch (e: Exception) {
        null
    }

    /** What is in [d] now, for the plan. */
    fun scan(d: File): Pair<Map<String, String?>, List<String>> {
        val present = ReadingFonts.FILES.mapNotNull { f -> File(d, f.name).takeIf { it.isFile }?.let { f.name to sha256(it) } }.toMap()
        val stray = d.list()?.filter { it.endsWith(ReadingFonts.PART) }.orEmpty()
        return present to stray
    }

    /**
     * Applies the plan for [wanted] to [d] with [fetch] (url, to file) -> SHA-256 of what it
     * wrote. Each file lands under a ReadingFonts.PART name and is renamed only after its hash
     * matched.
     */
    data class Outcome(val error: String?, val installed: Int)

    fun apply(d: File, wanted: Boolean, fetch: (String, File) -> String): Outcome {
        var n = 0
        val err = applyCounting(d, wanted, fetch) { n++ }
        return Outcome(err, n)
    }

    private fun applyCounting(d: File, wanted: Boolean, fetch: (String, File) -> String, installed: () -> Unit): String? {
        val (present, stray) = scan(d)
        val plan = ReadingFonts.plan(wanted, present, stray)
        if (plan.nothing) return null
        plan.delete.forEach { n -> if (File(d, n).delete()) log("deleted $n") }
        if (plan.download.isEmpty()) return null
        if (!d.isDirectory && !d.mkdirs()) return "can't write to ${d.path}"
        for (f in plan.download) {
            val part = File(d, f.name + ReadingFonts.PART)
            val sha = try {
                fetch(f.url, part)
            } catch (e: java.io.FileNotFoundException) {
                part.delete()
                return "can't write to ${d.path}"
            }
            if (!ReadingFonts.verified(f, sha)) {
                part.delete()
                return "${f.name} failed its checksum; not installed"
            }
            val live = File(d, f.name)
            live.delete()
            if (!part.renameTo(live)) {
                part.delete()
                return "can't write to ${d.path}"
            }
            log("installed ${f.name} (sha256 ok)")
            installed()
        }
        return null
    }

    /** Turns the row on or off: the pref first, then the files, off the main thread. */
    fun set(ctx: Context, wanted: Boolean, done: () -> Unit) {
        val p = Prefs(ctx)
        p.fontsWanted = wanted
        if (!wanted) p.fontsRestartPending = false
        run(ctx, done)
    }

    fun run(ctx: Context, done: () -> Unit) {
        if (busy) return
        busy = true
        val app = ctx.applicationContext
        val p = Prefs(app)
        val wanted = p.fontsWanted
        thread(name = "orbit-reading-fonts", isDaemon = true) {
            var turnedOn = false
            var fonts = 0
            val result = try {
                if (wanted && !Net.wifiConnected(app)) turnedOn = Updater.bringWifiUp(app)
                apply(dir(), wanted) { url, to -> Updater.download(url, to) }.also { fonts = it.installed }.error
            } catch (e: Exception) {
                OLog.w("reading fonts: failed", e)
                Updater.friendly(app, e)
            } finally {
                if (turnedOn) Net.setWifi(app, false, "reading fonts done, restoring off")
            }
            p.fontsStatus = result ?: ""
            // KOReader lists new fonts only after a restart; a run that wrote nothing owes none.
            if (wanted && fonts > 0) p.fontsRestartPending = true
            log(if (result == null) "${if (wanted) "on" else "off"}: done" else "result: $result")
            busy = false
            main.post { done() }
        }
    }

    /**
     * The restart that loads the fonts (ReadingFonts.restart): at the next screen-off, or at
     * once when the user taps Restart KOReader. Never when the Orbit plugin's restart is owed.
     */
    fun follow(ctx: Context, why: String, manual: Boolean = false, screenOff: Boolean = false): Boolean {
        val p = Prefs(ctx)
        val d = ReadingFonts.restart(p.fontsRestartPending, manual, screenOff, PatchInstaller.inProgress(ctx))
        if (d != ReadingFonts.Restart.NOW) return false
        p.fontsRestartPending = false
        if (p.koreaderBook == "1") p.restartReopen = "1"
        log("restarting KOReader to load them ($why)")
        Koreader.restart(ctx.applicationContext, "reading fonts installed ($why)", userStarted = manual)
        return true
    }
}

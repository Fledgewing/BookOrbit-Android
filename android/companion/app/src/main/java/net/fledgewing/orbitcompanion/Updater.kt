package net.fledgewing.orbitcompanion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.ScrollView
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlin.concurrent.thread

/**
 * Self-update from this repo's public GitHub releases (README "Updates").
 *
 * 1. Fetch releases/latest (or the releases list with "Include previews and release candidates"); only Android tags count.
 * 2. Newer than BuildConfig.VERSION_NAME? Download SHA256SUMS and orbit-companion-<ver>.apk.
 * 3. The APK's SHA-256 must match SHA256SUMS, and its signing certificate must match the
 *    installed app's.
 * 4. Install through a PackageInstaller session. On Android 12+ we ask for no user action, but
 *    Android only honours that when the app being installed targets a recent SDK (S+ on
 *    Android 14). The companion targets 28 for Wi-Fi control, so Android asks the user to
 *    confirm: right away when the check was started by hand, otherwise via a notification.
 */
object Updater {
    const val REPO = "Fledgewing/Orbify"
    internal const val API = "https://api.github.com/repos/$REPO"
    private const val OLD_CHANNEL = "updates"
    private const val CHANNEL = "updates_quiet"
    private const val ID_UPDATE = 3
    const val EXTRA_INTERACTIVE = "${Contract.PACKAGE}.extra.INTERACTIVE"
    const val EXTRA_VERSION = "${Contract.PACKAGE}.extra.VERSION"
    const val EXTRA_KEY = "${Contract.PACKAGE}.extra.INSTALL_KEY"

    @Volatile
    var busy = false
        private set

    private val main = Handler(Looper.getMainLooper())

    private fun log(msg: String) = OLog.i("update: $msg")

    /** The plugin's "Check for updates" (android/docs/INTERFACE.md): it downloads nothing itself. */
    const val ACTION_UPDATE = "${Contract.PACKAGE}.action.UPDATE"

    /**
     * The plugin asked: a check by hand. The plugin and the companion ship together, so a companion
     * that is up to date still brings the plugin of its own release when the one on disk is older
     * (PatchInstaller.afterAppUpdate); a newer companion brings it after its own install.
     */
    fun onPluginAsked(ctx: Context, why: String) {
        log("the plugin asked for a check ($why)")
        check(ctx, interactive = true, why = "plugin: $why") { result ->
            if (!result.startsWith("installing")) PatchInstaller.afterAppUpdate(ctx)
        }
    }

    /** The install window key (Pin.installStarted) for app updates. */
    const val INSTALL_KEY = "update"

    internal fun status(ctx: Context, s: String) {
        val p = Prefs(ctx)
        p.updateStatus = s
        p.updateStatusAt = System.currentTimeMillis()
        log("status: $s")
    }

    fun statusLine(ctx: Context): String {
        val p = Prefs(ctx)
        val base = "v${Version.parse(BuildConfig.VERSION_NAME)?.display() ?: BuildConfig.VERSION_NAME}"
        if (busy) return "$base · checking…"
        if (p.updateStatus.isEmpty()) return "$base · not checked yet"
        return "$base · ${p.updateStatus} (${Ui.clock(ctx, p.updateStatusAt)})"
    }

    /** Daily automatic check: Auto-update on, 24 h since the last one, Wi-Fi up, screen on. */
    fun maybeAutoCheck(ctx: Context, why: String) {
        val p = Prefs(ctx)
        if (!p.autoUpdate || busy) return
        if (!UpdatePolicy.due(p.updateCheckedAt, System.currentTimeMillis())) return
        if (!Net.wifiConnected(ctx) || !Net.screenOn(ctx)) {
            OLog.d("update: auto check due but network or screen not ready ($why)")
            return
        }
        check(ctx, interactive = false, why = why)
    }

    /** The app update's install session while it has no result yet (UpdateSession). */
    @Volatile
    private var session: UpdateSession.State? = null

    /** Android's prompt for [session], to open it again. */
    @Volatile
    private var sessionPrompt: Intent? = null

    /** The pending session, for UpdaterSessionTest. */
    internal fun pendingSession(): UpdateSession.State? = session

    private fun sessionAlive(ctx: Context, s: UpdateSession.State?): Boolean =
        s != null && try { ctx.packageManager.packageInstaller.getSessionInfo(s.id) != null } catch (e: Exception) { false }

    /** Our page is in front again: back from Android's prompt with the session open means confirmed. */
    fun onPageResumed(ctx: Context) {
        val s = session ?: return
        val next = UpdateSession.afterPrompt(s, sessionAlive(ctx, s))
        if (next != s) {
            session = next
            log("session ${s.id}: back from the prompt, still open; Android is checking v${s.version}")
            status(ctx, UpdateSession.CHECKING)
        }
    }

    /** [done] runs on the main thread with the final status line. */
    fun check(ctx: Context, interactive: Boolean, why: String, done: ((String) -> Unit)? = null) {
        if (busy) {
            log("check already running; ignored ($why)")
            return
        }
        // An install still pending: never a second session. Its prompt again, or say Android checks.
        val pending = session
        when (UpdateSession.onTap(pending, sessionAlive(ctx, pending), System.currentTimeMillis())) {
            UpdateSession.Tap.NEW_CHECK -> session = null
            UpdateSession.Tap.REOPEN_PROMPT -> {
                log("session ${pending!!.id} for v${pending.version} still waits for the user; its prompt again ($why)")
                val prompt = sessionPrompt
                if (interactive && prompt != null && openPrompt(ctx, prompt)) {
                    done?.let { d -> main.post { d(Prefs(ctx).updateStatus) } }
                    return
                }
                session = null
            }
            UpdateSession.Tap.SAY_CHECKING -> {
                log("session ${pending!!.id} for v${pending.version} is with Android; no new session ($why)")
                status(ctx, UpdateSession.CHECKING)
                done?.let { d -> main.post { d(UpdateSession.CHECKING) } }
                return
            }
        }
        busy = true
        // Started by hand while unlocked (Pin.run): the install window opens now, so the guard
        // lets the installer and Play Protect through (Guard.installSurface).
        if (interactive) Pin.installStarted(INSTALL_KEY)
        // From one of our pages: the update finishes back on it (UpdateReturn).
        if (interactive && ctx is android.app.Activity) UpdateReturn.mark(ctx, ctx)
        val app = ctx.applicationContext
        thread(name = "orbit-update", isDaemon = true) {
            // By hand with Wi-Fi off: turn it on for the check (Wi-Fi only, GitHub needs no
            // Tailscale), then put it back. Automatic checks never turn Wi-Fi on.
            var turnedOn = false
            val result = try {
                if (interactive && !Net.wifiConnected(app)) turnedOn = bringWifiUp(app)
                run(app, interactive, why)
            } catch (e: Exception) {
                OLog.w("update: check failed ($why)", e)
                friendly(app, e)
            } finally {
                if (turnedOn) {
                    OLog.i("update: Wi-Fi was off before the check; turning it back off")
                    Net.setWifi(app, false, "update check done, restoring off")
                }
            }
            status(app, result)
            if (interactive && !result.startsWith("installing")) Pin.installEnded(INSTALL_KEY)
            busy = false
            if (done != null) main.post { done(result) }
        }
    }

    /** Returns true when we turned Wi-Fi on. Waits up to 30 s for a connection. */
    internal fun bringWifiUp(ctx: Context): Boolean {
        val was = Net.wifiEnabled(ctx)
        if (!was && !Net.setWifi(ctx, true, "update check", WifiOwner.AUTO)) return false
        val t0 = android.os.SystemClock.elapsedRealtime()
        while (!Net.wifiConnected(ctx) && android.os.SystemClock.elapsedRealtime() - t0 < 30_000) Thread.sleep(250)
        log("Wi-Fi ${if (Net.wifiConnected(ctx)) "connected" else "NOT connected"} after ${OLog.since(t0)} ms for the check")
        return !was
    }

    /** Plain words instead of an exception name. */
    internal fun friendly(ctx: Context, e: Exception): String {
        val kind = NetErrors.kindOf(e)
        val msg = NetErrors.message(kind, Net.wifiEnabled(ctx), Net.wifiConnected(ctx), Net.vpnLockdown(ctx), e.message ?: e.javaClass.simpleName)
        log("error kind $kind: ${e.javaClass.simpleName}: ${e.message} -> $msg")
        return msg
    }

    private fun run(ctx: Context, interactive: Boolean, why: String): String {
        val p = Prefs(ctx)
        val pre = p.includePreReleases
        log("check started ($why, interactive=$interactive, pre-releases=$pre, installed v${BuildConfig.VERSION_NAME})")

        val releases = if (pre) {
            val arr = JSONArray(httpText("$API/releases?per_page=${ReleaseTags.LIST_PAGE}"))
            (0 until arr.length()).map { release(arr.getJSONObject(it)) }
        } else {
            listOf(release(JSONObject(httpText("$API/releases/latest"))))
        }
        // Only a check that reached GitHub counts for the daily timer: a failed one (no network,
        // VPN lockdown) is retried at the next Wi-Fi up instead of 24 h later.
        p.updateCheckedAt = System.currentTimeMillis()
        log("fetched ${releases.size} release(s): ${releases.joinToString { it.tag }}")
        val rel = UpdatePolicy.pick(releases, pre) ?: return "no release found"
        val ver = rel.version!!
        val current = Version.parse(BuildConfig.VERSION_NAME)
        if (!UpdatePolicy.isNewer(ver, current)) {
            log("up to date: newest is ${rel.tag}")
            return "up to date"
        }

        val apkName = UpdatePolicy.apkName(ver)
        val apkUrl = rel.assets[apkName] ?: return "${rel.tag} has no BookSync Companion APK"
        val sumsUrl = rel.assets[UpdatePolicy.SUMS_NAME] ?: return "${rel.tag} has no ${UpdatePolicy.SUMS_NAME}"
        val expected = Checksums.parse(httpText(sumsUrl))[apkName] ?: return "${UpdatePolicy.SUMS_NAME} has no line for the BookSync Companion APK"
        log("${rel.tag}: expecting sha256 $expected for $apkName")

        val dir = File(ctx.filesDir, "updates").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() } // only ever one pending update
        val part = File(dir, "$apkName.part")
        val got = download(apkUrl, part)
        if (!got.equals(expected, ignoreCase = true)) {
            part.delete()
            log("checksum MISMATCH: got $got")
            return "download failed its checksum; not installed"
        }
        log("checksum ok")
        val apk = File(dir, apkName)
        if (!part.renameTo(apk)) return "could not store the download"

        val certProblem = signerProblem(ctx, apk)
        if (certProblem != null) {
            apk.delete()
            log("signer check FAILED: $certProblem")
            return certProblem
        }
        log("signer matches the installed app")
        // A check by hand: the restart that finishes it doesn't wait for the book (v0.5.5).
        if (interactive) Prefs(ctx).userUpdateAt = System.currentTimeMillis()
        if (!UpdateSession.canCommit(session, sessionAlive(ctx, session), System.currentTimeMillis())) {
            log("a session is still pending; not committing another")
            return UpdateSession.CHECKING
        }
        installApk(ctx, apk, ctx.packageName, ver.toString(), interactive, INSTALL_KEY)
        return "installing v$ver"
    }

    internal fun release(o: JSONObject): ReleaseInfo = ReleaseInfo.from(o)

    /** A connect timeout or reset is retried twice, after 3 s and 10 s (NetErrors.withRetry). */
    private fun open(url: String): HttpURLConnection = NetErrors.withRetry(
        sleep = { Thread.sleep(it) },
        note = { i, e, wait -> log("try $i to ${URL(url).host} failed (${e.javaClass.simpleName}: ${e.message}); retrying in ${wait / 1000} s") },
    ) { openOnce(url) }

    private fun openOnce(url: String): HttpURLConnection {
        // HttpURLConnection follows the https -> https redirect to GitHub's asset host.
        val c = URL(url).openConnection() as HttpURLConnection
        c.connectTimeout = NetErrors.CONNECT_TIMEOUT_MS
        c.readTimeout = 30_000
        c.setRequestProperty("User-Agent", "OrbitCompanion/${BuildConfig.VERSION_NAME}")
        if (url.startsWith(API)) {
            c.setRequestProperty("Accept", "application/vnd.github+json")
            c.setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
        }
        val code = c.responseCode
        if (code != 200) {
            c.disconnect()
            throw java.io.IOException("HTTP $code from ${URL(url).host}")
        }
        return c
    }

    internal fun httpText(url: String): String = httpBytes(url).toString(Charsets.UTF_8)

    internal fun httpBytes(url: String): ByteArray {
        val c = open(url)
        try {
            return c.inputStream.use { it.readBytes() }
        } finally {
            c.disconnect()
        }
    }

    /** Streams to [to] and returns the lowercase hex SHA-256. */
    internal fun download(url: String, to: File): String {
        val t0 = android.os.SystemClock.elapsedRealtime()
        val md = MessageDigest.getInstance("SHA-256")
        val c = open(url)
        var n = 0L
        try {
            c.inputStream.use { input ->
                FileOutputStream(to).use { out ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val r = input.read(buf)
                        if (r < 0) break
                        md.update(buf, 0, r)
                        out.write(buf, 0, r)
                        n += r
                    }
                }
            }
        } finally {
            c.disconnect()
        }
        log("downloaded ${to.name.removeSuffix(".part")}: $n bytes in ${OLog.since(t0)} ms")
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun certDigests(sigs: Array<Signature>?): Set<String> =
        sigs.orEmpty().map { s -> MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).joinToString(":") { "%02X".format(it) } }.toSet()

    @Suppress("DEPRECATION")
    internal fun signers(pm: PackageManager, archive: String?, pkg: String?): Set<String> {
        if (Build.VERSION.SDK_INT >= 28) {
            val flags = PackageManager.GET_SIGNING_CERTIFICATES
            val info = if (archive != null) pm.getPackageArchiveInfo(archive, flags) else pm.getPackageInfo(pkg!!, flags)
            val si = info?.signingInfo
            if (si != null) return certDigests(if (si.hasMultipleSigners()) si.apkContentsSigners else si.signingCertificateHistory)
        }
        val info = if (archive != null) pm.getPackageArchiveInfo(archive, PackageManager.GET_SIGNATURES) else pm.getPackageInfo(pkg!!, PackageManager.GET_SIGNATURES)
        return certDigests(info?.signatures)
    }

    /** null when the downloaded APK is our package and signed by the installed app's certificate. */
    private fun signerProblem(ctx: Context, apk: File): String? {
        val pm = ctx.packageManager
        @Suppress("DEPRECATION")
        val archivePkg = pm.getPackageArchiveInfo(apk.path, 0)?.packageName
        if (archivePkg != ctx.packageName) return "the download is not BookSync Companion ($archivePkg); not installed"
        val theirs = signers(pm, apk.path, null)
        val ours = signers(pm, null, ctx.packageName)
        log("signer of the download: ${theirs.joinToString()} / installed: ${ours.joinToString()}")
        if (theirs.isEmpty()) return "could not read the download's signature; not installed"
        // Key rotation history: the update's newest cert must be one we already trust.
        if (theirs.intersect(ours).isEmpty()) {
            return "the update is signed with a different key (a debug build is installed?): uninstall and install the release APK once"
        }
        return null
    }

    /** A PackageInstaller session for [apk] ([pkg]); the result comes to InstallReceiver with [key]. */
    internal fun installApk(ctx: Context, apk: File, pkg: String, version: String, interactive: Boolean, key: String) {
        val pi = ctx.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(pkg)
        params.setSize(apk.length())
        params.setInstallReason(PackageManager.INSTALL_REASON_USER)
        if (Build.VERSION.SDK_INT >= 31) {
            // Honoured only for apps targeting S+ on Android 14 (see the class comment); harmless otherwise.
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        Pin.installStarted(key)
        val id = pi.createSession(params)
        pi.openSession(id).use { s ->
            s.openWrite("base.apk", 0, apk.length()).use { out ->
                apk.inputStream().use { it.copyTo(out) }
                s.fsync(out)
            }
            val cb = Intent(ctx, InstallReceiver::class.java)
                .putExtra(EXTRA_INTERACTIVE, interactive)
                .putExtra(EXTRA_VERSION, version)
                .putExtra(EXTRA_KEY, key)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            s.commit(PendingIntent.getBroadcast(ctx, id, cb, flags).intentSender)
        }
        if (key == INSTALL_KEY) {
            session = UpdateSession.State(id, version, UpdateSession.Phase.COMMITTED, System.currentTimeMillis())
            sessionPrompt = null
        }
        log("session $id committed for $pkg v$version (interactive=$interactive)")
    }

    /** Android's install prompt (the user started the check, so our page is in front). */
    private fun openPrompt(ctx: Context, confirm: Intent): Boolean = try {
        ctx.startActivity(confirm)
        true
    } catch (e: Exception) {
        OLog.w("update: could not open the install prompt", e)
        false
    }

    // Called by InstallReceiver.

    fun onSessionStatus(ctx: Context, intent: Intent) {
        val key = intent.getStringExtra(EXTRA_KEY) ?: INSTALL_KEY
        if (key != INSTALL_KEY) return Installers.onSessionStatus(ctx, intent, key)
        val st = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        val msg = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        val version = intent.getStringExtra(EXTRA_VERSION) ?: "?"
        val interactive = intent.getBooleanExtra(EXTRA_INTERACTIVE, false)
        when (st) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                if (confirm == null) {
                    status(ctx, "v$version: Android wants a confirmation but sent no prompt")
                    return
                }
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                log("Android asks the user to confirm v$version (interactive=$interactive)")
                session = session?.copy(phase = UpdateSession.Phase.PROMPTED, atMs = System.currentTimeMillis())
                sessionPrompt = confirm
                // A check started by hand has our page in front, so the prompt may open now.
                // In the background, Android blocks activity starts: post a notification instead.
                val shown = interactive && openPrompt(ctx, confirm)
                if (!shown) {
                    // Nothing on screen until the notification is tapped (PinActivity reopens the window).
                    Pin.installEnded(INSTALL_KEY)
                    ready = version to confirm
                    // Never while reading: the notification waits for a moment nobody is (Reading).
                    val app = ctx.applicationContext
                    Reading.show(app, Reading.KEY_UPDATE, "update v$version ready") { notifyReady(app, version, confirm) }
                }
                status(ctx, "v$version ready: confirm the install")
            }
            PackageInstaller.STATUS_SUCCESS -> {
                Pin.installEnded(INSTALL_KEY)
                session = null
                sessionPrompt = null
                ready = null
                Reading.drop(Reading.KEY_UPDATE)
                status(ctx, "updated to v$version")
                notifications(ctx).cancel(ID_UPDATE)
            }
            else -> {
                Pin.installEnded(INSTALL_KEY)
                session = null
                sessionPrompt = null
                status(ctx, UpdateSession.failureLine(st, msg, version))
            }
        }
    }

    /** MY_PACKAGE_REPLACED: we are the new version now. */
    fun onReplaced(ctx: Context) {
        ready = null
        Reading.drop(Reading.KEY_UPDATE)
        notifications(ctx).cancel(ID_UPDATE)
        File(ctx.filesDir, "updates").listFiles()?.forEach { it.delete() }
        // A fresh process: the window's last 60 s cover Play Protect's follow-up.
        Pin.installEnded(INSTALL_KEY)
        status(ctx, "updated to v${BuildConfig.VERSION_NAME}")
        // Started from one of our pages: back on it (the old process took it down), not KOReader.
        UpdateReturn.onReplaced(ctx)
        // One update covers everything: the release's patch, then KOReader's restart.
        Attention.onStart(ctx)
        PatchInstaller.afterAppUpdate(ctx) { Attention.evaluate(ctx, "after update") }
    }

    private fun notifications(ctx: Context) = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    /** The install prompt behind the update-ready notification (PinActivity.thenInstall). */
    @Volatile
    var pendingConfirm: Intent? = null

    /** A background update downloaded and waiting for the user's Install: (version, Android's prompt). */
    @Volatile
    private var ready: Pair<String, Intent>? = null

    /** The update ready to install, while it is still newer than this app (Status shows "Install"). */
    fun readyToInstall(): Pair<String, Intent>? = ready?.takeIf { stillNewer(it.first) }

    private fun stillNewer(version: String): Boolean =
        UpdatePolicy.isNewer(Version.parse(version), Version.parse(BuildConfig.VERSION_NAME))

    /** Quiet: no sound, no vibration, no heads-up (IMPORTANCE_DEFAULT never peeks); shown only through Reading. */
    private fun notifyReady(ctx: Context, version: String, confirm: Intent) {
        if (!stillNewer(version)) return log("v$version ready, but this app is already v${BuildConfig.VERSION_NAME}: no notification")
        val nm = notifications(ctx)
        // The old "updates" channel had a sound, which can't be changed once created: replaced.
        if (nm.getNotificationChannel(OLD_CHANNEL) != null) nm.deleteNotificationChannel(OLD_CHANNEL)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "App updates", NotificationManager.IMPORTANCE_DEFAULT).apply {
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        })
        val text = "BookSync Companion $version is ready. Tap to install."
        val n = Notification.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            // Through the PIN keypad (no PIN or unlocked: straight to Android's prompt).
            .setContentIntent(PendingIntent.getActivity(ctx, 3, PinActivity.thenInstall(ctx, confirm), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            .build()
        nm.notify(ID_UPDATE, n)
        log("notification posted: v$version ready to install")
    }
}

/** PackageInstaller session results. */
class InstallReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        Updater.onSessionStatus(ctx, intent)
    }
}

/** Settings › Open-source licenses: the notices generated at build time (assets). */
class LicensesActivity : EinkActivity() {
    override val pinPage = PinPage.NEUTRAL

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = try {
            assets.open("open_source_licenses.txt").use { it.readBytes().toString(Charsets.UTF_8) }
        } catch (e: Exception) {
            OLog.w("licenses: notices missing from this build", e)
            "The notices file is missing from this build."
        }
        // Its own ScrollView below the header.
        val root = page(scroll = false)
        root.addView(Ui.header(this, "Open-source licenses", "‹ Back") { finish() })
        val scroll = ScrollView(this).apply { isVerticalScrollBarEnabled = true }
        scroll.addView(Ui.text(this, text, 14f).apply { typeface = android.graphics.Typeface.MONOSPACE })
        root.addView(scroll)
    }
}

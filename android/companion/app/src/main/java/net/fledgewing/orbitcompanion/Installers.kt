package net.fledgewing.orbitcompanion

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.concurrent.thread

/**
 * Setup installs the rest (android/docs/DESIGN.md "Setup installs the rest"): one tap each for KOReader
 * (the official koreader/koreader release APK for this device's ABI, checked against GitHub's
 * published asset digest and KOReader's signing certificate, installed through a
 * PackageInstaller session) and the BookOrbit plugin (bookorbit/bookorbit's release tag,
 * each file checked against its git blob id, swapped into koreader/plugins/ atomically).
 * Downloads come only from those official sources; nothing is re-hosted.
 */
object Installers {
    const val KOREADER = "koreader"
    const val PLUGIN = "plugin"
    const val PLUGIN_REQUEST_CODE = 48

    private val main = Handler(Looper.getMainLooper())
    private val busy = HashSet<String>()

    private fun log(msg: String) = OLog.i("install: $msg")

    @Synchronized
    fun busy(key: String) = key in busy

    @Synchronized
    private fun claim(key: String): Boolean = busy.add(key)

    @Synchronized
    private fun release(key: String) {
        busy.remove(key)
    }

    // ------------------------------------------------------------------ KOReader

    fun koreaderVersion(ctx: Context): String? = try {
        ctx.packageManager.getPackageInfo(Koreader.PKG, 0).versionName
    } catch (e: Exception) {
        null
    }

    fun koreaderState(ctx: Context): KoreaderRelease.State {
        val signers = try {
            Updater.signers(ctx.packageManager, null, Koreader.PKG)
        } catch (e: Exception) {
            null
        }
        return KoreaderRelease.state(signers, Net.installed(ctx, KoreaderRelease.FDROID_PKG))
    }

    /** Install KOReader, or update it when the latest release is newer. [done] gets the status. */
    fun koreader(a: Activity, done: (String) -> Unit) {
        if (!claim(KOREADER)) return
        val app = a.applicationContext
        Pin.installStarted(KOREADER)
        thread(name = "orbit-install-koreader", isDaemon = true) {
            var turnedOn = false
            var committed = false
            val result = try {
                if (!Net.wifiConnected(app)) turnedOn = Updater.bringWifiUp(app)
                val r = koreaderRun(app)
                committed = r.startsWith("installing")
                r
            } catch (e: Exception) {
                OLog.w("install: KOReader failed", e)
                Updater.friendly(app, e)
            } finally {
                if (turnedOn) Net.setWifi(app, false, "KOReader download done, restoring off")
            }
            log("KOReader: $result")
            Prefs(app).koreaderInstallStatus = result
            if (!committed) Pin.installEnded(KOREADER)
            release(KOREADER)
            main.post { done(result) }
        }
    }

    private fun koreaderRun(ctx: Context): String {
        val state = koreaderState(ctx)
        if (state == KoreaderRelease.State.OTHER_SIGNER) return KoreaderRelease.explain(state)
        val rel = JSONObject(Updater.httpText(KoreaderRelease.API))
        val tag = rel.optString("tag_name")
        val assets = rel.optJSONArray("assets") ?: JSONArray()
        val byName = (0 until assets.length()).map { assets.getJSONObject(it) }.associateBy { it.getString("name") }
        val installed = koreaderVersion(ctx)
        if (state == KoreaderRelease.State.OFFICIAL && !KoreaderRelease.newer(tag, installed)) return "up to date ($installed)"
        val abis = Build.SUPPORTED_ABIS.toList()
        val name = KoreaderRelease.assetFor(abis, byName.keys) ?: return "$tag has no KOReader APK for ${abis.joinToString()}"
        val asset = byName.getValue(name)
        val expected = KoreaderRelease.digest(asset.optString("digest", ""))
        log("KOReader $tag: $name, ${asset.optLong("size")} bytes, from github.com/koreader/koreader, sha256 ${expected ?: "not published"}")
        val dir = File(ctx.filesDir, "installs").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() }
        val part = File(dir, "$name.part")
        val got = Updater.download(asset.getString("browser_download_url"), part)
        if (expected != null && !got.equals(expected, ignoreCase = true)) {
            part.delete()
            return "KOReader download failed its checksum; not installed"
        }
        val apk = File(dir, name)
        if (!part.renameTo(apk)) return "could not store the KOReader download"
        val certs = Updater.signers(ctx.packageManager, apk.path, null)
        if (KoreaderRelease.OFFICIAL_CERT !in certs) {
            apk.delete()
            log("KOReader signer ${certs.joinToString()} is not the official one")
            return "the KOReader download isn't signed with KOReader's key; not installed"
        }
        log("KOReader checks ok (sha256 ${if (expected != null) "matches GitHub's digest" else "not published"}, official signer)")
        Updater.installApk(ctx, apk, Koreader.PKG, tag, interactive = true, key = KOREADER)
        return "installing KOReader $tag"
    }

    /** InstallReceiver for a session we started here (not the companion's own update). */
    fun onSessionStatus(ctx: Context, intent: Intent, key: String) {
        val st = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        val msg = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        val version = intent.getStringExtra(Updater.EXTRA_VERSION) ?: "?"
        val p = Prefs(ctx)
        when (st) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                if (confirm == null) {
                    p.koreaderInstallStatus = "Android wants a confirmation but sent no prompt"
                    Pin.installEnded(key)
                    return
                }
                log("$key $version: Android asks the user to confirm")
                try {
                    ctx.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    p.koreaderInstallStatus = "confirm the install of KOReader $version"
                } catch (e: Exception) {
                    OLog.w("install: could not open the install prompt", e)
                    p.koreaderInstallStatus = "could not open Android's install prompt · tap to try again"
                    Pin.installEnded(key)
                }
            }
            PackageInstaller.STATUS_SUCCESS -> {
                Pin.installEnded(key)
                p.koreaderInstallStatus = "installed KOReader $version"
                File(ctx.filesDir, "installs").listFiles()?.forEach { it.delete() }
                log("$key $version installed")
            }
            else -> {
                Pin.installEnded(key)
                p.koreaderInstallStatus = "KOReader $version install failed ($st${if (msg != null) ": $msg" else ""})"
                log("$key $version failed: $st $msg")
            }
        }
    }

    // ------------------------------------------------------------------ BookOrbit plugin

    @Suppress("DEPRECATION")
    fun pluginsDir(): File = File(Environment.getExternalStorageDirectory(), "koreader/plugins")
    fun pluginDir(): File = File(pluginsDir(), PluginRelease.NAME)

    fun pluginVersion(): String? = try {
        File(pluginDir(), "main.lua").takeIf { it.isFile }?.readText()?.let { PluginRelease.version(it) }
    } catch (e: Exception) {
        null
    }

    /** Asks for storage first if needed; the activity calls [plugin] again on the grant. */
    fun pluginFrom(a: Activity, done: (String) -> Unit) {
        if (!PatchInstaller.hasPermission(a)) {
            log("plugin: asking for storage permission")
            a.requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), PLUGIN_REQUEST_CODE)
            return
        }
        plugin(a, done)
    }

    fun plugin(ctx: Context, done: (String) -> Unit) {
        if (!claim(PLUGIN)) return
        val app = ctx.applicationContext
        thread(name = "orbit-install-plugin", isDaemon = true) {
            var turnedOn = false
            val result = try {
                if (!Net.wifiConnected(app)) turnedOn = Updater.bringWifiUp(app)
                pluginRun()
            } catch (e: Exception) {
                OLog.w("install: plugin failed", e)
                Updater.friendly(app, e)
            } finally {
                if (turnedOn) Net.setWifi(app, false, "plugin download done, restoring off")
            }
            log("plugin: $result")
            val p = Prefs(app)
            p.pluginInstallStatus = result
            // Loaded at KOReader's next start: restart it now when the running patch can.
            if (result.startsWith("installed") && PatchRow.canRestart(p.patchVersionSeen.ifEmpty { null })) {
                main.post { Koreader.restart(app, "BookOrbit plugin installed") }
            }
            release(PLUGIN)
            main.post { done(result) }
        }
    }

    private fun pluginRun(): String {
        val rel = JSONObject(Updater.httpText("${PluginRelease.API}/releases/latest"))
        val tag = rel.optString("tag_name").takeIf { it.isNotEmpty() } ?: return "BookOrbit has no release"
        // The release tag's koreader-plugin/bookorbit.koplugin tree (bookorbit/bookorbit publishes
        // no plugin zip asset; its plugin updater downloads from the user's own server).
        val dirList = JSONArray(Updater.httpText("${PluginRelease.API}/contents/${PluginRelease.SRC_DIR}?ref=$tag"))
        val treeSha = (0 until dirList.length()).map { dirList.getJSONObject(it) }
            .firstOrNull { it.optString("name") == PluginRelease.NAME && it.optString("type") == "dir" }?.optString("sha")
            ?: return "BookOrbit $tag has no ${PluginRelease.NAME}"
        val tree = JSONObject(Updater.httpText("${PluginRelease.API}/git/trees/$treeSha?recursive=1"))
        if (tree.optBoolean("truncated")) return "BookOrbit $tag: the plugin's file list was cut short; not installed"
        val entries = tree.getJSONArray("tree")
        val blobs = (0 until entries.length()).map { entries.getJSONObject(it) }.filter { it.optString("type") == "blob" }
        if (blobs.isEmpty()) return "BookOrbit $tag: no plugin files"
        val parent = pluginsDir()
        if (!parent.isDirectory && !parent.mkdirs()) return "can't write to storage (koreader/plugins)"
        val staging = File(parent, PluginRelease.NAME + ".orbit-new")
        staging.deleteRecursively()
        var total = 0L
        for (b in blobs) {
            val path = b.getString("path")
            if (!PluginRelease.safePath(path)) {
                staging.deleteRecursively()
                return "BookOrbit $tag: unexpected file name $path; not installed"
            }
            val url = "${PluginRelease.RAW}/$tag/${PluginRelease.SRC_DIR}/${PluginRelease.NAME}/$path"
            val bytes = Updater.httpBytes(url)
            if (PluginRelease.gitBlobSha1(bytes) != b.getString("sha")) {
                staging.deleteRecursively()
                return "BookOrbit plugin file $path failed its checksum; not installed"
            }
            val f = File(staging, path)
            f.parentFile?.mkdirs()
            f.writeBytes(bytes)
            total += bytes.size
        }
        val version = PluginRelease.version(File(staging, "main.lua").takeIf { it.isFile }?.readText())
        if (version == null) {
            staging.deleteRecursively()
            return "BookOrbit $tag: no plugin main.lua; not installed"
        }
        log("plugin $version from github.com/bookorbit/bookorbit $tag: ${blobs.size} files, $total bytes, git blob ids ok")
        // Swap: old aside, new in, old gone. KOReader loads only *.koplugin folders.
        val live = pluginDir()
        val old = File(parent, PluginRelease.NAME + ".orbit-old")
        old.deleteRecursively()
        if (live.exists() && !live.renameTo(old)) {
            staging.deleteRecursively()
            return "can't replace koreader/plugins/${PluginRelease.NAME}"
        }
        if (!staging.renameTo(live)) {
            if (old.exists()) old.renameTo(live)
            staging.deleteRecursively()
            return "can't move the plugin into koreader/plugins"
        }
        old.deleteRecursively()
        return "installed BookOrbit plugin $version"
    }
}

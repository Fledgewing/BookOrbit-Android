package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import java.io.File
import org.json.JSONArray
import org.json.JSONObject

object ConnectorPlugin : ConnectorInstaller {
    override val homeModeKey = "bookorbit"
    override fun coverCacheDir(root: File) = File(root, "koreader/cache/bookorbit")
    override fun setupId(label: String): String? = when {
        label.startsWith("BookOrbit plugin") -> "plugin"
        label.startsWith("Signed in to BookOrbit") -> "signed_in"
        else -> null
    }
    override fun pluginDir() = File(Installers.pluginsDir(), PluginRelease.NAME)
    override fun version(main: String?) = PluginRelease.version(main)
    override fun needsInstall(installed: String?) = PluginRelease.needsInstall(installed)
    override fun install(): String {
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
        val parent = Installers.pluginsDir()
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
        OLog.i("plugin $version from github.com/bookorbit/bookorbit $tag: ${blobs.size} files, $total bytes, git blob ids ok")
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

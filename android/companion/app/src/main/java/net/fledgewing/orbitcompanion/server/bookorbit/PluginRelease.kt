package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import java.security.MessageDigest

/** The BookOrbit plugin from bookorbit/bookorbit's release tag (koreader-plugin/bookorbit.koplugin). */
object PluginRelease {
    const val API = "https://api.github.com/repos/bookorbit/bookorbit"
    const val RAW = "https://raw.githubusercontent.com/bookorbit/bookorbit"
    const val SRC_DIR = "koreader-plugin"
    const val NAME = "bookorbit.koplugin"
    /** The plugin the patch's hooks are checked against (android/koreader/test/plugin_compat.lua in CI). */
    const val MIN_VERSION = "2.3.0"

    private val VERSION = Regex("""(?m)^local PLUGIN_VERSION = "([^"]+)"""")

    /** PLUGIN_VERSION in the plugin's main.lua, or null. */
    fun version(mainLua: String?): String? = mainLua?.let { VERSION.find(it)?.groupValues?.get(1) }

    /**
     * Install only when it's missing or older than the patch needs: the plugin updates itself
     * from the BookOrbit server (bookorbit_updater.lua), and we never fight that.
     */
    fun needsInstall(installed: String?): Boolean {
        val i = installed?.let { Version.parse(it) } ?: return true
        return i < Version.parse(MIN_VERSION)!!
    }

    /** A tree path we may write: relative, no "." or ".." parts. */
    fun safePath(p: String): Boolean =
        p.isNotEmpty() && !p.startsWith("/") && !p.contains('\\') && p.split('/').none { it.isEmpty() || it == "." || it == ".." }

    /** Git's object id for a blob: SHA-1 of "blob <size>\0" + content (what the trees API lists). */
    fun gitBlobSha1(bytes: ByteArray): String {
        val md = MessageDigest.getInstance("SHA-1")
        md.update("blob ${bytes.size}\u0000".toByteArray(Charsets.US_ASCII))
        md.update(bytes)
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}


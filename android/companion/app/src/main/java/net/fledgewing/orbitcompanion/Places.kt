package net.fledgewing.orbitcompanion

import android.os.Environment
import java.io.File

/**
 * The only folders a companion command may touch files in (docs/design/security.md): the cache
 * worker's folder, the plugin's cover folder and the sleep screen's folder. A path a command names
 * is used only when it resolves (symlinks followed) to one of them or a file inside; anything else
 * is refused.
 */
object Places {
    /** orbit-cache, KOReader's cover folder for BookOrbit, orbit-sleep. */
    fun roots(): List<File> {
        val ext = Environment.getExternalStorageDirectory()
        return listOf(File(ext, "koreader/settings/orbit-cache"), ServerAdapters.connector.coverCacheDir(ext), File(ext, "koreader/settings/orbit-sleep"))
    }

    /**
     * [path] resolved, when it is absolute, has no `..` part and lies inside one of [roots] (or is
     * one); else null. Resolution follows symlinks, so a link that points out is refused.
     */
    fun inside(path: String?, roots: List<File>): File? {
        if (path.isNullOrEmpty() || path.indexOf('\u0000') >= 0) return null
        val f = File(path)
        if (!f.isAbsolute || path.split('/').any { it == ".." }) return null
        val real = try { f.canonicalFile } catch (e: Exception) { return null }
        for (r in roots) {
            val base = try { r.canonicalFile } catch (e: Exception) { continue }
            if (real == base || real.path.startsWith(base.path + File.separator)) return real
        }
        return null
    }

    fun inside(f: File, roots: List<File>): File? = inside(f.path, roots)
}

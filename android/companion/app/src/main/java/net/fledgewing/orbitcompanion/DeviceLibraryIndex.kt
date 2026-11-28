// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import java.io.File
import java.security.MessageDigest
import java.time.Instant
import java.util.Properties

/** First observed on this reader, not last edited or last read. Survives worker restarts.
 * UTC date strings share the catalog added-date filter and sort semantics. */
class DeviceLibraryIndex(private val file: File?, private val clock: () -> Long) {
    private val values = Properties().apply { if(file?.isFile==true) runCatching { file.inputStream().use(::load) } }
    private var dirty=false
    fun added(book: File): String {
        val key=MessageDigest.getInstance("SHA-256").digest(book.canonicalPath.toByteArray()).joinToString("") { "%02x".format(it) }
        val saved=values.getProperty(key)?.toLongOrNull()
        val at=saved ?: (clock()*1000).also {
            values.setProperty(key,it.toString())
            dirty=true
        }
        return Instant.ofEpochMilli(at).toString()
    }
    /** One atomic index write per scan, rather than rewriting it for every book. */
    fun flush() {
        val target=file ?: return
        if(!dirty) return
        target.parentFile?.mkdirs()
        val temp=File(target.parentFile,target.name+".part")
        try { temp.outputStream().use { values.store(it,null) };check(temp.renameTo(target));dirty=false }
        finally { temp.delete() }
    }
}

// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion
import java.io.File

/** A hash migration has no caller-supplied path; never follow links outside this fixed root. */
object HashSidecar {
    fun carry(root: File, old: String, new: String, checkpoint: () -> Unit = {}) {
        checkpoint()
        val hash = Regex("[0-9a-f]{32}")
        if (!hash.matches(old) || !hash.matches(new) || old == new) return
        val from = Places.inside(File(root, "${old.take(2)}/$old.sdr"), listOf(root)) ?: return
        val to = Places.inside(File(root, "${new.take(2)}/$new.sdr"), listOf(root)) ?: return
        if (!from.isDirectory || to.exists()) return
        to.mkdirs()
        for (file in from.listFiles() ?: emptyArray()) {
            checkpoint()
            if (Places.inside(file, listOf(from)) == null || !file.isFile) continue
            val dest = File(to, file.name)
            val temp = File(to, file.name + ".tmp")
            file.inputStream().use { input -> temp.outputStream().use { output -> input.copyTo(output) } }
            check(temp.renameTo(dest))
        }
    }
}

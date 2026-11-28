// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import android.content.Context
import android.os.Handler
import android.os.Looper
import java.io.File
import java.util.concurrent.Executors

/** Neutral, local-only Library service. One row / 8 KiB; no server, catalog, scan or subprocess. */
object LibraryDiagnostics {
    data class Snapshot(val text: String, val canClear: Boolean, val rows: Int = 1, val setup: List<Pair<String, String>> = emptyList()) {
        val bytes: Int get() = text.toByteArray(Charsets.UTF_8).size
    }
    private val queue = Executors.newSingleThreadExecutor { r -> Thread(r, "booksync-diagnostics").apply { isDaemon = true } }
    private val main by lazy { Handler(Looper.getMainLooper()) }
    private var summary: CrashSummary? = null
    private var summaryFile: File? = null
    @Synchronized internal fun store(ctx: Context): CrashSummary {
        val file = File(ctx.applicationContext.noBackupFilesDir, "companion-crashes.bin")
        if (summaryFile != file) {
            summary = CrashSummary(file)
            summaryFile = file
        }
        return requireNotNull(summary)
    }

    internal fun project(saved: CrashSummary.Snapshot): Snapshot = Snapshot(saved.text(), !saved.available || saved.entries.isNotEmpty()).also {
        check(it.rows == 1 && it.bytes <= CrashSummary.MAX_BYTES)
    }
    // Existing setup diagnostics remain unchanged, accessed through the same Library surface.
    fun snapshot(ctx: Context, done: (Snapshot) -> Unit) {
        val app = ctx.applicationContext
        queue.execute {
            val start = System.nanoTime()
            val crashes = runCatching { project(store(app).snapshot()) }.getOrElse { Snapshot("Crash summary unavailable", true) }
            val setup = runCatching { Setup.details(app) }.getOrElse { listOf("Setup diagnostics" to "Unavailable") }
            val setupBytes = setup.sumOf { (k,v) -> k.toByteArray().size + v.toByteArray().size }
            val snapshot = crashes.copy(setup = if (setupBytes <= 8192) setup else listOf("Setup diagnostics" to "Unavailable"))
            OLog.i("library.diagnostics rows=1 bytes=${snapshot.bytes} ms=${(System.nanoTime()-start)/1_000_000}")
            main.post { done(snapshot) }
        }
    }
    /** Explicit command; never clears any other diagnostics or user data. */
    fun clear(ctx: Context, done: (Boolean) -> Unit) {
        val app = ctx.applicationContext
        queue.execute { val ok = runCatching { store(app).clear() }.getOrDefault(false); main.post { done(ok) } }
    }
}

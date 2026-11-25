package net.fledgewing.orbitcompanion

import android.content.Context
import android.os.Process
import android.os.SystemClock
import java.io.File
import java.util.concurrent.Executors

/** One bulk writer, one mirror fetcher. New storage jobs belong on [executor] too. */
object BulkWork {
    @Volatile private var app: Context? = null
    val executor = Executors.newSingleThreadExecutor { task -> thread("orbit-bulk", task) }
    fun thread(name: String, task: Runnable): Thread = Thread({
        Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
        task.run()
    }, name).apply { isDaemon = true; priority = Thread.MIN_PRIORITY }

    fun attach(ctx: Context) { app = ctx.applicationContext }
    @Volatile private var nextCheck = 0L
    @Volatile private var reading = false
    @Synchronized private fun blocked(): Boolean {
        val ctx = app ?: return false
        val now = SystemClock.elapsedRealtime()
        if (now >= nextCheck) {
            reading = Reading.now(ctx) && Net.screenOn(ctx)
            nextCheck = now + 500
        }
        return reading
    }
    fun changed() { nextCheck = 0 }
    private val waiting = java.util.concurrent.atomic.AtomicInteger()
    val paused: Boolean get() = waiting.get() > 0
    fun checkpoint() {
        if (!blocked()) return
        waiting.incrementAndGet()
        try { awaitIdle(::blocked) { Thread.sleep(250) } } finally { waiting.decrementAndGet() }
    }
    internal fun awaitIdle(blocked: () -> Boolean, wait: () -> Unit) {
        while (blocked()) { if (Thread.currentThread().isInterrupted) throw InterruptedException(); wait() }
    }
    fun <T> phase(name: String, job: () -> T): T {
        val cpu = SystemClock.currentThreadTimeMillis()
        try { return job() } finally { OLog.i("bulk: $name CPU ${SystemClock.currentThreadTimeMillis() - cpu} ms") }
    }
}

/** A marker before any temporary image or cache write, including newly created subfolders. */
object NoMedia {
    fun directory(dir: File): File {
        if (!dir.isDirectory && !dir.mkdirs()) error("cache directory unavailable")
        val marker = File(dir, ".nomedia")
        if (!marker.exists() && !marker.createNewFile() && !marker.isFile) error("no-media marker unavailable")
        return dir
    }
    fun roots(roots: List<File>) { roots.forEach(::directory) }
}

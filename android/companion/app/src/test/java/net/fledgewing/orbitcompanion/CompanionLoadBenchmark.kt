package net.fledgewing.orbitcompanion

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import org.json.JSONTokener
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicLong

/** Opt-in, no device/network: ORBIFY_BENCHMARK=1 ./gradlew testDebugUnitTest --tests '*CompanionLoadBenchmark'. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class CompanionLoadBenchmark {
    // Reflection keeps JVM-only management APIs out of the Android compile classpath.
    private val bean = Class.forName("java.lang.management.ManagementFactory").getMethod("getThreadMXBean").invoke(null)
    private val allocations = Class.forName("com.sun.management.ThreadMXBean").getMethod("getThreadAllocatedBytes", Long::class.javaPrimitiveType)
    private val cpuTime = Class.forName("java.lang.management.ThreadMXBean").getMethod("getCurrentThreadCpuTime")
    private fun allocated() = allocations.invoke(bean, Thread.currentThread().id) as Long
    private fun cpu() = cpuTime.invoke(bean) as Long
    private data class Cost(val cpu: Long, val bytes: Long)
    private fun measure(work: () -> Unit): Cost {
        val bytes = allocated(); val start = cpu()
        work()
        return Cost(cpu() - start, allocated() - bytes)
    }

    @Test fun mirrorAndCoverPipeline() {
        assumeTrue(System.getenv("ORBIFY_BENCHMARK") == "1")
        Class.forName("com.sun.management.ThreadMXBean").getMethod("setThreadAllocatedMemoryEnabled", Boolean::class.javaPrimitiveType).invoke(bean, true)
        Class.forName("java.lang.management.ThreadMXBean").getMethod("setThreadCpuTimeEnabled", Boolean::class.javaPrimitiveType).invoke(bean, true)
        val details = (1..40).associateWith { id ->
            """{"id":$id,"title":"Synthetic book $id","hasCover":true,"tags":["fiction","test"],"metadata":{${(1..80).joinToString(",") { "\"field$it\":\"${"value ".repeat(8)}\"" }}}}"""
        }
        val page = """{"total":40,"items":[${(1..40).joinToString(",") { """{"id":$it,"title":"Synthetic book $it","hasCover":true}""" }}]}"""
        val bitmap = Bitmap.createBitmap(800, 1200, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(0xff505050.toInt())
        val image = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        bitmap.recycle()
        fun run(decoder: (String) -> Any?, legacyCover: Boolean): Cost {
            val root = Files.createTempDirectory("mirror-bench").toFile()
            val fetchCpu = AtomicLong(); val fetchBytes = AtomicLong()
            try {
                var covers = 0
                val http = CacheWorker.Http { url, headers, sink, _ ->
                    when {
                        sink != null && "If-None-Match" in headers -> CacheWorker.Reply(304)
                        sink != null -> { sink.writeBytes(image); covers++; CacheWorker.Reply(200, etag = "test", contentType = "image/png") }
                        url.contains("?") -> CacheWorker.Reply(200, page.toByteArray())
                        else -> CacheWorker.Reply(200, details.getValue(url.substringAfterLast('/').toInt()).toByteArray())
                    }
                }
                val worker = CacheWorker(root, http, log = {}, openSql = { JdbcSql(it) }, decodeJson = decoder,
                    resizeThumbnail = { f, w, h -> if (legacyCover) LegacyThumbnailCache.shrink(f, w, h) else ThumbnailCache.shrink(f, w, h) },
                    threadFactory = { name, task -> Thread({
                        val cost = measure { task.run() }
                        fetchCpu.addAndGet(cost.cpu); fetchBytes.addAndGet(cost.bytes)
                    }, name) })
                val plan = CacheWorker.Plan(mapOf("run" to "bench", "op" to "full", "owner" to "synthetic", "reason" to "benchmark",
                    "seed_lists" to listOf("/koreader/plugin/catalog/books?sort=title"), "detail_template" to "/koreader/plugin/catalog/books/987654321", "sentinel" to "987654321",
                    "cover_dir" to File(root, "covers").path, "covers_on" to true, "cover_width" to 240L, "cover_height" to 320L))
                assertEquals("finished", worker.run(plan, CacheWorker.Creds("https://books.example", "synthetic", "test")))
                fetchCpu.set(0); fetchBytes.set(0)
                val cost = measure {
                    repeat(2) { assertEquals("finished", worker.run(plan, CacheWorker.Creds("https://books.example", "synthetic", "test"))) }
                }
                assertEquals(40, covers)
                assertEquals(40L, worker.store.db().query("SELECT count(*) FROM books WHERE detail IS NOT NULL") { it.long(0) }.single())
                worker.store.db().close()
                return Cost(cost.cpu + fetchCpu.get(), cost.bytes + fetchBytes.get())
            } finally { root.deleteRecursively() }
        }
        val legacy: (String) -> Any? = { LuaValue.fromJsonValue(JSONTokener(it).nextValue()) }
        run(legacy, true); run(LuaValue::fromJson, false) // warm both, including graphics and SQLite
        val old = ArrayList<Cost>(); val new = ArrayList<Cost>()
        repeat(3) { old.add(run(legacy, true)); new.add(run(LuaValue::fromJson, false)) }
        fun report(name: String, costs: List<Cost>) {
            println("BENCH $name 2 cached mirrors+80 cover checks CPU_ms=${costs.map { it.cpu / 1_000_000 }.sorted()[1]} allocated_bytes=${costs.map { it.bytes }.sorted()[1]}")
        }
        report("intermediate-JSON-tree", old); report("direct-model", new)
        // Allocation is deterministic enough to guard; elapsed time/CPU remain reported evidence.
        assertTrue(new.map { it.bytes }.sorted()[1] < old.map { it.bytes }.sorted()[1])
    }
}

// Frozen pre-W28 algorithm for the opt-in benchmark; never packaged in the app.
/** Browsing images only; sleep images retain their full-screen resolution. */
private object LegacyThumbnailCache {
    fun shrink(file: File, width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return
        val scale = minOf(1.0, width.toDouble() / bounds.outWidth, height.toDouble() / bounds.outHeight)
        val jpeg = file.inputStream().use { it.read() == 0xff && it.read() == 0xd8 }
        if (scale >= 1.0 && jpeg) return
        val w = maxOf(1, (bounds.outWidth * scale).toInt())
        val h = maxOf(1, (bounds.outHeight * scale).toInt())
        val sampled = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply {
            inSampleSize = SharpCoversLogic.sample(bounds.outWidth, bounds.outHeight, w, h)
        }) ?: return
        val image = Bitmap.createScaledBitmap(sampled, w, h, true)
        val tmp = File(file.path + ".resize")
        val before = file.length()
        val shown = file.lastModified()
        try {
            val ok = tmp.outputStream().use { image.compress(Bitmap.CompressFormat.JPEG, 85, it) }
            val after = tmp.length()
            if (ok && after > 0 && tmp.renameTo(file)) {
                file.setLastModified(shown)
                OLog.i("covers: thumbnail ${bounds.outWidth}x${bounds.outHeight} -> ${w}x$h: $before -> $after bytes; saved ${before - after} bytes; estimated same-size cache saving ${100 - after * 100 / before}%")
            }
        } finally {
            tmp.delete()
            if (image !== sampled) image.recycle()
            sampled.recycle()
        }
    }
}

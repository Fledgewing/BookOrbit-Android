// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import java.io.*
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** Private diagnostic data, never Throwable.toString(), messages, causes or unrestricted logs. */
class CrashSummary(private val file: File, private val clock: () -> Long = System::currentTimeMillis) {
    data class Entry(val version: String, val type: String, val frames: List<String>, val first: Long, val last: Long, val count: Int)
    data class Snapshot(val available: Boolean, val entries: List<Entry>) {
        val rows = 1
        fun text(zone: ZoneId = ZoneId.systemDefault()): String {
            if (!available) return "Crash summary unavailable"
            if (entries.isEmpty()) return "No companion crash summaries saved."
            val format = DateTimeFormatter.ofPattern("d MMM uuuu, HH:mm z", Locale.getDefault()).withZone(zone)
            return entries.joinToString("\n\n") { e ->
                "${e.count} matching crashes · BookSync ${e.version}\n" +
                    "First seen: ${format.format(Instant.ofEpochMilli(e.first))}\n" +
                    "Last seen: ${format.format(Instant.ofEpochMilli(e.last))}\n${e.type}" +
                    e.frames.joinToString("\n", prefix = if (e.frames.isEmpty()) "" else "\n")
            } + "\n\nSaved on this reader. Never sent automatically."
        }
    }
    companion object {
        const val MAX_BYTES = 8192
        const val MAX_ENTRIES = 4
        const val MAX_COUNT = 999999
        private const val MAX_TIME = 253402300799999L
        private const val MAGIC = 0x42534331
        // Exact symbols only. A package prefix or an identifier regex is not a frame allowlist.
        internal val frames = setOf("Worker.run", "Worker.onIntent", "Worker.accountChanged", "LibraryReadModel.publish", "LibraryReadModel.publishBatch",
            "LibraryAccount.initialize", "LibraryAccount.command", "SetupDetailsActivity.onResume", "SetupDetailsActivity.render",
            "OrbitService.onCreate", "OrbitService.onStartCommand", "ProjectionStore.transaction", "SyncOwner.drain")
        private val types = setOf("IllegalStateException", "IllegalArgumentException", "NullPointerException",
            "UnsupportedOperationException", "ArithmeticException", "IndexOutOfBoundsException", "SecurityException",
            "RuntimeException", "Exception", "OutOfMemoryError", "StackOverflowError", "AssertionError", "Throwable", "IOException")
        private fun version(value: String) = value.length <= 64 && Regex("[0-9]{1,6}\\.[0-9]{1,6}\\.[0-9]{1,6}(?:-(?:preview|rc)\\.[0-9]{1,12}|-0\\.test\\.[0-9]{1,12})?").matches(value)
        private fun exceptionType(error: Throwable): String = error.javaClass.name.let { name ->
            name.substringAfterLast('.').takeIf { it in types && name in setOf("java.lang.$it", "java.io.$it") } ?: "Throwable"
        }
    }
    @Synchronized fun snapshot(): Snapshot = try {
        if (!file.exists()) Snapshot(true, emptyList()) else {
            val bytes = file.inputStream().use { stream ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(1024)
                while (output.size() <= MAX_BYTES) {
                    val n = stream.read(buffer, 0, minOf(buffer.size, MAX_BYTES + 1 - output.size()))
                    if (n < 0) break
                    output.write(buffer, 0, n)
                }
                output.toByteArray() }
            require(bytes.size <= MAX_BYTES)
            val input = DataInputStream(ByteArrayInputStream(bytes))
            require(input.readInt() == MAGIC)
            val size = input.readInt(); require(size in 0..MAX_ENTRIES)
            val entries = List(size) {
                val v = input.readUTF(); require(version(v))
                val type = input.readUTF(); require(type in types)
                val n = input.readInt(); require(n in 0..8)
                val symbols = List(n) { input.readUTF().also { require(it in frames) } }
                val first = input.readLong(); val last = input.readLong(); val count = input.readInt()
                require(first in 0..MAX_TIME && last in first..MAX_TIME && count in 1..MAX_COUNT)
                Entry(v, type, symbols, first, last, count)
            }
            require(input.available() == 0)
            Snapshot(true, entries)
        }
    } catch (_: Exception) { Snapshot(false, emptyList()) }

    @Synchronized fun record(error: Throwable, appVersion: String) {
        val v = appVersion.takeIf(::version) ?: "0.0.0"
        val type = exceptionType(error)
        val symbols = error.stackTrace.take(64).mapNotNull { frame ->
            val owner = frame.className.removePrefix("net.fledgewing.orbitcompanion.")
            if (frame.className != "net.fledgewing.orbitcompanion.$owner") null
            else "$owner.${frame.methodName}".takeIf { it in frames }
        }.take(8)
        val now = clock().coerceIn(0, MAX_TIME)
        val entries = snapshot().entries.toMutableList()
        val old = entries.firstOrNull { it.version == v && it.type == type && it.frames == symbols }
        entries.remove(old)
        entries.add(Entry(v, type, symbols, minOf(old?.first ?: now, now), maxOf(old?.last ?: now, now), ((old?.count ?: 0) + 1).coerceAtMost(MAX_COUNT)))
        while (entries.size > MAX_ENTRIES) entries.removeAt(0)
        val output = ByteArrayOutputStream()
        DataOutputStream(output).use { out ->
            out.writeInt(MAGIC); out.writeInt(entries.size)
            entries.forEach { e ->
                out.writeUTF(e.version); out.writeUTF(e.type); out.writeInt(e.frames.size); e.frames.forEach(out::writeUTF)
                out.writeLong(e.first); out.writeLong(e.last); out.writeInt(e.count)
            }
        }
        val bytes = output.toByteArray(); check(bytes.size <= MAX_BYTES)
        val temp = File(file.parentFile, file.name + ".part")
        try {
            FileOutputStream(temp).use { it.write(bytes); it.fd.sync() }
            Files.move(temp.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } finally { temp.delete() }
    }
    @Synchronized fun clear(): Boolean = try {
        Files.deleteIfExists(File(file.parentFile, file.name + ".part").toPath())
        Files.deleteIfExists(file.toPath()); true
    } catch (_: Exception) { false }
}

/** Saving is best effort. The previous handler owns termination and receives the original pair once. */
class CrashSummaryHandler(private val save: (Throwable) -> Unit, private val previous: Thread.UncaughtExceptionHandler) : Thread.UncaughtExceptionHandler {
    override fun uncaughtException(thread: Thread, error: Throwable) {
        try { save(error) } catch (_: Throwable) { /* No logs: neither messages nor storage errors are diagnostic data. */ }
        finally { previous.uncaughtException(thread, error) }
    }
}

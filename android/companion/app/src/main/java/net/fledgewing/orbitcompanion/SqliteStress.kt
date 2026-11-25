package net.fledgewing.orbitcompanion

import java.io.File

/**
 * The shared-storage stress test's writer (docs/design/sqlite-cache.md "Stress test"): writes
 * nonstop into orbit-cache/stress.db, one page of [ROWS] rows per transaction, while the plugin
 * reads the same file from KOReader. Every row of a page carries the page's generation, and the
 * page's `head` row carries that generation and the sum of the rows' lengths, so a reader can tell
 * a whole page from a torn one. Plain JVM over [Sql], so the unit test runs it against JDBC.
 */
class SqliteStress(private val open: () -> Sql, private val log: (String) -> Unit = { OLog.i(it) }) {
    data class Result(val writes: Long, val errors: Long, val maxWaitMs: Long, val integrity: String, val firstError: String?) {
        fun line() = "sqlite-stress writer: $writes writes, $errors errors, max lock wait $maxWaitMs ms, integrity $integrity" +
            (firstError?.let { " (first error: $it)" } ?: "")

        fun toModel(at: Long): Map<String, Any?> = sortedMapOf("writes" to writes, "errors" to errors, "max_wait_ms" to maxWaitMs,
            "integrity" to integrity, "first_error" to firstError, "at" to at)
    }

    /** Writes for [seconds]; [stop] is asked between pages. */
    fun run(seconds: Int, stop: () -> Boolean = { false }): Result {
        var writes = 0L
        var errors = 0L
        var maxWait = 0L
        var firstError: String? = null
        var integrity = "not checked"
        val db = open()
        try {
            db.exec("CREATE TABLE IF NOT EXISTS rows (page INTEGER, pos INTEGER, gen INTEGER, val TEXT, PRIMARY KEY (page, pos)) WITHOUT ROWID")
            db.exec("CREATE TABLE IF NOT EXISTS head (page INTEGER PRIMARY KEY, gen INTEGER, sum INTEGER)")
            var gen = db.query("SELECT max(gen) FROM head") { it.long(0) }.firstOrNull() ?: 0L
            val end = System.currentTimeMillis() + seconds * 1000L
            while (System.currentTimeMillis() < end && !stop()) {
                gen++
                val page = gen % PAGES
                val t0 = System.currentTimeMillis()
                try {
                    db.transaction {
                        var sum = 0L
                        for (pos in 0 until ROWS) {
                            val v = value(gen, pos)
                            sum += v.length
                            db.exec("INSERT OR REPLACE INTO rows (page, pos, gen, val) VALUES (?, ?, ?, ?)", page, pos.toLong(), gen, v)
                        }
                        db.exec("INSERT OR REPLACE INTO head (page, gen, sum) VALUES (?, ?, ?)", page, gen, sum)
                    }
                    writes++
                } catch (e: Exception) {
                    errors++
                    if (firstError == null) firstError = e.toString().take(200)
                }
                maxWait = maxOf(maxWait, System.currentTimeMillis() - t0)
            }
            integrity = try { db.pragma("integrity_check") ?: "no answer" } catch (e: Exception) { errors++; "failed: $e" }
            if (integrity != "ok") errors++
        } finally {
            db.close()
        }
        return Result(writes, errors, maxWait, integrity, firstError).also { log(it.line()) }
    }

    companion object {
        const val PAGES = 50L
        const val ROWS = 100
        const val SECONDS = 120
        const val FILE = "stress.db"
        const val RESULT = "stress-writer.lua"

        @Synchronized fun cleanup(root: File) {
            if (running) return
            listOf(FILE, "$FILE-journal", RESULT).forEach { File(root, it).delete() }
        }

        /** A row's text: its length varies with generation and position (the reader's checksum). */
        fun value(gen: Long, pos: Int): String {
            val n = 40 + ((gen * 7 + pos * 13) % 160).toInt()
            val sb = StringBuilder(n)
            for (i in 0 until n) sb.append('a' + ((gen + pos + i) % 26).toInt())
            return sb.toString()
        }

        @Volatile
        var running = false
            private set

        /**
         * The SQLITE_STRESS broadcast: a fresh stress.db beside the cache, written for [seconds]; the
         * result goes to the log and to orbit-cache/stress-writer.lua for the plugin's verdict.
         */
        fun start(root: File, seconds: Int) {
            synchronized(this) {
                if (running) { OLog.i("sqlite-stress: already running"); return }
                running = true
            }
            Thread({
                try {
                    root.mkdirs()
                    File(root, RESULT).delete()
                    listOf(FILE, "$FILE-journal").forEach { File(root, it).delete() }
                    OLog.i("sqlite-stress: writing ${File(root, FILE)} for $seconds s")
                    val r = SqliteStress({ AndroidSql(File(root, FILE)) }).run(seconds)
                    val tmp = File(root, "$RESULT.tmp")
                    tmp.writeBytes(LuaValue.encode(r.toModel(System.currentTimeMillis() / 1000)))
                    tmp.renameTo(File(root, RESULT))
                } catch (e: Exception) {
                    OLog.w("sqlite-stress writer: failed", e)
                } finally {
                    running = false
                }
            }, "orbit-sqlite-stress").apply { isDaemon = true }.start()
        }
    }
}

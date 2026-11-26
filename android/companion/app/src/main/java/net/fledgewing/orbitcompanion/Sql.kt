package net.fledgewing.orbitcompanion

import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteStatement
import java.io.File

/**
 * The few SQLite calls the offline cache's database needs (docs/design/sqlite-cache.md), as a
 * port: Android's own SQLite on the device ([AndroidSql]), JDBC in the plain JVM unit tests.
 * Arguments: Long, Int, Double, String, ByteArray (a blob) or null.
 */
interface Sql : AutoCloseable {
    fun exec(sql: String, vararg args: Any?)

    /** Rows of a query, each mapped while the cursor is on it. */
    fun <T> query(sql: String, vararg args: Any?, row: (Row) -> T): List<T>

    /** BEGIN IMMEDIATE ... COMMIT (rolled back on an exception): readers keep reading until COMMIT. */
    fun <T> transaction(block: () -> T): T

    /** A PRAGMA's single answer (journal_mode, integrity_check, user_version). */
    fun pragma(p: String): String? = query("PRAGMA $p") { it.text(0) }.firstOrNull()

    interface Row {
        fun long(i: Int): Long?
        fun text(i: Int): String?
        fun bytes(i: Int): ByteArray?
    }
}

/** One connection owner for cache operations. Nested helpers join the caller's transaction;
 * another thread waits until the whole transaction ends, including reads and direct writes.
 * A failed nested scope poisons the outer transaction even if its caller catches the error. */
class CacheSql(private val delegate: Sql) : Sql {
    private var depth = 0
    private var failed = false

    @Synchronized override fun exec(sql: String, vararg args: Any?) = delegate.exec(sql, *args)
    @Synchronized override fun <T> query(sql: String, vararg args: Any?, row: (Sql.Row) -> T): List<T> =
        delegate.query(sql, *args, row = row)
    @Synchronized override fun close() = delegate.close()

    @Synchronized override fun <T> transaction(block: () -> T): T {
        if (depth > 0) {
            depth++
            try { return block() } catch (e: Throwable) { failed = true; throw e }
            finally { depth-- }
        }
        return delegate.transaction {
            depth = 1
            failed = false
            try {
                val result = block()
                check(!failed) { "nested cache transaction failed" }
                result
            } finally { depth = 0; failed = false }
        }
    }
}

/** Cache databases use TRUNCATE on FUSE. Only borrowed KOReader statistics keep their native WAL mode. */
class AndroidSql(file: File, readOnly: Boolean = false, wal: Boolean = false) : Sql {
    private val db: SQLiteDatabase

    init {
        file.parentFile?.mkdirs()
        db = SQLiteDatabase.openDatabase(file.path, null, if (readOnly) SQLiteDatabase.OPEN_READONLY else SQLiteDatabase.OPEN_READWRITE or SQLiteDatabase.CREATE_IF_NECESSARY or (if (wal) SQLiteDatabase.ENABLE_WRITE_AHEAD_LOGGING else 0))
        if (!readOnly && !wal) {
            db.disableWriteAheadLogging()
            pragma("journal_mode=TRUNCATE")
        }
    }

    private fun bind(st: SQLiteStatement, args: Array<out Any?>) {
        args.forEachIndexed { n, a ->
            val i = n + 1
            when (a) {
                null -> st.bindNull(i)
                is Long -> st.bindLong(i, a)
                is Int -> st.bindLong(i, a.toLong())
                is Boolean -> st.bindLong(i, if (a) 1 else 0)
                is Double -> st.bindDouble(i, a)
                is ByteArray -> st.bindBlob(i, a)
                else -> st.bindString(i, a.toString())
            }
        }
    }

    override fun exec(sql: String, vararg args: Any?) {
        db.compileStatement(sql).use { st -> bind(st, args); st.execute() }
    }

    override fun <T> query(sql: String, vararg args: Any?, row: (Sql.Row) -> T): List<T> {
        val out = ArrayList<T>()
        db.rawQuery(sql, args.map { if (it is Boolean) (if (it) "1" else "0") else it?.toString() }.toTypedArray()).use { c ->
            val r = object : Sql.Row {
                override fun long(i: Int) = if (c.isNull(i)) null else c.getLong(i)
                override fun text(i: Int) = if (c.isNull(i)) null else c.getString(i)
                override fun bytes(i: Int) = if (c.isNull(i)) null else c.getBlob(i)
            }
            while (c.moveToNext()) out.add(row(r))
        }
        return out
    }

    override fun <T> transaction(block: () -> T): T {
        db.beginTransactionNonExclusive()
        try {
            val r = block()
            db.setTransactionSuccessful()
            return r
        } finally {
            db.endTransaction()
        }
    }

    override fun close() = db.close()
}

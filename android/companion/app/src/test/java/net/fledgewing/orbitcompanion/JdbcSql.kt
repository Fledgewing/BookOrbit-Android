package net.fledgewing.orbitcompanion

import java.io.File
import java.sql.Connection
import java.sql.DriverManager
import java.sql.PreparedStatement
import java.sql.Types

/** [Sql] over JDBC (xerial sqlite-jdbc): the plain JVM tests' SQLite, rollback journal like [AndroidSql]. */
class JdbcSql(file: File, busyMs: Int = 2500) : Sql {
    private val c: Connection = DriverManager.getConnection("jdbc:sqlite:${file.path}")

    init {
        c.createStatement().use { it.execute("PRAGMA busy_timeout=$busyMs") }
        pragma("journal_mode=TRUNCATE")
    }

    private fun bind(st: PreparedStatement, args: Array<out Any?>) {
        args.forEachIndexed { n, a ->
            val i = n + 1
            when (a) {
                null -> st.setNull(i, Types.NULL)
                is Long -> st.setLong(i, a)
                is Int -> st.setLong(i, a.toLong())
                is Boolean -> st.setLong(i, if (a) 1 else 0)
                is Double -> st.setDouble(i, a)
                is ByteArray -> st.setBytes(i, a)
                else -> st.setString(i, a.toString())
            }
        }
    }

    override fun exec(sql: String, vararg args: Any?) {
        c.prepareStatement(sql).use { st -> bind(st, args); st.execute() }
    }

    override fun <T> query(sql: String, vararg args: Any?, row: (Sql.Row) -> T): List<T> {
        val out = ArrayList<T>()
        c.prepareStatement(sql).use { st ->
            bind(st, args)
            st.executeQuery().use { rs ->
                val r = object : Sql.Row {
                    override fun long(i: Int): Long? = rs.getLong(i + 1).takeUnless { rs.wasNull() }
                    override fun text(i: Int): String? = rs.getString(i + 1)
                    override fun bytes(i: Int): ByteArray? = rs.getBytes(i + 1)
                }
                while (rs.next()) out.add(row(r))
            }
        }
        return out
    }

    override fun <T> transaction(block: () -> T): T {
        c.createStatement().use { it.execute("BEGIN IMMEDIATE") }
        try {
            val r = block()
            c.createStatement().use { it.execute("COMMIT") }
            return r
        } catch (e: Throwable) {
            runCatching { c.createStatement().use { it.execute("ROLLBACK") } }
            throw e
        }
    }

    override fun close() = c.close()
}

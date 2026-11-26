package net.fledgewing.orbitcompanion

/** Companion-owned, account-scoped position writes. Enqueue commits before transport starts;
 * a process death after delivery but before acknowledgment replays the same captured write.
 * Call only on LibraryAccount's serial worker. This is not a render/read-model operation. */
class ProgressOutbox(private val sql: Sql, private val log: (String) -> Unit = OLog::i,
    private val now: () -> Long = { System.currentTimeMillis()/1000 }) {
    companion object {
        const val MAX_PENDING = 1000
        const val MAX_POSITION_BYTES = 4096
        const val MAX_BATCH = 24
    }
    init {
        sql.exec("CREATE TABLE IF NOT EXISTS position_outbox (sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, adapter TEXT NOT NULL, owner TEXT NOT NULL, document TEXT NOT NULL, body BLOB NOT NULL)")
        sql.exec("CREATE INDEX IF NOT EXISTS position_outbox_owner ON position_outbox(adapter,owner,sequence)")
    }
    data class Entry(val id: String, val document: String, val update: Map<String, Any?>)
    data class Drain(val sent: Int, val pending: Int, val error: String?)

    fun enqueue(adapter: String, owner: String, document: String, update: Map<String, Any?>): String {
        require(adapter.isNotBlank() && adapter.length <= 100 && owner.isNotBlank() && owner.length <= 1024)
        require(document.isNotBlank() && document.length <= 1024)
        val fraction = (update["percentage"] as? Number)?.toDouble() ?: throw IllegalArgumentException("percentage")
        require(fraction.isFinite() && fraction in 0.0..1.0)
        val position = update["position"]
        require(position == null || position is String && position.length <= MAX_POSITION_BYTES && position.all { it.code <= 255 })
        // Never persist arbitrary command inputs: credentials and unrelated fields cannot enter the queue.
        val body = LuaValue.encode(mapOf("percentage" to fraction, "position" to position, "capturedAt" to now()))
        require(body.size <= 16384)
        val id = java.util.UUID.randomUUID().toString()
        sql.transaction {
            check(count() < MAX_PENDING) { "position queue full" }
            sql.exec("INSERT INTO position_outbox(id,adapter,owner,document,body) VALUES (?,?,?,?,?)", id,adapter,owner,document,body)
        }
        return id
    }
    fun count(): Int = sql.query("SELECT COUNT(*) FROM position_outbox") { it.long(0)!!.toInt() }.single()
    fun count(adapter: String, owner: String): Int = sql.query("SELECT COUNT(*) FROM position_outbox WHERE adapter=? AND owner=?",adapter,owner) { it.long(0)!!.toInt() }.single()
    fun contains(id: String): Boolean = sql.query("SELECT 1 FROM position_outbox WHERE id=?",id) { true }.isNotEmpty()
    private fun window(adapter: String, owner: String): List<Entry> =
        sql.query("SELECT id,document,body FROM position_outbox WHERE adapter=? AND owner=? ORDER BY sequence LIMIT ?",adapter,owner,MAX_BATCH) { row ->
            val raw = LuaValue.parse(row.bytes(2)!!) as Map<*, *>
            Entry(row.text(0)!!,row.text(1)!!,raw.entries.associate { it.key as String to it.value })
        }

    /** FIFO, bounded per drain. Stop at failure so a later override cannot overtake an earlier
     * write. Only an explicit successful response acknowledges a row; unsupported is retained. */
    fun drain(adapter: ServerAdapter): Drain {
        val start = System.nanoTime()
        try { return deliver(adapter) }
        finally { log("position.outbox.drain ms=${(System.nanoTime()-start)/1_000_000}") }
    }
    private fun deliver(adapter: ServerAdapter): Drain {
        val owner = adapter.positionOwner() ?: return Drain(0,0,"unauthorized")
        var sent = 0
        var error: String? = null
        for (entry in window(adapter.id,owner)) {
            try {
                check(adapter.positionOwner() == owner) { "position owner changed" }
                val result = adapter.position(entry.document,entry.update)
                val failure = result["error"] as? String
                if (failure != null) { error = failure; break }
                sql.exec("DELETE FROM position_outbox WHERE id=? AND adapter=? AND owner=?",entry.id,adapter.id,owner)
                sent++
            } catch (e: ServerFailure) { error = e.kind; break }
            catch (_: Exception) { error = "unavailable"; break }
        }
        return Drain(sent,count(adapter.id,owner),error)
    }
}

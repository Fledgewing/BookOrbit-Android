package net.fledgewing.orbitcompanion

/** Sole worker's durable five-phase journal. Payloads/checkpoints belong to the adapter and
 * never enter the UI read model. Every phase commits separately, including remote-pending data. */
class LifecycleQueue(val sql: Sql) {
    companion object {
        val PHASES = listOf("match","stats","annotations","state","progress")
        const val WINDOW = 24
        const val MAX_BYTES = 200 * 1024 * 1024
    }
    data class Entry(val id: String, val adapter: String, val owner: String, val document: String,
        val payload: ByteArray, val acknowledged: Set<String>, val checkpoint: ByteArray,
        val source: String?, val retired: Boolean)
    init {
        sql.exec("CREATE TABLE IF NOT EXISTS lifecycle_jobs (sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,adapter TEXT NOT NULL,owner TEXT NOT NULL,document TEXT NOT NULL,payload BLOB NOT NULL,checkpoint BLOB NOT NULL,source TEXT,retired INTEGER NOT NULL DEFAULT 0,done INTEGER NOT NULL DEFAULT 0)")
        sql.exec("CREATE UNIQUE INDEX IF NOT EXISTS lifecycle_source ON lifecycle_jobs(adapter,source) WHERE source IS NOT NULL")
        sql.exec("CREATE INDEX IF NOT EXISTS lifecycle_owner ON lifecycle_jobs(adapter,owner,done,sequence)")
        sql.exec("CREATE TABLE IF NOT EXISTS lifecycle_acks (id TEXT NOT NULL,phase TEXT NOT NULL,PRIMARY KEY(id,phase))")
        sql.exec("CREATE TABLE IF NOT EXISTS sync_records (adapter TEXT NOT NULL,owner TEXT NOT NULL,document TEXT NOT NULL,body BLOB NOT NULL,PRIMARY KEY(adapter,owner,document))")
        sql.exec("CREATE TABLE IF NOT EXISTS sync_imports (adapter TEXT NOT NULL,source TEXT NOT NULL,job TEXT NOT NULL,proof BLOB NOT NULL,retired INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(adapter,source))")
    }
    fun enqueue(adapter: String, owner: String, document: String, payload: ByteArray,
        acknowledged: Set<String> = emptySet(), checkpoint: ByteArray = LuaValue.encode(emptyMap<String,Any>()),
        source: String? = null, proof: ByteArray = byteArrayOf()): String = sql.transaction {
        require(adapter.isNotBlank() && owner.isNotBlank() && document.isNotBlank())
        require(acknowledged.all { it in PHASES } && payload.size <= MAX_BYTES && checkpoint.size <= MAX_BYTES)
        if (source != null) imported(adapter,source)?.let { return@transaction it }
        check(sql.query("SELECT COUNT(*) FROM lifecycle_jobs WHERE done=0") { it.long(0)!! }.single()<1000) { "lifecycle queue full" }
        check(sql.query("SELECT COALESCE(SUM(length(payload)+length(checkpoint)),0) FROM lifecycle_jobs WHERE done=0") { it.long(0)!! }.single()+payload.size+checkpoint.size<=MAX_BYTES) { "lifecycle byte limit" }
        val id = java.util.UUID.randomUUID().toString()
        sql.exec("INSERT INTO lifecycle_jobs(id,adapter,owner,document,payload,checkpoint,source) VALUES (?,?,?,?,?,?,?)",id,adapter,owner,document,payload,checkpoint,source)
        for (phase in acknowledged) sql.exec("INSERT INTO lifecycle_acks VALUES (?,?)",id,phase)
        if (source != null) sql.exec("INSERT INTO sync_imports(adapter,source,job,proof) VALUES (?,?,?,?)",adapter,source,id,proof)
        id
    }
    fun imported(adapter: String, source: String): String? = sql.query("SELECT job FROM sync_imports WHERE adapter=? AND source=?",adapter,source) { it.text(0) }.firstOrNull()
    fun importProof(adapter: String, source: String): ByteArray? = sql.query("SELECT proof FROM sync_imports WHERE adapter=? AND source=?",adapter,source) { it.bytes(0) }.firstOrNull()
    fun imports(adapter: String): List<Pair<String,ByteArray>> = sql.query("SELECT source,proof FROM sync_imports WHERE adapter=? AND retired=0",adapter) { it.text(0)!! to it.bytes(1)!! }
    fun retired(adapter: String, source: String) = sql.transaction {
        sql.exec("UPDATE sync_imports SET retired=1 WHERE adapter=? AND source=?",adapter,source)
        sql.exec("UPDATE lifecycle_jobs SET retired=1 WHERE adapter=? AND source=?",adapter,source)
    }
    fun window(adapter: String, owner: String): List<Entry> = sql.query(
        "SELECT id,document,payload,checkpoint,source,retired FROM lifecycle_jobs WHERE adapter=? AND owner=? AND done=0 ORDER BY sequence LIMIT ?",adapter,owner,WINDOW) { row ->
        val id=row.text(0)!!
        Entry(id,adapter,owner,row.text(1)!!,row.bytes(2)!!,
            sql.query("SELECT phase FROM lifecycle_acks WHERE id=?",id) { it.text(0)!! }.toSet(),row.bytes(3)!!,row.text(4),row.long(5)==1L)
    }
    fun acknowledge(id: String, phase: String, checkpoint: ByteArray) = sql.transaction {
        require(phase in PHASES && checkpoint.size <= MAX_BYTES)
        sql.exec("UPDATE lifecycle_jobs SET checkpoint=? WHERE id=?",checkpoint,id)
        sql.exec("INSERT OR IGNORE INTO lifecycle_acks VALUES (?,?)",id,phase)
    }
    fun checkpoint(id: String, checkpoint: ByteArray) {
        require(checkpoint.size <= MAX_BYTES)
        sql.exec("UPDATE lifecycle_jobs SET checkpoint=? WHERE id=?",checkpoint,id)
    }
    fun finish(id: String) {
        check(sql.query("SELECT COUNT(*) FROM lifecycle_acks WHERE id=?",id) { it.long(0)!! }.single()==PHASES.size.toLong())
        // Imported payloads and provenance remain as a migration backup after delivery.
        sql.transaction {
            val imported=sql.query("SELECT source FROM lifecycle_jobs WHERE id=?",id) { it.text(0) }.firstOrNull()!=null
            if(imported) sql.exec("UPDATE lifecycle_jobs SET done=1 WHERE id=?",id)
            else { sql.exec("DELETE FROM lifecycle_acks WHERE id=?",id); sql.exec("DELETE FROM lifecycle_jobs WHERE id=?",id) }
        }
    }
    fun pending(adapter: String, owner: String): Int = sql.query("SELECT COUNT(*) FROM lifecycle_jobs WHERE adapter=? AND owner=? AND done=0",adapter,owner) { it.long(0)!!.toInt() }.single()
    fun pending(): Int = sql.query("SELECT COUNT(*) FROM lifecycle_jobs WHERE done=0") { it.long(0)!!.toInt() }.single()
    fun contains(id: String): Boolean = sql.query("SELECT 1 FROM lifecycle_jobs WHERE id=? AND done=0",id) { true }.isNotEmpty()
    fun records(adapter: String, owner: String): List<Pair<String,Map<String,Any?>>> = sql.query("SELECT document,body FROM sync_records WHERE adapter=? AND owner=? ORDER BY rowid DESC LIMIT 300",adapter,owner) {
        val raw=LuaValue.parse(it.bytes(1)!!) as? Map<*, *>
        it.text(0)!! to raw.orEmpty().entries.associate { e -> e.key.toString() to e.value }
    }
    fun record(adapter: String, owner: String, document: String): Map<*, *> = sql.query(
        "SELECT body FROM sync_records WHERE adapter=? AND owner=? AND document=?",adapter,owner,document) { LuaValue.parse(it.bytes(0)!!) as? Map<*, *> }.firstOrNull().orEmpty()
    fun record(adapter: String, owner: String, document: String, record: Map<String,Any?>) {
        val body=LuaValue.encode(record); require(body.size <= 65536)
        sql.exec("INSERT OR REPLACE INTO sync_records VALUES (?,?,?,?)",adapter,owner,document,body)
    }
}

/** Opaque adapter checkpoint returned after one phase. A deferred phase remains unacknowledged. */
data class SyncPhaseResult(val checkpoint: ByteArray, val complete: Boolean = true)

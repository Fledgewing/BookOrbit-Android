package net.fledgewing.orbitcompanion

/** Position-only convenience over the five-phase journal, retained from the prerequisite.
 * Runtime writes are authorized and drained exclusively by SyncOwner. There is one journal,
 * not a second position database/writer. Commit precedes transport; failed acks replay. */
class ProgressOutbox(sql: Sql, private val now: ()->Long = { System.currentTimeMillis()/1000 }) {
    companion object {
        const val MAX_PENDING=1000
        const val MAX_POSITION_BYTES=4096
        const val MAX_BATCH=LifecycleQueue.WINDOW
    }
    private val journal=LifecycleQueue(sql)
    fun enqueue(adapter: String,owner: String,document: String,update: Map<String,Any?>): String {
        require(adapter.isNotBlank() && adapter.length<=100 && owner.isNotBlank() && owner.length<=1024)
        require(document.isNotBlank() && document.length<=1024)
        val fraction=(update["percentage"] as? Number)?.toDouble() ?: throw IllegalArgumentException("percentage")
        require(fraction.isFinite() && fraction in 0.0..1.0)
        val position=update["position"]
        require(position==null || position is String && position.length<=MAX_POSITION_BYTES && position.all { it.code<=255 })
        val body=LuaValue.encode(mapOf("percentage" to fraction,"position" to position,"capturedAt" to now()))
        require(body.size<=16384)
        return journal.enqueue(adapter,owner,document,body,LifecycleQueue.PHASES.take(4).toSet())
    }
    fun count()=journal.pending()
    fun count(adapter: String,owner: String)=journal.pending(adapter,owner)
    fun contains(id: String)=journal.contains(id)
}

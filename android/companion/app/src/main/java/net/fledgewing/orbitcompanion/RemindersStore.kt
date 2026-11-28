// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

/** Separate device database, never account/cache scoped. Two bounded checksummed snapshots
 * are committed together. Invalid bytes are retained; only explicit Retry reloads them. */
class RemindersStore(private val db: Sql) : Reminders.Store, AutoCloseable {
    override fun close() = db.close()
    var recovered = false
        private set
    private var loaded = false
    private var committed: ByteArray? = null
    init {
        db.exec("CREATE TABLE IF NOT EXISTS reminders_state(slot INTEGER PRIMARY KEY CHECK(slot IN (0,1)), body BLOB NOT NULL CHECK(length(body)<=8192), digest TEXT NOT NULL)")
    }
    private fun hash(b: ByteArray)=MessageDigest.getInstance("SHA-256").digest(b).joinToString("") {"%02x".format(it)}
    override fun load(): Reminders.State {
        val rows=db.query("SELECT slot,CASE WHEN length(body)<=8192 THEN body END,CASE WHEN length(digest)=64 THEN digest END FROM reminders_state ORDER BY slot LIMIT 2") {Triple(it.long(0)!!,it.bytes(1) ?: byteArrayOf(),it.text(2).orEmpty())}
        if(rows.isEmpty()) { loaded=true; return Reminders.State() }
        for((slot,body,digest) in rows) {
            val result=runCatching { require(slot in 0..1 && body.size<=8192 && hash(body)==digest); decode(body).also(Reminders::validate) }
            if(result.isSuccess) {
                recovered=slot==1L; loaded=true; committed=body
                return result.getOrThrow()
            }
        }
        loaded=false; throw IllegalStateException("Reminders could not be loaded")
    }
    override fun save(state: Reminders.State) {
        check(loaded)
        Reminders.validate(state)
        val body=encode(state); require(body.size<=8192)
        db.transaction {
            committed?.let {db.exec("INSERT OR REPLACE INTO reminders_state VALUES(1,?,?)",it,hash(it))}
            db.exec("INSERT OR REPLACE INTO reminders_state VALUES(0,?,?)",body,hash(body))
        }
        committed=body
    }
    companion object {
        fun encode(s: Reminders.State): ByteArray {
            val rows=s.records.map {r -> JSONObject().put("id",r.id).put("kind",r.kind).put("revision",r.revision)
                .put("enabled",r.enabled).put("minute",r.minuteOfDay).put("days",r.days).put("message",r.message)
                .put("interval",r.intervalMinutes).put("after",r.after).put("highWater",r.highWater)
                .put("mutation",r.mutation).put("response",r.response)
                .put("snooze",r.snooze?.let {JSONObject().put("original",it.original).put("due",it.due).put("sequence",it.sequence)}) }
            return JSONObject().put("version",1).put("generation",s.generation).put("rows",JSONArray(rows)).put("deletedId",s.deletedId).put("deletion",s.deletion).toString().toByteArray(Charsets.UTF_8)
        }
        fun decode(body: ByteArray): Reminders.State {
            require(body.size<=8192)
            val root=JSONObject(body.toString(Charsets.UTF_8)); require(root.get("version") is Number && root.getInt("version")==1 && root.getDouble("version")==1.0)
            require(root.keys().asSequence().toSet().all {it in setOf("version","generation","rows","deletedId","deletion")})
            val array=root.getJSONArray("rows"); require(array.length() in 1..9)
            fun JSONObject.text(k: String)=if(has(k)) getString(k) else null
            fun JSONObject.long(k: String):Long {
                val n=get(k);require(n is Number && n.toDouble().isFinite() && n.toLong().toDouble()==n.toDouble())
                return n.toLong()
            }
            fun JSONObject.int(k: String):Int? = if(has(k)) long(k).also {require(it in Int.MIN_VALUE..Int.MAX_VALUE)}.toInt() else null
            val rows=(0 until array.length()).map {i ->
                val r=array.getJSONObject(i)
                require(r.keys().asSequence().toSet().all {it in setOf("id","kind","revision","enabled","minute","days","message","interval","after","highWater","mutation","response","snooze")})
                val snooze=r.optJSONObject("snooze")?.let {require(it.keys().asSequence().toSet()==setOf("original","due","sequence"));Reminders.Snooze(it.getString("original"),it.long("due"),it.int("sequence")!!)}
                Reminders.Record(r.getString("id"),r.getString("kind"),r.long("revision"),r.get("enabled").let {require(it is Boolean);it},
                    r.int("minute"),r.int("days"),r.text("message"),r.int("interval"),r.long("after"),r.text("highWater"),snooze,r.text("mutation"),r.text("response"))
            }
            return Reminders.State(rows,root.text("deletedId"),root.text("deletion"),if(root.has("generation")) root.long("generation") else 0).also(Reminders::validate)
        }
    }
}

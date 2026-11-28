// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

/** Separate device database, never account/cache scoped. Two bounded checksummed snapshots
 * are committed together. Invalid bytes are retained; only explicit Retry reloads them. */
class RemindersStore(private val db: Sql) : Reminders.Store {
    var recovered = false
        private set
    private var loaded = false
    private var committed: ByteArray? = null
    init {
        db.exec("CREATE TABLE IF NOT EXISTS reminders_state(slot INTEGER PRIMARY KEY CHECK(slot IN (0,1)), body BLOB NOT NULL CHECK(length(body)<=8192), digest TEXT NOT NULL)")
    }
    private fun hash(b: ByteArray)=MessageDigest.getInstance("SHA-256").digest(b).joinToString("") {"%02x".format(it)}
    override fun load(): Reminders.State {
        val rows=db.query("SELECT slot,body,digest FROM reminders_state ORDER BY slot LIMIT 2") {Triple(it.long(0)!!,it.bytes(1)!!,it.text(2)!!)}
        if(rows.isEmpty()) { loaded=true; return Reminders.State() }
        for((slot,body,digest) in rows) {
            val result=runCatching { require(body.size<=8192 && hash(body)==digest); decode(body).also(Reminders::validate) }
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
            return JSONObject().put("version",1).put("rows",JSONArray(rows)).put("deletedId",s.deletedId).put("deletion",s.deletion).toString().toByteArray(Charsets.UTF_8)
        }
        fun decode(body: ByteArray): Reminders.State {
            require(body.size<=8192)
            val root=JSONObject(body.toString(Charsets.UTF_8)); require(root.getInt("version")==1)
            val array=root.getJSONArray("rows"); require(array.length() in 1..9)
            fun JSONObject.text(k: String)=if(has(k)) getString(k) else null
            fun JSONObject.int(k: String)=if(has(k)) getInt(k) else null
            val rows=(0 until array.length()).map {i ->
                val r=array.getJSONObject(i)
                val snooze=r.optJSONObject("snooze")?.let {Reminders.Snooze(it.getString("original"),it.getLong("due"),it.getInt("sequence"))}
                Reminders.Record(r.getString("id"),r.getString("kind"),r.getLong("revision"),r.getBoolean("enabled"),
                    r.int("minute"),r.int("days"),r.text("message"),r.int("interval"),r.getLong("after"),r.text("highWater"),snooze,r.text("mutation"),r.text("response"))
            }
            return Reminders.State(rows,root.text("deletedId"),root.text("deletion")).also(Reminders::validate)
        }
    }
}

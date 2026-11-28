// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** Device-owned, additive ledger. No catalog status, account identity or borrowed DB writes.
 * Native revisions are saved with reader intent before dispatch, so replays and reordering
 * cannot resurrect an undone completion. Imports never replace a native event. */
class LocalCompletion(private val db: Sql, private val now: () -> Long,
                      private val zone: ZoneId = ZoneId.systemDefault()) {
    init {
        db.exec("CREATE TABLE IF NOT EXISTS local_completions(document TEXT PRIMARY KEY,revision INTEGER NOT NULL,token TEXT NOT NULL,finished_on TEXT,provenance TEXT NOT NULL)")
        db.exec("CREATE INDEX IF NOT EXISTS local_completions_year ON local_completions(finished_on)")
        db.exec("CREATE TABLE IF NOT EXISTS local_completion_tokens(token TEXT PRIMARY KEY,document TEXT NOT NULL,before_date TEXT)")
        db.exec("CREATE TABLE IF NOT EXISTS local_goals(year INTEGER PRIMARY KEY,target INTEGER)")
        db.exec("CREATE TABLE IF NOT EXISTS local_completion_imports(checkpoint TEXT PRIMARY KEY)")
    }
    private fun today() = Instant.ofEpochSecond(now()).atZone(zone).toLocalDate()
    private fun identity(document: String) = require(document.matches(Regex("[a-fA-F0-9]{32}")))
    private fun date(value: String?): LocalDate? = runCatching { LocalDate.parse(value) }.getOrNull()
        ?.takeIf { it.year >= 2020 && !it.isAfter(today()) }
    fun event(document: String, revision: Long, token: String, complete: Boolean, at: Long) = db.transaction {
        identity(document)
        require(revision in 1..9007199254740991 && token == "$document:$revision")
        require(at in 1577836800..now())
        val old = db.query("SELECT revision FROM local_completions WHERE document=?",document.lowercase()) { it.long(0)!! }.firstOrNull()
        if (old == null || revision > old) db.exec("INSERT OR REPLACE INTO local_completions VALUES(?,?,?,?,?)",
            document.lowercase(),revision,token,if(complete) Instant.ofEpochSecond(at).atZone(zone).toLocalDate().toString() else null,"native-mark")
    }
    /** The existing catalog workflow checkpoints the same explicit local intent. Its stable
     * token deduplicates crash recovery; Undo restores the prior local date, even unknown. */
    fun catalogIntent(document: String, token: String, complete: Boolean, undo: String? = null, order: Long = now()*1000000) = db.transaction {
        identity(document)
        require(token.length in 1..128)
        if(db.query("SELECT token FROM local_completion_tokens WHERE token=?",token) {it.text(0)}.isNotEmpty()) return@transaction
        val before=db.query("SELECT finished_on FROM local_completions WHERE document=?",document.lowercase()) {it.text(0)}.firstOrNull()
        val restored=if(undo!=null) db.query("SELECT before_date FROM local_completion_tokens WHERE token=? AND document=?",undo,document.lowercase()) {it.text(0)}.firstOrNull() else null
        val day=if(undo!=null) restored else if(complete) Instant.ofEpochSecond(order/1000000).atZone(zone).toLocalDate().toString() else null
        require(order in 1577836800000000..9007199254740991)
        val previous=revision(document)
        val revision=order
        db.exec("INSERT INTO local_completion_tokens VALUES(?,?,?)",token,document.lowercase(),before)
        if(revision>previous) db.exec("INSERT OR REPLACE INTO local_completions VALUES(?,?,?,?,?)",document.lowercase(),revision,"$document:$revision",day,"native-card-mark")
    }
    /** A 0.11 native summary alone is ambiguous (remote sync also wrote it). A matching
     * local finish job, digest and exact valid summary date are the required provenance. */
    fun import011(document: String, summary: Map<*, *>, job: Map<*, *>) = db.transaction {
        identity(document)
        val day = date(summary["modified"] as? String)
        if (summary["status"] != "complete" || day == null || job["hash"] != document || job["finished_on"] != day.toString()) return@transaction
        val created = (job["created_at"] as? Number)?.toLong() ?: return@transaction
        if (created !in 1577836800..now() || Instant.ofEpochSecond(created).atZone(zone).toLocalDate() != day) return@transaction
        val checkpoint = "$document:$day:$created"
        if (db.query("SELECT checkpoint FROM local_completion_imports WHERE checkpoint=?",checkpoint) { it.text(0) }.isNotEmpty()) return@transaction
        db.exec("INSERT OR IGNORE INTO local_completions VALUES(?,0,?,?,?)",document.lowercase(),checkpoint,day.toString(),"0.11-native-finish-job")
        db.exec("INSERT INTO local_completion_imports VALUES(?)",checkpoint)
    }
    fun revision(document: String): Long = db.query("SELECT revision FROM local_completions WHERE document=?",document.lowercase()) { it.long(0)!! }.firstOrNull() ?: 0L
    fun setGoal(input: String?) = db.transaction {
        val target = input?.let { require(it.matches(Regex("[0-9]{1,3}"))); it.toInt().also { n -> require(n in 1..999) } }
        db.exec("INSERT OR REPLACE INTO local_goals VALUES(?,?)",today().year,target)
    }
    fun snapshot(): Map<String, Any?> = db.transaction {
        val year = today().year
        // A null target is an explicit Off record and carries forward as Off.
        val saved = db.query("SELECT target FROM local_goals WHERE year<=? ORDER BY year DESC LIMIT 1",year) { it.long(0) }
        val target = saved.firstOrNull()
        db.exec("INSERT OR IGNORE INTO local_goals VALUES(?,?)",year,target)
        val count = db.query("SELECT COUNT(*) FROM local_completions WHERE finished_on>=? AND finished_on<?","$year-01-01","${year+1}-01-01") { it.long(0)!! }.single()
        mapOf("year" to year,"target" to target,"books_this_year" to count,"completion_available" to true,
            "source" to "this reader", "goal_label" to LuaValue.str(if(target==null) "Off · This reader only" else "$year · $target books · This reader only"),
            "count_label" to LuaValue.str("$count ${if(count==1L) "book" else "books"} · This reader only"),
            "freshness" to mapOf("saved" to true))
    }
}

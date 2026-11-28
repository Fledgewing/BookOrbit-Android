// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.time.Instant
import java.time.ZoneId

class LocalCompletionTest {
    private val document="a".repeat(32)
    private fun at(s:String)=Instant.parse(s).epochSecond
    private fun fixture(block:(File)->Unit) { val dir=Files.createTempDirectory("local-completion").toFile();try {block(File(dir,"ledger.db"))} finally {dir.deleteRecursively()} }
    @Test fun retriesReorderingUndoRefinishAndRestart() = fixture { file ->
        var now=at("2026-12-31T23:30:00Z")
        JdbcSql(file).use { db -> val l=LocalCompletion(db,{now},ZoneId.of("UTC"))
            l.event(document,1,"$document:1",true,now)
            l.event(document,1,"$document:1",true,now)
            assertEquals(1L,l.snapshot()["books_this_year"])
            l.event(document,3,"$document:3",false,now)
            l.event(document,2,"$document:2",true,now)
            assertEquals(0L,l.snapshot()["books_this_year"])
            l.setGoal("12")
        }
        now=at("2027-01-01T00:30:00Z")
        JdbcSql(file).use { db -> val l=LocalCompletion(db,{now},ZoneId.of("UTC"))
            assertEquals(12L,l.snapshot()["target"])
            assertEquals(0L,l.snapshot()["books_this_year"])
            l.event(document,4,"$document:4",true,now)
            assertEquals(1L,l.snapshot()["books_this_year"])
            l.setGoal(null)
        }
        now=at("2028-01-01T00:30:00Z")
        JdbcSql(file).use { db -> val l=LocalCompletion(db,{now},ZoneId.of("UTC"))
            assertNull(l.snapshot()["target"])
            assertEquals(12L,db.query("SELECT target FROM local_goals WHERE year=2026") {it.long(0)}.single())
        }
    }
    @Test fun importsAreProvenAdditiveAndCannotResurrectUndo() = fixture { file -> JdbcSql(file).use { db ->
        val now=at("2026-11-27T20:00:00Z");val l=LocalCompletion(db,{now},ZoneId.of("UTC"))
        val summary=mapOf("status" to "complete","modified" to "2026-11-26")
        val job=mapOf("hash" to document,"finished_on" to "2026-11-26","created_at" to at("2026-11-26T12:00:00Z"))
        l.import011(document,summary,emptyMap<Any,Any>())
        l.import011(document,summary+mapOf("modified" to "2026-02-30"),job)
        l.import011(document,summary,job+mapOf("created_at" to now))
        assertEquals(0L,l.snapshot()["books_this_year"])
        l.import011(document,summary,job);l.import011(document,summary,job)
        assertEquals(1L,l.snapshot()["books_this_year"])
        val second="b".repeat(32)
        l.import011(second,summary,job+mapOf("hash" to second))
        assertEquals(2L,l.snapshot()["books_this_year"])
        l.event(document,1,"$document:1",false,now)
        l.import011(document,summary,job)
        assertEquals(1L,l.snapshot()["books_this_year"])
        assertEquals(2L,db.query("SELECT COUNT(*) FROM local_completion_imports") {it.long(0)}.single())
    } }
    @Test fun cardTokensDeduplicateAndUndoRestoresOriginalLocalDate() = fixture { file -> JdbcSql(file).use { db ->
        var now=at("2026-11-26T20:00:00Z");val l=LocalCompletion(db,{now},ZoneId.of("UTC"))
        l.catalogIntent(document,"first",true)
        now+=86400
        l.catalogIntent(document,"unread",false)
        l.catalogIntent(document,"undo",true,"unread",now*1000000+1)
        assertEquals("2026-11-26",db.query("SELECT finished_on FROM local_completions") {it.text(0)}.single())
        l.catalogIntent(document,"unread",false)
        assertEquals(1L,l.snapshot()["books_this_year"])
    } }
    @Test fun targetRangeAndInvalidEvents() = fixture { file -> JdbcSql(file).use { db ->
        val now=at("2026-11-27T20:00:00Z");val l=LocalCompletion(db,{now})
        for(input in listOf("0","1000","-1","1.5","","12x"," 12")) {
            try {l.setGoal(input);fail(input)} catch(_:IllegalArgumentException) {}
        }
        for(input in listOf("1","999")) {l.setGoal(input);assertEquals(input.toLong(),l.snapshot()["target"])}
        for(time in listOf(0L,now+1)) {try {l.event(document,1,"$document:1",true,time);fail()} catch(_:IllegalArgumentException) {}}
        try {l.event(document,1,"wrong",true,now);fail()} catch(_:IllegalArgumentException) {}
        assertEquals(0L,l.snapshot()["books_this_year"])
    } }
    @Test fun midnightYearAndDstUseReaderZone() = fixture { file -> JdbcSql(file).use { db ->
        var now=at("2027-01-01T07:59:00Z");val l=LocalCompletion(db,{now},ZoneId.of("America/Los_Angeles"))
        l.event(document,1,"$document:1",true,now);l.setGoal("9")
        assertEquals(2026,l.snapshot()["year"]);assertEquals(1L,l.snapshot()["books_this_year"])
        now+=120
        assertEquals(2027,l.snapshot()["year"]);assertEquals(0L,l.snapshot()["books_this_year"]);assertEquals(9L,l.snapshot()["target"])
        now=at("2027-11-07T09:30:00Z")
        l.event(document,2,"$document:2",true,now-3600)
        l.event(document,3,"$document:3",true,now)
        assertEquals(1L,l.snapshot()["books_this_year"])
        assertEquals("2027-11-07",db.query("SELECT finished_on FROM local_completions") {it.text(0)}.single())
    } }
    @Test fun tenThousandCompletionsUseIndexedCountAndOneSmallSummary() = fixture { file -> JdbcSql(file).use { db ->
        val l=LocalCompletion(db,{at("2026-11-27T20:00:00Z")},ZoneId.of("UTC"))
        db.transaction { repeat(10001) { n ->
            db.exec("INSERT INTO local_completions VALUES(?,1,?,?,'native-mark')","%032x".format(n),"token:$n","2026-11-26")
        } }
        assertEquals(10001L,l.snapshot()["books_this_year"])
        assertTrue(LuaValue.encode(l.snapshot()).size<16384)
        val plan=db.query("EXPLAIN QUERY PLAN SELECT COUNT(*) FROM local_completions WHERE finished_on>=? AND finished_on<?","2026-01-01","2027-01-01") {it.text(3)}.joinToString()
        assertTrue(plan,plan.contains("local_completions_year"))
    } }
    @Test fun localAndAccountGoalPairsNeverMix() {
        val now=at("2026-11-27T20:00:00Z")
        val local=ReadingStats.withLocalCompletion(emptyMap(),mapOf("target" to 12L,"books_this_year" to 3L,"completion_available" to true))
        fun goal(remote:RemoteReadingStats?)=ReadingStats.combine(local,remote,now)["goal"] as Map<*,*>
        assertEquals(3L,goal(null)["books_this_year"])
        assertEquals(12L,goal(null)["target"])
        assertNull(goal(RemoteReadingStats(target=20,goalAvailable=true))["books_this_year"])
        assertNull(goal(RemoteReadingStats(finished=8))["target"])
        val remote=ReadingStats.combine(local,RemoteReadingStats(target=20,goalAvailable=true,finished=8),now)
        assertEquals(8L,(remote["goal"] as Map<*,*>)["books_this_year"])
        assertEquals(3L,(remote["local_goal"] as Map<*,*>)["books_this_year"])
        assertTrue(LuaValue.encode(remote).size<16384)
    }
}

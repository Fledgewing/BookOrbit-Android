// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.time.Instant
import java.time.ZoneOffset

class PersonalReadingTest {
    private fun toy(vararg records: PersonalReadingRecord) = object: PersonalReadingSource {
        override val capabilities=PersonalReading.KINDS
        override fun read(kind: String, now: Long)=records.toList()
    }
    private fun rec(id:String, text:String=id)=PersonalReadingRecord(id,mapOf("passage" to text))
    @Test fun orderedMergeDedupeFailureAndCapabilityIsolation() {
        val broken=object:PersonalReadingSource {
            override val capabilities=PersonalReading.KINDS
            override fun read(kind:String,now:Long):List<PersonalReadingRecord> = error("unavailable")
        }
        val absent=object:PersonalReadingSource {
            override val capabilities=emptySet<String>()
            override fun read(kind:String,now:Long):List<PersonalReadingRecord> = error("must skip")
        }
        val registry=PersonalReading(listOf(absent,toy(rec("a","first")),broken,toy(rec("a","duplicate"),rec("b","second"))))
        val values=(0..3).map { registry.window("highlight",it*86400L+43200)["passage"] }
        assertEquals(setOf("first","second"),values.toSet()); assertEquals(values[0],values[2])
        assertEquals("ready",PersonalReading(listOf(broken,toy(rec("a")))).window("highlight",1)["state"])
        assertEquals("error",PersonalReading(listOf(broken)).window("yearago",1)["state"])
        assertEquals("empty",PersonalReading(listOf(toy())).window("yearago",1)["state"])
        assertEquals("error",PersonalReading(listOf(toy(rec("a","x".repeat(17000))))).window("highlight",1)["state"])
    }
    @Test fun sidecarDailySelectionSurvivesRestartAndChangesWithoutRepeats() {
        val root=Files.createTempDirectory("personal-fixture").toFile()
        try {
            File(root,"moon.epub").writeText("fixture")
            File(root,"moon.sdr/metadata.epub.lua").apply {
                parentFile!!.mkdirs()
                writeText("-- synthetic\nreturn "+String(LuaValue.encode(mapOf("doc_props" to mapOf("title" to "The Moon"),"annotations" to
                    listOf(mapOf("pos0" to "a","text" to "First passage"),mapOf("pos0" to "b","text" to "Second passage"),mapOf("text" to "Bookmark")))) ,Charsets.ISO_8859_1))
            }
            fun window(day:Long)=PersonalReading(listOf(DevicePersonalReading(listOf(root),File(root,"missing")))).window("highlight",day*86400+43200)
            assertEquals(window(100),window(100))
            assertNotEquals(window(100)["passage"],window(101)["passage"])
            assertEquals(window(100)["passage"],window(102)["passage"])
            assertTrue(LuaValue.encode(window(100)).size<=16384)
            assertEquals(1,window(100)["row_count"])
            assertEquals("empty",PersonalReading(listOf(DevicePersonalReading(listOf(root),File(root,"missing")))).window("yearago",1)["state"])
        } finally { root.deleteRecursively() }
    }
    @Test fun historyUsesCalendarDayMinutesAndLatestStopAndLeapClamp() {
        val root=Files.createTempDirectory("history-fixture").toFile()
        try { JdbcSql(File(root,"stats.db")).use { db ->
            db.exec("CREATE TABLE book(id INTEGER,title TEXT)")
            db.exec("CREATE TABLE page_stat_data(id_book INTEGER,page INTEGER,start_time INTEGER,duration INTEGER)")
            val now=Instant.parse("2024-02-29T12:00:00Z").epochSecond
            assertTrue(DevicePersonalReading.yearago(db,now,ZoneOffset.UTC).isEmpty())
            db.exec("INSERT INTO book VALUES(1,'The Moon')")
            val start=Instant.parse("2023-02-28T00:00:00Z").epochSecond
            db.exec("INSERT INTO page_stat_data VALUES(1,7,?,120)",start+1)
            db.exec("INSERT INTO page_stat_data VALUES(1,9,?,180)",start+600)
            db.exec("INSERT INTO page_stat_data VALUES(1,99,?,999)",start+86400)
            val row=DevicePersonalReading.yearago(db,now,ZoneOffset.UTC).single().fields
            assertEquals(5L,row["minutes"]); assertEquals(1,row["days_read"]); assertEquals(9L,row["stop_page"])
            assertEquals("2023-02-28",row["date"])
        } } finally { root.deleteRecursively() }
    }
}

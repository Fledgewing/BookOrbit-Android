// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.time.Instant
import java.time.ZoneOffset

class ReadingCardTest {
    private val now=Instant.parse("2026-11-26T12:00:00Z").epochSecond
    private val md5="a".repeat(32)
    private fun fixture(run: (File, Sql) -> Unit) {
        val dir=Files.createTempDirectory("card-fixture").toFile()
        try { JdbcSql(File(dir,"statistics.sqlite3")).use { db ->
            db.exec("CREATE TABLE book(id INTEGER,md5 TEXT)")
            db.exec("CREATE TABLE page_stat_data(id_book INTEGER,page INTEGER,start_time INTEGER,duration INTEGER,total_pages INTEGER)")
            db.exec("INSERT INTO book VALUES(1,?),(2,'other')",md5)
            run(dir,db)
        } } finally { dir.deleteRecursively() }
    }
    @Test fun normalizedPaceSurvivesLayoutChangesAndIgnoresOtherBooksAndInvalidVisits() = fixture { _,db ->
        // Each visit covers one percent of the book, despite different page counts.
        for(i in 1..5) db.exec("INSERT INTO page_stat_data VALUES(1,?,?,60,100)",i,now-i*60)
        val first=ReadingStats.forecast(db,md5,0.5,now,600,ZoneOffset.UTC)
        assertEquals("50 m left",first["time_left"])
        assertEquals("Done by Tue 1 Dec",first["finish_forecast"])
        db.exec("UPDATE page_stat_data SET total_pages=200")
        assertEquals("1 h 40 m left",ReadingStats.forecast(db,md5,0.5,now,600,ZoneOffset.UTC)["time_left"])
        db.exec("INSERT INTO page_stat_data VALUES(2,1,?,600,100),(1,0,?,600,100),(1,1,?,0,100),(1,1,?,99999,100),(1,1,?,60,100)",now-60,now-60,now-60,now-60,now+60)
        assertEquals("1 h 40 m left",ReadingStats.forecast(db,md5,0.5,now,0,ZoneOffset.UTC)["time_left"])
        assertNull(ReadingStats.forecast(db,md5,0.5,now,0,ZoneOffset.UTC)["finish_forecast"])
    }
    @Test fun unknownPaceLocatorAndIdentityNeverProduceAFinishDate() = fixture { _,db ->
        for(i in 1..4) db.exec("INSERT INTO page_stat_data VALUES(1,?,?,60,100)",i,now-i*60)
        assertTrue(ReadingStats.forecast(db,md5,0.5,now,600).isEmpty())
        for(fraction in listOf(null,Double.NaN,-0.1,1.1)) assertTrue(ReadingStats.forecast(db,md5,fraction,now,600).isEmpty())
        assertTrue(ReadingStats.forecast(db,"missing",0.5,now,600).isEmpty())
        assertEquals("Finished",ReadingStats.forecast(db,md5,1.0,now,600)["time_left"])
    }
    @Test fun registryUsesDeviceIdentityAndLocalProgressWithoutATitleJoin() = fixture { dir,db ->
        val file=File(dir,"moon.epub").apply { writeText("fixture") }
        File(dir,"moon.sdr/metadata.epub.lua").apply {
            parentFile!!.mkdirs()
            writeText("return "+String(LuaValue.encode(mapOf("partial_md5_checksum" to md5,"percent_finished" to 0.5)),Charsets.ISO_8859_1))
        }
        for(i in 1..5) db.exec("INSERT INTO page_stat_data VALUES(1,?,?,60,100)",i,now-i*60)
        val source=DevicePersonalReading(listOf(dir),File(dir,"statistics.sqlite3")) { JdbcSql(it) }
        val fallback=object:PersonalReadingSource {
            override val capabilities=emptySet<String>()
            override fun read(kind:String,now:Long)=emptyList<PersonalReadingRecord>()
            override fun card(book:Map<String,Any?>,now:Long,dailySeconds:Long)=mapOf("time_left" to "fallback")
        }
        val row=mapOf("title" to "Same title","local_path" to file.path,"progress" to 10)
        val card=PersonalReading(listOf(source,fallback)).card(row,now,600)
        assertEquals(50.0,card["progress"])
        assertEquals("50 m left",card["time_left"])
        assertEquals("fallback",PersonalReading(listOf(source,fallback)).card(row-"local_path",now,600)["time_left"])
        assertTrue(LuaValue.encode(card).size<LibraryReadModel.MAX_BYTES)
    }
    @Test fun localWindowPublishesCoverSeriesAndForecastInOneBoundedRow() = fixture { dir,db ->
        val folder=File(dir,"Books").apply { mkdirs() }
        File(folder,"moon.epub").writeText("fixture")
        val sidecar=File(folder,"moon.sdr").apply { mkdirs() }
        val cover=File(sidecar,"cover.jpg").apply { writeText("fixture cover") }
        File(sidecar,"metadata.epub.lua").writeText("return "+String(LuaValue.encode(mapOf(
            "doc_props" to mapOf("title" to "The Moon","series" to "Moon","series_index" to 2),
            "partial_md5_checksum" to md5,"percent_finished" to 0.5)),Charsets.ISO_8859_1))
        for(i in 1..5) db.exec("INSERT INTO page_stat_data VALUES(1,?,?,60,100)",i,now-i*60)
        val root=File(dir,"koreader/settings/orbit-cache").apply { mkdirs() }
        JdbcSql(File(root,"cache.sqlite3")).use { sql ->
            LibraryReadModel.initialize(sql)
            val store=object:ProjectionStore {
                override val root=root
                override fun db()=sql
                override fun meta(k:String):String?=null
                override fun <T> transaction(block:()->T):T=sql.transaction(block)
                override fun close() {}
            }
            val model=LibraryReadModel(store,{now},{},readingStats={ mapOf("year" to mapOf("seconds" to List(365) { 600L })) },
                personalDevice={ DevicePersonalReading(listOf(dir),File(dir,"statistics.sqlite3")) { JdbcSql(it) } })
            val request=String(LuaValue.encode(mapOf("op" to "window","source" to "reading","limit" to 1,"bytes" to 16384)),Charsets.ISO_8859_1)
            assertTrue(model.publish(DeviceLibrary.OWNER,listOf(request)))
            val bytes=sql.query("SELECT body FROM library_views") { it.bytes(0)!! }.single()
            assertTrue(bytes.size<=16384)
            val result=LuaValue.parse(bytes) as Map<*,*>
            val row=(result["items"] as List<*>).single() as Map<*,*>
            assertEquals(cover.path,row["cover_path"])
            assertEquals(true,(row["available"] as Map<*,*>)["cover"])
            assertEquals("Moon · Book 2",LuaValue.utf8(row["series_line"] as String))
            assertEquals("50 m left",row["time_left"])
            assertTrue((row["finish_forecast"] as String).startsWith("Done by "))
            assertEquals(50L,row["progress"])
        }
    }

}

// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.time.ZoneOffset

class LocalWidgetsTest {
    @Test fun oneBatchPublishesOnlyLocalRowsWithoutServerProjection() {
        val dir=Files.createTempDirectory("local-widget-batch").toFile()
        try { JdbcSql(java.io.File(dir,"views.sqlite3")).use { sql ->
            LibraryReadModel.initialize(sql)
            val store=object: ProjectionStore {
                override fun db()=sql
                override fun meta(k:String)=if(k=="owner") "fixture" else null
                override fun <T> transaction(block:()->T):T=sql.transaction(block)
                override fun close()=Unit
            }
            val adapter=object:ServerAdapter {
                override val id="fixture"
                override fun project(owner:String,request:Map<*,*>):Map<String,Any?> = error("no server projection")
            }
            var reads=0
            val model=LibraryReadModel(store,{86400},{},readingStats={reads++; mapOf("state" to "empty")},
                vocabulary={java.io.File(dir,"missing.sqlite3")},adapter=adapter)
            val requests=listOf("local.word","local.buddy","local.light").map { op ->
                String(LuaValue.encode(mapOf("op" to op,"limit" to 1,"bytes" to 16384)),Charsets.ISO_8859_1)
            }
            assertTrue(model.publish("fixture",requests)); assertEquals(1,reads)
            val rows=sql.query("SELECT body FROM library_views") { it.bytes(0)!! }
            assertEquals(3,rows.size)
            for(body in rows) {
                assertTrue(body.size<=16384)
                val result=LuaValue.parse(body) as Map<*,*>
                assertEquals(1L,result["row_count"])
            }
            assertFalse(model.publish("another-owner",requests))
        } } finally { dir.deleteRecursively() }
    }
    @Test fun vocabularyIsOneBoundedDailyRecordWithContextAndSource() {
        val dir=Files.createTempDirectory("local-widget").toFile()
        try { JdbcSql(java.io.File(dir,"vocabulary.sqlite3")).use { db ->
            db.exec("CREATE TABLE title(id INTEGER PRIMARY KEY,name TEXT)")
            db.exec("CREATE TABLE vocabulary(word TEXT PRIMARY KEY,title_id INTEGER,prev_context TEXT,next_context TEXT)")
            assertEquals("empty",LocalWidgets.word(db,86400,ZoneOffset.UTC)["state"])
            db.exec("INSERT INTO title VALUES(1,'The Moon')")
            db.exec("INSERT INTO vocabulary VALUES('lantern',1,'the','room')")
            val a=LocalWidgets.word(db,86400,ZoneOffset.UTC)
            assertEquals("lantern",a["word"]); assertEquals("the lantern room",a["context"]); assertEquals("The Moon",a["source"])
            assertEquals(a,LocalWidgets.word(db,86401,ZoneOffset.UTC))
            db.exec("INSERT INTO vocabulary VALUES('anchor',NULL,?,?)","x".repeat(10000),"y".repeat(10000))
            val b=LocalWidgets.word(db,2*86400,ZoneOffset.UTC)
            assertEquals("anchor",b["word"]); assertEquals("Source unavailable",b["source"])
            assertTrue(LuaValue.encode(b).size<16384); assertEquals(1,b["row_count"])
            assertEquals(2L,db.query("SELECT count(*) FROM vocabulary") { it.long(0) }.first())
        } } finally { dir.deleteRecursively() }
    }
    @Test fun missingVocabularyLightCapabilityAndLocalBuddyStates() {
        assertEquals("empty",LocalWidgets.word(java.io.File("missing-widget-vocabulary"),1)["state"])
        assertEquals("unavailable",LocalWidgets.light(emptyMap<Any,Any>())["state"])
        assertEquals("unavailable",LocalWidgets.light(mapOf("supported" to true,"level" to 101))["state"])
        assertEquals(LuaValue.str("Light · 40%"),LocalWidgets.light(mapOf("supported" to true,"level" to 40))["message"])
        assertEquals("empty",LocalWidgets.buddy(emptyMap())["state"])
        assertEquals("error",LocalWidgets.buddy(mapOf("state" to "error"))["state"])
        val buddy=LocalWidgets.buddy(mapOf("records" to mapOf("streak" to 3,"recorded_pages" to 20)))
        assertEquals(LuaValue.str("3 day reading streak · On this reader"),buddy["message"])
        assertEquals("ready",buddy["state"])
    }
}

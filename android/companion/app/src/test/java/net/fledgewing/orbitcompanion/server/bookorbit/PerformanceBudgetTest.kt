// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.time.ZoneOffset

/** Real SQLite/catalog/history projections. Elapsed host time is evidence, never a device gate. */
class PerformanceBudgetTest {
    @Test fun largeCatalogAndHistoryKeepEveryPublishedWindowBounded() {
        val root = Files.createTempDirectory("performance-fixture").toFile()
        val now = 1800000000L
        val owner = "performance-fixture"
        try {
            val volume=File(root,"volume")
            val books=File(volume,"Books").apply { mkdirs() }
            val localBook=File(books,"book.epub").apply { writeText("synthetic book") }
            val digest="00000000000000000000000000000001"
            File(books,"book.sdr/metadata.epub.lua").apply {
                parentFile!!.mkdirs()
                writeBytes("return ".toByteArray()+LuaValue.encode(mapOf("doc_props" to mapOf("title" to "Book 1"),
                    "percent_finished" to 0.25,"partial_md5_checksum" to digest,
                    "annotations" to listOf(mapOf("pos0" to "chapter.1","text" to "A synthetic highlight")))))
            }
            val cover=File(root,"cover.jpg").apply { writeText("synthetic cover reference") }
            val historyFile = File(volume,"koreader/settings/statistics.sqlite3").apply { parentFile!!.mkdirs() }
            val history = JdbcSql(historyFile)
            history.exec("CREATE TABLE book(id INTEGER PRIMARY KEY,title TEXT,md5 TEXT)")
            history.exec("INSERT INTO book VALUES(1,'Book 1','00000000000000000000000000000001')")
            history.exec("CREATE TABLE page_stat_data(id_book INTEGER,page INTEGER,start_time INTEGER,duration INTEGER,total_pages INTEGER)")
            history.exec("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<50000) INSERT INTO page_stat_data SELECT 1,x%300+1,?-x*900,60,300 FROM n",now)
            var chunks = 0
            var maxCursor = 0
            val counted = object : Sql by history {
                override fun <T> query(sql: String, vararg args: Any?, row: (Sql.Row) -> T): List<T> = history.query(sql,*args,row=row).also {
                    if (sql.startsWith("SELECT rowid,start_time,duration")) { chunks++; maxCursor=maxOf(maxCursor,it.size) }
                }
            }
            val start = System.nanoTime()
            val stats = ReadingStats.aggregate(counted, now, ZoneOffset.UTC)
            println("PERF history visits=50000 chunks=$chunks maxCursor=$maxCursor bytes=${LuaValue.encode(stats).size} ms=${(System.nanoTime()-start)/1000000}")
            assertEquals(50000L,(stats["records"] as Map<*,*>)["recorded_pages"])
            assertEquals(197,chunks)
            assertEquals(256,maxCursor)
            assertTrue(LuaValue.encode(stats).size<=16384)
            history.close()
            CacheStore(File(volume,"koreader/settings/orbit-cache"),{}) { JdbcSql(it) }.use { store ->
                store.own(owner)
                store.setMeta("bulk_active",1); store.setMeta("bulk_complete",1)
                store.setMeta("cover_file_1",LuaValue.str(cover.path))
                File(store.root,"copies/ask.lua").apply {
                    parentFile!!.mkdirs()
                    writeBytes(LuaValue.encode(mapOf("owner" to owner,"books" to listOf(mapOf("book_id" to 1,"path" to LuaValue.str(localBook.path),"md5" to digest)))))
                }
                store.transaction {
                    for (id in 1..10000) {
                        val row=mapOf("id" to id,"title" to "Book $id","authors" to listOf("Author ${id%100}"),
                            "readStatus" to if(id==1) "reading" else if(id%4==0) "read" else "unread",
                            "seriesName" to "Series ${id%100}","seriesId" to id%100+1,"seriesIndex" to id/100+1)
                        store.db().exec("INSERT INTO bulk_books(g,id,item) VALUES(1,?,?)",id,LuaValue.encode(row))
                    }
                    store.db().exec("INSERT INTO bulk_sections(g,section,pos,id,name,n) VALUES(1,'series',1,'series:1','Series 0',100)")
                    for(id in 100..10000 step 100) store.db().exec("INSERT INTO bulk_members(g,kind,value,id,context) VALUES(1,'seriesId','1',?,?)",id,LuaValue.encode(emptyMap<String,Any>()))
                }
                val key=BookOrbitLibrary.key(owner,"book",1)
                val cases = listOf(
                    "Continue reading" to mapOf("op" to "window","source" to "reading","limit" to 1),
                    "Book list" to mapOf("op" to "window","source" to "all","limit" to 12),
                    "Library" to mapOf("op" to "window","source" to "all","limit" to 24),
                    "Details" to mapOf("op" to "book","key" to key,"limit" to 1),
                    "Library summary" to mapOf("op" to "library.summary","limit" to 1),
                    "Storage" to mapOf("op" to "storage.summary","limit" to 1),
                    "Series" to mapOf("op" to "series","key" to BookOrbitLibrary.key(owner,"series",1),"limit" to 24),
                    "Filter" to mapOf("op" to "facets","source" to "all","field" to "author","limit" to 24),
                    "Source picker" to mapOf("op" to "sources","category" to "builtin","limit" to 6),
                    "End sheet" to mapOf("op" to "reader.finish","key" to key,"limit" to 3),
                    "Highlight" to mapOf("op" to "personal.reading","kind" to "highlight","limit" to 1),
                    "A year ago" to mapOf("op" to "personal.reading","kind" to "yearago","limit" to 1),
                    "Recommended" to mapOf("op" to "personal.reading","kind" to "recommended","limit" to 1),
                    "Discover" to mapOf("op" to "personal.reading","kind" to "discover","limit" to 1),
                    "Word" to mapOf("op" to "local.word","limit" to 1),
                    "Buddy" to mapOf("op" to "local.buddy","limit" to 1),
                    "Light" to mapOf("op" to "local.light","limit" to 1,"native" to mapOf("supported" to true,"level" to 25)),
                    "Clock" to mapOf("op" to "device.clock","limit" to 1),
                    "Battery" to mapOf("op" to "battery","limit" to 1),
                    "Stats" to mapOf("op" to "reading.stats","limit" to 1),
                    "Settings account" to mapOf("op" to "account.state","limit" to 1),
                    "Settings sleep" to mapOf("op" to "sleep.choices","category" to "lists","limit" to 6))
                val requests=cases.map { (_,args) -> String(LuaValue.encode(args+mapOf("bytes" to 16384)),Charsets.ISO_8859_1) }
                val spans=mutableListOf<String>()
                val worker=LibraryReadModel(store,{now},{spans.add(it)},readingStats={stats},
                    vocabulary={File(root,"missing-vocabulary")}, personalDevice={DevicePersonalReading(listOf(books),historyFile,open={JdbcSql(it)})},
                    sleepChoices={SleepChoices(at=now,cached=true,collections=emptyList(),tags=emptyList(),scopes=List(10000) { SleepChoices.Item(it.toLong(),"List $it",it) })})
                requests.chunked(16).forEach { worker.publish(owner,it) }
                val accountingErrors=mutableListOf<String>()
                for ((index,entry) in cases.withIndex()) {
                    val body=store.db().query("SELECT body FROM library_views WHERE owner=? AND request=?",owner,requests[index]) { it.bytes(0)!! }.single()
                    val result=LuaValue.parse(body) as Map<*,*>
                    val rows=(result["row_count"] as? Number)?.toInt() ?: (result["items"] as? List<*>)?.size ?: 1
                    println("PERF ${entry.first} rows=$rows bytes=${body.size} ${spans[index]}")
                    assertNull("${entry.first}: ${result["error"]}",result["error"])
                    if (entry.first=="Continue reading") {
                        val book=(result["items"] as List<*>).single() as Map<*,*>
                        assertEquals(LuaValue.str(cover.path),book["cover_path"])
                        assertEquals(25.0,(book["progress"] as Number).toDouble(),0.0)
                        assertEquals("this reader",book["forecast_source"])
                        assertNotEquals("Finish date unavailable",book["finish_forecast"])
                    }
                    if(entry.first in setOf("Highlight","A year ago","Recommended","Discover")) assertEquals(entry.first,"ready",result["state"])
                    assertTrue(entry.first,body.size<=16384)
                    assertTrue(entry.first,rows<=(entry.second["limit"] as Int))
                    if(!spans[index].contains("rows=$rows ")) accountingErrors.add(spans[index])
                }
                assertEquals("timing spans must count scalar rows too",emptyList<String>(),accountingErrors)
            }
        } finally { root.deleteRecursively() }
    }
}

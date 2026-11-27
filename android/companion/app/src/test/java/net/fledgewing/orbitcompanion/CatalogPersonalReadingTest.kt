// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test

class CatalogPersonalReadingTest {
    private fun book(key: String, status: String = "unread", series: String? = null, position: Double? = null, author: String = "A") =
        mapOf("key" to key, "title" to key, "status" to status, "series_key" to series, "series_position" to position, "authors" to listOf(author))
    private fun source(vararg rows: Map<String, Any?>) = CatalogPersonalReading { mapOf("items" to rows.toList(), "freshness" to mapOf("saved" to true)) }
    @Test fun seriesNextThenHistoryAffinityThenUnreadAndNoReadOrAbandoned() {
        val rows = source(book("first", "finished", "s", 1.0), book("third", series="s",position=3.0),
            book("second",series="s",position=2.0), book("familiar"), book("other",author="B"),
            book("reading","reading"),book("abandoned","abandoned"))
        val ranked=rows.read("recommended",1)
        assertEquals(listOf("second","familiar","third","other"),ranked.map { it.identity })
        assertEquals("Next in your series",ranked.first().fields["source"])
        assertEquals("An author you've read",ranked[1].fields["source"])
        assertEquals(4,rows.read("discover",1).size)
        assertTrue(rows.read("highlight",1).isEmpty())
    }
    @Test fun deviceSidecarsSupplySeriesAndHistoryWithoutMirror() {
        val root=java.nio.file.Files.createTempDirectory("recommendation-device").toFile()
        try {
            for ((name,status,index) in listOf(Triple("first","complete",1),Triple("second","new",2),Triple("third","new",3))) {
                java.io.File(root,"$name.epub").writeText("fixture")
                java.io.File(root,"$name.sdr/metadata.epub.lua").apply {
                    parentFile!!.mkdirs()
                    writeText("return "+String(LuaValue.encode(mapOf("doc_props" to mapOf("title" to name,"authors" to "A","series" to "s","series_index" to index),
                        "summary" to mapOf("status" to status))),Charsets.ISO_8859_1))
                }
            }
            val result=PersonalReading(listOf(DevicePersonalReading(listOf(root),java.io.File(root,"missing")))).window("recommended",1)
            assertEquals("second",(result["book"] as Map<*,*>)["title"])
            assertEquals("Next in your series",result["source"])
        } finally { root.deleteRecursively() }
    }
    @Test fun dailyPickRestartAnotherCycleAndToyFutureSource() {
        fun registry()=PersonalReading(listOf(source(book("a"),book("b"),book("c"))))
        val now=1800000000L
        val unicode=PersonalReading(listOf(source(book("a")+mapOf("title" to LuaValue.str("月"))))).window("discover",now)
        val wire=LuaValue.parse(LuaValue.encode(unicode)) as Map<*,*>
        assertEquals("Unread · saved library",LuaValue.utf8(wire["source"] as String))
        assertEquals("月",LuaValue.utf8((wire["book"] as Map<*,*>)["title"] as String))
        assertEquals(registry().window("discover",now),registry().window("discover",now+1))
        val picks=(0L..3L).map { registry().window("discover",now,it)["book"] }
        assertEquals(3,picks.take(3).toSet().size); assertEquals(picks[0],picks[3])
        assertTrue((0..20).map { registry().window("discover",now+86400*it)["book"] }.toSet().size>1)
        val toy=object:PersonalReadingSource {
            override val capabilities=setOf("recommended")
            override fun read(kind:String,now:Long)=listOf(PersonalReadingRecord("toy",mapOf("book" to book("toy"))))
        }
        assertEquals("a",((PersonalReading(listOf(source(book("a")),toy)).window("recommended",now)["book"] as Map<*,*>)["key"]))
        assertEquals("toy",((PersonalReading(listOf(source(),toy)).window("recommended",now)["book"] as Map<*,*>)["key"]))
        assertEquals("empty",PersonalReading(listOf(source())).window("discover",now)["state"])
        val missing=CatalogPersonalReading { mapOf("freshness" to mapOf("saved" to false)) }
        assertEquals("error",PersonalReading(listOf(missing)).window("recommended",now)["state"])
        val dedupe=PersonalReading(listOf(source(book("a")+mapOf("local_path" to "same")), source(book("mirror")+mapOf("local_path" to "same"))))
        assertEquals("a",((dedupe.window("discover",now)["book"] as Map<*,*>)["key"]))
        assertEquals(dedupe.window("discover",now),dedupe.window("discover",now,1))
        assertEquals(1,dedupe.window("discover",now)["row_count"])
        assertTrue(LuaValue.encode(dedupe.window("discover",now)).size<=16384)
    }
}

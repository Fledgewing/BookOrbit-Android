// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test

class PersonalReadingBudgetTest {
    @Test fun largeLibraryPicksShareOneRankedPoolPerBatch() {
        var reads = 0
        val records = List(10000) { PersonalReadingRecord("book:$it", mapOf("book" to mapOf("key" to "$it", "title" to "Book $it"))) }
        val source = object : PersonalReadingSource {
            override val capabilities = PersonalReading.KINDS
            override fun read(kind: String, now: Long): List<PersonalReadingRecord> { reads++; return records }
        }
        val production = PersonalReading(listOf(source))
        val productionStart = System.nanoTime()
        production.window("discover",1800000000,0)
        production.window("discover",1800000000,1)
        println("PERF discover production candidates=10000 picks=2 providerReads=$reads ms=${(System.nanoTime()-productionStart)/1000000}")
        assertEquals(1,reads)
        reads=0
        var ranks = 0
        val personal = PersonalReading(listOf(source), discoverRank = { ranks++; it })
        val start = System.nanoTime()
        val first = personal.window("discover", 1800000000, 0)
        val another = personal.window("discover", 1800000000, 1)
        println("PERF discover candidates=10000 picks=2 providerReads=$reads ranks=$ranks ms=${(System.nanoTime()-start)/1000000}")
        assertNotEquals(first["book"], another["book"])
        for (row in listOf(first, another)) {
            assertEquals(1, row["row_count"])
            assertTrue(LuaValue.encode(row).size <= LibraryReadModel.MAX_BYTES)
        }
        assertEquals("one provider read per kind/time in a worker batch", 1, reads)
        assertEquals("one rank per candidate, never per comparison or pick", 10000, ranks)
        personal.window("discover", 1800086400, 0)
        assertEquals(2, reads)
        assertEquals(20000, ranks)
        // A new publication must see changes; no cache survives the worker batch.
        PersonalReading(listOf(source)).window("recommended",1800086400)
        assertEquals(3, reads)
    }
}

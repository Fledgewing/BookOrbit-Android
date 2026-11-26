// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test

class ReaderControlsTest {
    private fun row(native: Map<String, Any?>): Map<*, *> =
        (ReaderControls.project(native)["items"] as List<*>).single() as Map<*, *>
    @Test fun missingAndInvalidPositionsStayUnknown() {
        for (native in listOf(emptyMap(), mapOf("page" to 1, "total" to 0),
            mapOf("page" to Double.NaN,"total" to 200),mapOf("page" to 201,"total" to 200))) {
            val item=row(native)
            assertNull(item["progress"])
            assertEquals("Position not available yet",item["position"])
            assertEquals(emptyList<Double>(),item["bookmarks"])
        }
    }
    @Test fun workerProjectsDistinctSortedMarkersAndDisplayLabels() {
        val item=row(mapOf("page" to 50,"total" to 200,"marked" to true,
            "chapters" to listOf(1,100,50,50,-1,201,Double.POSITIVE_INFINITY),"bookmarks" to listOf(200,1)))
        assertEquals(.25,item["progress"])
        assertEquals("p. 50 of 200 · 25%",item["position"])
        assertEquals("Chapter 2 of 3",item["chapter"])
        assertEquals(listOf(.005,.25,.5),item["chapters"])
        assertEquals(listOf(.005,1.0),item["bookmarks"])
        assertEquals(true,item["marked"])
    }
    @Test fun nativeChapterIdentityDoesNotBecomeTheSampleCount() {
        val item=row(mapOf("page" to 8000,"total" to 10000,"chapters" to (1..64).toList(),
            "chapter_total" to 1000,"chapter_index" to 800,"chapter_title" to "A chapter"))
        assertEquals("Chapter 800 of 1000",item["chapter"])
        assertEquals("800 · A chapter",item["chapter_title"])
        assertEquals(true,item["markers_reduced"])
    }
    @Test fun markerWindowsAndEncodedSnapshotStayBounded() {
        val native=mapOf("page" to 100,"total" to 10000,"chapters" to (1..10000).toList(),"bookmarks" to (1..10000).toList())
        val item=row(native)
        assertEquals(64,(item["chapters"] as List<*>).size)
        assertEquals(64,(item["bookmarks"] as List<*>).size)
        assertTrue(LuaValue.encode(ReaderControls.project(native)).size<=16384)
    }
}

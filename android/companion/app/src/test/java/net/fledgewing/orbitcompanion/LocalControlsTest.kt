// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion
import org.junit.Assert.*
import org.junit.Test
class LocalControlsTest {
    private fun text(m:Map<String,Any?>,k:String)=LuaValue.utf8(m[k].toString())
    @Test fun missingOrFutureOrForeignCheckIsNeverAReportedSuccess() {
        for(n in listOf(emptyMap<String,Any?>(),mapOf("at" to 101,"ok" to true,"kind" to "menu_sync"),mapOf("at" to 10,"ok" to true,"kind" to "refresh"))) {
            val r=LocalWidgets.controls(n,100);assertEquals("No saved sync check",text(r,"result"));assertEquals(false,r["wifi_enabled"])
        }
    }
    @Test fun resultAndAgeAreScopedToTheReadingSyncCheck() {
        val r=LocalWidgets.controls(mapOf("at" to 100,"ok" to false,"kind" to "sync_and_sleep","detail" to "must not copy","sync_available" to true),3700)
        assertEquals("Saved here · sync check failed",text(r,"result"));assertEquals("Checked 1 h ago",text(r,"age"));assertEquals(true,r["sync_enabled"])
        assertFalse(r.containsKey("detail"));assertTrue(LuaValue.encode(r).size<16384)
        val busy=LocalWidgets.controls(mapOf("sync_busy" to true,"sync_available" to true),100)
        assertEquals(false,busy["sync_enabled"]);assertEquals("Syncing…",text(busy,"sync_label"))
    }
    @Test fun HardwareAndWorkHoldsCannotBeInventedByPresentation() {
        val r=LocalWidgets.controls(mapOf("wifi_available" to true,"wifi_on" to true,"wifi_busy" to true,"night" to true,"rotate_available" to false),100)
        assertEquals(false,r["wifi_enabled"]);assertEquals("Wi-Fi busy",r["wifi_label"]);assertEquals("Night on",r["night_label"]);assertEquals(false,r["rotate_enabled"])
        assertEquals(false,LocalWidgets.controls(mapOf("wifi_available" to true),100)["wifi_enabled"])
        assertEquals(true,LocalWidgets.controls(mapOf("wifi_available" to true,"wifi_on" to false),100)["wifi_enabled"])
    }
}

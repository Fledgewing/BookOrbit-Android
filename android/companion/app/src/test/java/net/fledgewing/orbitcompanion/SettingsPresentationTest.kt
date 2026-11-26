package net.fledgewing.orbitcompanion

import android.provider.Settings
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.Executor

class SleepChoiceWindowTest {
    private val saved=SleepChoices(10,true,(1L..19L).map { SleepChoices.Item(it,"List $it",it.toInt()) },
        listOf(SleepChoices.Item(20,"Collection",null)),listOf(SleepChoices.Tag("quiet","Quiet",4)))
    @Test fun pagesHaveCountsAndNoMoreThanSixRows() {
        for (offset in listOf(0,6,12,18,24)) {
            val result=SleepChoiceWindow.project(saved,mapOf("category" to "lists","offset" to offset,"limit" to 99))
            val rows=result["items"] as List<*>
            assertTrue(rows.size<=6); assertEquals(19,result["total"])
            if(offset<19) assertEquals(offset+1,(rows.first() as Map<*,*>)["count"])
            assertTrue(LuaValue.encode(result).size<=16384)
        }
    }
    @Test fun emptyAndMissingRemainDistinctAndTagsReuseTheSleepOwner() {
        val missing=SleepChoiceWindow.project(null,emptyMap<String,Any>())
        assertEquals(false,(missing["freshness"] as Map<*,*>)["saved"])
        val empty=SleepChoiceWindow.project(saved,mapOf("category" to "libraries"))
        assertEquals(true,(empty["freshness"] as Map<*,*>)["saved"])
        assertTrue((empty["items"] as List<*>).isEmpty())
        val tags=SleepChoiceWindow.project(saved,mapOf("category" to "tags"))
        assertEquals("tag:quiet",((tags["items"] as List<*>).single() as Map<*,*>)["id"])
        val collections=SleepChoiceWindow.project(saved,mapOf("category" to "collections"))
        assertNull(((collections["items"] as List<*>).single() as Map<*,*>)["count"])
    }
    @Test fun titlesAreBoundedBeforeSerialization() {
        val large=saved.copy(scopes=listOf(SleepChoices.Item(1,"x".repeat(100000),1)))
        val result=SleepChoiceWindow.project(large,emptyMap<String,Any>())
        assertTrue(LuaValue.encode(result).size<=16384)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[34])
class DeviceSettingsTest {
    @Test fun sleepTimeoutAndNeverWriteOnlyAfterPermissionAndAcceptOnlyApprovedChoices() {
        val app=RuntimeEnvironment.getApplication()
        val oldWork=DeviceSettings.work; val oldPermission=DeviceSettings.canWrite
        DeviceSettings.work=Executor { it.run() }
        try {
            DeviceSettings.canWrite={false}
            DeviceSettings.initialize(app)
            Settings.System.putInt(app.contentResolver,Settings.System.SCREEN_OFF_TIMEOUT,600000)
            var result: String?="pending"
            DeviceSettings.sleep(app,300000) { result=it }
            assertEquals("permission",result)
            assertEquals(Settings.ACTION_MANAGE_WRITE_SETTINGS,shadowOf(app).nextStartedActivity.action)
            assertEquals(600000,Settings.System.getInt(app.contentResolver,Settings.System.SCREEN_OFF_TIMEOUT))
            DeviceSettings.canWrite={true}
            for(ms in listOf(300000,600000,900000,1800000,Int.MAX_VALUE)) {
                DeviceSettings.sleep(app,ms) { result=it }
                assertNull(result)
                assertEquals(ms,DeviceSettings.snapshot()["sleep_ms"])
                assertEquals(if(ms==Int.MAX_VALUE) "Never" else "${ms/60000} min idle",DeviceSettings.snapshot()["sleep_label"])
                assertTrue(LuaValue.encode(DeviceSettings.snapshot()).size<=16384)
            }
            assertThrows(IllegalArgumentException::class.java) { DeviceSettings.sleep(app,1) {} }
        } finally { DeviceSettings.work=oldWork; DeviceSettings.canWrite=oldPermission }
    }
}

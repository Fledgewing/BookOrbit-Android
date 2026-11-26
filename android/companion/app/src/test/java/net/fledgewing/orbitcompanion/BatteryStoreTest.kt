// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import org.robolectric.RuntimeEnvironment
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.ZoneOffset

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class BatteryStoreTest {
    @Test fun versionOneMigrationPreservesRowsAndLeavesOldMonotonicTimeUnknown() {
        android.database.sqlite.SQLiteDatabase.create(null).use { db ->
            db.execSQL("CREATE TABLE snap(t INTEGER,kind TEXT,level INTEGER,charging INTEGER,screen INTEGER,radio INTEGER,vpn INTEGER,wmode TEXT,content TEXT,light INTEGER,bright INTEGER,pages INTEGER,full INTEGER,partial INTEGER,temp INTEGER,volt INTEGER)")
            db.execSQL("INSERT INTO snap(t,kind,level) VALUES(1,'battery',78)")
            StatsStore.get(RuntimeEnvironment.getApplication()).onUpgrade(db,1,2)
            db.rawQuery("SELECT level,elapsed FROM snap",null).use { c ->
                assertTrue(c.moveToFirst()); assertEquals(78,c.getInt(0)); assertTrue(c.isNull(1))
            }
        }
    }
    @Test fun persistedMeasurementsSurviveReopenWithMonotonicTime() {
        val ctx = RuntimeEnvironment.getApplication()
        val store=StatsStore.get(ctx)
        store.writableDatabase.delete("snap", null, null)
        val t=1_700_000_000_000L
        store.insert(Snap(t,Snap.START,80,false,false,wmode="jit",elapsed=100))
        store.insert(Snap(t+3_600_000,"battery",76,false,false,wmode="jit",elapsed=3_600_100))
        store.close()
        val rows=store.snapsSince(t)
        assertEquals(2,rows.size); assertEquals(3_600_100L,rows.last().elapsed)
        val s=store.batterySnapshot(t+3_600_000,ZoneOffset.UTC)
        assertEquals(76,s["level"])
        assertEquals(4.0,(s["standby"] as Map<*,*>)["pct_per_hour"] as Double,1e-9)
    }
}

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
    private fun reset(store: StatsStore) {
        for (table in listOf("snap","daily","daily_cat","meta")) store.writableDatabase.delete(table,null,null)
    }
    @Test fun aFutureRollupCursorCannotHideCurrentMeasurementsAfterClockCorrection() {
        val store=StatsStore.get(RuntimeEnvironment.getApplication())
        reset(store)
        val t=1_700_000_000_000L
        val h=3_600_000L
        val day=24*h
        store.insert(Snap(t+100*day,Snap.START,100,false,false,wmode="jit",elapsed=0))
        store.rollup(t+101*day,ZoneOffset.UTC)
        for ((hours,pct,on) in listOf(Triple(0,75,true),Triple(1,71,true),Triple(2,67,false),Triple(14,61,false),Triple(26,55,false))) {
            store.insert(Snap(t+hours*h,if(hours==0) Snap.START else "battery",pct,false,on,
                wmode="jit",content=if(on) "text" else null,elapsed=2*day+hours*h))
        }
        val snapshot=store.batterySnapshot(t+26*h,ZoneOffset.UTC)
        assertEquals(55,snapshot["level"])
        assertEquals(4.0,(snapshot["screen_on"] as Map<*,*>)["pct_per_hour"] as Double,1e-9)
        assertEquals(0.5,(snapshot["standby"] as Map<*,*>)["pct_per_hour"] as Double,1e-9)
        assertEquals(71.5,snapshot["hours_usual_use"] as Double,1e-9)
    }
    @Test fun pruningInsideAChargeDoesNotArchiveTheRemainingSuffixAsAnotherCharge() {
        val store=StatsStore.get(RuntimeEnvironment.getApplication())
        reset(store)
        val t=1_700_000_000_000L
        val h=3_600_000L
        store.insert(Snap(t,Snap.START,20,false,false))
        store.insert(Snap(t+h,"battery",20,true,false))
        store.insert(Snap(t+2*h,"battery",60,true,false))
        store.insert(Snap(t+3*h,"battery",100,false,false))
        val now=t+90*24*h+h+h/2
        store.insert(Snap(now,Snap.START,80,false,false))
        store.rollup(now,ZoneOffset.UTC)
        assertEquals(t+2*h,store.snapsSince(t).first().t)
        store.rollup(now+60_000,ZoneOffset.UTC)
        val charges=store.batterySnapshot(now+60_000,ZoneOffset.UTC)["recent_charges"] as List<*>
        assertEquals(1,charges.size)
        val charge=charges.single() as Map<*,*>
        assertEquals(20,(charge["from_pct"] as Number).toInt())
        assertEquals(t+h,(charge["start"] as Number).toLong())
        assertEquals(2.0,(charge["hours"] as Number).toDouble(),1e-9)
    }
    @Test fun lastFiveChargesSurviveRawPruningAndDatabaseReopen() {
        val store=StatsStore.get(RuntimeEnvironment.getApplication())
        reset(store)
        val t=1_700_000_000_000L
        val h=3_600_000L
        for (i in 0..5) {
            val start=t+i*30*24*h
            store.insert(Snap(start,Snap.START,20,false,false))
            store.insert(Snap(start+h,"battery",20,true,false))
            store.insert(Snap(start+2*h,"battery",60,true,false))
            store.insert(Snap(start+3*h,"battery",100,false,false))
        }
        val now=t+250*24*h
        store.insert(Snap(now,Snap.START,80,false,false))
        store.rollup(now,ZoneOffset.UTC)
        assertEquals(1,store.snapsSince(t).size)
        store.close()
        val charges=store.batterySnapshot(now,ZoneOffset.UTC)["recent_charges"] as List<*>
        assertEquals(5,charges.size)
        val newest=charges.first() as Map<*,*>
        assertEquals(t+150*24*h+h,(newest["start"] as Number).toLong())
        assertEquals(20,(newest["from_pct"] as Number).toInt())
        assertEquals(100,(newest["to_pct"] as Number).toInt())
        assertEquals(2.0,(newest["hours"] as Number).toDouble(),1e-9)
        assertTrue(charges.all { (it as Map<*,*>)["ongoing"]==false })
    }

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
        reset(store)
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

// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files

class RemindersStoreTest {
    private fun fixture(block:(Sql)->Unit) {
        val dir=Files.createTempDirectory("reminders-store").toFile()
        try {JdbcSql(java.io.File(dir,"reminders.db")).use(block)} finally {dir.deleteRecursively()}
    }
    @Test fun missingStoreIsEmptyAndRoundTripSurvivesNewOwner()=fixture {db ->
        val s=RemindersStore(db);val empty=s.load();assertEquals(1,empty.records.size)
        val next=empty.copy(records=empty.records.map {it.copy(enabled=true,intervalMinutes=45)})
        s.save(next);assertEquals(next,RemindersStore(db).load())
    }
    @Test fun corruptPrimaryRecoversPreviousValidatedSnapshot()=fixture {db ->
        val s=RemindersStore(db);val before=s.load();s.save(before)
        s.save(before.copy(records=before.records.map {it.copy(enabled=true)}))
        db.exec("UPDATE reminders_state SET body=? WHERE slot=0","damaged".toByteArray())
        val recovered=RemindersStore(db);assertEquals(before,recovered.load());assertTrue(recovered.recovered)
        recovered.save(before);assertEquals(before,RemindersStore(db).load())
    }
    @Test fun bothDamagedRetainBytesAndCannotSave()=fixture {db ->
        val s=RemindersStore(db);val state=s.load();s.save(state);s.save(state)
        db.exec("UPDATE reminders_state SET body=?","damaged".toByteArray())
        val broken=RemindersStore(db)
        try {broken.load();fail()} catch(_:IllegalStateException) {}
        try {broken.save(state);fail()} catch(_:IllegalStateException) {}
        assertEquals(2L,db.query("SELECT COUNT(*) FROM reminders_state WHERE body=?","damaged".toByteArray()) {it.long(0)}.single())
    }
    @Test fun unknownVersionAndMalformedFieldsRejected() {
        val raw=RemindersStore.encode(Reminders.State()).toString(Charsets.UTF_8)
        for(bad in listOf(raw.replace("\"version\":1","\"version\":2"),raw.replace("\"interval\":20","\"interval\":21"),raw.replace("\"interval\":20","\"interval\":20.5"),raw.replace("\"enabled\":false","\"enabled\":\"false\""),raw.replace("local:eye-rest","family:eye-rest"),raw.replace("\"kind\":\"interval\"","\"kind\":\"interval\",\"source\":\"family\""),"{}")) {
            try {RemindersStore.decode(bad.toByteArray());fail(bad)} catch(_:Exception) {}
        }
    }
    @Test fun logicalStateStaysBounded() {
        val rows=(0..7).map {Reminders.Record("local:00000000-0000-0000-0000-00000000000$it","time",enabled=true,minuteOfDay=1439,days=127,message="😀".repeat(60),
            highWater="2026-11-27",snooze=Reminders.Snooze("2026-11-27",1796000000000,100),mutation="m".repeat(64),response="r".repeat(128))}
        val state=Reminders.State(rows+Reminders.State().records)
        Reminders.validate(state);assertTrue(RemindersStore.encode(state).size<=8192)
        assertEquals(state,RemindersStore.decode(RemindersStore.encode(state)))
    }
    @Test fun failuresAtEveryPublicationStatementRollbackBothSlots() {
        for(boundary in 1..3) fixture {db ->
            val initial=RemindersStore(db);val before=initial.load();initial.save(before);initial.save(before)
            var writes=0; var armed=false
            val fault=object:Sql by db {
                override fun exec(sql:String,vararg args:Any?) {if(armed && ++writes==boundary) throw IllegalStateException("full");db.exec(sql,*args)}
                override fun <T> transaction(block:()->T):T = db.transaction {val result=block();if(boundary==3) throw IllegalStateException("commit");result}
            }
            val s=RemindersStore(fault);s.load();armed=true
            try {s.save(before.copy(records=before.records.map {it.copy(enabled=true)}));fail()} catch(_:IllegalStateException) {}
            assertEquals(before,RemindersStore(db).load())
        }
    }
}

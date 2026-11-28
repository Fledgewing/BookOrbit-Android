// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import android.os.Environment
import android.os.SystemClock
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLooper
import org.robolectric.shadows.ShadowSystemClock
import java.io.File
import java.time.Duration
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Real Android SQLite and the complete asynchronous Library port, with no account. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk=[34])
class LibraryRemindersTest {
    @Test fun neutralPortOwnsRevisionsSourcesBudgetsAndIntervalDelivery() {
        val file=File(Environment.getExternalStorageDirectory(),"koreader/settings/booksync-reminders.sqlite3")
        file.delete()
        val app=RuntimeEnvironment.getApplication()
        fun call(op:String,args:Map<String,Any?> = emptyMap()): Map<String,Any?> {
            var result: Map<String,Any?>?=null;var error:String?=null
            val ready=CountDownLatch(1)
            LibraryReminders.command(app,"reminders.$op",args) {value,failure ->result=value;error=failure;ready.countDown()}
            val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(10)
            while(ready.count>0) {ShadowLooper.idleMainLooper();check(System.nanoTime()<deadline);Thread.sleep(5)}
            return if(error!=null) mapOf("error" to error) else result!!
        }
        fun rows(value:Map<String,Any?>)=(value["items"] as List<*>).filterIsInstance<Map<*,*>>()
        fun runtime(n:Int,presenting:Boolean=false)=call("runtime",mapOf("owner" to "test-visible","visible" to true,"sleeping" to false,"page" to true,
            "modal" to false,"presenting" to presenting,"input" to "input-$n","age" to 0,"at" to SystemClock.elapsedRealtime()))
        try {
            val empty=call("list");assertEquals(0L,empty["revision"]);assertEquals(1,rows(empty).size)
            val caps=(empty["capabilities"] as Map<*,*>)["reminders"] as Map<*,*>
            assertEquals(false,caps["sleepAvailable"]);assertEquals(8,caps["timeLimit"])
            val later=java.time.Instant.ofEpochMilli(System.currentTimeMillis()).atZone(java.time.ZoneId.systemDefault()).toLocalTime().plusHours(4)
            val fields=mapOf("kind" to "time","enabled" to true,"minuteOfDay" to (later.hour*60+later.minute),"days" to 127,"message" to "","mutation" to "a:0:first")
            val added=call("add",fields);assertNull(added["error"]);assertEquals(1L,added["revision"])
            val saved=added["saved"] as Map<*,*>;val id=saved["id"] as String
            assertEquals(added,call("add",fields))
            assertEquals("invalid",call("add",fields+mapOf("source" to "family"))["error"])
            assertEquals("invalid",call("setEnabled",mapOf("id" to "family:one","revision" to 1,"enabled" to false,"mutation" to "forged"))["error"])
            val disabled=call("setEnabled",mapOf("id" to id,"revision" to 1,"enabled" to false,"mutation" to "off"))
            assertEquals(2L,disabled["revision"])
            // Snapshot revision and individual record revision must not overwrite each other.
            val second=call("add",fields+mapOf("mutation" to "a:2:second"))
            assertEquals(3L,second["revision"]);assertEquals(1L,(second["saved"] as Map<*,*>)["revision"])
            assertEquals("conflict",call("add",fields+mapOf("mutation" to "a:0:late-new"))["error"])
            assertEquals("invalid",call("draft",mapOf("kind" to "time","enabled" to true,"minuteOfDay" to 1200.5,"days" to 127))["error"])
            assertEquals("invalid",call("draft",mapOf("kind" to "time","enabled" to true,"minuteOfDay" to 4294968496L,"days" to 127))["error"])
            val interval=rows(second).first {it["kind"]=="interval"}
            val enabled=call("edit",mapOf("id" to interval["id"],"revision" to interval["revision"],"kind" to "interval","enabled" to true,"intervalMinutes" to 20,"mutation" to "enable-eye"))
            assertEquals(4L,enabled["revision"])
            runtime(0)
            repeat(20) {n ->ShadowSystemClock.advanceBy(Duration.ofMinutes(1));runtime(n+1)}
            val due=(runtime(20)["due"] as List<*>).single() as Map<*,*>
            assertEquals("interval",due["kind"]);assertEquals(Reminders.EYE_TEXT,LuaValue.utf8(due["message"] as String))
            val claim=call("claimDue",mapOf("event" to due["event"],"owner" to "test-visible"));assertNotNull(claim["grant"])
            assertEquals(true,call("claimDue",mapOf("event" to due["event"],"owner" to "test-visible"))["stale"])
            // A stale duplicate claim must not discard the already-issued grant.
            assertEquals("invalid",call("respond",mapOf("grant" to claim["grant"],"owner" to "test-visible","action" to "sleep"))["error"])
            assertEquals(true,runtime(20,true)["grantValid"])
            ShadowSystemClock.advanceBy(Duration.ofMinutes(10));assertEquals(true,runtime(20,true)["grantValid"])
            val response=mapOf("grant" to claim["grant"],"owner" to "test-visible","action" to "turnOff")
            assertEquals(true,call("respond",response)["accepted"]);assertEquals(true,call("respond",response)["stale"])
            val final=call("list");assertEquals(5L,final["revision"])
            assertFalse(rows(final).first {it["kind"]=="interval"}["enabled"] as Boolean)
            assertTrue(LuaValue.encode(final).size<=8192)
            assertTrue(LuaValue.encode(claim).size<=1024)
            assertEquals(final,call("retry"))
            file.writeBytes(byteArrayOf())
            assertEquals("storage",call("retry")["error"])
            assertEquals(0L,file.length())
            assertEquals("storage",call("list")["error"])
        } finally {file.delete()}
    }
}

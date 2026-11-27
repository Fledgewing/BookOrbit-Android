// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import java.io.*
import java.net.*
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class BookTransferHttpTest {
    private class Reply(val code:Int,val bytes:InputStream,val size:Long,val fields:Map<String,String> = mapOf("ETag" to "\"revision-one\"")):HttpURLConnection(URL("https://fixture.example.test")) {
        override fun connect() {}
        override fun disconnect() {}
        override fun usingProxy()=false
        override fun getResponseCode()=code
        override fun getInputStream()=bytes
        override fun getContentLengthLong()=size
        override fun getHeaderField(name:String)=fields[name]
    }
    private fun fixture(test:(File)->Unit) {
        val root=Files.createTempDirectory("book-transfer").toFile()
        try { test(File(root,"fixture.part")) } finally { root.deleteRecursively() }
    }
    private val headers=mapOf("x-auth-user" to "fixture-reader","x-auth-key" to "synthetic-key")
    private val generous:(File)->Long={Long.MAX_VALUE}
    private fun interrupted()=object:InputStream() {
        var count=0
        override fun read():Int { if(count++<3) return 'a'.code;throw IOException("synthetic disconnect") }
        override fun read(b:ByteArray,off:Int,len:Int):Int { if(count>0) throw IOException("synthetic disconnect");repeat(3) { b[off+it]='a'.code.toByte() };count=3;return 3 }
    }
    @Test fun interruptedTransferResumesOnlyWithItsStrongValidatorAndExactRange()=fixture { part ->
        val first=Reply(200,interrupted(),6)
        val next=Reply(206,ByteArrayInputStream("bbb".toByteArray()),3,mapOf("ETag" to "\"revision-one\"","Content-Range" to "bytes 3-5/6"))
        var calls=0
        val http=BookTransferHttp({ if(calls++==0) first else next },generous)
        try { http.transfer("https://fixture.example.test","/fixture",headers,part,{_,_->},{false});fail("disconnected") }
        catch(e:ServerFailure) { assertEquals("offline",e.kind) }
        assertEquals("aaa",part.readText())
        http.transfer("https://fixture.example.test","/fixture",headers,part,{_,_->},{false})
        assertEquals("bytes=3-",next.getRequestProperty("Range"));assertEquals("\"revision-one\"",next.getRequestProperty("If-Range"))
        assertEquals("aaabbb",part.readText())
        http.transfer("https://fixture.example.test","/fixture",headers,part,{_,_->},{false})
        assertEquals("ready staging is reused for a link retry",2,calls)
    }
    @Test fun decliningRangeReplacesOnlyThePartialFileAndReportsRealBytes()=fixture { part ->
        val replies=java.util.ArrayDeque(listOf(Reply(200,interrupted(),6),Reply(200,ByteArrayInputStream("newnew".toByteArray()),6)))
        val http=BookTransferHttp({replies.removeFirst()},generous)
        runCatching { http.transfer("https://fixture.example.test","/fixture",headers,part,{_,_->},{false}) }
        var received=0L
        http.transfer("https://fixture.example.test","/fixture",headers,part,{n,_->received=n},{false})
        assertEquals("newnew",part.readText());assertEquals(6L,received)
    }
    @Test fun badContentRangeCannotAppendToTheRetainedPartial()=fixture { part ->
        val replies=java.util.ArrayDeque(listOf(Reply(200,interrupted(),6),Reply(206,ByteArrayInputStream("bbb".toByteArray()),3,mapOf("Content-Range" to "bytes 2-4/6"))))
        val http=BookTransferHttp({replies.removeFirst()},generous)
        runCatching { http.transfer("https://fixture.example.test","/fixture",headers,part,{_,_->},{false}) }
        try { http.transfer("https://fixture.example.test","/fixture",headers,part,{_,_->},{false});fail("bad range") }
        catch(e:ServerFailure) { assertEquals("invalid",e.kind) }
        assertEquals("aaa",part.readText())
    }
    @Test fun unknownSizeNeverBecomesAPercentageAndCancellationIsCheckedBetweenReads()=fixture { part ->
        var stop=false
        val input=object:ByteArrayInputStream(ByteArray(300000)) {
            override fun read(b:ByteArray,off:Int,len:Int):Int { val n=super.read(b,off,len);if(pos>=262144) stop=true;return n }
        }
        val http=BookTransferHttp({Reply(200,input,-1)},generous)
        try { http.transfer("https://fixture.example.test","/fixture",headers,part,{_,total->assertNull(total)},{stop});fail("canceled") }
        catch(e:ServerFailure) { assertEquals("canceled",e.kind) }
        assertTrue(part.length() in 1L..299999L)
    }
    @Test fun insufficientSpaceOrUnauthorizedReplyCannotTouchACompleteBook()=fixture { part ->
        val complete=File(part.parentFile,"book.epub").apply { writeText("keep") }
        for(code in listOf(200,401)) {
            val http=BookTransferHttp({Reply(code,ByteArrayInputStream(ByteArray(10)),10)},{0L})
            try { http.transfer("https://fixture.example.test","/fixture",headers,part,{_,_->},{false});fail("refused") }
            catch(e:ServerFailure) { assertEquals(if(code==401) "unauthorized" else "space",e.kind) }
            assertEquals("keep",complete.readText());assertFalse(part.exists())
        }
    }
}

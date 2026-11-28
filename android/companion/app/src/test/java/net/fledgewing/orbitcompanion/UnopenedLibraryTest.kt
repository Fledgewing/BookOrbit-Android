// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.time.ZoneId
class UnopenedLibraryTest {
    private val now=1800000000L
    private fun <T> fixture(block:(File,File)->T):T {
        val root=Files.createTempDirectory("unopened").toFile()
        try { val reader=File(root,"reader").apply { mkdirs();File(this,"history.lua").writeText("return {}") };return block(File(root,"Books").apply { mkdirs() },reader) }
        finally { root.deleteRecursively() }
    }
    private fun book(root:File,name:String)=File(root,"$name.epub").apply { writeText("original $name");setLastModified((now-86400*90)*1000) }
    private fun rows(r:Map<String,Any?>)=(r["items"] as List<*>).map { it as Map<*,*> }
    @Test fun localOpeningEvidenceIsIndependentOfServerUnreadAndCurrentBook()=fixture { books,reader ->
        val never=book(books,"Never");val opened=book(books,"Opened");val unknown=book(books,"Metadata")
        File(reader,"history.lua").writeBytes(("return "+String(LuaValue.encode(listOf(mapOf("file" to LuaValue.str(opened.canonicalPath)))),Charsets.ISO_8859_1)).toByteArray(Charsets.ISO_8859_1))
        File(books,"Metadata.sdr").mkdir()
        val library=UnopenedLibrary(listOf(books),reader,now)
        val r=rows(library.window(emptyMap<Any,Any>()));assertEquals(1,r.size);assertEquals("Never",r.single()["title"])
        assertEquals("unknown",r.single()["status"]);assertEquals(false,r.single()["status_write"])
        assertEquals(0,library.window(mapOf("exclude_path" to LuaValue.str(never.path)))["total"])
        assertTrue(unknown.exists())
    }
    @Test fun nativeDumpIndexedHistoryAndHeaderPreserveOpeningEvidence()=fixture { books,reader ->
        val opened=book(books,"Opened");book(books,"Candidate")
        val entry=mapOf("time" to now,"file" to LuaValue.str(opened.canonicalPath))
        val history=File(reader,"history.lua")
        history.writeBytes("-- native history\nreturn ".toByteArray()+LuaValue.encode(mapOf(1 to entry)))
        val result=UnopenedLibrary(listOf(books),reader,now).window(emptyMap<Any,Any>())
        assertEquals(true,(result["freshness"] as Map<*,*>)["saved"])
        assertEquals(listOf("Candidate"),rows(result).map { it["title"] })
        for(keys in listOf(mapOf("01" to entry),mapOf("1" to entry,"3" to entry))) {
            history.writeBytes("return ".toByteArray()+LuaValue.encode(keys))
            assertEquals("unavailable",UnopenedLibrary(listOf(books),reader,now).dust(emptyMap<Any,Any>())["state"])
        }
    }
    @Test fun centralHashAndLegacySidecarsAllExcludeFiles()=fixture { books,reader ->
        val central=book(books,"Central");val hashed=book(books,"Hashed");val legacy=book(books,"Legacy");book(books,"Candidate")
        File(reader,"docsettings${central.canonicalPath.substringBeforeLast('.')}.sdr").mkdirs()
        val md5=MessageDigest.getInstance("MD5").digest(hashed.readBytes()).joinToString("") { "%02x".format(it) }
        File(reader,"hashdocsettings/${md5.take(2)}/$md5.sdr").mkdirs()
        File(reader,"history/[${legacy.parentFile.canonicalPath.replace('/','#')}#] ${legacy.name}.lua").apply { parentFile.mkdirs();writeText("return {}") }
        assertEquals(listOf("Candidate"),rows(UnopenedLibrary(listOf(books),reader,now).window(emptyMap<Any,Any>())).map { it["title"] })
    }
    @Test fun missingMalformedHistoryAndLinksNeverBecomeAnEmptyKnownOpeningLedger()=fixture { books,reader ->
        book(books,"Candidate");val history=File(reader,"history.lua")
        for(value in listOf("broken","return {unrelated={}}","return {{file=''}}")) {
            history.writeText(value)
            val r=UnopenedLibrary(listOf(books),reader,now).window(emptyMap<Any,Any>())
            assertEquals(false,(r["freshness"] as Map<*,*>)["saved"]);assertTrue(rows(r).isEmpty())
        }
        history.delete();assertEquals("unavailable",UnopenedLibrary(listOf(books),reader,now).dust(emptyMap<Any,Any>())["state"])
        history.writeText("return {}");val outside=File(reader,"Outside.epub").apply { writeText("outside") }
        Files.createSymbolicLink(File(books,"Link.epub").toPath(),outside.toPath())
        assertEquals(1,UnopenedLibrary(listOf(books),reader,now).window(emptyMap<Any,Any>())["total"])
    }
    @Test fun dailyPickAndNextSurviveReconstructionAndUseFileAgeWithHonestCoverage()=fixture { books,reader ->
        repeat(3) { book(books,"Candidate $it") }
        val first=UnopenedLibrary(listOf(books),reader,now,ZoneId.of("UTC")).dust(emptyMap<Any,Any>())
        val args=mapOf("day" to first["day"],"pick" to 1)
        val next=UnopenedLibrary(listOf(books),reader,now,ZoneId.of("UTC")).dust(args)
        assertNotEquals((first["book"] as Map<*,*>)["key"],(next["book"] as Map<*,*>)["key"])
        assertEquals(next,UnopenedLibrary(listOf(books),reader,now,ZoneId.of("UTC")).dust(args))
        assertEquals("File age 90 days",next["age"]);assertEquals("No saved opening record",next["source"])
        assertTrue(LuaValue.encode(next).size<16384)
        assertEquals(1,UnopenedLibrary(listOf(books),reader,now).window(mapOf("query" to mapOf("q" to "Candidate 2")))["total"])
    }
}

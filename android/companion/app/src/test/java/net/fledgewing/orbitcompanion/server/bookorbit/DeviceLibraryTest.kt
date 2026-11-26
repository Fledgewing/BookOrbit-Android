// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class DeviceLibraryTest {
    @Test fun localProjectionsWorkWithoutAdapterOrCatalogOwnershipAndAfterSignOut() {
        val volume=Files.createTempDirectory("device-library").toFile()
        try {
            val folder=File(volume,"Books").apply { mkdirs() }
            val book=File(folder,"fixture.epub").apply { writeText("fixture") }
            val sidecar=File(folder,"fixture.sdr").apply { mkdirs() }
            File(sidecar,"metadata.epub.lua").writeText("return {[\"doc_props\"]={[\"title\"]=\"Local title\"},[\"summary\"]={[\"status\"]=\"reading\"},[\"percent_finished\"]=0.25}")
            val cover=File(sidecar,"cover.jpg").apply { writeText("fixture cover") }
            val cache=File(volume,"koreader/settings/orbit-cache").apply { mkdirs() }
            CacheStore(cache,{}) { JdbcSql(it) }.use { store ->
                // No adapter is available: its methods must never be consulted for device data.
                val unavailable=object : ServerAdapter {
                    override val id="unavailable"
                    override fun project(owner: String,request: Map<*,*>): Map<String,Any?> = error("remote projection")
                    override fun cachedReadingStats(owner: String): RemoteReadingStats? = error("remote stats")
                }
                val model=LibraryReadModel(store,{99},{},readingStats={ mapOf("state" to "ready","total_seconds" to 600) },
                    battery={ mapOf("level" to 75) },accountStats={ error("account stats") },adapter=unavailable)
                fun read(op: String, vararg args: Pair<String,Any?>): Map<*,*> {
                    val request=String(LuaValue.encode(mapOf("op" to op,"limit" to 1,"bytes" to 16384)+args),Charsets.ISO_8859_1)
                    model.publish(DeviceLibrary.OWNER,listOf(request))
                    val body=store.db().query("SELECT body FROM library_views WHERE owner=? AND request=?",DeviceLibrary.OWNER,request) { it.bytes(0)!! }.single()
                    assertTrue(body.size<=16384)
                    return LuaValue.parse(body) as Map<*,*>
                }
                for(previousOwner in listOf<String?>(null,"previous-account")) {
                    if(previousOwner!=null) store.own(previousOwner)
                    val data=read("window","source" to "on-device")
                    val row=(data["items"] as List<*>).single() as Map<*,*>
                    assertEquals("Local title",row["title"]); assertEquals(book.canonicalPath,row["local_path"])
                    assertEquals(25.0,(row["progress"] as Number).toDouble(),0.001)
                    assertEquals(cover.path,read("cover","key" to row["key"])["local_path"])
                    assertEquals(true,read("capabilities")["onDevice"])
                    assertEquals(false,read("capabilities")["download"])
                    assertEquals(75L,read("battery")["level"])
                    assertFalse(read("reading.stats").containsKey("error"))
                    assertEquals(previousOwner,store.meta("owner"))
                    assertFalse(model.publish("wrong-account",listOf("{op=\"battery\"}")))
                }
                val request=String(LuaValue.encode(mapOf("op" to "battery","limit" to 1,"bytes" to 256)),Charsets.ISO_8859_1)
                LibraryReadModel(store,{99},{},battery={ mapOf("oversized" to "x".repeat(17000)) },adapter=unavailable).publish(DeviceLibrary.OWNER,listOf(request))
                val result=store.db().query("SELECT body FROM library_views WHERE owner=? AND request=?",DeviceLibrary.OWNER,request) { LuaValue.parse(it.bytes(0)!!) as Map<*,*> }.single()
                assertEquals("budget",result["error"])
            }
        } finally { volume.deleteRecursively() }
    }
    @Test fun windowsAreBoundedFilteredAndDoNotFollowEscapingLinks() {
        val root=Files.createTempDirectory("device-window").toFile()
        val outside=Files.createTempDirectory("outside-device").toFile()
        try {
            for(i in 1..30) File(root,"Book $i.epub").writeText("fixture")
            File(outside,"Private.epub").writeText("fixture")
            Files.createSymbolicLink(File(root,"escape").toPath(),outside.toPath())
            val adapter=DeviceLibrary(listOf(root))
            val page=adapter.project(DeviceLibrary.OWNER,mapOf("op" to "window","source" to "on-device","limit" to 6,"query" to mapOf("sort" to "title")))
            assertEquals(6,(page["items"] as List<*>).size); assertEquals(30,page["total"])
            val search=adapter.project(DeviceLibrary.OWNER,mapOf("op" to "window","source" to "on-device","query" to mapOf("q" to "Book 20")))
            assertEquals(1,(search["items"] as List<*>).size)
            assertEquals("unauthorized",adapter.project("other",mapOf("op" to "window"))["error"])
        } finally { root.deleteRecursively(); outside.deleteRecursively() }
    }
}

// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class CoverReferenceTest {
    private class Kit : AutoCloseable {
        val root=Files.createTempDirectory("cover-reference").toFile()
        val covers=File(root,"covers")
        val creds=CacheWorker.Creds("https://library.example/api/v1","fixture","fixture-key")
        val owner="fixture|https://library.example/api/v1"
        val requests=mutableListOf<String>()
        val seenHeaders=mutableListOf<Map<String,String>>()
        var offline=false
        var throws=false
        val worker=CacheWorker(File(root,"cache"), { url, headers, sink, _ ->
            requests+=url; seenHeaders+=headers
            if (throws) error("transport")
            when {
                offline -> CacheWorker.Reply(0)
                headers["If-None-Match"]=="version-one" -> CacheWorker.Reply(304)
                else -> {
                    sink!!.writeBytes(byteArrayOf(-1,-40,-1,1))
                    CacheWorker.Reply(200,etag="version-one",contentType="image/jpeg")
                }
            }
        },log={},openSql={ JdbcSql(it) },places=listOf(root))
        init { worker.store.own(owner); covers.mkdirs() }
        fun ref(name: String)=File(covers,name).path
        fun acquire(name: String,refresh: Boolean=false)=worker.acquireCoverReference(owner,ref(name),creds,covers,refresh)
        fun path(result: Map<String,Any?>)=File(LuaValue.utf8(result["local_path"] as String))
        override fun close() { worker.store.close(); root.deleteRecursively() }
    }
    @Test fun localLegacyCoverImportsWithoutNetworkAndPublishesOneBoundedReference() {
        Kit().use { k ->
            val legacy=File(k.ref("7_100.jpg")).apply { writeBytes(byteArrayOf(-1,-40,-1,0)) }
            File(legacy.path+".etag").writeText("version-one")
            k.offline=true
            var growth=0L
            val result=k.worker.acquireCoverReference(k.owner,legacy.path,k.creds,k.covers,false) { growth=it }
            assertTrue(growth>0)
            k.worker.acquireCoverReference(k.owner,legacy.path,k.creds,k.covers,false) { growth=it }
            assertEquals(0L,growth)
            assertTrue(k.path(result).isFile); assertNotEquals(legacy,k.path(result)); assertTrue(legacy.isFile)
            assertTrue(k.requests.isEmpty())
            val request=mapOf("op" to "cover.reference","reference" to LuaValue.str(legacy.path),"limit" to 1L,"bytes" to 16384L)
            val encoded=String(LuaValue.encode(request),Charsets.ISO_8859_1)
            assertTrue(LibraryReadModel(k.worker.store,log={}).publish(k.owner,listOf(encoded)))
            val body=k.worker.store.db().query("SELECT body FROM library_views WHERE request=?",LuaValue.utf8(encoded)) { it.bytes(0)!! }.single()
            assertTrue(body.size<=16384)
            assertEquals(result["local_path"],(LuaValue.parse(body) as Map<*,*>)["local_path"])
            assertTrue(k.requests.isEmpty())
            for ((id,head) in listOf(8 to "\u0089PNG",9 to "GIF8",10 to "RIFF0000WEBP")) {
                File(k.ref("${id}_100.jpg")).writeBytes(head.toByteArray(Charsets.ISO_8859_1))
                assertTrue(k.path(k.acquire("${id}_100.jpg")).isFile)
            }
            File(k.ref("11_100.jpg")).writeText("<html>not an image</html>")
            try { k.acquire("11_100.jpg"); fail("HTML must not be imported as a cover") }
            catch (e: ServerFailure) { assertEquals("unavailable",e.kind) }
        }
    }
    @Test fun missingCoversFetchOnlyInCompanionAndForcedRefreshUsesEtag() {
        Kit().use { k ->
            val first=k.acquire("7_100.jpg")
            assertTrue(k.path(first).isFile); assertEquals(1,k.requests.size)
            assertTrue(k.requests.single().endsWith("/books/7/thumbnail"))
            val second=k.acquire("7_100.jpg",true)
            assertEquals(first,second); assertEquals(2,k.requests.size)
            assertEquals("version-one",k.seenHeaders.last()["If-None-Match"])
            k.offline=true
            assertEquals(first,k.acquire("7_100.jpg")); assertEquals(2,k.requests.size)
            assertEquals(true,k.acquire("7_100.jpg",true)["stale"])
            assertTrue(k.path(first).isFile)
        }
    }
    @Test fun portraitAndBookWithSameIdAreSeparateAndPortraitUsesAdapterRoute() {
        Kit().use { k ->
            val book=k.acquire("7_100.jpg")
            val author=k.acquire("a7_100.jpg")
            assertNotEquals(book["local_path"],author["local_path"])
            assertTrue(k.path(book).isFile); assertTrue(k.path(author).isFile)
            assertTrue(k.requests.last().endsWith("/authors/7/photo"))
            assertNotEquals(k.worker.store.meta("cover_file_7"),k.worker.store.meta("cover_file_a7"))
        }
    }
    @Test fun forcedRefreshFetchesEvenWhenLegacyImageHasNoEtagAndTransportFailureKeepsIt() {
        Kit().use { k ->
            val legacy=File(k.ref("7_100.jpg")).apply { writeBytes(byteArrayOf(-1,-40,-1,0)) }
            k.acquire("7_100.jpg")
            k.throws=true
            assertEquals(true,k.acquire("7_100.jpg",true)["stale"])
            assertEquals(1,k.requests.size); assertTrue(legacy.isFile)
            k.throws=false
            assertEquals(false,k.acquire("7_100.jpg",true)["stale"])
            assertEquals(2,k.requests.size)
        }
    }
    @Test fun accountChangeTraversalAndForeignNamespacesFailBeforeAnyTransport() {
        Kit().use { k ->
            fun rejected(reference: String,owner: String=k.owner) {
                try { k.worker.acquireCoverReference(owner,reference,k.creds,k.covers); fail("accepted reference") }
                catch (_: ServerFailure) {}
            }
            rejected(k.ref("7_100.jpg"),"another-owner")
            rejected(File(k.root,"7_100.jpg").path)
            rejected(File(k.covers,BookOrbitLibrary.namespace("another-owner")+"/7_100.jpg").path)
            rejected(k.ref("../7_100.jpg"))
            rejected(k.ref("not-a-cover.jpg"))
            assertTrue(k.requests.isEmpty())
        }
    }
    @Test fun referenceProjectionChecksIdentityAndKeepsOnlyABoundedWorkingSet() {
        Kit().use { k ->
            for (i in 1..65) {
                File(k.ref("7_${i}.jpg")).writeBytes(byteArrayOf(-1,-40,-1,0))
                k.acquire("7_${i}.jpg")
            }
            assertTrue(k.requests.isEmpty())
            val first=LuaValue.str(k.ref("7_1.jpg"))
            assertNull(k.worker.store.meta("cover_ref_"+MirrorLogic.hash(first)))
            val reference=LuaValue.str(k.ref("7_65.jpg"))
            val key="cover_ref_"+MirrorLogic.hash(reference)
            k.worker.store.setMeta(key,String(LuaValue.encode(mapOf("reference" to "different-reference","local_path" to reference)),Charsets.ISO_8859_1))
            val result=BookOrbitProjection(k.worker.store).project(k.owner,mapOf("op" to "cover.reference","reference" to reference))
            assertNull(result["local_path"])
            val order=LuaValue.parse(k.worker.store.meta("cover_ref_order")!!.toByteArray(Charsets.ISO_8859_1)) as List<*>
            assertEquals(64,order.size)
        }
    }
    @Test fun nativeSettingsAreReadAsLiteralDataOnlyAndNeverModifyCredentials() {
        Kit().use { k ->
            val file=File(k.root,"settings.reader.lua")
            val raw=mapOf("bookorbit" to mapOf("server_url" to k.creds.server,"username" to k.creds.user,"userkey" to k.creds.key),
                "other" to mapOf("text" to "not executed"))
            val bytes=("-- KOReader settings\nreturn "+String(LuaValue.encode(raw),Charsets.ISO_8859_1)+"\n").toByteArray(Charsets.ISO_8859_1)
            file.writeBytes(bytes)
            val account=LegacyCoverSource.read(file)!!
            assertEquals(k.owner,account.owner); assertEquals(k.creds.key,account.credentials.key)
            assertFalse(account.toString().contains(k.creds.key)); assertArrayEquals(bytes,file.readBytes())
            file.writeText(String(bytes,Charsets.ISO_8859_1).replace(k.creds.server,"https://library.example/api/v1/koreader/"))
            assertEquals(k.creds.server,LegacyCoverSource.read(file)!!.credentials.server)
            // An unrelated native value need not be representable by the cache codec.
            file.writeText(String(bytes,Charsets.ISO_8859_1).replace("[\"other\"]=", "[\"unrelated\"]=math.huge,[\"other\"]="))
            assertNotNull(LegacyCoverSource.read(file))
            file.writeText("return { [\"bookorbit\"] = require(\"unsafe\") }")
            assertNull(LegacyCoverSource.read(file))
        }
    }
}

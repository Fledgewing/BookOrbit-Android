package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class BookOrbitSyncTest {
    private class Kit(val root: File) : AutoCloseable {
        val sql=JdbcSql(File(root,"journal.db")); val q=LifecycleQueue(sql)
        val book=File(root,"fixture.epub").apply { writeText("fixture book bytes") }
        val sidecar=File(root,"fixture.sdr/metadata.epub.lua").apply { parentFile!!.mkdirs(); writeBytes(LuaValue.encode(mapOf("summary" to mapOf("status" to "reading"),"unrelated" to "keep"))) }
        val calls=mutableListOf<Pair<String,Map<String,Any?>>>()
        var response: ((String,Map<String,Any?>)->Map<*, *>)?=null
        val sync=BookOrbitSync(root,{ path,body ->
            calls+=path to body
            response?.invoke(path,body) ?: if(path.endsWith("match-check")) mapOf("matches" to listOf(mapOf("hash" to document,"bookFileId" to 4,"positionCompatible" to true)))
            else mapOf("results" to listOf(emptyMap<String,Any>()))
        },sql,::JdbcSql,{true})
        var document="a".repeat(32)
        fun job(snapshot: Map<String,Any?>,checkpoint: Map<String,Any?> = emptyMap()): LifecycleQueue.Entry {
            val payload=mapOf("digest" to document,"file" to book.path,"percentage" to .5,"progress" to "/p50","ts" to 1000L)+snapshot
            val id=q.enqueue("fixture","account",document,LuaValue.encode(payload),checkpoint=LuaValue.encode(checkpoint))
            return q.window("fixture","account").first { it.id==id }
        }
        override fun close()=sql.close()
    }
    private fun fixture(test: (Kit)->Unit) {
        val root=Files.createTempDirectory("sync-protocol").toFile()
        try { Kit(root).use(test) } finally { root.deleteRecursively() }
    }
    @Test fun pendingManualStatusCannotOvertakePositionOrAcceptAnOlderStateReply() = fixture { k ->
        val owner="fixture-account"
        val digest=CatalogWorkflow.partial(k.book)
        val pending=File(k.root,"orbit-cache/workflows/${BookOrbitLibrary.namespace(owner)}.lua")
        pending.parentFile!!.mkdirs()
        pending.writeBytes(LuaValue.encode(mapOf("finishes" to mapOf(digest to mapOf("hash" to digest,"manual_status" to "read",
            "ready" to true,"native_summary" to mapOf("status" to "complete"),"native_token" to "current")))))
        k.sidecar.writeBytes(LuaValue.encode(mapOf("summary" to mapOf("status" to "complete","rating" to 4L),"booksync_status_token" to "current")))
        val capture=k.sync.capture(mapOf("path" to k.book.path,"percentage" to .4,"position" to "/p40","catalog_owner" to owner))
        val snapshot=LuaValue.parse(capture.second) as Map<*,*>
        assertEquals(true,snapshot["manual_status_pending"]);assertEquals(.4,snapshot["percentage"])
        k.response={_,body ->
            val sent=(body["books"] as List<*>).single() as Map<*,*>
            assertFalse(sent.containsKey("status"))
            mapOf("results" to listOf(mapOf("statusSet" to true,"status" to "reading")))
        }
        k.document=digest
        val job=k.job(snapshot.entries.associate { it.key.toString() to it.value })
        k.sync.phase(job,"state",job.checkpoint,null)
        assertEquals("complete",(LegacyLifecycleImport.literal(k.sidecar)!!["summary"] as Map<*,*>)["status"])
    }
    @Test fun phaseRequestsAreAdapterOwnedAndStatsCursorDoesNotLoseEqualTimestampRows() = fixture { k ->
        JdbcSql(File(k.root,"statistics.sqlite3")).use { db ->
            db.exec("CREATE TABLE book (id INTEGER PRIMARY KEY,md5 TEXT)")
            db.exec("CREATE TABLE page_stat_data (id_book INTEGER,page INTEGER,start_time INTEGER,duration INTEGER,total_pages INTEGER)")
            db.exec("INSERT INTO book VALUES (1,?)",k.document)
            db.transaction { repeat(300) { db.exec("INSERT INTO page_stat_data VALUES (1,?,1000,10,400)",it+1) } }
        }
        val job=k.job(mapOf("stats_ids" to listOf(1)))
        var cp=k.sync.phase(job,"match",job.checkpoint,null).checkpoint
        val first=k.sync.phase(job,"stats",cp,null); assertFalse(first.complete); cp=first.checkpoint
        val second=k.sync.phase(job,"stats",cp,null); assertTrue(second.complete)
        val uploaded=k.calls.filter { it.first.endsWith("page-stats") }.flatMap {
            val books=it.second["books"] as List<*>; (books.single() as Map<*, *>)["events"] as List<*>
        }
        assertEquals(300,uploaded.size)
        assertEquals((1L..300L).toList(),uploaded.map { (it as Map<*, *>)["page"] })
    }
    @Test fun remotePendingWaitsForCloseThenPersistsSidecarBeforeAcknowledgmentAndVerifiesOneLocator() = fixture { k ->
        val remote=mapOf("serverId" to 10L,"version" to 2L,"datetime" to "2026-11-25 10:00:00","posFormat" to "xpointer",
            "pos0" to "/p10","pos1" to "/p11","drawer" to "lighten","text" to "fixture")
        val job=k.job(mapOf("annotations" to emptyList<Any>(),"bookmarks" to emptyList<Any>()),
            mapOf("remote_pending" to mapOf("annotations" to mapOf("to_apply" to mapOf("add" to listOf(remote)))),
                "exchange_annotations" to mapOf("done" to true),"exchange_bookmarks" to mapOf("done" to true)))
        val held=k.sync.phase(job,"annotations",job.checkpoint,k.book.path)
        assertFalse(held.complete); assertTrue(k.calls.isEmpty())
        k.response={path,_ ->
            if(path.endsWith("exchange-ack")) {
                val data=LegacyLifecycleImport.literal(k.sidecar)!!
                assertEquals("keep",data["unrelated"])
                assertEquals(1,(data["annotations"] as List<*>).size)
            }
            mapOf("results" to listOf(emptyMap<String,Any>()))
        }
        val closed=k.sync.phase(job,"annotations",held.checkpoint,null)
        assertTrue(closed.complete)
        val row=k.sync.nextVerification("account",k.document)["row"] as Map<*, *>
        assertEquals("/p10",row["start"]); assertEquals("/p11",row["end"])
        assertFalse(row.containsKey("serverId")); assertFalse(row.containsKey("version"))
        val capture=k.sync.capture(mapOf("path" to k.book.path,"percentage" to .5,"position" to "/p50","captured_at" to 1001L))
        val captured=LuaValue.parse(capture.second) as Map<*, *>
        assertEquals("unverified sidecar rows must not become local uploads",emptyList<Any>(),captured["annotations"])
        k.sync.verification("account",k.document,row["key"] as String,true,10)
        assertTrue(k.sync.nextVerification("account",k.document).isEmpty())
        assertEquals(true,(((k.calls.last().second["books"] as List<*>).single() as Map<*, *>)["applied"] as List<*>).let { (it.single() as Map<*, *>)["verified"] })
    }
    @Test fun unknownRatingAndReviewNeverBecomeAccidentalClearsAndOpenSidecarsAreNotWritten() = fixture { k ->
        val original=k.sidecar.readBytes()
        k.response={path,body ->
            if(path.endsWith("book-states")) {
                val sent=(body["books"] as List<*>).single() as Map<*, *>
                assertFalse(sent.containsKey("rating")); assertFalse(sent.containsKey("reviewNote"))
                assertFalse(sent.containsKey("ratingCleared")); assertFalse(sent.containsKey("reviewCleared"))
                mapOf("results" to listOf(mapOf("statusSet" to true,"status" to "complete","ratingSet" to true,"rating" to 4,"reviewNoteSet" to false)))
            } else emptyMap<String,Any>()
        }
        val job=k.job(mapOf("status" to "reading"))
        val held=k.sync.phase(job,"state",job.checkpoint,k.book.path)
        assertFalse(held.complete); assertArrayEquals(original,k.sidecar.readBytes())
        k.sync.phase(job,"state",held.checkpoint,null)
        val summary=LegacyLifecycleImport.literal(k.sidecar)!!["summary"] as Map<*, *>
        assertEquals("complete",summary["status"]); assertEquals(4L,summary["rating"])
    }
    @Test fun knownAccountHistoryPreservesExplicitRatingAndReviewClears() = fixture { k ->
        k.sql.exec("INSERT INTO adapter_sync_books VALUES (?,?,?)","account",k.document,LuaValue.encode(mapOf(
            "ratingSyncedKnown" to true,"ratingSynced" to 4,"reviewSyncedKnown" to true,"reviewSyncedNote" to "old review")))
        k.sync.phase(k.job(emptyMap()),"state",LuaValue.encode(emptyMap<String,Any>()),k.book.path)
        val sent=(k.calls.single().second["books"] as List<*>).single() as Map<*, *>
        assertEquals(true,sent["ratingCleared"]); assertEquals(true,sent["reviewCleared"])
    }
    @Test fun disabledAnnotationSyncDoesNotStartExchangesOrChangeSidecars() = fixture { k ->
        val original=k.sidecar.readBytes()
        for(job in listOf(k.job(mapOf("annotation_sync" to false)),k.job(emptyMap(),mapOf("legacy" to mapOf("annotation_sync" to false))))) {
            assertTrue(k.sync.phase(job,"annotations",job.checkpoint,null).complete)
        }
        assertTrue(k.calls.isEmpty()); assertArrayEquals(original,k.sidecar.readBytes())
    }
    @Test fun customDirectionsTranslateSavedPresetAndRespectLaterPreferenceChanges() = fixture { k ->
        val settings=File(k.root,"settings").also { it.mkdirs() }
        val config=File(k.root,"settings.reader.lua")
        fun write(ahead: Int,behind: Int) { config.writeBytes(LuaValue.encode(mapOf("orbit_android" to mapOf("sync_mode" to "custom",
            "osm_saved_plugin" to mapOf("sync_forward" to 2,"sync_backward" to 1)),"bookorbit" to mapOf("sync_forward" to ahead,"sync_backward" to behind)))) }
        val sync=BookOrbitSync(settings,{_,_->error("preferences never use network")},k.sql,::JdbcSql,{true})
        write(3,3); assertEquals(PositionDirections(false,"follow","ask"),sync.directions())
        write(1,2); assertEquals(PositionDirections(false,"ask","follow"),sync.directions())
    }
    @Test fun malformedSidecarIsPreservedInsteadOfBeingOverwritten() = fixture { k ->
        k.sidecar.writeText("return os.execute('not evaluated')")
        val job=k.job(emptyMap(),mapOf("remote_pending" to mapOf("state" to mapOf("status_known" to true,"status" to "complete"))))
        assertThrows(ServerFailure::class.java) { k.sync.phase(job,"state",job.checkpoint,null) }
        assertEquals("return os.execute('not evaluated')",k.sidecar.readText())
    }
}

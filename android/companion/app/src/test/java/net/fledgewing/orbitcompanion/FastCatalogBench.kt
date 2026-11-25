package net.fledgewing.orbitcompanion

import java.io.File
import java.nio.file.Files
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Deterministic catalog shape shared with Xteink's bulk benchmark. Transport latency is
 * optional and reported separately; this is JVM/SQLite evidence, never device timing. */
class FastCatalogBench {
    @Test fun benchmark() {
        assumeTrue(System.getenv("ORBIFY_BULK_BENCH") == "1")
        val fixture = JSONObject(File("../../../shared/fixtures/catalog/bulk-refresh/catalog.json").readText())
        val shape = fixture.getJSONObject("benchmark")
        val n = shape.getInt("books")
        val latency = System.getenv("ORBIFY_BULK_LATENCY_MS")?.toLong() ?: 0L
        var changed = false
        val books = (1..n).map { id -> mapOf<String,Any?>("id" to id.toLong(),"title" to "Book %05d".format(id),
            "authors" to listOf("Author %03d".format(id%50)),"seriesName" to "Series %03d".format(id%100),"seriesIndex" to (id/100).toString(),
            "formats" to listOf(if(id%2==0) "epub" else "pdf"),"files" to listOf(mapOf("id" to id*10L,"format" to "epub","contentVersion" to "v1","devicePath" to "$id.epub","downloadUrl" to "/files/${id*10}/download"))) }
        fun book(id: Int) = if(changed && id==1) books[id-1] + ("title" to "Changed book") else books[id-1]
        fun row(id: Int) = book(id).filterKeys {it!="files"} + mapOf("seriesId" to (id%100+1000L),"readStatus" to listOf("unread","reading","read")[id%3],"hasCover" to true,
            "addedAt" to "2026-01-01","updatedAt" to if(changed && id==1) "2026-02-01" else "2026-01-02","lastReadAt" to null)
        fun scope(key:String,id:Int): List<Int> = when(key) {
            "libraryId" -> (1..n).filter {it%2==id-1}
            "collectionId" -> (1..n).filter {it%7==id}
            "smartScopeId" -> (1..n).filter {it%11==id}
            "seriesId" -> (1..n).filter {it%100==id-1000} + if(id-1000<5) (1..10).map {it*100+50+id-1000} else emptyList()
            else -> emptyList()
        }
        var calls=0; var bytes=0L; var peak=0L
        val lines=ArrayList<String>()
        val root=Files.createTempDirectory("bulk-bench").toFile()
        val inventory=LuaValue.fromJson(File("../../../shared/fixtures/catalog/sections.json").readText()) as Map<*,*>
        val worker=CacheWorker(root,{url,_,sink,_->
            assertNull("covers stay lazy",sink)
            val (path,encoded)=MirrorLogic.splitPath(url.substringAfter("/api/v1"))
            val q=MirrorLogic.parseQuery(encoded)
            assertFalse("details stay lazy",Regex("/books/[0-9]+").containsMatchIn(path))
            val size=q["size"]?.toInt()?:100; val page=q["page"]?.toInt()?:1
            val response: Map<String,Any?> = when {
                path.endsWith("/manifest") -> {
                    val start=q["cursor"]?.toInt()?:0; val end=minOf(n,start+size)
                    mapOf("items" to (start+1..end).map(::book),"hasNext" to (end<n),"nextCursor" to if(end<n) end.toString() else null)
                }
                path.contains("/sections/") && !path.contains("/dashboard/") -> {
                    val section=path.substringAfterLast('/')
                    val entries=when(section) {
                        "series" -> (1000..1099).map {id->mapOf("id" to "series:$id","seriesId" to id,"title" to "Series %03d".format(id-1000),"count" to scope("seriesId",id).size)}
                        "authors" -> (0..49).map {mapOf("id" to "Author %03d".format(it),"title" to "Author %03d".format(it),"count" to (n/50))}
                        else -> {val (selector,count)=when(section){"libraries"->"libraryId" to 2;"collections"->"collectionId" to 3;else->"smartScopeId" to 2};(1..count).map {mapOf("id" to it,"title" to "Scope $it","count" to scope(selector,it).size)}}
                    }
                    mapOf("items" to entries.drop((page-1)*size).take(size),"total" to entries.size)
                }
                path.endsWith("/books") -> {
                    var ids=(1..n).toList()
                    for(k in listOf("libraryId","collectionId","smartScopeId","seriesId"))q[k]?.let {ids=scope(k,it.toInt())}
                    q["ids"]?.let {ids=it.split(',').map(String::toInt)}
                    q["readStatus"]?.let {status->ids=ids.filter {BulkCatalog.status(row(it)["readStatus"])==status}}
                    ids=when(q["sort"]){"author"->ids.sortedWith(compareBy<Int>{it%50}.thenBy{it});"published"->ids.sortedWith(compareBy<Int>{it%37}.thenBy{it});"recently_read"->ids.sortedWith(compareBy<Int>{it%17}.thenBy{it});else->ids}
                    if(q["order"]=="desc")ids=ids.reversed()
                    mapOf("items" to ids.drop((page-1)*size).take(size).map {id->row(id).let {r->if(q["seriesId"]!=null)r+mapOf("seriesId" to q["seriesId"]!!.toLong(),"seriesIndex" to (id/100).toString()) else r}},"total" to ids.size)
                }
                else -> emptyMap()
            }
            val payload=JSONObject(response).toString().toByteArray()
            calls++;bytes+=payload.size
            peak=maxOf(peak,Runtime.getRuntime().totalMemory()-Runtime.getRuntime().freeMemory())
            if(latency>0)Thread.sleep(latency)
            CacheWorker.Reply(200,payload)
        },log={lines.add(it)},openSql=::JdbcSql)
        try {
            for(mode in (System.getenv("ORBIFY_BULK_MODES")?.split(',') ?: listOf("cold","unchanged","changed"))) {
                changed=mode=="changed"
                val before=calls; val received=bytes; val start=System.nanoTime()
                val result=worker.run(CacheWorker.Plan(mapOf("op" to if(mode=="cold")"full" else "incremental","run" to mode,"owner" to "reader|https://books.example/api/v1","catalog" to inventory,"limit" to 250L*1024*1024)),CacheWorker.Creds("https://books.example/api/v1","reader","key"))
                assertEquals("finished",result)
                val seconds=(System.nanoTime()-start)/1e9
                println("BULK BENCH $mode books=$n requests=${calls-before} bytes=${bytes-received} elapsedSeconds=$seconds latencyMs=$latency databaseBytes=${worker.store.fileBytes()}")
                lines.filter {it.startsWith("bulk:")}.forEach(::println);lines.clear()
                assertEquals(n.toLong(),worker.store.db().query("SELECT count(*) FROM books"){it.long(0)}.single())
                val window=worker.store.window("/koreader/plugin/catalog/books?sort=title&order=asc",null,20,10000)!!
                assertEquals(20,(window["items"] as List<*>).size)
            }
            println("BULK BENCH JVM requestSampledHeapPeakBytes=$peak (includes fixture/server/test runtime)")
        } finally {worker.store.close();root.deleteRecursively()}
    }
}

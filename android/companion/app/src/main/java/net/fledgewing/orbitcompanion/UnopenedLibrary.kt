// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.time.Instant
import java.time.ZoneId

/** Conservative device-only pool: absent saved opening evidence is not server unread. */
class UnopenedLibrary(private val roots:List<File>,private val readerRoot:File,private val now:Long,
    private val zone:ZoneId=ZoneId.systemDefault()) {
    private val day=Instant.ofEpochSecond(now).atZone(zone).toLocalDate().toString()
    private fun text(file:File):Any? {
        if(!file.isFile || file.length()>1048576 || java.nio.file.Files.isSymbolicLink(file.toPath())) return null
        val source=file.readText(Charsets.ISO_8859_1).replaceFirst(Regex("\\A(?:--[^\\n]*\\n)?\\s*return\\s+"),"")
        return LuaValue.parse(source.toByteArray(Charsets.ISO_8859_1))
    }
    private val history by lazy {
        val value=runCatching { text(File(readerRoot,"history.lua")) }.getOrNull()
        val entries=when(value) { is List<*> -> value;is Map<*,*> -> if(value.isEmpty()) emptyList<Any>() else if(value.keys.all { it is Number && it.toLong() in 1..value.size.toLong() }) value.values.toList() else null;else -> null }
        entries?.takeIf { rows -> rows.all { val path=(it as? Map<*,*>)?.get("file") as? String;path!=null && path.startsWith("/") && path.length<=4096 && '\u0000' !in path } }?.map { File(LuaValue.utf8((it as Map<*,*>)["file"].toString())).canonicalPath }?.toSet()
    }
    private fun hash(file:File):String {
        val digest=MessageDigest.getInstance("MD5")
        RandomAccessFile(file,"r").use { input ->
            val bytes=ByteArray(1024)
            for(offset in listOf(0L)+(0..10).map { 1024L shl (2*it) }) {
                BulkWork.checkpoint();input.seek(offset);val n=input.read(bytes);if(n<0) break;digest.update(bytes,0,n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
    private val centralStems by lazy {
        val central=File(readerRoot,"docsettings")
        if(!central.isDirectory) emptySet() else central.walkTopDown().onEnter {
            BulkWork.checkpoint();!java.nio.file.Files.isSymbolicLink(it.toPath())
        }.filter { it.isDirectory && it.name.endsWith(".sdr") }.map {
            File("/"+it.relativeTo(central).path.removeSuffix(".sdr")).canonicalPath
        }.toSet()
    }
    private val legacyPaths by lazy {
        File(readerRoot,"history").listFiles().orEmpty().mapNotNull { file ->
            BulkWork.checkpoint()
            val name=file.name
            val close=name.indexOf("] ")
            if(!name.startsWith("[") || close<2 || !name.endsWith(".lua")) null else {
                val parent=name.substring(1,close).removeSuffix("#").replace('#','/')
                File(parent,name.substring(close+2).removeSuffix(".lua")).canonicalPath
            }
        }.toSet()
    }
    private fun sidecar(file:File):Boolean {
        val stem=file.canonicalPath.substringBeforeLast('.')
        if(File("$stem.sdr").exists()) return true
        if(stem in centralStems || file.canonicalPath in legacyPaths) return true
        val legacy="["+file.canonicalPath.replace(Regex("(.*/)([^/]+)$"),"$1] $2").replace('/','#')+".lua"
        if(File(readerRoot,"history/$legacy").exists()) return true
        val hashes=File(readerRoot,"hashdocsettings")
        if(hashes.isDirectory) {
            val md5=hash(file)
            if(File(hashes,"${md5.take(2)}/$md5.sdr").exists()) return true
        }
        return false
    }
    private fun evidenceReady()=history!=null && listOf("docsettings","hashdocsettings","history").all { name ->
        val dir=File(readerRoot,name)
        !dir.exists() || dir.isDirectory && dir.canRead() && !java.nio.file.Files.isSymbolicLink(dir.toPath())
    }
    private val pool by lazy {
        val opened=history
        if(opened==null || !evidenceReady()) emptyList() else DeviceLibrary.files(roots).filter { file ->
            BulkWork.checkpoint();file.canonicalPath !in opened && try { !sidecar(file) } catch(e:Exception) { if(e is InterruptedException) throw e;false }
        }.sortedWith(compareBy<File> { it.lastModified() }.thenBy { it.canonicalPath }).mapIndexed { index,file ->
            val key=MessageDigest.getInstance("SHA-256").digest(file.canonicalPath.toByteArray()).joinToString("") { "%02x".format(it) }
            mapOf("key" to "device:book:$key","title" to LuaValue.boundedText(file.nameWithoutExtension,160),"local_path" to LuaValue.str(file.canonicalPath),
                "rank" to index,"on_device" to true,"status" to "unknown","downloadable" to false,"detail_available" to false,"can_remove" to false,"status_write" to false,
                "file_bytes" to file.length(),"file_at" to file.lastModified()/1000,
                "status_note" to "No saved opening record")
        }.toList()
    }
    private fun selected(args:Map<*,*>):List<Map<String,Any?>> {
        val current=(args["exclude_path"] as? String)?.let(LuaValue::utf8)?.let { File(it).canonicalPath }
        return pool.filter { LuaValue.utf8(it["local_path"].toString())!=current }
    }
    fun window(args:Map<*,*>):Map<String,Any?> {
        val query=args["query"] as? Map<*,*> ?: emptyMap<Any,Any>();LibraryFilter.validate(query)
        val rows=selected(args).filter { LibraryFilter.matches(it,query) }.sortedWith(LibraryFilter.comparator(query))
        val offset=((args["offset"] as? Number)?.toInt() ?: 0).coerceAtLeast(0);val limit=((args["limit"] as? Number)?.toInt() ?: 12).coerceIn(1,24)
        if(args["op"]=="groups") return SeriesPresentation.groups(rows,query,offset,limit,
            ((args["preview"] as? Number)?.toInt() ?: 3).coerceIn(1,9),((args["group_limit"] as? Number)?.toInt() ?: 3).coerceIn(1,6))+
            mapOf("context" to mapOf("coverage" to LuaValue.str("No saved opening record · local files")),"freshness" to mapOf("saved" to evidenceReady(),"origin" to "local-reader"))
        if(args["op"]=="facets") {
            val f=query.entries.associate { it.key.toString() to it.value }
            val facet=LibraryFacets(args["field"].toString(),f,now)
            selected(args).forEach { facet.include(it) }
            return facet.page(offset,limit)+mapOf("total" to rows.size,"freshness" to mapOf("saved" to evidenceReady(),"origin" to "local-reader"))
        }
        val page=rows.drop(offset).take(limit)
        return mapOf("items" to page,"total" to rows.size.takeIf { evidenceReady() },"next" to (offset+page.size).takeIf { it<rows.size },
            "context" to mapOf("title" to "Unopened on this reader","coverage" to LuaValue.str(if(history==null) "Saved opening history unavailable" else "No saved opening record · local files")),
            "freshness" to mapOf("saved" to evidenceReady(),"origin" to "local-reader"))
    }
    fun dust(args:Map<*,*>):Map<String,Any?> {
        if(!evidenceReady()) return mapOf("state" to "unavailable","reason" to "Saved opening records unavailable","row_count" to 1)
        val rows=selected(args)
        if(rows.isEmpty()) return mapOf("state" to "empty","row_count" to 1)
        val pick=if(args["day"]==day) ((args["pick"] as? Number)?.toLong() ?: 0).coerceIn(0,1000000000) else 0
        val index=Math.floorMod(Instant.ofEpochSecond(now).atZone(zone).toLocalDate().toEpochDay()+pick,rows.size.toLong()).toInt()
        val book=rows[index];val at=(book["file_at"] as? Number)?.toLong()
        val age=at?.takeIf { it>0 && it<=now }?.let { (now-it)/86400 }
        return mapOf("state" to "ready","row_count" to 1,"book" to book,"day" to day,"pick" to pick,
            "age" to (age?.let { "File age $it days" } ?: "File age unknown"),"summary" to LuaValue.str("${rows.size} local files · ${rows.sumOf { (it["file_bytes"] as Number).toLong() }} bytes"),
            "source" to "No saved opening record")
    }
}

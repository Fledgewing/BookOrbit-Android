// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import java.io.File
import java.security.MessageDigest

/** Device files have an identity even before a server is configured. Only the companion
 * scans and parses native sidecars; LibraryReadModel still bounds every published window. */
class DeviceLibrary(private val roots: List<File>) : ServerAdapter {
    override val id = "device"
    companion object { const val OWNER = "device-local" }
    private val books by lazy {
        roots.distinctBy { it.canonicalPath }.flatMap { root ->
            if (!root.isDirectory) emptyList() else root.walkTopDown().onEnter {
                BulkWork.checkpoint()
                Places.inside(it,listOf(root)) != null && !java.nio.file.Files.isSymbolicLink(it.toPath()) && !it.name.endsWith(".sdr")
            }.filter { it.isFile && it.extension.lowercase() in setOf("epub","pdf","mobi","azw","azw3","fb2","djvu","cbz","cbr","txt") &&
                Places.inside(it,listOf(root)) != null }.map(::book).toList()
        }.distinctBy { it["key"] }
    }
    private fun sidecar(file: File) = File(file.parentFile,"${file.nameWithoutExtension}.sdr")
    private fun book(file: File): Map<String,Any?> {
        BulkWork.checkpoint()
        val metadata=File(sidecar(file),"metadata.${file.extension}.lua")
        val data=if(metadata.isFile && metadata.length()<=1048576 && Places.inside(metadata,roots)!=null) runCatching {
            val text=metadata.readText(Charsets.ISO_8859_1).replaceFirst(Regex("\\A(?:--[^\\n]*\\n)?\\s*return\\s+"),"")
            LuaValue.parse(text.toByteArray(Charsets.ISO_8859_1)) as? Map<*,*>
        }.getOrNull() else null
        val props=data?.get("doc_props") as? Map<*,*>
        val summary=data?.get("summary") as? Map<*,*>
        val fraction=(data?.get("percent_finished") as? Number)?.toDouble()?.takeIf { it.isFinite() && it in 0.0..1.0 }
        val status=when(summary?.get("status")) { "complete" -> "finished"; "reading" -> "reading"; "abandoned" -> "abandoned"; else -> if(fraction!=null && fraction>0) "reading" else "unread" }
        val hash=MessageDigest.getInstance("SHA-256").digest(file.canonicalPath.toByteArray()).joinToString("") { "%02x".format(it) }
        val cover=sidecar(file).listFiles()?.filter { it.isFile && it.nameWithoutExtension=="cover" && Places.inside(it,roots)!=null }?.sortedBy { it.name }?.firstOrNull()
        return mapOf("key" to "device:book:$hash","title" to LuaValue.boundedText((props?.get("title") as? String)?.let(LuaValue::utf8) ?: file.nameWithoutExtension,256),
            "authors" to listOfNotNull((props?.get("authors") as? String)?.let { LuaValue.boundedText(LuaValue.utf8(it),256) }),
            "local_path" to LuaValue.str(file.canonicalPath),"on_device" to true,"status" to status,"progress" to fraction?.times(100),
            "last_read" to (metadata.lastModified()/1000).takeIf { metadata.isFile },"cover_path" to cover?.path?.let(LuaValue::str),
            "formats" to listOf(file.extension.lowercase()),"available" to mapOf("cover" to (cover!=null)),"downloadable" to false)
    }
    override fun localFiles(owner: String): List<LocalBook>? = if(owner==OWNER) books.map {
        LocalBook(File(LuaValue.utf8(it["local_path"] as String)),it["status"]=="finished",null)
    } else null
    override fun project(owner: String, request: Map<*,*>): Map<String,Any?> {
        if(owner!=OWNER) return mapOf("error" to "unauthorized")
        val fresh=mapOf("saved" to true,"origin" to "local-device")
        fun rows(items: List<*>) = mapOf("items" to items,"freshness" to fresh)
        val op=request["op"]
        if(op=="capabilities") return mapOf("onDevice" to true,"readingStats" to true,"catalog" to true,"detail" to true,"download" to false,
            "lists" to mapOf("read" to false,"save" to false),"wantToRead" to false,"progress" to mapOf("read" to true,"write" to false),
            "status" to mapOf("read" to true,"write" to false))
        if(op in setOf("lists","collections")) return rows(emptyList<Any>())
        if(op=="sources") {
            val definitions=listOf(Triple("device","On this device",books.size),Triple("reading","Reading now",books.count { it["status"]=="reading" }),Triple("finished","Finished",books.count { it["status"]=="finished" }))
            val offset=((request["offset"] as? Number)?.toInt() ?: 0).coerceAtLeast(0)
            val limit=((request["limit"] as? Number)?.toInt() ?: 6).coerceIn(1,6)
            val items=if(request["category"] in setOf("lists","authors")) emptyList() else definitions.drop(offset).take(limit).map { (src,title,count) -> mapOf("src" to src,"title" to title,"count" to count) }
            return rows(items)+mapOf("total" to if(items.isEmpty()) 0 else definitions.size)
        }
        if(op=="catalog.state") return mapOf("state" to "idle","freshness" to fresh)
        if(op=="library.summary") return mapOf("total" to books.size,"on_device" to books.size,"freshness" to fresh)
        if(op in setOf("book","reader","progress","status","cover")) {
            val row=books.firstOrNull { if(op=="reader") it["local_path"]==request["path"] else it["key"]==request["key"] } ?: return rows(emptyList<Any>())
            return when(op) {
                "cover" -> mapOf("local_path" to row["cover_path"],"freshness" to fresh)
                "progress","status" -> row + mapOf("freshness" to fresh)
                else -> rows(listOf(row))
            }
        }
        if(op !in setOf("window","counts","facets","groups")) return rows(emptyList<Any>())
        val filter=(request["query"] as? Map<*,*>).orEmpty().entries.associate { it.key.toString() to it.value }
        LibraryFilter.validate(filter)
        val source=request["source"]
        val sourceFilter=when(source) { "reading" -> mapOf("show" to "reading"); "finished" -> mapOf("show" to "finished"); "want-to-read" -> mapOf("wtr" to true); else -> emptyMap() }
        var selected=if(source !in setOf("all","library/all","on-device","reading","finished","search")) emptyList() else books.filter { LibraryFilter.matches(it,sourceFilter) && LibraryFilter.matches(it,filter) }
        val sort=if(filter["sort"]==null && source=="reading") filter+mapOf("sort" to "last","dir" to "desc") else filter
        selected=selected.sortedWith(LibraryFilter.comparator(sort))
        if(request["exclude_current"]==true && source=="reading") selected=selected.drop(1)
        val offset=((request["offset"] as? Number)?.toInt() ?: 0).coerceAtLeast(0)
        val limit=((request["limit"] as? Number)?.toInt() ?: 24).coerceIn(1,24)
        if(op=="groups") return SeriesPresentation.groups(selected,filter,offset,limit.coerceAtLeast(5),
            ((request["preview"] as? Number)?.toInt() ?: 3).coerceIn(1,9),
            ((request["group_limit"] as? Number)?.toInt() ?: 2).coerceIn(1,6))+mapOf("freshness" to fresh)
        if(op=="counts") return mapOf("total" to selected.size,"freshness" to fresh)
        if(op=="facets") return LibraryFacets(request["field"].toString(),filter,System.currentTimeMillis()/1000).let { facet ->
            selected.forEach { facet.include(it) }; facet.page(offset,limit)+mapOf("freshness" to fresh) }
        return rows(selected.drop(offset).take(limit)) + mapOf("total" to selected.size,"next" to (offset+limit).takeIf { it<selected.size },"local_coverage" to "device-files")
    }
}

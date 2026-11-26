// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import android.os.StatFs
import java.io.File
import java.time.Instant
import java.time.ZoneOffset

/** Local files are normalized by the existing catalog adapter; no backend payload escapes it. */
data class LocalBook(val file: File, val finished: Boolean, val md5: String?)

/** Runs only on the existing companion writer. No scan, arithmetic or formatting in Lua. */
class DeviceStorage(private val store: ProjectionStore, private val adapter: ServerAdapter,
    private val volume: File = requireNotNull(requireNotNull(requireNotNull(store.root.parentFile).parentFile).parentFile),
    private val covers: File = ServerAdapters.connector.coverCacheDir(volume),
    private val capacity: (File) -> Pair<Long,Long> = { StatFs(it.path).let { s -> s.totalBytes to s.availableBytes } },
    private val now: () -> Long = { System.currentTimeMillis()/1000 },
    private val lastOpened: (LocalBook) -> Long? = { book -> lastOpened(store.root,book) }) {
    companion object {
        val folders = listOf("Books","BookSync","Download")
        fun downloadRoot(root: File): File {
            val saved=File(root,"download-folder")
            val name=if(saved.isFile) saved.readText().takeIf(folders::contains) else null
            val volume=requireNotNull(requireNotNull(requireNotNull(root.parentFile).parentFile).parentFile)
            return File(volume,name ?: "Books")
        }
        fun format(bytes: Long): String = if (bytes >= 1_000_000_000L) String.format(java.util.Locale.ROOT,"%.1f GB",bytes/1e9)
            else if(bytes>=1_000_000) "${bytes/1_000_000} MB" else if(bytes>=1000) "${bytes/1000} KB" else "$bytes B"
        fun lastOpened(root: File, book: LocalBook): Long? {
            val md5=book.md5?.takeIf { Regex("[0-9a-f]{32}").matches(it) } ?: return null
            val file=File(root.parentFile,"statistics.sqlite3")
            if (!file.isFile) return null
            return runCatching { AndroidSql(file,readOnly=true).use { sql ->
                sql.query("SELECT MAX(p.start_time) FROM page_stat p JOIN book b ON b.id=p.id_book WHERE b.md5=?",md5) { it.long(0) }.singleOrNull()
            } }.getOrNull()
        }
    }
    private fun files(owner: String): List<LocalBook>? = adapter.localFiles(owner)?.mapNotNull {
        val file=Places.inside(it.file,listOf(volume))
        if(file != null && file.isFile && Places.inside(file,listOf(store.root,covers)) == null) it.copy(file=file) else null
    }?.distinctBy { it.file.path }
    private fun coverFiles(): List<File> = (if(Places.inside(covers,listOf(volume))==null) emptyList() else covers.walkTopDown().maxDepth(2).onEnter { Places.inside(it,listOf(covers)) != null && !java.nio.file.Files.isSymbolicLink(it.toPath()) }.toList()).filter {
        it.isFile && Places.inside(it,listOf(covers)) != null && (it.extension == "jpg" || it.name.endsWith(".jpg.etag"))
    }
    private fun old(book: LocalBook): Boolean = lastOpened(book)?.let {
        it < Instant.ofEpochSecond(now()).atZone(ZoneOffset.UTC).minusMonths(6).toEpochSecond()
    } == true
    private fun folder(): String? = File(store.root,"download-folder").let { if (it.isFile) it.readText().takeIf(folders::contains) else null }
    fun summary(owner: String, excludePath: String? = null, currentFolder: String? = null): Map<String,Any?> {
        val selected=folder()
        val destination=selected?.let { File(volume,it) } ?: currentFolder?.let { Places.inside(it,listOf(volume)) }
        val label=destination?.let { if(it.parentFile?.canonicalFile==volume.canonicalFile) "/${it.name}" else it.path } ?: "Not selected"
        val books=files(owner)
        val coverFiles=coverFiles()
        val coverBytes=coverFiles.sumOf { it.length() }
        val cacheBytes=store.root.walkTopDown().onEnter { Places.inside(it,listOf(store.root)) != null && !java.nio.file.Files.isSymbolicLink(it.toPath()) }.filter { it.isFile && Places.inside(it,listOf(store.root)) != null }.sumOf { it.length() } + coverBytes
        val bookBytes=books.orEmpty().sumOf { it.file.length() }
        val cap=runCatching { capacity(volume) }.getOrNull()?.takeIf { it.first>0 && it.second in 0..it.first }
        val protectedPath=excludePath?.let { File(it).canonicalPath }
        val eligible=books.orEmpty().filter { it.file.path != protectedPath }
        val oldBooks=eligible.filter(::old)
        val finishedBooks=eligible.filter { it.finished }
        val actions=mutableListOf<Map<String,Any?>>()
        fun action(id: String, label: String, candidates: List<File>, suffix: String) {
            val bytes=candidates.sumOf { it.length() }
            if (bytes>0) actions += mapOf("id" to id,"label" to label,"bytes" to bytes,"count" to candidates.size,
                "detail" to "Frees ${format(bytes)} · $suffix", "token" to token(candidates))
        }
        action("old","Remove books not opened in 6 months",oldBooks.map { it.file },"${oldBooks.size} books")
        action("finished","Remove finished books from device",finishedBooks.map { it.file },"${finishedBooks.size} books you have read")
        action("covers","Clear cover cache",coverFiles,"covers download again when needed")
        val total=cap?.first; val free=cap?.second
        val low=total!=null && free!=null && free<total/10
        val freeLabel=free?.let(::format) ?: "Space unavailable"
        val parts=if (total!=null && free!=null) {
            val b=bookBytes.coerceAtMost(total-free); val c=cacheBytes.coerceAtMost(total-free-b)
            listOf(mapOf("label" to "Books","bytes" to bookBytes,"fraction" to b.toDouble()/total,"pattern" to "solid"),
                mapOf("label" to "Covers and offline catalog","bytes" to cacheBytes,"fraction" to c.toDouble()/total,"pattern" to "hatch"),
                mapOf("label" to "Apps and system","bytes" to total-free-b-c,"fraction" to (total-free-b-c).toDouble()/total,"pattern" to "dots"),
                mapOf("label" to "Free","bytes" to free,"fraction" to free.toDouble()/total,"pattern" to "white"))
                .map { it + mapOf("display" to if(it["label"]=="Books" && books==null) "Not indexed" else format(it["bytes"] as Long)) }
        } else emptyList()
        return mapOf("freshness" to mapOf("saved" to true),"available" to (cap!=null),"on_device" to books?.size,
            "free" to free,"total" to total,"free_label" to freeLabel,
            "caption" to if (total!=null) "$freeLabel free of ${format(total)}" else "Space unavailable",
            "widget_label" to if(low) "Low space · $freeLabel free" else if(total!=null) "$freeLabel free of ${format(total)}" else "Space unavailable",
            "warning" to if(low) "Low space: $freeLabel free. ${if(free!!>=200_000_000) "Downloads still work." else "Downloads must leave 200 MB free."} Free ${format(total!!/10-free)} more to get back above 10% (${format(total/10)})." else null,
            "parts" to parts,"actions" to actions,"folder" to (selected ?: destination?.name?.takeIf(folders::contains)),"download_path" to destination?.path?.let(LuaValue::str),"folder_label" to LuaValue.boundedText(label,160),
            "folders" to folders.map { mapOf("id" to it,"label" to "/$it") },"local_coverage" to if(books==null) "not-saved" else "tracked-files")
    }
    fun command(owner: String, op: String, args: Map<*,*>): Map<String,Any?> {
        require(store.meta("owner")==owner)
        val excludePath=(args["exclude_path"] as? String)?.let(LuaValue::utf8)?.let { File(it).canonicalPath }
        when(op) {
            "storage.folder" -> {
                val value=args["folder"] as? String ?: error("folder")
                require(value in folders)
                val dir=Places.inside(File(volume,value),listOf(volume)) ?: error("folder")
                check(dir.isDirectory || dir.mkdirs())
                val target=File(store.root,"download-folder")
                val temp=File(store.root,"download-folder.part"); temp.writeText(value); check(temp.renameTo(target))
            }
            "storage.free" -> {
                val action=args["action"] as? String ?: error("action")
                val candidates=when(action) {
                    "old" -> files(owner).orEmpty().filter { it.file.path != excludePath }.filter(::old).map { it.file }
                    "finished" -> files(owner).orEmpty().filter { it.file.path != excludePath && it.finished }.map { it.file }
                    "covers" -> coverFiles()
                    else -> error("action")
                }
                // Confirm the exact preview, so a newly downloaded/finished book is never swept in.
                val preview=args["token"] as? String ?: error("token")
                if(preview!=token(candidates)) return summary(owner,excludePath)+mapOf("error" to "Files changed. Review the updated amounts and try again.")
                var failed=false
                candidates.forEach { if (!it.delete() && it.exists()) failed=true }
                if(failed) return summary(owner,excludePath)+mapOf("error" to "Some files could not be removed. Try again.")
            }
            else -> error("operation")
        }
        return summary(owner,excludePath)
    }
    private fun token(files: List<File>): String = java.security.MessageDigest.getInstance("SHA-256")
        .digest(files.sortedBy { it.path }.joinToString("\n") { "${it.canonicalPath}:${it.length()}:${it.lastModified()}" }.toByteArray())
        .joinToString("") { "%02x".format(it) }
}

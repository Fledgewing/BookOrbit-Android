// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import java.io.File

/** Shared native metadata paths. The serial worker writes complete literal records atomically. */
internal class ReaderSidecar(private val settings: File, private val hash: (File)->String?,
    private val allowed: (File)->Boolean) {
    private val global=LegacyLifecycleImport.literal(File(settings.parentFile,"settings.reader.lua")).orEmpty()
    fun path(book: File): File {
        val name="metadata.${book.extension.ifEmpty { "_" }}.lua"
        val doc=File(book.parentFile,"${book.nameWithoutExtension}.sdr/$name")
        val dir=File(settings.parentFile,"docsettings${book.path.substringBeforeLast('.')}.sdr/$name")
        val hash=hash(book)
        val hashed=hash?.let { File(settings.parentFile,"hashdocsettings/${it.take(2)}/$it.sdr/$name") }
        val candidates=when(global["document_metadata_folder"]) {
            "hash" -> listOfNotNull(hashed,doc,dir)
            "dir" -> listOfNotNull(dir,doc,hashed)
            else -> listOfNotNull(doc,dir,hashed)
        }
        return (candidates.firstOrNull { it.isFile } ?: candidates.first()).also { require(allowed(it)) }
    }
    fun read(book: File): Map<String,Any?> {
        val source=path(book)
        if(!source.isFile) return emptyMap()
        val parsed=LegacyLifecycleImport.literal(source) ?: throw ServerFailure("invalid-sidecar")
        return parsed.entries.associate { it.key.toString() to it.value }
    }
    fun write(book: File, data: Map<String,Any?>) {
        val dest=path(book); require(allowed(dest)); dest.parentFile?.mkdirs()
        val temp=File(dest.parentFile,dest.name+".booksync.tmp")
        temp.writeBytes("return ".toByteArray()+LuaValue.encode(data)); check(temp.renameTo(dest))
    }
}

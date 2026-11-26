package net.fledgewing.orbitcompanion.server.bookorbit

import net.fledgewing.orbitcompanion.*
import java.io.File
import java.security.MessageDigest

/** Read-only parsing until the journal/checkpoint commit; then atomic per-entry retirement.
 * Originals stay in a non-writer archive. No Lua is executed, even for corrupt input. */
internal class LegacyLifecycleImport(private val queue: LifecycleQueue, private val root: File,
    private val owner: (Map<*, *>) -> String?, private val crash: (String) -> Unit = {}) {
    companion object {
        private val NAME=Regex("^(entry_[a-fA-F0-9]+_[0-9]+_[0-9]+)_g([0-9]+)\\.lua$")
        fun literal(file: File, max: Int = LifecycleQueue.MAX_BYTES): Map<*, *>? {
            if (!file.isFile || file.length()>max) return null
            val text=String(file.readBytes(),Charsets.ISO_8859_1)
                .replaceFirst(Regex("\\A(?:\\s*--[^\\n]*\\n)*\\s*(?:return\\s+)?"),"")
            return LuaValue.parse(text.toByteArray(Charsets.ISO_8859_1)) as? Map<*, *>
        }
        private fun hash(file: File): String {
            val digest=MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input -> val bytes=ByteArray(8192)
                while (true) { val n=input.read(bytes); if (n<0) break; digest.update(bytes,0,n) } }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
    }
    fun run(quiesced: Boolean): Int {
        check(quiesced) { "legacy writer still active" }
        val source=File(root,"bookorbit-lifecycle-outbox")
        val archive=File(root,"booksync-retired-lifecycle")
        // Resume a crash between individual renames even when its metadata has already moved.
        for ((id,encoded) in queue.imports("bookorbit")) {
            val proof=LuaValue.parse(encoded) as? Map<*, *> ?: continue
            val dest=File(archive,id)
            check(dest.isDirectory || dest.mkdirs())
            for ((name,digest) in proof) {
                require(name is String && name.matches(Regex(Regex.escape(id)+"(?:_payload)?_g[0-9]+\\.lua")))
                val from=File(source,name); val to=File(dest,name)
                if (to.isFile) { check(hash(to)==digest); if (from.isFile) check(hash(from)==digest && from.delete()) }
                else { check(from.isFile && hash(from)==digest); check(from.renameTo(to)) }
                crash("retire-file")
            }
            queue.retired("bookorbit",id)
        }
        val login=literal(File(root.parentFile,"settings.reader.lua"))?.get("bookorbit") as? Map<*, *> ?: emptyMap<Any,Any>()
        owner(login) // Initialize credential/provenance lookup, even when the source is empty.
        val files=source.listFiles().orEmpty().filter { NAME.matches(it.name) }
        require(files.size<=10000)
        var imported=0
        for ((id,generations) in files.groupBy { NAME.matchEntire(it.name)!!.groupValues[1] }) {
            val selected=generations.sortedByDescending { NAME.matchEntire(it.name)!!.groupValues[2].toLongOrNull() ?: 0L }
                .firstNotNullOfOrNull { metadata ->
                    val generation=NAME.matchEntire(metadata.name)!!.groupValues[2].toLongOrNull()
                    val m=literal(metadata) ?: return@firstNotNullOfOrNull null
                    if (m["version"]!=1L || m["id"]!=id || m["generation"]!=generation || (m["acknowledged"] !is Map<*, *> && m["acknowledged"] != emptyList<Any>())) return@firstNotNullOfOrNull null
                    val digest=m["digest"] as? String ?: return@firstNotNullOfOrNull null
                    if (!digest.matches(Regex("[a-fA-F0-9]+"))) return@firstNotNullOfOrNull null
                    val pg=(m["payload_generation"] as? Number)?.toLong()?.takeIf { it>=1 } ?: return@firstNotNullOfOrNull null
                    val payload=File(source,"${id}_payload_g$pg.lua")
                    val p=literal(payload) ?: return@firstNotNullOfOrNull null
                    if (p["version"]!=1L || p["id"]!=id || p["digest"]!=digest || p["snapshot"] !is Map<*, *>) return@firstNotNullOfOrNull null
                    Triple(m,payload,metadata)
                } ?: continue // Damaged entries remain untouched for recovery, never silently dropped.
            val m=selected.first
            val payload=literal(selected.second)!!["snapshot"] as Map<*, *>
            val bound=owner(login+mapOf("_entry" to m,"_snapshot" to payload)) ?: continue // Unproven ownership stays in source.
            val entryFiles=source.listFiles().orEmpty().filter { it.name.matches(Regex(Regex.escape(id)+"(?:_payload)?_g[0-9]+\\.lua")) }
            if (entryFiles.sumOf { it.length() }>LifecycleQueue.MAX_BYTES) continue
            val proof=LuaValue.encode(entryFiles.associate { it.name to hash(it) })
            val key=id // Immutable after quiescence; dedup spans crashes, not account switches.
            val acks=(m["acknowledged"] as? Map<*, *>).orEmpty()
            val pending=(m["remote_pending"] as? Map<*, *>).orEmpty()
            val outstanding=buildSet {
                if(pending.containsKey("annotations") || pending.containsKey("bookmarks")) add("annotations")
                if(pending.containsKey("state")) add("state")
            }
            crash("before-checkpoint")
            queue.enqueue("bookorbit",bound,m["digest"] as String,LuaValue.encode(payload),
                LifecycleQueue.PHASES.filter { acks[it]==true && it !in outstanding }.toSet(),
                LuaValue.encode(mapOf("legacy" to m,"remote_pending" to m["remote_pending"])),key,proof)
            crash("after-checkpoint")
            check(queue.importProof("bookorbit",key)?.contentEquals(proof)==true) { "legacy source changed after checkpoint" }
            check(entryFiles.all { it.isFile && hash(it)==(LuaValue.parse(proof) as Map<*, *>)[it.name] })
            val dest=File(archive,id)
            check(dest.isDirectory || dest.mkdirs())
            for (f in entryFiles) {
                val target=File(dest,f.name)
                if (target.exists()) check(hash(target)==hash(f) && f.delete())
                else check(f.renameTo(target))
                crash("retire-file")
            }
            crash("after-retire")
            queue.retired("bookorbit",key)
            imported++
        }
        // Crash after the atomic retirement but before its marker: the committed proof is enough.
        for (dir in archive.listFiles().orEmpty().filter { it.isDirectory }) {
            val proof=queue.importProof("bookorbit",dir.name)?.let(LuaValue::parse) as? Map<*, *> ?: continue
            if (proof.all { (name,digest) -> name is String && File(dir,name).isFile && hash(File(dir,name))==digest }) queue.retired("bookorbit",dir.name)
        }
        return imported
    }
}

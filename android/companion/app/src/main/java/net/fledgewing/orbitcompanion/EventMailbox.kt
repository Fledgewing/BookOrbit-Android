// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import java.io.File
import java.util.UUID

/** Durable, bounded handoff. Only the companion worker lists or parses the spool. */
class EventMailbox(private val root: File, private val checkpoint: () -> Unit = {}) {
    private val spool get() = File(root, "events")
    private val batch get() = File(root, "events-batch.lua")
    private val names get() = File(root, "events-batch-names.lua")

    fun publish(ack: String?) {
        checkpoint()
        val prior = runCatching { LuaValue.parse(batch.readBytes()) as? Map<*, *> }.getOrNull()
        if (prior != null) {
            if (ack != prior["id"]) return
            val saved = runCatching { LuaValue.parse(names.readBytes()) as? List<*> }.getOrNull() ?: emptyList<Any>()
            for (name in saved.filterIsInstance<String>()) {
                if (name.matches(Regex("[A-Za-z0-9-]+\\.lua"))) File(spool, name).delete()
            }
            batch.delete()
            names.delete()
        }
        val events = ArrayList<Any>()
        val selected = ArrayList<String>()
        var bytes = 0L
        for (f in (spool.listFiles() ?: emptyArray()).sortedBy { it.name }) {
            checkpoint()
            if (!f.name.endsWith(".lua") || !f.isFile || f.canonicalFile.parentFile != spool.canonicalFile) continue
            val n = f.length()
            if (n > 48000) {
                splitLarge(f)
                return publish(null)
            }
            if (events.size >= 8 || bytes + n > 48000) break
            val ev = runCatching { LuaValue.parse(f.readBytes()) as? Map<*, *> }.getOrNull()
            if (ev == null) { f.delete(); continue }
            events.add(ev); selected.add(f.name); bytes += n
        }
        if (events.isEmpty()) return
        root.mkdirs()
        // Names first: a crash cannot publish an unacknowledgeable batch.
        atomic(names, LuaValue.encode(selected))
        atomic(batch, LuaValue.encode(sortedMapOf("id" to UUID.randomUUID().toString(), "events" to events)))
    }
    private fun splitLarge(file: File) {
        val ev = runCatching { LuaValue.parse(file.readBytes()) as? Map<*, *> }.getOrNull()
        val found = ev?.get("found") as? List<*>
        val parts = ArrayList<Map<*, *>>()
        if (found != null) {
            var group = ArrayList<Any?>()
            for (item in found) {
                val candidate = ev.toMutableMap().apply { put("found", group + item) }
                if (group.isNotEmpty() && LuaValue.encode(candidate).size > 48000) {
                    parts.add(ev.toMutableMap().apply { put("found", group) })
                    group = ArrayList()
                }
                group.add(item)
            }
            if (group.isNotEmpty()) parts.add(ev.toMutableMap().apply { put("found", group) })
        }
        // Unexpected oversized records fail explicitly instead of blocking every later answer.
        if (parts.isEmpty() || parts.any { LuaValue.encode(it).size > 48000 }) {
            parts.clear()
            parts.add(mapOf("kind" to ev?.get("kind"), "key" to ev?.get("key"), "err" to "event too large"))
        }
        parts.forEachIndexed { i, part ->
            atomic(File(spool, file.name.removeSuffix(".lua") + "-p$i.lua"), LuaValue.encode(part))
        }
        file.delete()
    }
    private fun atomic(file: File, bytes: ByteArray) {
        val temp = File(file.path + ".tmp")
        temp.writeBytes(bytes)
        check(temp.renameTo(file))
    }
}

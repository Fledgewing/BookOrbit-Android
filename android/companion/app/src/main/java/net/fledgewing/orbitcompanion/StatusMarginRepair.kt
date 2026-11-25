// SPDX-License-Identifier: MIT
package net.fledgewing.orbitcompanion

import java.io.File
import java.security.MessageDigest

/** W31: a single, byte-preserving repair from KOReader's own pre-change backup.
 * Never execute Lua, infer a default, restore horizontal margins, or replace whole settings tables.
 */
object StatusMarginRepair {
    private val queued = java.util.concurrent.atomic.AtomicBoolean()
    @Volatile private var finished = false
    @Volatile private var closedReported = false

    /** Never repair a loaded sidecar: KOReader would later save its stale in-memory values. */
    fun schedule(ctx: android.content.Context, reportedClosed: Boolean = false) {
        if (reportedClosed) closedReported = true
        if (finished || !queued.compareAndSet(false, true)) return
        val app = ctx.applicationContext
        BulkWork.executor.execute {
            try {
                val prefs = Prefs(app)
                finished = run(android.os.Environment.getExternalStorageDirectory(),
                    BulkWork::checkpoint, OLog::i) { closedReported && prefs.koreaderBook == "0" }
            } catch (e: Exception) {
                OLog.w("status repair: deferred", e)
            } finally { queued.set(false) }
        }
    }

    // Book-open checks must not sit behind a paused whole-library job. Only the
    // selected, not-yet-loaded sidecar is touched; a fixed result file avoids the
    // bulk mailbox's reading checkpoint and backlog.
    private val bookExecutor = java.util.concurrent.Executors.newSingleThreadExecutor { task -> BulkWork.thread("orbit-repair", task) }
    fun beforeOpen(path: String, token: String) {
        require(token.matches(Regex("[0-9-]+")))
        bookExecutor.execute {
            var result = "checked"
            try {
                val root = android.os.Environment.getExternalStorageDirectory().canonicalFile
                val book = File(path).canonicalFile
                require(book.path.startsWith(root.path + File.separator))
                val stem = book.name.substringBeforeLast('.', book.name)
                val suffix = book.name.substringAfterLast('.', "_")
                val target = File(book.parentFile, "$stem.sdr/metadata.$suffix.lua")
                require(target.canonicalPath.startsWith(root.path + File.separator) && target.canonicalFile == target.absoluteFile)
                if (target.isFile) run(root, {}, OLog::i, target = target)
                else OLog.i("status repair: book-open check; no adjacent sidecar")
            } catch (e: Exception) { result = "deferred"; OLog.w("status repair: book-open check deferred", e) }
            val dir = Worker.root()
            dir.mkdirs()
            val file = File(dir, "repair-result.lua")
            val tmp = File(file.path + ".tmp")
            tmp.writeBytes(LuaValue.encode(mapOf("token" to token, "result" to result)))
            check(tmp.renameTo(file))
        }
    }

    internal val bookKeys = setOf("copt_t_page_margin", "copt_b_page_margin", "copt_sync_t_b_page_margins")
    // The only global key written by the old status controller (onToggleFooterMode).
    internal val footerKeys = setOf("reader_footer_mode")
    private val longOpen = Regex("\\[(=*)\\[")
    private data class Token(val text: String, val start: Int, val end: Int)
    private data class Entry(val start: Int, val end: Int, val value: String)
    private data class Table(val entries: Map<String, Entry>, val end: Int)

    /** Tokenize without evaluating anything, including comments, escaped and long Lua strings. */
    private fun tokens(s: String): List<Token> {
        val out = ArrayList<Token>()
        var i = 0
        fun longEnd(at: Int): Int? {
            val m = longOpen.matchAt(s, at) ?: return null
            val end = s.indexOf("]${m.groupValues[1]}]", m.range.last + 1)
            require(end >= 0)
            return end + m.groupValues[1].length + 2
        }
        while (i < s.length) {
            val start = i
            when {
                s[i].isWhitespace() -> { i++; continue }
                s.startsWith("--", i) -> { i = longEnd(i + 2) ?: s.indexOf('\n', i).let { if (it < 0) s.length else it }; continue }
                s[i] == '"' || s[i] == '\'' -> {
                    val quote = s[i++]
                    while (i < s.length && s[i] != quote) { if (s[i] == '\\') i++; i++ }
                    require(i < s.length); i++
                }
                s[i] == '[' && longEnd(i) != null -> i = longEnd(i)!!
                s[i].isLetterOrDigit() || s[i] in "_+-." -> {
                    i++; while (i < s.length && (s[i].isLetterOrDigit() || s[i] in "_+-.")) i++
                }
                else -> i++
            }
            out.add(Token(s.substring(start, i), start, i))
        }
        return out
    }

    private fun table(s: String, keys: Set<String>): Table? = runCatching {
        val t = tokens(s)
        require(t.size >= 3 && t[0].text == "return" && t[1].text == "{")
        var depth = 0
        var end = -1
        val entries = linkedMapOf<String, Entry>()
        for (i in 1 until t.size) {
            val tok = t[i]
            if (tok.text == "{") depth++
            if (tok.text == "}") { depth--; if (depth == 0) { require(i == t.lastIndex); end = tok.start } }
            require(depth >= 0)
            if (depth != 1 || tok.text != "[" || i + 4 >= t.size) continue
            val key = t[i+1].text.removeSurrounding("\"").removeSurrounding("'")
            if (key !in keys) continue
            require(t[i+2].text == "]" && t[i+3].text == "=")
            val value = t[i+4]
            require(value.text in setOf("true", "false", "nil") || value.text.toDoubleOrNull()?.isFinite() == true)
            val next = t.getOrNull(i+5)
            require(next?.text in setOf(",", ";", "}"))
            require(key !in entries)
            entries[key] = Entry(tok.start, if (next?.text in setOf(",", ";")) next!!.end else value.end, value.text)
        }
        require(depth == 0 && end >= 0)
        Table(entries, end)
    }.getOrNull()

    /** null = unreadable/nonliteral source; an unchanged string = nothing to restore. */
    internal fun restore(current: String, old: String, keys: Set<String>): String? {
        val now = table(current, keys) ?: return null
        val before = table(old, keys) ?: return null
        val edits = ArrayList<Triple<Int, Int, String>>()
        val additions = StringBuilder()
        for (key in keys) {
            val n = now.entries[key]; val b = before.entries[key]
            if (n?.value == b?.value) continue
            if (n != null) edits.add(Triple(n.start, n.end, b?.let { "[\"$key\"] = ${it.value}," } ?: ""))
            else if (b != null) additions.append("\n[\"$key\"] = ${b.value},\n")
        }
        // KOReader dumps trailing commas. Refuse insertion after an unterminated last field.
        if (additions.isNotEmpty()) {
            val prefix = tokens(current.substring(0, now.end)).last().text
            if (prefix !in setOf("{", ",", ";")) return null
            edits.add(Triple(now.end, now.end, additions.toString()))
        }
        var result = current
        for ((start, end, replacement) in edits.sortedByDescending { it.first }) result = result.replaceRange(start, end, replacement)
        return result
    }

    fun run(root: File, checkpoint: () -> Unit, log: (String) -> Unit, target: File? = null, canApply: () -> Boolean = { true }): Boolean {
        val base = root.canonicalFile
        val done = File(base, "koreader/settings/booksync-w31-repair.done")
        if (target == null && done.exists()) return true
        var deferred = false
        val seen = HashSet<String>()
        fun walk(dir: File) {
            checkpoint()
            if (dir.canonicalFile != dir.absoluteFile || !seen.add(dir.path)) return
            val files = target?.let { arrayOf(it.canonicalFile) } ?: dir.listFiles() ?: error("repair folder unavailable")
            for (file in files) {
                checkpoint()
                if (file.canonicalFile != file.absoluteFile) continue
                if (file.isDirectory) {
                    // Android app-private trees cannot contain KOReader's external sidecars.
                    if (file.name != "Android") walk(file)
                    continue
                }
                if (target != null && file != target.canonicalFile) continue
                val global = file == File(base, "koreader/settings.reader.lua")
                if (!global && !(dir.name.endsWith(".sdr") && file.name.matches(Regex("metadata\\..+\\.lua")))) continue
                val snapshot = File(file.path + ".booksync-w31.old")
                val old = snapshot.takeIf { it.isFile } ?: File(file.path + ".old")
                val marker = File(file.path + ".booksync-w31.done")
                if (marker.exists() && target != null) log("status repair: selected sidecar already checked")
                if (!old.isFile && target != null) log("status repair: selected sidecar has no recovery backup")
                if (marker.exists() || !old.isFile || old.canonicalFile != old.absoluteFile
                    || snapshot.canonicalFile != snapshot.absoluteFile) continue
                // Bounded reads; unsupported files stay untouched and can be recovered manually.
                if (file.length() > 16 * 1024 * 1024 || old.length() > 16 * 1024 * 1024) continue
                val bytes = file.readBytes()
                val text = String(bytes, Charsets.ISO_8859_1)
                val keys = if (global) footerKeys else bookKeys + footerKeys
                val oldBytes = old.readBytes()
                val repaired = restore(text, String(oldBytes, Charsets.ISO_8859_1), keys)
                val id = MessageDigest.getInstance("SHA-256").digest(file.path.toByteArray()).take(6).joinToString("") { "%02x".format(it) }
                if (repaired == null) { log("status repair $id: unsupported settings; left untouched"); continue }
                checkpoint()
                // Preserve the recovery source before a loaded book can rotate .old on
                // close. Capturing a backup does not change any native settings file.
                if (!canApply()) {
                    if (repaired != text && !snapshot.exists()) snapshot.writeBytes(oldBytes)
                    deferred = true
                    continue
                }
                // A native save during the scan invalidates the comparison; retry next startup.
                check(file.readBytes().contentEquals(bytes)) { "settings changed during repair" }
                val backup = File(file.path + ".booksync-before-w31")
                val tmp = File(file.path + ".booksync-w31.tmp")
                if (backup.canonicalFile != backup.absoluteFile || tmp.canonicalFile != tmp.absoluteFile) continue
                // A prior attempt reached the write stage. Different current bytes mean
                // it applied already, or the user saved since: never replay over that save.
                if (backup.exists() && !backup.readBytes().contentEquals(bytes)) {
                    marker.writeText("already applied or subsequently changed\n")
                    log("status repair $id: retained subsequent settings")
                    continue
                }
                if (repaired != text) {
                    if (!backup.exists()) backup.writeBytes(bytes)
                    tmp.writeText(repaired, Charsets.ISO_8859_1)
                    checkpoint()
                    if (!canApply()) {
                        if (!snapshot.exists()) snapshot.writeBytes(oldBytes)
                        tmp.delete()
                        deferred = true
                        continue
                    }
                    check(file.readBytes().contentEquals(bytes)) { "settings changed before replacement" }
                    check(tmp.renameTo(file))
                    val was = table(text, keys)!!.entries
                    val restored = table(repaired, keys)!!.entries
                    val changes = keys.sorted().filter { was[it]?.value != restored[it]?.value }
                        .joinToString(", ") { "$it:${was[it]?.value ?: "unset"}->${restored[it]?.value ?: "unset"}" }
                    log("status repair $id: restored $changes from .old; original saved")
                }
                marker.writeText("checked\n")
            }
        }
        log("status repair: ${if (target == null) "scan" else "book-open check"} started")
        walk(target?.canonicalFile?.parentFile ?: base)
        if (deferred) {
            log("status repair: recovery backups captured; waiting for a closed-book report")
            return false
        }
        if (target == null) {
            done.parentFile?.mkdirs()
            done.writeText("complete\n")
        }
        log("status repair: complete")
        return true
    }
}

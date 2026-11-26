package net.fledgewing.orbitcompanion

import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.io.ByteArrayOutputStream

/**
 * The Orbit cache's values (docs/design/companion-worker.md "Step 2"): what a reply is once the
 * plugin has it, and its files. The model: a Map (string keys, sorted), a List, a byte string
 * (an ISO-8859-1 String: one char per byte, the reply's UTF-8 kept as bytes), a Long, a Double,
 * a Boolean, or null. The plugin's `Cache.encode` writes tables as Lua literals and
 * `Cache.decode` loads them; `encode` and `parse` here are the same format, so either side reads
 * the other's files. Two values are equal when their encodings are (`Cache.revalidate`).
 */
object LuaValue {
    private val L1 = Charsets.ISO_8859_1

    /** A model byte string as text (its bytes read as UTF-8), or a number as Lua's tostring shows it. */
    fun text(v: Any?): String = when (v) {
        is String -> v
        is Long -> v.toString()
        is Double -> if (v == Math.floor(v) && Math.abs(v) < 9.007199254740992E15) v.toLong().toString() else v.toString()
        else -> v.toString()
    }

    /** A Kotlin String as a model byte string. */
    fun str(s: String): String = if (s.all { it.code < 128 }) s else String(s.toByteArray(Charsets.UTF_8), L1)

    /** Small display labels, bounded in UTF-8 bytes without cutting a code point. */
    fun boundedText(text: String, maxBytes: Int): String {
        require(maxBytes >= 0)
        val bytes=text.toByteArray(Charsets.UTF_8)
        var end=minOf(bytes.size,maxBytes)
        while (end>0 && end<bytes.size && (bytes[end].toInt() and 0xc0)==0x80) end--
        return String(bytes,0,end,L1)
    }

    /** A model byte string as a Kotlin String. */
    fun utf8(s: String): String = String(s.toByteArray(L1), Charsets.UTF_8)

    // ------------------------------------------------------------------ JSON

    /** A server reply as the model (rapidjson's nulls dropped from objects, as `Cache.encode` drops them). */
    fun fromJson(text: String): Any? {
        val tokens = JSONTokener(text)
        val value = jsonValue(tokens, 0)
        require(tokens.nextClean() == 0.toChar()) { "trailing JSON" }
        return value
    }

    /** Consume tokens straight into the cache model; never build a second JSONObject tree. */
    private fun jsonValue(t: JSONTokener, depth: Int): Any? {
        require(depth <= 40) { "JSON nesting" }
        return when (val c = t.nextClean()) {
            '{' -> {
                val m = java.util.TreeMap<String, Any?>()
                if (t.nextClean() != '}') {
                    t.back()
                    while (true) {
                        require(t.nextClean() == '"') { "JSON key" }
                        val key = str(t.nextString('"'))
                        require(t.nextClean() == ':') { "JSON colon" }
                        val value = jsonValue(t, depth + 1)
                        if (value != null) m[key] = value else m.remove(key)
                        val end = t.nextClean()
                        if (end == '}') break
                        require(end == ',') { "JSON object" }
                    }
                }
                m
            }
            '[' -> {
                val a = ArrayList<Any?>()
                if (t.nextClean() != ']') {
                    t.back()
                    while (true) {
                        a.add(jsonValue(t, depth + 1))
                        val end = t.nextClean()
                        if (end == ']') break
                        require(end == ',') { "JSON array" }
                    }
                }
                a
            }
            '"' -> str(t.nextString('"'))
            else -> {
                require(c != 0.toChar()) { "JSON value" }
                t.back()
                fromJsonValue(t.nextValue())
            }
        }
    }

    fun fromJsonValue(v: Any?): Any? = when (v) {
        null, JSONObject.NULL -> null
        is JSONObject -> {
            val m = java.util.TreeMap<String, Any?>()
            for (k in v.keys()) {
                val x = fromJsonValue(v.opt(k))
                if (x != null) m[str(k)] = x
            }
            m
        }
        is JSONArray -> (0 until v.length()).map { fromJsonValue(v.opt(it)) }
        is String -> str(v)
        is Boolean -> v
        is Int -> v.toLong()
        is Long -> v
        is Number -> num(v.toDouble())
        else -> str(v.toString())
    }

    private fun num(d: Double): Any = if (d == Math.floor(d) && Math.abs(d) < 9.007199254740992E15) d.toLong() else d

    // ------------------------------------------------------------------ Lua literals

    /** `Cache.encode`: arrays positionally, then keys sorted (numbers before strings). */
    fun encode(v: Any?): ByteArray = ByteArrayOutputStream().also { write(it, v, 0) }.toByteArray()

    private fun raw(o: ByteArrayOutputStream, s: String) {
        if (s.length <= 3) for (c in s) o.write(c.code) else o.write(s.toByteArray(L1))
    }

    /** LuaJIT's string.format("%q") (lj_strfmt.c): a newline as backslash-newline, other control bytes in decimal (3 digits before a digit). */
    private fun quoted(o: ByteArrayOutputStream, s: String) {
        o.write('"'.code)
        for ((i, ch) in s.withIndex()) {
            val c = ch.code and 0xff
            val digitNext = i + 1 < s.length && s[i + 1] in '0'..'9'
            when {
                c == '"'.code -> raw(o, "\\\"")
                c == '\\'.code -> raw(o, "\\\\")
                c == '\n'.code -> raw(o, "\\\n")
                c == 0 -> raw(o, if (digitNext) "\\000" else "\\0")
                c < 32 || c == 127 -> raw(o, "\\" + if (digitNext) String.format(java.util.Locale.ROOT, "%03d", c) else c.toString())
                else -> o.write(c)
            }
        }
        o.write('"'.code)
    }

    /** C's "%.17g", as Cache.encode writes a number that is not a whole one. */
    fun g17(v: Double): String {
        if (v == 0.0) return "0"
        val bd = java.math.BigDecimal(v).round(java.math.MathContext(17, java.math.RoundingMode.HALF_EVEN))
        val exp = bd.precision() - bd.scale() - 1
        if (exp < -4 || exp >= 17) {
            val digits = bd.unscaledValue().abs().toString().trimEnd('0').ifEmpty { "0" }
            val mant = digits.substring(0, 1) + if (digits.length > 1) "." + digits.substring(1) else ""
            return (if (v < 0) "-" else "") + mant + "e" + (if (exp < 0) "-" else "+") + String.format(java.util.Locale.ROOT, "%02d", Math.abs(exp))
        }
        return bd.stripTrailingZeros().toPlainString()
    }

    private fun write(o: ByteArrayOutputStream, v: Any?, depth: Int) {
        when (v) {
            null -> raw(o, "nil")
            is String -> quoted(o, v)
            is Boolean -> raw(o, v.toString())
            is Long -> raw(o, v.toString())
            is Int -> raw(o, v.toString())
            is Double -> raw(o, if (v.isNaN() || v.isInfinite()) "0" else if (v == Math.floor(v) && Math.abs(v) < 9.007199254740992E15) v.toLong().toString() else g17(v))
            is List<*> -> {
                if (depth > 40) return raw(o, "nil")
                raw(o, "{")
                v.forEachIndexed { i, x -> if (i > 0) raw(o, ","); write(o, x, depth + 1) }
                raw(o, "}")
            }
            is Map<*, *> -> {
                if (depth > 40) return raw(o, "nil")
                raw(o, "{")
                val keys = v.keys.filter { v[it] != null }.sortedWith { a, b ->
                    when {
                        a is Number && b is Number -> a.toDouble().compareTo(b.toDouble())
                        a is Number -> -1
                        b is Number -> 1
                        else -> a.toString().compareTo(b.toString())
                    }
                }
                keys.forEachIndexed { i, k ->
                    if (i > 0) raw(o, ",")
                    raw(o, "[")
                    if (k is Number) write(o, k, depth + 1) else quoted(o, k.toString())
                    raw(o, "]=")
                    write(o, v[k], depth + 1)
                }
                raw(o, "}")
            }
            else -> quoted(o, v.toString())
        }
    }

    /** Loads a Lua literal of the cache's kind (what `Cache.encode` writes); null when it isn't one. */
    fun parse(bytes: ByteArray): Any? = try { Parser(bytes).run { val v = value(); ws(); if (i == b.size) v else null } } catch (e: Exception) { null }

    private class Parser(val b: ByteArray) {
        var i = 0
        fun ws() { while (i < b.size && (b[i].toInt() and 0xff) <= 32) i++ }
        fun peek(): Int { ws(); return if (i < b.size) b[i].toInt() and 0xff else -1 }
        fun expect(c: Char) { if (peek() != c.code) error("expected $c at $i"); i++ }

        fun value(): Any? {
            val c = peek()
            return when {
                c == '{'.code -> table()
                c == '"'.code -> string()
                c == '-'.code || (c >= '0'.code && c <= '9'.code) -> number()
                word("nil") -> null
                word("true") -> true
                word("false") -> false
                else -> error("unexpected at $i")
            }
        }

        fun word(w: String): Boolean {
            ws()
            if (i + w.length > b.size) return false
            for (k in w.indices) if ((b[i + k].toInt() and 0xff) != w[k].code) return false
            i += w.length
            return true
        }

        fun number(): Any {
            val start = i
            while (i < b.size && "0123456789+-.eExXabcdefABCDEF".indexOf((b[i].toInt() and 0xff).toChar()) >= 0) i++
            val t = String(b, start, i - start, L1)
            t.toLongOrNull()?.let { return it }
            val d = t.toDouble()
            return if (d == Math.floor(d) && Math.abs(d) < 9.007199254740992E15) d.toLong() else d
        }

        fun string(): String {
            expect('"')
            val o = StringBuilder()
            while (true) {
                val c = b[i++].toInt() and 0xff
                if (c == '"'.code) break
                if (c != '\\'.code) { o.append(c.toChar()); continue }
                val e = b[i++].toInt() and 0xff
                when (e.toChar()) {
                    'n', '\n' -> o.append('\n')
                    'r' -> o.append('\r')
                    't' -> o.append('\t')
                    'a' -> o.append(7.toChar())
                    'b' -> o.append(8.toChar())
                    'f' -> o.append(12.toChar())
                    'v' -> o.append(11.toChar())
                    in '0'..'9' -> {
                        var n = e - '0'.code
                        var k = 0
                        while (k < 2 && i < b.size && (b[i].toInt() and 0xff) in '0'.code..'9'.code) { n = n * 10 + ((b[i].toInt() and 0xff) - '0'.code); i++; k++ }
                        o.append(n.toChar())
                    }
                    else -> o.append(e.toChar())
                }
            }
            return o.toString()
        }

        fun table(): Any {
            expect('{')
            val list = ArrayList<Any?>()
            val map = java.util.TreeMap<String, Any?>()
            var keyed = false
            while (true) {
                if (peek() == '}'.code) { i++; break }
                if (peek() == '['.code) {
                    i++
                    val k = value()
                    expect(']'); expect('=')
                    val v = value()
                    keyed = true
                    if (v != null) map[text(k)] = v
                } else {
                    list.add(value())
                }
                val c = peek()
                if (c == ','.code || c == ';'.code) i++
            }
            if (!keyed) return list
            // A mixed table (positional items and keys): the items under their positions.
            list.forEachIndexed { n, v -> if (v != null) map[(n + 1).toString()] = v }
            return map
        }
    }

}

package net.fledgewing.orbitcompanion

import org.json.JSONArray
import org.json.JSONObject

/**
 * Settings shared by the companion and the Orbit KOReader plugin, one definition for both:
 * shared/settings/schema.json, copied into the APK's assets as settings_schema.json and into the
 * plugin's zip (docs/design/companion-settings.md §4.1). Pure: parsed from text, tested on the JVM.
 */
data class SettingDef(
    val key: String,
    val type: String,
    /** The default as a wire string (bool 1/0, numbers in decimal, rules one per line). */
    val default: String,
    val values: List<Pair<String, String>>,
    val max: Int,
    val section: String,
    val label: String,
    val line: String,
    val readers: List<String>,
    val applies: String,
    val parentKey: String?,
    val parentIs: List<String>?,
    val parentNot: List<String>?,
    val cap: String?,
    val hidden: Boolean,
    val search: List<String>,
) {
    /** Read by the plugin: a change waits for KOReader (§4.5). */
    val pluginReads: Boolean get() = "plugin" in readers

    fun valueLabel(wire: String): String = if (key == "sync_mode" && wire == "custom") "KOReader decides" else values.firstOrNull { it.first == wire }?.second ?: wire
}

data class SettingsSection(val id: String, val title: String)

class SettingsSchema(val sections: List<SettingsSection>, val settings: List<SettingDef>) {
    val byKey: Map<String, SettingDef> = settings.associateBy { it.key }

    fun section(id: String): SettingsSection? = sections.firstOrNull { it.id == id }

    companion object {
        const val ASSET = "settings_schema.json"

        fun parse(text: String): SettingsSchema {
            val o = JSONObject(text)
            val secs = o.optJSONArray("sections") ?: JSONArray()
            val sections = (0 until secs.length()).map { secs.getJSONObject(it) }.map { SettingsSection(it.getString("id"), it.getString("title")) }
            val arr = o.optJSONArray("settings") ?: JSONArray()
            val settings = (0 until arr.length()).map { arr.getJSONObject(it) }.map { d ->
                val type = d.getString("type")
                val values = d.optJSONArray("values")?.let { v -> (0 until v.length()).map { v.getJSONObject(it) }.map {
                    val id = it.get("id").toString()
                    (if (id == "server-home") HomeButton.LIBRARY.key else id) to it.getString("label")
                } }.orEmpty()
                val def = d.opt("default")
                val defWire = when {
                    def == null || def == JSONObject.NULL -> ""
                    def is Boolean -> if (def) "1" else "0"
                    else -> def.toString()
                }
                val parent = d.optJSONObject("parent")
                SettingDef(
                    key = d.getString("key"), type = type, default = defWire, values = values, max = d.optInt("max", 500),
                    section = d.getString("section"), label = d.getString("label"), line = d.optString("line"),
                    readers = strings(d.optJSONArray("reader")), applies = d.optString("applies", "now"),
                    parentKey = parent?.optString("key")?.takeIf { it.isNotEmpty() },
                    parentIs = parent?.optJSONArray("is")?.let { strings(it) },
                    parentNot = parent?.optJSONArray("not")?.let { strings(it) },
                    cap = d.optString("cap").takeIf { it.isNotEmpty() }, hidden = d.optBoolean("hidden", false),
                    search = strings(d.optJSONArray("search")),
                )
            }
            return SettingsSchema(sections, settings)
        }

        private fun strings(a: JSONArray?): List<String> = if (a == null) emptyList() else (0 until a.length()).map { a.get(it).toString() }
    }
}

/** One side's value of a key: the wire string and when it last changed (null: never set on this side). */
data class SettingEntry(val v: String, val at: Long?)

/** A key the merge takes: [same] when only the time moved (the other side's echo). */
data class SettingTaken(val key: String, val v: String, val at: Long, val was: String?, val same: Boolean)

/**
 * The per-key merge (docs/design/companion-settings.md §4.4); the plugin's logic/settings_sync.lua
 * is the same rule, and shared/fixtures/settings/merge.json holds the cases both test.
 */
object SettingsSync {
    const val FUTURE_MS = 86_400_000L

    /** The keys shared with one whole-set settings_at before per-key times. */
    val LEGACY = setOf(
        "wifi_mode", "wifi_idle_min", "home_button", "sleep_mode", "sleep_from", "sleep_leave_out", "sleep_hours",
        "sleep_text", "sleep_battery", "sleep_style", "sleep_text_position", "sleep_battery_corner",
    )

    /** [s] normalised by the schema, or null when the schema refuses it (it is then ignored, never defaulted). */
    fun fromWire(d: SettingDef, s: String?): String? {
        if (s == null) return null
        return when (d.type) {
            "bool" -> when (s) { "1", "true" -> "1"; "0", "false" -> "0"; else -> null }
            "choice" -> s.takeIf { v -> d.values.any { it.first == v } }
            // Pick from, a set, and Leave out: SleepPoolLogic's rules (docs/design/lock-screen.md R1c, X8).
            "source" -> SleepPoolLogic.sources(s).joinToString("\n")
            "rules" -> SleepPoolLogic.rules(s).joinToString("\n")
            "text" -> {
                val t = s.replace(Regex("[\r\n\t]+"), " ").trim()
                val n = t.codePointCount(0, t.length)
                if (n <= d.max) t else t.substring(0, t.offsetByCodePoints(0, d.max))
            }
            else -> null
        }
    }

    /**
     * Takes each remote key that changed later than ours. [remoteWinsTie]: false on the companion
     * (a tie keeps the companion's value), true on the plugin.
     */
    fun merge(schema: SettingsSchema, local: Map<String, SettingEntry>, remote: Map<String, SettingEntry>, nowMs: Long, remoteWinsTie: Boolean): List<SettingTaken> =
        schema.settings.mapNotNull { d ->
            val r = remote[d.key] ?: return@mapNotNull null
            var rat = r.at ?: 0L
            if (rat > nowMs + FUTURE_MS) rat = nowMs
            val v = fromWire(d, r.v) ?: return@mapNotNull null
            if (rat <= 0) return@mapNotNull null
            val l = local[d.key]
            val lat = l?.at
            val same = lat != null && l.v == v
            if (lat == null || rat > lat || (rat == lat && remoteWinsTie && !same)) SettingTaken(d.key, v, rat, l?.v, same) else null
        }

    /** The wire's "values": key -> {v, at}. */
    fun parseValues(text: String?): Map<String, SettingEntry> {
        if (text.isNullOrBlank()) return emptyMap()
        val o = runCatching { JSONObject(text) }.getOrNull() ?: return emptyMap() // "[]" (empty) included
        return parseValues(o)
    }

    fun parseValues(o: JSONObject): Map<String, SettingEntry> = o.keys().asSequence().mapNotNull { k ->
        val e = o.optJSONObject(k) ?: return@mapNotNull null
        val v = e.opt("v")?.takeIf { it != JSONObject.NULL }?.toString() ?: return@mapNotNull null
        k to SettingEntry(v, e.optLong("at", 0L).takeIf { it > 0 })
    }.toMap()

    fun valuesJson(values: Map<String, SettingEntry>): String {
        val o = JSONObject()
        for ((k, e) in values.toSortedMap()) {
            val at = e.at ?: continue
            o.put(k, JSONObject().put("v", e.v).put("at", at))
        }
        return o.toString()
    }

    /** A row shows only while its parent has (is) or hasn't (not) the value, and the parent shows. */
    fun visible(schema: SettingsSchema, key: String, get: (String) -> String, depth: Int = 0): Boolean {
        val d = schema.byKey[key] ?: return false
        val pk = d.parentKey ?: return true
        if (depth > 8 || schema.byKey[pk] == null) return true
        val pv = get(pk)
        if (d.parentIs != null && pv !in d.parentIs) return false
        if (d.parentNot != null && pv in d.parentNot) return false
        return visible(schema, pk, get, depth + 1)
    }

    /** Waiting for KOReader: changed here later than the plugin last reported it. */
    fun pending(d: SettingDef, localAt: Long?, pluginAt: Long?): Boolean =
        d.pluginReads && localAt != null && localAt > 1 && localAt > (pluginAt ?: 0L)
}

package net.fledgewing.orbitcompanion

/**
 * Orbify's modes and the capabilities the companion offers in each (docs/design/addon-mode.md
 * §3, §6). Pure, unit-tested. Full is today's Orbify; Add-on keeps the reader's own launcher and
 * leaves Wi-Fi and sleep alone unless a helper is switched on.
 */
enum class OrbitMode(val key: String) {
    FULL("full"),
    ADDON("addon");

    companion object {
        fun of(key: String?): OrbitMode? = values().firstOrNull { it.key == key }
    }
}

/** Add-on's optional helpers (each off until switched on); Full has them all. */
data class Helpers(
    val wifi: Boolean = false,
    val sleepSync: Boolean = false,
    val screenOff: Boolean = false,
    val clicker: Boolean = false,
    val pin: Boolean = false,
)

object ModeLogic {
    /** Every mode: installs and updates, the setup rows, stats, a restart finished by the companion. */
    val BASE = listOf("install", "setup", "stats", "relaunch")

    /** Before a mode is chosen, the companion behaves as Full (today's Orbify). */
    fun effective(mode: OrbitMode?): OrbitMode = mode ?: OrbitMode.FULL

    /** The caps the plugin sees (/status and the status file), in a stable order. */
    fun caps(mode: OrbitMode?, helpers: Helpers, adminGranted: Boolean): List<String> {
        val out = BASE.toMutableList()
        when (effective(mode)) {
            OrbitMode.FULL -> {
                out += listOf("home", "apps", "wifi", "sleep_sync", "clicker", "pin")
                if (adminGranted) out += "screen_off"
            }
            OrbitMode.ADDON -> {
                if (helpers.wifi) out += "wifi"
                if (helpers.sleepSync) out += "sleep_sync"
                if (helpers.sleepSync && helpers.screenOff && adminGranted) out += "screen_off"
                if (helpers.clicker) out += "clicker"
                if (helpers.pin) out += "pin"
            }
        }
        return out
    }

    /** A JSON string literal. */
    fun str(s: String): String {
        val b = StringBuilder("\"")
        for (c in s) {
            when {
                c == '"' -> b.append("\\\"")
                c == '\\' -> b.append("\\\\")
                c == '\n' -> b.append("\\n")
                c == '\r' -> b.append("\\r")
                c == '\t' -> b.append("\\t")
                c < ' ' -> b.append(String.format("\\u%04x", c.code))
                else -> b.append(c)
            }
        }
        return b.append('"').toString()
    }

    fun caps(list: List<String>): String = list.joinToString(",", "[", "]") { str(it) }

    /** /status's setup_prompt: { key, rows } or null. */
    fun setupPrompt(key: String, rows: String): String =
        if (key.isEmpty()) "null"
        else "{\"key\":${str(key)},\"rows\":${rows.split('\n').filter { it.isNotEmpty() }.joinToString(",", "[", "]") { str(it) }}}"

    /**
     * koreader/settings/orbit-companion.json (§6.2): what the plugin reads when no service
     * answers on loopback. [body] without written_at decides whether a rewrite is needed.
     */
    fun statusFileBody(version: String, mode: OrbitMode?, caps: List<String>, setupKey: String, setupRows: String): String =
        "{\"proto\":${str(Contract.PROTOCOL)},\"version\":${str(version)},\"mode\":${str(effective(mode).key)}," +
            "\"caps\":${caps(caps)},\"setup_prompt\":${setupPrompt(setupKey, setupRows)}"

    fun statusFile(body: String, writtenAt: Long): String = "$body,\"written_at\":$writtenAt}"
}

/**
 * The Orbit plugin's REPORT (§7.3): one yes/no about the BookOrbit login and the recommended
 * settings' state. The companion never learns the server, the account or the key.
 */
object PluginReport {
    /** The extras the companion keeps; anything else in a REPORT is ignored. */
    val KEPT = setOf("signed_in", "recommended", "conflicts")

    fun signedIn(v: String?): String = if (v == "1" || v == "0") v else ""
    fun recommended(v: String?): String = if (v in setOf("none", "partial", "applied", "reviewed")) v!! else ""
    fun conflicts(v: String?): Int = v?.toIntOrNull()?.coerceAtLeast(0) ?: 0

    /** A Setup row's state: done, pending (waiting for KOReader to report), and its detail. */
    data class Row(val done: Boolean, val pending: Boolean, val detail: String)

    fun signedInRow(signedIn: String): Row = when (signedIn) {
        "1" -> Row(true, false, "done")
        "0" -> Row(false, false, "not signed in · tap to open BookOrbit's sign-in in KOReader")
        else -> Row(true, true, "KOReader reports this once the Orbit plugin runs")
    }

    fun recommendedRow(state: String, conflicts: Int): Row = when (state) {
        "applied" -> Row(true, false, "applied · tap to review")
        "reviewed" -> Row(true, false, "reviewed · tap to change")
        "partial" -> Row(false, false, "$conflicts to review · tap to open them in KOReader")
        else -> Row(true, true, "applied by the Orbit plugin at KOReader's next start")
    }
}

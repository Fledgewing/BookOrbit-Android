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
    val BASE = listOf("install", "setup", "stats", "relaunch", "sleep_screen")

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

    /** The first plugin that sends REPORT (and obeys `signin`, `recommended`). */
    const val REPORT_SINCE = "0.11.0"

    /** Both rows while the running plugin can't report yet. */
    const val CHECKING = "Checking… (after KOReader restarts)"

    /**
     * The running plugin ([running], /status?patch_version=) sends REPORT. Unknown counts as
     * able: a REPORT that came decides. Older (v0.11.1: 0.10.1 running after the update): pending.
     */
    fun canReport(running: String?): Boolean {
        val r = running?.let { Version.parse(it) } ?: return true
        return r >= Version.parse(REPORT_SINCE)!!
    }

    private val CHECKING_ROW = Row(true, true, CHECKING)

    /** Pending, never a fix, while the plugin is older than [REPORT_SINCE] or no REPORT came yet. */
    fun signedInRow(signedIn: String, running: String? = null): Row = when {
        !canReport(running) || signedIn.isEmpty() -> CHECKING_ROW
        signedIn == "1" -> Row(true, false, "done")
        else -> Row(false, false, "not signed in · tap to open BookOrbit's sign-in in KOReader")
    }

    fun recommendedRow(state: String, conflicts: Int, running: String? = null): Row = when {
        !canReport(running) || state.isEmpty() -> CHECKING_ROW
        state == "applied" -> Row(true, false, "applied · tap to review")
        state == "reviewed" -> Row(true, false, "reviewed · tap to change")
        state == "partial" -> Row(false, false, "$conflicts to review · tap to open them in KOReader")
        else -> Row(true, true, "applied by the Orbit plugin at KOReader's next start")
    }
}

/**
 * Add-on mode's rules (docs/design/addon-mode.md §4, §7, §8): the first-run choice and the
 * migration of existing installs, which broadcasts need the service, the checklist's required
 * and optional rows, and the switch plans. Pure, unit-tested.
 */
object AddonLogic {
    /**
     * Existing installs never see the choice (§4.1): one that is Home, or has a Full-only step
     * done (device admin, accessibility), is Full. Otherwise the choice shows (null).
     */
    fun migrate(current: OrbitMode?, isHome: Boolean, adminActive: Boolean, accessibilityOn: Boolean): OrbitMode? =
        current ?: if (isHome || adminActive || accessibilityOn) OrbitMode.FULL else null

    /** The service runs in Full, and in Add-on only while a helper needs it (§7.2). */
    fun needsService(mode: OrbitMode?, h: Helpers): Boolean =
        ModeLogic.effective(mode) == OrbitMode.FULL || h.wifi || h.sleepSync || h.clicker || h.pin

    enum class Route { SERVICE, RECORD, DROP }

    /**
     * Where a broadcast from the plugin goes (§7.1). Service actions only with their cap;
     * record actions are kept without the service; in Full every cap is on, so nothing changes.
     */
    fun route(action: String, caps: Collection<String>, service: Boolean): Route {
        fun svc(ok: Boolean) = if (ok) Route.SERVICE else Route.DROP
        return when (action) {
            Contract.NET_UP -> svc("wifi" in caps || "sleep_sync" in caps)
            Contract.NET_DONE -> svc("sleep_sync" in caps)
            Contract.WIFI_OFF -> svc("wifi" in caps)
            Contract.SLEEP_NOW -> svc("screen_off" in caps)
            // RELAUNCH: the service starts KOReader again; without Home, the relaunch activity does (§7.4).
            Contract.RELAUNCH -> svc(service && "home" in caps)
            Contract.SETTINGS, Contract.STATS -> if (service) Route.SERVICE else Route.RECORD
            Contract.SETUP_LATER, Contract.REPORT -> Route.RECORD
            else -> if (service) Route.SERVICE else Route.DROP
        }
    }

    /** Add-on's required rows (§4.3): the only ones counted, walked, notified or prompted. */
    val REQUIRED = listOf("koreader", "plugin", "patch", "signed_in")

    /** Rows that may remind in Add-on: the four required ones, and recommended-settings conflicts (§4.4). */
    val REMINDS = REQUIRED.toSet() + "recommended"

    /** The rows SetupAttention evaluates: in Add-on, every optional row is info only. */
    fun attentionRows(mode: OrbitMode?, rows: List<Pair<String, Boolean>>): List<Pair<String, Boolean>> =
        if (ModeLogic.effective(mode) == OrbitMode.FULL) rows else rows.filter { it.first in REMINDS }

    /** An optional row's state: never allowed, allowed once and now off, or on. */
    enum class OptState { NEVER, OFF, ON }

    /**
     * An optional row: its noun, and what you get with it or lose without it, read from the one
     * table both modes share (Checklist.LOSS, Checklist.ON; companion-checklist §3.3).
     */
    data class Optional(val id: String, val title: String) {
        val without: String get() = Checklist.LOSS.getValue(id)
        val on: String get() = Checklist.ON.getValue(id)
    }

    val OPTIONAL = listOf(
        Optional("install_updates", "Install apps"),
        Optional("notifications", "Notifications"),
        Optional("clicker", "Clicker buttons"),
        Optional("keyboard", "Orbit keyboard"),
        Optional("wifi_switching", "Wi-Fi switching"),
        Optional("sleep_sync", "Sleep sync"),
        Optional("admin", "Screen lock"),
        Optional("battery", "Battery"),
    )

    fun optional(id: String): Optional? = OPTIONAL.firstOrNull { it.id == id }

    /** The optional row's one line (§3.7): "On: …" when on, otherwise "Without it: …". */
    fun optionalLine(o: Optional, st: OptState): String = when (st) {
        OptState.NEVER, OptState.OFF -> "Without it: ${o.without}"
        OptState.ON -> "On: ${o.on}"
    }

    fun optState(granted: Boolean, asked: Boolean): OptState = when {
        granted -> OptState.ON
        asked -> OptState.OFF
        else -> OptState.NEVER
    }

    /**
     * Which optional rows Add-on shows (§4.3): clicker only once a button is mapped or a PIN is
     * set; keyboard only with a Send-key action; the Wi-Fi switching and Sleep sync helpers
     * always; screen off only with Sleep sync; battery only with Sleep sync or Wi-Fi switching.
     */
    fun optionalIds(h: Helpers, clickerMapped: Boolean, pinSet: Boolean, sendKeyMapped: Boolean): List<String> {
        val out = mutableListOf("install_updates", "notifications")
        if (clickerMapped || pinSet) out += "clicker"
        if (sendKeyMapped) out += "keyboard"
        out += listOf("wifi_switching", "sleep_sync")
        if (h.sleepSync) out += "admin"
        if (h.sleepSync || h.wifi) out += "battery"
        return out
    }

    /** One step of a mode switch. */
    enum class Step { REFUSE_NO_HOME, SET_MODE, DISABLE_HOME, ENABLE_HOME, REMOVE_ADMIN, STOP_ACCESSIBILITY, STOP_WIFI_TIMER, STOP_SERVICE, START_SERVICE, WRITE_STATUS, OPEN_SETUP }

    /**
     * Full → Add-on (§8): refused without another Home app; each step only when it still has
     * something to do, so running a finished plan again does nothing.
     */
    fun toAddon(now: OrbitMode?, homeEnabled: Boolean, otherHome: Boolean, keep: Helpers, adminActive: Boolean, accessibilityOn: Boolean, serviceRunning: Boolean): List<Step> {
        if (homeEnabled && !otherHome) return listOf(Step.REFUSE_NO_HOME)
        val out = mutableListOf<Step>()
        if (now != OrbitMode.ADDON) out += Step.SET_MODE
        if (homeEnabled) out += Step.DISABLE_HOME
        if (adminActive && !(keep.sleepSync && keep.screenOff)) out += Step.REMOVE_ADMIN
        if (accessibilityOn && !(keep.clicker || keep.pin)) out += Step.STOP_ACCESSIBILITY
        if (!keep.wifi) out += Step.STOP_WIFI_TIMER
        if (serviceRunning && !needsService(OrbitMode.ADDON, keep)) out += Step.STOP_SERVICE
        if (out.isNotEmpty()) out += Step.WRITE_STATUS
        return out
    }

    /** Add-on → Full (§8): Home again, the service, then Setup walks the new rows. */
    fun toFull(now: OrbitMode?, homeEnabled: Boolean, serviceRunning: Boolean): List<Step> {
        val out = mutableListOf<Step>()
        if (now != OrbitMode.FULL) out += Step.SET_MODE
        if (!homeEnabled) out += Step.ENABLE_HOME
        if (!serviceRunning) out += Step.START_SERVICE
        if (out.isNotEmpty()) out += listOf(Step.WRITE_STATUS, Step.OPEN_SETUP)
        return out
    }

    /** What Full → Add-on changes, for the page before it (§8 step 1). */
    val TO_ADDON_CHANGES = listOf(
        "Home goes back to your reader's own launcher.",
        "Orbit stops switching Wi-Fi and keeping the reader awake for sleep syncs.",
        "The lock-screen permission is released.",
        "The clicker service and the Settings PIN stop, unless you keep them below.",
        "KOReader keeps its reading settings. Orbit undoes only what needed Full mode: KOReader's Wi-Fi action and the two-finger swipe for other apps.",
    )
    val TO_FULL_CHANGES = listOf(
        "Orbit becomes the Home app: Home opens your book or BookOrbit.",
        "Orbit switches Wi-Fi, keeps the reader awake for sleep syncs and runs in the background.",
        "Setup then walks the permissions Full mode needs.",
    )
}

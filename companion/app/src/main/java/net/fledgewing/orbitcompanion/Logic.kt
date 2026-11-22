package net.fledgewing.orbitcompanion

// Pure decisions with no Android imports, unit-tested in app/src/test.

enum class HomeAction { START_KOREADER, SHOW_LAUNCHER }

/**
 * What the HOME activity does. Times are a monotonic clock in ms (SystemClock.elapsedRealtime).
 *
 * - Every Home press starts KOReader with "home", except a second press within [doublePressMs],
 *   which shows the launcher page (and starts a new pair, so a third quick press goes back to
 *   KOReader).
 * - When Home comes back to the front without a press (the app on top closed, crashed or was
 *   killed), KOReader starts again, unless the last start was under [failWindowMs] ago: then
 *   KOReader is not staying up and the launcher page shows, so nobody is locked out.
 */
class HomeDecider(
    private val doublePressMs: Long = 2_000,
    private val failWindowMs: Long = 5_000,
) {
    private var lastPressAt: Long? = null
    private var lastStartAt: Long? = null

    fun onHomePress(now: Long, koreaderInstalled: Boolean, homeOpensKoreader: Boolean): HomeAction {
        val prev = lastPressAt
        lastPressAt = now
        if (!koreaderInstalled || !homeOpensKoreader) return HomeAction.SHOW_LAUNCHER
        if (prev != null && now - prev in 0..doublePressMs) {
            lastPressAt = null
            return HomeAction.SHOW_LAUNCHER
        }
        lastStartAt = now
        return HomeAction.START_KOREADER
    }

    fun onUncovered(now: Long, koreaderInstalled: Boolean, homeOpensKoreader: Boolean): HomeAction {
        if (!koreaderInstalled || !homeOpensKoreader) return HomeAction.SHOW_LAUNCHER
        val last = lastStartAt
        if (last != null && now - last in 0 until failWindowMs) {
            lastStartAt = null
            return HomeAction.SHOW_LAUNCHER
        }
        lastStartAt = now
        return HomeAction.START_KOREADER
    }

    /** startActivity threw: forget the start so the crash window doesn't count it. */
    fun startFailed() {
        lastStartAt = null
    }

    /** KOReader started from the launcher page's button. */
    fun startedByHand(now: Long) {
        lastStartAt = now
    }
}

/** The "Wi-Fi after sleep sync" setting. */
enum class WifiAfterSleep(val key: String) {
    KEEP_ON("keep"),
    OFF_AFTER_30("off30"),
    OFF_NOW("now");

    companion object {
        val DEFAULT = OFF_AFTER_30
        fun fromKey(key: String?): WifiAfterSleep = entries.firstOrNull { it.key == key } ?: DEFAULT
    }
}

sealed class SleepWifiAction {
    object KeepOn : SleepWifiAction()
    object OffNow : SleepWifiAction()

    /** "Sync and sleep": NET_DONE comes before SLEEP_NOW, so the screen is still on. */
    object OffAtNextScreenOff : SleepWifiAction()
    data class OffAt(val deadlineMs: Long) : SleepWifiAction()
}

enum class TimerVerdict { TURN_OFF, SCREEN_ON, ALREADY_OFF, NOT_DUE, NO_TIMER }

object WifiPolicy {
    const val OFF_AFTER_MS = 30 * 60_000L
    const val SCREEN_OFF_GRACE_MS = 30_000L
    const val WAKE_LOCK_CAP_MS = 25_000L

    // An exact alarm can be delivered a little early or late; early by up to this still counts.
    private const val EARLY_SLACK_MS = 5_000L

    fun isSleepReason(reason: String?): Boolean = reason == "sleep" || reason == "sync_and_sleep"

    /**
     * What NET_DONE does with Wi-Fi. null: not a sleep sync, Wi-Fi is left alone.
     * [restoreOff]: Wi-Fi was off before this sleep sync (NET_DONE restore="off") and the user
     * didn't turn it on by hand, so it goes back off like "Off now".
     */
    fun afterSleepSync(mode: WifiAfterSleep, reason: String?, screenOn: Boolean, nowWallMs: Long, restoreOff: Boolean = false): SleepWifiAction? {
        if (!isSleepReason(reason)) return null
        return when (if (restoreOff) WifiAfterSleep.OFF_NOW else mode) {
            WifiAfterSleep.KEEP_ON -> SleepWifiAction.KeepOn
            // Scheduled even with the screen on: the timer checks the screen when it fires.
            WifiAfterSleep.OFF_AFTER_30 -> SleepWifiAction.OffAt(nowWallMs + OFF_AFTER_MS)
            WifiAfterSleep.OFF_NOW -> when {
                !screenOn -> SleepWifiAction.OffNow
                reason == "sync_and_sleep" -> SleepWifiAction.OffAtNextScreenOff
                else -> SleepWifiAction.KeepOn // woken again already: the reader is using it
            }
        }
    }

    /** The Wi-Fi-off timer fired. Wi-Fi goes off only if the screen is still off. */
    fun onTimer(nowWallMs: Long, deadlineMs: Long, screenOn: Boolean, wifiOn: Boolean): TimerVerdict = when {
        deadlineMs <= 0 -> TimerVerdict.NO_TIMER
        nowWallMs < deadlineMs - EARLY_SLACK_MS -> TimerVerdict.NOT_DUE
        !wifiOn -> TimerVerdict.ALREADY_OFF
        screenOn -> TimerVerdict.SCREEN_ON
        else -> TimerVerdict.TURN_OFF
    }

    /** NET_UP's wake_lock_s ("0" = none), hard-capped at 25 s. */
    fun wakeLockMs(raw: String?, enabled: Boolean): Long {
        if (!enabled) return 0
        val s = raw?.trim()?.toDoubleOrNull() ?: return 0
        if (s.isNaN() || s <= 0) return 0
        return minOf((s * 1000).toLong(), WAKE_LOCK_CAP_MS)
    }

    /** Whole minutes left, rounded up, for "Wi-Fi off in N min". */
    fun minutesLeft(nowWallMs: Long, deadlineMs: Long): Long {
        val left = deadlineMs - nowWallMs
        if (left <= 0) return 0
        return (left + 59_999) / 60_000
    }
}

/** At most one event per [intervalMs] (SLEEP_NOW). */
class RateLimiter(private val intervalMs: Long) {
    private var last: Long? = null

    fun tryAcquire(now: Long): Boolean {
        val l = last
        if (l != null && now - l in 0 until intervalMs) return false
        last = now
        return true
    }
}

/** A release version: MAJOR.MINOR.PATCH with an optional pre-release ("v" prefix and "+build" ignored). */
data class Version(val major: Int, val minor: Int, val patch: Int, val pre: String? = null) : Comparable<Version> {
    /** Monotonic Android versionCode, the same formula the release workflow uses. */
    val code: Int get() = major * 10_000 + minor * 100 + patch

    override fun compareTo(other: Version): Int {
        compareValues(major, other.major).let { if (it != 0) return it }
        compareValues(minor, other.minor).let { if (it != 0) return it }
        compareValues(patch, other.patch).let { if (it != 0) return it }
        // A release sorts after any of its pre-releases (semver 11.3).
        if (pre == other.pre) return 0
        if (pre == null) return 1
        if (other.pre == null) return -1
        val a = pre.split('.')
        val b = other.pre.split('.')
        for (i in 0 until minOf(a.size, b.size)) {
            val x = a[i]
            val y = b[i]
            val xn = x.toLongOrNull()
            val yn = y.toLongOrNull()
            val c = when {
                xn != null && yn != null -> compareValues(xn, yn)
                xn != null -> -1 // numeric identifiers sort before alphanumeric ones
                yn != null -> 1
                else -> x.compareTo(y)
            }
            if (c != 0) return c
        }
        return compareValues(a.size, b.size)
    }

    override fun toString(): String = "$major.$minor.$patch" + (pre?.let { "-$it" } ?: "")

    companion object {
        private val RE = Regex("""^[vV]?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$""")

        fun parse(raw: String?): Version? {
            val m = RE.matchEntire(raw?.trim() ?: return null) ?: return null
            val (a, b, c, p) = m.destructured
            return Version(a.toIntOrNull() ?: return null, b.toIntOrNull() ?: return null, c.toIntOrNull() ?: return null, p.ifEmpty { null })
        }
    }
}

/** One GitHub release, reduced to what the updater needs. */
data class ReleaseInfo(val tag: String, val prerelease: Boolean, val draft: Boolean, val assets: Map<String, String>) {
    val version: Version? get() = Version.parse(tag)
}

object UpdatePolicy {
    const val INTERVAL_MS = 24 * 60 * 60_000L
    const val SUMS_NAME = "SHA256SUMS"

    fun apkName(v: Version) = "orbit-companion-$v.apk"

    /** At most one automatic check per 24 h; a clock that went backwards also allows one. */
    fun due(lastCheckMs: Long, nowMs: Long): Boolean = lastCheckMs <= 0 || nowMs < lastCheckMs || nowMs - lastCheckMs >= INTERVAL_MS

    /** The newest usable release: never a draft, a pre-release only when asked for. */
    fun pick(releases: List<ReleaseInfo>, includePre: Boolean): ReleaseInfo? =
        releases.filter { !it.draft && (includePre || !it.prerelease) && it.version != null }
            .maxWithOrNull(compareBy { it.version!! })

    fun isNewer(candidate: Version?, current: Version?): Boolean =
        candidate != null && (current == null || candidate > current)
}

/** `sha256sum` output: "<64 hex>  name" or "<64 hex> *name" per line. Bad lines are skipped. */
object Checksums {
    private val LINE = Regex("""^([0-9a-fA-F]{64}) [ *](.+)$""")

    fun parse(text: String): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        text.lineSequence().forEach { raw ->
            val m = LINE.matchEntire(raw.trimEnd('\r').trim()) ?: return@forEach
            out[m.groupValues[2].trim()] = m.groupValues[1].lowercase()
        }
        return out
    }
}

/** Whether another app can be used: missing, disabled ("frozen", e.g. by a vendor launcher) or fine. */
enum class AppState { MISSING, FROZEN, OK }

object AppStates {
    // PackageManager.COMPONENT_ENABLED_STATE_*
    private const val DISABLED = 2
    private const val DISABLED_USER = 3
    private const val DISABLED_UNTIL_USED = 4

    /**
     * [found]: the package exists (looked up with MATCH_DISABLED_COMPONENTS).
     * [enabledSetting]: getApplicationEnabledSetting. [appInfoEnabled]: ApplicationInfo.enabled.
     * [suspended]: ApplicationInfo.FLAG_SUSPENDED.
     */
    fun of(found: Boolean, enabledSetting: Int, appInfoEnabled: Boolean, suspended: Boolean): AppState = when {
        !found -> AppState.MISSING
        enabledSetting == DISABLED || enabledSetting == DISABLED_USER || enabledSetting == DISABLED_UNTIL_USED -> AppState.FROZEN
        !appInfoEnabled || suspended -> AppState.FROZEN
        else -> AppState.OK
    }

    /**
     * [disabler]: the label of the app that most likely disabled it (the vendor launcher, read at
     * run time), or null. [hint]: where that app re-enables it.
     */
    fun disabledMessage(app: String, disabler: String?, hint: String?): String = when {
        disabler != null && hint != null -> "$app is disabled by $disabler: re-enable it in $disabler › $hint."
        disabler != null -> "$app is disabled by $disabler: re-enable it there."
        else -> "$app is disabled by the system: re-enable it in Settings › Apps."
    }

    /** Short status value, e.g. "Disabled by Meebook Launcher". */
    fun disabledShort(disabler: String?): String = if (disabler != null) "Disabled by $disabler" else "Disabled by the system"
}

/** The shared "Wi-Fi" setting (docs/DESIGN.md "Wi-Fi modes"). The patch decides when; we switch. */
enum class WifiMode(val key: String, val label: String) {
    ALWAYS_ON("always_on", "Always on"),
    OFF_READING("off_reading", "Off while reading"),
    JIT("jit", "Just in time");

    companion object {
        val DEFAULT = JIT
        fun fromKey(key: String?): WifiMode = entries.firstOrNull { it.key == key } ?: DEFAULT
        fun valid(key: String?) = entries.any { it.key == key }
    }
}

/** The shared "Home button" setting. */
enum class HomeButton(val key: String, val label: String) {
    SMART("smart", "Back to my book, then BookOrbit home"),
    BOOKORBIT("bookorbit", "BookOrbit home");

    companion object {
        val DEFAULT = SMART
        fun fromKey(key: String?): HomeButton = entries.firstOrNull { it.key == key } ?: DEFAULT
        fun valid(key: String?) = entries.any { it.key == key }
    }
}

object SharedSettings {
    val IDLE_MINUTES = listOf(1, 2, 5, 10)
    fun validIdle(v: Int?) = v != null && v in IDLE_MINUTES
}

/** Who turned Wi-Fi on. Only automatic (patch or companion) Wi-Fi is turned off automatically. */
enum class WifiOwner(val key: String) {
    NONE("none"), AUTO("auto"), MANUAL("manual");

    companion object {
        fun fromKey(key: String?): WifiOwner = entries.firstOrNull { it.key == key } ?: NONE
    }
}

object WifiOwnership {
    /** How long after our own setWifiEnabled(true) an ENABLED broadcast still counts as ours. */
    const val PENDING_MS = 60_000L

    /** Wi-Fi came on. Ours (with the owner we asked for) if we asked recently, else the user's. */
    fun onEnabled(nowMs: Long, pendingAtMs: Long, pendingOwner: WifiOwner?): WifiOwner =
        if (pendingOwner != null && pendingAtMs > 0 && nowMs - pendingAtMs in 0..PENDING_MS) pendingOwner else WifiOwner.MANUAL

    /** A WIFI_OFF: auto ones never turn off Wi-Fi the user turned on by hand. */
    fun allowOff(auto: Boolean, owner: WifiOwner): Boolean = !auto || owner != WifiOwner.MANUAL
}

/** Home press -> the COMMAND extra for KOReader (docs/INTERFACE.md "go home"). */
object HomeCommands {
    const val HOME = "home"
    const val HOME_SMART = "home_smart"
    const val FROM_OTHER_APP = "other_app"
    /** Save and quit, then the companion starts KOReader again (patch 0.3.1+, docs/INTERFACE.md). */
    const val RESTART = "restart"

    fun forPress(button: HomeButton): String = if (button == HomeButton.SMART) HOME_SMART else HOME

    /** KOReader went away and Home came back: smart mode reopens the book; otherwise a plain start. */
    fun forUncovered(button: HomeButton): String? = if (button == HomeButton.SMART) HOME_SMART else null

    /**
     * FROM extra. We only know for sure Home came from outside KOReader when one of our own pages
     * was in front, or KOReader had gone away (uncovered); otherwise the patch measures its pause.
     */
    fun from(companionPageInFront: Boolean, uncovered: Boolean): String? =
        if (companionPageInFront || uncovered) FROM_OTHER_APP else null
}

/** Setup's Wi-Fi off/on test leaves Wi-Fi as it found it. */
object WifiTestPlan {
    enum class Step { OFF, ON }

    /** Was on: off, then on (times the reconnect). Was off: on (timed), then back off. */
    fun steps(wasOn: Boolean): List<Step> = if (wasOn) listOf(Step.OFF, Step.ON) else listOf(Step.ON, Step.OFF)
}

/** Plain-English network errors for update checks. */
object NetErrors {
    const val BLOCKED = "Internet blocked: is 'Block connections without VPN' on for Tailscale?"
    const val LOCKDOWN_WARNING =
        "Block connections without VPN is on: internet (updates) is blocked. VPN settings › Tailscale ⚙ › turn it off"

    /** always_on_vpn_lockdown: "1" on, "0" off, anything else unknown. */
    fun lockdown(value: String?): Boolean? = when (value?.trim()) {
        "1" -> true
        "0" -> false
        else -> null
    }

    /**
     * [kind]: "permission" (EACCES/EPERM), "connect" (no route, refused, timeout, DNS) or other.
     */
    fun message(kind: String, wifiEnabled: Boolean, wifiConnected: Boolean, vpnUp: Boolean, detail: String): String = when {
        kind == "permission" -> BLOCKED
        kind == "connect" && !wifiEnabled -> "no internet: Wi-Fi is off"
        kind == "connect" && !wifiConnected -> "no internet: Wi-Fi isn't connected"
        kind == "connect" && vpnUp -> BLOCKED
        kind == "connect" -> "no internet: GitHub can't be reached"
        else -> "check failed: $detail"
    }

    /** EACCES/EPERM: what Android returns when lockdown blocks a socket outside the VPN. */
    fun kindOf(e: Throwable): String {
        var t: Throwable? = e
        while (t != null) {
            val m = t.message.orEmpty()
            if (m.contains("EACCES") || m.contains("EPERM") || m.contains("Permission denied", ignoreCase = true) ||
                t is SecurityException
            ) {
                return "permission"
            }
            t = t.cause
        }
        return if (e is java.net.UnknownHostException || e is java.net.ConnectException ||
            e is java.net.SocketTimeoutException || e is java.net.NoRouteToHostException
        ) {
            "connect"
        } else {
            "other"
        }
    }
}

/** The KOReader patch file the companion installs (Setup "KOReader patch installed"). */
/**
 * The Setup row "KOReader patch installed": the file decides "outdated"; the version the
 * running patch reports (broadcasts, /status ping) decides "restart to finish".
 */
enum class PatchRowState { MISSING, OUTDATED, RESTART, CURRENT }

object PatchRow {
    /** The first patch that obeys COMMAND=restart (docs/INTERFACE.md). */
    const val RESTART_COMMAND_SINCE = "0.3.1"

    /** file: PATCH_VERSION in koreader/patches (null: missing or unreadable). running: last reported. */
    fun state(file: String?, running: String?, app: String): PatchRowState {
        if (file == null && running == null) return PatchRowState.MISSING
        val have = file ?: running
        if (PatchFile.needsInstall(have, app)) return PatchRowState.OUTDATED
        val f = file?.let { Version.parse(it) } ?: return PatchRowState.CURRENT
        val r = running?.let { Version.parse(it) } ?: return PatchRowState.CURRENT
        return if (r < f) PatchRowState.RESTART else PatchRowState.CURRENT
    }

    /** The running patch can restart KOReader on the companion's command. */
    fun canRestart(running: String?): Boolean {
        val r = running?.let { Version.parse(it) } ?: return false
        return r >= Version.parse(RESTART_COMMAND_SINCE)!!
    }
}

object PatchFile {
    const val NAME = "2-orbit-android.lua"
    private val VERSION = Regex("""(?m)^local PATCH_VERSION = "([^"]+)"""")

    /** PATCH_VERSION declared in the file's text, or null. */
    fun version(text: String?): String? = text?.let { VERSION.find(it)?.groupValues?.get(1) }

    /** Install or update when missing, unreadable or older than the app's release. */
    fun needsInstall(installed: String?, app: String): Boolean {
        val a = Version.parse(app) ?: return installed == null
        val i = installed?.let { Version.parse(it) } ?: return true
        return i < a
    }
}

/**
 * "Setup needs you": which Setup rows to prompt about (docs/DESIGN.md "Setup needs you").
 * Rows are identified by a stable id (idOf). A prompt shows for rows that aren't done and
 * aren't ignored, unless snoozed with "Later". A snooze lasts until the next app update or
 * until a row regresses (done, then not done again).
 */
object SetupAttention {
    /** Rows that report a test or a sighting, not a setting: never prompted about. */
    val INFO_ONLY = setOf("patch_seen", "wifi_test", "keymapper")

    fun idOf(label: String): String = when {
        label.startsWith("Set Orbit as Home") -> "home"
        label.startsWith("Allow notifications") -> "notifications"
        label.startsWith("Not disabled") -> "disabled"
        label.startsWith("Install updates") -> "install_updates"
        label.startsWith("Battery:") -> "battery:" + label.substringAfter("(", "").substringBefore(")")
        label.startsWith("Tailscale") -> "tailscale"
        label.startsWith("Allow \"lock screen\"") -> "admin"
        label.startsWith("KOReader patch installed") -> "patch"
        label.startsWith("KOReader patch answered") -> "patch_seen"
        label.startsWith("Wi-Fi off/on test") -> "wifi_test"
        label.startsWith("Clicker buttons") -> "clicker"
        label.startsWith("Key Mapper") || label.startsWith("Another key mapper") -> "keymapper"
        else -> label.lowercase().replace(Regex("[^a-z0-9]+"), "_").trim('_')
    }

    data class State(
        val ignored: Set<String> = emptySet(),
        val snoozeCode: Int = 0,
        val snoozeNotDone: Set<String> = emptySet(),
        val lastDone: Set<String> = emptySet(),
    )

    /** needed: rows to fix (not done, not ignored); regressed: of those, done last time; show: prompt now. */
    data class Result(val needed: List<String>, val regressed: Set<String>, val show: Boolean, val next: State, val pending: List<String> = emptyList())

    /** After an in-app fix finishes: close the prompt ("All set") when nothing is left to show. */
    fun allSet(r: Result): Boolean = r.needed.isEmpty() && r.pending.isEmpty()

    /**
     * [pending]: rows that are fine but wait on something outside the app (e.g. "Restart
     * KOReader to finish"): counted as done, never a "needs you", but listed in an open prompt.
     */
    fun evaluate(rows: List<Pair<String, Boolean>>, st: State, versionCode: Int, pending: Set<String> = emptySet()): Result {
        val done = rows.filter { it.second || it.first in pending }.map { it.first }.toSet()
        val needed = rows.filter { it.first !in done && it.first !in INFO_ONLY && it.first !in st.ignored }.map { it.first }
        val waiting = rows.map { it.first }.filter { it in pending && it !in st.ignored }
        val regressed = needed.filter { it in st.lastDone }.toSet()
        // A row fixed since the snooze leaves it; if it breaks again it is new to the snooze.
        val snoozeLeft = st.snoozeNotDone - done
        val snoozed = st.snoozeCode == versionCode && snoozeLeft.containsAll(needed)
        val next = st.copy(snoozeNotDone = snoozeLeft, lastDone = done)
        return Result(needed, regressed, needed.isNotEmpty() && !snoozed, next, waiting)
    }

    /** "Later": quiet until the next update or a regression. */
    fun snooze(st: State, needed: List<String>, versionCode: Int): State =
        st.copy(snoozeCode = versionCode, snoozeNotDone = needed.toSet())

    fun ignore(st: State, id: String): State = st.copy(ignored = st.ignored + id)
    fun unignoreAll(st: State): State = st.copy(ignored = emptySet())
}

/** User-visible changes per version, shown once after an update ("What's new"). */
object WhatsNew {
    val NOTES: List<Pair<String, List<String>>> = listOf(
        "0.2.2" to listOf(
            "Home goes book → BookOrbit home → this launcher → back to your book.",
            "Setup can install the KOReader patch for you.",
            "A setup guide for new readers: docs/SETUP.md.",
        ),
        "0.2.3" to listOf("No more \"Connecting to Wi-Fi\" message when the reader wakes."),
        "0.2.4" to listOf(
            "Setup now tells you when a step needs you (here, in a quiet notification, and in KOReader's Android sync status).",
            "This list: what changed after each update.",
        ),
        "0.3.0" to listOf(
            "Battery: hours left, % per hour in standby and reading, by setting and content, and a daily history (Orbit Companion › Battery).",
            "Export a battery summary and compare readers side by side.",
        ),
        "0.3.1" to listOf(
            "Setup: after installing the KOReader patch, the step updates at once; if KOReader still runs the old patch, a \"Restart KOReader\" button finishes it.",
        ),
        "0.3.2" to listOf(
            "Settings › Home opens: KOReader + BookOrbit, or any reader app (Readest, Moon+ Reader, …). Home brings it back where it was; press Home twice for the launcher page.",
        ),
        "0.4.0" to listOf(
            "Settings › Clicker buttons: map a Bluetooth clicker's buttons (press, hold, double press) to next/previous page, Home, Back, frontlight or Sync and sleep.",
            "In KOReader pages turn exactly; in other apps it taps the page once you switch on Settings › Accessibility › Orbit clicker buttons.",
            "Using Key Mapper for this? Turn it off once Orbit's buttons work; you can then uninstall it.",
        ),
    )

    /** Notes for versions newer than [fromCode] up to [toCode] (Version.code), oldest first. */
    fun since(fromCode: Int, toCode: Int, notes: List<Pair<String, List<String>>> = NOTES): List<Pair<String, List<String>>> =
        notes.filter { (v, _) ->
            val c = Version.parse(v)?.code ?: return@filter false
            c in (fromCode + 1)..toCode
        }
}

/**
 * "Home opens" (docs/DESIGN.md): KOReader + BookOrbit (the default, "") or any launchable app,
 * by package. For another app a Home press just brings it to the front; the KOReader commands
 * (home / home_smart) and the patch's Smart Home steps don't apply.
 */
object HomeApp {
    const val KOREADER_BOOKORBIT = ""
    const val KOREADER_PKG = "org.koreader.launcher"

    fun isKoreader(choice: String?): Boolean = choice.isNullOrEmpty() || choice == KOREADER_PKG

    /** pkg null = KOReader (with command/from); else that app, no extras. */
    data class Launch(val pkg: String?, val command: String?, val from: String?)

    fun launch(choice: String?, press: Boolean, button: HomeButton, companionPageInFront: Boolean): Launch {
        if (!isKoreader(choice)) return Launch(choice, null, null)
        val command = if (press) HomeCommands.forPress(button) else HomeCommands.forUncovered(button)
        val from = if (command == HomeCommands.HOME_SMART) HomeCommands.from(companionPageInFront, !press) else null
        return Launch(null, command, from)
    }

    /** The picker: known reader apps first, then everything else; A–Z within each. KOReader is the default row, not listed. */
    fun order(apps: List<Pair<String, String>>, readers: Set<String>): List<Pair<String, String>> =
        apps.filter { it.first != KOREADER_PKG }.distinctBy { it.first }
            .sortedWith(compareBy<Pair<String, String>>({ it.first !in readers }, { it.second.lowercase() }))
}

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

    /** What NET_DONE does with Wi-Fi. null: not a sleep sync, Wi-Fi is left alone. */
    fun afterSleepSync(mode: WifiAfterSleep, reason: String?, screenOn: Boolean, nowWallMs: Long): SleepWifiAction? {
        if (!isSleepReason(reason)) return null
        return when (mode) {
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

/** Whether another app can be used: missing, disabled ("frozen" by the Meebook launcher) or fine. */
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

    fun frozenMessage(name: String) = "$name is frozen by Meebook: open Meebook › Freeze management and unfreeze $name."
}

package net.fledgewing.orbitcompanion

/**
 * "Nothing interrupts reading" (v0.11.1), pure part. Reading = KOReader in front with a book open
 * in the foreground (not BookOrbit Home or a list over it), as the plugin reports it in STATS.
 * While reading, every notification and every start of a page the user didn't ask for is held
 * and shown at the next moment that isn't reading (a suspend or background, the book closed,
 * BookOrbit Home, a companion page in front), never while the screen is off (nobody sees it).
 * Reading (the runtime) holds the gate.
 */
object ReadingLogic {
    /** A reading STATS counts this long without a new one (STATS come every 5 min with a book open). */
    const val FRESH_MS = BatteryStats.CONTENT_FRESH_MS

    /** A not-reading moment is acted on after this, if it still holds (a suspend comes as the screen goes off). */
    const val SETTLE_MS = 1_500L

    /**
     * Reading or not from a STATS broadcast; null: no change. The plugin 0.11.1+ sends
     * `reading=1|0`; older ones only `open`, so a missing extra is derived: a suspend is not
     * reading, open=1 is, open=0 isn't.
     */
    fun fromStats(reason: String?, open: String?, reading: String?): Boolean? = when {
        reading == "1" -> true
        reading == "0" -> false
        reason == "suspend" -> false
        open == "1" -> true
        open == "0" -> false
        else -> null
    }

    /** [sinceMs]: wall time of the last report that said reading (0: not reading). */
    fun reading(sinceMs: Long, nowMs: Long): Boolean = sinceMs > 0 && nowMs - sinceMs in 0..FRESH_MS

    /** When a held reading state runs out without a new report, or null. */
    fun expiresAt(sinceMs: Long): Long? = if (sinceMs > 0) sinceMs + FRESH_MS + 1 else null

    /** Something may be shown now: nobody is reading and the screen is on. */
    fun mayShow(reading: Boolean, screenOn: Boolean): Boolean = !reading && screenOn
}

/** What waits for a moment that isn't reading: one entry per key (a newer offer replaces it), in offer order. */
class ReadingGate {
    private val held = LinkedHashSet<String>()

    val holding: Set<String> get() = held.toSet()

    /** true: show it now. false: held until [release]. */
    fun offer(key: String, reading: Boolean, screenOn: Boolean): Boolean {
        if (ReadingLogic.mayShow(reading, screenOn)) {
            held.remove(key)
            return true
        }
        held.add(key)
        return false
    }

    /** At a moment that may show: every held key, in order (and the gate is empty). Else none. */
    fun release(reading: Boolean, screenOn: Boolean): List<String> {
        if (!ReadingLogic.mayShow(reading, screenOn) || held.isEmpty()) return emptyList()
        val out = held.toList()
        held.clear()
        return out
    }

    /** No longer wanted (already shown elsewhere, installed, fixed). */
    fun drop(key: String): Boolean = held.remove(key)
}

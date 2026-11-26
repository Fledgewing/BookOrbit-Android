package net.fledgewing.orbitcompanion

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * The sleep screen's decisions (docs/design/lock-screen.md), pure and unit-tested: the settings
 * the Orbit plugin shares (SETTINGS), the rotation rule at sleep (shared/fixtures/sleep/cases.json),
 * the layout of the Bar and the Overlay, and which sink a reader uses. SleepScreen.kt reads the
 * files and the system; SleepCanvas.kt draws.
 */
enum class SleepMode(val key: String, val label: String) {
    OFF("off", "The reader's own"),
    RECOMMENDED("recommended", "Recommended cover"),
    CURRENT("current", "Current book"),
    ;

    companion object {
        fun of(k: String?): SleepMode? = entries.firstOrNull { it.key == k }
    }
}

enum class SleepStyle(val key: String, val label: String) {
    BAR("bar", "Bar"),
    OVERLAY("overlay", "Overlay"),
    ;

    companion object {
        fun of(k: String?): SleepStyle? = entries.firstOrNull { it.key == k }
    }
}

enum class TextPosition(val key: String, val label: String) {
    RIGHT("right", "Right"),
    LEFT("left", "Left"),
    TOP("top", "Top"),
    BOTTOM("bottom", "Bottom"),
    ;

    val vertical: Boolean get() = this == RIGHT || this == LEFT

    companion object {
        fun of(k: String?): TextPosition? = entries.firstOrNull { it.key == k }
    }
}

enum class Corner(val key: String, val label: String, val top: Boolean, val left: Boolean) {
    TOP_LEFT("top_left", "Top left", true, true),
    TOP_RIGHT("top_right", "Top right", true, false),
    BOTTOM_LEFT("bottom_left", "Bottom left", false, true),
    BOTTOM_RIGHT("bottom_right", "Bottom right", false, false),
    ;

    companion object {
        fun of(k: String?): Corner? = entries.firstOrNull { it.key == k }
        fun at(top: Boolean, left: Boolean): Corner = entries.first { it.top == top && it.left == left }
    }
}

/** How the reader shows a sleep image: an Android screen saver (dream), or a picture it picks. */
enum class SleepSink { DREAM, PICTURE }

data class SleepSettings(
    val mode: SleepMode = SleepMode.OFF,
    val from: String = "up_next",
    val leaveOut: List<String> = emptyList(),
    val hours: Int = 6,
    val text: String = "",
    val battery: Boolean = false,
    val style: SleepStyle = SleepStyle.BAR,
    val textPosition: TextPosition = TextPosition.RIGHT,
    val batteryCorner: Corner = Corner.BOTTOM_LEFT,
    /** L10: a black, then white, frame before the cover (clears ghosting); off by default. */
    val flash: Boolean = false,
) {
    companion object {
        val DEFAULT = SleepSettings()
        /** Change cover every: [EVERY_SLEEP] (a random ready cover at each sleep, R4b), else hours. */
        const val EVERY_SLEEP = 0
        val HOURS = listOf(EVERY_SLEEP, 1, 3, 6, 12, 24)

        fun hoursLabel(h: Int): String = if (h == EVERY_SLEEP) "Every sleep" else "$h h"
        const val TEXT_MAX = 60
        val KEYS = listOf(
            "sleep_mode", "sleep_from", "sleep_leave_out", "sleep_hours", "sleep_text", "sleep_battery",
            "sleep_style", "sleep_text_position", "sleep_battery_corner", "sleep_flash",
        )
        /** One line, at most 60 characters (code points). */
        fun cleanText(s: String?): String {
            val t = (s ?: "").replace(Regex("[\r\n\t]+"), " ").trim()
            val n = t.codePointCount(0, t.length)
            return if (n <= TEXT_MAX) t else t.substring(0, t.offsetByCodePoints(0, TEXT_MAX))
        }

        /**
         * The settings with the extras present in [get] applied over [base]: a key that is missing
         * keeps base's value (an older plugin sends none); a bad value is the default.
         */
        fun merge(base: SleepSettings, get: (String) -> String?): SleepSettings {
            var s = base
            get("sleep_mode")?.let { s = s.copy(mode = SleepMode.of(it) ?: DEFAULT.mode) }
            get("sleep_from")?.let { s = s.copy(from = SleepPoolLogic.sources(it).joinToString("\n")) }
            get("sleep_leave_out")?.let { s = s.copy(leaveOut = SleepPoolLogic.rules(it)) }
            get("sleep_hours")?.let { v -> s = s.copy(hours = v.toIntOrNull()?.takeIf { it in HOURS } ?: DEFAULT.hours) }
            get("sleep_text")?.let { s = s.copy(text = cleanText(it)) }
            get("sleep_battery")?.let { s = s.copy(battery = it == "1" || it == "true") }
            get("sleep_style")?.let { s = s.copy(style = SleepStyle.of(it) ?: DEFAULT.style) }
            get("sleep_text_position")?.let { s = s.copy(textPosition = TextPosition.of(it) ?: DEFAULT.textPosition) }
            get("sleep_battery_corner")?.let { s = s.copy(batteryCorner = Corner.of(it) ?: DEFAULT.batteryCorner) }
            get("sleep_flash")?.let { s = s.copy(flash = it == "1" || it == "true") }
            return s
        }
    }

    /** As the plugin stores them (and /status and the status file report them). */
    fun toMap(): Map<String, String> = linkedMapOf(
        "sleep_mode" to mode.key, "sleep_from" to from, "sleep_leave_out" to leaveOut.joinToString("\n"),
        "sleep_hours" to hours.toString(), "sleep_text" to text, "sleep_battery" to if (battery) "1" else "0",
        "sleep_style" to style.key, "sleep_text_position" to textPosition.key, "sleep_battery_corner" to batteryCorner.key,
        "sleep_flash" to if (flash) "1" else "0",
    )

    /** "Up next in series", "List 12", "Library", several joined with ", " (R1c). */
    fun fromLabel(): String = SleepPoolLogic.sources(from).joinToString(", ") { item ->
        when (item) {
            SleepPoolLogic.LIBRARY -> "Library"
            "up_next" -> "Up next in series"
            "want_to_read" -> "Want to read"
            "discover" -> "Discover"
            else -> item.substringBefore(':').let { when (it) { "scope" -> "List"; "library" -> "Library"; else -> "Collection" } } + " " + item.substringAfter(':')
        }
    }
}

/**
 * One wake, two reporters: the service's SCREEN_ON (Full mode, or Add-on with the service) and the
 * plugin's resume after a real sleep (every mode: a manifest receiver can't hear SCREEN_ON). The
 * first moves the picture on; the other, within [SAME_WAKE_MS], is the same wake.
 */
object SleepWake {
    const val SAME_WAKE_MS = 20_000L

    /** [lastMs], [nowMs]: elapsedRealtime of the last wake handled and now (a reboot resets it). */
    fun due(lastMs: Long, nowMs: Long): Boolean = lastMs <= 0L || nowMs < lastMs || nowMs - lastMs >= SAME_WAKE_MS
}

/** The rotation rule at sleep (R4) and the fallbacks (F1, F4). */
object SleepRotation {
    /** With Every sleep a cover is shown this many times, then the plugin retires it (R4b). */
    const val SHOWS_MAX = 3

    /** [shows]: Every sleep's show counts per pool id, kept on disk (a reboot keeps them). */
    data class State(val shown: Long = 0L, val changedAt: Long = 0L, val shows: Map<Long, Int> = emptyMap())

    /** [show]: "pool:<id>", "current", "default" (the drawn Sleeping page) or "off". */
    data class Decision(val show: String, val next: State) {
        val poolId: Long? get() = show.removePrefix("pool:").toLongOrNull()?.takeIf { show.startsWith("pool:") }
    }

    /**
     * What to show. Hours: the next pool cover once X hours have passed (R4). Every sleep
     * ([SleepSettings.EVERY_SLEEP]): with [advance] (a real sleep, or the picture written for the
     * next one) a random ready cover, never the one just shown, preferring covers shown fewer than
     * [SHOWS_MAX] times; when all are used up (nothing new arrived), any of them, so it keeps
     * cycling. Without [advance] (a preview, a redraw for the battery) the current one stays.
     * [rand]: n -> 0 until n.
     */
    fun decide(
        mode: SleepMode, hours: Int, now: Long, pool: List<Long>, hasCurrent: Boolean, st: State,
        advance: Boolean = true, rand: (Int) -> Int = { kotlin.random.Random.nextInt(it) },
    ): Decision {
        if (mode == SleepMode.OFF) return Decision("off", st)
        if (mode == SleepMode.CURRENT && hasCurrent) return Decision("current", st)
        if (pool.isEmpty()) return Decision(if (hasCurrent) "current" else "default", st)
        if (hours == SleepSettings.EVERY_SLEEP) return everySleep(now, pool, st, advance, rand)
        // A clock that went backwards resets the last change to now.
        val changed = if (now < st.changedAt) now else st.changedAt
        val idx = pool.indexOf(st.shown)
        val due = st.shown == 0L || now - changed >= hours * 3_600_000L
        val next = when {
            idx < 0 -> pool[0]
            due -> pool[(idx + 1) % pool.size]
            else -> pool[idx]
        }
        return Decision("pool:$next", st.copy(shown = next, changedAt = if (due) now else changed))
    }

    private fun everySleep(now: Long, pool: List<Long>, st: State, advance: Boolean, rand: (Int) -> Int): Decision {
        if (!advance && st.shown in pool) return Decision("pool:${st.shown}", st)
        val others = if (pool.size > 1) pool.filter { it != st.shown } else pool
        val fresh = others.filter { (st.shows[it] ?: 0) < SHOWS_MAX }
        val from = fresh.ifEmpty { others }
        val pick = from[rand(from.size).coerceIn(0, from.size - 1)]
        if (!advance) return Decision("pool:$pick", st)
        // Counts only for the covers ready now: one that left and comes back later starts again.
        val shows = pool.associateWith { st.shows[it] ?: 0 }.filterValues { it > 0 }.toMutableMap()
        shows[pick] = (shows[pick] ?: 0) + 1
        return Decision("pool:$pick", State(pick, now, shows))
    }

    /** "12:2,40:1" (the stored form) <-> counts. */
    fun encodeShows(m: Map<Long, Int>): String = m.entries.joinToString(",") { "${it.key}:${it.value}" }

    fun decodeShows(s: String?): Map<Long, Int> = (s ?: "").split(',').mapNotNull { p ->
        val id = p.substringBefore(':').toLongOrNull() ?: return@mapNotNull null
        val n = p.substringAfter(':', "").toIntOrNull() ?: return@mapNotNull null
        if (id > 0 && n > 0) id to n else null
    }.toMap()

    /** state.json for the plugin: the cover shown, when, and Every sleep's counts (it retires the used-up). */
    fun stateJson(st: State): String =
        "{\"v\":1,\"shown\":${st.shown},\"changed_at\":${st.changedAt},\"shows\":{" +
            st.shows.entries.joinToString(",") { "\"${it.key}\":${it.value}" } + "}}"
}

/** A rectangle in panel pixels. */
data class Box(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    val width: Int get() = right - left
    val height: Int get() = bottom - top
}

/** The layout (L1-L9): sizes in pixels of the panel the sink draws on, read at run time. */
object SleepLayout {
    /** L3: 7 % of the panel, 10 % with two lines of text. */
    fun bandHeight(h: Int, lines: Int): Int = (h * if (lines >= 2) 0.10 else 0.07).roundToInt()

    /** L3d: the plates' inset, 2 % of the short side (M8C 28 px, Boox 25 px). */
    fun inset(w: Int, h: Int): Int = (min(w, h) * 0.02).roundToInt()

    /** L2: the whole cover, centred, in the area above the band. */
    fun cover(w: Int, h: Int, bandH: Int, imgW: Int, imgH: Int): Box {
        val areaH = h - bandH
        if (imgW <= 0 || imgH <= 0) return Box(0, 0, w, areaH)
        val scale = min(w.toDouble() / imgW, areaH.toDouble() / imgH)
        val cw = (imgW * scale).roundToInt()
        val ch = (imgH * scale).roundToInt()
        val l = (w - cw) / 2
        val t = (areaH - ch) / 2
        return Box(l, t, l + cw, t + ch)
    }

    /** L3b2: the battery moves to the opposite side when the text would share its corner. */
    fun batteryCorner(corner: Corner, position: TextPosition, hasText: Boolean): Corner {
        if (!hasText) return corner
        return when (position) {
            TextPosition.TOP -> if (corner.top) Corner.at(false, corner.left) else corner
            TextPosition.BOTTOM -> if (!corner.top) Corner.at(true, corner.left) else corner
            TextPosition.RIGHT -> if (!corner.left) Corner.at(corner.top, true) else corner
            TextPosition.LEFT -> if (corner.left) Corner.at(corner.top, false) else corner
        }
    }

    /**
     * The text's plate (L3b). [textW]: the longest line's width as drawn; [textH]: all lines' height.
     * Right and Left: rotated, one line, so the plate is textH wide and textW (cut at 90 % of the
     * edge) tall. Top and Bottom: textW wide (≤ 90 % of the panel), centred.
     */
    fun textPlate(w: Int, h: Int, position: TextPosition, textW: Int, textH: Int, pad: Int): Box {
        val inset = inset(w, h)
        return if (position.vertical) {
            val pw = textH + 2 * pad
            val ph = min(textW + 2 * pad, (h * 0.9).roundToInt())
            val t = (h - ph) / 2
            if (position == TextPosition.RIGHT) Box(w - inset - pw, t, w - inset, t + ph) else Box(inset, t, inset + pw, t + ph)
        } else {
            val pw = min(textW + 2 * pad, (w * 0.9).roundToInt())
            val ph = textH + 2 * pad
            val l = (w - pw) / 2
            if (position == TextPosition.TOP) Box(l, inset, l + pw, inset + ph) else Box(l, h - inset - ph, l + pw, h - inset)
        }
    }

    /** The battery's plate in its corner (L3c). */
    fun batteryPlate(w: Int, h: Int, corner: Corner, bw: Int, bh: Int, pad: Int): Box {
        val inset = inset(w, h)
        val pw = bw + 2 * pad
        val ph = bh + 2 * pad
        val l = if (corner.left) inset else w - inset - pw
        val t = if (corner.top) inset else h - inset - ph
        return Box(l, t, l + pw, t + ph)
    }

    /** The longest a line of text may be: Right/Left 90 % of the edge, Top/Bottom and the Bar their width. */
    fun maxTextWidth(w: Int, h: Int, style: SleepStyle, position: TextPosition, pad: Int, batteryW: Int): Int = when {
        style == SleepStyle.BAR -> w - 2 * inset(w, h) - (if (batteryW > 0) batteryW + 2 * pad else 0)
        position.vertical -> (h * 0.9).roundToInt() - 2 * pad
        else -> (w * 0.9).roundToInt() - 2 * pad
    }

    /**
     * Greedy word wrap into at most [maxLines] lines no wider than [maxW]; what doesn't fit is cut
     * with "…" on the last line (L5). A word longer than a line is cut too.
     */
    fun wrap(text: String, maxW: Int, maxLines: Int, measure: (String) -> Float): List<String> {
        val words = text.split(' ').filter { it.isNotEmpty() }
        if (words.isEmpty() || maxLines < 1) return emptyList()
        val lines = mutableListOf<String>()
        var cur = ""
        var i = 0
        while (i < words.size && lines.size < maxLines) {
            val t = if (cur.isEmpty()) words[i] else "$cur ${words[i]}"
            if (cur.isEmpty() || measure(t) <= maxW) {
                cur = t
                i++
            } else {
                lines += cur
                cur = ""
            }
        }
        if (cur.isNotEmpty()) lines += cur
        val last = lines.size - 1
        if (i < words.size || measure(lines[last]) > maxW) lines[last] = cut(lines[last], maxW, measure)
        return lines
    }

    /** [s] shortened until it fits with "…" after it. */
    fun cut(s: String, maxW: Int, measure: (String) -> Float): String {
        var t = s.trimEnd()
        while (t.isNotEmpty() && measure("$t…") > maxW) t = t.dropLast(1).trimEnd()
        return "$t…"
    }

    /** The UI font size (L5): 9 pt at the panel's density, never under 20 px. */
    fun fontPx(dpi: Float): Int = max(20, (dpi * 9f / 72f).roundToInt())
}

object SleepSystem {
    /** The only Settings.Secure keys the companion ever writes (P1; SleepGuardTest). */
    val KEYS = listOf("screensaver_components", "screensaver_enabled", "screensaver_activate_on_sleep")

    /** The vendor's sleep image is a screen saver on most readers; Boox shows a picked picture. */
    fun sink(vendorId: String): SleepSink = if (vendorId == "onyx") SleepSink.PICTURE else SleepSink.DREAM

    /** Ours is the chosen screen saver: the first of the (comma-separated) components. */
    fun oursChosen(components: String?, ours: String): Boolean =
        components?.split(',')?.firstOrNull()?.trim() == ours

    /** The values that choose ours, for [KEYS] in order. */
    fun ourValues(ours: String): List<String> = listOf(ours, "1", "1")

    /** "How it is shown" (S2): one line for the menus. */
    fun shownBy(sink: SleepSink, oursChosen: Boolean, pictureReady: Boolean): String = when (sink) {
        SleepSink.DREAM -> if (oursChosen) "BookSync screen saver ✓" else "Set up ›"
        SleepSink.PICTURE -> if (pictureReady) "Picture: Pictures/Orbit/sleep.png" else "Set up ›"
    }
}

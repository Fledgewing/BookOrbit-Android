package net.fledgewing.orbitcompanion

import kotlin.math.abs

/** Position policy shared with logic/orbismart.lua and the cross-platform recorded cases.
 * Pages/chapters are local locator captures; adapter resets and redates arrive normalized. */
object PositionPolicy {
    const val SKEW_SECONDS = 600
    data class Marker(val at: Long, val place: Double)
    data class Input(val local: Double, val remote: Double? = null, val tolerance: Double = 1.0,
        val remoteAt: Long = 0, val marker: Marker? = null, val turnAt: Long = 0,
        val reset: Boolean = false, val redated: Boolean = false, val finished: Boolean = false,
        val released: Boolean = false, val declinedAt: Long = 0, val overrideAt: Long? = null,
        val percentOnly: Boolean = false)
    data class Decision(val decision: String, val rule: String, val dropped: Boolean = false)
    fun decide(i: Input): Decision {
        val remote = i.remote
        val moved = i.marker != null && remote != null && i.remoteAt != i.marker.at && !i.redated
        val dropped = i.overrideAt != null && moved && i.remoteAt > i.overrideAt
        fun result(decision: String, rule: String) = Decision(decision,rule,dropped)
        fun move(decision: String, rule: String) = if (i.declinedAt != 0L && i.declinedAt == i.remoteAt)
            result("stay","declined") else result(decision,rule)
        if (i.overrideAt != null && !dropped) return result("override","override")
        if (remote == null) return result("push","no-server")
        if (abs(i.local-remote) <= i.tolerance) return result("same","rule1")
        if (i.reset) return move("follow","rule2")
        if (i.finished && i.local < remote) return result(if (i.released) "push" else "hold","rule7")
        if (remote > i.local) return move("take","rule3")
        if (!moved) return result("push","rule4")
        if (i.percentOnly) return result("push","percent")
        if (abs(i.local-(i.marker?.place ?: 0.0)) <= i.tolerance) return move("follow","rule5")
        if (i.remoteAt > i.turnAt + SKEW_SECONDS) return move("follow","rule6")
        return result("push","rule6")
    }
    fun apply(decision: String, moment: String): String = when {
        decision !in setOf("take","follow") -> "no"
        moment == "prerender" -> "now"
        moment == "sleep" -> "wake"
        moment == "close" -> "no"
        else -> "ask"
    }
    fun mayPush(place: Double?, remote: Double?, tolerance: Double = 1.0, exempt: Boolean = false) =
        exempt || remote == null || place == null || place >= remote-tolerance
}

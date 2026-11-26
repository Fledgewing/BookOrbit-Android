package net.fledgewing.orbitcompanion

import java.net.URLDecoder
import java.net.URLEncoder
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Sharp sleep-screen covers (docs/design/lock-screen.md L7, R3), pure and unit-tested
 * (SharpCoversLogicTest). A recommended cover always comes from library's full-size cover
 * (`GET /api/v1/opds/:bookId/cover`, B `opds/opds.controller.ts:229`), scaled once to the panel.
 * That route takes the OPDS cover token (`?t=`, B `opds/opds-auth.guard.ts` isTokenImagePath), which
 * the companion learns once from a small OPDS feed signed in with the reader's OPDS login. Until
 * then, or when OPDS is unavailable, the plugin's 400 x 600 thumbnail is the fallback: a state of
 * the Sharp covers row, never a mode.
 */
object SharpCoversLogic {
    /** The row's states. NONE: never signed in (or signed out); LOST: a 401/403 after sign-in. */
    enum class State(val key: String) {
        NONE("none"), ON("on"), LOST("lost");

        companion object {
            fun of(k: String?): State = entries.firstOrNull { it.key == k } ?: NONE
        }
    }

    /** What one HTTP status means. */
    enum class Outcome { OK, NOT_MODIFIED, AUTH_LOST, OPDS_OFF, NO_COVER, LATER }

    /**
     * 401: the login (or, later, the token: the server's secret changed) isn't accepted. 403:
     * OPDS is off server-wide (OpdsEnabledGuard) or the account lacks OpdsAccess. Anything else
     * that isn't a cover (offline, 5xx) is tried again at the next refresh.
     */
    fun outcome(code: Int): Outcome = when (code) {
        200 -> Outcome.OK
        304 -> Outcome.NOT_MODIFIED
        401 -> Outcome.AUTH_LOST
        403 -> Outcome.OPDS_OFF
        404 -> Outcome.NO_COVER
        else -> Outcome.LATER
    }

    /** The cover's size once fitted inside the panel (never enlarged). */
    fun fit(srcW: Int, srcH: Int, panelW: Int, panelH: Int): Pair<Int, Int> {
        if (srcW <= 0 || srcH <= 0 || panelW <= 0 || panelH <= 0) return 0 to 0
        val k = min(1.0, min(panelW.toDouble() / srcW, panelH.toDouble() / srcH))
        return maxOf(1, (srcW * k).roundToInt()) to maxOf(1, (srcH * k).roundToInt())
    }

    /** The decode sample (a power of two) that keeps the decoded image at least the fitted size. */
    fun sample(srcW: Int, srcH: Int, outW: Int, outH: Int): Int {
        var s = 1
        while (srcW / (s * 2) >= outW && srcH / (s * 2) >= outH) s *= 2
        return s
    }

    /** Bytes the sharp covers may use: 24 MB, or a tenth of Orbit's storage limit when that is smaller (0: no limit). */
    fun maxBytes(storageLimitMb: Int): Long {
        val cap = 24L * 1024 * 1024
        return if (storageLimitMb <= 0) cap else min(cap, storageLimitMb * 1024L * 1024 / 10)
    }

    data class Stored(val id: Long, val bytes: Long, val usedAt: Long)

    /**
     * Which stored covers go: every one no longer in the pool, then the least recently used
     * until the rest fits [maxBytes].
     */
    fun prune(stored: List<Stored>, pool: Set<Long>, maxBytes: Long): List<Long> {
        val gone = stored.filter { it.id !in pool }.map { it.id }.toMutableList()
        val kept = stored.filter { it.id in pool }.sortedBy { it.usedAt }
        var total = kept.sumOf { it.bytes }
        for (s in kept) {
            if (total <= maxBytes) break
            gone += s.id
            total -= s.bytes
        }
        return gone
    }

    // ---------------------------------------------------------------- the words

    const val TITLE = "Sharp covers"
    const val FALLBACK = "until then, covers come from the small thumbnail and look soft"

    /** The Sleep screen page's row: (sub line, right-hand value). */
    fun row(state: State, haveServer: Boolean, sharp: Int, pool: Int, why: String?): Pair<String, String> = when {
        !haveServer -> "Waiting for KOReader's next cover refresh, which tells BookSync the server" to ""
        state == State.ON -> "Full-size covers from library · $sharp of $pool ready" to "On ›"
        state == State.LOST -> "${why ?: "library stopped accepting the sign-in"} · $FALLBACK" to "Sign in again ›"
        else -> "Sign in once with your library OPDS login · $FALLBACK" to "Sign in once ›"
    }

    const val PROMPT = "Your library OPDS login (often the same as your KOReader sync login). " +
        "BookSync uses it once to get a cover link and keeps only that link, never the password."
    const val WRONG = "OPDS username or password not accepted."
    const val OPDS_OFF = "OPDS is off on this server or for this account. Covers come from the small thumbnail until it is on."
    const val NO_TOKEN = "library sent no cover link: none of its recent books has a cover yet. Try again later."
    const val OFFLINE = "library couldn't be reached. Try again when the reader is online."

    /** The words after a sign-in attempt, for [outcome] (null: signed in). */
    fun signInMessage(outcome: Outcome, gotToken: Boolean): String? = when (outcome) {
        Outcome.OK -> if (gotToken) null else NO_TOKEN
        Outcome.AUTH_LOST -> WRONG
        Outcome.OPDS_OFF -> OPDS_OFF
        else -> OFFLINE
    }

    /** Why the sign-in was lost, for the row and Setup. */
    fun lostWhy(outcome: Outcome): String =
        if (outcome == Outcome.OPDS_OFF) "OPDS is off on this server or for this account" else "library stopped accepting the sign-in"
}

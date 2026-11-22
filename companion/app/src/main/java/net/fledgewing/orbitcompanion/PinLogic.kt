package net.fledgewing.orbitcompanion

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

/**
 * Settings PIN (docs/DESIGN.md "Settings PIN"): kid-proof, optional, off by default. Pure and
 * tested: the hash, the wrong-try back-off, the unlock window and the app guard's decision.
 */
object PinHash {
    const val ITERATIONS = 20_000 // ~0.2 s on an e-reader CPU; a 4–8 digit PIN is kid-proofing, not a vault
    private const val PREFIX = "pbkdf2-sha256"

    fun valid(pin: String): Boolean = pin.length in 4..8 && pin.all { it in '0'..'9' }

    /** "pbkdf2-sha256$iterations$salt$hash" (Base64). Only this is stored; never the PIN. */
    fun hash(pin: String, salt: ByteArray = newSalt(), iterations: Int = ITERATIONS): String {
        val enc = Base64.getEncoder()
        return "$PREFIX\$$iterations\$${enc.encodeToString(salt)}\$${enc.encodeToString(derive(pin, salt, iterations))}"
    }

    fun verify(pin: String, stored: String?): Boolean {
        val parts = stored?.split('$') ?: return false
        if (parts.size != 4 || parts[0] != PREFIX) return false
        val iterations = parts[1].toIntOrNull() ?: return false
        val dec = Base64.getDecoder()
        val salt = runCatching { dec.decode(parts[2]) }.getOrNull() ?: return false
        val want = runCatching { dec.decode(parts[3]) }.getOrNull() ?: return false
        return MessageDigest.isEqual(derive(pin, salt, iterations), want)
    }

    private fun newSalt() = ByteArray(16).also { SecureRandom().nextBytes(it) }

    private fun derive(pin: String, salt: ByteArray, iterations: Int): ByteArray {
        val spec = PBEKeySpec(pin.toCharArray(), salt, iterations, 256)
        try {
            return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        } finally {
            spec.clearPassword()
        }
    }
}

/** Wrong tries: after 5, wait 30 s, doubling with each further wrong try up to 5 min. Wall clock ms. */
data class PinBackoff(val failures: Int = 0, val lockedUntil: Long = 0) {
    companion object {
        const val FREE_TRIES = 5
        const val FIRST_WAIT_MS = 30_000L
        const val MAX_WAIT_MS = 300_000L
    }

    fun waitMs(now: Long): Long = maxOf(0L, lockedUntil - now)

    fun fail(now: Long): PinBackoff {
        val n = failures + 1
        if (n < FREE_TRIES) return PinBackoff(n, 0)
        val shift = (n - FREE_TRIES).coerceAtMost(10)
        val wait = minOf(MAX_WAIT_MS, FIRST_WAIT_MS shl shift)
        return PinBackoff(n, now + wait)
    }

    fun success(): PinBackoff = PinBackoff()
}

/** A right PIN unlocks for 5 minutes or until the screen turns off. Monotonic ms. */
class PinSession(private val windowMs: Long = WINDOW_MS) {
    companion object {
        const val WINDOW_MS = 5 * 60_000L
    }

    private var until = 0L

    fun unlock(now: Long) {
        until = now + windowMs
    }

    fun unlocked(now: Long): Boolean = now < until

    fun lock() {
        until = 0L
    }
}

/**
 * The app guard: with a PIN set and the settings locked, a guarded app coming to the front gets
 * the PIN page on top. Never guards the companion, KOReader, phone/emergency or system UI; nor
 * the installer while a companion self-update runs; nor a page a Setup "Fix" just opened.
 */
object Guard {
    enum class Decision { ALLOW, GUARD }

    val NEVER = setOf(
        Koreader.PKG, "com.android.systemui",
        "com.android.dialer", "com.google.android.dialer", "com.android.phone", "com.android.server.telecom",
        "com.android.incallui", "com.android.emergency", "com.google.android.apps.safetyhub",
    )

    /** Allowed while a companion self-update runs (its install and permission screens). */
    val INSTALLERS = setOf(
        "com.android.packageinstaller", "com.google.android.packageinstaller",
        "com.android.permissioncontroller", "com.google.android.permissioncontroller",
    )

    const val FIX_WINDOW_MS = 10 * 60_000L
    const val UPDATE_WINDOW_MS = 10 * 60_000L

    fun canGuard(pkg: String, own: String): Boolean = pkg != own && pkg !in NEVER

    fun decide(
        pkg: String?,
        own: String,
        pinSet: Boolean,
        unlocked: Boolean,
        guarded: Set<String>,
        fixAllowed: Set<String>,
        selfUpdate: Boolean,
    ): Decision = when {
        pkg == null || !pinSet || unlocked -> Decision.ALLOW
        !canGuard(pkg, own) -> Decision.ALLOW
        selfUpdate && pkg in INSTALLERS -> Decision.ALLOW
        pkg in fixAllowed -> Decision.ALLOW
        pkg in guarded -> Decision.GUARD
        else -> Decision.ALLOW
    }
}

/** RESET_PIN (adb only). The receiver needs DUMP, which only the shell holds; on Android 14+
 * a sender uid that Android reports must also be shell (2000) or root (0). */
object PinReset {
    const val SHELL_UID = 2000

    fun allowed(sentFromUid: Int?): Boolean = sentFromUid == null || sentFromUid < 0 || sentFromUid == SHELL_UID || sentFromUid == 0
}

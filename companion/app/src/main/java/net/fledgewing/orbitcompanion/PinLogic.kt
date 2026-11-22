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

/** What came to the front, for ending an unlock (Guard.classify). */
enum class Fg { KOREADER, HOME, APP, OTHER }

/**
 * The live PIN state, one per process, shared by the pages, the accessibility service and
 * /status (no snapshot: set, clear and the guard list change it at once).
 *
 * An unlock holds while the user is inside what it covers: the companion's protected pages,
 * the packages in [scope] (a guarded app, a Setup Fix target, pages opened from a protected
 * page) and any guarded app. Leaving (KOReader, Home, another app, an open companion page)
 * starts a [graceMs] grace (2 min): coming back inside it needs no PIN and stops it; leaving
 * again starts a fresh one; when it runs out, it locks. Screen-off locks at once. The hard cap
 * ([capMs]) applies only while nothing watches the foreground (accessibility service off).
 */
class PinGate(private val graceMs: Long = GRACE_MS, private val capMs: Long = CAP_MS) {
    companion object {
        const val GRACE_MS = 2 * 60_000L
        const val CAP_MS = 15 * 60_000L
    }

    @Volatile
    var pinSet = false
    @Volatile
    var guarded: Set<String> = emptySet()
    /** The accessibility service is running, so leaving other apps is seen. */
    @Volatile
    var watching = false
    private var unlockedAt = -1L
    /** -1 while inside; else when the user left. */
    private var leftAt = -1L
    private val scope = HashSet<String>()
    private var updateUntil = 0L

    @Synchronized
    fun unlocked(now: Long): Boolean {
        if (unlockedAt < 0 || now < unlockedAt) return false
        if (!watching && now - unlockedAt >= capMs) return false
        return leftAt < 0 || now - leftAt < graceMs
    }

    fun locked(now: Long): Boolean = pinSet && !unlocked(now)

    /** Inside since [now]? False when outside (in the grace) or locked. */
    @Synchronized
    fun inside(now: Long): Boolean = unlocked(now) && leftAt < 0

    @Synchronized
    fun unlock(now: Long, scopePkgs: Collection<String> = emptyList()) {
        unlockedAt = now
        leftAt = -1
        scope.clear()
        scope.addAll(scopePkgs)
    }

    /** A page opened from the unlocked flow joins it. False when locked. */
    @Synchronized
    fun addScope(pkg: String, now: Long): Boolean {
        if (!unlocked(now)) return false
        return scope.add(pkg)
    }

    @Synchronized
    fun inScope(pkg: String): Boolean = pkg in scope

    /** Screen-off (and PIN removed): at once. True when it was unlocked. */
    @Synchronized
    fun lock(): Boolean {
        val was = unlockedAt >= 0
        unlockedAt = -1
        leftAt = -1
        scope.clear()
        return was
    }

    /** A protected companion page (or something in scope) is in front: inside again, no grace. */
    @Synchronized
    fun enter(now: Long) {
        if (unlocked(now)) leftAt = -1
    }

    /** The user left what the unlock covers: the grace starts. True when this started it. */
    @Synchronized
    fun leave(now: Long): Boolean {
        if (!unlocked(now) || leftAt >= 0) return false
        leftAt = now
        return true
    }

    /** Something came to the front (the accessibility service). True when the user left. */
    @Synchronized
    fun onForeground(fg: Fg, pkg: String, cls: String?, now: Long): Boolean {
        if (!unlocked(now) || fg == Fg.OTHER) return false
        // Home always leaves, even when the launcher's package hosts a screen in scope (Boox).
        val covered = fg != Fg.HOME && (pkg in scope || Guard.matches(guarded, pkg, cls))
        if (covered) {
            scope.add(pkg)
            leftAt = -1
            return false
        }
        return leave(now)
    }

    @Synchronized
    fun selfUpdateStarted(now: Long, forMs: Long = Guard.UPDATE_WINDOW_MS) {
        updateUntil = now + forMs
    }

    @Synchronized
    fun decide(pkg: String?, cls: String?, own: String, now: Long): Guard.Decision =
        Guard.decide(pkg, cls, own, pinSet, unlocked(now), guarded, now < updateUntil)
}

/**
 * The app guard: with a PIN set and locked, a guarded app (an entry "pkg", or "pkg/activity"
 * for one screen of a package that also hosts the launcher) gets the PIN page on top. Never
 * the companion, KOReader, phone/emergency or system UI; nor the installer during a
 * companion self-update the user started.
 */
object Guard {
    enum class Decision { ALLOW, GUARD }

    const val SETTINGS_PKG = "com.android.settings"
    const val SYSTEM_UI = "com.android.systemui"

    val NEVER = setOf(
        Koreader.PKG, SYSTEM_UI,
        "com.android.dialer", "com.google.android.dialer", "com.android.phone", "com.android.server.telecom",
        "com.android.incallui", "com.android.emergency", "com.google.android.apps.safetyhub",
    )

    /** Allowed while a companion self-update runs (its install and permission screens). */
    val INSTALLERS = setOf(
        "com.android.packageinstaller", "com.google.android.packageinstaller",
        "com.android.permissioncontroller", "com.google.android.permissioncontroller",
    )

    const val UPDATE_WINDOW_MS = 10 * 60_000L

    fun canGuard(pkg: String, own: String): Boolean = pkg != own && pkg !in NEVER

    fun component(pkg: String, cls: String) = "$pkg/$cls"

    fun matches(guarded: Set<String>, pkg: String, cls: String?): Boolean =
        pkg in guarded || (cls != null && component(pkg, cls) in guarded)

    /**
     * The guard entry for a Settings screen [cls] in [pkg]: the whole package for AOSP Settings
     * or a vendor settings app; only that screen when the package also has the Home role or is
     * system UI (a Boox resolves Settings to com.onyx, which also hosts its launcher).
     */
    fun settingsEntry(pkg: String, cls: String, homePkgs: Set<String>): String =
        if (pkg == SETTINGS_PKG || (pkg !in homePkgs && pkg != SYSTEM_UI)) pkg else component(pkg, cls)

    /** What [pkg]/[cls] in front means for an unlock; null: our own (the pages decide). */
    fun classify(
        pkg: String,
        cls: String?,
        own: String,
        homeComponents: Set<String>,
        homePkgs: Set<String>,
        ime: Set<String>,
        launchable: Boolean,
        guarded: Set<String>,
    ): Fg? = when {
        pkg == own -> null
        pkg == Koreader.PKG -> Fg.KOREADER
        cls != null && component(pkg, cls) in homeComponents -> Fg.HOME
        pkg == SYSTEM_UI || pkg in ime -> Fg.OTHER
        matches(guarded, pkg, cls) -> Fg.APP
        pkg in homePkgs -> Fg.OTHER // the launcher package's other windows (overlays, transitions)
        launchable -> Fg.APP
        else -> Fg.OTHER
    }

    fun decide(
        pkg: String?,
        cls: String?,
        own: String,
        pinSet: Boolean,
        unlocked: Boolean,
        guarded: Set<String>,
        selfUpdate: Boolean,
    ): Decision = when {
        pkg == null || !pinSet || unlocked -> Decision.ALLOW
        !canGuard(pkg, own) -> Decision.ALLOW
        selfUpdate && pkg in INSTALLERS -> Decision.ALLOW
        matches(guarded, pkg, cls) -> Decision.GUARD
        else -> Decision.ALLOW
    }
}

/** RESET_PIN (adb only). The receiver needs DUMP, which only the shell holds; on Android 14+
 * a sender uid that Android reports must also be shell (2000) or root (0). */
object PinReset {
    const val SHELL_UID = 2000

    fun allowed(sentFromUid: Int?): Boolean = sentFromUid == null || sentFromUid < 0 || sentFromUid == SHELL_UID || sentFromUid == 0
}

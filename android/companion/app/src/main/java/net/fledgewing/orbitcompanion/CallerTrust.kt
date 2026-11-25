package net.fledgewing.orbitcompanion

import android.content.Context
import android.content.pm.PackageManager

/**
 * Who may call the companion (docs/design/security.md "The caller check"): only KOReader, and
 * only the copy whose signing certificate was pinned the first time it was seen (trust on first
 * use). That copy may come from GitHub, F-Droid or a self-built KOReader. Another signer is
 * refused until the user trusts it once on the Setup page. Pure; [KoreaderTrust] is the Android side.
 */
object CallerTrust {
    /** The KOReader packages that run the Orbit plugin. */
    val KOREADER_PKGS = listOf(Koreader.PKG, KoreaderRelease.FDROID_PKG)

    /** The trusted KOReader: its package and its signing certificates (SHA-256, AA:BB:… form). */
    data class Pin(val pkg: String, val signers: Set<String>) {
        fun encode(): String = pkg + "|" + signers.sorted().joinToString(",")

        companion object {
            fun decode(s: String?): Pin? {
                val pkg = s?.substringBefore('|', "")?.takeIf { it.isNotEmpty() } ?: return null
                val signers = s.substringAfter('|').split(',').filter { it.isNotEmpty() }.toSet()
                return if (signers.isEmpty()) null else Pin(pkg, signers)
            }
        }
    }

    enum class Verdict {
        /** The pinned KOReader. */
        ACCEPT,
        /** KOReader, nothing pinned yet: pin it and accept. */
        PIN,
        /** KOReader with another signer (or the other KOReader package): refused; Setup asks. */
        CHANGED,
        /** Not KOReader, or its certificate can't be read. */
        REFUSE,
    }

    data class Decision(val verdict: Verdict, val pin: Pin? = null) {
        val accepted get() = verdict == Verdict.ACCEPT || verdict == Verdict.PIN
    }

    /**
     * [callerPkgs]: the packages of the calling UID. [signersOf]: a package's certificates (empty:
     * not installed or unreadable). A certificate rotation keeps the old one in the history, so the
     * pinned set only has to be contained in the current one.
     */
    fun decide(pinned: Pin?, callerPkgs: List<String>, signersOf: (String) -> Set<String>): Decision {
        val pkg = pinned?.pkg?.takeIf { it in callerPkgs } ?: KOREADER_PKGS.firstOrNull { it in callerPkgs } ?: return Decision(Verdict.REFUSE)
        val signers = signersOf(pkg)
        if (signers.isEmpty()) return Decision(Verdict.REFUSE)
        val now = Pin(pkg, signers)
        return when {
            pinned == null -> Decision(Verdict.PIN, now)
            pinned.pkg == pkg && signers.containsAll(pinned.signers) -> Decision(Verdict.ACCEPT, now)
            else -> Decision(Verdict.CHANGED, now)
        }
    }
}

/** [CallerTrust] on the device: the pin, the copy waiting for the user's trust, the Setup row. */
object KoreaderTrust {
    const val ROW_ID = "koreader_trust"
    private const val PIN = "pin"
    private const val CHANGED = "changed"

    private fun sp(ctx: Context) = ctx.applicationContext.getSharedPreferences("caller_trust", Context.MODE_PRIVATE)

    fun pin(ctx: Context): CallerTrust.Pin? = CallerTrust.Pin.decode(sp(ctx).getString(PIN, null))

    /** A package's certificates (empty: not installed or unreadable); tests replace it. */
    @Volatile
    internal var signersOf: (PackageManager, String) -> Set<String> = { pm, pkg ->
        try { Updater.signers(pm, null, pkg) } catch (e: Exception) { emptySet() }
    }

    /** The caller check for one call from [uid]; pins on first use, records a changed copy. */
    fun check(ctx: Context, uid: Int): Boolean {
        val pm = ctx.packageManager
        val pkgs = pm.getPackagesForUid(uid)?.toList() ?: emptyList()
        return apply(ctx, CallerTrust.decide(pin(ctx), pkgs) { signersOf(pm, it) }, "call from ${pkgs.joinToString().ifEmpty { "uid $uid" }}")
    }

    /**
     * Before the companion puts a command on KOReader's start: false only when the installed
     * KOReader is known to be another copy than the pinned one (it then starts with no command).
     * Nothing pinned yet: it is pinned now.
     */
    fun koreaderTrusted(ctx: Context, pkg: String = Koreader.PKG): Boolean {
        val pm = ctx.packageManager
        val d = CallerTrust.decide(pin(ctx), listOf(pkg)) { signersOf(pm, it) }
        if (d.verdict == CallerTrust.Verdict.REFUSE) return true // not installed: the start fails anyway
        return apply(ctx, d, "command to $pkg")
    }

    private fun apply(ctx: Context, d: CallerTrust.Decision, what: String): Boolean {
        val p = sp(ctx)
        when (d.verdict) {
            CallerTrust.Verdict.PIN -> {
                p.edit().putString(PIN, d.pin!!.encode()).commit()
                OLog.i("trust: KOReader ${d.pin.pkg} pinned on first use (${d.pin.signers.joinToString()})")
            }
            CallerTrust.Verdict.ACCEPT -> if (p.getString(CHANGED, null) != null) p.edit().remove(CHANGED).apply()
            CallerTrust.Verdict.CHANGED -> {
                val enc = d.pin!!.encode()
                if (p.getString(CHANGED, null) != enc) {
                    p.edit().putString(CHANGED, enc).commit()
                    OLog.w("trust: KOReader changed (${d.pin.pkg}, ${d.pin.signers.joinToString()}); refused until trusted in Setup ($what)")
                    android.os.Handler(android.os.Looper.getMainLooper()).post { runCatching { Attention.evaluate(ctx.applicationContext, "KOReader changed") } }
                }
            }
            CallerTrust.Verdict.REFUSE -> OLog.w("trust: refused $what")
        }
        return d.accepted
    }

    /** The refused copy, while it is still the one installed: Setup shows "KOReader changed". */
    fun changed(ctx: Context): CallerTrust.Pin? {
        val c = CallerTrust.Pin.decode(sp(ctx).getString(CHANGED, null)) ?: return null
        val now = signersOf(ctx.packageManager, c.pkg)
        return if (now.isNotEmpty() && now.containsAll(c.signers)) c else null
    }

    /** The user trusts the changed copy: it becomes the pinned one. */
    fun trustChanged(ctx: Context) {
        val c = changed(ctx) ?: return
        sp(ctx).edit().putString(PIN, c.encode()).remove(CHANGED).commit()
        OLog.i("trust: the user trusted KOReader ${c.pkg} (${c.signers.joinToString()})")
    }
}

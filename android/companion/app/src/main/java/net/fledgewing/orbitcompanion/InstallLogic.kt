package net.fledgewing.orbitcompanion

import java.security.MessageDigest

/**
 * Setup installs the rest (android/docs/DESIGN.md "Setup installs the rest"): KOReader and the
 * library plugin from their official GitHub sources, never re-hosted. Pure decisions here;
 * the downloads and installs are in Installers.kt.
 */
object KoreaderRelease {
    const val MANUAL_URL = "https://github.com/koreader/koreader/releases/latest"
    fun manualInstall(addon: Boolean, canInstall: Boolean, state: State): Boolean =
        addon && !canInstall && state != State.OTHER_SIGNER

    const val API = "https://api.github.com/repos/koreader/koreader/releases/latest"
    /** F-Droid's build: a separate app; KOReader skips user patches on that flavor
     * (frontend/userpatch.lua:27-28 at v2026.07.1: `android.prop.flavor == "fdroid"`). */
    const val FDROID_PKG = "org.koreader.launcher.fdroid"
    /** SHA-256 of the certificate that signs koreader/koreader's release APKs (apksigner, v2026.07.1). */
    const val OFFICIAL_CERT = "FD:49:2A:4F:E0:01:F1:70:58:B8:26:DA:43:58:A1:DC:EA:C3:8D:26:68:6F:34:25:22:C5:A4:97:BC:D4:DC:CC"

    /** The release asset name part for each Android ABI (koreader-android-<arch>-<tag>.apk). */
    private fun arch(abi: String): String? = when (abi) {
        "arm64-v8a" -> "arm64"
        "armeabi-v7a", "armeabi" -> "arm"
        "x86", "x86_64" -> "x86"
        else -> null
    }

    /** The APK for the first supported ABI (Build.SUPPORTED_ABIS order), or null. */
    fun assetFor(abis: List<String>, names: Collection<String>): String? {
        for (abi in abis) {
            val a = arch(abi) ?: continue
            names.firstOrNull { Regex("^koreader-android-$a-v[0-9][^/]*\\.apk$").matches(it) }?.let { return it }
        }
        return null
    }

    /** GitHub's asset digest ("sha256:<hex>") as lowercase hex, or null when not published. */
    fun digest(d: String?): String? =
        d?.trim()?.lowercase()?.removePrefix("sha256:")?.takeIf { Regex("^[0-9a-f]{64}$").matches(it) }

    /** KOReader's versionName / tag ("v2026.07.1", "v2026.07") as numbers. */
    private fun parts(v: String?): List<Int>? {
        val m = Regex("""^v?(\d+(?:\.\d+)*)""").find(v?.trim() ?: return null) ?: return null
        return m.groupValues[1].split('.').map { it.toInt() }
    }

    /** [latest] is newer than [installed] (null installed: nothing to compare, so false). */
    fun newer(latest: String?, installed: String?): Boolean {
        // KOReader also has two-part calendar versions; preserve that format while comparing
        // full semver suffixes whenever both sides have three components.
        val lv = Version.parse(latest)
        val iv = Version.parse(installed)
        if (lv != null && iv != null) return lv > iv
        val l = parts(latest) ?: return false
        val i = parts(installed) ?: return false
        for (k in 0 until maxOf(l.size, i.size)) {
            val c = compareValues(l.getOrElse(k) { 0 }, i.getOrElse(k) { 0 })
            if (c != 0) return c > 0
        }
        return false
    }

    enum class State { MISSING, OFFICIAL, OTHER_SIGNER, FDROID_ONLY }

    /** [signers]: the installed org.koreader.launcher's certificates (null: not installed). */
    fun state(signers: Set<String>?, fdroidInstalled: Boolean): State = when {
        signers == null -> if (fdroidInstalled) State.FDROID_ONLY else State.MISSING
        OFFICIAL_CERT in signers -> State.OFFICIAL
        else -> State.OTHER_SIGNER
    }

    fun explain(s: State): String = when (s) {
        State.MISSING -> "not installed · tap to install the official KOReader from GitHub"
        State.OFFICIAL -> "official build"
        State.FDROID_ONLY -> "F-Droid's KOReader is a separate app that skips user patches, so the patch and BookSync can't work with it. Tap to install the official KOReader next to it; your books stay where they are."
        State.OTHER_SIGNER -> "this KOReader is signed by someone else, so Android can't update it with the official one. Uninstall it first (your books and koreader/ folder stay), then tap here."
    }
}

/**
 * Up-front detections for Setup (item: Play Protect, vendor freeze, Family Link/managed),
 * in plain words. Pure: the caller reads the device.
 */
object DeviceChecks {
    const val FAMILY_LINK = "com.google.android.apps.kids.familylinkhelper"
    const val PLAY_STORE = "com.android.vending"

    /** UserManager restrictions that block what Setup does (installs, Home, accessibility). */
    val BLOCKING = mapOf(
        "no_install_apps" to "installing apps",
        "no_install_unknown_sources" to "installing apps from outside the Play Store",
        "no_install_unknown_sources_globally" to "installing apps from outside the Play Store",
        "no_config_default_apps" to "changing the Home app",
        "no_uninstall_apps" to "uninstalling apps",
    )

    /** What blocks Setup on a supervised or managed device, or null when nothing does. */
    fun managed(familyLink: Boolean, restrictions: Set<String>, otherAdmins: List<String>): String? {
        val blocked = restrictions.mapNotNull { BLOCKING[it] }.distinct()
        if (!familyLink && blocked.isEmpty() && otherAdmins.isEmpty()) return null
        val who = if (familyLink) "Family Link supervises this device" else "This device is managed (${otherAdmins.joinToString().ifEmpty { "a work or school profile" }})"
        val what = if (blocked.isEmpty()) "it may block the Home app, accessibility or installs" else "it blocks ${blocked.joinToString()}"
        val ask = if (familyLink) "approve it in the parent's Family Link app" else "ask whoever manages it to allow it"
        return "$who: $what. When a step won't stick, $ask."
    }

    fun playProtect(): String =
        "Play Protect checks apps installed outside the Play Store and may warn about BookSync, KOReader or their updates. Tap \"More details\", then \"Install anyway\". The Settings PIN never covers it during an install."
}

/**
 * Setup's advisories (v0.5.3): Family Link / managed, Play Protect and the launcher's app freeze
 * are tips, not steps. They never count towards "steps need you", the notification, the Home
 * prompt, Fix next or setup_needed, and "Got it" hides one for good (Prefs.hiddenTips).
 */
object SetupTips {
    val IDS = setOf("managed", "play_protect", "freeze_tip")

    fun isTip(id: String) = id in IDS

    /** Rows to show: hidden tips left out. */
    fun visible(ids: List<String>, hidden: Set<String>): List<String> = ids.filter { !isTip(it) || it !in hidden }

    /** The steps (tips left out) for Setup's done/total count. */
    fun steps(rows: List<Pair<String, Boolean>>): List<Pair<String, Boolean>> = rows.filter { !isTip(it.first) }

    /** Setup is complete when every step is done; tips and info rows don't count. */
    fun complete(rows: List<Pair<String, Boolean>>): Boolean =
        rows.all { (id, done) -> done || isTip(id) || id in SetupAttention.INFO_ONLY }

    fun hide(hidden: Set<String>, id: String): Set<String> = if (isTip(id)) hidden + id else hidden
}

/** Setup's "Fix next": the pending rows in order, each tried once per walk. */
object SetupWalk {
    /**
     * [rows]: (id, done) in Setup order. The next one to fix, or null when the walk is over.
     * [pending] rows wait for KOReader to report (e.g. the plugin's REPORT): never a step.
     */
    fun next(rows: List<Pair<String, Boolean>>, tried: Set<String>, pending: Set<String> = emptySet()): String? =
        rows.firstOrNull { (id, done) -> !done && id !in SetupAttention.INFO_ONLY && id !in tried && id !in pending }?.first
}

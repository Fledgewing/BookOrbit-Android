package net.fledgewing.orbitcompanion

/**
 * Reading fonts (docs/design/reading-fonts.md): Bitter and Literata, an Optional Setup row, off
 * until the user turns it on. The device downloads each file from a pinned upstream URL (a commit
 * SHA, never a branch) and keeps it only when its SHA-256 matches the one below. Nothing is
 * bundled in the APK. Each family's OFL.txt goes into the fonts folder with the fonts, as the SIL
 * Open Font License asks of anyone who redistributes them. Pure, unit-tested (FontsLogicTest);
 * FontInstaller does the I/O.
 */
object ReadingFonts {
    /** One file: its name in koreader/fonts, where it comes from, and what it must hash to. */
    data class File(val name: String, val url: String, val sha256: String, val bytes: Long)

    const val ID = "reading_fonts"
    const val LABEL = "Reading fonts: Bitter, Literata"

    /** Staged downloads: never *.ttf while incomplete, so KOReader never lists a half file. */
    const val PART = ".orbit-part"

/**
     * Bitter v2.002 (solmatas/BitterPro at the last commit with static TTFs, 75fe4ad; later
     * commits ship only the variable font) and Literata 3.103 (googlefonts/literata, tag 3.103,
     * the default 12 pt text size). Static Regular, Italic, Bold, Bold Italic: KOReader handles
     * variable fonts only from v2026.07, with open issues (docs/design/reading-fonts.md §2).
     * Hashes and sizes taken from the pinned files on 2026-11-23.
     */
    val FILES: List<File> = listOf(
        File("Bitter-Regular.ttf", "https://raw.githubusercontent.com/solmatas/BitterPro/75fe4ad90b9e6138a4938090d909cbf1bb1e9d03/fonts/ttf/Bitter-Regular.ttf", "e8b0073077f2b60bcb97a0e71c5d31ed2b9207e2b2a194c08895a649cc00f6fd", 173268),
        File("Bitter-Italic.ttf", "https://raw.githubusercontent.com/solmatas/BitterPro/75fe4ad90b9e6138a4938090d909cbf1bb1e9d03/fonts/ttf/Bitter-Italic.ttf", "b05ec44b2218e80a0b658a81883ba3c118d4829380ccc3aa171d665c88d018db", 171724),
        File("Bitter-Bold.ttf", "https://raw.githubusercontent.com/solmatas/BitterPro/75fe4ad90b9e6138a4938090d909cbf1bb1e9d03/fonts/ttf/Bitter-Bold.ttf", "8e3885f813fa767ac8b75beb63e88e6f30996eeab8ba4927eff9eda9e63d4f93", 172696),
        File("Bitter-BoldItalic.ttf", "https://raw.githubusercontent.com/solmatas/BitterPro/75fe4ad90b9e6138a4938090d909cbf1bb1e9d03/fonts/ttf/Bitter-BoldItalic.ttf", "25572f279851c2487298bdf02cd72603c5838b7f0f9ea3de3725d7ac975f9286", 171180),
        File("Bitter-OFL.txt", "https://raw.githubusercontent.com/solmatas/BitterPro/75fe4ad90b9e6138a4938090d909cbf1bb1e9d03/OFL.txt", "b49fc895c04ec3e9cd31077f2539979da8065e2747037b1bb9c6548787050db4", 4423),
        File("Literata-Regular.ttf", "https://raw.githubusercontent.com/googlefonts/literata/0c2761b727a1b3a7cffd313c37f0f5163dfc7a63/fonts/ttf/Literata-Regular.ttf", "0390890de9bb9d5862a6ba4125b82c61792ccc3d66b63e73eee75c1a16fcd208", 319964),
        File("Literata-Italic.ttf", "https://raw.githubusercontent.com/googlefonts/literata/0c2761b727a1b3a7cffd313c37f0f5163dfc7a63/fonts/ttf/Literata-Italic.ttf", "198f70cc9a17bab578553fa274b81984d58c440efe26bc06f1d841c194b6691a", 304104),
        File("Literata-Bold.ttf", "https://raw.githubusercontent.com/googlefonts/literata/0c2761b727a1b3a7cffd313c37f0f5163dfc7a63/fonts/ttf/Literata-Bold.ttf", "b6af95b3b443cdbce964aa06741596987f2f5c3ede46a2bc846e5addd99d061f", 331304),
        File("Literata-BoldItalic.ttf", "https://raw.githubusercontent.com/googlefonts/literata/0c2761b727a1b3a7cffd313c37f0f5163dfc7a63/fonts/ttf/Literata-BoldItalic.ttf", "1dade59381ad02f4679d7e993a7a406472e587ac332af7a6168d3ad9214a99dc", 318888),
        File("Literata-OFL.txt", "https://raw.githubusercontent.com/googlefonts/literata/0c2761b727a1b3a7cffd313c37f0f5163dfc7a63/OFL.txt", "8742963604cd89dc81437811a850018fc03b2bfad686d7422c8235967c87614e", 4389),
    )

    private val HEX64 = Regex("^[0-9a-f]{64}$")
    private val PINNED = Regex("^https://raw\\.githubusercontent\\.com/[^/]+/[^/]+/[0-9a-f]{40}/.+")
    private val NAME = Regex("^[A-Za-z0-9._-]+\\.(ttf|txt)$")

    /**
     * What is wrong with a manifest (empty: nothing): every URL pinned to a commit on
     * raw.githubusercontent.com over https, every SHA-256 64 lowercase hex digits, plain unique
     * file names (no paths), sizes above zero, and an OFL.txt for each family.
     */
    fun problems(files: List<File> = FILES): List<String> {
        val out = mutableListOf<String>()
        files.forEach { f ->
            if (!PINNED.matches(f.url)) out += "${f.name}: url isn't pinned to a commit: ${f.url}"
            if (!HEX64.matches(f.sha256)) out += "${f.name}: sha256 isn't 64 lowercase hex digits"
            if (!NAME.matches(f.name)) out += "${f.name}: not a plain .ttf or .txt file name"
            if (f.bytes <= 0) out += "${f.name}: no size"
        }
        files.groupBy { it.name }.filter { it.value.size > 1 }.keys.forEach { out += "$it: listed twice" }
        val families = files.filter { it.name.endsWith(".ttf") }.map { it.name.substringBefore('-') }.toSet()
        families.forEach { fam -> if (files.none { it.name == "$fam-OFL.txt" }) out += "$fam: no $fam-OFL.txt beside its fonts" }
        return out
    }

    /** A download is kept only when its SHA-256 is the manifest's (case and spaces ignored). */
    fun verified(f: File, sha256: String?): Boolean = sha256 != null && sha256.trim().lowercase() == f.sha256

    /**
     * What to change in the fonts folder. [wanted]: the row is on. [present]: each manifest file
     * name on disk with its SHA-256 (null when it can't be read). [stray]: other names there that
     * end in [PART] (left by an interrupted download).
     */
    data class Plan(val download: List<File>, val delete: List<String>) {
        val nothing get() = download.isEmpty() && delete.isEmpty()
    }

    /**
     * On: download every file missing or not matching its SHA-256; off: delete only the files that
     * are ours (their SHA-256 matches), never a font the user put there under the same name.
     * Interrupted downloads go either way. Running a finished plan again does nothing.
     */
    fun plan(wanted: Boolean, present: Map<String, String?>, stray: List<String> = emptyList(), files: List<File> = FILES): Plan {
        val parts = stray.filter { it.endsWith(PART) }
        return if (wanted) {
            Plan(files.filter { !verified(it, present[it.name]) }, parts)
        } else {
            Plan(emptyList(), files.filter { it.name in present && verified(it, present[it.name]) }.map { it.name } + parts)
        }
    }

    /** The row is done when every file is there at its size (cheap; the install checks hashes). */
    fun installed(sizes: Map<String, Long>, files: List<File> = FILES): Boolean = files.all { sizes[it.name] == it.bytes }

    /** KOReader reads its font list once per start (frontend/fontlist.lua getFontList). */
    enum class Restart { NONE, WAIT, NOW }

    /**
     * The restart after an install: none unless one is pending; at once when the user taps
     * Restart KOReader ([manual]); otherwise only when the screen goes off, never while someone
     * may be reading (the reading gate), and never on top of the Orbit plugin's own restart.
     */
    fun restart(pending: Boolean, manual: Boolean, screenOff: Boolean, patchRestarting: Boolean): Restart = when {
        !pending -> Restart.NONE
        patchRestarting -> Restart.NONE
        manual || screenOff -> Restart.NOW
        else -> Restart.WAIT
    }

    /** The row's verb. */
    fun verb(wanted: Boolean, busy: Boolean, installed: Boolean, restartPending: Boolean): String? = when {
        busy -> null
        !wanted -> "Turn on"
        !installed -> "Retry"
        restartPending -> "Restart KOReader"
        else -> "Turn off"
    }

    /** The line under the row while something is going on, or null. */
    fun extra(wanted: Boolean, busy: Boolean, installed: Boolean, restartPending: Boolean, status: String): String? = when {
        busy -> if (wanted) "Downloading…" else "Removing…"
        wanted && !installed && status.isNotEmpty() -> "Not installed: $status"
        wanted && installed && restartPending -> "Installed; KOReader shows them after it restarts, when the screen next goes off."
        else -> null
    }
}

package net.fledgewing.orbitcompanion

/**
 * The Setup checklist (docs/design/companion-checklist.md): a summary first, what needs the user
 * lifted out and expanded, everything else folded into one line per group, and a loss line on
 * every row that isn't done. Pure, unit-tested (ChecklistLogicTest); Setup builds the [Row]s from
 * the device, ChecklistUi draws the [Page].
 */
object Checklist {
    /** The five states (§3.4): each has its own glyph and words, never grey alone. */
    enum class State { DONE, NEEDS_YOU, SET_BY_READER, OFF, CHECKING }

    /** The groups (§3.2), in page order. */
    enum class Group(val title: String) {
        APPS("Apps"), BOOKORBIT("BookOrbit"), PERMISSIONS("Permissions"), CONNECTION("Connection"), OPTIONAL("Optional"),
    }

    /** Which group a row id sits in; a row marked optional always sits in Optional. */
    val GROUP_OF: Map<String, Group> = mapOf(
        "disabled" to Group.APPS,
        "koreader" to Group.APPS,
        "koreader_trust" to Group.APPS,
        "plugin" to Group.APPS,
        "patch" to Group.APPS,
        "signed_in" to Group.BOOKORBIT,
        "recommended" to Group.BOOKORBIT,
        "sharp_covers" to Group.BOOKORBIT,
        "home" to Group.PERMISSIONS,
        "install_updates" to Group.PERMISSIONS,
        "notifications" to Group.PERMISSIONS,
        "battery" to Group.PERMISSIONS,
        "admin" to Group.PERMISSIONS,
        "clicker" to Group.PERMISSIONS,
        "keyboard" to Group.PERMISSIONS,
        "tailscale" to Group.CONNECTION,
        "wifi_test" to Group.CONNECTION,
        "wifi_switching" to Group.OPTIONAL,
        "sleep_sync" to Group.OPTIONAL,
        "screen_saver" to Group.OPTIONAL,
        "reading_fonts" to Group.OPTIONAL,
        "screen_mode" to Group.OPTIONAL,
    )

    /** Needs you order (§3.1): what blocks the most first (a frozen app, installs, sign-in), then group order. */
    val NEED_ORDER = listOf(
        "disabled", "install_updates", "koreader", "koreader_trust", "plugin", "patch", "signed_in", "recommended", "sharp_covers",
        "home", "notifications", "battery", "admin", "clicker", "keyboard", "tailscale", "wifi_test",
    )

    /**
     * What doesn't work without each row (§3.3, user ruling 2026-11-23): one table for both modes,
     * shown as "Until then: …" on a required row not done yet, and "Without it: …" on an
     * optional or skipped row. Every id Setup can show has a line (ChecklistLogicTest's guard).
     */
    val LOSS: Map<String, String> = mapOf(
        "disabled" to "it can't start, sync or update.",
        "koreader" to "nothing to read with.",
        "koreader_trust" to "BookSync ignores KOReader: no sync help, no covers saved, no updates through BookSync.",
        "plugin" to "no library, no sync.",
        "patch" to "new fixes don't reach KOReader.",
        "signed_in" to "nothing syncs.",
        "sharp_covers" to "sleep-screen covers come from the small thumbnail and look soft.",
        "recommended" to "KOReader keeps settings that work against syncing. Nothing changes until you choose.",
        "home" to "Home doesn't open your book.",
        "install_updates" to "BookSync can't install KOReader or update itself; updates are a download link.",
        "notifications" to "you see updates and steps only in KOReader and when you open BookSync.",
        "battery" to "sleep syncs and Wi-Fi switching can be late: Android may pause the app while the screen is off.",
        "admin" to "Sync and sleep asks you to press the power button.",
        "clicker" to "clicker buttons work only inside KOReader, and the Settings PIN locks only BookSync's settings.",
        "keyboard" to "Send-key clicker actions work only inside KOReader.",
        "tailscale" to "no sync with your server away from home Wi-Fi.",
        "wifi_test" to "nothing breaks; the test only times how fast the reader reconnects.",
        "wifi_switching" to "BookSync leaves Wi-Fi as it is, so a sync waits until you turn Wi-Fi on.",
        "sleep_sync" to "the reader can fall asleep before a sync finishes; it finishes when you next wake it.",
        "screen_saver" to "what the reader shows while it sleeps doesn't follow your Sleep screen setting until you run one USB command.",
        "reading_fonts" to "KOReader offers only its own fonts and the reader's; Bitter and Literata aren't among them.",
        "screen_mode" to "the sleep screen may show ghosting from the last page.",
    )

    /** "On: …" on an optional row that is on. */
    val ON: Map<String, String> = mapOf(
        "install_updates" to "BookSync installs KOReader and its own updates.",
        "notifications" to "BookSync tells you about updates and setup steps.",
        "clicker" to "clicker buttons work in every app.",
        "keyboard" to "Send-key actions work in every app.",
        "admin" to "Sync and sleep turns the screen off.",
        "battery" to "sleep syncs and Wi-Fi switching run on time.",
        "wifi_switching" to "BookSync turns Wi-Fi on for a sync and off again.",
        "sleep_sync" to "syncs finish as the reader sleeps.",
        "reading_fonts" to "Bitter and Literata are in KOReader's font menu.",
        "screen_mode" to "BookSync draws in the reader's clearest screen mode.",
    )

    /**
     * One row as Setup reads it. [ids]: the stored ids it stands for (SetupAttention): a merged row
     * (Battery) keeps one per app so skips and snoozes still apply per app; for Battery, only the
     * apps not done. [short]: its words in the group's one line when done. [info]: shown, never
     * counted (a test, Add-on's status lines). [verb]: the one button, null for none.
     */
    data class Row(
        val id: String,
        val label: String,
        val done: Boolean,
        val stateLine: String = "",
        val short: String = label,
        val pending: Boolean = false,
        val optional: Boolean = false,
        val info: Boolean = false,
        val setByReader: Boolean = false,
        val pinFree: Boolean = false,
        val verb: String? = null,
        val ids: List<String> = listOf(id),
        /** A line of its own under the state (the Clicker row's "Key Mapper is also on"). */
        val extra: String? = null,
    )

    data class Item(
        val row: Row,
        val state: State,
        val group: Group,
        /** A step the user skipped ("Don't ask about this"): Off in its group until Allow. */
        val skipped: Boolean,
        /** Worked before and stopped: the state line starts "Stopped working". */
        val regressed: Boolean,
        /** "New in 0.12" (NewIn), or null. */
        val newIn: String?,
    ) {
        val id get() = row.id
        /** "Until then: …" / "Without it: …", or null when there is nothing to lose. */
        val loss: String? get() = lossLine(row.id, state)
        /** Waiting on something outside the app, with a button to finish it (Restart KOReader). */
        val ready: Boolean get() = state == State.CHECKING && row.verb != null
    }

    fun groupOf(r: Row): Group = if (r.optional) Group.OPTIONAL else GROUP_OF[r.id] ?: Group.PERMISSIONS

    fun skipped(r: Row, ignored: Set<String>): Boolean = !r.optional && r.ids.isNotEmpty() && r.ids.all { it in ignored }

    fun state(r: Row, ignored: Set<String>): State = when {
        r.pending -> State.CHECKING
        r.done && r.setByReader -> State.SET_BY_READER
        r.done -> State.DONE
        r.optional || r.info || skipped(r, ignored) -> State.OFF
        else -> State.NEEDS_YOU
    }

    fun lossLine(id: String, state: State): String? {
        val loss = LOSS[id] ?: return null
        return when (state) {
            State.NEEDS_YOU -> "Until then: $loss"
            State.OFF -> "Without it: $loss"
            else -> null
        }
    }

    /** An optional row's line: "On: …" when on, otherwise "Without it: …" (§3.7). */
    fun optionalLine(id: String, on: Boolean): String? =
        if (on) ON[id]?.let { "On: $it" } else LOSS[id]?.let { "Without it: $it" }

    /** Every row with its state, group and tags. [lastDone]: rows done at the last evaluation. */
    fun items(
        rows: List<Row>,
        ignored: Set<String> = emptySet(),
        lastDone: Set<String> = emptySet(),
        newIn: (Row) -> String? = { null },
    ): List<Item> = rows.map { r ->
        val st = state(r, ignored)
        Item(
            r, st, groupOf(r),
            skipped = st == State.OFF && skipped(r, ignored),
            regressed = st == State.NEEDS_YOU && r.ids.any { it in lastDone },
            newIn = newIn(r),
        )
    }

    /** Needs you, in order (§3.1). */
    fun needsYou(items: List<Item>): List<Item> {
        val needs = items.filter { it.state == State.NEEDS_YOU }
        return needs.sortedWith(compareBy({ NEED_ORDER.indexOf(it.id).let { i -> if (i < 0) NEED_ORDER.size + it.group.ordinal else i } }))
    }

    /** "2 things need you" counts these and nothing else. */
    fun count(items: List<Item>): Int = items.count { it.state == State.NEEDS_YOU }

    sealed class Summary {
        data class AllSet(val optionalBelow: Boolean) : Summary()
        data class NeedsYou(val n: Int) : Summary()
        /** The Settings PIN is set and locked (§3.9). */
        data class NeedsGrownUp(val n: Int) : Summary()
        object Checking : Summary()
        data class FirstRun(val steps: Int) : Summary()
        data class Walking(val step: Int, val of: Int, val label: String) : Summary()
    }

    /**
     * The summary card (§3.1). [firstRun]: the mode was just chosen and Start not tapped yet;
     * [walk]: Fix next is running (step, of, the step's label); [locked]: the Settings PIN is
     * set and locked.
     */
    fun summary(items: List<Item>, firstRun: Boolean = false, walk: Triple<Int, Int, String>? = null, locked: Boolean = false): Summary {
        val n = count(items)
        return when {
            walk != null && !locked -> Summary.Walking(walk.first, walk.second, walk.third)
            n > 0 && locked -> Summary.NeedsGrownUp(n)
            n > 0 && firstRun -> Summary.FirstRun(n)
            n > 0 -> Summary.NeedsYou(n)
            items.any { it.state == State.CHECKING && !it.ready } -> Summary.Checking
            else -> Summary.AllSet(optionalBelow = items.any { it.state == State.OFF })
        }
    }

    private fun things(n: Int, verb: String) = "$n thing${if (n == 1) "" else "s"} ${if (n == 1) verb + "s" else verb}"

    fun summaryTitle(s: Summary): String = when (s) {
        is Summary.AllSet -> "All set"
        is Summary.NeedsYou -> "${things(s.n, "need")} you"
        is Summary.NeedsGrownUp -> "${things(s.n, "need")} a grown-up"
        Summary.Checking -> "Checking…"
        is Summary.FirstRun -> "Let's set up this reader"
        is Summary.Walking -> "Step ${s.step} of ${s.of}: ${s.label}"
    }

    fun summaryLine(s: Summary): String = when (s) {
        is Summary.AllSet -> if (s.optionalBelow) "Everything this reader needs is done. Optional items below." else "Everything this reader needs is done."
        is Summary.NeedsYou -> "Goes through each one and comes back here."
        is Summary.NeedsGrownUp -> "Asks for the Settings PIN."
        Summary.Checking -> "Waiting for KOReader to report. Open KOReader once."
        is Summary.FirstRun -> "${s.steps} step${if (s.steps == 1) "" else "s"}. Each opens a page, and Back returns here."
        is Summary.Walking -> "Do this step, then press Back to come here for the next one."
    }

    /** The summary's full-width button, or null. */
    fun summaryButton(s: Summary): String? = when (s) {
        is Summary.NeedsYou -> "Fix next"
        is Summary.NeedsGrownUp -> "Unlock to fix"
        is Summary.FirstRun -> "Start"
        is Summary.Walking -> "Stop"
        else -> null
    }

    fun summaryState(s: Summary): State = when (s) {
        is Summary.AllSet -> State.DONE
        Summary.Checking -> State.CHECKING
        else -> State.NEEDS_YOU
    }

    /** The status page's summary row (§3.8): "Setup: all set ✓" or "Setup: 2 things need you ›". */
    fun statusTitle(s: Summary): String = when (s) {
        is Summary.AllSet -> "Setup: all set ✓"
        is Summary.NeedsYou -> "Setup: ${things(s.n, "need")} you ›"
        is Summary.NeedsGrownUp -> "Setup: ${things(s.n, "need")} a grown-up ›"
        is Summary.FirstRun -> "Setup: let's set up this reader ›"
        is Summary.Walking -> "Setup: step ${s.step} of ${s.of} ›"
        Summary.Checking -> "Setup: checking… ›"
    }

    /** Its second line: what needs the user, by name, or the summary's line. */
    fun statusLine(s: Summary, items: List<Item>): String {
        val names = needsYou(items).map { it.row.label }.distinct()
        return if (names.isNotEmpty() && s !is Summary.AllSet) "${names.joinToString(", ")} · tap to fix" else summaryLine(s)
    }

    /** Whether a row shows its verb (§3.9): locked, only PIN-free update follow-through does. */
    fun verbShown(i: Item, locked: Boolean): Boolean = i.row.verb != null && (!locked || i.row.pinFree)

    /** A group's one line (§3.2) and its glyph state. */
    data class GroupView(val group: Group, val state: State, val line: String, val items: List<Item>, val newTag: Boolean)

    fun groups(items: List<Item>): List<GroupView> = Group.values().mapNotNull { g ->
        val inG = items.filter { it.group == g }
        if (inG.isEmpty()) null else GroupView(g, groupState(g, inG), groupLine(g, inG), inG, inG.any { it.newIn != null })
    }

    fun groupState(g: Group, items: List<Item>): State = when {
        items.any { it.state == State.NEEDS_YOU } -> State.NEEDS_YOU
        items.any { it.state == State.CHECKING } -> State.CHECKING
        g == Group.OPTIONAL && items.any { it.state == State.OFF } -> State.OFF
        else -> State.DONE
    }

    private fun isDone(i: Item) = i.state == State.DONE || i.state == State.SET_BY_READER

    fun groupLine(g: Group, items: List<Item>): String {
        val needs = items.count { it.state == State.NEEDS_YOU }
        val parts = mutableListOf<String>()
        if (needs > 0) parts += "$needs need${if (needs == 1) "s" else ""} you"
        when (g) {
            Group.PERMISSIONS -> {
                val done = items.count(::isDone)
                parts += if (done == items.size) "$done of ${items.size} allowed" else "$done of ${items.size}"
                items.filter { it.skipped }.forEach { parts += "${it.row.label} skipped" }
                items.filter { it.state == State.CHECKING }.forEach { parts += "${it.row.label} checking" }
                if (items.any { it.state == State.SET_BY_READER }) parts += "set by the reader: ${items.filter { it.state == State.SET_BY_READER }.joinToString { it.row.label }}"
            }
            Group.OPTIONAL -> {
                val on = items.count(::isDone)
                parts += if (items.size == 1) "${items[0].row.label}: ${if (on == 1) "on" else "off"}" else "$on of ${items.size} on"
            }
            else -> {
                val words = items.mapNotNull { i ->
                    when {
                        isDone(i) -> i.row.short
                        i.state == State.CHECKING -> "${i.row.label}: checking"
                        i.skipped -> "${i.row.label} skipped"
                        i.state == State.OFF -> "${i.row.label}: ${i.row.stateLine.ifEmpty { "off" }.replaceFirstChar { it.lowercase() }}"
                        else -> null
                    }
                }
                if (words.isNotEmpty()) parts += words.joinToString(if (g == Group.APPS) ", " else " · ")
            }
        }
        return parts.joinToString(" · ")
    }

    /** One group open at a time (D2): tapping the open one closes it. Keys: a Group's name, or "tips". */
    fun toggle(open: String?, tapped: String): String? = if (open == tapped) null else tapped

    /** The whole page (§3.1), drawn by ChecklistUi. */
    data class Page(
        val summary: Summary,
        val needs: List<Item>,
        /** Fine but waiting, with a button to finish (Restart KOReader): "Ready now". */
        val ready: List<Item>,
        val groups: List<GroupView>,
        val locked: Boolean,
        /** First run: the Needs you rows are numbered steps. */
        val numbered: Boolean,
    )

    fun page(items: List<Item>, firstRun: Boolean = false, walk: Triple<Int, Int, String>? = null, locked: Boolean = false): Page {
        val s = summary(items, firstRun, walk, locked)
        return Page(s, needsYou(items), items.filter { it.ready }, groups(items), locked, s is Summary.FirstRun)
    }
}

/**
 * The merged Battery row (§3.5) from one BatteryRow.Row per installed app. The per-app ids stay
 * ("battery:Orbit" …) so skips and snoozes still apply per app.
 */
object BatteryMerge {
    enum class AppState { DONE, SET_BY_READER, NEEDS_YOU, LOCKED_WRONG }

    /**
     * One installed app, from BatteryRow (which decides done; this only words it). [locked]: the
     * reader's Settings shows its battery setting as "not available" (Orbit as an active device
     * admin), so nobody can change it there.
     */
    data class App(val name: String, val row: BatteryRow.Row, val locked: Boolean = false) {
        // Keep persisted skip/snooze keys from before the display-name change.
        val id get() = "battery:${if (name == "BookSync") "Orbit" else name}"
    }

    /** Set by the reader (§3.4): already right, and the reader doesn't let anyone change it. */
    fun state(a: App): AppState = when {
        a.row.done && a.locked -> AppState.SET_BY_READER
        a.row.done -> AppState.DONE
        a.locked -> AppState.LOCKED_WRONG
        else -> AppState.NEEDS_YOU
    }

    /** One app's line on the Battery detail page. */
    fun appLine(a: App): String = when (state(a)) {
        AppState.DONE -> "Unrestricted"
        AppState.SET_BY_READER -> "Set by the reader"
        AppState.LOCKED_WRONG -> "Can't be changed in Settings on this reader"
        AppState.NEEDS_YOU -> "Restricted"
    }

    /**
     * One app's verb: Set opens its battery page; where Settings can't change it, Allow opens
     * Android's own prompt (Orbit, BatteryRow.Open.PROMPT), else Help says what can (USB).
     */
    fun appVerb(a: App): String? = when (state(a)) {
        AppState.NEEDS_YOU -> "Set"
        AppState.LOCKED_WRONG -> if (a.row.open == BatteryRow.Open.PROMPT) "Allow" else "Help"
        else -> null
    }

    private fun names(l: List<String>) = when (l.size) {
        0 -> ""
        1 -> l[0]
        else -> l.dropLast(1).joinToString(", ") + " and " + l.last()
    }

    /** The one Battery row. */
    fun row(apps: List<App>, optional: Boolean = false, pinFree: Boolean = false): Checklist.Row {
        val open = apps.filter { state(it) == AppState.NEEDS_YOU || state(it) == AppState.LOCKED_WRONG }
        val byReader = apps.filter { state(it) == AppState.SET_BY_READER }.map { it.name }
        val unrestricted = apps.filter { state(it) == AppState.DONE }.map { it.name }
        val done = open.isEmpty()
        val line = when {
            done && byReader.isEmpty() -> "Unrestricted for ${apps.joinToString(", ") { it.name }}"
            done && unrestricted.isEmpty() -> "Set by the reader"
            done -> "Unrestricted for ${unrestricted.joinToString(", ")} · set by the reader for ${byReader.joinToString(", ")}"
            open.all { state(it) == AppState.LOCKED_WRONG } -> "${names(open.map { it.name })}: can't be changed in Settings on this reader"
            else -> "${names(open.map { it.name })} ${if (open.size == 1) "is" else "are"} restricted"
        }
        return Checklist.Row(
            id = "battery", label = "Battery", done = done, stateLine = line, short = "battery",
            optional = optional, pinFree = pinFree,
            setByReader = done && byReader.isNotEmpty() && unrestricted.isEmpty(),
            verb = if (done) null else if (open.all { appVerb(it) == "Help" }) "Help" else "Fix",
            ids = open.map { it.id },
        )
    }
}

/**
 * The "New in 0.12" tag (§3.8, D14): on a row a recent update added, until the row is done or the
 * next update. [SINCE]: the release that first showed each row id; rows not listed predate the
 * redesign and never get a tag.
 */
object NewIn {
    val SINCE: Map<String, String> = mapOf(
        "wifi_switching" to "0.12.0",
        "sleep_sync" to "0.12.0",
        "reading_fonts" to "0.12.0",
    )

    /** versionCode = MAJOR*10000 + MINOR*100 + PATCH (app/build.gradle.kts). */
    fun versionOf(code: Int): Version? = if (code <= 0) null else Version(code / 10_000, code / 100 % 100, code % 100)

    /** [updatedFrom]: the version the last update came from (null: a fresh install, no tags). */
    fun tag(id: String, done: Boolean, updatedFrom: Version?, current: Version?, since: Map<String, String> = SINCE): String? {
        val s = since[id]?.let { Version.parse(it) } ?: return null
        if (done || updatedFrom == null || s <= updatedFrom) return null
        if (current != null && s > current) return null
        return "New in ${s.major}.${s.minor}"
    }
}

/** The Details page (§3.6): everything a support conversation needs, and Copy for support. */
object SetupDetails {
    fun copyText(version: String, lines: List<Pair<String, String>>): String =
        (listOf("BookSync Companion $version setup details") + lines.map { (k, v) -> "$k: $v" }).joinToString("\n")
}

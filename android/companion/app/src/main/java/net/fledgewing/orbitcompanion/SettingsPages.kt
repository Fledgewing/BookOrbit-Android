package net.fledgewing.orbitcompanion

import android.app.AlertDialog
import android.content.Intent
import android.os.Environment
import android.os.FileObserver
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.InputFilter
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.LinearLayout
import java.io.File

/**
 * The Settings pages (docs/design/companion-settings.md §5): a top page with search and eight
 * sections, one page per section drawn from the shared schema plus the companion's own rows.
 * Behind the Settings PIN they open read-only: values and lines, no controls, one Unlock button
 * (§4.7). A change shows "Waiting for KOReader" until the plugin reports it back (§4.5).
 */
abstract class SettingsPage : EinkActivity() {
    // Read-only while locked (no keypad on open); staying on these pages keeps an unlock.
    override val pinPage: PinPage get() = PinPage.PROTECTED

    protected val schema: SettingsSchema get() = SettingsStore.schema(this)
    protected val prefs: Prefs by lazy { Prefs(this) }
    protected val locked: Boolean get() = forceLocked ?: Pin.locked(this)

    override fun onResume() {
        super.onResume()
        render()
    }

    abstract fun render()

    override fun refresh() = render()

    /** Locked: one line and Unlock; the page redraws with its controls once the PIN is right. */
    protected fun lockedBar(root: LinearLayout) {
        if (!locked) return
        root.addView(Ui.card(this).apply {
            addView(Ui.text(this@SettingsPage, "Settings are locked. You can look; changes need the PIN.", 18f))
            addView(Ui.gap(this@SettingsPage, 8))
            addView(Ui.button(this@SettingsPage, "Unlock", heightDp = 56, sp = 20f) { Pin.run(this@SettingsPage) { render() } })
        })
        root.addView(Ui.gap(this, 12))
    }

    protected fun note(text: String) = Ui.text(this, text, 16f, color = Ui.MID).apply {
        setPadding(0, Ui.dp(this@SettingsPage, 6), 0, Ui.dp(this@SettingsPage, 8))
    }

    protected fun subhead(root: LinearLayout, title: String) {
        root.addView(Ui.text(this, title, 21f, bold = true).apply { setPadding(0, Ui.dp(this@SettingsPage, 14), 0, Ui.dp(this@SettingsPage, 6)) })
    }

    /** A changed shared key: stored with its time, told to the plugin, the page redrawn once. */
    protected fun setShared(key: String, wire: String) {
        if (locked) return
        SettingsStore.set(this, key, wire, "settings page")
        OLog.debug = prefs.debugLog
        render()
    }

    /** The row's line: what it does, then Waiting for KOReader or Changed in KOReader at …. */
    protected fun lineFor(d: SettingDef): String = buildString {
        append(d.line)
        if (d.applies == "restart") append(" Applies when KOReader restarts.")
        if (SettingsStore.pending(this@SettingsPage, d.key)) {
            append(" … Waiting for KOReader")
        } else {
            SettingsStore.fromPluginAt(this@SettingsPage, d.key)?.takeIf { System.currentTimeMillis() - it < 86_400_000L }?.let {
                append(" · Changed in KOReader at ${Ui.clock(this@SettingsPage, it)}")
            }
        }
    }

    protected fun <T> segmented(root: LinearLayout, title: String, sub: String?, options: List<Pair<T, String>>, current: T, pick: (T) -> Unit) {
        root.addView(Ui.text(this, title, 21f).apply { setPadding(0, Ui.dp(this@SettingsPage, 10), 0, Ui.dp(this@SettingsPage, 6)) })
        val rows = if (options.size == 4) options.chunked(2) else listOf(options)
        rows.forEach { row ->
            val seg = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                background = Ui.box(this@SettingsPage, Ui.PAPER)
                val pad = Ui.dp(this@SettingsPage, 2)
                setPadding(pad, pad, pad, pad)
            }
            row.forEach { (value, label) ->
                val sel = value == current
                val t = Ui.text(this, label, 17f, bold = sel, color = if (sel) Ui.PAPER else Ui.INK).apply {
                    gravity = Gravity.CENTER
                    minHeight = Ui.dp(this@SettingsPage, 64)
                    setBackgroundColor(if (sel) Ui.INK else Ui.PAPER)
                }
                if (!locked) Ui.clickable(t, { if (!sel) pick(value) })
                seg.addView(t, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            }
            root.addView(seg)
        }
        if (!sub.isNullOrEmpty()) root.addView(note(sub))
    }

    protected fun toggleRow(root: LinearLayout, label: String, sub: String?, on: Boolean, set: (Boolean) -> Unit): View =
        Ui.row(this, label, sub, Ui.toggle(this, on), onClick = if (locked) null else ({ set(!on) })).also { root.addView(it) }

    protected fun linkRow(root: LinearLayout, label: String, sub: String?, value: String = "›", open: () -> Unit): View =
        Ui.row(this, label, sub, Ui.value(this, value), onClick = open).also { root.addView(it) }

    companion object {
        /** Tests: draw as if the PIN were locked (true) or unlocked (false); null = the real lock. */
        @Volatile
        internal var forceLocked: Boolean? = null

        const val EXTRA_SECTION = "section"
        const val EXTRA_FOCUS = "focus"
        const val EXTRA_KEY = "key"

        fun section(ctx: android.content.Context, id: String, focus: String? = null): Intent =
            Intent(ctx, if (id == "sleep") SleepScreenActivity::class.java else SettingsSectionActivity::class.java)
                .putExtra(EXTRA_SECTION, id).apply { focus?.let { putExtra(EXTRA_FOCUS, it) } }
    }
}

/** Settings: search, then the eight sections with their state in one line (§5.1). */
class SettingsActivity : SettingsPage() {
    private val main = Handler(Looper.getMainLooper())
    private var query = ""
    private var results: LinearLayout? = null
    private val searchNow = Runnable { drawResults() }

    override fun onPause() {
        super.onPause()
        main.removeCallbacks(searchNow)
    }

    override fun render() {
        val root = page(scroll = true)
        root.addView(Ui.header(this, "Settings", "‹ Back") { finish() })
        lockedBar(root)
        val box = EditText(this).apply {
            hint = "Search settings"
            setText(query)
            setSingleLine()
            textSize = 20f
            imeOptions = EditorInfo.IME_ACTION_SEARCH
            minHeight = Ui.dp(this@SettingsActivity, 64)
            background = Ui.box(this@SettingsActivity, Ui.PAPER)
            val p = Ui.dp(this@SettingsActivity, 12)
            setPadding(p, 0, p, 0)
            tag = "search"
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
                override fun afterTextChanged(s: Editable?) {
                    query = s?.toString().orEmpty()
                    // One redraw per pause in typing, none per key (§5.4).
                    main.removeCallbacks(searchNow)
                    main.postDelayed(searchNow, SEARCH_PAUSE_MS)
                }
            })
        }
        root.addView(box)
        root.addView(Ui.gap(this, 8))
        results = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(results)
        drawResults()
    }

    /** The section list, or search results in its place. */
    internal fun drawResults() {
        val out = results ?: return
        out.removeAllViews()
        val q = query.trim()
        if (q.isEmpty()) {
            schema.sections.forEach { s ->
                out.addView(Ui.row(this, s.title, summary(s.id), Ui.value(this, "›"), onClick = { startActivity(SettingsPage.section(this, s.id)) }).apply { tag = "section:${s.id}" })
            }
            out.addView(note("Orbit ${BuildConfig.VERSION_NAME}" + prefs.patchVersionSeen.takeIf { it.isNotEmpty() }?.let { " · plugin $it" }.orEmpty()))
            return
        }
        val hits = SettingsUi.search(schema, q)
        if (hits.isEmpty()) {
            out.addView(note("Nothing matches \"$q\". Try Wi-Fi, sleep, PIN or storage."))
            return
        }
        var last: String? = null
        val get = { k: String -> SettingsStore.get(this, k) }
        hits.forEach { h ->
            if (h.section != last) {
                last = h.section
                out.addView(Ui.text(this, schema.section(h.section)?.title.orEmpty(), 16f, bold = true, color = Ui.MID).apply { setPadding(0, Ui.dp(this@SettingsActivity, 10), 0, 0) })
            }
            val d = schema.byKey[h.id]
            val shown = d == null || SettingsSync.visible(schema, h.id, get)
            val sub = when {
                d == null -> null
                !shown -> SettingsUi.shownWhen(schema, h.id)
                else -> SettingsUi.valueLabel(d, get(h.id))
            }
            // A hidden row opens its section at the parent that shows it.
            val focus = if (shown) h.id else d?.parentKey
            out.addView(Ui.row(this, h.label, sub, Ui.value(this, "›"), onClick = { startActivity(SettingsPage.section(this, h.section, focus)) }).apply { tag = "hit:${h.id}" })
        }
    }

    /** Each section's state in one line (§5.1). */
    private fun summary(id: String): String {
        val g = { k: String -> SettingsStore.get(this, k) }
        fun label(k: String) = schema.byKey[k]?.let { SettingsUi.valueLabel(it, g(k)) }.orEmpty()
        val line = when (id) {
            "reading" -> "Home: ${label("home_button")} · end-of-book sheet ${if (g("eob_sheet") == "1") "on" else "off"}"
            "sleep" -> if (g("sleep_mode") == "off") "The reader's own" else "${label("sleep_mode")}" +
                if (g("sleep_mode") == "recommended") " · ${label("sleep_from")} · every ${g("sleep_hours")} h" else ""
            "sync" -> listOfNotNull(
                label("wifi_mode").takeIf { "wifi" in Mode.caps(this) },
                listOfNotNull("sleep".takeIf { g("sync_on_sleep") == "1" }, "wake".takeIf { g("sync_on_wake") == "1" }).let { if (it.isEmpty()) "no automatic syncs" else "sync on " + it.joinToString(" and ") },
            ).joinToString(" · ")
            "library" -> "Limit ${label("storage_limit_mb")} · " + if (g("mirror_auto") == "1") "Full refresh every ${label("mirror_ttl_days")}" else "Full refresh by hand"
            "buttons" -> "Bluetooth page clicker buttons"
            "kids" -> if (Pin.isSet(this)) "PIN on · ${Pin.guarded(this).size} guarded apps" else "PIN off"
            "setup" -> when (prefs.mode) { OrbitMode.ADDON -> "Add-on mode"; OrbitMode.FULL -> "Full mode"; null -> "Mode not chosen yet" }
            "updates" -> Updater.statusLine(this) + if (g("auto_update_patch") == "1") " · automatic" else ""
            else -> ""
        }
        val waiting = schema.settings.count { it.section == id && !it.hidden && SettingsStore.pending(this, it.key) }
        return if (waiting > 0) "$line · … $waiting waiting for KOReader" else line
    }

    companion object {
        const val SEARCH_PAUSE_MS = 500L
    }
}

/** One section: its shared rows from the schema, the companion's own rows, then Do now (§5.5). */
open class SettingsSectionActivity : SettingsPage() {
    protected open val fixedSection: String? = null
    private val sectionId: String get() = fixedSection ?: intent.getStringExtra(EXTRA_SECTION) ?: "reading"
    private var focus: String? = null
    private var testResult: String? = null
    private var test: NetTest? = null
    private var restartNeeded = false

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        focus = intent.getStringExtra(EXTRA_FOCUS)
    }

    override fun onPause() {
        super.onPause()
        test?.cancel()
    }

    private val addon: Boolean get() = prefs.mode == OrbitMode.ADDON

    override fun render() {
        val root = page(scroll = true)
        val section = schema.section(sectionId)
        root.addView(Ui.header(this, section?.title ?: "Settings", "‹ Settings") { finish() })
        lockedBar(root)
        val extras = SettingsUi.extras(sectionId)
        val focused = mutableListOf<View>()
        fun extra(e: SettingsUi.Extra) {
            val before = root.childCount
            drawExtra(root, e.id)
            if (e.id == focus && root.childCount > before) focused += root.getChildAt(before)
        }
        // A section's companion rows that lead (Home opens before the Home button, the helpers).
        schema.settings.filter { it.section == sectionId }.forEach { d ->
            extras.filter { it.before == d.key && !it.action }.forEach { extra(it) }
            SettingsSlots.draw(this, sectionId, root, locked, before = d.key)
            val before = root.childCount
            drawShared(root, d)
            if (d.key == focus && root.childCount > before) focused += root.getChildAt(before)
        }
        extras.filter { it.before == null && !it.action }.forEach { extra(it) }
        SettingsSlots.draw(this, sectionId, root, locked)
        val actions = extras.filter { it.action }
        if (!locked && (actions.isNotEmpty() || restartNeeded)) {
            subhead(root, "Do now")
            if (restartNeeded) root.addView(Ui.button(this, "Restart KOReader to apply", heightDp = 56, sp = 20f) {
                Koreader.restart(this, "settings: restart to apply")
                restartNeeded = false
            })
            actions.forEach { extra(it) }
            testResult?.let { root.addView(Ui.text(this, it, 18f).apply { setPadding(0, Ui.dp(this@SettingsSectionActivity, 8), 0, 0) }) }
        }
        // The searched row: outlined, at the top of the page.
        focused.firstOrNull()?.let { v ->
            v.foreground = Ui.box(this, android.graphics.Color.TRANSPARENT, strokeDp = 2, radiusDp = 2)
            v.post { (root.parent as? android.widget.ScrollView)?.scrollTo(0, v.top) }
        }
    }

    /** A shared key's row, by its type (§5.5): toggles, segmented up to four values, else a page. */
    private fun drawShared(root: LinearLayout, d: SettingDef) {
        if (d.hidden) return
        if (d.cap != null && d.cap !in Mode.caps(this)) return
        if (d.key == "home_button" && (addon || !HomeApp.showsHomeButton(prefs.homeApp))) return
        val get = { k: String -> SettingsStore.get(this, k) }
        if (!SettingsSync.visible(schema, d.key, get)) return
        val v = get(d.key)
        val line = lineFor(d)
        when {
            d.type == "bool" -> toggleRow(root, d.label, line, v == "1") { on ->
                // Merged rows (§5.2): one switch sets the companion's half too.
                when (d.key) {
                    "wake_tailscale" -> prefs.wakeTailscaleWithWifi = on
                    "auto_update_patch" -> prefs.autoUpdate = on
                    "patch_update_prerelease" -> prefs.includePreReleases = on
                }
                if (d.applies == "restart") restartNeeded = true
                setShared(d.key, if (on) "1" else "0")
            }.tag = "key:${d.key}"
            d.type == "choice" && d.values.size <= 4 -> {
                val before = root.childCount
                segmented(root, d.label, line, d.values, v) { setShared(d.key, it) }
                root.getChildAt(before)?.tag = "key:${d.key}"
            }
            d.type == "choice" || d.type == "source" -> linkRow(root, d.label, line, SettingsUi.valueLabel(d, v, choices()) + "  ›") {
                startActivity(Intent(this, SettingChoiceActivity::class.java).putExtra(EXTRA_KEY, d.key))
            }.tag = "key:${d.key}"
            d.type == "rules" -> linkRow(root, d.label, line, SettingsUi.valueLabel(d, v) + "  ›") {
                startActivity(Intent(this, LeaveOutActivity::class.java))
            }.tag = "key:${d.key}"
            d.type == "text" -> Ui.row(this, d.label, line, Ui.value(this, if (locked) SettingsUi.valueLabel(d, v) else "Edit"),
                onClick = if (locked) null else ({ editText(d, v) })).also {
                if (v.isNotEmpty()) (it.getChildAt(0) as? LinearLayout)?.addView(Ui.text(this, v, 18f, bold = true))
                it.tag = "key:${d.key}"
                root.addView(it)
            }
        }
    }

    private fun choices(): SleepChoices? = SleepChoices.read(SleepScreen.dir())

    /** A one-line text, "12 of 60" under it. */
    private fun editText(d: SettingDef, v: String) {
        val count = Ui.text(this, "", 16f, color = Ui.MID)
        val input = EditText(this).apply {
            setText(v)
            setSingleLine()
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            filters = arrayOf(InputFilter.LengthFilter(d.max * 2))
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, c: Int, after: Int) = Unit
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, c: Int) = Unit
                override fun afterTextChanged(s: Editable?) {
                    val t = s?.toString().orEmpty()
                    count.text = "${t.codePointCount(0, t.length)} of ${d.max}"
                }
            })
        }
        count.text = "${v.codePointCount(0, v.length)} of ${d.max}"
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val p = Ui.dp(this@SettingsSectionActivity, 16)
            setPadding(p, p / 2, p, 0)
            addView(input)
            addView(count)
        }
        AlertDialog.Builder(this).setTitle(d.label).setView(box)
            .setPositiveButton("Save") { _, _ -> setShared(d.key, input.text.toString()) }
            .setNeutralButton("Clear") { _, _ -> setShared(d.key, "") }
            .setNegativeButton("Cancel", null).show()
    }

    /** The companion's own rows, by id (SettingsUi.EXTRAS). */
    private fun drawExtra(root: LinearLayout, id: String) {
        val ro = locked
        when (id) {
            "home_opens" -> if (!addon) {
                val c = prefs.homeApp
                linkRow(root, "Home opens", HomeApp.summary(c, if (HomeApp.isApp(c)) HomeTarget.label(this, c) else null)) {
                    startActivity(Intent(this, HomeAppActivity::class.java))
                }
            }
            "helper_wifi" -> helper(root, "Wi-Fi switching", "Orbit turns Wi-Fi on for a sync and off again", prefs.helperWifi) { prefs.helperWifi = it }
            "helper_sleep_sync" -> helper(root, "Sleep sync", "keeps the reader awake while it syncs on sleep", prefs.helperSleepSync) { prefs.helperSleepSync = it }
            "screen_off" -> if (addon && prefs.helperSleepSync) {
                helper(root, "Screen off after Sync and sleep", if (Net.adminActive(this)) "uses the lock-screen permission" else "asks for the lock-screen permission", prefs.helperScreenOff) {
                    prefs.helperScreenOff = it
                    if (it && !Net.adminActive(this)) {
                        tryStart(
                            Intent(android.app.admin.DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                                .putExtra(android.app.admin.DevicePolicyManager.EXTRA_DEVICE_ADMIN, AdminReceiver.component(this))
                                .putExtra(android.app.admin.DevicePolicyManager.EXTRA_ADD_EXPLANATION, "Lets \"Sync and sleep\" turn the screen off after syncing. It uses only the lock-screen permission."),
                            "device admin",
                        )
                    }
                }
            }
            "wifi_after_sleep" -> if ((!addon || prefs.helperSleepSync) && SettingsStore.get(this, "sync_on_sleep") == "1") {
                segmented(root, "Wi-Fi after sleep sync", "Short naps keep Wi-Fi up, so waking syncs in about 1 s. The timer only turns Wi-Fi off if the screen is still off.",
                    listOf(WifiAfterSleep.KEEP_ON to "Keep on", WifiAfterSleep.OFF_AFTER_30 to "Off after 30 min", WifiAfterSleep.OFF_NOW to "Off now"), prefs.wifiAfterSleep) {
                    prefs.wifiAfterSleep = it
                    companionChanged("wifi_after_sleep=${it.key}")
                }
            }
            "wake_lock" -> if ((!addon || prefs.helperSleepSync) && SettingsStore.get(this, "sync_on_sleep") == "1") {
                toggleRow(root, "Keep the reader awake while syncing", "Released at the plugin's 20 s cap; 25 s at most.", prefs.wakeLockEnabled) {
                    prefs.wakeLockEnabled = it
                    companionChanged("wake_lock=$it")
                }
            }
            "notify_tailscale" -> toggleRow(root, "Tailscale alert", "A notification when Tailscale won't connect.", prefs.notifyTailscale) {
                prefs.notifyTailscale = it
                companionChanged("notify_tailscale=$it")
            }
            "helper_clicker" -> helper(root, "Clicker buttons", "Bluetooth page clicker buttons", prefs.helperClicker) { prefs.helperClicker = it }
            "clickers" -> if (!addon || prefs.helperClicker) {
                linkRow(root, "Clicker buttons", "Bluetooth page clicker: page turns, Home, Back, Sleep") { startActivity(Intent(this, ClickersActivity::class.java)) }
            } else root.addView(note("Without the Clicker buttons helper, clicker buttons are KOReader's own."))
            "helper_pin" -> helper(root, "Settings PIN", "locks Orbit's settings (not your launcher's)", prefs.helperPin) { prefs.helperPin = it }
            "pin" -> when {
                addon && !prefs.helperPin -> Unit
                Pin.isSet(this) -> {
                    linkRow(root, "Settings PIN", "On · tap to change") { Pin.run(this) { startActivity(PinActivity.intent(this, PinActivity.Mode.SET)) } }
                    if (!ro) linkRow(root, "Turn the PIN off", null) {
                        Pin.run(this) {
                            Pin.clear(this, "turned off in Settings")
                            render()
                        }
                    }
                }
                else -> linkRow(root, "Settings PIN", "Off · keeps kids out of settings") { startActivity(PinActivity.intent(this, PinActivity.Mode.SET)) }
            }
            "guarded" -> if ((!addon || prefs.helperPin) && Pin.isSet(this)) {
                linkRow(root, "Guarded apps", "${Pin.guarded(this).size} · open only after the PIN") { Pin.run(this) { startActivity(Intent(this, GuardedAppsActivity::class.java)) } }
            }
            "setup" -> linkRow(root, "Setup", "The checklist: what Orbit needs on this reader") { startActivity(Intent(this, SetupActivity::class.java)) }
            "mode" -> linkRow(root, "Mode", when (prefs.mode) {
                OrbitMode.ADDON -> "Add-on: your launcher stays · Switch"
                OrbitMode.FULL -> "Full: Orbit runs the reader · Switch"
                null -> "not chosen yet"
            }) { Pin.run(this) { startActivity(Intent(this, ModeActivity::class.java)) } }
            "recommended" -> {
                val r = RecommendedPages.read()
                val n = r?.items?.count { it.state == "conflict" } ?: 0
                linkRow(root, "Recommended settings", when {
                    r == null -> "Open KOReader once to see them here."
                    n > 0 -> "$n differ from Orbit's"
                    else -> "${r.items.count { it.state == "applied" }} applied"
                }) { startActivity(Intent(this, RecommendedReviewActivity::class.java)) }
            }
            "skipped" -> prefs.setupIgnored.takeIf { it.isNotEmpty() }?.let { skipped ->
                Ui.row(this, "Skipped setup steps: ${skipped.size}", "tap to be asked again", Ui.value(this, "›"), onClick = if (ro) null else ({
                    Attention.unignoreAll(this)
                    Attention.evaluate(this, "settings")
                    render()
                })).also { root.addView(it) }
            }
            "app_version" -> {
                val ready = Updater.readyToInstall()
                if (ready != null) {
                    root.addView(Ui.row(this, "App version", "Update ready: v${ready.first}", Ui.button(this, "Install", heightDp = 56, sp = 18f) {
                        startActivity(PinActivity.thenInstall(this, ready.second))
                    }))
                } else {
                    root.addView(Ui.row(this, "App version", Updater.statusLine(this), Ui.button(this, if (Updater.busy) "Checking…" else "Check for updates", heightDp = 56, sp = 18f) {
                        Pin.run(this) {
                            Updater.check(this, interactive = true, why = "settings") { if (!isFinishing) render() }
                            render()
                        }
                    }))
                }
            }
            "debug_log" -> toggleRow(root, "Debug log", "More detail in logcat, tag OrbitCompanion.", prefs.debugLog) {
                prefs.debugLog = it
                companionChanged("debug=$it")
            }
            "details" -> linkRow(root, "Details", "Versions and state, for support") { startActivity(Intent(this, SetupDetailsActivity::class.java)) }
            "licenses" -> linkRow(root, "Open-source licenses", null) { startActivity(Intent(this, LicensesActivity::class.java)) }
            "shown_by" -> if (SettingsStore.get(this, "sleep_mode") != "off") {
                linkRow(root, "Shown by", SleepScreen.shownBy(this)) { SleepSetupHelp.setUp(this) { render() } }
            }
            "preview" -> if (SettingsStore.get(this, "sleep_mode") != "off") {
                linkRow(root, "Preview", "5 s, or until you tap") { startActivity(Intent(this, SleepPreviewActivity::class.java)) }
            } else root.addView(note("The reader shows its own sleep screen. Turn this on for a recommended BookOrbit cover or the current book."))
            "do_sync_sleep" -> command("Sync and sleep now", HomeCommands.SYNC_SLEEP, root)
            "do_test_sync_path" -> command("Test the sync path", HomeCommands.TEST_SYNC_PATH, root)
            "do_full_refresh" -> command("Full refresh now", HomeCommands.FULL_REFRESH, root)
            "do_test_network" -> root.addView(Ui.button(this, if (test?.running == true) "Testing…" else "Test network", heightDp = 56, sp = 20f) { runTest() }.withGap())
        }
    }

    private fun View.withGap(): View = apply {
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { topMargin = Ui.dp(this@SettingsSectionActivity, 8) }
    }

    /** A Do now button: KOReader does the work, so it starts with the COMMAND (when its plugin knows it). */
    private fun command(label: String, cmd: String, root: LinearLayout) {
        root.addView(Ui.button(this, label, heightDp = 56, sp = 20f) {
            val plugin = prefs.patchVersionSeen.ifEmpty { null }
            if (PluginCommands.allowed(cmd, plugin) == null) {
                Ui.note(this, "This needs a newer Orbit plugin in KOReader. Install this app's update in Setup, then try again.")
            } else {
                Koreader.start(this, "settings: $label", cmd)
            }
        }.withGap())
    }

    private fun runTest() {
        if (test?.running == true) return
        testResult = "Testing: Wi-Fi on, Tailscale wake…"
        test = NetTest(this, offFirst = false) { ok, summary ->
            testResult = (if (ok) "Network test passed: " else "Network test failed: ") + summary
            render()
        }.also { it.start() }
        render()
    }

    /** An Add-on helper, shown only in Add-on: starts or stops the service and tells the plugin. */
    private fun helper(root: LinearLayout, label: String, sub: String, on: Boolean, set: (Boolean) -> Unit) {
        if (!addon) return
        toggleRow(root, label, sub, on) {
            set(it)
            Mode.helpersChanged(this, "helper $label ${if (it) "on" else "off"}")
            render()
        }
    }

    private fun companionChanged(what: String) {
        OLog.debug = prefs.debugLog
        OLog.i("settings: $what")
        OrbitService.start(this, Intent(OrbitService.ACTION_REFRESH))
        render()
    }
}

/**
 * Rows other features add to a section without editing it, e.g. "Sharp covers: sign in once" in
 * Sleep screen (docs/design/companion-settings.md §6). Drawn after the section's own rows.
 */
object SettingsSlots {
    fun interface Slot {
        fun draw(a: SettingsPage, root: LinearLayout, locked: Boolean)
    }

    private data class Entry(val section: String, val before: String?, val slot: Slot)

    private val slots = mutableListOf(Entry("sleep", "sleep_from", ScreenModeRow), Entry("sleep", "sleep_text", SharpCoversRow))

    /** [before]: drawn just before that shared key's place (whether or not it shows); null: after the section's rows. */
    @Synchronized
    fun register(section: String, before: String? = null, slot: Slot) { slots += Entry(section, before, slot) }

    @Synchronized
    fun draw(a: SettingsPage, section: String, root: LinearLayout, locked: Boolean, before: String? = null) {
        slots.filter { it.section == section && it.before == before }.forEach {
            runCatching { it.slot.draw(a, root, locked) }.onFailure { e -> OLog.w("settings slot in $section", e) }
        }
    }
}

/** A choice with five or more values, or the sleep screen's Pick from (§5.5, §6.1). */
class SettingChoiceActivity : SettingsPage() {
    private var watch: FileObserver? = null

    private val key: String get() = intent.getStringExtra(EXTRA_KEY).orEmpty()

    override fun onResume() {
        super.onResume()
        if (schema.byKey[key]?.type == "source") askForLists()
    }

    override fun onPause() {
        super.onPause()
        watch?.stopWatching()
        watch = null
    }

    /** The picker is open: the plugin writes fresh lists (choices.json) at its next look (§6.2). */
    private fun askForLists() {
        val now = System.currentTimeMillis()
        prefs.wantChoicesAt = now
        StatusFile.write(this, "sleep picker open")
        ClickChannel.settings(now)
        @Suppress("DEPRECATION")
        watch = object : FileObserver(SleepScreen.dir().path, CLOSE_WRITE or MOVED_TO) {
            override fun onEvent(event: Int, path: String?) {
                if (path == SleepChoices.FILE || path == SleepChoices.SCOPES_FILE) runOnUiThread { if (!isFinishing) render() }
            }
        }.also { it.startWatching() }
    }

    override fun render() {
        val d = schema.byKey[key] ?: return finish()
        val root = page(scroll = true)
        root.addView(Ui.header(this, d.label, "‹ Back") { finish() })
        lockedBar(root)
        root.addView(note(lineFor(d)))
        val v = SettingsStore.get(this, key)
        fun option(id: String, label: String, sub: String? = null) {
            val sel = id == v
            root.addView(Ui.row(this, (if (sel) "●  " else "○  ") + label, sub, onClick = if (locked || sel) null else ({ setShared(key, id); finish() })).apply { tag = "option:$id" })
        }
        if (d.type != "source") {
            d.values.forEach { (id, label) -> option(id, label) }
            return
        }
        // Pick from is a set (docs/design/lock-screen.md R1c): each item ticks on and off, the page stays.
        val picked = SleepPoolLogic.sources(v)
        fun tick(id: String, label: String, sub: String? = null) {
            root.addView(Ui.row(this, label, sub, left = Ui.check(this, id in picked),
                onClick = if (locked) null else ({ setShared(key, SleepPoolLogic.togglePick(v, id)) })).apply { tag = "option:$id" })
        }
        tick(SleepPoolLogic.LIBRARY, "Library", "Every book you can see. The others are part of it.")
        subhead(root, "Lists")
        d.values.filter { it.first != SleepPoolLogic.LIBRARY }.forEach { (id, label) -> tick(id, label) }
        val c = SleepChoices.read(SleepScreen.dir())
        if (c == null) {
            root.addView(note("Open KOReader once to load your smart scopes and collections."))
        } else {
            if (c.scopes.isNotEmpty()) subhead(root, "Smart scopes")
            c.scopes.forEach { tick("scope:${it.id}", it.title, it.count?.let { n -> "$n books" }) }
            if (c.collections.isNotEmpty()) subhead(root, "Collections")
            c.collections.forEach { tick("collection:${it.id}", it.title, it.count?.let { n -> "$n books" }) }
            if (c.at > 0) root.addView(note("Lists from KOReader, ${Ui.clock(this, c.at)}" + if (c.cached) " (saved, offline)" else ""))
        }
        picked.filter { (it.startsWith("scope:") || it.startsWith("collection:")) && c?.title(it) == null }.forEach { tick(it, SleepChoices.fallback(it)) }
        root.addView(note("For a custom field: make a smart scope with that condition in BookOrbit, then pick it here."))
    }
}

/** Sleep screen › Leave out: the rules, Remove, and Add a rule (§6.3). */
class LeaveOutActivity : SettingsPage() {
    private enum class View0 { RULES, TAGS, LISTS }
    private var view = View0.RULES

    override fun render() {
        val d = schema.byKey["sleep_leave_out"] ?: return finish()
        val c = SleepChoices.read(SleepScreen.dir())
        val rules = SettingsStore.get(this, d.key).split('\n').filter { it.isNotBlank() }
        val root = page(scroll = true)
        // Ticks on and off; the page stays, so several can be added at once (X8).
        fun toggle(rule: String) = setShared(d.key, SleepPoolLogic.toggleRule(rules.joinToString("\n"), rule))
        fun tickRow(rule: String, label: String, sub: String?) =
            root.addView(Ui.row(this, label, sub, left = Ui.check(this, rule in rules), onClick = if (locked) null else ({ toggle(rule) })).apply { tag = "pick:$rule" })
        when (view) {
            View0.RULES -> {
                root.addView(Ui.header(this, "Leave out", "‹ Back") { finish() })
                lockedBar(root)
                root.addView(note(lineFor(d)))
                if (rules.isEmpty()) root.addView(note("No rules: every book can show."))
                rules.forEach { r ->
                    root.addView(Ui.row(this, c?.ruleLabel(r) ?: SleepChoices.fallback(r), null,
                        if (locked) null else Ui.button(this, "Remove", heightDp = 56, sp = 18f) { setShared(d.key, (rules - r).joinToString("\n")) }).apply { tag = "rule:$r" })
                }
                if (!locked) {
                    subhead(root, "Add a rule")
                    linkRow(root, "Tag…", "From your books' tags, or type one") { view = View0.TAGS; render() }
                    linkRow(root, "Library, smart scopes and collections…", null) { view = View0.LISTS; render() }
                    root.addView(note("For a custom field: make a smart scope with that condition in BookOrbit, then leave it out here."))
                }
            }
            View0.TAGS -> {
                root.addView(Ui.header(this, "Leave out a tag", "‹ Back") { view = View0.RULES; render() })
                linkRow(root, "Type a tag…", null) { typeTag { if ("tag:$it" !in rules) toggle("tag:$it") } }
                if (c == null) root.addView(note("Open KOReader once to list your tags here."))
                c?.tags?.forEach { t -> tickRow("tag:${t.tag}", t.label, "${t.count} books") }
            }
            View0.LISTS -> {
                root.addView(Ui.header(this, "Leave out a list", "‹ Back") { view = View0.RULES; render() })
                tickRow(SleepPoolLogic.LIBRARY, "Library", "Every book: the sleep screen shows the current book instead.")
                if (c == null) root.addView(note("Open KOReader once to load your smart scopes and collections."))
                c?.scopes?.let { l -> if (l.isNotEmpty()) subhead(root, "Smart scopes"); l.forEach { s -> tickRow("scope:${s.id}", s.title, s.count?.let { "$it books" }) } }
                c?.collections?.let { l -> if (l.isNotEmpty()) subhead(root, "Collections"); l.forEach { s -> tickRow("collection:${s.id}", s.title, s.count?.let { "$it books" }) } }
            }
        }
    }

    private fun typeTag(done: (String) -> Unit) {
        val input = EditText(this).apply { setSingleLine(); hint = "age:18" }
        AlertDialog.Builder(this).setTitle("Tag").setView(input)
            .setPositiveButton("Add") { _, _ -> input.text.toString().trim().lowercase().takeIf { it.isNotEmpty() }?.let(done) }
            .setNegativeButton("Cancel", null).show()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (view != View0.RULES) { view = View0.RULES; render() } else super.onBackPressed()
    }
}

object RecommendedPages {
    fun file(): File = File(Environment.getExternalStorageDirectory(), "koreader/settings/${RecommendedReview.FILE}")

    fun read(): RecommendedReview? = RecommendedReview.parse(runCatching { file().readText() }.getOrNull())
}

/** Setup and mode › Recommended settings: the plugin's review list; KOReader applies the choices (§5.8). */
class RecommendedReviewActivity : SettingsPage() {
    override fun render() {
        val root = page(scroll = true)
        root.addView(Ui.header(this, "Recommended settings", "‹ Back") { finish() })
        lockedBar(root)
        val r = RecommendedPages.read()
        if (r == null) {
            root.addView(note("Open KOReader once: the Orbit plugin lists its recommended settings here."))
            return
        }
        val queued = SettingsStore.get(this, "recommended_choice")
        root.addView(note("KOReader applies your choices when it next starts or wakes, because they are KOReader's and BookOrbit's own settings." +
            if (r.at > 0) " List from KOReader, ${Ui.clock(this, r.at)}." else ""))
        r.items.forEach { it0 ->
            val q = SettingsUi.choiceFor(queued, it0.id)?.takeIf { it in it0.offers }
            val sub = it0.stateLine + (q?.let { " … ${RecommendedReview.CHOICE_WORDS[it]}: waiting for KOReader" } ?: "")
            val buttons = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            if (!locked && q == null) it0.offers.forEach { what ->
                buttons.addView(Ui.button(this, RecommendedReview.CHOICE_WORDS.getValue(what), heightDp = 56, sp = 16f) { choose(it0.id, what) },
                    LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginStart = Ui.dp(this@RecommendedReviewActivity, 6) })
            }
            root.addView(Ui.row(this, it0.label, sub, buttons).apply { tag = "rec:${it0.id}" })
        }
        if (!locked && r.items.any { it.state == "conflict" } && queued.isEmpty()) {
            root.addView(Ui.gap(this, 12))
            root.addView(Ui.button(this, "Use Orbit's for all", heightDp = 56, sp = 20f) { choose("all", "ours") })
        }
    }

    private fun choose(id: String, what: String) {
        setShared("recommended_choice", SettingsUi.withChoice(SettingsStore.get(this, "recommended_choice"), id, what))
    }
}

/** Sleep screen's Shown by row (docs/design/lock-screen.md P1-P3): choose Orbit's screen saver, or say how. */
object SleepSetupHelp {
    fun setUp(a: EinkActivity, redraw: () -> Unit) {
        when (SleepScreen.sink(a)) {
            SleepSink.DREAM -> when {
                SleepScreen.oursChosen(a) -> Ui.note(a, "Orbit's screen saver shows the sleep screen.")
                SleepScreen.chooseOurs(a, "Set up") -> redraw()
                !a.tryStart(Intent(android.provider.Settings.ACTION_DREAM_SETTINGS), "screen saver settings") -> Ui.note(a,
                    "This reader hides its Screen saver settings. Connect it to a computer and run:\n\ntools/install-usb.sh --sleep-screen on\n\n" +
                        "or, once, tools/install-usb.sh --grant-screen-saver so Orbit can switch it itself.")
            }
            SleepSink.PICTURE -> Ui.note(a,
                "On the reader: Apps › Screensaver › Screensaver style, pick the picture Pictures/Orbit/sleep.png. Orbit keeps it up to date.")
        }
    }
}

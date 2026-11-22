package net.fledgewing.orbitcompanion

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import android.os.SystemClock
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The HOME activity. Translucent and empty: it never draws, it only decides.
 * Every Home press and every boot starts KOReader with "home"; a second press within 2 s, or a
 * KOReader that is missing or won't start, shows the launcher page instead (HomeDecider).
 */
class HomeActivity : Activity() {
    companion object {
        /** Process-wide, so presses are paired across activity re-creation. */
        val decider = HomeDecider()
    }

    private var pressPending = false
    private var startOnScreenOn = false

    private val screenOnReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            if (startOnScreenOn) {
                startOnScreenOn = false
                OLog.i("home: screen on, starting the deferred KOReader")
                decide(press = false)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.setWindowAnimations(0)
        OrbitService.start(this)
        registerReceiver(screenOnReceiver, IntentFilter(Intent.ACTION_SCREEN_ON))
        pressPending = true // boot, or a Home press that found no home task
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pressPending = true
    }

    override fun onResume() {
        super.onResume()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
        val press = pressPending
        pressPending = false
        if (!Net.screenOn(this)) {
            // KOReader went away with the screen off (some firmwares force-stop the foreground app
            // a while after the power button). Start it on the next wake, not now: a start now
            // could be stopped again.
            startOnScreenOn = true
            OLog.i("home: ${if (press) "press" else "uncovered"} with the screen off, KOReader starts on wake")
            return
        }
        decide(press)
    }

    private fun decide(press: Boolean) {
        // A new setup step: the prompt once, then (when it closes) on to KOReader as usual.
        if (press && Attention.promptOnHome(this)) return
        val prefs = Prefs(this)
        val choice = prefs.homeApp
        val other = !HomeApp.isKoreader(choice)
        // Disabled (e.g. a vendor launcher's app freeze) counts as unusable: starting it would throw.
        val problem = if (other) HomeTarget.problem(this, choice) else Koreader.problem(this)
        val installed = problem == null
        val now = SystemClock.elapsedRealtime()
        val action = if (press) {
            decider.onHomePress(now, installed, prefs.homeOpensKoreader)
        } else {
            decider.onUncovered(now, installed, prefs.homeOpensKoreader)
        }
        val why = when {
            problem != null -> problem
            !prefs.homeOpensKoreader -> null
            press -> "Home pressed twice."
            else -> "${HomeTarget.name(this)} closed straight after starting."
        }
        OLog.i("home ${if (press) "press" else "uncovered"}: $action${if (problem != null) " ($problem)" else ""}")
        if (action == HomeAction.START_KOREADER) {
            // "Home button": BookOrbit home -> "home" on a press, a plain start after KOReader went
            // away. Back to my book -> "home_smart" for both; the patch decides (HomePlan).
            // Another "Home opens" app: just bring it to the front (HomeApp.launch).
            val l = HomeApp.launch(choice, press, prefs.homeButton, EinkActivity.companionPageInFront())
            val reason = if (press) "home press" else "home uncovered"
            val started = if (l.pkg != null) {
                HomeTarget.start(this, l.pkg, reason)
            } else {
                OLog.i("home: ${prefs.homeButton.key} -> command ${l.command ?: "-"}${if (l.from != null) " from ${l.from}" else ""}")
                Koreader.start(this, reason, l.command, l.from)
            }
            if (started) return
            decider.startFailed()
            showLauncher("${HomeTarget.name(this)} didn't start.")
        } else {
            showLauncher(why)
        }
    }

    private fun showLauncher(why: String?) {
        val i = Intent(this, LauncherActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
        if (why != null) i.putExtra("why", why)
        startActivity(i)
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        // A launcher ignores Back.
    }

    override fun onDestroy() {
        unregisterReceiver(screenOnReceiver)
        super.onDestroy()
    }
}

/** Mockup 1: the escape-hatch launcher page. */
class LauncherActivity : EinkActivity() {
    private var why: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        why = intent.getStringExtra("why")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        why = intent.getStringExtra("why")
    }

    override fun onResume() {
        super.onResume()
        // Unfrozen since: drop the stale message.
        if (why == Vendor.disabledMessage(this, "KOReader") && Koreader.state(this) != AppState.FROZEN) why = null
        render()
    }

    private fun render() {
        val root = page()
        root.addView(Ui.header(this, "Orbit"))
        val choice = Prefs(this).homeApp
        if (!HomeApp.isKoreader(choice)) {
            // "Home opens" another app: it is the big first tile; KOReader stays a tile below.
            val name = HomeTarget.label(this, choice)
            root.addView(Ui.button(this, "Open $name", solid = true, heightDp = 120, sp = 26f) {
                if (HomeTarget.start(this, choice, "launcher button")) {
                    HomeActivity.decider.startedByHand(SystemClock.elapsedRealtime())
                } else {
                    why = HomeTarget.problem(this, choice) ?: "$name didn't start."
                    render()
                }
            })
            root.addView(Ui.gap(this, 8))
        }
        val koFirst = HomeApp.isKoreader(choice)
        val open = Ui.button(this, "Open KOReader\n", solid = koFirst, heightDp = if (koFirst) 120 else 88, sp = if (koFirst) 26f else 22f) {
            if (Koreader.goHome(this, "launcher button")) {
                HomeActivity.decider.startedByHand(SystemClock.elapsedRealtime())
            } else {
                why = Koreader.problem(this) ?: "KOReader didn't start."
                render()
            }
        }
        open.text = android.text.SpannableStringBuilder().apply {
            append("Open KOReader\n")
            val s = length
            append(if (Prefs(this@LauncherActivity).homeButton == HomeButton.SMART) "back to your book" else "opens on BookOrbit home")
            setSpan(android.text.style.RelativeSizeSpan(0.65f), s, length, 0)
            setSpan(android.text.style.StyleSpan(android.graphics.Typeface.NORMAL), s, length, 0)
        }
        root.addView(open)
        why?.let { root.addView(Ui.text(this, it, 18f, color = Ui.MID).apply { setPadding(0, Ui.dp(this@LauncherActivity, 8), 0, 0) }) }
        if (Koreader.state(this) == AppState.FROZEN) {
            root.addView(Ui.gap(this, 8))
            root.addView(
                Ui.button(this, "Re-enable KOReader") {
                    tryStart(Vendor.reenablePage(this, Koreader.PKG), "re-enable page")
                },
            )
        }
        Attention.evaluate(this, "launcher", notify = false)
        Attention.bannerText(this)?.let { t ->
            root.addView(Ui.gap(this, 8))
            root.addView(Ui.text(this, t, 19f, bold = true).also { v ->
                Ui.clickable(v, { startActivity(Intent(this, AttentionActivity::class.java)) })
            })
        }
        root.addView(Ui.gap(this, 16))
        root.addView(
            Ui.weightRow(
                this,
                Ui.button(this, "⋯  Other apps") { startActivity(Intent(this, AppsActivity::class.java)) },
                Ui.button(this, "⚙  Companion") { startActivity(Intent(this, StatusActivity::class.java)) },
            ),
        )
        root.addView(Ui.gap(this, 12))
        // Wi-Fi by hand: on here is the user's, so "Just in time" leaves it on until they turn it off.
        val wifiOn = Net.wifiEnabled(this)
        root.addView(Ui.row(this, "Wi-Fi", if (wifiOn) "on · ${Prefs(this).wifiOwner.key}" else "off", Ui.toggle(this, wifiOn), onClick = {
            if (wifiOn) {
                Net.setWifi(this, false, "launcher Wi-Fi tile")
            } else {
                Net.setWifi(this, true, "launcher Wi-Fi tile", WifiOwner.MANUAL)
            }
            android.os.Handler(mainLooper).postDelayed({ if (!isFinishing) render() }, 800)
        }))
        root.addView(Ui.gap(this, 12))
        val card = Ui.card(this)
        card.addView(Ui.row(this, "Network", right = Ui.value(this, Status.networkLine(this))))
        card.addView(Ui.row(this, "Last sleep sync", right = Ui.value(this, Status.lastSleepSync(this))))
        root.addView(card)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        // The launcher page is the bottom of the Home task: Back does nothing.
    }
}

/**
 * Mockup 2: pinned tiles, then all apps A–Z, paged (no scrolling). Hold a row to pin or unpin;
 * hold a tile to unpin. Also opened by the patch (SHOW_APPS).
 */
class AppsActivity : EinkActivity() {
    data class App(val label: String, val component: ComponentName)

    companion object {
        const val MAX_PINS = 6

        /** Fixed "Android Settings" tile: not a real component; launch() opens Settings.ACTION_SETTINGS. */
        val SETTINGS_TILE = ComponentName("android.settings", "ACTION_SETTINGS")
    }

    private lateinit var prefs: Prefs
    private var apps: List<App> = emptyList()
    private var pageIndex = 0
    private var perPage = 0
    private var note: String = "hold to pin"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        prefs = Prefs(this)
    }

    override fun onResume() {
        super.onResume()
        apps = loadApps()
        if (prefs.pins == null) prefs.pins = defaultPins()
        seedSettingsPin()
        render()
    }

    private fun loadApps(): List<App> {
        val t0 = SystemClock.elapsedRealtime()
        val pm = packageManager
        val main = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val list = pm.queryIntentActivities(main, 0)
            .filter { it.activityInfo.packageName != packageName }
            .map { App(it.loadLabel(pm).toString(), ComponentName(it.activityInfo.packageName, it.activityInfo.name)) }
            .toMutableList()
        // "<Vendor> home" from the vendor profile, if this device has one (Vendor.kt).
        Vendor.homeTile(this)?.let { (label, component) -> list.add(App(label, component)) }
        list.add(App("Android Settings", SETTINGS_TILE))
        val sorted = list.distinctBy { it.component }.sortedBy { it.label.lowercase() }
        OLog.d("apps page: ${sorted.size} apps in ${OLog.since(t0)} ms")
        return sorted
    }

    private fun defaultPins(): List<String> {
        val tailscale = apps.firstOrNull { it.component.packageName == Net.TAILSCALE_PKG }?.component
        val vendorHome = Vendor.homeTile(this)?.second?.let { home -> apps.firstOrNull { it.component == home }?.component }
        return listOfNotNull(tailscale, SETTINGS_TILE, vendorHome).map { it.flattenToString() }
    }

    /** Once per install: pins made before the Settings tile existed get it too. Unpinning sticks. */
    private fun seedSettingsPin() {
        if (prefs.settingsPinSeeded) return
        prefs.settingsPinSeeded = true
        val key = SETTINGS_TILE.flattenToString()
        val pins = prefs.pins.orEmpty()
        if (key !in pins && pins.size < MAX_PINS) prefs.pins = pins + key
    }

    private fun pinned(): List<App> {
        val byKey = apps.associateBy { it.component.flattenToString() }
        return prefs.pins.orEmpty().mapNotNull { byKey[it] }
    }

    private fun launch(app: App) {
        if (app.component == SETTINGS_TILE) {
            tryStart(Intent(android.provider.Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), "Android Settings")
            return
        }
        val i = Intent(Intent.ACTION_MAIN).setComponent(app.component).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (app.component != Vendor.homeTile(this)?.second) i.addCategory(Intent.CATEGORY_LAUNCHER)
        tryStart(i, "app ${app.component.flattenToShortString()}")
    }

    private fun togglePin(app: App) {
        val key = app.component.flattenToString()
        val pins = prefs.pins.orEmpty().toMutableList()
        note = when {
            pins.remove(key) -> "Unpinned ${app.label}"
            pins.size >= MAX_PINS -> "Six pinned: hold a tile to unpin one"
            else -> {
                pins.add(key)
                "Pinned ${app.label}"
            }
        }
        prefs.pins = pins
        render()
    }

    private fun render() {
        val root = page()
        root.addView(Ui.header(this, "Other apps", "‹ Back") { finish() })

        // Pinned tiles, three per row.
        val tiles = pinned()
        tiles.chunked(3).forEach { rowApps ->
            val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            for (i in 0 until 3) {
                val lp = LinearLayout.LayoutParams(0, Ui.dp(this, 110), 1f).apply {
                    if (i > 0) marginStart = Ui.dp(this@AppsActivity, 10)
                }
                val app = rowApps.getOrNull(i)
                row.addView(if (app == null) View(this) else tile(app), lp)
            }
            root.addView(row)
            root.addView(Ui.gap(this, 10))
        }

        val label = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, Ui.dp(this@AppsActivity, 8), 0, Ui.dp(this@AppsActivity, 4))
            addView(Ui.text(this@AppsActivity, "ALL APPS · A–Z", 16f, bold = true), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(Ui.text(this@AppsActivity, note, 16f, color = Ui.MID))
        }
        root.addView(label)

        val list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(list, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        val pager = TextView(this)
        val prev = Ui.button(this, "‹ prev", heightDp = 72) { turn(-1) }
        val next = Ui.button(this, "next ›", heightDp = 72) { turn(+1) }
        pager.gravity = Gravity.CENTER
        pager.textSize = 18f
        pager.setTextColor(Ui.INK)
        val footer = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(prev, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(pager, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(next, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }
        root.addView(footer)

        // The page size depends on the space left, known after layout.
        list.addOnLayoutChangeListener { v, _, top, _, bottom, _, oldTop, _, oldBottom ->
            if (bottom - top != oldBottom - oldTop || perPage == 0) {
                perPage = maxOf(1, (bottom - top) / Ui.dp(this, Ui.ROW_DP + 4))
                v.post { fillPage(list, pager) }
            }
        }
        if (perPage > 0) fillPage(list, pager)
    }

    private fun pageCount() = maxOf(1, (apps.size + perPage - 1) / maxOf(1, perPage))

    private fun turn(delta: Int) {
        val n = pageCount()
        pageIndex = (pageIndex + delta + n) % n
        render()
    }

    private fun fillPage(list: LinearLayout, pager: TextView) {
        list.removeAllViews()
        val n = pageCount()
        pageIndex = pageIndex.coerceIn(0, n - 1)
        val pins = prefs.pins.orEmpty().toSet()
        apps.drop(pageIndex * perPage).take(perPage).forEach { app ->
            val pinned = app.component.flattenToString() in pins
            list.addView(
                Ui.row(
                    this, app.label,
                    left = Ui.letter(this, app.label),
                    right = if (pinned) Ui.value(this, "pinned", bold = false) else null,
                    onClick = { launch(app) },
                    onLong = { togglePin(app) },
                ),
            )
        }
        pager.text = "page ${pageIndex + 1} of $n"
    }

    private fun tile(app: App): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER
        background = Ui.pressable(Ui.box(this@AppsActivity, Ui.PAPER), Ui.box(this@AppsActivity, Ui.PRESSED))
        addView(Ui.letter(this@AppsActivity, app.label).apply {
            (layoutParams as LinearLayout.LayoutParams).marginEnd = 0
        })
        addView(Ui.text(this@AppsActivity, app.label, 16f).apply {
            gravity = Gravity.CENTER
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        })
        Ui.clickable(this, { launch(app) }, { togglePin(app) })
    }
}

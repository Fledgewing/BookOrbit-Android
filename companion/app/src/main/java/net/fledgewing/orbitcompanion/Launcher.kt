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
            // KOReader was force-stopped with the screen off (the M8C does this ~110 s after the
            // power button). Start it on the next wake, not now: a start now would be killed again.
            startOnScreenOn = true
            OLog.i("home: ${if (press) "press" else "uncovered"} with the screen off, KOReader starts on wake")
            return
        }
        decide(press)
    }

    private fun decide(press: Boolean) {
        val prefs = Prefs(this)
        val installed = Koreader.installed(this)
        val now = SystemClock.elapsedRealtime()
        val action = if (press) {
            decider.onHomePress(now, installed, prefs.homeOpensKoreader)
        } else {
            decider.onUncovered(now, installed, prefs.homeOpensKoreader)
        }
        val why = when {
            !installed -> "KOReader isn't installed."
            !prefs.homeOpensKoreader -> null
            press -> "Home pressed twice."
            else -> "KOReader closed straight after starting."
        }
        OLog.i("home ${if (press) "press" else "uncovered"}: $action")
        if (action == HomeAction.START_KOREADER) {
            // A press goes to BookOrbit home; a restart after KOReader went away (killed after
            // sleep) reopens it as a plain start, so the reader lands back in the book.
            val started = if (press) Koreader.goHome(this, "home press") else Koreader.start(this, "home uncovered", null)
            if (started) return
            decider.startFailed()
            showLauncher("KOReader didn't start.")
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
        render()
    }

    private fun render() {
        val root = page()
        root.addView(Ui.header(this, "Orbit"))
        val open = Ui.button(this, "Open KOReader\n", solid = true, heightDp = 120, sp = 26f) {
            if (Koreader.goHome(this, "launcher button")) {
                HomeActivity.decider.startedByHand(SystemClock.elapsedRealtime())
            } else {
                why = if (Koreader.installed(this)) "KOReader didn't start." else "KOReader isn't installed."
                render()
            }
        }
        open.text = android.text.SpannableStringBuilder().apply {
            append("Open KOReader\n")
            val s = length
            append("opens on BookOrbit home")
            setSpan(android.text.style.RelativeSizeSpan(0.65f), s, length, 0)
            setSpan(android.text.style.StyleSpan(android.graphics.Typeface.NORMAL), s, length, 0)
        }
        root.addView(open)
        why?.let { root.addView(Ui.text(this, it, 18f, color = Ui.MID).apply { setPadding(0, Ui.dp(this@LauncherActivity, 8), 0, 0) }) }
        root.addView(Ui.gap(this, 16))
        root.addView(
            Ui.weightRow(
                this,
                Ui.button(this, "⋯  Other apps") { startActivity(Intent(this, AppsActivity::class.java)) },
                Ui.button(this, "⚙  Companion") { startActivity(Intent(this, StatusActivity::class.java)) },
            ),
        )
        root.addView(Ui.gap(this, 24))
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
        val MEEBOOK_HOME = ComponentName("com.haoqing.app.hqreader", "com.haoqing.app.hqreader.view.activity.LauncherActivity")
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
        if (Net.installed(this, MEEBOOK_HOME.packageName)) list.add(App("Meebook home", MEEBOOK_HOME))
        val sorted = list.distinctBy { it.component }.sortedBy { it.label.lowercase() }
        OLog.d("apps page: ${sorted.size} apps in ${OLog.since(t0)} ms")
        return sorted
    }

    private fun defaultPins(): List<String> {
        val wanted = listOf(Net.TAILSCALE_PKG, "com.android.settings", MEEBOOK_HOME.packageName)
        return wanted.mapNotNull { pkg ->
            if (pkg == MEEBOOK_HOME.packageName) {
                apps.firstOrNull { it.component == MEEBOOK_HOME }
            } else {
                apps.firstOrNull { it.component.packageName == pkg }
            }?.component?.flattenToString()
        }
    }

    private fun pinned(): List<App> {
        val byKey = apps.associateBy { it.component.flattenToString() }
        return prefs.pins.orEmpty().mapNotNull { byKey[it] }
    }

    private fun launch(app: App) {
        val i = Intent(Intent.ACTION_MAIN).setComponent(app.component).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (app.component != MEEBOOK_HOME) i.addCategory(Intent.CATEGORY_LAUNCHER)
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

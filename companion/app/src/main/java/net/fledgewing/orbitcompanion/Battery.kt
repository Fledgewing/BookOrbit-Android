package net.fledgewing.orbitcompanion

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import java.io.File
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.TextStyle
import java.util.Locale

/**
 * Battery page (docs/STATS-DESIGN.md, mockups docs/stats-mockups.html): paged, never
 * scrolled. Now, Rates, By setting, History, Compare; Export and Import as their own pages.
 */
class BatteryActivity : EinkActivity() {
    private enum class Tab(val label: String) { NOW("Now"), RATES("Rates"), SETTING("By setting"), HISTORY("History"), COMPARE("Compare"), EXPORT("Export"), IMPORT("Import") }

    private val zone: ZoneId = ZoneId.systemDefault()
    private var tab = Tab.NOW
    private var view: StatsStore.View? = null
    private var historyPage = 0
    private var comparePage = 0
    private var importMsg: String? = null
    private var exportMsg: String? = null

    companion object {
        private const val REQ_EXPORT = 21
        private const val REQ_IMPORT = 22
        private const val DAYS_PER_PAGE = 7
        private const val IMPORTS_PER_PAGE = 2
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        savedInstanceState?.getString("tab")?.let { t -> Tab.entries.firstOrNull { it.name == t }?.let { tab = it } }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString("tab", tab.name)
    }

    override fun onResume() {
        super.onResume()
        load()
    }

    private fun load() {
        Thread {
            val v = try { StatsStore.get(this).view(System.currentTimeMillis(), zone) } catch (e: Exception) {
                OLog.w("stats: view failed", e); null
            }
            runOnUiThread {
                view = v
                if (!isFinishing) render()
            }
        }.start()
    }

    // ---- small building blocks -------------------------------------------------------------

    private fun line(root: LinearLayout, label: String, sub: String?, value: String, dim: Boolean = false) {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = Ui.dp(this@BatteryActivity, 52)
            setPadding(0, Ui.dp(this@BatteryActivity, 4), 0, Ui.dp(this@BatteryActivity, 4))
        }
        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        col.addView(Ui.text(this, label, 19f))
        if (sub != null) col.addView(Ui.text(this, sub, 14f, color = Ui.MID))
        row.addView(col, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        row.addView(Ui.text(this, value, 20f, bold = !dim, color = if (dim) Ui.MID else Ui.INK).apply { gravity = Gravity.END })
        root.addView(row)
        root.addView(View(this).apply { setBackgroundColor(Ui.LIGHT) }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, Ui.dp(this, 1)))
    }

    private fun section(root: LinearLayout, title: String) {
        root.addView(Ui.text(this, title, 16f, bold = true, color = Ui.MID).apply { setPadding(0, Ui.dp(this@BatteryActivity, 10), 0, 0) })
    }

    private fun f1(v: Double) = String.format(Locale.US, "%.1f", v)
    private fun f2(v: Double) = String.format(Locale.US, "%.2f", v)
    private fun rateText(r: Rate) = (if (r.pctPerH < 1) f2(r.pctPerH) else f1(r.pctPerH)) + " %/h" + (r.se?.let { " ± " + (if (it < 1) f2(it) else f1(it)) } ?: "")
    private fun hoursText(h: Double): String = when {
        h < 1 -> "${(h * 60).toInt()} min"
        h < 48 -> "about ${h.toInt()} h"
        else -> "about ${(h / 24).toInt()} days ${(h % 24).toInt()} h"
    }
    private fun minText(m: Double): String = if (m < 60) "${m.toInt()} min" else "${(m / 60).toInt()} h ${(m % 60).toInt()} min"

    /** A rate line: the value with its data, or "—" and what's missing. */
    private fun rateLine(root: LinearLayout, label: String, cat: String) {
        val r = BatteryStats.rate(cat, view?.totals?.get(cat))
        when {
            r == null -> line(root, label, "no data yet", "—", dim = true)
            r.shown -> line(root, label, "${f1(r.hours)} h of data · ${r.segments} stretches", rateText(r))
            else -> line(root, label, r.missing, "—", dim = true)
        }
    }

    private fun tabs(root: LinearLayout) {
        val main = listOf(Tab.NOW, Tab.RATES, Tab.SETTING, Tab.HISTORY, Tab.COMPARE)
        val buttons = main.map { t ->
            Ui.button(this, t.label, solid = t == tab, heightDp = 56, sp = 15f) {
                tab = t
                render()
            }
        }
        root.addView(Ui.weightRow(this, *buttons.toTypedArray(), gapDp = 4))
        root.addView(Ui.gap(this, 8))
    }

    private fun render() {
        val root = page()
        when (tab) {
            Tab.EXPORT -> return exportPage(root)
            Tab.IMPORT -> return importPage(root)
            else -> Unit
        }
        root.addView(Ui.header(this, "Battery", "Back") { finish() })
        tabs(root)
        val v = view
        if (v == null) {
            root.addView(Ui.text(this, "Loading…", 20f, color = Ui.MID))
            return
        }
        when (tab) {
            Tab.NOW -> nowPage(root, v)
            Tab.RATES -> ratesPage(root, v)
            Tab.SETTING -> settingPage(root)
            Tab.HISTORY -> historyPage(root, v)
            Tab.COMPARE -> comparePage(root, v)
            else -> Unit
        }
    }

    private fun foot(root: LinearLayout, vararg views: View) {
        root.addView(View(this), LinearLayout.LayoutParams(1, 0, 1f))
        root.addView(Ui.weightRow(this, *views))
    }

    // ---- pages ----------------------------------------------------------------------------

    private fun nowPage(root: LinearLayout, v: StatsStore.View) {
        val last = v.last
        val level = last?.level ?: -1
        root.addView(Ui.text(this, if (level >= 0) "$level%" else "—", 56f, bold = true))
        root.addView(Ui.text(this, if (last?.charging == true) "Charging" else "Not charging", 17f, color = Ui.MID))
        val t = v.totals
        val rStandby = BatteryStats.rate("standby", t["standby"])
        val rReading = BatteryStats.rate("reading", t["reading"])
        val recent = v.days.takeLast(BatteryStats.ESTIMATE_WINDOW_DAYS)
        val f = BatteryStats.onShare(recent)
        section(root, "TIME LEFT")
        val mix = BatteryStats.hoursLeft(level, f, rReading, rStandby)
        line(root, "At your usual use", if (f != null) "last 7 days: screen on ${minText(recent.sumOf { it.screenMin } / recent.size)} a day" else "needs 24 h of use and both rates",
            mix?.let { hoursText(it) } ?: "—", dim = mix == null)
        val text = BatteryStats.hoursLeftAt(level, BatteryStats.rate("reading|content=text", t["reading|content=text"]))
        line(root, "Reading text non-stop", null, text?.let { hoursText(it) } ?: "—", dim = text == null)
        val sb = BatteryStats.hoursLeftAt(level, rStandby)
        line(root, "Standby only", null, sb?.let { hoursText(it) } ?: "—", dim = sb == null)
        section(root, "TODAY")
        val today = v.days.lastOrNull()?.takeIf { it.day == BatteryStats.day(System.currentTimeMillis(), zone) } ?: DayTotals(0)
        line(root, "Used", null, "${today.usedPct}%")
        line(root, "Screen on", null, minText(today.screenMin))
        line(root, "Pages turned", null, "${today.pages}")
        line(root, "Full / partial refreshes", null, "${today.full} / ${today.partial}")
        val since = LocalDate.ofEpochDay(BatteryStats.day(v.rawSince, zone))
        root.addView(Ui.text(this, "Data since ${since.dayOfMonth} ${since.month.getDisplayName(TextStyle.SHORT, Locale.getDefault())} · ${v.days.size} days", 15f, color = Ui.MID).apply {
            setPadding(0, Ui.dp(this@BatteryActivity, 8), 0, 0)
        })
        foot(root, Ui.button(this, "Export…", heightDp = 64, sp = 19f) { tab = Tab.EXPORT; exportMsg = null; render() })
    }

    private fun ratesPage(root: LinearLayout, v: StatsStore.View) {
        rateLine(root, "Standby (screen off)", "standby")
        rateLine(root, "Reading (all)", "reading")
        rateLine(root, "Screen on, not reading", "awake")
        rateLine(root, "Charging", "charging")
        section(root, "PER 100")
        for ((label, cat) in listOf("text" to "reading|content=text", "comic" to "reading|content=comic", "webtoon" to "reading|content=webtoon", "PDF" to "reading|content=pdf")) {
            val s = v.totals[cat]
            if (s == null || s.pages == 0L) continue
            val p = BatteryStats.per100(BatteryStats.rate(cat, s), s.pages)
            line(root, "Per 100 pages ($label)", "${s.pages} pages", p?.let { f1(it) + "%" } ?: "—", dim = p == null)
        }
        val s = v.totals["reading"]
        val pf = BatteryStats.per100(BatteryStats.rate("reading", s), s?.full ?: 0)
        line(root, "Per 100 full refreshes", "${s?.full ?: 0} full refreshes", pf?.let { f1(it) + "%" } ?: "—", dim = pf == null)
        foot(root, Ui.text(this, "± = how sure (1 standard error). \"—\": under 1 h or 2% of data.", 15f, color = Ui.MID))
    }

    private fun settingPage(root: LinearLayout) {
        section(root, "STANDBY, BY WI-FI MODE")
        WifiMode.entries.forEach { m -> rateLine(root, m.label, "standby|wifi_mode=${m.key}") }
        section(root, "READING")
        listOf("text" to "Text", "comic" to "Comic", "webtoon" to "Webtoon (continuous)", "pdf" to "PDF").forEach { (k, l) -> rateLine(root, l, "reading|content=$k") }
        rateLine(root, "Frontlight on", "reading|light=on")
        rateLine(root, "Frontlight off", "reading|light=off")
        WifiMode.entries.forEach { m -> rateLine(root, "Wi-Fi ${m.label}", "reading|wifi_mode=${m.key}") }
    }

    private fun historyPage(root: LinearLayout, v: StatsStore.View) {
        val days = v.days.sortedByDescending { it.day }
        val pages = maxOf(1, (days.size + DAYS_PER_PAGE - 1) / DAYS_PER_PAGE)
        historyPage = historyPage.coerceIn(0, pages - 1)
        val shown = days.drop(historyPage * DAYS_PER_PAGE).take(DAYS_PER_PAGE)
        val maxUsed = maxOf(20, days.maxOfOrNull { it.usedPct } ?: 0)
        root.addView(Ui.text(this, "% used per day (bar), screen on, pages, full refreshes", 15f, color = Ui.MID))
        val today = BatteryStats.day(System.currentTimeMillis(), zone)
        val barMax = resources.displayMetrics.widthPixels - Ui.dp(this, 200)
        for (d in shown) {
            val date = LocalDate.ofEpochDay(d.day)
            val name = if (d.day == today) "Today" else "${date.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.getDefault())} ${date.dayOfMonth}"
            val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
            row.addView(Ui.text(this, name, 18f, bold = true), LinearLayout.LayoutParams(Ui.dp(this, 90), ViewGroup.LayoutParams.WRAP_CONTENT))
            val bar = View(this).apply { setBackgroundColor(if (d.charges > 0) Ui.MID else Ui.INK) }
            row.addView(bar, LinearLayout.LayoutParams(maxOf(2, barMax * d.usedPct / maxUsed), Ui.dp(this, 16)))
            row.addView(View(this), LinearLayout.LayoutParams(0, 1, 1f))
            row.addView(Ui.text(this, "${d.usedPct}%", 18f, bold = true))
            root.addView(row)
            val extra = listOfNotNull(minText(d.screenMin), "${d.pages} pages", "${d.full} full", if (d.charges > 0) "charged" else null).joinToString(" · ")
            root.addView(Ui.text(this, extra, 14f, color = Ui.MID).apply { setPadding(Ui.dp(this@BatteryActivity, 90), 0, 0, Ui.dp(this@BatteryActivity, 8)) })
        }
        if (shown.isEmpty()) root.addView(Ui.text(this, "No days yet.", 18f, color = Ui.MID))
        foot(root,
            Ui.button(this, "‹ Newer", heightDp = 64, sp = 18f) { if (historyPage > 0) { historyPage--; render() } },
            Ui.text(this, "${historyPage + 1} / $pages", 17f, color = Ui.MID).apply { gravity = Gravity.CENTER },
            Ui.button(this, "Older ›", heightDp = 64, sp = 18f) { if (historyPage < pages - 1) { historyPage++; render() } })
    }

    private fun importsDir() = File(filesDir, "imports").apply { mkdirs() }

    private fun imports(): List<Pair<File, StatsExport.Imported>> =
        importsDir().listFiles()?.sortedBy { it.name }?.mapNotNull { f ->
            try { f to StatsExport.parse(f.readText()) } catch (e: Exception) { null }
        } ?: emptyList()

    private fun comparePage(root: LinearLayout, v: StatsStore.View) {
        val all = imports()
        val pages = maxOf(1, (all.size + IMPORTS_PER_PAGE - 1) / IMPORTS_PER_PAGE)
        comparePage = comparePage.coerceIn(0, pages - 1)
        val others = all.drop(comparePage * IMPORTS_PER_PAGE).take(IMPORTS_PER_PAGE)
        fun cellRate(rates: Map<String, Rate>, vararg cats: String): String {
            for (c in cats) {
                val r = rates[c] ?: continue
                return if (r.shown) (if (r.pctPerH < 1) f2(r.pctPerH) else f1(r.pctPerH)) + "\n${f1(r.hours)} h" + (if (c == "awake") " (awake)" else "") else "—\n${f1(r.hours)} h"
            }
            return "n/a"
        }
        val mine = v.totals.mapNotNull { (c, s) -> BatteryStats.rate(c, s)?.let { c to it } }.toMap()
        val cap = StatsRecorder.capacity(this)
        val reading = v.totals["reading"]
        val cols = listOf(
            listOf("This ${Build.MODEL}", "Android ${Build.VERSION.RELEASE}",
                cellRate(mine, "standby"), cellRate(mine, "reading", "awake"), cellRate(mine, "reading|content=text"), cellRate(mine, "reading|content=comic"),
                BatteryStats.per100(mine["reading"], reading?.pages ?: 0)?.let { f1(it) + "%" } ?: "—",
                cap?.let { "${it.first} mAh" } ?: "—", "${v.days.size}"),
        ) + others.map { (_, im) ->
            listOf(im.label, if (im.source == StatsExport.SOURCE_ANDROID) "Android ${im.androidVersion ?: "?"}" else im.source,
                cellRate(im.rates, "standby"), cellRate(im.rates, "reading", "awake"), cellRate(im.rates, "reading|content=text"), cellRate(im.rates, "reading|content=comic"),
                im.per100Pages?.let { f1(it) + "%" } ?: "—", im.capacityMah?.let { "$it mAh" } ?: "—",
                (if (im.days > 0) "${im.days}" else "no dates\n${f1(im.hours)} h") + if (im.batterySource == "voltage_estimate") "\n% from voltage" else "")
        }
        // Firmware readers only know asleep/awake (docs/STATS.md): say so in the row names.
        val fw = others.any { it.second.asleepAwake }
        val labels = listOf("", "", if (fw) "Standby / asleep %/h" else "Standby %/h", if (fw) "Reading / awake %/h" else "Reading %/h",
            "Text %/h", "Comic %/h", "Per 100 pages", "Capacity", "Days of data")
        for (i in labels.indices) {
            val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setPadding(0, Ui.dp(this@BatteryActivity, 3), 0, Ui.dp(this@BatteryActivity, 3)) }
            row.addView(Ui.text(this, labels[i], 16f, color = Ui.MID), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1.1f))
            cols.forEach { c -> row.addView(Ui.text(this, c[i], if (i == 1) 14f else 17f, bold = i == 0 || (i >= 2 && !c[i].startsWith("—") && c[i] != "n/a"), color = if (i == 1) Ui.MID else Ui.INK), LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)) }
            root.addView(row)
            root.addView(View(this).apply { setBackgroundColor(Ui.LIGHT) }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, Ui.dp(this, 1)))
        }
        if (all.isEmpty()) root.addView(Ui.text(this, "Import another reader's battery summary to compare it here.", 17f, color = Ui.MID).apply { setPadding(0, Ui.dp(this@BatteryActivity, 10), 0, 0) })
        val buttons = mutableListOf<View>(Ui.button(this, "Import…", heightDp = 64, sp = 18f) { tab = Tab.IMPORT; importMsg = null; render() })
        if (others.isNotEmpty()) buttons += Ui.button(this, "Remove…", heightDp = 64, sp = 18f) { removeImport(others.map { it.first }) }
        if (pages > 1) buttons += Ui.button(this, "${comparePage + 1}/$pages ›", heightDp = 64, sp = 18f) { comparePage = (comparePage + 1) % pages; render() }
        foot(root, *buttons.toTypedArray())
    }

    private fun removeImport(files: List<File>) {
        val root = page()
        root.addView(Ui.header(this, "Remove from Compare", "Back") { render() })
        files.forEach { f ->
            val label = try { StatsExport.parse(f.readText()).label } catch (e: Exception) { f.name }
            root.addView(Ui.row(this, label, f.name, Ui.value(this, "Remove"), onClick = {
                f.delete()
                OLog.i("stats: removed import ${f.name}")
                render()
            }))
        }
    }

    private fun exportPage(root: LinearLayout) {
        root.addView(Ui.header(this, "Export battery summary", "Back") { tab = Tab.NOW; render() })
        root.addView(Ui.text(this, "A file to compare with other readers (format orbit-battery-stats/1). It holds:", 18f))
        listOf(
            "Model, Android version, battery capacity, app version",
            "The rates and per-100 numbers, with their hours of data",
            "% used, screen time, pages and refreshes per day",
            "Each stretch of the last 90 days: start and end time, %, and its settings",
        ).forEach { root.addView(Ui.text(this, "• $it", 17f)) }
        root.addView(Ui.gap(this, 8))
        root.addView(Ui.text(this, "Never included: book titles or files, Wi-Fi names, accounts, or any device ID.", 17f, color = Ui.MID))
        root.addView(Ui.gap(this, 16))
        root.addView(Ui.button(this, "Save…", solid = true) { startExport() })
        exportMsg?.let { root.addView(Ui.text(this, it, 18f, bold = true).apply { setPadding(0, Ui.dp(this@BatteryActivity, 12), 0, 0) }) }
    }

    private fun exportName() = "orbit-battery-${Build.MODEL.replace(Regex("[^A-Za-z0-9]+"), "")}-${LocalDate.now(zone)}.json"

    private fun startExport() {
        val i = Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("application/json")
            .putExtra(Intent.EXTRA_TITLE, exportName())
        @Suppress("DEPRECATION")
        try {
            startActivityForResult(i, REQ_EXPORT)
        } catch (e: Exception) {
            // No document picker: straight to Downloads (the storage permission from the patch install).
            writeExport { json ->
                val f = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), exportName())
                f.writeText(json)
                "Saved to Downloads/${f.name}"
            }
        }
    }

    private fun writeExport(write: (String) -> String) {
        exportMsg = "Saving…"
        render()
        Thread {
            val msg = try {
                val now = System.currentTimeMillis()
                val store = StatsStore.get(this)
                val v = store.view(now, zone)
                val json = StatsExport.build(StatsRecorder.device(this), BuildConfig.VERSION_NAME, now, zone, v.totals, v.days, store.exportSegments(now))
                write(json.toString(1)).also { OLog.i("stats: exported (${v.days.size} days)") }
            } catch (e: Exception) {
                OLog.w("stats: export failed", e)
                "Couldn't save: ${e.message ?: e.javaClass.simpleName}"
            }
            runOnUiThread { exportMsg = msg; if (tab == Tab.EXPORT) render() }
        }.start()
    }

    private fun importPage(root: LinearLayout) {
        root.addView(Ui.header(this, "Import a summary", "Back") { tab = Tab.COMPARE; render() })
        root.addView(Ui.text(this, "Pick a file another reader exported (orbit-battery-stats/1). It shows on Compare next to this device; it is never mixed into this device's numbers.", 18f))
        root.addView(Ui.gap(this, 16))
        root.addView(Ui.button(this, "Pick a file…", solid = true) {
            val i = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
            @Suppress("DEPRECATION")
            if (!tryStartForResult(i, REQ_IMPORT)) { importMsg = "No file picker on this device."; render() }
        })
        importMsg?.let { root.addView(Ui.text(this, it, 18f, bold = true).apply { setPadding(0, Ui.dp(this@BatteryActivity, 12), 0, 0) }) }
    }

    @Suppress("DEPRECATION")
    private fun tryStartForResult(i: Intent, req: Int): Boolean = try {
        startActivityForResult(i, req); true
    } catch (e: Exception) {
        false
    }

    @Deprecated("Activity result API; this app uses no AndroidX")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        val uri: Uri = data?.data ?: return
        if (resultCode != RESULT_OK) return
        when (requestCode) {
            REQ_EXPORT -> writeExport { json ->
                contentResolver.openOutputStream(uri, "wt")?.use { it.write(json.toByteArray()) } ?: error("can't write there")
                "Saved."
            }
            REQ_IMPORT -> {
                importMsg = try {
                    val text = contentResolver.openInputStream(uri)?.use { s -> s.readBytes().toString(Charsets.UTF_8) } ?: error("can't read it")
                    val im = StatsExport.parse(text)
                    val name = "import-${System.currentTimeMillis()}.json"
                    File(importsDir(), name).writeText(text)
                    OLog.i("stats: imported ${im.label} (${im.source}, ${im.days} days)")
                    "Added ${im.label} (${im.days} days) to Compare."
                } catch (e: StatsExport.BadFile) {
                    "Not usable: ${e.message}"
                } catch (e: Exception) {
                    "Couldn't read it: ${e.message ?: e.javaClass.simpleName}"
                }
                tab = Tab.IMPORT
            }
        }
        render()
    }
}

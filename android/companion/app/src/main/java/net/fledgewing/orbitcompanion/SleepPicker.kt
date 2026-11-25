package net.fledgewing.orbitcompanion

import android.os.FileObserver
import android.os.Handler
import android.os.Looper
import android.widget.LinearLayout
import android.widget.TextView
import android.view.View
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/** Serial disk work for the sleep pickers. Drawing and taps only use the in-memory snapshot. */
internal object SleepPickerWork {
    private val worker = BulkWork.executor
    internal var executor: Executor = worker
    @Volatile var choices: SleepChoices? = null

    fun submit(job: () -> Unit) = executor.execute(job)
}

/** Both pickers use the companion worker's saved lists, with refresh and file I/O off the UI thread. */
abstract class SleepPickerPage : SettingsPage() {
    protected open val loadsChoices: Boolean get() = true
    protected val choices: SleepChoices? get() = SleepPickerWork.choices
    private val main = Handler(Looper.getMainLooper())
    private var generation = 0
    private var watch: FileObserver? = null
    private data class Tick(val id: String, val row: View, val box: TextView, val label: String)
    private val ticks = mutableListOf<Tick>()
    private var statusNote: TextView? = null

    protected fun beginPicker() { ticks.clear(); statusNote = null }

    protected fun pickerNote(d: SettingDef): TextView = note(lineFor(d)).also { statusNote = it }

    protected fun pickerRow(root: LinearLayout, id: String, label: String, sub: String?, selected: Boolean, tag: String, choose: () -> Unit) {
        val box = Ui.check(this, selected)
        val row = Ui.row(this, label, sub, left = box, onClick = if (locked) null else choose).apply {
            this.tag = tag
            isSelected = selected
            contentDescription = "$label: ${if (selected) "selected" else "not selected"}"
        }
        ticks += Tick(id, row, box, label)
        root.addView(row)
    }

    override fun onResume() {
        val opened = System.nanoTime()
        super.onResume()
        if (!loadsChoices) return
        OLog.i("sleep picker: open and draw in ${(System.nanoTime() - opened) / 1_000_000} ms")
        val token = ++generation
        val app = applicationContext
        SleepPickerWork.submit {
            val start = System.nanoTime()
            val dir = SleepScreen.dir()
            @Suppress("DEPRECATION")
            val observer = object : FileObserver(dir.path, CLOSE_WRITE or MOVED_TO) {
                override fun onEvent(event: Int, path: String?) {
                    if (path == SleepChoices.SCOPES_FILE || path == SleepChoices.TAGS_FILE) load(token)
                }
            }
            observer.startWatching()
            main.post {
                if (token == generation) watch = observer else SleepPickerWork.submit { observer.stopWatching() }
            }
            readChoices(token)
            val now = System.currentTimeMillis()
            Prefs(app).wantChoicesAt = now
            StatusFile.write(app, "sleep picker open")
            ClickChannel.settings(now)
            OLog.i("sleep picker: lists and refresh queued in ${(System.nanoTime() - start) / 1_000_000} ms on worker")
        }
    }

    private fun load(token: Int) = SleepPickerWork.submit { readChoices(token) }

    private fun readChoices(token: Int) {
        SleepPickerWork.choices = SleepChoices.read(SleepScreen.dir())
        main.post { if (token == generation && !isFinishing && !isDestroyed) render() }
    }

    override fun onPause() {
        ++generation
        watch?.let { observer -> SleepPickerWork.submit { observer.stopWatching() } }
        watch = null
        super.onPause()
    }

    /** Store locally now, then sync and redraw the picture in the worker; the checkmark never waits. */
    protected fun setPicked(key: String, value: String) {
        if (locked) return
        val start = System.nanoTime()
        SettingsStore.setPicker(this, key, value)
        val wire = SettingsStore.get(this, key)
        val selected = (if (key == "sleep_from") SleepPoolLogic.sources(wire) else SleepPoolLogic.rules(wire)).toSet()
        if (selected.any { id -> ticks.none { it.id == id } }) {
            // A typed tag needs a new row; ordinary taps keep the existing rows and scroll position.
            render()
        } else {
            ticks.forEach { tick ->
                val on = tick.id in selected
                if (tick.row.isSelected != on) {
                    tick.row.isSelected = on
                    tick.row.contentDescription = "${tick.label}: ${if (on) "selected" else "not selected"}"
                    tick.box.text = if (on) "✓" else ""
                    tick.box.background = Ui.box(this, if (on) Ui.INK else Ui.PAPER, radiusDp = 2)
                }
            }
            statusNote?.text = lineFor(schema.byKey.getValue(key))
        }
        OLog.i("sleep picker: toggle and draw in ${(System.nanoTime() - start) / 1_000_000} ms")
    }
}

package net.fledgewing.orbitcompanion

import android.os.FileObserver
import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/** Serial disk work for the sleep pickers. Drawing and taps only use the in-memory snapshot. */
internal object SleepPickerWork {
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "orbit-sleep-picker").apply { isDaemon = true } }
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
        render()
        OLog.i("sleep picker: toggle and draw in ${(System.nanoTime() - start) / 1_000_000} ms")
    }
}

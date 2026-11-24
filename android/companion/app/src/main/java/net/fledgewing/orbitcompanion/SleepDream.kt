package net.fledgewing.orbitcompanion

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.service.dreams.DreamService
import android.view.Choreographer
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView

/**
 * "Orbit sleep screen": the screen saver the system starts when the reader goes to sleep (the dream
 * sink, docs/design/lock-screen.md). Only the system starts it (BIND_DREAM_SERVICE), so it never
 * shows while a book is read; it draws once, from files already on the device, with the battery
 * level at that moment. Never interactive: a touch wakes the reader as it always did (K3).
 * With the clearing flash on (L10, SleepFlash) a black, then a white frame come before the cover.
 */
class SleepDream : DreamService() {
    private var shown: Bitmap? = null
    private val main = Handler(Looper.getMainLooper())
    private var flash: SleepFlash.Runner? = null
    private var wake: PowerManager.WakeLock? = null

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        isInteractive = false
        isFullscreen = true
        isScreenBright = false
    }

    override fun onDreamingStarted() {
        super.onDreamingStarted()
        val bmp = try {
            val (w, h, dpi) = SleepScreen.panel(this)
            SleepScreen.render(this, w, h, dpi, advance = true, why = "screen saver")
        } catch (e: Exception) {
            OLog.w("sleep screen: screen saver failed to draw", e)
            return
        }
        // L1: drawn portrait; a reader asleep in landscape gets it turned.
        val dm = resources.displayMetrics
        val turned = if (dm.widthPixels > dm.heightPixels) {
            Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, android.graphics.Matrix().apply { postRotate(90f) }, true).also { bmp.recycle() }
        } else {
            bmp
        }
        shown = turned
        val cover = ImageView(this).apply {
            setBackgroundColor(Color.WHITE)
            scaleType = ImageView.ScaleType.FIT_CENTER
            setImageBitmap(turned)
        }
        // A full-panel plate over the cover for the flash frames; gone for the cover.
        val plate = View(this).apply { visibility = View.GONE }
        setContentView(FrameLayout(this).apply {
            addView(cover, FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
            addView(plate, FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
        })
        val frames = SleepFlash.frames(SleepScreen.settings(this).flash)
        if (frames.size > 1) holdAwake()
        flash = SleepFlash.Runner(
            frames,
            show = { f ->
                when (f) {
                    SleepFlash.Frame.BLACK -> plate.apply { setBackgroundColor(Color.BLACK); visibility = View.VISIBLE }
                    SleepFlash.Frame.WHITE -> plate.apply { setBackgroundColor(Color.WHITE); visibility = View.VISIBLE }
                    SleepFlash.Frame.COVER -> plate.visibility = View.GONE
                }
            },
            // The frame callback after the next one: the frame with the change has been drawn by then.
            afterDrawn = { next ->
                Choreographer.getInstance().postFrameCallback { Choreographer.getInstance().postFrameCallback { next() } }
            },
            delay = { ms, next -> main.postDelayed(next, ms) },
            now = { SystemClock.elapsedRealtime() },
            done = { ms ->
                if (frames.size > 1) {
                    OLog.i(SleepFlash.line(ms))
                    // Let the cover frame reach the panel before the reader may sleep.
                    main.postDelayed({ releaseWake() }, SleepFlash.HOLD_MS)
                }
            },
        ).also { it.start() }
    }

    /** The flash takes ~0.5 s: keep the CPU up until the cover is on the panel (timed, never held). */
    private fun holdAwake() {
        wake = runCatching {
            (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "orbit:sleep-flash").apply { acquire(3_000L) }
        }.getOrNull()
    }

    private fun releaseWake() {
        runCatching { wake?.takeIf { it.isHeld }?.release() }
        wake = null
    }

    override fun onDreamingStopped() {
        super.onDreamingStopped()
        flash?.cancel()
        main.removeCallbacksAndMessages(null)
        releaseWake()
        OLog.i("sleep screen: screen saver stopped")
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        flash?.cancel()
        main.removeCallbacksAndMessages(null)
        releaseWake()
        shown?.recycle()
        shown = null
    }
}

package net.fledgewing.orbitcompanion

import android.graphics.Bitmap
import android.service.dreams.DreamService
import android.widget.ImageView

/**
 * "Orbit sleep screen": the screen saver the system starts when the reader goes to sleep (the dream
 * sink, docs/design/lock-screen.md). Only the system starts it (BIND_DREAM_SERVICE), so it never
 * shows while a book is read; it draws once, from files already on the device, with the battery
 * level at that moment. Never interactive: a touch wakes the reader as it always did (K3).
 */
class SleepDream : DreamService() {
    private var shown: Bitmap? = null

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
        setContentView(ImageView(this).apply {
            setBackgroundColor(android.graphics.Color.WHITE)
            scaleType = ImageView.ScaleType.FIT_CENTER
            setImageBitmap(turned)
        })
    }

    override fun onDreamingStopped() {
        super.onDreamingStopped()
        OLog.i("sleep screen: screen saver stopped")
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        shown?.recycle()
        shown = null
    }
}

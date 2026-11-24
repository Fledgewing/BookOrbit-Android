package net.fledgewing.orbitcompanion

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.LinearLayout

/**
 * Settings › Sleep screen (docs/design/lock-screen.md S1, S2; companion-settings §6): the section
 * page for the shared sleep-screen keys, also opened by KOReader's menu (SHOW_SLEEP). Read-only
 * behind the Settings PIN (K1).
 */
class SleepScreenActivity : SettingsSectionActivity() {
    override val fixedSection: String = "sleep"
}

/**
 * The preview (S2): the sleep screen as it would show now, for 5 s or until a tap. Opened from
 * KOReader's menu (SLEEP_PREVIEW) or the page above: a user action, so the reading gate allows it.
 * It never moves the rotation on.
 */
class SleepPreviewActivity : EinkActivity() {
    private val main = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val (w, h, dpi) = SleepScreen.panel(this)
        val bmp = SleepScreen.render(this, w, h, dpi, advance = false, why = "preview")
        val view = ImageView(this).apply {
            setBackgroundColor(android.graphics.Color.WHITE)
            scaleType = ImageView.ScaleType.FIT_CENTER
            setImageBitmap(bmp)
            setOnClickListener { finish() }
        }
        setContentView(view)
        main.postDelayed({ if (!isFinishing) finish() }, 5_000)
    }

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        super.onDestroy()
    }
}

/**
 * Setup's one optional row for the sleep screen (docs/design/lock-screen.md P3), in the Add-on
 * design's style: shown only while Sleep screen is on and the reader uses the screen saver.
 */
object SleepSetup {
    /** The checklist's id for it (Checklist.GROUP_OF, its "On:" / "Without it:" lines). */
    const val ID = "screen_saver"
    const val TITLE = "Switch the screen saver from Orbit"
    const val COMMAND = "Connect the reader to a computer and run, once:\n\ntools/install-usb.sh --grant-screen-saver\n\n" +
        "Without it: tools/install-usb.sh --sleep-screen on (or off) does the switch itself."

    fun shown(mode: SleepMode, sink: SleepSink): Boolean = mode != SleepMode.OFF && sink == SleepSink.DREAM

    fun check(ctx: android.content.Context): Check? {
        if (!shown(SleepScreen.settings(ctx).mode, SleepScreen.sink(ctx))) return null
        val granted = SleepScreen.canSwitch(ctx)
        val line = Checklist.optionalLine(ID, granted).orEmpty()
        return Check(TITLE, granted, line, action = if (granted) null else "Show how", optional = true, id = ID) { a ->
            OLog.i("setup: sleep screen optional row: Show how")
            Ui.note(a, COMMAND)
        }
    }
}

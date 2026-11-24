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
 * L7: Sharp covers, the Sleep screen section's row (docs/design/sharp-sleep-covers, through
 * SettingsSlots): signed in once, or the thumbnail fallback (a state, not a mode). Shown for
 * Recommended cover, after Change cover every.
 */
object SharpCoversRow : SettingsSlots.Slot {
    override fun draw(a: SettingsPage, root: LinearLayout, locked: Boolean) {
        if (SettingsStore.get(a, "sleep_mode") != "recommended") return
        val acct = SharpCovers.account()
        val state = SharpCovers.state(a)
        val ids = SleepScreen.pool().map { it.id }
        val (sub, value) = SharpCoversLogic.row(state, acct != null, SharpCovers.sharpCount(a, ids), ids.size, SharpCovers.lostWhy(a))
        root.addView(Ui.row(a, SharpCoversLogic.TITLE, sub, if (value.isEmpty()) null else Ui.value(a, value), onClick = when {
            acct == null || locked -> null
            state == SharpCoversLogic.State.ON -> { -> signOutAsk(a) }
            else -> { -> signIn(a, acct) }
        }).apply { tag = "slot:sharp_covers" })
    }

    private fun signOutAsk(a: SettingsPage) {
        android.app.AlertDialog.Builder(a)
            .setMessage("Sleep-screen covers come from BookOrbit's full-size cover. Sign out to use the small thumbnail again.")
            .setPositiveButton("Sign out") { _, _ -> SharpCovers.signOut(a, "companion page"); a.render() }
            .setNegativeButton("Keep", null).show()
    }

    /** The OPDS login, once: the password goes to one request and is cleared; only the cover link is kept. */
    private fun signIn(a: SettingsPage, acct: SharpCovers.Account) {
        val pad = Ui.dp(a, 16)
        val user = android.widget.EditText(a).apply {
            hint = "OPDS username"
            setText(SharpCovers.user(a) ?: acct.user)
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
        }
        val pass = android.widget.EditText(a).apply {
            hint = "OPDS password"
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD
        }
        val box = LinearLayout(a).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad / 2, pad, 0)
            addView(Ui.text(a, SharpCoversLogic.PROMPT, 16f, color = Ui.MID))
            addView(user)
            addView(pass)
        }
        android.app.AlertDialog.Builder(a).setTitle(SharpCoversLogic.TITLE).setView(box)
            .setPositiveButton("Sign in") { _, _ ->
                val name = user.text.toString().trim()
                val e = pass.text
                val pw = CharArray(e.length).also { e.getChars(0, e.length, it, 0) }
                e.clear()
                kotlin.concurrent.thread(name = "orbit-sharp-sign-in") {
                    val msg = SharpCovers.signIn(a, acct.server, name, pw)
                    if (msg == null) SharpCovers.sync(a, "signed in")
                    a.runOnUiThread {
                        if (a.isFinishing) return@runOnUiThread
                        a.render()
                        Ui.note(a, msg ?: "Signed in. Sharp covers download now while the reader is online.")
                    }
                }
            }
            .setNegativeButton("Cancel") { _, _ -> pass.text.clear() }
            .show()
    }
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
